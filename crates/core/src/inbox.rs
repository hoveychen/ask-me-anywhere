//! [`Inbox`] — the multi-writer `iroh-doc` that holds one user's message cards.
//!
//! Mirrors ARCHITECTURE.md §2/§4: every device runs an [`Inbox`], all replicas
//! of the same `iroh-doc`. Pushing a card, dismissing it, firing an action and
//! editing a bound form field are all just entry writes that CRDT-converge:
//!
//! - `msg/<id>`             → [`MessageCard`]  (immutable, single writer per id)
//! - `state/<id>`           → [`MessageState`] (multi-writer, our own ts+device LWW)
//! - `data/<id>/<bindPath>` → scalar JSON      (multi-writer, iroh latest-per-key LWW)
//!
//! Networking is wired exactly like iroh-docs' own example: an [`Endpoint`]
//! plus a [`Router`] accepting the blobs, gossip and docs ALPNs. Content bytes
//! live in the blobs store keyed by each entry's content hash, so reads go
//! through [`BlobsStore::get_bytes`].

use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use futures_lite::StreamExt;
use iroh::{protocol::Router, Endpoint};
use iroh_blobs::{api::Store as BlobsStore, store::mem::MemStore, BlobsProtocol};
use iroh_docs::{
    api::{
        protocol::{AddrInfoOptions, ShareMode},
        Doc,
    },
    engine::LiveEvent,
    protocol::Docs,
    store::Query,
    AuthorId, DocTicket, Entry, NamespaceId,
};
use iroh_gossip::net::Gossip;

use crate::model::{data_key, msg_key, state_key, MessageCard, MessageState, Status};

/// One device's view of the shared message-card inbox.
///
/// Holds the live iroh node ([`Router`] + protocols), the replicated [`Doc`]
/// and this device's signing [`AuthorId`]. Clone-free: drive a single instance
/// per process and hand out `&Inbox`.
#[derive(Debug)]
pub struct Inbox {
    router: Router,
    blobs: BlobsStore,
    doc: Doc,
    author: AuthorId,
    /// Human-readable device label stamped into every [`MessageState`] we write.
    device: String,
}

impl Inbox {
    /// Spawn a fresh node on `endpoint` and create a brand-new inbox document.
    /// The returned inbox is the first replica; share [`Inbox::ticket`] to let
    /// other devices [`Inbox::join`] it.
    pub async fn create(endpoint: Endpoint, device: impl Into<String>) -> Result<Self> {
        let (router, blobs, docs) = spawn_node(endpoint).await?;
        let doc = docs.create().await.context("create inbox doc")?;
        let author = docs.author_default().await.context("default author")?;
        Ok(Self { router, blobs, doc, author, device: device.into() })
    }

    /// Spawn a fresh node on `endpoint` and join an existing inbox via a
    /// [`DocTicket`] (the payload of the pairing QR code). Joins automatically
    /// start syncing with the ticket's peers.
    pub async fn join(
        endpoint: Endpoint,
        ticket: DocTicket,
        device: impl Into<String>,
    ) -> Result<Self> {
        let (router, blobs, docs) = spawn_node(endpoint).await?;
        let doc = docs.import(ticket).await.context("import inbox doc from ticket")?;
        let author = docs.author_default().await.context("default author")?;
        Ok(Self { router, blobs, doc, author, device: device.into() })
    }

    /// This inbox document's namespace id (stable across all replicas).
    pub fn doc_id(&self) -> NamespaceId {
        self.doc.id()
    }

    /// This device's author id.
    pub fn author(&self) -> AuthorId {
        self.author
    }

    /// The underlying iroh endpoint (for address inspection / liveness checks).
    pub fn endpoint(&self) -> &Endpoint {
        self.router.endpoint()
    }

    /// Produce a write-capable ticket for pairing a new device. Encodes the
    /// namespace key plus our relay + direct addresses so the joiner can both
    /// authorize into the doc and dial us.
    pub async fn ticket(&self) -> Result<DocTicket> {
        self.doc
            .share(ShareMode::Write, AddrInfoOptions::RelayAndAddresses)
            .await
            .context("share inbox ticket")
    }

    // ---- messages (msg/<id>, immutable) -----------------------------------

    /// Push a new actionable card. Writes `msg/<id>`; the card is immutable, so
    /// the same id must not be pushed twice with different content.
    pub async fn push(&self, card: &MessageCard) -> Result<()> {
        let value = serde_json::to_vec(card).context("serialize MessageCard")?;
        self.doc
            .set_bytes(self.author, msg_key(&card.id), value)
            .await
            .context("write msg entry")?;
        Ok(())
    }

    /// Read a single card by id, or `None` if not present locally yet.
    pub async fn get_message(&self, id: &str) -> Result<Option<MessageCard>> {
        let entry = self.doc.get_one(Query::key_exact(msg_key(id))).await?;
        match entry {
            Some(entry) => Ok(Some(self.decode_entry(&entry).await?)),
            None => Ok(None),
        }
    }

    /// List every card currently in the local replica, newest-created first.
    pub async fn list_messages(&self) -> Result<Vec<MessageCard>> {
        let stream = self.doc.get_many(Query::key_prefix("msg/")).await?;
        tokio::pin!(stream);
        let mut cards = Vec::new();
        while let Some(entry) = stream.next().await {
            let entry = entry?;
            cards.push(self.decode_entry::<MessageCard>(&entry).await?);
        }
        cards.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        Ok(cards)
    }

    // ---- state (state/<id>, multi-writer LWW) -----------------------------

    /// Write a card's mutable state. Each device writes under its own author,
    /// so reads must reconcile via [`MessageState::wins_over`] — see
    /// [`Inbox::get_state`].
    pub async fn set_state(&self, state: &MessageState) -> Result<()> {
        let value = serde_json::to_vec(state).context("serialize MessageState")?;
        self.doc
            .set_bytes(self.author, state_key(&state.msg_id), value)
            .await
            .context("write state entry")?;
        Ok(())
    }

    /// Read a card's converged state. iroh-docs keeps the latest entry *per
    /// author*; we fold those with our own ts+device LWW so the answer is the
    /// same on every device regardless of sync order.
    pub async fn get_state(&self, id: &str) -> Result<Option<MessageState>> {
        let stream = self.doc.get_many(Query::key_exact(state_key(id))).await?;
        tokio::pin!(stream);
        let mut winner: Option<MessageState> = None;
        while let Some(entry) = stream.next().await {
            let entry = entry?;
            let candidate: MessageState = self.decode_entry(&entry).await?;
            match &winner {
                Some(current) if !candidate.wins_over(current) => {}
                _ => winner = Some(candidate),
            }
        }
        Ok(winner)
    }

    /// Convenience: dismiss a card globally (`status = dismissed`,
    /// `action_name = "dismiss"`), stamped with this device and the current time.
    pub async fn dismiss(&self, id: &str) -> Result<()> {
        self.set_state(&MessageState {
            msg_id: id.to_string(),
            status: Status::Dismissed,
            action_name: Some("dismiss".into()),
            action_context: None,
            device: self.device.clone(),
            ts: now_ms(),
        })
        .await
    }

    // ---- data model (data/<id>/<bindPath>, multi-writer LWW) --------------

    /// Write a single A2UI data-model binding value. `bind_path` is a JSON
    /// Pointer like `/contact/email`. LWW-converges per bind path.
    pub async fn set_data(
        &self,
        id: &str,
        bind_path: &str,
        value: &serde_json::Value,
    ) -> Result<()> {
        let bytes = serde_json::to_vec(value).context("serialize data value")?;
        self.doc
            .set_bytes(self.author, data_key(id, bind_path), bytes)
            .await
            .context("write data entry")?;
        Ok(())
    }

    /// Read a bound data-model value, latest-writer-wins across devices.
    pub async fn get_data(&self, id: &str, bind_path: &str) -> Result<Option<serde_json::Value>> {
        let query = Query::single_latest_per_key().key_exact(data_key(id, bind_path));
        match self.doc.get_one(query).await? {
            Some(entry) => Ok(Some(self.decode_entry(&entry).await?)),
            None => Ok(None),
        }
    }

    // ---- sync / lifecycle -------------------------------------------------

    /// Subscribe to live document events (inserts, content-ready, neighbor
    /// up/down). Callers watch this to refresh their UI on remote changes.
    pub async fn subscribe(
        &self,
    ) -> Result<impl futures_lite::Stream<Item = Result<LiveEvent>> + Unpin + use<>> {
        let stream = self.doc.subscribe().await?;
        Ok(stream.map(|res| res.map_err(anyhow::Error::from)))
    }

    /// Gracefully shut the node down.
    pub async fn shutdown(self) -> Result<()> {
        self.router.shutdown().await.context("router shutdown")?;
        Ok(())
    }

    // ---- internals --------------------------------------------------------

    /// Pull an entry's content out of the blobs store and JSON-decode it.
    async fn decode_entry<T: serde::de::DeserializeOwned>(&self, entry: &Entry) -> Result<T> {
        let bytes = self
            .blobs
            .get_bytes(entry.content_hash())
            .await
            .context("read entry content from blobs")?;
        serde_json::from_slice(&bytes).context("deserialize entry content")
    }
}

/// Build the iroh node: bind the blobs, gossip and docs protocols onto a router
/// over `endpoint`, exactly as iroh-docs' own `examples/setup.rs` does.
async fn spawn_node(endpoint: Endpoint) -> Result<(Router, BlobsStore, Docs)> {
    let blobs = MemStore::new();
    let gossip = Gossip::builder().spawn(endpoint.clone());
    let docs = Docs::memory()
        .spawn(endpoint.clone(), (*blobs).clone(), gossip.clone())
        .await
        .context("spawn docs protocol")?;

    let router = Router::builder(endpoint)
        .accept(iroh_blobs::ALPN, BlobsProtocol::new(&blobs, None))
        .accept(iroh_gossip::ALPN, gossip)
        .accept(iroh_docs::ALPN, docs.clone())
        .spawn();

    Ok((router, (*blobs).clone(), docs))
}

/// Current unix time in milliseconds, for [`MessageState::ts`].
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_millis() as u64
}
