//! Dart-facing bridge over the [`ama_core::Inbox`].
//!
//! M3a only needs the local-only operations — create an in-memory inbox, push a
//! card, list the cards. Pairing / dismiss / data sync land in M3b/c. The
//! `a2ui` payload crosses the FFI as a JSON string because `serde_json::Value`
//! has no FRB primitive — Dart parses or builds it with `dart:convert`.

use std::sync::Arc;

use anyhow::{Context, Result};
use flutter_rust_bridge::frb;

use ama_core::{
    build_endpoint, now_ms, Inbox, MessageCard, RelayChoice, Status,
};

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
    /// Spin up a fresh inbox node. Uses n0's default relays for now — M3b/c
    /// will plumb the relay choice through to Dart.
    #[frb]
    pub async fn create(device: String) -> Result<InboxHandle> {
        let endpoint = build_endpoint(RelayChoice::N0).await?;
        let inbox = Inbox::create(endpoint, device).await?;
        Ok(InboxHandle { inner: Arc::new(inbox) })
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

/// Crude unique id that doesn't require a uuid crate dependency in the bridge:
/// `now_ms` plus a 4-byte nanos-derived suffix. Good enough for M3a demo cards.
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    format!("{}-{:04x}", d.as_millis(), (d.subsec_nanos() & 0xffff))
}
