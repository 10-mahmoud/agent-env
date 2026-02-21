#!/bin/bash

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

# Symlink ~/work and ~/projects to their host-path mounts so getcwd(2)
# resolves to the host path and docker-compose bind-mount paths work
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/dev" ]; then
  for dir in work projects; do
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

touch /tmp/.entrypoint-done
exec "$@"
