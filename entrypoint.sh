#!/bin/bash

# Rootless Docker UID fix — detect and correct at runtime.
# In rootless Docker, UID 0 inside the container maps to the host user.
# If the image was built with HOST_UID != 0, dev has the wrong UID and
# bind-mounted files will have mangled ownership on both sides.
# The uid_map's first line tells us: if UID 0 maps to a non-zero host UID,
# we're in rootless mode and dev must be UID 0.
HOST_MAPPED_UID=$(awk 'NR==1{print $2}' /proc/self/uid_map 2>/dev/null)
if [ "${HOST_MAPPED_UID:-0}" != "0" ] && [ "$(id -u dev 2>/dev/null)" != "0" ]; then
  echo "==> Rootless Docker detected (UID 0 → host UID $HOST_MAPPED_UID), fixing dev user..."
  usermod -o -u 0 -g 0 dev 2>/dev/null || true
  # Fix ownership on the named volume to match the new UID
  chown -R dev: /home/dev 2>/dev/null || true
fi

# Copy default .bashrc if missing (named volume may be empty on first boot)
if [ ! -f /home/dev/.bashrc ]; then
  cp /etc/skel/.bashrc /home/dev/.bashrc
fi

# Fix home dir ownership — the named volume may retain files from a previous
# build with a different UID (e.g. after HOST_UID changed)
DEV_UID=$(id -u dev)
if [ "$(stat -c '%u' /home/dev/.bashrc 2>/dev/null)" != "$DEV_UID" ]; then
  # Fix shell dotfiles first so exec sessions don't race the bulk chown
  chown dev: /home/dev/.bashrc /home/dev/.profile /home/dev/.bash_logout 2>/dev/null || true
  chown -R dev: /home/dev 2>/dev/null || true
fi

# ff CLI: pretend we're on the host so it uses docker compose run/exec
rm -f /.dockerenv

# Symlink ~/work, ~/projects, and ~/hatnote to their host-path mounts so getcwd(2)
# resolves to the host path and docker-compose bind-mount paths work
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/dev" ]; then
  for dir in work projects hatnote; do
    target="$HOST_HOME/$dir"
    link="/home/dev/$dir"
    if [ -d "$target" ]; then
      [ -d "$link" ] && [ ! -L "$link" ] && rmdir "$link" 2>/dev/null || true
      [ ! -e "$link" ] && ln -s "$target" "$link" && chown -h dev: "$link"
    fi
  done
fi

# Docker socket: ensure dev user can access it regardless of GID
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  if ! id -G dev | tr ' ' '\n' | grep -qx "$SOCK_GID"; then
    if ! getent group "$SOCK_GID" >/dev/null 2>&1; then
      groupadd -g "$SOCK_GID" docker-host
    fi
    usermod -aG "$SOCK_GID" dev
  fi
fi

# SSH known_hosts: the host file is mounted read-only, but SSH needs to write
# new host keys.  Copy to a writable location and configure SSH to use it.
if [ -f /home/dev/.ssh/known_hosts ] && [ ! -w /home/dev/.ssh/known_hosts ]; then
  cp /home/dev/.ssh/known_hosts /home/dev/.ssh/known_hosts.local 2>/dev/null || true
  chown dev: /home/dev/.ssh/known_hosts.local 2>/dev/null || true
fi
# Always write the SSH config — it uses the writable copy for new entries
# and falls back to the mounted original as a read-only reference.
cat > /etc/ssh/ssh_config.d/agent-env.conf <<'SSHEOF'
Host *
    UserKnownHostsFile /home/dev/.ssh/known_hosts.local /home/dev/.ssh/known_hosts
    StrictHostKeyChecking accept-new
SSHEOF

# Git config: the host gitconfig has includeIf rules using gitdir:~/work/
# which resolves to /home/dev/work/ inside the container. But the actual
# gitdir after symlink resolution is $HOST_HOME/work/. Rewrite system
# gitconfig with host-path equivalents so the professional identity activates.
{
  echo "[safe]"
  echo "    directory = *"
  if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/dev" ] && [ -f /home/dev/.gitconfig ]; then
    awk -v hh="$HOST_HOME" '
      /\[includeIf "gitdir:~\// {
        sub(/gitdir:~\//, "gitdir:" hh "/")
        print
        getline
        # Make relative include paths absolute (they resolve from /etc/ in system gitconfig)
        sub(/path = \./, "path = /home/dev/.")
        print
      }
    ' /home/dev/.gitconfig
  fi
} > /etc/gitconfig

# Rootless Docker: dev runs as UID 0 for file parity — fix prompt and identity
if [ "$(id -u dev 2>/dev/null)" = "0" ] && [ -f /home/dev/.bashrc ]; then
  if ! grep -q 'agent-env-rootless-prompt' /home/dev/.bashrc 2>/dev/null; then
    printf '\n# agent-env-rootless-prompt\nif [ "$(id -u)" = "0" ] && [ "${AGENT_ENV:-}" = "1" ]; then\n  export USER=dev LOGNAME=dev\n  PS1="${debian_chroot:+($debian_chroot)}dev@\\h:\\w\\$ "\nfi\n' >> /home/dev/.bashrc
  fi
fi

# pre-commit: install git hooks for finfam if config exists but any hook is missing
FINFAM_DIR="${HOST_HOME:-/home/dev}/work/finfam"
if [ -f "$FINFAM_DIR/.pre-commit-config.yaml" ]; then
  if [ ! -f "$FINFAM_DIR/.git/hooks/pre-commit" ] || [ ! -f "$FINFAM_DIR/.git/hooks/pre-push" ] || [ ! -f "$FINFAM_DIR/.git/hooks/post-rewrite" ]; then
    su -c "cd $FINFAM_DIR && pre-commit install --hook-type pre-commit --hook-type pre-push --hook-type post-rewrite" dev 2>/dev/null || true
  fi
fi

# Donut Browser MCP bridge (container side)
# socat on :51081 bridges to Unix socket; Python proxy on :51080 adds MCP
# lifecycle compliance (initialize/initialized) that Donut doesn't implement.
(
  _sock="${HOST_HOME:-/home/dev}/work/.donut-mcp.sock"
  for _ in $(seq 1 60); do [ -S "$_sock" ] && break; sleep 2; done
  [ -S "$_sock" ] || exit 0
  socat TCP-LISTEN:51081,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:"$_sock" &
  exec python3 /donut-mcp-proxy.py
) &

touch /tmp/.entrypoint-done
exec "$@"
