# iroh-relay on Muvee

Deploys the iroh-relay to the Muvee PaaS. This is the path actually used for
M2 (the `deploy/relay/` sibling directory contains the generic stand-alone
VPS recipe — Docker Compose / systemd — for non-Muvee hosts).

## How it differs from the stand-alone deploy

| | Stand-alone (`deploy/relay/`) | Muvee (`deploy/relay-muvee/`) |
|---|---|---|
| TLS | iroh-relay does its own Let's Encrypt | Traefik front handles TLS |
| Listen port | 80 / 443 / 7842 | 8080 (HTTP only, Traefik proxies) |
| QUIC fastpath (UDP/7842) | Available | **Not routed** — Muvee is HTTP/HTTPS only; clients use the relay HTTPS/WS fallback instead |
| Cert persistence | `/var/lib/iroh-relay` volume | n/a (Traefik holds certs) |
| Domain | yours (DNS A → VPS) | `<prefix>.<muvee-base-domain>` |

For ask-me-anywhere's traffic profile (small notification cards, infrequent),
the HTTPS/WS fallback is fine. Only deploy via `deploy/relay/` if QUIC fastpath
matters (e.g. high-volume payloads behind very strict NAT).

## Deploy

The build context is just this directory (two files); we use Muvee's hosted
git option so we don't need GitHub.

```bash
# 1. Create the project (server-hosted git, domain "relay", no auth gate).
muveectl projects create \
  --name iroh-relay \
  --git-source hosted \
  --domain relay \
  --dockerfile Dockerfile \
  --description "Self-hosted iroh-relay for ask-me-anywhere (M2)" \
  --tags relay,iroh,p2p

# `projects create` prints the new PROJECT_ID and the hosted-git push URL.
# Capture both.

# 2. Push just this directory as the project's source.
TMP=$(mktemp -d)
cp Dockerfile relay.toml "$TMP/"
( cd "$TMP" && git init -q && git add . \
    && git -c user.email=ci@local -c user.name=ci commit -q -m init \
    && git remote add origin <PUSH_URL_FROM_STEP_1> \
    && git push -u origin HEAD:main )

# 3. Build & deploy.
muveectl projects deploy PROJECT_ID
muveectl projects logs PROJECT_ID            # watch the build
muveectl projects runtime-logs PROJECT_ID -f # watch the relay come up

# 4. Verify (the relay returns an HTTP page on /):
muveectl projects curl PROJECT_ID / -i

# 5. Point an ama node at it (this URL is the built-in default — see below):
cargo run -p ama-cli -- create --name desktop \
  --relay https://relay.<base-domain>
```

The relay URL ends up as `https://<prefix>.<base-domain>` where `<prefix>` is
the `--domain` value above. Run `muveectl projects get PROJECT_ID --json` to
see the resolved domain after creation.

`https://relay.muveeai.com` is the **default** relay baked into the clients
(`ama_core::net::DEFAULT_RELAY`), so `ama create` / the Flutter app use it with
no `--relay` flag. Override per command with `--relay <url>`, or fall back to
n0's public pool with `--relay n0` (or `--relay disabled` for direct/LAN-only).
If this relay is ever down, nodes can't mint a reachable ticket until it's
redeployed (`muveectl projects deploy PROJECT_ID`) — or until they pass
`--relay n0`.

## Why no `--auth-required`

The relay must be openly reachable by every device that holds the URL — it's
the NAT-fallback channel, not a protected app. Adding ForwardAuth would block
legitimate clients. Access control happens at the iroh layer (only devices with
your doc's write ticket can join the inbox); the relay itself just forwards
encrypted bytes (ARCHITECTURE.md §7).
