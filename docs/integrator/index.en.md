# Integrator Guide

"Integrating" = hooking an external event source (a script, a CI run, cron, a GitHub/Slack/Linear webhook) into an existing ask-me-anywhere inbox. This is the reference for people writing the glue code.

Two paths:

| Path | Use | Suits |
|---|---|---|
| **A. `ama send` one-shot** | `ama send --ticket … --card-file …` | Scripts / cron / CI steps that push once and exit |
| **B. `ama serve` long-running** | `POST /push` + `POST /github/pr` | Multiple sources, retry-tolerant, needs token auth |

A is the script glue, B is the daemon. Both consume the same [CardInput JSON shape](#cardinput-json), so the "event → A2UI card" transform you write once works on either surface.

## 1. `ama send` — one-shot from a script {#1-ama-send-one-shot-from-a-script}

```bash
ama send \
  --ticket docaaa… \
  --card-file ./card.json \
  [--name script-name] \
  [--relay https://relay.example.com] \
  [--wait-secs 5]
```

| Flag | Default | Meaning |
|---|---|---|
| `--ticket` | (required) | Pairing ticket of the target inbox. Get it from a device's Flutter app or from `ama create`. |
| `--card-file` | (required) | Card JSON path, or `-` to read stdin |
| `--name` | `script` | Fallback `source` field on the card when the JSON omits it |
| `--relay` | n0 public | Self-hosted relay URL |
| `--wait-secs` | 5 | Max seconds to hold the node open after the local push, giving gossip a chance to deliver the entry to at least one peer. Exits earlier on `SyncFinished` |

Exit code: `0` on local push success (even if gossip eventually times out — the local entry is durable and syncs next time the node comes online); non-zero on bad input or node startup failure.

### stdin mode

Good for pipelines:

```bash
curl -s https://api.example.com/event | jq '...' | \
  ama send --ticket "$TICKET" --card-file - --name api-bridge
```

### Caveat: in-memory replica

`ama send` is a one-shot process and its inbox replica is in-memory (`MemStore`). Once the process exits, that replica is gone. Push therefore needs to **gossip to at least one live peer before exit** (`--wait-secs` is that window). If the window is too short and no peer is online, the card is lost. For reliable delivery, use `ama serve` instead.

## 2. `ama serve` — long-running webhook {#2-ama-serve-long-running-webhook}

```bash
ama serve \
  --ticket docaaa… \
  --bind 0.0.0.0:8080 \
  [--name webhook] \
  [--relay https://relay.example.com] \
  [--token <BEARER>] \
  [--token-file ./token.txt]
```

| Flag | Default | Meaning |
|---|---|---|
| `--ticket` | (required) | Pairing ticket; joined once at startup; the same iroh node is reused for the process lifetime |
| `--bind` | `127.0.0.1:8080` | TCP listen address. Production / Docker uses `0.0.0.0:8080` |
| `--name` | `webhook` | Fallback `source` field on incoming cards |
| `--relay` | n0 public | Self-hosted relay URL |
| `--token` | (none) | Inline Bearer token. Required on POST routes. Mutually exclusive with `--token-file` |
| `--token-file` | (none) | Path to a file containing the token (first line, trimmed) |

No token = the server runs **open**; a WARNING fires at startup. Production deployments should **always** set a token.

Every flag has a matching env var (`AMA_TICKET` / `AMA_BIND` / `AMA_NAME` / `AMA_RELAY` / `AMA_TOKEN` / `AMA_TOKEN_FILE`) — easier than flags in a Dockerfile.

### 2.1 Routes

| Method | Path | Auth | Purpose | Response |
|---|---|---|---|---|
| GET | `/healthz` | open | liveness probe | `200 ok` |
| POST | `/push` | Bearer | push a card (fire and forget) | `200 {"id":"<uuid>"}` |
| POST | `/github/pr` | Bearer | GitHub PR webhook adapter | `200 {"id":"<uuid>","ignored":bool}` |
| POST | `/ask` | Bearer | push **+ block for the answer** (see §3) | `200 {"id","timed_out","state","data"}` |
| GET | `/cards/{id}` | Bearer | full card snapshot (see §3) | `200 {"card","state","data"}` or `404` |
| GET | `/cards/{id}/state` | Bearer | MessageState only | `200 {...}` or `404` |
| GET | `/cards/{id}/data/{*path}` | Bearer | single A2UI bindPath value | `200 <value>` or `404` |
| GET | `/events?card_id=<id>` | Bearer | **live SSE stream** (see §3) | `text/event-stream` |

`/healthz` is unauthed — point Traefik / Muvee / k8s liveness probes here. Other routes go through middleware: no token → `401 unauthorized`, wrong token → also 401. JSON parse failure → `422 Unprocessable Entity` (axum default). Read routes that target an id / state / bindPath that was never written return `404 not found`.

### 2.2 `POST /push` — generic

Body = CardInput JSON:

```bash
curl -X POST https://webhook.example.com/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "summary": "build #142 failed",
    "a2ui": [
      {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
      {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
        {"id":"root","component":"Column","children":["msg"]},
        {"id":"msg","component":"Text","text":"main → red"}
      ]}}
    ],
    "source": "ci"
  }'
```

Response:

```json
{ "id": "8e33d6f1-c5ed-492b-9262-6bfc82ecf692" }
```

`id` is a freshly-minted UUID you can use to reference the card later (`/get` REPL command, Flutter detail-page deep links, etc.).

### 2.3 `POST /github/pr` — GitHub adapter

Takes a GitHub Webhooks `pull_request` payload as-is. GitHub sends a large JSON; the adapter reads only `action / number / pull_request.{title, body, html_url, user.login} / repository.full_name` and ignores the rest (serde defaults to `deny_unknown_fields = false`).

Actionable actions: `opened` / `reopened` / `ready_for_review`. Everything else (`closed`, `synchronize`, `labeled`, …) returns `200 {"ignored":true}` and writes nothing, so GitHub's at-least-once delivery doesn't spam the inbox.

When actionable, the constructed card looks like:

```text
summary = "[org/repo#42] Title (by @login)"
a2ui    = a message array: createSurface + updateComponents, where root is a Column whose children are Text(summary), Text(body truncated to 280 chars), and a Button (its child points to a Text("Open PR"), action.event.name="open_url", context={url: html_url})
source  = "<--name>/github"   # e.g. "webhook/github"
```

Concretely:

```json
[
  {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
  {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
    {"id":"root","component":"Column","children":["title","body","open"]},
    {"id":"title","component":"Text","text":"[org/repo#42] Title (by @login)","variant":"h4"},
    {"id":"body","component":"Text","text":"<body truncated to 280 chars>"},
    {"id":"open","component":"Button","variant":"primary","child":"openText","action":{"event":{"name":"open_url","context":{"url":"<html_url>"}}}},
    {"id":"openText","component":"Text","text":"Open PR"}
  ]}}
]
```

#### GitHub-side setup

Repo Settings → Webhooks → Add webhook:

- Payload URL: `https://webhook.example.com/github/pr`
- Content type: `application/json`
- Events: only *Pull requests*
- Secret: leave blank (we use Bearer auth, not HMAC)

GitHub doesn't natively support **custom Authorization headers**, so wiring it up requires either fronting the adapter with a small proxy (Cloudflare Worker, …) that injects `Authorization: Bearer $TOKEN`, or extending `auth_middleware` to verify `X-Hub-Signature-256` HMAC instead (TODO).

## 3. Reading the answer back {#answer-back}

A2UI is only useful if you can also get the user's reply out — which button they tapped, what they typed. The CRDT already carries that (it's written to `state/<id>` and `data/<id>/<bindPath>` by the Flutter renderer); M6 exposes it over HTTP three different ways:

| Shape | Route | Use when |
|---|---|---|
| **A. Polling** | `GET /cards/{id}` family | cron / GH Actions / one-shot scripts; second-scale latency is fine |
| **B. Live SSE stream** | `GET /events?card_id=<id>` | Long-running integrators that want immediate signals |
| **D. Single blocking ask** | `POST /ask` | "Ask once and grab the reply"; the simplest client code |

(C — outbound webhook callback — is deliberately not implemented. Integrators are typically client-side scripts that have no HTTP receiver of their own.)

### 3.1 A: Polling

```bash
TOKEN="$(cat .ama-token)"
HOST="https://webhook.example.com"

# 1. Push, capture the id
ID=$(curl -fsSL -X POST "$HOST/push" \
       -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       --data '{"summary":"approve PR #42?"}' | jq -r .id)

# 2. Poll until status != unread
while :; do
  RESP=$(curl -fsSL "$HOST/cards/$ID/state" \
           -H "Authorization: Bearer $TOKEN")
  STATUS=$(echo "$RESP" | jq -r .status)
  [ "$STATUS" = "actioned" ] || [ "$STATUS" = "dismissed" ] && break
  sleep 2
done

# 3. Pull the full snapshot (state + all bound data)
curl -fsSL "$HOST/cards/$ID" -H "Authorization: Bearer $TOKEN"
```

`GET /cards/{id}` returns:
```json
{
  "card":  { "id", "summary", "a2ui", "source", "created_at" },
  "state": { "status", "action_name", "action_context", "device", "ts" } | null,
  "data":  { "/note": "...", "/score": 7, "/contact/email": "..." }
}
```

`state == null` when the user hasn't touched the card. A never-pushed id → 404 on the whole route.

### 3.2 B: Live SSE stream

```bash
# curl -N keeps the connection unbuffered so each event prints immediately
curl -N "$HOST/events?card_id=$ID" \
  -H "Authorization: Bearer $TOKEN"
```

Event stream:
```text
event: state
data: {"msg_id":"<id>","status":"actioned","action_name":"approve","action_context":{"by":"alice"},"device":"phone","ts":1730...}

event: data
data: {"bind_path":"/note","value":"looks good"}

: keep-alive   # comment every 15s so middleboxes don't reap the connection
```

`card_id` is a **required** query — the handler refuses to broadcast every state/data write on the inbox by default (leaks unrelated cards). When the client disconnects, the server-side subscription is dropped automatically.

On connect the stream **replays a snapshot** — the card's current state (if any) and every bound data value, as the first `state` / `data` events — before switching to live deltas. The subscription is taken *before* the snapshot read, so a write landing in between is also delivered live (state/data are LWW, so the duplicate is idempotent). This means you do **not** need the old "GET `/cards/{id}` then attach SSE" pattern with its race window — just attach SSE and you get the current values plus everything after. (Replay from an arbitrary timestamp — `?since=<ts>` — is not implemented.)

### 3.3 D: Blocking /ask (single step)

```bash
curl -fsSL -X POST "$HOST/ask" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "summary":"approve PR #42?",
    "a2ui": { ... },
    "timeout_secs": 30
  }'
```

Response (user tapped approve):
```json
{
  "id": "8e33...",
  "timed_out": false,
  "state": { "status":"actioned", "action_name":"approve", "action_context":{...}, "device":"phone", "ts":... },
  "data": { "/note":"..." }
}
```

Response (timed out):
```json
{ "id": "8e33...", "timed_out": true }
```

`timeout_secs` defaults to 60 and is hard-capped at 600 server-side. **The practical ceiling in cloud deployments is set by the front-proxy**: Cloudflare / Traefik / k8s ingress typically reap idle HTTP connections around 100s, so use `timeout_secs <= 90` to be safe. Past the timeout, fall back to A (GET `/cards/{id}` with the returned id).

What if the connection drops while `/ask` is blocking? The card is already pushed and durable on the inbox replica — but **the client never sees the id** (the response hadn't come back), so the request is unsafe to retry. For unreliable links, prefer the `/push` + polling/SSE combo.

## 4. CardInput JSON {#cardinput-json}

Both `/push` and `ama send --card-file` consume the same shape:

```json
{
  "summary": "Title shown in the notification (REQUIRED)",
  "a2ui":   [ ... A2UI message array, optional ... ],
  "source": "where this card came from (optional)"
}
```

| Field | Type | Required | Default | Notes |
|---|---|---|---|---|
| `summary` | string | yes | — | System notification + list summary text. Keep it short (~60 chars). |
| `a2ui` | array | no | `[]` | A2UI message array (wire format in §5). With `[]`, the Flutter end shows a summary-only card. See §5. |
| `source` | string | no | `--name` value (`script` / `webhook`) | Marks the card's origin. Free-form (`"github"`, `"linear"`, `"ci"`); syncs to every replica. |

`id` and `created_at` are minted by `ama` — don't pass them in JSON (they're ignored — `id` is a fresh UUIDv4, `created_at` is ms epoch).

### Validation

Missing `summary` → axum parse failure → `422` (the response body names the missing field). All other fields are optional. The `a2ui` field is not internally schema-checked — a malformed message array renders as a fallback in the Flutter renderer.

## 5. A2UI card templates

A2UI v0.9 is Google's open spec; ask-me-anywhere renders it via the `genui` Flutter SDK. `genui` accepts only the **message-array** wire format: `a2ui` is a JSON array of messages (`createSurface` / `updateDataModel` / `updateComponents`). Components are **flat objects** with `id` + `component` string fields, referenced by id from a parent's `children` array. Bindings use `value:{path}` (where `path` is a JSON-Pointer string); buttons use a `child` Text ref + `action.event.name`. The full component catalog lives in the [A2UI spec](https://github.com/google/A2UI/tree/main/specification/v0_9). Common templates below.

### 5.1 Text-only

```json
{
  "summary": "deploy succeeded",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["msg"]},
      {"id":"msg","component":"Text","text":"main → production · build #142"}
    ]}}
  ]
}
```

### 5.2 Link button

```json
{
  "summary": "PR review requested",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["title","body","open"]},
      {"id":"title","component":"Text","text":"Review needed: foo refactor"},
      {"id":"body","component":"Text","text":"Updates the BarService trait to async; ~200 LOC."},
      {"id":"open","component":"Button","variant":"primary","child":"openText","action":{"event":{"name":"open_url","context":{"url":"https://github.com/acme/widget/pull/42"}}}},
      {"id":"openText","component":"Text","text":"Open PR"}
    ]}}
  ]
}
```

### 5.3 Approve / deny

`action.event.name == "dismiss"` is the convention for "close this card" (state flips to `Dismissed`); any other action name flips the state to `Actioned` and writes `name + context` into the doc.

```json
{
  "summary": "approve 500 USD expense?",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["q","actions"]},
      {"id":"q","component":"Text","text":"Vendor: WidgetCo · Amount: $500"},
      {"id":"actions","component":"Row","children":["ok","deny"]},
      {"id":"ok","component":"Button","variant":"primary","child":"okText","action":{"event":{"name":"approve"}}},
      {"id":"okText","component":"Text","text":"Approve"},
      {"id":"deny","component":"Button","child":"denyText","action":{"event":{"name":"dismiss"}}},
      {"id":"denyText","component":"Text","text":"Deny"}
    ]}}
  ]
}
```

### 5.4 Form input (two-way data-model sync)

Field values bind to the doc's `data/<msgId>/<bindPath>` keys; concurrent edits LWW-converge across replicas. Declare the binding on the component with `value:{path}`, where `path` is an RFC 6901 JSON Pointer string (e.g. `/note`); every bound field also needs an initial seed in an `updateDataModel` message.

```json
{
  "summary": "rate the build",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/score","value":7}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/note","value":""}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["q","score","note","submit"]},
      {"id":"q","component":"Text","text":"How was deployment #142?"},
      {"id":"score","component":"Slider","min":0,"max":10,"value":{"path":"/score"}},
      {"id":"note","component":"TextField","label":"Any notes?","value":{"path":"/note"}},
      {"id":"submit","component":"Button","variant":"primary","child":"submitText","action":{"event":{"name":"submit"}}},
      {"id":"submitText","component":"Text","text":"Submit"}
    ]}}
  ]
}
```

On submit, the A2UI renderer fires the action, which writes `state/<msgId>` + `data/<msgId>/score` + `data/<msgId>/note`. Every replica sees the converged value within seconds.

### 5.5 AmaChoice — AMA's custom component (option description / preview / Other)

The basic catalog's `ChoicePicker` options carry only `{label, value}`. AMA extends the catalog with a custom component, **`AmaChoice`** (still A2UI — an agent references it by component name; the catalog just grew), to match Claude Code's AskUserQuestion fidelity. Fields:

| Field | Type | Meaning |
|---|---|---|
| `label` | string | Heading above the options |
| `multiple` | bool | `true` = multi-select (checkboxes); `false`/omitted = single (radios) |
| `value` | `{path}` | Bound path for the selection (always a list; single-select is a one-element list) |
| `other` | `{path}` | Optional. When set, shows an Other text field that is **mutually exclusive** with the options (pick an option → Other clears; type Other → selection clears) |
| `options` | array | `[{label, value, description?, preview?}]`. In single-select, choosing an option that has a `preview` shows that preview panel below |

```json
{
  "summary": "deploy target?",
  "a2ui": [
    {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json"}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/env","value":[]}},
    {"version":"v0.9","updateDataModel":{"surfaceId":"card","path":"/envOther","value":""}},
    {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
      {"id":"root","component":"Column","children":["pick","ok"]},
      {"id":"pick","component":"AmaChoice","label":"Target","value":{"path":"/env"},"other":{"path":"/envOther"},
       "options":[
         {"label":"Production","value":"prod","description":"Live traffic","preview":"prod.example.com · irreversible"},
         {"label":"Staging","value":"staging","description":"Pre-prod mirror"}
       ]},
      {"id":"ok","component":"Button","variant":"primary","child":"okt","action":{"event":{"name":"confirm"}}},
      {"id":"okt","component":"Text","text":"Confirm"}
    ]}}
  ]
}
```

The reply lands in `data/<id>/env` (the option, a list) and `data/<id>/envOther` (the Other text) — mutually exclusive, only one is non-empty.

### 5.6 Client functions: gating and actions

A2UI's `checks` (component-enabled conditions) and `action.functionCall` (button calls) can reference host-registered client functions. AMA registers three:

| Function | Used in | Effect |
|---|---|---|
| `allAnswered` | `checks.condition` | True only when every argument is answered (non-empty list / non-blank string / non-null) |
| `anyAnswered` | `checks.condition` | True when any argument is answered (for "option OR Other") |
| `setData` | `action.functionCall` | Writes `args.value` into the `args.path` data path (button-driven state, e.g. switching tabs) |

```json
"checks":[{"message":"answer first","condition":{"call":"allAnswered","args":{"a":{"path":"/env"},"b":{"path":"/note"}}}}]
```

A check's `condition` true → component enabled; any check false → disabled. **Note**: genui treats "non-null" as true (an empty list `[]` counts), so test "unanswered" with `allAnswered`/`anyAnswered`, never a bare `{path}`. The `setData` action: `"action":{"functionCall":{"call":"setData","args":{"path":"/step","value":1}}}`.

### 5.7 Multi-question wizard (Tabs, progressive Next/Confirm)

To ask several questions on one card: bind `Tabs`' `activeTab` to `/step`, one question per tab. Each non-final tab carries a **Next** button — its `action` uses `setData` to write `/step` to the next index (switching the tab), and its `checks` use `anyAnswered` to gate it (you can only advance once the current question is answered). The last tab carries **Confirm** (an `event` action; `checks` use `allAnswered` wrapping `anyAnswered` to require every question). The tab headers themselves also navigate. All pure A2UI, pushable from anywhere.

Key point: Next/Back are `setData` (they only write data, `status` stays `Unread`), so they do **not** end a `/ask` wait; only Confirm's `event`→`recordAction` flips the state to `Actioned` and lets `/ask` return. The step-through wizard composes naturally with synchronous ask-and-wait.

## 6. Language examples

### 6.1 Bash / curl

```bash
TOKEN="$(cat .ama-token)"
HOST="https://webhook.example.com"
curl -fsSL -X POST "$HOST/push" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data @./card.json
```

### 6.2 Python

Push then block on the answer — the simplest "ask, get answer" loop:

```python
import os, requests

TOKEN = os.environ["AMA_TOKEN"]
HOST  = os.environ["AMA_HOST"]   # https://webhook.example.com

r = requests.post(
    f"{HOST}/ask",
    headers={"Authorization": f"Bearer {TOKEN}"},
    json={
        "summary": "deploy build #142?",
        "a2ui": [
            {"version": "v0.9", "createSurface": {
                "surfaceId": "card",
                "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json"}},
            {"version": "v0.9", "updateComponents": {"surfaceId": "card", "components": [
                {"id": "root", "component": "Column", "children": ["q", "ok", "no"]},
                {"id": "q", "component": "Text", "text": "Approve deploy?"},
                {"id": "ok", "component": "Button", "variant": "primary",
                 "child": "okText", "action": {"event": {"name": "approve"}}},
                {"id": "okText", "component": "Text", "text": "Approve"},
                {"id": "no", "component": "Button",
                 "child": "noText", "action": {"event": {"name": "dismiss"}}},
                {"id": "noText", "component": "Text", "text": "Dismiss"},
            ]}},
        ],
        "timeout_secs": 90,
    },
    timeout=120,
)
r.raise_for_status()
ans = r.json()
if ans["timed_out"]:
    print(f"no one answered card {ans['id']} in 90s")
else:
    print(f"answer: {ans['state']['action_name']}  data: {ans['data']}")
```

Push only — `POST /push`:

```python
r = requests.post(f"{HOST}/push",
                  headers={"Authorization": f"Bearer {TOKEN}"},
                  json={"summary": "DB backup completed",
                        "source": "ops-cron"}, timeout=10)
r.raise_for_status()
print(r.json()["id"])
```

### 6.3 Go

```go
package main

import (
    "bytes"
    "encoding/json"
    "fmt"
    "net/http"
    "os"
)

func main() {
    body, _ := json.Marshal(map[string]any{
        "summary": "build finished",
        "a2ui": []any{
            map[string]any{"version": "v0.9", "createSurface": map[string]any{
                "surfaceId": "card",
                "catalogId": "https://a2ui.org/specification/v0_9/basic_catalog.json",
            }},
            map[string]any{"version": "v0.9", "updateComponents": map[string]any{
                "surfaceId": "card",
                "components": []any{
                    map[string]any{"id": "root", "component": "Column", "children": []any{"msg"}},
                    map[string]any{"id": "msg", "component": "Text", "text": "build #142 green"},
                },
            }},
        },
        "source": "ci",
    })
    req, _ := http.NewRequest("POST", os.Getenv("AMA_HOST")+"/push", bytes.NewReader(body))
    req.Header.Set("Authorization", "Bearer "+os.Getenv("AMA_TOKEN"))
    req.Header.Set("Content-Type", "application/json")
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != 200 {
        panic(fmt.Sprintf("status %d", resp.StatusCode))
    }
}
```

## 7. Debugging & limitations

### Limitations

- **No retry queue.** `/push` returning 200 means the webhook wrote the entry to its own replica and handed it to gossip. If no peer is reachable right now, the card stays in the webhook's replica until a peer comes back — but nothing notifies you of "delivery failure → retry". For most real flows, the long-running webhook itself is enough.
- **No rate limit.** No in-process rate limiting; at-least-once delivery from upstream sources (GitHub, …) is your problem. The `/github/pr` adapter mitigates this by writing only on a whitelist of `action` values.
- **No HMAC.** GitHub's `X-Hub-Signature-256` is not verified. If you worry about request forgery, front the adapter with a proxy + Bearer token (current setup) or extend `auth_middleware` to validate HMAC.

### Debugging

Server-side traces: `RUST_LOG="warn,iroh_docs=debug,iroh_gossip=debug,ama=trace"`. In Docker, bind it through `muveectl secrets create` + `bind-secret --env-var` (see [Ops](../ops/index.md)).

Client push failing:
- `curl -i` to see status + headers
- `401`: token wrong / missing `Authorization: Bearer …` / header name typo
- `422`: malformed JSON or missing `summary` (axum's response body names the field)
- Timeouts: confirm the webhook container is alive (`muveectl projects describe`), `/healthz` works
