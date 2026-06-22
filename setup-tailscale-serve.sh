#!/usr/bin/env bash
set -euo pipefail
#
# Persistent HTTPS reverse-proxying for finfam dev services via `tailscale serve`.
# Idempotent — safe to re-run. Works on Linux and macOS.
#
# Tailscaled stores the config and restores it on every boot, so this only
# needs to run once per host (and again any time the port map changes).
#
# Port convention: HTTPS port = HTTP port + 300

if [[ "${AGENT_ENV:-}" == "1" ]]; then
    echo "ERROR: run this on the host, not inside agent-env." >&2
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    echo "Error: tailscale not found." >&2
    echo "  macOS:  brew install tailscale  (or Tailscale.app from the App Store)" >&2
    echo "  Linux:  https://tailscale.com/download/linux" >&2
    exit 1
fi

# `tailscale serve` requires root, OR an operator user. Probe with a read-only
# status check; if it's denied, grant operator once via sudo so this and every
# future run / status check works without sudo.
# NOTE: we intentionally do NOT run `tailscale serve reset` — that would wipe
# any existing serve/funnel routes not managed by this script (e.g. Overseerr).
if ! tailscale serve status >/dev/null 2>&1; then
    echo "Granting $USER operator rights on tailscaled (one-time, requires sudo)..."
    sudo tailscale set --operator="$USER"
fi

# HTTPS port -> upstream HTTP port on localhost
routes=(
    # finfam
    "5473:5173"   # Frontend (SvelteKit/Vite)
    "8381:8081"   # API (FastAPI/uvicorn)
    "4621:4321"   # Docs (Astro)
    "9320:9020"   # MinIO S3 API
    "9321:9021"   # MinIO Console
    # GoodTurn
    "5483:5183"   # Frontend (SvelteKit)
    "8383:8083"   # API (FastAPI/uvicorn)
)

for route in "${routes[@]}"; do
    https_port="${route%%:*}"
    upstream_port="${route##*:}"
    tailscale serve --bg --https="$https_port" "http://localhost:$upstream_port"
done

echo
echo "Serve config:"
tailscale serve status
echo
host=$(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')
echo "Verify:  curl https://$host:8381/id/"
