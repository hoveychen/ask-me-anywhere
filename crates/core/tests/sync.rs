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

use std::path::PathBuf;
use std::time::Duration;

use ama_core::{
    build_endpoint, load_or_create_secret_key, now_ms, Inbox, MessageCard, MessageState,
    RelayChoice, Status,
};
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
///
/// Polls `endpoint().addr()` (resolved via `watch_addr()` / `home_relay()`,
/// a freshly-built `EndpointAddr`). Do NOT spawn `Endpoint::online()`
/// alongside this — `online()` iterates the `home_relay_status()` watcher,
/// which aliases state the relay actor mutates concurrently, double-freeing
/// the heap (SIGABRT in release). See crates/cli/src/main.rs::wait_relay.
async fn wait_relay(inbox: &Inbox) {
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

    let a = Inbox::create(relay_endpoint(relay_map.clone()).await, "desktop", None)
        .await
        .expect("create A");
    wait_relay(&a).await;
    let ticket = a.ticket().await.expect("ticket");
    let b = Inbox::join(relay_endpoint(relay_map.clone()).await, ticket, "phone", None)
        .await
        .expect("join B");
    wait_relay(&b).await;

    assert_sync_scenario(&a, &b).await;

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
    // `_server` (the relay) stays alive until here, then shuts down on drop.
}

/// M3c pairing: the QR/paste payload is the *string* ticket, so prove a node
/// pairs and converges when joining via [`Inbox::ticket_string`] +
/// [`Inbox::join_ticket`] (the exact path the Flutter pairing UI drives),
/// not just the in-memory `DocTicket`.
#[tokio::test]
async fn two_nodes_pair_via_ticket_string() {
    let (relay_map, _url, _server) = iroh::test_utils::run_relay_server()
        .await
        .expect("spawn local relay");

    let a = Inbox::create(relay_endpoint(relay_map.clone()).await, "desktop", None)
        .await
        .expect("create A");
    wait_relay(&a).await;
    let ticket_str = a.ticket_string().await.expect("ticket string");
    let b = Inbox::join_ticket(
        relay_endpoint(relay_map.clone()).await,
        &ticket_str,
        "phone",
        None,
    )
    .await
    .expect("join B from ticket string");
    wait_relay(&b).await;

    assert_sync_scenario(&a, &b).await;

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
}

/// A unique temp data dir for a persistence test, e.g.
/// `<tmp>/ama-persist-<pid>-<ms>`. No `tempfile` dep — the suffix is unique
/// enough for a single test run, and we `remove_dir_all` it at the end.
fn temp_data_dir(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!("ama-persist-{tag}-{}-{}", std::process::id(), now_ms()))
}

/// A fully-offline endpoint: relay disabled, minimal preset, no n0 discovery.
/// Persistence is local-only (one node writes then reopens), so it never needs
/// to reach a peer.
async fn offline_endpoint(secret_path: &std::path::Path) -> Endpoint {
    let key = load_or_create_secret_key(secret_path).expect("load/create secret key");
    build_endpoint(RelayChoice::Disabled, Some(key))
        .await
        .expect("bind offline endpoint")
}

/// The persist-store guarantee: a card pushed on a persistent node is still
/// there after a "restart" — drop the node, then [`Inbox::open`] the same data
/// dir on a fresh endpoint. Also asserts the persisted [`load_or_create_secret_key`]
/// keeps the node-id stable across that restart (identity persistence).
#[tokio::test]
async fn persistent_inbox_survives_restart() {
    let dir = temp_data_dir("restart");
    let key_path = dir.join("node-key");

    // First "launch": create a persistent inbox, push a card, then shut down.
    let first_id = {
        let inbox = Inbox::create(offline_endpoint(&key_path).await, "desktop", Some(&dir))
            .await
            .expect("create persistent inbox");
        let node_id = inbox.endpoint().id();
        let card = MessageCard {
            id: "persist-1".into(),
            a2ui: serde_json::json!({ "root": { "Text": { "text": "still here?" } } }),
            summary: "still here?".into(),
            source: "test".into(),
            created_at: now_ms(),
        };
        inbox.push(&card).await.expect("push");
        // Confirm it's locally readable before we tear the node down.
        assert!(inbox.get_message("persist-1").await.unwrap().is_some());
        inbox.shutdown().await.expect("shutdown first launch");
        node_id
    };

    // Second "launch": reopen the same data dir on a brand-new endpoint.
    let reopened = Inbox::open(offline_endpoint(&key_path).await, "desktop", &dir)
        .await
        .expect("open persisted inbox")
        .expect("a persisted inbox should exist at this data dir");

    // The card written before the restart is still present.
    let card = reopened
        .get_message("persist-1")
        .await
        .expect("read message")
        .expect("card pushed before restart must survive");
    assert_eq!(card.summary, "still here?");

    // Identity persisted: same secret key file → same node-id across restart.
    assert_eq!(
        reopened.endpoint().id(),
        first_id,
        "persisted secret key should keep the node-id stable across restart"
    );

    reopened.shutdown().await.expect("shutdown second launch");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `Inbox::open` on a data dir that has never created/joined an inbox returns
/// `Ok(None)`, so an app can cleanly fall back to `create`.
#[tokio::test]
async fn open_returns_none_on_fresh_dir() {
    let dir = temp_data_dir("fresh");
    let key_path = dir.join("node-key");
    let opened = Inbox::open(offline_endpoint(&key_path).await, "desktop", &dir)
        .await
        .expect("open should not error on a fresh dir");
    assert!(opened.is_none(), "a never-used data dir has no inbox to open");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
#[ignore = "needs internet / n0 relay; run with `cargo test -- --ignored`"]
async fn two_nodes_sync_via_n0_relay() {
    let a = Inbox::create(n0_endpoint().await, "desktop", None).await.expect("create A");
    wait_relay(&a).await;
    let ticket = a.ticket().await.expect("ticket");
    let b = Inbox::join(n0_endpoint().await, ticket, "phone", None).await.expect("join B");
    wait_relay(&b).await;

    assert_sync_scenario(&a, &b).await;

    a.shutdown().await.expect("shutdown A");
    b.shutdown().await.expect("shutdown B");
}
