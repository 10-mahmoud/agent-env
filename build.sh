#!/usr/bin/env bash
set -euo pipefail

# Build the agent-env container, auto-detecting CPU capabilities and host
# docker GID.
#
# Usage:
#   ./build.sh                         # auto-detect everything
#   ./build.sh --rebuild-pi-natives    # force pi_natives source rebuild
#   ./build.sh --no-rebuild-pi-natives # force skip pi_natives rebuild
#
# Any extra flags are forwarded to `docker compose build`.

REBUILD_PI_NATIVES=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-pi-natives)    REBUILD_PI_NATIVES=true; shift ;;
        --no-rebuild-pi-natives) REBUILD_PI_NATIVES=false; shift ;;
        *)                       EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# --- Auto-detect: pi_natives rebuild (AVX2 check) ---
if [[ -z "$REBUILD_PI_NATIVES" ]]; then
    if grep -q ' avx2 ' /proc/cpuinfo 2>/dev/null; then
        REBUILD_PI_NATIVES=false
        echo "==> AVX2 detected — using prebuilt pi_natives binary"
    else
        REBUILD_PI_NATIVES=true
        echo "==> No AVX2 detected — will rebuild pi_natives from source"
    fi
fi

# --- Auto-detect: host docker socket GID ---
if [[ -z "${DOCKER_GID:-}" ]]; then
    if [[ -S /var/run/docker.sock ]]; then
        DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
        echo "==> Docker socket GID: $DOCKER_GID"
    else
        DOCKER_GID=997
        echo "==> No docker socket found, defaulting to GID $DOCKER_GID"
    fi
fi

export REBUILD_PI_NATIVES DOCKER_GID
exec docker compose build "${EXTRA_ARGS[@]}"
