//! Dart-facing bridge over the [`ama_core::Inbox`].
//!
//! M3a only needs the local-only operations — create an in-memory inbox, push a
//! card, list the cards. Pairing / dismiss / data sync land in M3b/c. The
//! `a2ui` payload crosses the FFI as a JSON string because `serde_json::Value`
//! has no FRB primitive — Dart parses or builds it with `dart:convert`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use flutter_rust_bridge::frb;
use futures_lite::StreamExt;

use ama_core::{
    build_endpoint, load_or_create_secret_key, now_ms, parse_key, Endpoint, Inbox, KeyKind,
    LiveEvent, MessageCard, RelayChoice, Status,
};

use crate::frb_generated::StreamSink;

/// Build a persistent iroh endpoint for the inbox rooted at `data_dir`: load (or
/// first-time generate) the device's long-term secret key from
/// `<data_dir>/node-key`, so the node-id and pairing ticket stay stable across
/// app restarts.
async fn persistent_endpoint(data_dir: &Path) -> Result<Endpoint> {
    let key = load_or_create_secret_key(&data_dir.join("node-key"))?;
    build_endpoint(RelayChoice::N0, Some(key)).await
}

/// Opaque handle to a running inbox node, held by Dart between calls.
pub struct InboxHandle {
    inner: Arc<Inbox>,
}

/// Plain-data view of a [`MessageCard`] that crosses the FFI cleanly.
#[derive(Clone, Debug)]
pub struct CardView {
    pub id: String,
    pub summary: String,
    pub source: String,
    pub created_at: u64,
    /// A2UI message tree as a JSON string (Dart side parses with `jsonDecode`).
    pub a2ui_json: String,
    /// Latest converged status; defaults to [`Status::Unread`] when no state
    /// entry has been written yet.
    pub status: CardStatus,
}

/// Mirror of [`ama_core::Status`] for Dart — the core enum's `Serialize` impl
/// isn't exposed across FRB.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CardStatus {
    Unread,
    Dismissed,
    Actioned,
}

impl From<Status> for CardStatus {
    fn from(s: Status) -> Self {
        match s {
            Status::Unread => CardStatus::Unread,
            Status::Dismissed => CardStatus::Dismissed,
            Status::Actioned => CardStatus::Actioned,
        }
    }
}

impl InboxHandle {
    /// Create a brand-new persistent inbox node rooted at `data_dir`. Messages,
    /// state and the device identity all live on disk under that dir, so they
    /// survive a restart (reopen later with [`open`]). Uses n0's default relays
    /// for now — a later milestone plumbs the relay choice through to Dart.
    #[frb]
    pub async fn create(device: String, data_dir: String) -> Result<InboxHandle> {
        let dir = PathBuf::from(data_dir);
        let endpoint = persistent_endpoint(&dir).await?;
        let inbox = Inbox::create(endpoint, device, Some(&dir)).await?;
        Ok(InboxHandle { inner: Arc::new(inbox) })
    }

    /// Reopen the persistent inbox previously created/joined under `data_dir`,
    /// or `None` if this dir has never held one. An app boots by trying `open`
    /// first and falling back to [`create`].
    #[frb]
    pub async fn open(device: String, data_dir: String) -> Result<Option<InboxHandle>> {
        let dir = PathBuf::from(data_dir);
        let endpoint = persistent_endpoint(&dir).await?;
        let inbox = Inbox::open(endpoint, device, &dir).await?;
        Ok(inbox.map(|inbox| InboxHandle { inner: Arc::new(inbox) }))
    }

    /// Join an existing inbox from a serialized pairing ticket string — the QR /
    /// paste payload another device produced via [`ticket`]. Spins up a node
    /// rooted at `data_dir` that imports the shared doc, starts syncing, and
    /// persists it so the join survives a restart.
    #[frb]
    pub async fn join(ticket: String, device: String, data_dir: String) -> Result<InboxHandle> {
        let dir = PathBuf::from(data_dir);
        let endpoint = persistent_endpoint(&dir).await?;
        let inbox = Inbox::join_ticket(endpoint, &ticket, device, Some(&dir)).await?;
        Ok(InboxHandle { inner: Arc::new(inbox) })
    }

    /// This inbox's pairing ticket as a string. Render it as a QR code (or let
    /// the user copy it) so another device can [`join`] this inbox.
    #[frb]
    pub async fn ticket(&self) -> Result<String> {
        self.inner.ticket_string().await
    }

    /// Push a new actionable card. `a2ui_json` is the A2UI message tree
    /// serialized as JSON; pass `"{}"` if you don't have one yet.
    #[frb]
    pub async fn push(&self, summary: String, a2ui_json: String) -> Result<String> {
        let a2ui: serde_json::Value =
            serde_json::from_str(&a2ui_json).context("invalid a2ui_json")?;
        let card = MessageCard {
            id: uuid_like(),
            a2ui,
            summary,
            source: "app".to_string(),
            created_at: now_ms(),
        };
        self.inner.push(&card).await?;
        Ok(card.id)
    }

    /// Record a fired A2UI action against a card. `action_name == "dismiss"`
    /// dismisses the card; any other name marks it actioned. `action_context_json`
    /// is the resolved A2UI action context (BoundValue map) as a JSON string, or
    /// `None`/empty when the action carried no context. Converges across devices.
    #[frb]
    pub async fn record_action(
        &self,
        msg_id: String,
        action_name: String,
        action_context_json: Option<String>,
    ) -> Result<()> {
        let context = match action_context_json {
            Some(s) if !s.trim().is_empty() => {
                Some(serde_json::from_str(&s).context("invalid action_context_json")?)
            }
            _ => None,
        };
        self.inner.record_action(&msg_id, &action_name, context).await
    }

    /// Write an A2UI data-model binding value for a card. `bind_path` is a JSON
    /// Pointer like `/contact/email`; `value_json` is the value serialized as
    /// JSON. Converges across devices (latest-writer-wins per path).
    #[frb]
    pub async fn set_data(
        &self,
        msg_id: String,
        bind_path: String,
        value_json: String,
    ) -> Result<()> {
        let value: serde_json::Value =
            serde_json::from_str(&value_json).context("invalid value_json")?;
        self.inner.set_data(&msg_id, &bind_path, &value).await
    }

    /// Read the current converged value at a card's data-model path as a JSON
    /// string, or `None` if unset locally yet.
    #[frb]
    pub async fn get_data(&self, msg_id: String, bind_path: String) -> Result<Option<String>> {
        let value = self.inner.get_data(&msg_id, &bind_path).await?;
        Ok(value.map(|v| serde_json::to_string(&v).unwrap_or_else(|_| "null".to_string())))
    }

    /// Live document changes, for refreshing the UI on remote (and local)
    /// writes. Each event names the touched key family (`message` / `state` /
    /// `data`), plus a coarse `tick` when a sync / content batch completes (the
    /// point at which freshly-synced remote content becomes readable). The Dart
    /// side fetches the actual value via [`get_data`] / [`list_messages`].
    #[frb]
    pub async fn watch(&self, sink: StreamSink<DocEvent>) -> Result<()> {
        let mut stream = self.inner.subscribe().await?;
        while let Some(event) = stream.next().await {
            let to_send = match event? {
                LiveEvent::InsertLocal { entry } => classify_key(entry.key()),
                LiveEvent::InsertRemote { entry, .. } => classify_key(entry.key()),
                LiveEvent::ContentReady { .. }
                | LiveEvent::PendingContentReady
                | LiveEvent::SyncFinished(_) => Some(DocEvent {
                    kind: "tick".to_string(),
                    msg_id: None,
                    bind_path: None,
                }),
                _ => None,
            };
            if let Some(event) = to_send {
                // `add` errs once Dart drops the subscription — stop the loop.
                if sink.add(event).is_err() {
                    break;
                }
            }
        }
        Ok(())
    }

    /// All cards present in the local replica, newest first, each paired with
    /// its converged [`CardStatus`].
    #[frb]
    pub async fn list_messages(&self) -> Result<Vec<CardView>> {
        let cards = self.inner.list_messages().await?;
        let mut out = Vec::with_capacity(cards.len());
        for card in cards {
            // get_state may transiently err while a synced blob is still
            // downloading; treat that as "no state yet" — caller refreshes.
            let status = match self.inner.get_state(&card.id).await {
                Ok(Some(state)) => state.status.into(),
                _ => CardStatus::Unread,
            };
            out.push(CardView {
                id: card.id,
                a2ui_json: serde_json::to_string(&card.a2ui).unwrap_or_else(|_| "{}".to_string()),
                summary: card.summary,
                source: card.source,
                created_at: card.created_at,
                status,
            });
        }
        Ok(out)
    }
}

/// A coarse document-change notification surfaced to Dart by [`InboxHandle::watch`].
/// Dart reacts by re-fetching the touched value; the event itself carries only
/// enough to know *what* changed, not the new bytes.
#[derive(Clone, Debug)]
pub struct DocEvent {
    /// One of `"message"`, `"state"`, `"data"`, `"tick"`.
    pub kind: String,
    /// The card id the change concerns (absent for `"tick"`).
    pub msg_id: Option<String>,
    /// For `"data"` events, the JSON-Pointer bind path (e.g. `/note`).
    pub bind_path: Option<String>,
}

/// Map a doc entry key to the [`DocEvent`] Dart should react to, or `None` for
/// keys outside the inbox's three families. Key parsing (and its tests) live in
/// [`ama_core::parse_key`] alongside the key builders.
fn classify_key(key: &[u8]) -> Option<DocEvent> {
    match parse_key(std::str::from_utf8(key).ok()?)? {
        KeyKind::Message { id } => Some(DocEvent {
            kind: "message".to_string(),
            msg_id: Some(id),
            bind_path: None,
        }),
        KeyKind::State { id } => Some(DocEvent {
            kind: "state".to_string(),
            msg_id: Some(id),
            bind_path: None,
        }),
        KeyKind::Data { id, bind_path } => Some(DocEvent {
            kind: "data".to_string(),
            msg_id: Some(id),
            bind_path: Some(bind_path),
        }),
    }
}

/// Crude unique id that doesn't require a uuid crate dependency in the bridge:
/// `now_ms` plus a 4-byte nanos-derived suffix. Good enough for M3a demo cards.
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    format!("{}-{:04x}", d.as_millis(), (d.subsec_nanos() & 0xffff))
}
