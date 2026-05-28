# ask-me-anywhere

> Multi-device actionable message-card network · global dismiss/state sync · pure P2P, no server · A2UI rendering

ask-me-anywhere models "my inbox" as one multi-writer CRDT document
([iroh-docs](https://docs.rs/iroh-docs)) replicated across every device I own. Pushing a message is a single entry write; dismissing is a state flip; form input is a collaborative field write. All operations collapse to reads/writes against that document, and iroh-docs gossip + sync converge the replicas automatically.

The card payload is an [A2UI](https://github.com/google/A2UI) message tree — not just "title + button", any rich UI renders correctly, and its data model two-way-syncs across every replica.

## Pick your perspective

| You are | Start here | Goal |
|---|---|---|
| Installing the app and reading cards on your devices | [User Guide](user/index.md) | Install, pair, daily use |
| Pushing cards into the inbox from a script or webhook | [Integrator Guide](integrator/index.md) | `ama send` CLI, HTTP `/push`, A2UI card schema |
| Operating a self-hosted relay or webhook bridge | [Operator Guide](ops/index.md) | Relay deploy, webhook deploy, secret rotation, troubleshooting |

For the underlying architecture, see [ARCHITECTURE.md](https://github.com/hoveychen/ask-me-anywhere/blob/main/ARCHITECTURE.md) in the repo root.
