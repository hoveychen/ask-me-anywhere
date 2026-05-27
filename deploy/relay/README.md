# Self-hosted iroh-relay (M2)

Run an `iroh-relay` instance on a small VPS so ask-me-anywhere doesn't depend on
n0's public relays. The relay only dumb-forwards encrypted QUIC packets and
helps with NAT holepunching — it never reads or stores any message content
(ARCHITECTURE.md §5 / §7).

## Prerequisites

1. A small VPS (1 vCPU / 512 MB RAM is enough for personal use).
2. A domain or subdomain, e.g. `relay.example.com`, with an **A record**
   (and **AAAA** if you have v6) pointing at the VPS public IP.
3. Open these inbound ports on the VPS firewall / security group:
   - `80/tcp`  — ACME http-01 challenge + captive portal
   - `443/tcp` — relay HTTPS
   - `7842/udp` — relay QUIC
4. Pin the iroh-relay version to **0.98.0** to match the clients
   (`iroh-docs = 0.98`, `iroh-blobs = 0.100`).

## Configure

Edit [`relay.toml`](./relay.toml) and fill in the two placeholders:

- `hostname` → your relay domain (must match the DNS record above).
- `contact` → an email Let's Encrypt can reach.

The defaults pick Let's Encrypt production + standard ports; you usually don't
need to change anything else.

## Deploy — pick one

### A. Docker Compose (recommended)

```bash
# on the VPS, in this deploy/relay/ directory:
docker compose up -d --build
docker compose logs -f relay   # watch ACME issue the cert
```

`network_mode: host` is used so UDP/7842 and the http-01 challenge on :80 work
without per-protocol port-mapping pitfalls. The `relay-certs` volume persists
the issued Let's Encrypt certs across restarts.

### B. systemd (binary install)

```bash
# on the VPS:
cargo install iroh-relay --version 0.98.0 --features server --locked
sudo install -m755 ~/.cargo/bin/iroh-relay /usr/local/bin/iroh-relay
sudo install -Dm644 relay.toml /etc/iroh-relay/relay.toml   # edit placeholders first
sudo cp iroh-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now iroh-relay
sudo journalctl -fu iroh-relay
```

The unit uses `DynamicUser=true` + `StateDirectory=iroh-relay`, so certs land in
`/var/lib/iroh-relay/` under a managed user, and binds privileged ports via
`AmbientCapabilities=CAP_NET_BIND_SERVICE` instead of running as root.

## Verify

1. `curl -fsS https://relay.example.com/` should respond with the relay's
   captive-portal HTML (or at least a valid TLS handshake on 443).
2. Point an `ama` node at it and check the ticket carries your relay URL:
   ```bash
   ama create --name desktop --relay https://relay.example.com
   ```
   The ticket section in the output should encode `relay.example.com`.
3. From a second machine (or different network), join with the ticket:
   ```bash
   ama join --name phone --relay https://relay.example.com <TICKET>
   ```
   Send a card from one side, run `list` / `dismiss` on the other — they should
   sync within a few seconds.

If step 3 fails, check the relay logs (`docker compose logs relay` /
`journalctl -u iroh-relay`) for ACME issuance errors (most common: DNS not
propagated, or :80 blocked by firewall).

## Notes

- This relay has **no client allowlist** — anyone with the URL can use it as a
  relay. That's fine for a personal device-pair network but if you ever expose
  the URL publicly, consider adding the `[limits]` block in `relay.toml` (rate
  limiting) or fronting it with auth.
- The relay is stateless beyond its TLS cert cache. Snapshots/backups are
  unnecessary; if the VPS is lost, just re-deploy and the existing nodes will
  reconnect once the new IP resolves.
