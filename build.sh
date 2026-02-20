#!/usr/bin/env bash
set -euo pipefail

# Build the agent-env container, auto-detecting CPU capabilities and host
# UID/GID.
#
# Usage:
#   ./build.sh                         # auto-detect everything
#   ./build.sh --rebuild-pi-natives    # force pi_natives source rebuild
#   ./build.sh --no-rebuild-pi-natives # force skip pi_natives rebuild
#   ./build.sh --omp-version 12.13.0   # pin omp to a specific version
#   ./build.sh --omp-version latest    # force reinstall latest omp
#
# Any extra flags are forwarded to `docker compose build`.

REBUILD_PI_NATIVES=""
OMP_VERSION=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-pi-natives)    REBUILD_PI_NATIVES=true; shift ;;
        --no-rebuild-pi-natives) REBUILD_PI_NATIVES=false; shift ;;
        --omp-version)           OMP_VERSION="$2"; shift 2 ;;
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

# --- Auto-detect: host UID/GID for file ownership parity ---
# Rootless Docker remaps UIDs: UID 0 inside = host user, so dev must be UID 0.
# Traditional Docker has no remap: dev should match the host user's UID.
if [[ -z "${HOST_UID:-}" ]]; then
    if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        HOST_UID=0
        HOST_GID=0
        echo "==> Rootless Docker detected — dev user will be UID 0 (maps to host user)"
    else
        HOST_UID="$(id -u)"
        HOST_GID="$(id -g)"
    fi
fi
echo "==> Host UID/GID: $HOST_UID/$HOST_GID"

# --- OMP version: resolve "latest" to a concrete version for cache busting ---
if [[ -z "$OMP_VERSION" ]]; then
    echo "==> OMP version: using cached layer (pass --omp-version to update)"
elif [[ "$OMP_VERSION" == "latest" ]]; then
    OMP_VERSION="$(npm view @oh-my-pi/pi-coding-agent version 2>/dev/null || echo "unknown-$(date +%s)")"
    echo "==> OMP version: resolved latest → $OMP_VERSION"
else
    echo "==> OMP version: pinning to $OMP_VERSION"
fi

export REBUILD_PI_NATIVES HOST_UID HOST_GID
[[ -n "$OMP_VERSION" ]] && export OMP_VERSION
exec docker compose build "${EXTRA_ARGS[@]}"
