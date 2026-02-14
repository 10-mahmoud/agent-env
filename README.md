# agent-env

Docker-based development environment for working on [finfam](https://github.com/user/finfam). Provides a reproducible container with Claude Code, oh-my-pi, Docker-in-Docker (via host socket), and all the tooling finfam needs — pre-configured and ready to go.

Works on both older remote servers (Ivy Bridge / Xeon without AVX2) and modern local machines (Ryzen, Haswell+). CPU differences are detected automatically at build time.

## Prerequisites

- Docker with Compose plugin
- A `.env` file in this directory (see [Configuration](#configuration))

## Quick start

```bash
# 1. Build the container (auto-detects CPU, docker GID, etc.)
./build.sh

# 2. Drop into a shell inside the container
./dev.sh
```

That's it. You're in `/workspace/finfam` as the `dev` user with `claude`, `omp`, `docker`, `poetry`, and everything else on your PATH.

## Configuration

Create a `.env` file with at minimum:

```
ANTHROPIC_API_KEY=sk-ant-...
```

Optional variables (can also go in `.env`):

| Variable | Default | Description |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | IP to bind SSH and HTTP ports to. Set to your Tailscale IP for remote access. |
| `DOCKER_GID` | auto-detected | GID of the host's docker socket. `build.sh` and `dev.sh` detect this automatically. |
| `REBUILD_PI_NATIVES` | auto-detected | Set `true` to force pi_natives source rebuild, `false` to skip. `build.sh` checks for AVX2. |
| `PPROTECT_PASSPHRASE` | — | Passphrase for pprotect, if used. |

### Remote server example `.env`

```
ANTHROPIC_API_KEY=sk-ant-...
BIND_ADDR=100.95.42.123
```

## Scripts

### `build.sh`

Builds the container image. Auto-detects:
- **AVX2 support** — skips the Rust/pi_natives source rebuild on modern CPUs (saves several minutes)
- **Docker socket GID** — ensures the container can talk to the host's Docker daemon

```bash
./build.sh                         # auto-detect everything
./build.sh --rebuild-pi-natives    # force pi_natives source rebuild
./build.sh --no-rebuild-pi-natives # force skip
./build.sh --no-cache              # extra flags forwarded to docker compose build
```

### `dev.sh`

Starts the container (if not running) and execs into it.

```bash
./dev.sh           # bash shell in /workspace/finfam
./dev.sh npm test  # run a command directly
```

## What's inside

- **Ubuntu 24.04** base
- **Python 3.11** + Poetry 2.1.2
- **Node.js 22 LTS** + Bun
- **Claude Code** (npm) + **oh-my-pi** (bun)
- **Docker CLI + Compose** (talks to host daemon via socket)
- **Rust nightly** (only installed when pi_natives rebuild is needed)
- ripgrep, tmux, vim, emacs-nox, git, jq, build-essential

## Architecture

The container runs an SSH server for remote access and mounts the host's Docker socket for Docker-in-Docker workflows. The finfam project is bind-mounted at `/workspace/finfam`. A named volume (`agent-env-home`) persists the dev user's home directory across container rebuilds.

The entrypoint removes `/.dockerenv` so the ff CLI thinks it's running on a real host and correctly uses `docker compose run/exec` for its sub-containers.
