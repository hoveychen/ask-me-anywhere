# Operator Guide

ask-me-anywhere has two server-side components you can deploy independently:

| Component | Role | How to deploy |
|---|---|---|
| **iroh-relay** | NAT-traversal fallback (forwards encrypted bytes only, never reads / stores) | VPS / Muvee |
| **ama-webhook** | HTTP ingress that turns external events into A2UI cards and pushes them into your inbox | Muvee (or plain Docker) |

Neither is mandatory. Self-hosting the relay is a data-sovereignty / control choice vs n0's public relays; the webhook is only needed if external sources push cards (you can also use [`ama send`](../integrator/index.md#1-ama-send-one-shot-from-a-script) directly).

---

## 1. Relay deploy {#relay-deploy}

### 1.1 Pick a template

The repo ships two relay deploy templates under `deploy/`:

| Path | Platform | TLS | QUIC fastpath |
|---|---|---|---|
| [`deploy/relay/`](https://github.com/hoveychen/ask-me-anywhere/tree/main/deploy/relay) | Plain VPS (Docker Compose / systemd) | iroh-relay runs its own Let's Encrypt | UDP/7842 |
| [`deploy/relay-muvee/`](https://github.com/hoveychen/ask-me-anywhere/tree/main/deploy/relay-muvee) | Muvee PaaS | Traefik terminates TLS, container runs plain HTTP/8080 | **Not available** — Muvee is HTTP/HTTPS only; QUIC isn't routed, traffic falls back to HTTPS/WS |

For ask-me-anywhere's traffic profile (small infrequent notification cards), the HTTPS/WS fallback is fine. Pick Muvee for the lower ops overhead; pick the plain-VPS template if you have a VPS and care about direct QUIC.

### 1.2 Plain VPS (summary)

Full steps in `deploy/relay/README.md`. Key points:

1. A small VPS (1 vCPU / 512 MB is enough); DNS A/AAAA pointed at it.
2. Open `80/tcp` (ACME challenge), `443/tcp` (HTTPS), `7842/udp` (QUIC).
3. Edit `relay.toml`: fill in `hostname` + `contact` (Let's Encrypt email).
4. `docker compose up -d --build`, or install the systemd unit.
5. Clients connect via `--relay https://relay.your-domain`.

### 1.3 Muvee (summary)

Full steps in `deploy/relay-muvee/README.md`. The key commands:

```bash
muveectl projects create \
  --name iroh-relay \
  --git-source hosted \
  --domain relay \
  --dockerfile Dockerfile \
  --tags relay,iroh,p2p

# Follow the printed instructions to capture PROJECT_ID and the hosted-git URL.
# Push deploy/relay-muvee/{Dockerfile,relay.toml} to that URL.
# Then: muveectl projects deploy PROJECT_ID
```

Clients use `--relay https://relay.<your-muvee-base-domain>`.

### 1.4 Why the relay has no auth

The relay has to be reachable by every device that holds the URL — it's the NAT-fallback channel, not a protected app. ForwardAuth would block legit clients. Access control lives at the iroh layer (only devices with the doc's write ticket can join the inbox); the relay itself forwards encrypted bytes (Architecture §7).

---

## 2. Webhook deploy {#webhook-deploy}

### 2.1 Concept

`ama serve` is a long-running process that joins your inbox as a "virtual device". It exposes:

- `GET /healthz` — open, for liveness probes
- `POST /push` + `POST /github/pr` — both go through a Bearer-token middleware

See the [Integrator Guide](../integrator/index.md#2-ama-serve-long-running-webhook) for the full HTTP API.

### 2.2 Three essential env vars

| Var | Role | Source |
|---|---|---|
| `AMA_TICKET` | Pairing ticket of the inbox to join | A device's Flutter QR screen or `ama create` output |
| `AMA_TOKEN` | Bearer secret | `openssl rand -hex 32` |
| `AMA_RELAY` | Self-hosted relay URL (optional, recommended) | Your relay domain |

`AMA_BIND` is hardcoded to `0.0.0.0:8080` by the Dockerfile — Traefik terminates HTTPS in front.

### 2.3 Deploying on Muvee (end-to-end)

```bash
# 1. Sanity-check the image builds locally. Build context is the repo root
#    because the Dockerfile copies Cargo.toml / Cargo.lock / crates/.
docker build -f deploy/webhook/Dockerfile -t ama-webhook .

# 2. Mint a ticket from a device that's running the inbox. e.g. locally:
cargo run -p ama-cli -- create --name bootstrap \
  --relay https://relay.muveeai.com
# Grab the printed docaaa... — this is AMA_TICKET.
# Keep this 'ama create' process alive until the webhook joins once.

# 3. Generate a token.
openssl rand -hex 32 > token.txt   # AMA_TOKEN

# 4. Create the Muvee project.
muveectl projects create \
  --name ama-webhook \
  --git-source hosted \
  --domain webhook \
  --dockerfile deploy/webhook/Dockerfile \
  --tags webhook,ama,m5
# Capture PROJECT_ID.

# 5. Wire env vars through Muvee secrets. There's no 'env set' subcommand —
#    use 'secrets create' + 'bind-secret --env-var'.
muveectl secrets create --name AMA_TICKET --type password --value "docaaa..."
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TICKET_SECRET_ID> --env-var AMA_TICKET

muveectl secrets create --name AMA_TOKEN  --type password --value "$(cat token.txt)"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TOKEN_SECRET_ID>  --env-var AMA_TOKEN

muveectl secrets create --name AMA_RELAY  --type password --value "https://relay.muveeai.com"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_RELAY_SECRET_ID>  --env-var AMA_RELAY

# 6. Push the source. Hosted-git push needs a PROJECT-SCOPED token (mvt_...),
#    NOT the session token (mvp_...).
PROJECT_TOKEN="$(muveectl tokens create PROJECT_ID --name git-push | awk '/^Token:/{print $2}')"
git push "https://x:${PROJECT_TOKEN}@muveeai.com/git/PROJECT_ID.git" main

# 7. Build & deploy.
muveectl projects deploy PROJECT_ID
muveectl projects logs PROJECT_ID            # build phase
muveectl projects runtime-logs PROJECT_ID --follow  # container coming up
```

A successful start prints:

```
joined inbox <namespace-id>
listening on http://0.0.0.0:8080
```

### 2.4 End-to-end verification

```bash
HOST="https://webhook.<your-muvee-base-domain>"
TOKEN="$(cat token.txt)"

# /healthz is open
curl -i "$HOST/healthz"
# → 200 ok

# /push without auth → 401
curl -i -X POST -H "Content-Type: application/json" \
  --data '{"summary":"ping"}' "$HOST/push"
# → 401

# /push with auth → 200 + id, and a native notification on every paired device
curl -i -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"summary":"hello from prod webhook"}' "$HOST/push"
```

The first successful `/push` fires native notifications on each paired device.

---

## 3. Secret rotation {#secret-rotation}

Muvee's `secrets` subcommands are `create / delete / list` — **no update**. Rotating a value means unbind → delete → create → bind again, and then **deploy (not restart)** so the container picks up the new value.

### 3.1 Rotate the webhook's Bearer token

```bash
PROJECT_ID=<...>
OLD_TOKEN_SECRET_ID=<...>

# 1. Unbind + delete the old secret
muveectl projects unbind-secret $PROJECT_ID $OLD_TOKEN_SECRET_ID
muveectl secrets delete $OLD_TOKEN_SECRET_ID

# 2. Generate a fresh token, create the new secret
NEW_TOKEN="$(openssl rand -hex 32)"
NEW_SECRET_OUT=$(muveectl secrets create --name AMA_TOKEN --type password --value "$NEW_TOKEN")
NEW_SECRET_ID=$(echo "$NEW_SECRET_OUT" | grep -oE "ID: [a-f0-9-]+" | awk '{print $2}')

# 3. Bind again as the env var
muveectl projects bind-secret $PROJECT_ID --secret-id "$NEW_SECRET_ID" --env-var AMA_TOKEN

# 4. **Important: deploy, NOT restart**
#    restart only re-execs the container with the old env;
#    deploy re-evaluates the secret bindings.
muveectl projects deploy $PROJECT_ID
```

After the deploy, the old token is dead. If you have clients still using it, give them the new one BEFORE you deploy.

### 3.2 Rotate the inbox ticket

The ticket is more sensitive than the token — it grants write access to the doc. Rotate when:

- The ticket leaks (same reasoning as the token).
- You want to switch the webhook to a fresh inbox (data partitioning).

Steps: same as §3.1, with `AMA_TOKEN` → `AMA_TICKET`. Mint a fresh ticket:

```bash
cargo run -p ama-cli -- create --name bootstrap --relay https://relay.muveeai.com
# Grab the docaaa... line as the new AMA_TICKET
```

Caveat: rotating the ticket = switching the doc namespace. **Cards in the old doc do NOT migrate.** Devices need to join the new ticket too.

---

## 4. Monitoring {#monitoring}

### 4.1 Container state

```bash
muveectl projects describe PROJECT_ID
```

Look at:

| Field | Healthy | Unhealthy |
|---|---|---|
| `Status` | `running` | `exited` / `restarting` |
| `Exit Code` | `0` (or the last clean exit when running) | non-zero → check runtime-logs |
| `Restart Count` | occasional 1-2 is OK | climbing → process crashing / OOM, check events |

### 4.2 Logs

```bash
muveectl projects logs PROJECT_ID            # build-phase docker build/run logs
muveectl projects runtime-logs PROJECT_ID --follow   # container stdout/stderr
muveectl projects events PROJECT_ID --follow         # Muvee platform events (deploy / restart / OOM)
```

Typical healthy runtime-logs:

```
joined inbox 162faaa…
listening on http://0.0.0.0:8080
/push -> [eee2fdfc-…] hello from remote curl
```

`failed closing path err=MultipathNotNegotiated` is a benign quinn close-path WARN — ignore.

### 4.3 Health probe

`GET /healthz` is open, cheap, doesn't touch the inbox — perfect for:

- Muvee Traefik health checks
- Cloudflare / external uptime probes
- k8s liveness/readiness

---

## 5. Troubleshooting {#troubleshooting}

### 5.1 Webhook won't start

`muveectl projects logs PROJECT_ID` for the build phase. Most common: a sed that nukes the entire `members = [...]` line during the workspace prune (see [chore commit 86bbf4b](https://github.com/hoveychen/ask-me-anywhere/commit/86bbf4b)) or a stale Cargo.lock.

### 5.2 `/push` returns 401

- Token typo? Echo `"Authorization: Bearer $TOKEN"` and double-check.
- Secret actually reaching the container? `muveectl projects env PROJECT_ID --raw` (note: `--raw` shows values plain).
- Just rotated the token? Used restart instead of deploy → old env still loaded; see §3.1.

### 5.3 `/push` returns 200 but no device sees the card

Most common cause: **the ticket in `AMA_TICKET` is unreachable**. Symptom in the webhook's own logs:

```
WARN gossip: dial failed: timed out peer=...
WARN sync: sync failed origin=Connect(DirectJoin) err=Failed to establish connection
```

Root cause: `ama create` printed the ticket before its iroh endpoint registered with the relay, so the ticket's embedded reachability info points at a node with no relay URL. Fixed in [chore commit 86bbf4b](https://github.com/hoveychen/ask-me-anywhere/commit/86bbf4b) — `ama create` now waits for the relay before printing.

> If your deployed image predates that commit, rebuild + redeploy.

Other causes:

- The "bootstrap peer" (the original `ama create` process) for the inbox died, and no other alive peer has registered its address in the swarm metadata. **A long-lived peer somewhere is required** — keep one device's app running, or run a persistent `ama create` on a VPS.

### 5.4 Devices not syncing

- Both online? Test: dismiss a card on one, watch the other update within seconds.
- Relay reachable? Mac: the `flutter run` log shows `home is now relay https://...`. Android: `adb logcat | grep relay`.
- Firewall? On Android, disable VPN / corporate proxy and retry.
- Old ticket replaced by a server-side rotation → devices need to join the new ticket.

### 5.5 Notification didn't pop

See the [User Guide FAQ](../user/index.md#3-faq).

### 5.6 SSE / `/ask` long connections get cut (M6)

`GET /events` and `POST /ask` are **long HTTP connections** — middleboxes (Cloudflare / Traefik / k8s ingress) typically reap them around 100s of idle. Symptom: client gets EOF / 504 unexpectedly, but `ama serve` shows no error and the card landed.

Diagnose + work around:

- SSE already injects a 15s `: keep-alive` comment. Cloudflare and friends honour it; cuts past that point usually mean a more aggressive proxy in the path.
- Cap `/ask`'s `timeout_secs` at **≤ 90 seconds** so the server returns first; on `timed_out: true`, the client should switch to polling `GET /cards/{id}` to wait for a delayed answer.
- If the client lib has its own idle timeout (reqwest defaults to 30s; curl has none), bump it or remove it.
- If the proxy is yours, set `proxy_read_timeout` / `read_timeout` to ≥ 1.5× the longest expected `timeout_secs`.

---

## 6. Security notes {#security}

- **The relay needs no auth** (§1.4), but if the URL leaks to a malicious party they can use it as a NAT-traversal hop. The traffic is end-to-end encrypted so they don't see content — but **they consume your bandwidth**. If that's a concern, add an IP allowlist or move to a VPN-only setup.
- **The webhook token is a secret-grade asset.** A leak = anyone can push cards into your inbox. Rotation in §3.1.
- **The inbox ticket is MORE sensitive.** A leak = anyone can join your inbox and read every card you've received (and every future card). There's **no kick feature** in the current version — the only remedy is starting fresh (§3.2).
- The relay / webhook containers don't persist data. All state lives in the doc replicas (distributed). Deleting the Muvee project doesn't lose cards — as long as one device with the app is around, the data is there.
