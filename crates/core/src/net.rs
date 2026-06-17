//! Endpoint construction with a configurable relay (ARCHITECTURE.md §5, M2) and
//! a persistent node identity (the persist-store plan).
//!
//! The relay is iroh's NAT-fallback / holepunch-coordination channel — it only
//! dumb-forwards encrypted traffic, it never reads or stores message content.
//! M2 lets a node point at a *self-hosted* relay instead of n0's public ones;
//! address discovery (DHT / pkarr) is left untouched, so only the fallback
//! transport changes.
//!
//! The node's [`SecretKey`] is its long-term identity: it derives the node-id
//! and the pairing ticket this device shares. [`load_or_create_secret_key`]
//! persists it to disk so both stay stable across restarts — without it every
//! relaunch is a brand-new device that already-paired peers must rediscover.

use std::path::Path;

use anyhow::{Context, Result};
use iroh::{endpoint::presets, Endpoint, RelayMap, RelayMode, RelayUrl, SecretKey};

/// The project's self-hosted iroh relay (deploy/relay-muvee). It's the *default*
/// NAT-fallback relay so a paired device is reachable via a stable, known relay
/// rather than n0's public pool — the ticket a device shares carries this relay
/// URL. Address discovery still uses n0 (see [`build_endpoint`]); only the relay
/// fallback changes. Override per command with `--relay <url>` / `n0` / `disabled`.
pub const DEFAULT_RELAY: &str = "https://relay.muveeai.com";

/// Which relay an inbox node should use.
#[derive(Debug, Clone)]
pub enum RelayChoice {
    /// n0's production relays.
    N0,
    /// A single self-hosted relay — the project default ([`DEFAULT_RELAY`]) or
    /// any `--relay <url>`.
    Custom(RelayUrl),
    /// No relay at all; direct connections only (works on the same LAN, fails
    /// behind symmetric NAT).
    Disabled,
}

impl RelayChoice {
    /// The project default: the self-hosted [`DEFAULT_RELAY`].
    pub fn default_relay() -> Self {
        // DEFAULT_RELAY is a compile-time constant we control, so a parse failure
        // is a build-time bug, not a runtime input error — assert it.
        RelayChoice::Custom(
            DEFAULT_RELAY
                .parse()
                .expect("DEFAULT_RELAY must be a valid relay url"),
        )
    }

    /// Resolve a `--relay <value>` argument:
    /// - absent → [`DEFAULT_RELAY`] (self-hosted),
    /// - `n0` → n0's public relays,
    /// - `disabled` → no relay (direct/LAN only),
    /// - anything else → that URL.
    pub fn from_url_opt(url: Option<&str>) -> Result<Self> {
        match url {
            None => Ok(RelayChoice::default_relay()),
            Some(s) if s.eq_ignore_ascii_case("n0") => Ok(RelayChoice::N0),
            Some(s) if s.eq_ignore_ascii_case("disabled") => Ok(RelayChoice::Disabled),
            Some(s) => {
                let url: RelayUrl = s.parse().with_context(|| format!("invalid relay url: {s}"))?;
                Ok(RelayChoice::Custom(url))
            }
        }
    }

    fn mode(&self) -> RelayMode {
        match self {
            RelayChoice::N0 => RelayMode::Default,
            RelayChoice::Custom(url) => RelayMode::Custom(RelayMap::from(url.clone())),
            RelayChoice::Disabled => RelayMode::Disabled,
        }
    }
}

/// Load this device's long-term iroh identity from `path`, generating and
/// persisting a fresh key the first time. The file holds the raw 32 secret-key
/// bytes. Keeping the same key across restarts keeps the node-id — and the
/// pairing ticket the device shares — stable, so already-paired peers don't
/// have to rediscover this device every launch.
pub fn load_or_create_secret_key(path: &Path) -> Result<SecretKey> {
    if path.exists() {
        let bytes =
            std::fs::read(path).with_context(|| format!("read secret key {}", path.display()))?;
        let arr: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .with_context(|| format!("secret key {} must be exactly 32 bytes", path.display()))?;
        Ok(SecretKey::from_bytes(&arr))
    } else {
        let key = SecretKey::generate();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create key dir {}", parent.display()))?;
        }
        std::fs::write(path, key.to_bytes())
            .with_context(|| format!("write secret key {}", path.display()))?;
        Ok(key)
    }
}

/// Bind an iroh endpoint using the chosen relay, keeping n0's address discovery
/// so peers can still find each other. When `secret_key` is `Some`, the node
/// adopts that persistent identity; `None` lets iroh generate an ephemeral one
/// (fine for tests / throwaway nodes).
pub async fn build_endpoint(relay: RelayChoice, secret_key: Option<SecretKey>) -> Result<Endpoint> {
    let mut builder = Endpoint::builder(presets::N0).relay_mode(relay.mode());
    if let Some(key) = secret_key {
        builder = builder.secret_key(key);
    }
    builder.bind().await.context("bind endpoint")
}
