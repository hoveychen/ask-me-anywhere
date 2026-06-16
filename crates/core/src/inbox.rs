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

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use futures_lite::StreamExt;
use iroh::{protocol::Router, Endpoint};
use iroh_blobs::{api::Store as BlobsStore, store::fs::FsStore, store::mem::MemStore, BlobsProtocol};
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

use crate::model::{
    data_key, msg_key, state_key, status_for_action, MessageCard, MessageState,
};

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
    /// Spawn a node on `endpoint` and create a brand-new inbox document. The
    /// returned inbox is the first replica; share [`Inbox::ticket`] to let other
    /// devices [`Inbox::join`] it.
    ///
    /// When `data_dir` is `Some`, the node uses persistent on-disk stores and
    /// records the new doc's namespace there, so a later [`Inbox::open`] on the
    /// same dir reopens *this* inbox instead of starting empty. `None` keeps
    /// everything in memory (tests / throwaway nodes).
    pub async fn create(
        endpoint: Endpoint,
        device: impl Into<String>,
        data_dir: Option<&Path>,
    ) -> Result<Self> {
        let (router, blobs, docs) = spawn_node(endpoint, data_dir).await?;
        let doc = docs.create().await.context("create inbox doc")?;
        let author = docs.author_default().await.context("default author")?;
        if let Some(dir) = data_dir {
            save_namespace(dir, doc.id())?;
        }
        Ok(Self { router, blobs, doc, author, device: device.into() })
    }

    /// Reopen the persisted inbox stored under `data_dir`, or `Ok(None)` when
    /// this dir has never created/joined one (no saved namespace, or its replica
    /// is missing from the store). The companion to [`Inbox::create`]: an app
    /// boots by trying `open` first and falling back to `create`.
    pub async fn open(
        endpoint: Endpoint,
        device: impl Into<String>,
        data_dir: &Path,
    ) -> Result<Option<Self>> {
        let Some(id) = load_namespace(data_dir)? else {
            return Ok(None);
        };
        let (router, blobs, docs) = spawn_node(endpoint, Some(data_dir)).await?;
        let Some(doc) = docs.open(id).await.context("open persisted inbox doc")? else {
            return Ok(None);
        };
        let author = docs.author_default().await.context("default author")?;
        Ok(Some(Self { router, blobs, doc, author, device: device.into() }))
    }

    /// Whether a persisted inbox already lives under `data_dir` (i.e. a prior
    /// `create`/`join` recorded its namespace there). Lets a caller decide
    /// between [`Inbox::open`] and [`Inbox::create`] *before* binding an
    /// endpoint, so the choice costs no extra node.
    pub fn is_persisted(data_dir: &Path) -> Result<bool> {
        Ok(load_namespace(data_dir)?.is_some())
    }

    /// Spawn a node on `endpoint` and join an existing inbox via a [`DocTicket`]
    /// (the payload of the pairing QR code). Joins automatically start syncing
    /// with the ticket's peers. `data_dir` behaves as in [`Inbox::create`]:
    /// `Some` persists the joined inbox so it survives a restart.
    pub async fn join(
        endpoint: Endpoint,
        ticket: DocTicket,
        device: impl Into<String>,
        data_dir: Option<&Path>,
    ) -> Result<Self> {
        let (router, blobs, docs) = spawn_node(endpoint, data_dir).await?;
        let doc = docs.import(ticket).await.context("import inbox doc from ticket")?;
        let author = docs.author_default().await.context("default author")?;
        if let Some(dir) = data_dir {
            save_namespace(dir, doc.id())?;
        }
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

    /// This inbox's pairing ticket serialized as a string — the payload a new
    /// device renders as a QR code (or pastes) and feeds to [`Inbox::join_ticket`].
    /// Round-trips with [`Inbox::join_ticket`] via `DocTicket`'s `Display`/`FromStr`.
    pub async fn ticket_string(&self) -> Result<String> {
        Ok(self.ticket().await?.to_string())
    }

    /// Join an existing inbox from its serialized [`Inbox::ticket_string`].
    /// Convenience over [`Inbox::join`] that parses the ticket on the way in.
    pub async fn join_ticket(
        endpoint: Endpoint,
        ticket: &str,
        device: impl Into<String>,
        data_dir: Option<&Path>,
    ) -> Result<Self> {
        let ticket: DocTicket = ticket.parse().context("parse doc ticket")?;
        Self::join(endpoint, ticket, device, data_dir).await
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

    /// Record a fired A2UI action against a card, converging its global status:
    /// the `"dismiss"` action name dismisses the card, every other action marks
    /// it actioned (see [`status_for_action`]). Stamped with this device and the
    /// current time so reads reconcile via [`MessageState::wins_over`].
    pub async fn record_action(
        &self,
        id: &str,
        action_name: &str,
        action_context: Option<serde_json::Value>,
    ) -> Result<()> {
        self.set_state(&MessageState {
            msg_id: id.to_string(),
            status: status_for_action(action_name),
            action_name: Some(action_name.to_string()),
            action_context,
            device: self.device.clone(),
            ts: now_ms(),
        })
        .await
    }

    /// Convenience: dismiss a card globally (`status = dismissed`,
    /// `action_name = "dismiss"`), stamped with this device and the current time.
    pub async fn dismiss(&self, id: &str) -> Result<()> {
        self.record_action(id, "dismiss", None).await
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

    /// Read every bound data-model value for a card as a `bind_path → value`
    /// map. Used by the answer-back HTTP read path so a single GET returns
    /// the whole form state.
    pub async fn list_data(
        &self,
        id: &str,
    ) -> Result<std::collections::HashMap<String, serde_json::Value>> {
        // Trailing `/` so card id "abc" does NOT prefix-match "abc-other".
        let prefix = format!("data/{id}/");
        let query = Query::single_latest_per_key().key_prefix(&prefix);
        let stream = self.doc.get_many(query).await?;
        tokio::pin!(stream);
        let mut out = std::collections::HashMap::new();
        while let Some(entry) = stream.next().await {
            let entry = entry?;
            let key = String::from_utf8_lossy(entry.key()).to_string();
            // `key` is `data/<id><bind_path>`; everything after the id-prefix
            // is the bind_path, leading slash included (matches data_key).
            let Some(bind_path) = key.strip_prefix(&format!("data/{id}")) else {
                continue;
            };
            let value: serde_json::Value = self.decode_entry(&entry).await?;
            out.insert(bind_path.to_string(), value);
        }
        Ok(out)
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
///
/// `data_dir = Some(dir)` uses persistent stores (an [`FsStore`] under
/// `dir/blobs` and a persistent docs replica db under `dir/docs`); `None` keeps
/// both in memory. The returned [`BlobsStore`] handle keeps the backing store's
/// actor (and, for `FsStore`, its runtime) alive for the node's lifetime, so we
/// don't need to retain the concrete store wrapper.
async fn spawn_node(
    endpoint: Endpoint,
    data_dir: Option<&Path>,
) -> Result<(Router, BlobsStore, Docs)> {
    let gossip = Gossip::builder().spawn(endpoint.clone());

    let (blobs, docs): (BlobsStore, Docs) = match data_dir {
        Some(dir) => {
            // redb won't create its parent dir, so make both store dirs up front.
            let docs_dir = dir.join("docs");
            std::fs::create_dir_all(&docs_dir)
                .with_context(|| format!("create docs dir {}", docs_dir.display()))?;
            let store = FsStore::load(dir.join("blobs"))
                .await
                .context("load persistent blobs store")?;
            let blobs: BlobsStore = (*store).clone();
            let docs = Docs::persistent(docs_dir)
                .spawn(endpoint.clone(), blobs.clone(), gossip.clone())
                .await
                .context("spawn docs protocol (persistent)")?;
            (blobs, docs)
        }
        None => {
            let store = MemStore::new();
            let blobs: BlobsStore = (*store).clone();
            let docs = Docs::memory()
                .spawn(endpoint.clone(), blobs.clone(), gossip.clone())
                .await
                .context("spawn docs protocol (memory)")?;
            (blobs, docs)
        }
    };

    let router = Router::builder(endpoint)
        .accept(iroh_blobs::ALPN, BlobsProtocol::new(&blobs, None))
        .accept(iroh_gossip::ALPN, gossip)
        .accept(iroh_docs::ALPN, docs.clone())
        .spawn();

    Ok((router, blobs, docs))
}

/// Path of the file recording which doc namespace is *this* data dir's inbox.
/// The persistent docs store can hold many replicas; this single-line file
/// remembers the one [`Inbox::open`] should reopen.
fn namespace_path(data_dir: &Path) -> PathBuf {
    data_dir.join("inbox-namespace")
}

/// Record the inbox's namespace id under `data_dir` (overwrites any prior one —
/// a dir holds exactly one inbox).
fn save_namespace(data_dir: &Path, id: NamespaceId) -> Result<()> {
    std::fs::create_dir_all(data_dir)
        .with_context(|| format!("create data dir {}", data_dir.display()))?;
    let path = namespace_path(data_dir);
    std::fs::write(&path, id.to_string())
        .with_context(|| format!("write inbox namespace {}", path.display()))
}

/// Read the inbox namespace recorded under `data_dir`, or `None` if none has
/// been created/joined here yet.
fn load_namespace(data_dir: &Path) -> Result<Option<NamespaceId>> {
    let path = namespace_path(data_dir);
    if !path.exists() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("read inbox namespace {}", path.display()))?;
    let id: NamespaceId = raw
        .trim()
        .parse()
        .with_context(|| format!("parse inbox namespace from {}", path.display()))?;
    Ok(Some(id))
}

/// Current unix time in milliseconds, for [`MessageState::ts`].
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_millis() as u64
}
