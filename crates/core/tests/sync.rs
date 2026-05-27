//! P4 — two-node CRDT sync integration test.
//!
//! Spins up two real iroh nodes in one process, pairs them with a ticket (the
//! same path the CLI / QR pairing uses), and verifies the three sync flows that
//! M1 promises (ARCHITECTURE.md §2/§6):
//!
//! 1. a card pushed on node A appears on node B,
//! 2. a dismiss on node B converges back to node A (global dismiss),
//! 3. an A2UI data-model field edit on A propagates to B.
//!
//! Both nodes wait for a home relay before pairing (the relay carries the
//! ticket's reachability and coordinates holepunching); the message payloads
//! themselves still flow peer-to-peer / direct. The test therefore needs
//! network access to a relay. All waits are bounded, so missing connectivity or
//! a broken sync fails the test with a clear message instead of hanging.

use std::time::Duration;

use ama_core::{now_ms, Inbox, MessageCard, MessageState, Status};
use iroh::{endpoint::presets, Endpoint};

const POLL: Duration = Duration::from_millis(100);
/// ~30s budget per convergence wait — generous for local holepunching, but
/// finite so a genuinely broken sync fails the test instead of stalling CI.
const TRIES: usize = 300;

async fn bind() -> Endpoint {
    Endpoint::bind(presets::N0).await.expect("bind endpoint")
}

/// Wait until the node has a home relay URL in its address. The relay is what
/// makes the pairing ticket routable across NATs and lets holepunching
/// coordinate, so minting a ticket before this is set produces an unreachable
/// ticket (the failure we hit first). Bounded so missing connectivity fails the
/// test instead of hanging.
async fn wait_relay(inbox: &Inbox) {
    // Kick off relay connection in the background; then poll the advertised addr.
    let ep = inbox.endpoint().clone();
    tokio::spawn(async move { ep.online().await });
    for _ in 0..600 {
        if inbox.endpoint().addr().relay_urls().next().is_some() {
            return;
        }
        tokio::time::sleep(POLL).await;
    }
    panic!("node never obtained a relay url (no network connectivity?)");
}

// The reads below tolerate transient `Err`s: a synced entry shows up (the
// record) before its content blob finishes downloading, and reading the
// half-downloaded blob errors until the `ContentReady` event lands. We just
// keep polling — only a timeout is a real failure.

async fn await_message(inbox: &Inbox, id: &str) -> MessageCard {
    for _ in 0..TRIES {
        if let Ok(Some(card)) = inbox.get_message(id).await {
            return card;
        }
        tokio::time::sleep(POLL).await;
    }
    panic!("card {id} never synced to peer");
}

async fn await_status(inbox: &Inbox, id: &str, want: Status) -> MessageState {
    for _ in 0..TRIES {
        if let Ok(Some(state)) = inbox.get_state(id).await {
            if state.status == want {
                return state;
            }
        }
        tokio::time::sleep(POLL).await;
    }
    panic!("state {id} never converged to {want:?}");
}

async fn await_data(inbox: &Inbox, id: &str, path: &str) -> serde_json::Value {
    for _ in 0..TRIES {
        if let Ok(Some(value)) = inbox.get_data(id, path).await {
            return value;
        }
        tokio::time::sleep(POLL).await;
    }
    panic!("data {id}{path} never synced to peer");
}

#[tokio::test]
async fn two_nodes_sync_and_dismiss_converges() {
    // Node A creates the inbox; node B joins via the pairing ticket.
    let a = Inbox::create(bind().await, "desktop").await.expect("create A");
    // A must have a relay before minting the ticket so it carries A's relay URL.
    wait_relay(&a).await;
    let ticket = a.ticket().await.expect("ticket");
    let b = Inbox::join(bind().await, ticket, "phone").await.expect("join B");
    wait_relay(&b).await;

    // 1. A pushes a card → B receives the full payload.
    let card = MessageCard {
        id: "card-1".into(),
        a2ui: serde_json::json!({ "root": { "Text": { "text": "Deploy now?" } } }),
        summary: "Deploy now?".into(),
        source: "test".into(),
        created_at: now_ms(),
    };
    a.push(&card).await.expect("push");
    let on_b = await_message(&b, "card-1").await;
    assert_eq!(on_b.summary, "Deploy now?");
    assert_eq!(on_b.a2ui, card.a2ui);

    // 2. B dismisses → A converges to Dismissed (global dismiss).
    b.dismiss("card-1").await.expect("dismiss");
    let on_a = await_status(&a, "card-1", Status::Dismissed).await;
    assert_eq!(on_a.action_name.as_deref(), Some("dismiss"));
    assert_eq!(on_a.device, "phone");
    // Both replicas now agree.
    assert_eq!(
        b.get_state("card-1").await.unwrap().unwrap().status,
        Status::Dismissed
    );

    // 3. A2UI data-model field edit on A → propagates to B.
    a.set_data("card-1", "/note", &serde_json::json!("shipping it"))
        .await
        .expect("set_data");
    let note = await_data(&b, "card-1", "/note").await;
    assert_eq!(note, serde_json::json!("shipping it"));

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
}
