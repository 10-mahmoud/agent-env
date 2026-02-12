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
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS via nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Bun (install to /usr/local so it's available to all users)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# Claude Code (via npm, globally available)
RUN npm install -g @anthropic-ai/claude-code

# oh-my-pi (via bun)
RUN bun install -g @anthropic-ai/claude-code \
    && bun install -g @oh-my-pi/pi-coding-agent \
    && chmod -R o+rX /root/.bun \
    && chmod o+x /root \
    && ln -sf /root/.bun/bin/omp /usr/local/bin/omp

# Create non-root user with sudo
RUN useradd -m -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up SSH
RUN mkdir /var/run/sshd \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers dev" >> /etc/ssh/sshd_config

# Ensure dev user's .ssh directory exists with correct permissions
RUN mkdir -p /home/dev/.ssh && chmod 700 /home/dev/.ssh && chown dev:dev /home/dev/.ssh

# Create workspace directory
RUN mkdir -p /workspace && chown dev:dev /workspace

# Entrypoint: ensure dev user has a .bashrc on first boot (named volume may be empty)
RUN echo '#!/bin/bash\n\
if [ ! -f /home/dev/.bashrc ]; then\n\
  cp /etc/skel/.bashrc /home/dev/.bashrc\n\
  chown dev:dev /home/dev/.bashrc\n\
fi\n\
exec "$@"' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
