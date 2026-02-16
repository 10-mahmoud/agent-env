FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System packages
RUN apt-get update && apt-get install -y \
    openssh-server \
    git \
    curl \
    wget \
    ripgrep \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    unzip \
    jq \
    tmux \
    vim \
    ca-certificates \
    emacs-nox \
    gnupg \
    iproute2 \
    software-properties-common \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Python 3.11 via deadsnakes PPA (ff requires ^3.11)
RUN add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --set python3 /usr/bin/python3.11

# Docker CLI + compose plugin (no daemon — we use host's via socket)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y \
    docker-ce-cli \
    docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS via nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Chromium dependencies for Puppeteer (oh-my-pi browser integration)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnspr4 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
    libxkbcommon0 libatspi2.0-0t64 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libcairo2 libpango-1.0-0 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# Language servers (for Claude Code / omp LSP integration)
RUN npm install -g \
    typescript \
    typescript-language-server \
    svelte-language-server \
    pyright \
    bash-language-server \
    vscode-langservers-extracted \
    yaml-language-server

# Bun (install to /usr/local so it's available to all users)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# Poetry 2.1.2 + shell plugin (for ff CLI)
RUN curl -sSL https://install.python-poetry.org | POETRY_VERSION=2.1.2 python3 - \
    && ln -sf /root/.local/bin/poetry /usr/local/bin/poetry \
    && poetry self add poetry-plugin-shell

# Claude Code (native installer — auto-updates, no Node.js runtime needed)
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && ln -sf /root/.local/bin/claude /usr/local/bin/claude

# oh-my-pi (via bun)
RUN bun install -g @oh-my-pi/pi-coding-agent \
    && chmod -R o+rX /root/.bun \
    && chmod o+x /root \
    && ln -sf /root/.bun/bin/omp /usr/local/bin/omp

# Conditionally install Rust nightly and rebuild pi_natives from source.
# The prebuilt pi_natives binary requires AVX2. Older CPUs (e.g. Ivy Bridge /
# Xeon E3-1220 V2) lack AVX2 and need a source rebuild. Newer CPUs (Ryzen,
# Haswell+) can skip this entirely.  Use build.sh to auto-detect, or pass
# --build-arg REBUILD_PI_NATIVES=true|false explicitly.
ARG REBUILD_PI_NATIVES=false
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:${PATH}"
RUN if [ "$REBUILD_PI_NATIVES" = "true" ]; then \
    echo ">>> Installing Rust nightly and rebuilding pi_natives from source..." \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
       | sh -s -- -y --default-toolchain nightly --profile minimal \
    && rustc --version \
    && git clone --depth 1 https://github.com/can1357/oh-my-pi /tmp/oh-my-pi \
    && cd /tmp/oh-my-pi/crates/pi-natives \
    && RUSTFLAGS="-C target-cpu=native" cargo build --release \
    && cp /tmp/oh-my-pi/target/release/libpi_natives.so \
       /root/.bun/install/global/node_modules/@oh-my-pi/pi-natives/native/pi_natives.linux-x64.node \
    && rm -rf /tmp/oh-my-pi /usr/local/cargo/registry /usr/local/cargo/git \
    ; else \
    echo ">>> Skipping pi_natives rebuild (AVX2 available, prebuilt binary is fine)" \
    ; fi

# Create a 'docker' group matching the host's docker socket GID so the dev
# user can access /var/run/docker.sock.  Override with --build-arg DOCKER_GID=NNN.
ARG DOCKER_GID=997
RUN if getent group "$DOCKER_GID" > /dev/null 2>&1; then \
    groupmod -n docker "$(getent group "$DOCKER_GID" | cut -d: -f1)"; \
    else \
    groupadd -g "$DOCKER_GID" docker; \
    fi

# Create non-root user with sudo + docker access
RUN useradd -m -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && usermod -aG docker dev

# Set up SSH
RUN mkdir /var/run/sshd \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers dev" >> /etc/ssh/sshd_config

# Ensure dev user's .ssh directory exists with correct permissions
RUN mkdir -p /home/dev/.ssh && chmod 700 /home/dev/.ssh && chown dev:dev /home/dev/.ssh

# Create workspace directory
RUN mkdir -p /workspace && chown dev:dev /workspace

# Mark /workspace as a git safe directory so bind-mounted repos (owned by the
# host UID) don't trigger git's "dubious ownership" error for the dev user.
RUN git config --system --add safe.directory '*'

# Entrypoint: set up dev user environment on first boot
# - Copy .bashrc if missing (named volume may be empty)
# - Remove /.dockerenv so ff CLI thinks it's on the host and uses docker compose run/exec
# - Symlink ~/work and ~/projects to host-path mounts so getcwd(2) resolves
#   to the host path and docker-compose bind-mount paths work on the host daemon
RUN echo '#!/bin/bash\n\
if [ ! -f /home/dev/.bashrc ]; then\n\
  cp /etc/skel/.bashrc /home/dev/.bashrc\n\
  chown dev:dev /home/dev/.bashrc\n\
fi\n\
rm -f /.dockerenv\n\
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/dev" ]; then\n\
  for dir in work projects; do\n\
    target="$HOST_HOME/$dir"\n\
    link="/home/dev/$dir"\n\
    if [ -d "$target" ]; then\n\
      [ -d "$link" ] && [ ! -L "$link" ] && rmdir "$link" 2>/dev/null || true\n\
      [ ! -e "$link" ] && ln -s "$target" "$link" && chown -h dev:dev "$link"\n\
    fi\n\
  done\n\
fi\n\
exec "$@"' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 22 8888 8889 8890

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
