#!/usr/bin/env bash
set -euo pipefail

# Get into the agent-env development environment.  Works from anywhere:
#
#   On the host  → starts the container (if needed) and execs into it
#   In the container → runs directly in /workspace/finfam
#
# Usage:
#   ./dev.sh              # interactive bash shell
#   ./dev.sh npm test     # run a command directly

# Default to bash if no command given
if [[ $# -eq 0 ]]; then
    set -- bash
fi

# Already inside the container — just run in-place
if [[ "${AGENT_ENV:-}" == "1" ]]; then
    cd /workspace/finfam
    exec "$@"
fi

# On the host — make sure the container is up, then exec in
if [[ -z "${DOCKER_GID:-}" ]] && [[ -S /var/run/docker.sock ]]; then
    export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
fi

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q '^agent-env$'; then
    echo "==> Starting agent-env..."
    docker compose up -d
fi

exec docker compose exec -u dev -w /workspace/finfam agent-env "$@"
