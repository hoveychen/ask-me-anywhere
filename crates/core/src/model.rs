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

/// The three key families in the inbox doc, recovered from a raw entry key —
/// the inverse of [`msg_key`] / [`state_key`] / [`data_key`]. Used to route
/// live document events back to the card (and bind path) they touched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyKind {
    Message { id: String },
    State { id: String },
    /// `bind_path` keeps its leading `/` (e.g. `/note`), matching [`data_key`].
    Data { id: String, bind_path: String },
}

/// Parse a doc entry key into its [`KeyKind`], or `None` for keys outside the
/// three families. A `data/` key splits at the first `/` after the prefix, so
/// the card id (which carries no `/`) is separated from the bind path while the
/// bind path keeps its leading `/`.
pub fn parse_key(key: &str) -> Option<KeyKind> {
    if let Some(rest) = key.strip_prefix("data/") {
        let slash = rest.find('/')?;
        let (id, bind_path) = rest.split_at(slash);
        return Some(KeyKind::Data {
            id: id.to_string(),
            bind_path: bind_path.to_string(),
        });
    }
    if let Some(id) = key.strip_prefix("state/") {
        return Some(KeyKind::State { id: id.to_string() });
    }
    if let Some(id) = key.strip_prefix("msg/") {
        return Some(KeyKind::Message { id: id.to_string() });
    }
    None
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

    #[test]
    fn parse_key_inverts_key_builders() {
        assert_eq!(
            parse_key(&msg_key("abc")),
            Some(KeyKind::Message { id: "abc".into() })
        );
        assert_eq!(
            parse_key(&state_key("abc")),
            Some(KeyKind::State { id: "abc".into() })
        );
        assert_eq!(
            parse_key(&data_key("abc", "/note")),
            Some(KeyKind::Data { id: "abc".into(), bind_path: "/note".into() })
        );
        // Nested bind paths keep every segment, leading slash included.
        assert_eq!(
            parse_key(&data_key("abc", "/contact/email")),
            Some(KeyKind::Data {
                id: "abc".into(),
                bind_path: "/contact/email".into(),
            })
        );
        assert_eq!(parse_key("other/x"), None);
        assert_eq!(parse_key("data/justid"), None); // no bind path → not a data entry
    }
}
