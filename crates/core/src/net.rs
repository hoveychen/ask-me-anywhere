//! Endpoint construction with a configurable relay (ARCHITECTURE.md §5, M2).
//!
//! The relay is iroh's NAT-fallback / holepunch-coordination channel — it only
//! dumb-forwards encrypted traffic, it never reads or stores message content.
//! M2 lets a node point at a *self-hosted* relay instead of n0's public ones;
//! address discovery (DHT / pkarr) is left untouched, so only the fallback
//! transport changes.

use anyhow::{Context, Result};
use iroh::{endpoint::presets, Endpoint, RelayMap, RelayMode, RelayUrl};

/// Which relay an inbox node should use.
#[derive(Debug, Clone)]
pub enum RelayChoice {
    /// n0's production relays (the iroh default).
    N0,
    /// A single self-hosted relay — M2's own VPS relay.
    Custom(RelayUrl),
    /// No relay at all; direct connections only (works on the same LAN, fails
    /// behind symmetric NAT).
    Disabled,
}

impl RelayChoice {
    /// Parse a `--relay <url>` argument into a choice. An empty/absent value
    /// means [`RelayChoice::N0`].
    pub fn from_url_opt(url: Option<&str>) -> Result<Self> {
        match url {
            None => Ok(RelayChoice::N0),
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

/// Bind an iroh endpoint using the chosen relay, keeping n0's address discovery
/// so peers can still find each other.
pub async fn build_endpoint(relay: RelayChoice) -> Result<Endpoint> {
    Endpoint::builder(presets::N0)
        .relay_mode(relay.mode())
        .bind()
        .await
        .context("bind endpoint")
}
