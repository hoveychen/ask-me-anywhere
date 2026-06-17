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

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use ama_core::{
    build_endpoint, load_or_create_secret_key, now_ms, parse_key, Endpoint, Inbox, KeyKind,
    LiveEvent, MessageCard, MessageState, RelayChoice, Status,
};
use axum::{
    extract::{Query, State},
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    middleware::{from_fn_with_state, Next},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
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
    /// Create a fresh inbox and print a pairing ticket for other devices. With
    /// `--data-dir`, the inbox and node identity persist there: rerunning
    /// `create` with the same dir reopens the existing inbox (same ticket)
    /// instead of starting over.
    Create {
        /// Human-readable device label (stamped into state writes).
        #[arg(long, default_value = "device")]
        name: String,
        /// Relay to use. Omit for the project default (relay.muveeai.com);
        /// pass a URL for another self-hosted relay, `n0` for n0's public pool,
        /// or `disabled` for direct/LAN-only.
        #[arg(long)]
        relay: Option<String>,
        /// Persist the inbox store + node identity here. Omit for an ephemeral
        /// in-memory node (the previous default).
        #[arg(long = "data-dir")]
        data_dir: Option<PathBuf>,
    },
    /// Join an existing inbox using a ticket from `create`.
    Join {
        /// The pairing ticket emitted by `ama create`.
        ticket: String,
        #[arg(long, default_value = "device")]
        name: String,
        /// Relay to use. Omit for the project default (relay.muveeai.com); pass a
        /// URL for another relay, `n0` for n0 public, or `disabled` for direct-only.
        #[arg(long)]
        relay: Option<String>,
        /// Persist the joined inbox + node identity here so the join survives a
        /// restart. Omit for an ephemeral in-memory node.
        #[arg(long = "data-dir")]
        data_dir: Option<PathBuf>,
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
        /// Relay to use. Omit for the project default (relay.muveeai.com); pass a
        /// URL for another relay, `n0` for n0 public, or `disabled` for direct-only.
        #[arg(long)]
        relay: Option<String>,
        /// Maximum seconds to hold the node open after the local push, giving
        /// gossip a chance to deliver the entry to at least one peer. The CLI
        /// exits sooner once it sees a `SyncFinished` event.
        #[arg(long, default_value_t = 5)]
        wait_secs: u64,
        /// Persist this sender's node identity here so it keeps a stable
        /// node-id across runs. Omit for an ephemeral identity.
        #[arg(long = "data-dir")]
        data_dir: Option<PathBuf>,
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
        /// Relay to use. Omit for the project default (relay.muveeai.com); pass a
        /// URL for another relay, `n0` for n0 public, or `disabled` for direct-only.
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
        /// Persist the joined inbox + node identity here so a restart of the
        /// bridge keeps the same node-id. Omit for an ephemeral node.
        #[arg(long = "data-dir", env = "AMA_DATA_DIR")]
        data_dir: Option<PathBuf>,
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

/// Build a node endpoint for a CLI command. With `data_dir` the node adopts a
/// persistent identity (key under `<data_dir>/node-key`) so its node-id and
/// ticket survive restarts; without it the identity is ephemeral.
async fn cli_endpoint(relay: RelayChoice, data_dir: Option<&Path>) -> Result<Endpoint> {
    match data_dir {
        Some(dir) => {
            let key = load_or_create_secret_key(&dir.join("node-key"))?;
            build_endpoint(relay, Some(key)).await
        }
        None => build_endpoint(relay, None).await,
    }
}

/// `ama create`: open the inbox already persisted at `data_dir`, else create a
/// new one (recording its namespace so a later run reopens it). Without
/// `data_dir` it's always a fresh ephemeral inbox. Binds exactly one endpoint —
/// the persisted-or-not decision is made before binding via [`Inbox::is_persisted`].
async fn create_inbox(name: &str, relay: RelayChoice, data_dir: Option<&Path>) -> Result<Inbox> {
    let endpoint = cli_endpoint(relay, data_dir).await?;
    match data_dir {
        Some(dir) if Inbox::is_persisted(dir)? => Inbox::open(endpoint, name, dir)
            .await?
            .context("inbox namespace recorded at data dir but its replica is missing"),
        other => Inbox::create(endpoint, name, other).await,
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
        Command::Create { name, relay, data_dir } => {
            let relay = RelayChoice::from_url_opt(relay.as_deref())?;
            let inbox = create_inbox(&name, relay, data_dir.as_deref()).await?;
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
        Command::Join { ticket, name, relay, data_dir } => {
            let ticket = ticket.parse().context("parse ticket")?;
            let endpoint =
                cli_endpoint(RelayChoice::from_url_opt(relay.as_deref())?, data_dir.as_deref())
                    .await?;
            let inbox = Inbox::join(endpoint, ticket, name, data_dir.as_deref()).await?;
            println!("joined inbox {}", inbox.doc_id());
            Arc::new(inbox)
        }
        Command::Send { ticket, card_file, name, relay, wait_secs, data_dir } => {
            return run_send(ticket, card_file, name, relay, wait_secs, data_dir).await;
        }
        Command::Serve { ticket, bind, name, relay, token, token_file, data_dir } => {
            return run_serve(ticket, bind, name, relay, token, token_file, data_dir).await;
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
    data_dir: Option<PathBuf>,
) -> Result<()> {
    let raw = read_card_input(&card_file).await?;
    let input: CardInput = serde_json::from_slice(&raw).context("parse card JSON")?;
    let card = input.into_card(&name);

    let ticket = ticket.parse().context("parse ticket")?;
    let endpoint =
        cli_endpoint(RelayChoice::from_url_opt(relay.as_deref())?, data_dir.as_deref()).await?;
    let inbox = Inbox::join(endpoint, ticket, name, data_dir.as_deref()).await?;
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
    data_dir: Option<PathBuf>,
) -> Result<()> {
    let token = resolve_token(token, token_file).await?;
    if token.is_none() {
        eprintln!(
            "WARNING: --token/--token-file not set; the server is OPEN. \
             Anyone reaching the bind address can push cards into the inbox."
        );
    }

    let ticket = ticket.parse().context("parse ticket")?;
    let endpoint =
        cli_endpoint(RelayChoice::from_url_opt(relay.as_deref())?, data_dir.as_deref()).await?;
    let inbox = Arc::new(Inbox::join(endpoint, ticket, name.clone(), data_dir.as_deref()).await?);
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
        // Answer-back read endpoints (M6 P1). `{*path}` is axum's wildcard
        // capture, so /cards/abc/data/contact/email lands with path="contact/email".
        .route("/cards/{id}", http_get(get_card_handler))
        .route("/cards/{id}/state", http_get(get_state_handler))
        .route("/cards/{id}/data/{*path}", http_get(get_data_handler))
        // SSE stream for live state/data updates (M6 P2). Filters by card_id.
        .route("/events", http_get(events_handler))
        // Blocking ask: push + wait for state change in one HTTP call (M6 P3).
        .route("/ask", post(ask_handler))
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

// ---- answer-back read endpoints (M6 P1) -----------------------------------

/// `GET /cards/{id}` — full snapshot of a card: the immutable payload plus
/// the current state and every bound data-model value. 404 if the card id
/// has never been written to (locally or via gossip).
async fn get_card_handler(
    State(state): State<ServerState>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Result<Json<CardSnapshot>, ApiError> {
    let card = state
        .inbox
        .get_message(&id)
        .await
        .map_err(|e| ApiError::internal(format!("get_message: {e:#}")))?
        .ok_or_else(ApiError::not_found)?;
    let card_state = state
        .inbox
        .get_state(&id)
        .await
        .map_err(|e| ApiError::internal(format!("get_state: {e:#}")))?;
    let data = state
        .inbox
        .list_data(&id)
        .await
        .map_err(|e| ApiError::internal(format!("list_data: {e:#}")))?;
    Ok(Json(CardSnapshot { card, state: card_state, data }))
}

#[derive(serde::Serialize)]
struct CardSnapshot {
    card: MessageCard,
    state: Option<MessageState>,
    data: std::collections::HashMap<String, serde_json::Value>,
}

/// `GET /cards/{id}/state` — just the [`MessageState`] (status, action_name,
/// action_context, device, ts). 404 if the card has no state entry yet
/// (i.e. no action has been taken).
async fn get_state_handler(
    State(state): State<ServerState>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Result<Json<MessageState>, ApiError> {
    state
        .inbox
        .get_state(&id)
        .await
        .map_err(|e| ApiError::internal(format!("get_state: {e:#}")))?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

/// `GET /cards/{id}/data/{*path}` — single bound value (e.g. `/cards/abc/data/note`
/// returns the value at bind_path `/note`). 404 if that bind_path was never
/// written. axum's `{*path}` strips the leading slash; we add it back to
/// match the [`crate::ama_core::data_key`] convention.
async fn get_data_handler(
    State(state): State<ServerState>,
    axum::extract::Path((id, path)): axum::extract::Path<(String, String)>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let bind_path = format!("/{path}");
    state
        .inbox
        .get_data(&id, &bind_path)
        .await
        .map_err(|e| ApiError::internal(format!("get_data: {e:#}")))?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

/// Body of `POST /ask`. Extends [`CardInput`] with an optional timeout for
/// the blocking wait; on timeout the response is `200 { timed_out: true,
/// id }` so the client can `GET /cards/{id}` later.
#[derive(Debug, Deserialize)]
struct AskInput {
    summary: String,
    #[serde(default)]
    a2ui: Option<serde_json::Value>,
    #[serde(default)]
    source: Option<String>,
    /// Max seconds to wait for the card to be actioned or dismissed.
    /// Defaults to 60. Cap is enforced at 600 (Cloudflare / Traefik typically
    /// kill idle HTTP connections around 100s, but local / direct setups can
    /// hold longer).
    #[serde(default = "default_ask_timeout")]
    timeout_secs: u64,
}

fn default_ask_timeout() -> u64 {
    60
}

impl AskInput {
    fn into_card_input(self) -> CardInput {
        CardInput {
            summary: self.summary,
            a2ui: self.a2ui,
            source: self.source,
        }
    }
}

#[derive(serde::Serialize)]
struct AskResponse {
    id: String,
    /// True when no action came in within `timeout_secs`. The card is still
    /// durable in the webhook's replica; the client can poll
    /// `GET /cards/{id}` later to pick the answer up when it arrives.
    timed_out: bool,
    /// Final MessageState (status + action_name + action_context + ts).
    /// Present iff `timed_out == false`.
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<MessageState>,
    /// Bound data-model values at the moment the card reached its final
    /// state. Empty when timed out.
    #[serde(default)]
    data: std::collections::HashMap<String, serde_json::Value>,
}

/// `POST /ask` — push a card AND wait for the user to action or dismiss it,
/// returning the resolved state in one HTTP call. Closest to the
/// "ask, get answer" semantic the project name implies.
///
/// Timing: the subscription is established BEFORE the push, so the
/// InsertLocal event for the eventual state write is guaranteed not to be
/// lost in the gap.
async fn ask_handler(
    State(state): State<ServerState>,
    Json(input): Json<AskInput>,
) -> Result<Json<AskResponse>, ApiError> {
    let timeout_secs = input.timeout_secs.min(600);
    let card = input.into_card_input().into_card(&state.default_source);
    let id = card.id.clone();

    let events = state
        .inbox
        .subscribe()
        .await
        .map_err(|e| ApiError::internal(format!("subscribe: {e:#}")))?;

    state
        .inbox
        .push(&card)
        .await
        .map_err(|e| ApiError::internal(format!("push: {e:#}")))?;
    eprintln!("/ask -> [{}] {}  (waiting up to {timeout_secs}s)", card.id, card.summary);

    let final_state = wait_for_final_state(events, &state.inbox, &id, Duration::from_secs(timeout_secs)).await;
    let resp = match final_state {
        Some(s) => {
            let data = state
                .inbox
                .list_data(&id)
                .await
                .unwrap_or_default();
            AskResponse { id, timed_out: false, state: Some(s), data }
        }
        None => AskResponse {
            id,
            timed_out: true,
            state: None,
            data: Default::default(),
        },
    };
    Ok(Json(resp))
}

/// Pull events until we see a `state/<id>` write whose status is no longer
/// `Unread`, or `budget` elapses. Returns the resolved [`MessageState`] on
/// the success path, `None` on timeout.
async fn wait_for_final_state(
    events: impl futures_lite::Stream<Item = Result<LiveEvent>> + Unpin,
    inbox: &Inbox,
    target_id: &str,
    budget: Duration,
) -> Option<MessageState> {
    let mut events = events;
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let next = tokio::select! {
            _ = tokio::time::sleep_until(deadline) => return None,
            ev = events.next() => ev,
        };
        let entry = match next {
            Some(Ok(LiveEvent::InsertLocal { entry })) => entry,
            Some(Ok(LiveEvent::InsertRemote { entry, .. })) => entry,
            Some(Ok(_)) => continue,
            Some(Err(_)) => continue,
            None => return None,
        };
        let key = String::from_utf8_lossy(entry.key()).to_string();
        let Some(KeyKind::State { id }) = parse_key(&key) else { continue };
        if id != target_id {
            continue;
        }
        let Ok(Some(state)) = inbox.get_state(&id).await else { continue };
        if !matches!(state.status, Status::Unread) {
            return Some(state);
        }
    }
}

#[derive(Deserialize)]
struct EventsQuery {
    /// Filter to events touching this card id. Required — without it the
    /// stream would broadcast every state/data write on the inbox, which is
    /// rarely what the integrator wants and leaks unrelated cards.
    card_id: String,
}

/// Build a `data` SSE event for a bind_path/value pair.
fn data_event(bind_path: &str, value: &serde_json::Value) -> Option<Event> {
    Event::default()
        .event("data")
        .json_data(serde_json::json!({ "bind_path": bind_path, "value": value }))
        .ok()
}

/// `GET /events?card_id=<id>` — SSE stream of `state` and `data` events for
/// a single card. Each event has the resolved value as its JSON payload
/// (the same shape the polling endpoints return), so a client never has to
/// follow up with a separate read.
///
/// On connect the stream first replays a **snapshot**: the card's current
/// state (if any) and every bound data value, as `state` / `data` events —
/// then switches to live deltas. The subscription is taken BEFORE the
/// snapshot read, so an update landing between the two is captured by the
/// live stream as well; since state/data are LWW, the duplicate emit is
/// idempotent. This closes the race the old "GET /cards/{id} then attach
/// SSE" pattern had (an update in the gap was missed entirely).
///
/// SSE event types:
///   - `state` → MessageState JSON
///   - `data`  → `{ "bind_path": "/note", "value": "ok" }`
///
/// A keep-alive comment is sent every 15s so middleboxes (Cloudflare, k8s
/// ingress) don't reap idle long-poll connections. The subscription is
/// dropped automatically when the client disconnects (axum cancels the
/// response future, and the LiveEvent stream is owned by it).
async fn events_handler(
    State(state): State<ServerState>,
    Query(params): Query<EventsQuery>,
) -> Result<Sse<impl futures_lite::Stream<Item = std::result::Result<Event, std::convert::Infallible>>>, ApiError>
{
    let card_id = params.card_id;

    // 1. Subscribe FIRST so nothing written after this point is lost, even
    //    while we read the snapshot below.
    let events = state
        .inbox
        .subscribe()
        .await
        .map_err(|e| ApiError::internal(format!("subscribe: {e:#}")))?;
    let inbox = state.inbox.clone();

    // 2. Read the current snapshot (state + all data) and turn it into the
    //    initial batch of SSE events.
    let mut snapshot: Vec<Event> = Vec::new();
    if let Ok(Some(s)) = inbox.get_state(&card_id).await {
        if let Ok(ev) = Event::default().event("state").json_data(&s) {
            snapshot.push(ev);
        }
    }
    if let Ok(data) = inbox.list_data(&card_id).await {
        for (bind_path, value) in data {
            if let Some(ev) = data_event(&bind_path, &value) {
                snapshot.push(ev);
            }
        }
    }
    let snapshot_stream = futures_lite::stream::iter(snapshot.into_iter().map(Ok));

    // 3. Live deltas after the snapshot.
    let live_stream = futures_lite::stream::unfold(
        (events, inbox, card_id),
        |(mut events, inbox, card_id)| async move {
            loop {
                let ev = events.next().await?;
                let entry = match ev {
                    Ok(LiveEvent::InsertRemote { entry, .. })
                    | Ok(LiveEvent::InsertLocal { entry }) => entry,
                    Ok(_) => continue,
                    Err(_) => continue,
                };
                let key = String::from_utf8_lossy(entry.key()).to_string();
                let Some(kind) = parse_key(&key) else { continue };
                let sse_event = match kind {
                    KeyKind::State { id } if id == card_id => match inbox.get_state(&id).await {
                        Ok(Some(state)) => Event::default()
                            .event("state")
                            .json_data(&state)
                            .ok(),
                        _ => None,
                    },
                    KeyKind::Data { id, bind_path } if id == card_id => {
                        match inbox.get_data(&id, &bind_path).await {
                            Ok(Some(value)) => data_event(&bind_path, &value),
                            _ => None,
                        }
                    }
                    _ => None,
                };
                if let Some(ev) = sse_event {
                    return Some((Ok(ev), (events, inbox, card_id)));
                }
            }
        },
    );

    let stream = snapshot_stream.chain(live_stream);
    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
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
    // A2UI v0.9 message array (createSurface → updateComponents). This is the
    // wire form the genui renderer actually accepts; the older {root:{Card}}
    // object shape rendered as a summary-only fallback (no Open PR button).
    let a2ui = serde_json::json!([
        {
            "version": "v0.9",
            "createSurface": {
                "surfaceId": "card",
                "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json"
            }
        },
        {
            "version": "v0.9",
            "updateComponents": {
                "surfaceId": "card",
                "components": [
                    { "id": "root", "component": "Column", "children": ["title", "body", "open"] },
                    { "id": "title", "component": "Text", "text": summary.clone(), "variant": "h4" },
                    { "id": "body", "component": "Text", "text": body_excerpt },
                    {
                        "id": "open",
                        "component": "Button",
                        "variant": "primary",
                        "child": "openText",
                        "action": {
                            "event": {
                                "name": "open_url",
                                "context": { "url": p.pull_request.html_url.clone() }
                            }
                        }
                    },
                    { "id": "openText", "component": "Text", "text": "Open PR" }
                ]
            }
        }
    ]);
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
    fn not_found() -> Self {
        Self { status: StatusCode::NOT_FOUND, body: "not found".into() }
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

/// Wait (bounded) until the inbox's endpoint has a relay URL in its address,
/// so the next `Inbox::ticket()` carries a reachable relay URL.
///
/// Polls `endpoint().addr()` — which resolves through `watch_addr()` /
/// `home_relay()` and returns a freshly-built `EndpointAddr` — until a relay
/// URL appears. The relay connection is driven by the endpoint's background
/// actor on its own after bind; we only wait for it.
///
/// Do NOT use `Endpoint::online()` here, and do NOT spawn it alongside this
/// poll: `online()` iterates the `home_relay_status()` watcher value
/// (`Vec<Option<(RelayUrl, HomeRelayStatus)>>`), which aliases state the relay
/// actor mutates concurrently — dropping that partially-consumed iterator
/// double-frees the heap (SIGABRT / exit 134, flaky, release-only; confirmed
/// via macOS crash report pointing at the `Flatten<…HomeRelayStatus…>` drop).
/// The `addr()` path never touches `HomeRelayStatus`, so it's race-free.
async fn wait_relay(inbox: &Inbox) -> Result<()> {
    for _ in 0..600 {
        if inbox.endpoint().addr().relay_urls().next().is_some() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    bail!("inbox never obtained a relay url within 60s — check network / relay config")
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

    /// `ama create --data-dir X` is restart-friendly: the second run reopens the
    /// same inbox (same namespace) and still sees a card pushed in the first run,
    /// instead of minting a fresh empty inbox. Offline (relay disabled), so it
    /// needs no network. This is the CLI-level proof of the persist-store plan.
    #[tokio::test]
    async fn create_with_data_dir_reopens_same_inbox_across_restart() {
        let dir = std::env::temp_dir()
            .join(format!("ama-cli-persist-{}-{}", std::process::id(), now_ms()));

        // First run: create the persistent inbox and push a card.
        let first = create_inbox("device", RelayChoice::Disabled, Some(&dir))
            .await
            .expect("first create");
        let namespace = first.doc_id();
        let card = MessageCard {
            id: "cli-card-1".into(),
            a2ui: serde_json::json!({}),
            summary: "from first run".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        first.push(&card).await.expect("push");
        first.shutdown().await.expect("shutdown first");

        // Second run on the same dir: must reopen the same inbox, not create anew.
        let second = create_inbox("device", RelayChoice::Disabled, Some(&dir))
            .await
            .expect("second create");
        assert_eq!(
            second.doc_id(),
            namespace,
            "rerunning create on the same data dir must reopen the same inbox"
        );
        assert!(
            second.get_message("cli-card-1").await.unwrap().is_some(),
            "card pushed in the first run must survive into the second"
        );
        second.shutdown().await.expect("shutdown second");
        let _ = std::fs::remove_dir_all(&dir);
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

    // Find the first component of type `kind` in a v0.9 message-array payload.
    fn find_component<'a>(a2ui: &'a serde_json::Value, kind: &str) -> &'a serde_json::Value {
        for msg in a2ui.as_array().expect("a2ui is a message array") {
            if let Some(comps) = msg
                .get("updateComponents")
                .and_then(|u| u.get("components"))
                .and_then(|c| c.as_array())
            {
                for comp in comps {
                    if comp.get("component").and_then(|c| c.as_str()) == Some(kind) {
                        return comp;
                    }
                }
            }
        }
        panic!("no `{kind}` component found in a2ui");
    }

    #[test]
    fn github_pr_to_card_a2ui_is_renderable_v09_with_open_pr_button() {
        let card = github_pr_to_card(&sample_github_payload("opened"), "webhook");
        // Renderable A2UI v0.9: a message array whose first message creates a
        // surface (the {root:{Card}} shape the app can't render is gone).
        let messages = card.a2ui.as_array().expect("a2ui is a message array");
        assert!(messages[0].get("createSurface").is_some());
        // The Button fires action.event with the PR url in its context.
        let button = find_component(&card.a2ui, "Button");
        let url = button["action"]["event"]["context"]["url"]
            .as_str()
            .expect("Button.action.event.context.url present");
        assert_eq!(url, "https://github.com/acme/widget/pull/42");
        assert_eq!(button["action"]["event"]["name"].as_str(), Some("open_url"));
    }

    #[test]
    fn github_pr_to_card_falls_back_when_body_missing() {
        let mut p = sample_github_payload("opened");
        p.pull_request.body = None;
        let card = github_pr_to_card(&p, "webhook");
        let dump = serde_json::to_string(&card.a2ui).unwrap();
        assert!(dump.contains("(no description)"), "fallback body present");
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

    // ---- M6 P1: answer-back read endpoints --------------------------------

    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use iroh::{endpoint::presets, Endpoint, RelayMode};
    use tower::util::ServiceExt;

    /// Spin up a local-only Inbox + a router with no token configured.
    /// `presets::Minimal` + `RelayMode::Disabled` skips n0 relay/discovery
    /// so the test is fully offline and deterministic.
    async fn local_router_state() -> (Router, Arc<Inbox>) {
        let ep = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .expect("bind endpoint");
        let inbox = Arc::new(Inbox::create(ep, "test", None).await.expect("create inbox"));
        let state = ServerState {
            inbox: inbox.clone(),
            default_source: Arc::new("test".into()),
            token: None,
        };
        (build_router(state), inbox)
    }

    async fn get(router: &Router, path: &str) -> (StatusCode, serde_json::Value) {
        let resp = router
            .clone()
            .oneshot(Request::builder().method("GET").uri(path).body(Body::empty()).unwrap())
            .await
            .expect("router oneshot");
        let status = resp.status();
        let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
        let json = if bytes.is_empty() {
            serde_json::Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or_else(|_| {
                serde_json::Value::String(String::from_utf8_lossy(&bytes).into_owned())
            })
        };
        (status, json)
    }

    #[tokio::test]
    async fn get_card_returns_full_snapshot() {
        let (router, inbox) = local_router_state().await;
        let card = MessageCard {
            id: "card-snap".into(),
            a2ui: serde_json::json!({ "kind": "Text" }),
            summary: "snap".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        inbox.push(&card).await.expect("push");
        inbox.record_action("card-snap", "approve", Some(serde_json::json!({"by":"alice"})))
            .await
            .expect("record_action");
        inbox.set_data("card-snap", "/note", &serde_json::json!("ok"))
            .await
            .expect("set_data");

        let (status, body) = get(&router, "/cards/card-snap").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["card"]["id"], "card-snap");
        assert_eq!(body["state"]["action_name"], "approve");
        assert_eq!(body["state"]["action_context"]["by"], "alice");
        assert_eq!(body["data"]["/note"], "ok");
    }

    #[tokio::test]
    async fn get_card_404_when_unknown() {
        let (router, _) = local_router_state().await;
        let (status, _) = get(&router, "/cards/never-pushed").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn get_state_returns_just_state_or_404() {
        let (router, inbox) = local_router_state().await;
        let card = MessageCard {
            id: "card-s".into(),
            a2ui: serde_json::json!({}),
            summary: "s".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        inbox.push(&card).await.expect("push");
        // 404 before any state write — card exists but state/<id> doesn't.
        let (status, _) = get(&router, "/cards/card-s/state").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        // After dismiss, state lands and the route returns it.
        inbox.dismiss("card-s").await.expect("dismiss");
        let (status, body) = get(&router, "/cards/card-s/state").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["status"], "dismissed");
        assert_eq!(body["action_name"], "dismiss");
    }

    #[tokio::test]
    async fn get_data_returns_value_at_bind_path() {
        let (router, inbox) = local_router_state().await;
        inbox.push(&MessageCard {
            id: "card-d".into(),
            a2ui: serde_json::json!({}),
            summary: "d".into(),
            source: "test".into(),
            created_at: now_ms(),
        }).await.unwrap();
        inbox.set_data("card-d", "/score", &serde_json::json!(7)).await.unwrap();
        inbox.set_data("card-d", "/contact/email", &serde_json::json!("a@b.c")).await.unwrap();

        let (status, body) = get(&router, "/cards/card-d/data/score").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, serde_json::json!(7));

        // Nested bind path with multiple segments (axum {*path} wildcard).
        let (status, body) = get(&router, "/cards/card-d/data/contact/email").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, serde_json::json!("a@b.c"));

        // Missing bind path → 404.
        let (status, _) = get(&router, "/cards/card-d/data/nope").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn events_streams_state_and_data_writes_for_one_card() {
        use http_body_util::BodyExt;

        let (router, inbox) = local_router_state().await;
        // Pre-push the card so its id exists. The SSE only emits state / data
        // events; we'll trigger those after the connection is established.
        let card = MessageCard {
            id: "card-stream".into(),
            a2ui: serde_json::json!({}),
            summary: "stream".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        inbox.push(&card).await.expect("push");

        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/events?card_id=card-stream")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .expect("sse oneshot");
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok()),
            Some("text/event-stream")
        );

        // Subscription is now live (the handler awaited subscribe() before
        // returning the response). Trigger writes that should land as events.
        let writer = inbox.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            writer.dismiss("card-stream").await.expect("dismiss");
            tokio::time::sleep(Duration::from_millis(50)).await;
            writer
                .set_data("card-stream", "/note", &serde_json::json!("typed"))
                .await
                .expect("set_data");
        });

        // Pull frames until we've collected both expected SSE events, with
        // a generous per-test timeout so a stall fails loudly instead of
        // hanging CI.
        let mut body = resp.into_body();
        let mut buf = String::new();
        let mut state_seen = false;
        let mut data_seen = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while !(state_seen && data_seen) {
            let frame = tokio::time::timeout_at(deadline, body.frame())
                .await
                .expect("SSE stream stalled")
                .expect("body stream ended early")
                .expect("frame error");
            if let Ok(data) = frame.into_data() {
                buf.push_str(&String::from_utf8_lossy(&data));
            }
            if !state_seen && buf.contains("event: state") && buf.contains("\"action_name\":\"dismiss\"") {
                state_seen = true;
            }
            if !data_seen && buf.contains("event: data") && buf.contains("\"bind_path\":\"/note\"") {
                data_seen = true;
            }
        }
        // Dropping `body` here drops the response future, which cancels the
        // SSE handler's subscription — verifies the cleanup path implicitly.
    }

    #[tokio::test]
    async fn events_replays_snapshot_on_connect() {
        use http_body_util::BodyExt;

        // A card that ALREADY has state + data before anyone attaches SSE.
        let (router, inbox) = local_router_state().await;
        inbox.push(&MessageCard {
            id: "card-snap-sse".into(),
            a2ui: serde_json::json!({}),
            summary: "snap".into(),
            source: "test".into(),
            created_at: now_ms(),
        }).await.unwrap();
        inbox.record_action("card-snap-sse", "approve", Some(serde_json::json!({"by": "bob"})))
            .await
            .unwrap();
        inbox.set_data("card-snap-sse", "/note", &serde_json::json!("prefilled"))
            .await
            .unwrap();

        // Attach SSE AFTER the writes. With the snapshot-prelude the first
        // events must carry the already-present state + data (no live write
        // needed, no separate GET).
        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/events?card_id=card-snap-sse")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let mut body = resp.into_body();
        let mut buf = String::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let frame = tokio::time::timeout_at(deadline, body.frame())
                .await
                .expect("snapshot SSE stalled")
                .expect("body ended early")
                .expect("frame error");
            if let Ok(data) = frame.into_data() {
                buf.push_str(&String::from_utf8_lossy(&data));
            }
            let have_state = buf.contains("event: state") && buf.contains("\"action_name\":\"approve\"");
            let have_data = buf.contains("event: data") && buf.contains("\"bind_path\":\"/note\"") && buf.contains("prefilled");
            if have_state && have_data {
                break;
            }
        }
    }

    #[tokio::test]
    async fn events_ignores_other_card_writes() {
        use http_body_util::BodyExt;

        let (router, inbox) = local_router_state().await;
        let want = MessageCard {
            id: "card-want".into(),
            a2ui: serde_json::json!({}),
            summary: "want".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        let other = MessageCard {
            id: "card-other".into(),
            a2ui: serde_json::json!({}),
            summary: "other".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        inbox.push(&want).await.unwrap();
        inbox.push(&other).await.unwrap();

        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/events?card_id=card-want")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let writer = inbox.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            // Two writes on the OTHER card — these must NOT appear in our stream.
            writer.dismiss("card-other").await.unwrap();
            writer
                .set_data("card-other", "/x", &serde_json::json!("noise"))
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
            // One write on the wanted card — this is the only event we should see.
            writer.dismiss("card-want").await.unwrap();
        });

        let mut body = resp.into_body();
        let mut buf = String::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let frame = tokio::time::timeout_at(deadline, body.frame())
                .await
                .expect("SSE stream stalled")
                .expect("body stream ended early")
                .expect("frame error");
            if let Ok(data) = frame.into_data() {
                buf.push_str(&String::from_utf8_lossy(&data));
            }
            if buf.contains("event: state")
                && buf.contains("\"action_name\":\"dismiss\"")
                && buf.contains("\"msg_id\":\"card-want\"")
            {
                break;
            }
        }
        // The noise events on card-other should be absent. The buffer up to
        // the point we matched card-want's event must not mention card-other.
        assert!(
            !buf.contains("card-other"),
            "card-other leaked into card-want stream:\n{buf}"
        );
    }

    async fn post_json(router: &Router, path: &str, body: serde_json::Value) -> (StatusCode, serde_json::Value) {
        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .expect("router oneshot");
        let status = resp.status();
        let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| serde_json::Value::String(String::from_utf8_lossy(&bytes).into_owned()));
        (status, json)
    }

    #[tokio::test]
    async fn ask_returns_actioned_state_when_user_acts_before_timeout() {
        let (router, inbox) = local_router_state().await;

        // Drive the inbox concurrently: shortly after /ask subscribes + pushes,
        // simulate a device side recording an action on whatever card just landed.
        let acting_inbox = inbox.clone();
        tokio::spawn(async move {
            // Discover the freshly-pushed card id by polling list_messages.
            let id = loop {
                let cards = acting_inbox.list_messages().await.unwrap();
                if let Some(c) = cards.into_iter().next() {
                    break c.id;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            };
            acting_inbox
                .set_data(&id, "/note", &serde_json::json!("looks good"))
                .await
                .unwrap();
            acting_inbox
                .record_action(&id, "approve", Some(serde_json::json!({"by": "test"})))
                .await
                .unwrap();
        });

        let (status, body) = post_json(
            &router,
            "/ask",
            serde_json::json!({
                "summary": "approve?",
                "timeout_secs": 5
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["timed_out"], false);
        assert_eq!(body["state"]["status"], "actioned");
        assert_eq!(body["state"]["action_name"], "approve");
        assert_eq!(body["state"]["action_context"]["by"], "test");
        assert_eq!(body["data"]["/note"], "looks good");
        assert!(body["id"].is_string());
    }

    #[tokio::test]
    async fn ask_times_out_when_no_action_arrives() {
        let (router, _inbox) = local_router_state().await;
        let (status, body) = post_json(
            &router,
            "/ask",
            serde_json::json!({"summary": "no one will answer", "timeout_secs": 1}),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["timed_out"], true);
        assert!(body["id"].is_string());
        // No state field when timed out.
        assert!(body["state"].is_null() || body.get("state").is_none());
    }

    #[tokio::test]
    async fn ask_default_timeout_is_60s_when_field_absent() {
        // Use a body without timeout_secs and verify the field defaults to 60
        // by re-deserializing through AskInput directly (cheap, doesn't sit
        // for 60 seconds).
        let parsed: AskInput =
            serde_json::from_str(r#"{"summary":"x"}"#).unwrap();
        assert_eq!(parsed.timeout_secs, 60);
    }

    #[tokio::test]
    async fn read_endpoints_require_token_when_configured() {
        let ep = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .unwrap();
        let inbox = Arc::new(Inbox::create(ep, "test", None).await.unwrap());
        let state = ServerState {
            inbox: inbox.clone(),
            default_source: Arc::new("test".into()),
            token: Some(Arc::new("s3cr3t".into())),
        };
        let router = build_router(state);

        // No Authorization header → 401.
        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/cards/any")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        // With the right token → 404 (no card pushed yet) but routes through auth.
        let resp = router
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/cards/any")
                    .header(AUTHORIZATION, "Bearer s3cr3t")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
}

/// Deterministic end-to-end proof of the real message-source chain: a GitHub PR
/// webhook POSTed at one node's `ama serve` HTTP surface becomes a card that
/// gossips to a *second*, paired node. Uses an in-process local relay (no n0 /
/// internet), so unlike the live `scripts/connect-source-demo.sh` run it isn't
/// subject to public-discovery timing flakiness.
#[cfg(test)]
mod real_source_e2e {
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::http::Request;
    use iroh::{
        endpoint::presets, tls::CaRootsConfig, Endpoint, RelayMap, RelayMode,
    };
    use std::time::Duration;
    use tower::util::ServiceExt;

    /// An endpoint on the given in-process relay only (no n0 discovery), trusting
    /// the test relay's self-signed cert.
    async fn relay_endpoint(relay_map: RelayMap) -> Endpoint {
        Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Custom(relay_map))
            .ca_roots_config(CaRootsConfig::insecure_skip_verify())
            .bind()
            .await
            .expect("bind relay endpoint")
    }

    /// Wait until the node has a relay URL (its ticket's reachability), bounded.
    async fn wait_relay(inbox: &Inbox) {
        for _ in 0..600 {
            if inbox.endpoint().addr().relay_urls().next().is_some() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("node never obtained a relay url");
    }

    /// Poll the owner for the card by id until it (and its content blob) arrive.
    async fn await_message(inbox: &Inbox, id: &str) -> MessageCard {
        for _ in 0..300 {
            if let Ok(Some(card)) = inbox.get_message(id).await {
                return card;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("card {id} never synced to the owner node");
    }

    #[tokio::test]
    async fn github_pr_webhook_becomes_a_card_that_syncs_to_the_owner() {
        // In-process relay; both nodes use only it.
        let (relay_map, _url, _server) = iroh::test_utils::run_relay_server()
            .await
            .expect("spawn local relay");

        // Owner node A — the "app's inbox".
        let owner = Inbox::create(relay_endpoint(relay_map.clone()).await, "owner", None)
            .await
            .expect("create owner");
        wait_relay(&owner).await;
        let ticket = owner.ticket_string().await.expect("ticket");

        // Bridge node B — what `ama serve` runs: joins the owner's inbox.
        let bridge = Arc::new(
            Inbox::join_ticket(relay_endpoint(relay_map.clone()).await, &ticket, "webhook", None)
                .await
                .expect("join bridge"),
        );
        wait_relay(&bridge).await;

        // Drive the GitHub PR adapter through the real HTTP router on the bridge.
        let router = build_router(ServerState {
            inbox: bridge.clone(),
            default_source: Arc::new("webhook".into()),
            token: None,
        });
        let payload = include_str!("../../../scripts/sample-github-pr.json");
        let resp = router
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/github/pr")
                    .header("content-type", "application/json")
                    .body(Body::from(payload))
                    .unwrap(),
            )
            .await
            .expect("router oneshot");
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["ignored"], serde_json::json!(false), "PR should be actionable");
        let id = body["id"].as_str().expect("card id in response").to_string();

        // The real proof: the card the adapter built on the bridge gossips to the
        // owner node, with the adapter's summary intact.
        let card = await_message(&owner, &id).await;
        assert_eq!(
            card.summary,
            "[acme/widgets#42] Add retry to the upload path (by @octocat)"
        );
        assert_eq!(card.source, "webhook/github");

        owner.shutdown().await.expect("shutdown owner");
        Arc::try_unwrap(bridge)
            .expect("sole bridge ref")
            .shutdown()
            .await
            .expect("shutdown bridge");
    }
}
