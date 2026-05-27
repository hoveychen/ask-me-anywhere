//! Two-node CRDT sync integration tests (ARCHITECTURE.md §2/§5/§6).
//!
//! Two real iroh nodes run in one process, pair with a ticket (the same path
//! the CLI / QR pairing uses), and exercise the three sync flows M1 promises:
//!
//! 1. a card pushed on node A appears on node B,
//! 2. a dismiss on node B converges back to node A (global dismiss),
//! 3. an A2UI data-model field edit on A propagates to B.
//!
//! Both share [`assert_sync_scenario`]; they differ only in which relay the
//! nodes use:
//!
//! - [`two_nodes_sync_over_self_hosted_relay`] (M2) spins up a local
//!   `iroh-relay` in-process and configures both nodes with it. Fully offline
//!   and deterministic — the canonical CI test. NOTE: it proves the custom-relay
//!   config path is valid and that two nodes so configured pair and converge; it
//!   does NOT prove traffic is *relayed*. Both nodes share a host, so iroh
//!   holepunches a direct loopback path regardless of the relay (verified: the
//!   test still passes if each node uses a *separate* relay). True relay-fallback
//!   under symmetric NAT can only be shown across machines — that's M2 P4 (real
//!   VPS relay + two devices).
//! - [`two_nodes_sync_via_n0_relay`] uses n0's public relays, validating the
//!   default real-world path. It needs internet, so it's `#[ignore]`d by default;
//!   run it with `cargo test -- --ignored` for a live check.
//!
//! All waits are bounded, so missing connectivity or a broken sync fails with a
//! clear message instead of hanging.

use std::time::Duration;

use ama_core::{now_ms, Inbox, MessageCard, MessageState, Status};
use iroh::{endpoint::presets, tls::CaRootsConfig, Endpoint, RelayMap, RelayMode};

const POLL: Duration = Duration::from_millis(100);
/// ~30s budget per convergence wait — generous for holepunching, but finite so
/// a genuinely broken sync fails the test instead of stalling CI.
const TRIES: usize = 300;

/// An endpoint on n0's default relays + discovery.
async fn n0_endpoint() -> Endpoint {
    Endpoint::bind(presets::N0).await.expect("bind endpoint")
}

/// An endpoint that uses only the given (self-hosted / local) relay, with no n0
/// discovery. `insecure_skip_verify` trusts the test relay's self-signed cert;
/// production endpoints (see `ama_core::build_endpoint`) keep real TLS.
async fn relay_endpoint(relay_map: RelayMap) -> Endpoint {
    Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Custom(relay_map))
        .ca_roots_config(CaRootsConfig::insecure_skip_verify())
        .bind()
        .await
        .expect("bind relay endpoint")
}

/// Wait until the node has a relay URL in its address. The relay carries the
/// pairing ticket's reachability, so minting a ticket before this is set
/// produces an unreachable ticket (a failure we hit early on). Bounded so
/// missing connectivity fails the test instead of hanging.
async fn wait_relay(inbox: &Inbox) {
    let ep = inbox.endpoint().clone();
    tokio::spawn(async move { ep.online().await });
    for _ in 0..600 {
        if inbox.endpoint().addr().relay_urls().next().is_some() {
            return;
        }
        tokio::time::sleep(POLL).await;
    }
    panic!("node never obtained a relay url (no connectivity to the relay?)");
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

/// The shared assertions: push → dismiss-converge → data-field sync. `a` is the
/// inbox creator, `b` the joiner; both must already be paired and relay-ready.
async fn assert_sync_scenario(a: &Inbox, b: &Inbox) {
    // 1. A pushes a card → B receives the full payload.
    let card = MessageCard {
        id: "card-1".into(),
        a2ui: serde_json::json!({ "root": { "Text": { "text": "Deploy now?" } } }),
        summary: "Deploy now?".into(),
        source: "test".into(),
        created_at: now_ms(),
    };
    a.push(&card).await.expect("push");
    let on_b = await_message(b, "card-1").await;
    assert_eq!(on_b.summary, "Deploy now?");
    assert_eq!(on_b.a2ui, card.a2ui);

    // 2. B dismisses → A converges to Dismissed (global dismiss).
    b.dismiss("card-1").await.expect("dismiss");
    let on_a = await_status(a, "card-1", Status::Dismissed).await;
    assert_eq!(on_a.action_name.as_deref(), Some("dismiss"));
    assert_eq!(on_a.device, "phone");
    assert_eq!(
        b.get_state("card-1").await.unwrap().unwrap().status,
        Status::Dismissed
    );

    // 3. A2UI data-model field edit on A → propagates to B.
    a.set_data("card-1", "/note", &serde_json::json!("shipping it"))
        .await
        .expect("set_data");
    let note = await_data(b, "card-1", "/note").await;
    assert_eq!(note, serde_json::json!("shipping it"));
}

#[tokio::test]
async fn two_nodes_sync_over_self_hosted_relay() {
    // Run our own relay in-process; both nodes use only it (no n0, no internet).
    let (relay_map, _url, _server) = iroh::test_utils::run_relay_server()
        .await
        .expect("spawn local relay");

    let a = Inbox::create(relay_endpoint(relay_map.clone()).await, "desktop")
        .await
        .expect("create A");
    wait_relay(&a).await;
    let ticket = a.ticket().await.expect("ticket");
    let b = Inbox::join(relay_endpoint(relay_map.clone()).await, ticket, "phone")
        .await
        .expect("join B");
    wait_relay(&b).await;

    assert_sync_scenario(&a, &b).await;

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
    // `_server` (the relay) stays alive until here, then shuts down on drop.
}

#[tokio::test]
#[ignore = "needs internet / n0 relay; run with `cargo test -- --ignored`"]
async fn two_nodes_sync_via_n0_relay() {
    let a = Inbox::create(n0_endpoint().await, "desktop").await.expect("create A");
    wait_relay(&a).await;
    let ticket = a.ticket().await.expect("ticket");
    let b = Inbox::join(n0_endpoint().await, ticket, "phone").await.expect("join B");
    wait_relay(&b).await;

    assert_sync_scenario(&a, &b).await;

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
}
