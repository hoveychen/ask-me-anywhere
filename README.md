# ask-me-anywhere

> Multi-device actionable message-card network · global dismiss/state sync · pure P2P, no server · A2UI rendering

**ask-me-anywhere** (`ama`) pushes rich, interactive notification cards to all of
*your own* devices and keeps them in sync — dismiss a card on your phone and it
disappears on your desktop; fill in a form field on one device and the value
shows up on the others. There is **no central server that stores your
messages**: your inbox is a multi-writer CRDT document replicated peer-to-peer
across your devices, and message content never lives on any third party.

Cards are [A2UI](https://github.com/google/A2UI) message trees, so a card is not
limited to "title + button" — any rich UI renders correctly, and its data model
two-way-syncs across every replica.

---

## Table of contents

- [How it works](#how-it-works)
- [Features](#features)
- [Repository layout](#repository-layout)
- [Quick start (CLI)](#quick-start-cli)
- [CLI reference](#cli-reference)
- [Pushing cards from scripts & webhooks](#pushing-cards-from-scripts--webhooks)
- [Self-hosting the infrastructure](#self-hosting-the-infrastructure)
- [Apps](#apps)
- [Building from source](#building-from-source)
- [Documentation](#documentation)
- [Status](#status)
- [License](#license)

---

## How it works

Your inbox is modeled as **one multi-writer CRDT document**
([iroh-docs](https://docs.rs/iroh-docs)). Every device you own holds a full
replica and is a reader *and* writer. Every feature collapses to a read/write
against that document:

| Action | Under the hood |
|---|---|
| Push a message | write `msg/<id>` (payload = A2UI message tree) |
| Global dismiss | write `state/<id>/status` (last-writer-wins) |
| Tap an action | write `state/<id>/action` (A2UI `userAction` result) |
| Collaborative form input | write `data/<id>/<bindPath>` (A2UI data-model field, LWW) |
| Multi-device consistency | iroh-docs gossip (live) + sync (catch-up); CRDT converges |

Devices discover each other over the **iroh DHT** (BitTorrent-style, no central
directory) and connect with **QUIC, end-to-end encrypted, direct-first**. When
two devices are behind symmetric NAT and can't hole-punch, traffic falls back
through a **self-hosted iroh relay that only dumb-forwards encrypted bytes — it
never reads or stores message content**.

```
   ┌─────────────┐        ┌─────────────┐
   │  Desktop    │◄──────►│  Android    │   direct-first (QUIC, E2E encrypted)
   │ (Flutter)   │        │ (Flutter +  │
   └──────┬──────┘        └──────┬──────┘  foreground service runs P2P
          │   NAT fallback only  │
          └────────►┌──────────┐◄┘
                    │  relay   │   dumb-forwards encrypted traffic;
                    │ (yours)  │   reads nothing, stores nothing
                    └──────────┘
   discovery: iroh DHT (mainline / pkarr) — no central directory
```

For the full design and trade-offs, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Features

- **Pure P2P, zero-persistence** — messages live only on your devices; no server
  owns your inbox.
- **Global state sync** — dismiss / action / form input converge across all
  devices via CRDT.
- **A2UI cards** — arbitrary rich UI, not just title + button, with two-way data
  binding.
- **End-to-end encrypted** — iroh QUIC transport; the relay only ever sees
  ciphertext.
- **Device pairing by ticket / QR** — a new device joins by scanning a pairing
  ticket, then syncs the full inbox.
- **HTTP injection bridge** — a webhook server (`ama serve`) lets scripts,
  GitHub, Linear, etc. `POST` cards into your inbox.

## Repository layout

```
crates/
  core/            ama-core — Rust core: iroh-doc inbox, model, net (P2P engine)
  cli/             ama-cli  — the `ama` binary (create/join/send/serve)
flutter_app/       Flutter app (Desktop + Android; iOS scaffolding, deferred)
  rust/            flutter_rust_bridge binding to ama-core
deploy/
  relay/           stand-alone iroh-relay recipe (Docker Compose / systemd, any VPS)
  relay-muvee/     iroh-relay for the Muvee PaaS  ← powers relay.muveeai.com
  webhook/         ama serve webhook bridge for the Muvee PaaS ← powers webhook.muveeai.com
docs/              MkDocs site (bilingual: user / integrator / operator guides)
scripts/           demo helpers + sample GitHub PR payload
ARCHITECTURE.md    full design doc (zh)
```

## Quick start (CLI)

Build the `ama` binary and pair two nodes on one machine to see cards sync:

```bash
# Build
cargo build -p ama-cli --release   # binary at target/release/ama

# Terminal A — create an inbox, print a pairing ticket
ama create --name desktop
# → prints a ticket string (and a QR code)

# Terminal B — join that inbox from the ticket
ama join --name laptop <TICKET>

# Push a card into the inbox (one-shot) — appears on every paired node
echo '{"summary":"hello from a script"}' | ama send --ticket <TICKET> --card-file -
```

By default nodes use the project's relay (`relay.muveeai.com`). Override with
`--relay <url>` for your own relay, `--relay n0` for n0's public pool, or
`--relay disabled` for direct/LAN-only.

## CLI reference

| Command | Purpose |
|---|---|
| `ama create` | Create a fresh inbox and print a pairing ticket. `--data-dir` persists the inbox + identity so reruns reopen it. |
| `ama join <ticket>` | Join an existing inbox from a ticket. `--data-dir` persists the join across restarts. |
| `ama send --ticket <t> --card-file <f\|->` | One-shot: join, push a card (JSON file or stdin), hold briefly for gossip delivery, exit. |
| `ama serve` | Long-running webhook bridge: join once, listen on HTTP, forward `POST /push` and `POST /github/pr` as cards. |

Common flags: `--name <label>` (device label stamped on writes), `--relay <url\|n0\|disabled>`, `--data-dir <path>`.

Run `ama <command> --help` for the full flag list.

### Card JSON shape

```json
{
  "summary": "required — backs the system notification when A2UI can't render",
  "a2ui":    { "...A2UI v0.9 message tree...": "optional; defaults to {}" },
  "source":  "optional label; defaults to the CLI --name"
}
```

## Pushing cards from scripts & webhooks

`ama serve` is a single-tenant HTTP bridge in front of one inbox:

| Route | Auth | Purpose |
|---|---|---|
| `GET /healthz` | open | liveness probe |
| `POST /push` | bearer token | inject a card (same JSON shape as `ama send`) |
| `POST /github/pr` | bearer token | accept a GitHub `pull_request` webhook and render it as a card |

```bash
# Run the bridge locally
ama serve --ticket <TICKET> --bind 127.0.0.1:8080 --token "$(openssl rand -hex 32)"

# Push a card over HTTP
curl -X POST http://127.0.0.1:8080/push \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  --data '{"summary":"deploy finished ✅"}'
```

Config for a hosted deployment is read from env (`AMA_TICKET`, `AMA_TOKEN` /
`AMA_TOKEN_FILE`, `AMA_RELAY`, `AMA_NAME`, `AMA_BIND`). See
[deploy/webhook/README.md](deploy/webhook/README.md).

## Self-hosting the infrastructure

Two optional pieces let you run the whole network yourself. **Neither can read
your messages** — the relay only forwards ciphertext, and the webhook bridge
only injects cards into an inbox it was given a ticket for.

| Component | What it does | Recipes |
|---|---|---|
| **iroh relay** | NAT-fallback: dumb-forwards encrypted QUIC when two devices can't connect directly. The default baked into clients is `relay.muveeai.com`. | [deploy/relay/](deploy/relay/) (stand-alone VPS: Docker Compose / systemd) · [deploy/relay-muvee/](deploy/relay-muvee/) (Muvee PaaS) |
| **webhook bridge** | Runs `ama serve` so external sources (scripts, GitHub, …) can `POST` cards into your inbox over HTTP. | [deploy/webhook/](deploy/webhook/) (Muvee PaaS) |

> The `relay-muvee` and `webhook` recipes target the maintainer's
> [Muvee](https://muveeai.com) PaaS (they front the service on
> `relay.muveeai.com` / `webhook.muveeai.com` via Traefik + hosted git). For
> your own host, `deploy/relay/` is the generic, provider-agnostic path.

## Apps

The Flutter app is one codebase for Desktop and Android (iOS scaffolding exists
but is deferred — see [ARCHITECTURE.md](ARCHITECTURE.md) §1). It embeds
`ama-core` via [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/)
and renders cards with the A2UI Flutter renderer, plus native notifications and
QR pairing. On Android a foreground service keeps the P2P node alive.

Release builds (signed Android APK, signed + notarized macOS DMG) are produced
by [`.github/workflows/release.yml`](.github/workflows/release.yml) and attached
to GitHub Releases.

## Building from source

**Prerequisites:** a recent [Rust toolchain](https://rustup.rs) (edition 2024)
and, for the apps, the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```bash
# Rust core + CLI
cargo build --release
cargo test                       # workspace tests (incl. two-node sync test)

# Flutter app
cd flutter_app
flutter pub get
flutter run                      # or: flutter build apk / flutter build macos
```

## Documentation

Full guides live under [docs/](docs/) (MkDocs, bilingual EN/ZH):

- **User Guide** — install, pair, daily use — [en](docs/user/index.en.md) · [zh](docs/user/index.zh.md)
- **Integrator Guide** — `ama send`, HTTP `/push`, A2UI card schema — [en](docs/integrator/index.en.md) · [zh](docs/integrator/index.zh.md)
- **Operator Guide** — relay / webhook deploy, secret rotation, troubleshooting — [en](docs/ops/index.en.md) · [zh](docs/ops/index.zh.md)

Serve the docs locally with `pip install -r requirements-docs.txt && mkdocs serve`.

## Status

Early / personal project. Core P2P sync, CLI, webhook bridge, relay deploys, and
the Desktop + Android app are in place; iOS background push is out of scope for
now (it requires APNs, which conflicts with the zero-persistence P2P model).

## License

No license file is present yet — all rights reserved by default until one is
added. Open an issue if you'd like to use this.
