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
}
