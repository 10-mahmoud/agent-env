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

# Bun (install to /usr/local so it's available to all users)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# Rust nightly (needed to build pi_natives from source for this CPU)
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain nightly --profile minimal \
    && rustc --version

# Claude Code (via npm, globally available)
RUN npm install -g @anthropic-ai/claude-code

# oh-my-pi (via bun)
RUN bun install -g @anthropic-ai/claude-code \
    && bun install -g @oh-my-pi/pi-coding-agent \
    && chmod -R o+rX /root/.bun \
    && chmod o+x /root \
    && ln -sf /root/.bun/bin/omp /usr/local/bin/omp

# Rebuild pi_natives from source for this CPU (prebuilt binary uses AVX2
# which is not available on Ivy Bridge / Xeon E3-1220 V2)
RUN git clone --depth 1 https://github.com/can1357/oh-my-pi /tmp/oh-my-pi \
    && cd /tmp/oh-my-pi/crates/pi-natives \
    && RUSTFLAGS="-C target-cpu=native" cargo build --release \
    && cp /tmp/oh-my-pi/target/release/libpi_natives.so \
       /root/.bun/install/global/node_modules/@oh-my-pi/pi-natives/native/pi_natives.linux-x64.node \
    && rm -rf /tmp/oh-my-pi /usr/local/cargo/registry /usr/local/cargo/git

# Chromium dependencies for Puppeteer (oh-my-pi browser integration)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnspr4 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
    libxkbcommon0 libatspi2.0-0t64 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libcairo2 libpango-1.0-0 libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# Poetry 2.1.2 (for ff CLI)
RUN curl -sSL https://install.python-poetry.org | POETRY_VERSION=2.1.2 python3 - \
    && ln -sf /root/.local/bin/poetry /usr/local/bin/poetry

# Rename the existing GID-997 group to 'docker' to match host's docker socket GID
RUN groupmod -n docker $(getent group 997 | cut -d: -f1)

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

# Entrypoint: set up dev user environment on first boot
# - Copy .bashrc if missing (named volume may be empty)
# - Remove /.dockerenv so ff CLI thinks it's on the host and uses docker compose run/exec
RUN echo '#!/bin/bash\n\
if [ ! -f /home/dev/.bashrc ]; then\n\
  cp /etc/skel/.bashrc /home/dev/.bashrc\n\
  chown dev:dev /home/dev/.bashrc\n\
fi\n\
# Remove /.dockerenv so ff CLI behaves as if running on the host\n\
rm -f /.dockerenv\n\
exec "$@"' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 22 8888

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
