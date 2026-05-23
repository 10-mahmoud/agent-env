#!/usr/bin/env bash
set -euo pipefail
#
# Start Caddy as an HTTPS reverse proxy using Tailscale certs.
# Run on the HOST machine (not inside agent-env).
#
# Usage:
#   ./start-caddy.sh          # auto-detect tailnet hostname
#   ./start-caddy.sh stop     # stop Caddy
#
# Prerequisites:
#   - Caddy installed (brew install caddy / apt install caddy)
#   - Tailscale running with HTTPS enabled
#   - Linux only: TS_PERMIT_CERT_UID=caddy in /etc/default/tailscaled

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CADDYFILE="$SCRIPT_DIR/Caddyfile"

if [[ "${1:-}" == "stop" ]]; then
    sudo caddy stop 2>/dev/null && echo "Caddy stopped." || echo "Caddy was not running."
    exit 0
fi

if ! command -v caddy >/dev/null 2>&1; then
    echo "Error: caddy not found. Install it first:"
    echo "  macOS:  brew install caddy"
    echo "  Linux:  see https://caddyserver.com/docs/install#debian-ubuntu-raspbian"
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    echo "Error: tailscale not found."
    exit 1
fi

# Get this machine's Tailscale FQDN
export TAILNET_HOST
TAILNET_HOST=$(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')
if [[ -z "$TAILNET_HOST" || "$TAILNET_HOST" == "null" ]]; then
    echo "Error: could not determine Tailscale hostname. Is Tailscale running?"
    exit 1
fi

echo "Tailnet host: $TAILNET_HOST"
echo "Starting Caddy with HTTPS on ports 5473, 8381, 4621, 9320, 9321..."

# Stop any existing Caddy instance
sudo caddy stop 2>/dev/null || true

# Caddy reads {env.TAILNET_HOST} from the environment
sudo TAILNET_HOST="$TAILNET_HOST" caddy start --config "$CADDYFILE"

echo "Caddy running. Verify:"
echo "  curl https://$TAILNET_HOST:8381/id/"
