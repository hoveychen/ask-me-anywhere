//! ama-core — peer-to-peer actionable-message-card inbox.
//!
//! See ARCHITECTURE.md. The inbox is one multi-writer `iroh-doc` replicated
//! across all of a single user's devices; messages, dismiss/action state and
//! A2UI data-model bindings are CRDT entries that converge without any server.

pub mod inbox;
pub mod model;

pub use inbox::{now_ms, Inbox};
pub use model::{data_key, msg_key, state_key, MessageCard, MessageState, Status};
