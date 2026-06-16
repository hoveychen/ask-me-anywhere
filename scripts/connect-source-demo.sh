#!/usr/bin/env bash
#
# connect-source-demo.sh — feed a REAL card into an ask-me-anywhere inbox.
#
# Points the `ama serve` webhook bridge at an inbox's pairing ticket (grab it
# from the Flutter app's "Connect a source" screen, or from `ama create`),
# starts the bridge, POSTs a sample GitHub PR webhook through the built-in
# adapter, then leaves the bridge running so the card syncs to your devices
# over P2P. This is the "see a real card, not the debug gallery" quickstart.
#
# Usage:
#   scripts/connect-source-demo.sh --ticket <docaaa…> [--token <BEARER>] \
#       [--bind 127.0.0.1:8080] [--payload scripts/sample-github-pr.json]
#
# Env:
#   AMA_BIN   path to a prebuilt `ama` binary (skips the cargo build step)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

ticket=""
token=""
bind="127.0.0.1:8080"
payload="$here/sample-github-pr.json"

usage() {
  sed -n '3,18p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)  ticket="$2"; shift 2 ;;
    --token)   token="$2"; shift 2 ;;
    --bind)    bind="$2"; shift 2 ;;
    --payload) payload="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$ticket" ]]; then
  echo "error: --ticket is required (get it from the app's Connect-a-source screen or 'ama create')" >&2
  usage 1
fi
if [[ ! -f "$payload" ]]; then
  echo "error: payload file not found: $payload" >&2
  exit 1
fi

# Resolve the ama binary: prefer $AMA_BIN, else build it once.
ama="${AMA_BIN:-}"
if [[ -z "$ama" ]]; then
  echo "building ama (cargo build -p ama-cli --release)…" >&2
  ( cd "$repo_root" && cargo build -p ama-cli --release >&2 )
  ama="$repo_root/target/release/ama"
fi

serve_args=(serve --ticket "$ticket" --bind "$bind")
curl_auth=()
if [[ -n "$token" ]]; then
  serve_args+=(--token "$token")
  curl_auth=(-H "Authorization: Bearer $token")
fi

# Start the bridge in the background; clean it up on exit.
"$ama" "${serve_args[@]}" &
serve_pid=$!
trap 'kill "$serve_pid" 2>/dev/null || true' EXIT

# Wait for the HTTP listener to come up (the node also needs a moment to join).
echo "waiting for the bridge on http://$bind …" >&2
for _ in $(seq 1 50); do
  if curl -fsS "http://$bind/healthz" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 0.2
done
if [[ "${ready:-}" != "1" ]]; then
  echo "error: bridge never became healthy on http://$bind" >&2
  exit 1
fi

echo "POST /github/pr  (sample PR from $payload)" >&2
resp="$(curl -fsS -X POST "http://$bind/github/pr" \
  -H "Content-Type: application/json" "${curl_auth[@]}" \
  --data @"$payload")"
echo "$resp"

echo >&2
echo "card pushed → $resp" >&2
echo "bridge is live on http://$bind; it stays up so the card syncs to your" >&2
echo "paired devices. Open the app — the card should land in the inbox." >&2
echo "Ctrl-C to stop the bridge." >&2
wait "$serve_pid"
