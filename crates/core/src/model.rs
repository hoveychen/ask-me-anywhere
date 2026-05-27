//! Data model for the actionable-message-card inbox.
//!
//! Mirrors ARCHITECTURE.md §3/§4. The inbox is a single multi-writer
//! `iroh-doc`; every device holds a replica. Three key namespaces:
//!
//! - `msg/<id>`              → [`MessageCard`] (immutable A2UI message tree)
//! - `state/<id>`            → [`MessageState`] (LWW: status / userAction)
//! - `data/<id>/<bindPath>`  → scalar value (LWW, A2UI data-model binding)

use serde::{Deserialize, Serialize};

/// An actionable card. The payload is an A2UI message tree rendered by the
/// GenUI SDK on each device. Immutable once written.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MessageCard {
    /// Globally-unique id (ULID).
    pub id: String,
    /// A2UI message tree (opaque JSON to the core; rendered by the Flutter end).
    pub a2ui: serde_json::Value,
    /// Plain-text summary for system-level notifications that can't render A2UI.
    pub summary: String,
    /// Who/what produced this card.
    pub source: String,
    /// Creation time, unix ms.
    pub created_at: u64,
}

/// Lifecycle status of a card, synced globally across devices.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Unread,
    Dismissed,
    Actioned,
}

/// Mutable per-card state. Converges via last-writer-wins on [`MessageState::lww_key`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MessageState {
    pub msg_id: String,
    pub status: Status,
    /// A2UI `action.name` the user fired, if any. `"dismiss"` is the dismiss convention.
    pub action_name: Option<String>,
    /// Resolved A2UI action context (BoundValue map), if any.
    pub action_context: Option<serde_json::Value>,
    /// Device that produced this state.
    pub device: String,
    /// Logical timestamp, unix ms — primary LWW key.
    pub ts: u64,
}

impl MessageState {
    /// LWW comparison key: later `ts` wins; ties broken by `device` for determinism.
    /// Returns `true` if `self` should win over `other`.
    pub fn wins_over(&self, other: &MessageState) -> bool {
        (self.ts, self.device.as_str()) > (other.ts, other.device.as_str())
    }
}

/// The global [`Status`] a fired A2UI action converges a card to. The
/// `"dismiss"` action name is the dismiss convention; every other action marks
/// the card actioned. See [`crate::inbox::Inbox::record_action`].
pub fn status_for_action(action_name: &str) -> Status {
    match action_name {
        "dismiss" => Status::Dismissed,
        _ => Status::Actioned,
    }
}

/// Key for a card's immutable payload.
pub fn msg_key(id: &str) -> String {
    format!("msg/{id}")
}

/// Key for a card's mutable state.
pub fn state_key(id: &str) -> String {
    format!("state/{id}")
}

/// Key for an A2UI data-model binding value. `bind_path` is a JSON Pointer
/// (RFC 6901), e.g. `/contact/email`.
pub fn data_key(id: &str, bind_path: &str) -> String {
    format!("data/{id}{bind_path}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lww_later_ts_wins() {
        let early = MessageState {
            msg_id: "m1".into(),
            status: Status::Unread,
            action_name: None,
            action_context: None,
            device: "desktop".into(),
            ts: 100,
        };
        let late = MessageState { ts: 200, status: Status::Dismissed, ..early.clone() };
        assert!(late.wins_over(&early));
        assert!(!early.wins_over(&late));
    }

    #[test]
    fn lww_tie_broken_by_device() {
        let a = MessageState {
            msg_id: "m1".into(),
            status: Status::Dismissed,
            action_name: None,
            action_context: None,
            device: "android".into(),
            ts: 100,
        };
        let b = MessageState { device: "desktop".into(), ..a.clone() };
        // "desktop" > "android" lexically, deterministic either way.
        assert!(b.wins_over(&a));
        assert!(!a.wins_over(&b));
    }

    #[test]
    fn status_for_action_maps_dismiss_and_others() {
        assert_eq!(status_for_action("dismiss"), Status::Dismissed);
        assert_eq!(status_for_action("approve"), Status::Actioned);
        assert_eq!(status_for_action("snooze"), Status::Actioned);
        assert_eq!(status_for_action(""), Status::Actioned);
    }

    #[test]
    fn keys_format() {
        assert_eq!(msg_key("abc"), "msg/abc");
        assert_eq!(state_key("abc"), "state/abc");
        assert_eq!(data_key("abc", "/contact/email"), "data/abc/contact/email");
    }
}
