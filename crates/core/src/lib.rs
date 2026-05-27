//! ama-core — peer-to-peer actionable-message-card inbox.
//!
//! See ARCHITECTURE.md. The inbox is one multi-writer `iroh-doc` replicated
//! across all of a single user's devices; messages, dismiss/action state and
//! A2UI data-model bindings are CRDT entries that converge without any server.

pub mod inbox;
pub mod model;
pub mod net;

pub use inbox::{now_ms, Inbox};
pub use iroh_docs::engine::LiveEvent;
pub use model::{
    data_key, msg_key, state_key, status_for_action, MessageCard, MessageState, Status,
};
pub use net::{build_endpoint, RelayChoice};
