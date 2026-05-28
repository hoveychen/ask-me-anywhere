//! `ama` — a CLI inbox node for manual two-process testing of the P2P sync.
//!
//! Two terminals:
//!
//! ```text
//!   term A:  ama create --name desktop      # prints a pairing ticket + QR
//!   term B:  ama join   --name phone <TICKET>
//! ```
//!
//! Both then drop into an interactive prompt. `send <text>` pushes an
//! actionable card; the other node prints it as it syncs in. `dismiss <id>`
//! flips the shared state and converges on both sides. This is the human-driven
//! counterpart to the P4 integration test.
//!
//! For scripted injection use `ama send` (one-shot, M5 P1): joins an inbox by
//! ticket, pushes a card described by a JSON file (or stdin), holds the node
//! alive briefly so gossip can flush, and exits.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use ama_core::{build_endpoint, now_ms, Inbox, LiveEvent, MessageCard, RelayChoice, Status};
use axum::{
    extract::State,
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    middleware::{from_fn_with_state, Next},
    response::IntoResponse,
    routing::{get as http_get, post},
    Json, Router,
};
use clap::{Parser, Subcommand};
use futures_lite::StreamExt;
use qrcode::{render::unicode, QrCode};
use serde::Deserialize;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};

#[derive(Parser)]
#[command(name = "ama", about = "Ask-me-anywhere P2P inbox node")]
struct Cli {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create a fresh inbox and print a pairing ticket for other devices.
    Create {
        /// Human-readable device label (stamped into state writes).
        #[arg(long, default_value = "device")]
        name: String,
        /// Self-hosted relay URL (e.g. https://relay.example.com). Defaults to
        /// n0's public relays when omitted.
        #[arg(long)]
        relay: Option<String>,
    },
    /// Join an existing inbox using a ticket from `create`.
    Join {
        /// The pairing ticket emitted by `ama create`.
        ticket: String,
        #[arg(long, default_value = "device")]
        name: String,
        /// Self-hosted relay URL. Defaults to n0's public relays when omitted.
        #[arg(long)]
        relay: Option<String>,
    },
    /// One-shot: join an inbox, push a card described in a JSON file (or stdin),
    /// hold the node alive briefly so gossip can deliver, then exit.
    Send {
        /// Ticket of the inbox to push into.
        #[arg(long)]
        ticket: String,
        /// Path to the card JSON, or `-` for stdin.
        #[arg(long = "card-file")]
        card_file: String,
        /// Default `source` for the card when the JSON omits it (the JSON's own
        /// `source` field wins). Also stamped onto state writes.
        #[arg(long, default_value = "script")]
        name: String,
        /// Self-hosted relay URL. Defaults to n0's public relays when omitted.
        #[arg(long)]
        relay: Option<String>,
        /// Maximum seconds to hold the node open after the local push, giving
        /// gossip a chance to deliver the entry to at least one peer. The CLI
        /// exits sooner once it sees a `SyncFinished` event.
        #[arg(long, default_value_t = 5)]
        wait_secs: u64,
    },
    /// Long-running webhook bridge: join an inbox once, listen on HTTP, and
    /// forward `POST /push` bodies (same JSON shape as `send --card-file`) as
    /// cards into the inbox. `GET /healthz` is a liveness probe.
    Serve {
        /// Ticket of the inbox to push into. The server joins once at startup
        /// and reuses the same embedded node for the process lifetime.
        #[arg(long, env = "AMA_TICKET")]
        ticket: String,
        /// TCP address to bind, e.g. `127.0.0.1:8080` or `0.0.0.0:8080`.
        #[arg(long, env = "AMA_BIND", default_value = "127.0.0.1:8080")]
        bind: String,
        /// Default `source` stamped on incoming cards that omit it.
        #[arg(long, env = "AMA_NAME", default_value = "webhook")]
        name: String,
        /// Self-hosted relay URL. Defaults to n0's public relays when omitted.
        #[arg(long, env = "AMA_RELAY")]
        relay: Option<String>,
        /// Inline bearer token required on POST routes (`/push`, `/github/pr`).
        /// Mutually exclusive with `--token-file`. When neither is set the
        /// server runs OPEN (logged at startup).
        #[arg(long, env = "AMA_TOKEN", conflicts_with = "token_file")]
        token: Option<String>,
        /// Path to a file whose first line is the bearer token. Trailing
        /// whitespace is trimmed.
        #[arg(long, env = "AMA_TOKEN_FILE")]
        token_file: Option<String>,
    },
}

/// JSON shape accepted by `ama send`. `summary` is required (it backs the
/// system notification when A2UI can't render); `a2ui` defaults to `{}` for
/// summary-only cards; `source` defaults to the CLI's `--name` flag.
#[derive(Debug, Deserialize, PartialEq)]
struct CardInput {
    summary: String,
    #[serde(default)]
    a2ui: Option<serde_json::Value>,
    #[serde(default)]
    source: Option<String>,
}

impl CardInput {
    /// Resolve the input plus a fallback `source` into a fully-formed
    /// [`MessageCard`]. `id` is freshly minted; `created_at` is now.
    fn into_card(self, default_source: &str) -> MessageCard {
        MessageCard {
            id: uuid::Uuid::new_v4().to_string(),
            a2ui: self.a2ui.unwrap_or_else(|| serde_json::json!({})),
            summary: self.summary,
            source: self.source.unwrap_or_else(|| default_source.to_string()),
            created_at: now_ms(),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Install a tracing subscriber so RUST_LOG=iroh_docs=debug,ama=trace etc.
    // surfaces the iroh / gossip / docs event stream; without this, all the
    // tracing-crate spans the network stack emits are silently dropped.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    let cli = Cli::parse();

    let inbox = match cli.cmd {
        Command::Create { name, relay } => {
            let endpoint = build_endpoint(RelayChoice::from_url_opt(relay.as_deref())?).await?;
            let inbox = Inbox::create(endpoint, name).await?;
            // The ticket's reachability is carried by the relay URL; minting
            // it before the relay is assigned produces an unreachable ticket,
            // and external dials (ama send / ama serve / a paired device just
            // after scanning) time out at the gossip layer. See
            // crates/core/tests/sync.rs::wait_relay.
            wait_relay(&inbox).await?;
            let ticket = inbox.ticket().await?;
            print_ticket(&ticket.to_string());
            Arc::new(inbox)
        }
        Command::Join { ticket, name, relay } => {
            let ticket = ticket.parse().context("parse ticket")?;
            let endpoint = build_endpoint(RelayChoice::from_url_opt(relay.as_deref())?).await?;
            let inbox = Inbox::join(endpoint, ticket, name).await?;
            println!("joined inbox {}", inbox.doc_id());
            Arc::new(inbox)
        }
        Command::Send { ticket, card_file, name, relay, wait_secs } => {
            return run_send(ticket, card_file, name, relay, wait_secs).await;
        }
        Command::Serve { ticket, bind, name, relay, token, token_file } => {
            return run_serve(ticket, bind, name, relay, token, token_file).await;
        }
    };

    // Watch the document for remote changes in the background.
    let events = inbox.subscribe().await?;
    tokio::spawn(watch(inbox.clone(), events));

    repl(inbox).await
}

/// One-shot send: join, push, drain gossip, shutdown. The local push is
/// durable in the joiner's in-memory replica only — once we exit the replica
/// is gone, so we hold the node open until either `SyncFinished` confirms a
/// peer pulled the entry or `wait_secs` elapses (best-effort delivery).
async fn run_send(
    ticket: String,
    card_file: String,
    name: String,
    relay: Option<String>,
    wait_secs: u64,
) -> Result<()> {
    let raw = read_card_input(&card_file).await?;
    let input: CardInput = serde_json::from_slice(&raw).context("parse card JSON")?;
    let card = input.into_card(&name);

    let ticket = ticket.parse().context("parse ticket")?;
    let endpoint = build_endpoint(RelayChoice::from_url_opt(relay.as_deref())?).await?;
    let inbox = Inbox::join(endpoint, ticket, name).await?;
    let events = inbox.subscribe().await?;

    inbox.push(&card).await.context("push card")?;
    eprintln!("pushed [{}] {}", card.id, card.summary);

    wait_for_sync(events, Duration::from_secs(wait_secs)).await;

    inbox.shutdown().await?;
    Ok(())
}

/// Read the card JSON from `path`, or stdin when `path == "-"`.
async fn read_card_input(path: &str) -> Result<Vec<u8>> {
    if path == "-" {
        let mut buf = Vec::new();
        tokio::io::stdin()
            .read_to_end(&mut buf)
            .await
            .context("read card from stdin")?;
        Ok(buf)
    } else {
        let path = PathBuf::from(path);
        if !path.exists() {
            bail!("card file not found: {}", path.display());
        }
        tokio::fs::read(&path)
            .await
            .with_context(|| format!("read card file {}", path.display()))
    }
}

/// Webhook bridge: join the inbox once, then run an axum server forever.
/// `Ctrl+C` triggers a graceful shutdown that closes the iroh endpoint
/// cleanly (preventing the "Endpoint dropped without calling close" warning).
async fn run_serve(
    ticket: String,
    bind: String,
    name: String,
    relay: Option<String>,
    token: Option<String>,
    token_file: Option<String>,
) -> Result<()> {
    let token = resolve_token(token, token_file).await?;
    if token.is_none() {
        eprintln!(
            "WARNING: --token/--token-file not set; the server is OPEN. \
             Anyone reaching the bind address can push cards into the inbox."
        );
    }

    let ticket = ticket.parse().context("parse ticket")?;
    let endpoint = build_endpoint(RelayChoice::from_url_opt(relay.as_deref())?).await?;
    let inbox = Arc::new(Inbox::join(endpoint, ticket, name.clone()).await?);
    eprintln!("joined inbox {}", inbox.doc_id());

    let state = ServerState {
        inbox: inbox.clone(),
        default_source: Arc::new(name),
        token: token.map(Arc::new),
    };

    let app = build_router(state.clone());

    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("bind {bind}"))?;
    eprintln!("listening on http://{}", listener.local_addr()?);

    let server = axum::serve(listener, app).with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
        eprintln!("shutting down…");
    });
    server.await.context("axum serve")?;

    // Clean shutdown so the iroh endpoint closes its sockets / relay actor.
    if let Ok(inbox) = Arc::try_unwrap(inbox) {
        inbox.shutdown().await?;
    }
    Ok(())
}

/// Resolve the configured token, reading from disk if `--token-file` was used.
/// Trims trailing whitespace so a `printf foo > token` style file works.
async fn resolve_token(
    inline: Option<String>,
    from_file: Option<String>,
) -> Result<Option<String>> {
    match (inline, from_file) {
        (Some(t), None) => Ok(Some(t)),
        (None, Some(path)) => {
            let raw = tokio::fs::read_to_string(&path)
                .await
                .with_context(|| format!("read --token-file {path}"))?;
            let trimmed = raw.trim().to_string();
            if trimmed.is_empty() {
                bail!("--token-file {path} is empty");
            }
            Ok(Some(trimmed))
        }
        (None, None) => Ok(None),
        (Some(_), Some(_)) => {
            // clap's `conflicts_with` should already reject this, but be defensive.
            bail!("--token and --token-file are mutually exclusive")
        }
    }
}

/// Wire the public (`/healthz`) and auth-required (`/push`, `/github/pr`)
/// routes. Extracted from `run_serve` so it can be exercised in unit tests
/// via `tower::ServiceExt::oneshot`.
fn build_router(state: ServerState) -> Router {
    let public = Router::new()
        .route("/healthz", http_get(healthz))
        .with_state(state.clone());
    let authed = Router::new()
        .route("/push", post(push_handler))
        .route("/github/pr", post(github_pr_handler))
        .layer(from_fn_with_state(state.clone(), auth_middleware))
        .with_state(state);
    public.merge(authed)
}

/// State shared into every axum handler.
#[derive(Clone)]
struct ServerState {
    inbox: Arc<Inbox>,
    /// Fallback `source` for cards whose JSON omits it; matches `ama send`'s
    /// `--name` semantics so the two surfaces behave consistently.
    default_source: Arc<String>,
    /// Bearer token required on auth-protected routes. `None` means the server
    /// was started without `--token` and the middleware lets everything through.
    token: Option<Arc<String>>,
}

/// Bearer-token guard for POST routes. With no configured token the middleware
/// is effectively a no-op (so the M5 P2 open-server behaviour is preserved
/// when nobody opted in); with a token, the request must carry
/// `Authorization: Bearer <token>` (exact match) or it's rejected as 401.
async fn auth_middleware(
    State(state): State<ServerState>,
    headers: HeaderMap,
    req: axum::extract::Request,
    next: Next,
) -> Result<axum::response::Response, ApiError> {
    let Some(expected) = state.token.as_deref() else {
        return Ok(next.run(req).await);
    };
    let provided = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim);
    match provided {
        Some(t) if t == expected.as_str() => Ok(next.run(req).await),
        _ => Err(ApiError::unauthorized()),
    }
}

/// `GET /healthz` — cheap liveness probe (no inbox call).
async fn healthz() -> &'static str {
    "ok"
}

/// `POST /push` — body is the same JSON shape as `ama send --card-file`. On
/// success returns `200 { "id": "<uuid>" }`; on a malformed body, `400`.
async fn push_handler(
    State(state): State<ServerState>,
    Json(input): Json<CardInput>,
) -> Result<Json<PushResponse>, ApiError> {
    let card = input.into_card(&state.default_source);
    state
        .inbox
        .push(&card)
        .await
        .map_err(|e| ApiError::internal(format!("push: {e:#}")))?;
    eprintln!("/push -> [{}] {}", card.id, card.summary);
    Ok(Json(PushResponse { id: card.id }))
}

#[derive(serde::Serialize)]
struct PushResponse {
    id: String,
}

/// Minimal subset of GitHub's `pull_request` webhook payload — only the
/// fields the adapter actually reads. GitHub sends a lot more; serde's
/// default `deny_unknown_fields = false` lets us ignore the rest.
#[derive(Debug, Deserialize, PartialEq)]
struct GithubPrPayload {
    action: String,
    pull_request: GithubPr,
    repository: GithubRepo,
}

#[derive(Debug, Deserialize, PartialEq)]
struct GithubPr {
    number: u64,
    title: String,
    #[serde(default)]
    body: Option<String>,
    html_url: String,
    user: GithubUser,
}

#[derive(Debug, Deserialize, PartialEq)]
struct GithubUser {
    login: String,
}

#[derive(Debug, Deserialize, PartialEq)]
struct GithubRepo {
    full_name: String,
}

/// `POST /github/pr` — accepts a GitHub `pull_request` webhook payload and
/// (for `opened` / `reopened` / `ready_for_review` actions) turns it into an
/// A2UI card with the PR title, body excerpt, and a single "Open PR" link.
/// Other actions are quietly ignored so GitHub's at-least-once delivery
/// doesn't spam the inbox with noise events.
async fn github_pr_handler(
    State(state): State<ServerState>,
    Json(payload): Json<GithubPrPayload>,
) -> Result<Json<GithubPrResponse>, ApiError> {
    if !matches!(payload.action.as_str(), "opened" | "reopened" | "ready_for_review") {
        return Ok(Json(GithubPrResponse { id: None, ignored: true }));
    }
    let card = github_pr_to_card(&payload, &state.default_source);
    state
        .inbox
        .push(&card)
        .await
        .map_err(|e| ApiError::internal(format!("push: {e:#}")))?;
    eprintln!("/github/pr -> [{}] {}", card.id, card.summary);
    Ok(Json(GithubPrResponse { id: Some(card.id), ignored: false }))
}

#[derive(serde::Serialize)]
struct GithubPrResponse {
    /// Card id if the payload was actioned, `None` if ignored.
    id: Option<String>,
    /// `true` when the action was not in the actioned set (e.g. `closed`).
    ignored: bool,
}

/// Pure transform: GitHub PR payload → A2UI card. Pure so it can be
/// unit-tested without spinning up the network stack.
fn github_pr_to_card(p: &GithubPrPayload, default_source: &str) -> MessageCard {
    let summary = format!(
        "[{}#{}] {} (by @{})",
        p.repository.full_name, p.pull_request.number, p.pull_request.title, p.pull_request.user.login
    );
    let body_excerpt = p
        .pull_request
        .body
        .as_deref()
        .unwrap_or("(no description)")
        .chars()
        .take(280)
        .collect::<String>();
    let a2ui = serde_json::json!({
        "root": {
            "Card": {
                "id": "root",
                "children": [
                    { "Text": { "id": "title", "text": summary.clone() } },
                    { "Text": { "id": "body", "text": body_excerpt } },
                    { "Button": {
                        "id": "open",
                        "label": "Open PR",
                        "action": {
                            "name": "open_url",
                            "context": { "url": p.pull_request.html_url.clone() }
                        }
                    } }
                ]
            }
        }
    });
    MessageCard {
        id: uuid::Uuid::new_v4().to_string(),
        a2ui,
        summary,
        source: format!("{default_source}/github"),
        created_at: now_ms(),
    }
}

/// Tiny error wrapper: maps anyhow-style errors to HTTP responses without
/// dragging in a full error crate.
struct ApiError {
    status: StatusCode,
    body: String,
}

impl ApiError {
    fn internal(msg: String) -> Self {
        Self { status: StatusCode::INTERNAL_SERVER_ERROR, body: msg }
    }
    fn unauthorized() -> Self {
        Self { status: StatusCode::UNAUTHORIZED, body: "unauthorized".into() }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (self.status, self.body).into_response()
    }
}

/// Hold the node open until gossip confirms a peer received our push, or
/// `budget` elapses — whichever comes first. Best-effort: if no peer is online
/// during the window the entry is lost when we exit.
async fn wait_for_sync(
    events: impl futures_lite::Stream<Item = Result<LiveEvent>> + Unpin,
    budget: Duration,
) {
    let mut events = events;
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                eprintln!("wait timeout after {budget:?} — entry may not have synced");
                break;
            }
            ev = events.next() => {
                match ev {
                    Some(Ok(LiveEvent::SyncFinished(_))) => {
                        eprintln!("sync finished — entry delivered");
                        break;
                    }
                    Some(Ok(_)) => continue,
                    Some(Err(err)) => {
                        eprintln!("event stream error: {err:#}");
                        break;
                    }
                    None => break,
                }
            }
        }
    }
}

/// Wait (bounded) until the inbox's endpoint has registered with a relay,
/// so the next `Inbox::ticket()` carries a reachable relay URL. Mirrors the
/// `wait_relay` helper in `crates/core/tests/sync.rs`.
async fn wait_relay(inbox: &Inbox) -> Result<()> {
    let ep = inbox.endpoint().clone();
    // `online().await` proactively probes relay/discovery; without this the
    // background relay actor still drives the assignment but slower.
    tokio::spawn(async move { ep.online().await });
    for _ in 0..600 {
        if inbox.endpoint().addr().relay_urls().next().is_some() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    bail!("inbox never obtained a relay url within 60s — check network / relay config");
}

/// Pretty-print a ticket as both copyable text and a scannable QR code.
fn print_ticket(ticket: &str) {
    println!("\n── pairing ticket ─────────────────────────────────");
    println!("{ticket}");
    if let Ok(code) = QrCode::new(ticket.as_bytes()) {
        let qr = code
            .render::<unicode::Dense1x2>()
            .dark_color(unicode::Dense1x2::Light)
            .light_color(unicode::Dense1x2::Dark)
            .quiet_zone(true)
            .build();
        println!("\n{qr}");
    }
    println!("───────────────────────────────────────────────────");
    println!("On the other device:  ama join --name <label> <TICKET>\n");
}

/// Print remote document activity as it arrives.
async fn watch(inbox: Arc<Inbox>, mut events: impl futures_lite::Stream<Item = Result<LiveEvent>> + Unpin) {
    while let Some(event) = events.next().await {
        let event = match event {
            Ok(e) => e,
            Err(err) => {
                eprintln!("watch error: {err:#}");
                continue;
            }
        };
        match event {
            LiveEvent::NeighborUp(peer) => println!("\n🔗 peer connected: {peer}"),
            LiveEvent::NeighborDown(peer) => println!("\n💤 peer disconnected: {peer}"),
            LiveEvent::InsertRemote { entry, .. } => {
                let key = String::from_utf8_lossy(entry.key()).to_string();
                report_remote(&inbox, &key).await;
            }
            LiveEvent::ContentReady { .. }
            | LiveEvent::PendingContentReady
            | LiveEvent::SyncFinished(_)
            | LiveEvent::InsertLocal { .. } => {}
        }
        print_prompt();
    }
}

/// Describe a remote-inserted entry by reading back the converged value.
async fn report_remote(inbox: &Inbox, key: &str) {
    if let Some(id) = key.strip_prefix("msg/") {
        match inbox.get_message(id).await {
            Ok(Some(card)) => println!("\n📨 new card [{}] {}", card.id, card.summary),
            // Content for the entry may still be downloading.
            _ => println!("\n📨 incoming card {id} (syncing… run `list`)"),
        }
    } else if let Some(id) = key.strip_prefix("state/") {
        match inbox.get_state(id).await {
            Ok(Some(state)) => println!("\n🔄 {id} → {:?}", state.status),
            _ => println!("\n🔄 state update for {id}"),
        }
    } else if let Some(rest) = key.strip_prefix("data/") {
        println!("\n✏️  data update: {rest}");
    }
}

/// Interactive command loop reading from stdin.
async fn repl(inbox: Arc<Inbox>) -> Result<()> {
    print_help();
    print_prompt();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let line = line.trim();
        if line.is_empty() {
            print_prompt();
            continue;
        }
        let (cmd, rest) = match line.split_once(' ') {
            Some((c, r)) => (c, r.trim()),
            None => (line, ""),
        };
        match cmd {
            "send" => send_card(&inbox, rest).await?,
            "list" => list(&inbox).await?,
            "get" => get(&inbox, rest).await?,
            "dismiss" => dismiss(&inbox, rest).await?,
            "data" => set_data(&inbox, rest).await?,
            "ticket" => println!("{}", inbox.ticket().await?),
            "help" => print_help(),
            "quit" | "exit" => break,
            other => println!("unknown command '{other}' (try `help`)"),
        }
        print_prompt();
    }
    Ok(())
}

async fn send_card(inbox: &Inbox, text: &str) -> Result<()> {
    if text.is_empty() {
        println!("usage: send <summary text>");
        return Ok(());
    }
    let card = MessageCard {
        id: uuid::Uuid::new_v4().to_string(),
        a2ui: serde_json::json!({}),
        summary: text.to_string(),
        source: "cli".to_string(),
        created_at: now_ms(),
    };
    inbox.push(&card).await?;
    println!("sent [{}]", card.id);
    Ok(())
}

async fn list(inbox: &Inbox) -> Result<()> {
    let cards = inbox.list_messages().await?;
    if cards.is_empty() {
        println!("(no cards)");
        return Ok(());
    }
    for card in cards {
        let status = match inbox.get_state(&card.id).await? {
            Some(state) => format!("{:?}", state.status),
            None => format!("{:?}", Status::Unread),
        };
        println!("[{}] {:<10} {}", card.id, status, card.summary);
    }
    Ok(())
}

async fn get(inbox: &Inbox, id: &str) -> Result<()> {
    if id.is_empty() {
        println!("usage: get <id>");
        return Ok(());
    }
    match inbox.get_message(id).await? {
        Some(card) => {
            println!("id:      {}", card.id);
            println!("summary: {}", card.summary);
            println!("source:  {}", card.source);
            println!("a2ui:    {}", card.a2ui);
            match inbox.get_state(id).await? {
                Some(state) => println!("state:   {state:?}"),
                None => println!("state:   {:?} (default)", Status::Unread),
            }
        }
        None => println!("no card {id}"),
    }
    Ok(())
}

async fn dismiss(inbox: &Inbox, id: &str) -> Result<()> {
    if id.is_empty() {
        println!("usage: dismiss <id>");
        return Ok(());
    }
    inbox.dismiss(id).await?;
    println!("dismissed {id}");
    Ok(())
}

async fn set_data(inbox: &Inbox, rest: &str) -> Result<()> {
    // data <id> <bindPath> <json-value>
    let mut parts = rest.splitn(3, ' ');
    let (Some(id), Some(path), Some(raw)) = (parts.next(), parts.next(), parts.next()) else {
        println!("usage: data <id> <bindPath> <json-value>   e.g. data abc /email \"\\\"a@b.c\\\"\"");
        return Ok(());
    };
    let value: serde_json::Value =
        serde_json::from_str(raw).unwrap_or_else(|_| serde_json::Value::String(raw.to_string()));
    inbox.set_data(id, path, &value).await?;
    println!("set data {id}{path} = {value}");
    Ok(())
}

fn print_help() {
    println!(
        "commands:\n  \
         send <text>              push a new card\n  \
         list                     list cards + state\n  \
         get <id>                 show one card\n  \
         dismiss <id>             dismiss a card (syncs to peers)\n  \
         data <id> <path> <val>   set an A2UI data-model field\n  \
         ticket                   print the pairing ticket\n  \
         help | quit"
    );
}

fn print_prompt() {
    use std::io::Write;
    print!("> ");
    let _ = std::io::stdout().flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn card_input_full_shape_round_trips() {
        let raw = r#"{
          "summary": "PR #42 opened",
          "a2ui": { "kind": "Text", "text": "hi" },
          "source": "github"
        }"#;
        let parsed: CardInput = serde_json::from_str(raw).unwrap();
        assert_eq!(parsed.summary, "PR #42 opened");
        assert_eq!(parsed.source.as_deref(), Some("github"));
        assert_eq!(
            parsed.a2ui,
            Some(serde_json::json!({ "kind": "Text", "text": "hi" }))
        );
    }

    #[test]
    fn card_input_defaults_a2ui_and_source() {
        let parsed: CardInput = serde_json::from_str(r#"{"summary": "ping"}"#).unwrap();
        let card = parsed.into_card("script");
        assert_eq!(card.summary, "ping");
        // a2ui absent in input → defaults to {} so renderers always see an object.
        assert_eq!(card.a2ui, serde_json::json!({}));
        // source absent → falls back to the CLI's default_source.
        assert_eq!(card.source, "script");
        // id is a fresh UUID and created_at is set.
        assert!(!card.id.is_empty());
        assert!(card.created_at > 0);
    }

    #[test]
    fn card_input_keeps_explicit_source_over_default() {
        let parsed: CardInput =
            serde_json::from_str(r#"{"summary": "x", "source": "webhook"}"#).unwrap();
        let card = parsed.into_card("cli-fallback");
        assert_eq!(card.source, "webhook");
    }

    #[test]
    fn card_input_rejects_missing_summary() {
        let err = serde_json::from_str::<CardInput>(r#"{"a2ui": {}}"#).unwrap_err();
        assert!(
            err.to_string().contains("summary"),
            "expected error to mention missing field: {err}"
        );
    }

    // ---- GitHub adapter ---------------------------------------------------

    fn sample_github_payload(action: &str) -> GithubPrPayload {
        GithubPrPayload {
            action: action.into(),
            pull_request: GithubPr {
                number: 42,
                title: "Add foo".into(),
                body: Some("Adds foo because bar.".into()),
                html_url: "https://github.com/acme/widget/pull/42".into(),
                user: GithubUser { login: "octocat".into() },
            },
            repository: GithubRepo { full_name: "acme/widget".into() },
        }
    }

    #[test]
    fn github_pr_to_card_summary_includes_repo_number_title_user() {
        let card = github_pr_to_card(&sample_github_payload("opened"), "webhook");
        assert_eq!(card.summary, "[acme/widget#42] Add foo (by @octocat)");
        assert_eq!(card.source, "webhook/github");
    }

    #[test]
    fn github_pr_to_card_a2ui_carries_open_pr_button() {
        let card = github_pr_to_card(&sample_github_payload("opened"), "webhook");
        // The Button child's action.context.url is what the renderer dispatches.
        let url = card.a2ui["root"]["Card"]["children"][2]["Button"]["action"]["context"]["url"]
            .as_str()
            .expect("Button.action.context.url present");
        assert_eq!(url, "https://github.com/acme/widget/pull/42");
    }

    #[test]
    fn github_pr_to_card_falls_back_when_body_missing() {
        let mut p = sample_github_payload("opened");
        p.pull_request.body = None;
        let card = github_pr_to_card(&p, "webhook");
        let body = card.a2ui["root"]["Card"]["children"][1]["Text"]["text"]
            .as_str()
            .unwrap();
        assert_eq!(body, "(no description)");
    }

    #[test]
    fn github_pr_payload_ignores_unknown_fields() {
        // GitHub sends a giant payload; serde must not choke on the extras.
        let raw = r#"{
          "action": "opened",
          "number": 99,
          "extra_top_level_field": "ignore me",
          "pull_request": {
            "id": 1234567890,
            "number": 42,
            "title": "t",
            "body": "b",
            "html_url": "https://x/y/pull/42",
            "user": { "login": "u", "id": 1 },
            "merged": false
          },
          "repository": { "id": 99, "full_name": "x/y" },
          "sender": { "login": "z" }
        }"#;
        let parsed: GithubPrPayload = serde_json::from_str(raw).unwrap();
        assert_eq!(parsed.action, "opened");
        assert_eq!(parsed.pull_request.number, 42);
    }

    // ---- Token resolution -------------------------------------------------

    #[tokio::test]
    async fn resolve_token_inline_wins() {
        let t = resolve_token(Some("abc".into()), None).await.unwrap();
        assert_eq!(t.as_deref(), Some("abc"));
    }

    #[tokio::test]
    async fn resolve_token_from_file_trims_trailing_whitespace() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("ama-token-{}", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, "secret-token\n").await.unwrap();
        let t = resolve_token(None, Some(path.to_string_lossy().into_owned()))
            .await
            .unwrap();
        assert_eq!(t.as_deref(), Some("secret-token"));
        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test]
    async fn resolve_token_none_is_open_server() {
        let t = resolve_token(None, None).await.unwrap();
        assert!(t.is_none());
    }

    #[tokio::test]
    async fn resolve_token_empty_file_errors() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("ama-empty-{}", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, "   \n  \n").await.unwrap();
        let err = resolve_token(None, Some(path.to_string_lossy().into_owned()))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("empty"), "unexpected error: {err}");
        let _ = tokio::fs::remove_file(&path).await;
    }
}
