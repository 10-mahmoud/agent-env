#!/usr/bin/env bash
set -euo pipefail
# One-time fix for rootless Docker host-gateway bug (moby/moby#47684).
# Run this ON THE HOST (not inside the container).
#
# What it does:
#   1. Sets host-gateway-ip to 10.0.2.2 (slirp4netns tap → real host)
#   2. Disables host-loopback isolation so containers can reach host ports
#   3. Restarts rootless Docker
#
# After this, host.docker.internal resolves to the real host IP inside any
# container, and published ports (goodturn:8083, finfam:8081, etc.) are reachable.
#
# Security note: disabling host-loopback allows containers to reach any port
# on the real host. Acceptable for dev; do not apply on shared/production hosts.

if [[ "${AGENT_ENV:-}" == "1" ]]; then
    echo "ERROR: This script must be run on the host, not inside agent-env." >&2
    exit 1
fi

if ! docker info --format '{{range .SecurityOptions}}{{.}}{{end}}' 2>/dev/null | grep -q rootless; then
    echo "Docker is not running in rootless mode. This fix is not needed." >&2
    exit 0
fi

# 1. daemon.json — tell Docker what IP host-gateway should resolve to
_daemon_json="$HOME/.config/docker/daemon.json"
mkdir -p "$(dirname "$_daemon_json")"
if [[ -f "$_daemon_json" ]]; then
    if grep -q '"host-gateway-ip"' "$_daemon_json"; then
        echo "daemon.json already has host-gateway-ip. Skipping."
    else
        echo "WARNING: $_daemon_json exists but lacks host-gateway-ip."
        echo "  Please add '\"host-gateway-ip\": \"10.0.2.2\"' manually."
        echo "  Current contents:"
        cat "$_daemon_json"
        exit 1
    fi
else
    echo '{"host-gateway-ip":"10.0.2.2"}' > "$_daemon_json"
    echo "Created $_daemon_json"
fi

# 2. systemd override — allow containers to reach the real host
_override_dir="$HOME/.config/systemd/user/docker.service.d"
_override="$_override_dir/rootless-host-access.conf"
mkdir -p "$_override_dir"
if [[ -f "$_override" ]]; then
    echo "systemd override already exists. Skipping."
else
    printf '[Service]\nEnvironment="DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false"\n' > "$_override"
    echo "Created $_override"
fi

# 3. Restart Docker
echo "Reloading systemd and restarting Docker..."
systemctl --user daemon-reload
systemctl --user restart docker
echo "Done. Recreate agent-env to pick up the change:"
echo "  ./dev.sh --recreate -d"
