# ama-webhook on Muvee

Deploys the `ama serve` webhook bridge (M5 P3) to the Muvee PaaS. Companion to
`deploy/relay-muvee/`: the relay carries iroh's NAT-fallback traffic; the
webhook accepts HTTP `POST /push` and `POST /github/pr` from external sources
(scripts, GitHub webhooks, Linear, …) and pushes the resulting A2UI cards into
your inbox over the same iroh-doc CRDT your devices read from.

## Environment variables

Read by `ama serve` via clap's `env =` bindings.

| Var | Required | Default | Purpose |
|---|---|---|---|
| `AMA_TICKET` | yes | — | Pairing ticket of the inbox the server joins. Generate with `ama create` on one of your devices, then copy/paste the printed ticket. |
| `AMA_TOKEN` | recommended | (none → open) | Bearer token required on `POST /push` and `POST /github/pr`. Without it the server runs open and logs a warning. |
| `AMA_TOKEN_FILE` | alternative to `AMA_TOKEN` | — | Path to a file holding the token (trimmed). Useful for Muvee secret-as-file mounting. |
| `AMA_RELAY` | optional | n0 defaults | Self-hosted iroh-relay URL; for ask-me-anywhere this should be `https://relay.muveeai.com`. |
| `AMA_NAME` | optional | `webhook` | Default `source` stamped on cards that omit it. |
| `AMA_BIND` | set by Dockerfile | `0.0.0.0:8080` | TCP bind address. Don't override under Muvee. |

## Deploy

Build context must be the workspace root, not this directory — the Dockerfile
copies `Cargo.toml` / `Cargo.lock` / `crates/` from there.

```bash
# 1. Sanity-check the image builds locally.
docker build -f deploy/webhook/Dockerfile -t ama-webhook .

# 2. Generate the inbox ticket on a device (one-off; reuse it across
#    redeploys until you rotate it).
cargo run -p ama-cli -- create --name desktop \
  --relay https://relay.muveeai.com
# copy the printed ticket; this is AMA_TICKET below.

# 3. Generate a token for HTTP auth.
openssl rand -hex 32 > token.txt   # save the value as AMA_TOKEN below

# 4. Create the Muvee project.
muveectl projects create \
  --name ama-webhook \
  --git-source hosted \
  --domain webhook \
  --dockerfile deploy/webhook/Dockerfile \
  --description "ama-webhook — HTTP bridge that injects cards into the inbox (M5)" \
  --tags webhook,ama,m5

# Capture the PROJECT_ID and the hosted-git push URL.

# 5. Wire the env vars through Muvee secrets. There's no direct `env set`
#    subcommand — values live in the platform's secrets vault and bind to
#    a project with --env-var. Repeat per variable; each `secrets create`
#    prints a SECRET_ID you pass straight into bind-secret.
muveectl secrets create --name AMA_TICKET --type password --value "doc..."
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TICKET_SECRET_ID> --env-var AMA_TICKET
muveectl secrets create --name AMA_TOKEN  --type password --value "$(cat token.txt)"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_TOKEN_SECRET_ID>  --env-var AMA_TOKEN
muveectl secrets create --name AMA_RELAY  --type password --value "https://relay.muveeai.com"
muveectl projects bind-secret PROJECT_ID --secret-id <AMA_RELAY_SECRET_ID>  --env-var AMA_RELAY

# 6. Push the workspace source. `git push` needs a project-scoped token as
#    the password (the session token does NOT work for hosted-git pushes).
PROJECT_TOKEN="$(muveectl tokens create PROJECT_ID --name git-push | awk '/^Token:/{print $2}')"
git push "https://x:${PROJECT_TOKEN}@muveeai.com/git/PROJECT_ID.git" main

# 7. Build & deploy.
muveectl projects deploy PROJECT_ID
muveectl projects logs PROJECT_ID            # watch the build
muveectl projects runtime-logs PROJECT_ID --follow  # watch the server come up

# Rotating a secret later: `muveectl secrets create` does not overwrite an
# existing name, so unbind + delete + recreate + rebind, then `projects deploy`
# (not just `restart` — restart keeps the old env) to pick up the new value.

# 8. Verify end-to-end.
HOST="https://webhook.muveeai.com"
TOKEN="$(cat token.txt)"
# Open route, no auth:
curl -i "$HOST/healthz"
# Guarded route without auth → 401:
curl -i -X POST -H "Content-Type: application/json" \
  --data '{"summary":"ping"}' "$HOST/push"
# Guarded route with auth → 200 + id, and a notification on every paired device:
curl -i -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"summary":"hello from prod webhook"}' "$HOST/push"
```

## Why expose only one inbox per container

`ama serve` is single-tenant by design: each running container holds one
inbox replica. If you want multiple sources to share a single inbox, point
them all at the same container; if you want strict isolation (e.g. work vs
personal), deploy multiple containers with different `AMA_TICKET`s. The
single-tenancy keeps the auth surface narrow (one bearer token guards one
inbox) and matches `ARCHITECTURE.md` §7's threat model.

## GitHub webhook setup (optional)

In your repo's settings → Webhooks → Add webhook:

- Payload URL: `https://webhook.muveeai.com/github/pr`
- Content type: `application/json`
- Secret: (leave blank — auth is the bearer token, not HMAC; see below)
- Events: only `Pull requests`

Then in `Headers`, configure `Authorization: Bearer <token>`. GitHub doesn't
support custom headers natively, so for production you'll usually front the
adapter with a relay (e.g. a Cloudflare Worker) that adds the header, or
switch to HMAC by extending `auth_middleware` in `crates/cli/src/main.rs`.

Until then, the simplest test is from the command line:

```bash
curl -X POST "$HOST/github/pr" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data @sample-pr.json
```
