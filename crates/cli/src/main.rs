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

use std::sync::Arc;

use anyhow::{Context, Result};
use ama_core::{build_endpoint, now_ms, Inbox, LiveEvent, MessageCard, RelayChoice, Status};
use clap::{Parser, Subcommand};
use futures_lite::StreamExt;
use qrcode::{render::unicode, QrCode};
use tokio::io::{AsyncBufReadExt, BufReader};

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
}

#[tokio::main]
async fn main() -> Result<()> {
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
    };

    // Watch the document for remote changes in the background.
    let events = inbox.subscribe().await?;
    tokio::spawn(watch(inbox.clone(), events));

    repl(inbox).await
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
