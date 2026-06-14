#!/bin/bash
# Setup ADB server on the host for agent-env container access.
#
# The container can't reach WiFi devices directly (Docker bridge network).
# This installs Google's platform-tools (modern ADB with wireless pairing
# support) and creates a systemd user service that runs `adb -a server`
# (listens on all interfaces, port 5037).
# The container entrypoint auto-detects this and sets ADB_SERVER_SOCKET.
#
# Usage (on the host, not in agent-env):
#   ./setup-adb-host.sh
#
# After setup:
#   - ADB server starts automatically on login
#   - agent-env container's `adb` commands transparently reach WiFi devices
#   - `systemctl --user status adb-server` to check
#   - `systemctl --user restart adb-server` to restart

set -euo pipefail

ADB_DIR="${HOME}/.local/share/android-platform-tools"
ADB_BIN="${ADB_DIR}/platform-tools/adb"

# 1. Install Google's platform-tools (not the ancient apt package)
#    The apt android-tools-adb is v28 and doesn't support `adb pair`.
if [ -x "$ADB_BIN" ]; then
    echo "adb already installed: $($ADB_BIN version | head -1)"
else
    echo "Installing Google platform-tools..."
    mkdir -p "$ADB_DIR"
    cd /tmp
    curl -sL https://dl.google.com/android/repository/platform-tools-latest-linux.zip -o platform-tools.zip
    unzip -qo platform-tools.zip -d "$ADB_DIR"
    rm platform-tools.zip
    echo "adb installed: $($ADB_BIN version | head -1)"
fi

# Kill any existing adb server (apt version or stale)
"$ADB_BIN" kill-server 2>/dev/null || true
# Also kill apt-installed adb server if running
pkill -f '/usr/bin/adb.*server' 2>/dev/null || true

# 2. Create systemd user service
UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "${UNIT_DIR}/adb-server.service" <<EOF
[Unit]
Description=ADB server (all interfaces)
Documentation=https://developer.android.com/tools/adb

[Service]
# -a = listen on all interfaces (not just localhost)
# This lets the Docker container reach it via host.docker.internal:5037
ExecStart=${ADB_BIN} -a -P 5037 server nodaemon
ExecStop=${ADB_BIN} kill-server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# 3. Enable and start
systemctl --user daemon-reload
systemctl --user enable adb-server.service
systemctl --user restart adb-server.service

echo ""
echo "ADB server running on 0.0.0.0:5037 ($($ADB_BIN version | head -1))"
echo "Status: systemctl --user status adb-server"
echo ""
echo "Restart agent-env to pick up the change, or run inside it:"
echo "  export ADB_SERVER_SOCKET=tcp:host.docker.internal:5037"
echo "  adb devices"
