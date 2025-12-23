#!/bin/bash
# Initialize all shared memory segments

set -euo pipefail

# Check sudo without password
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
    exit 1
fi

INSTALL_PATH="/usr/local/bin/hft-shm"

# Check if hft-shm is installed
if [ ! -x "$INSTALL_PATH" ]; then
    echo "Error: hft-shm not installed at $INSTALL_PATH. Run 04_install_hft-shm.sh first" >&2
    exit 1
fi

# Get the real user's home directory (not root's when running with sudo)
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

CONFIG_FILE="$USER_HOME/hft.toml"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found" >&2
    exit 1
fi

echo "Initializing shared memory segments..."
echo "Config: $CONFIG_FILE"
sudo "$INSTALL_PATH" init --config "$CONFIG_FILE"

echo ""
echo "Verifying segments..."
sudo "$INSTALL_PATH" list --config "$CONFIG_FILE"

echo ""
echo "=== Verification ==="
ls -la /dev/shm/hft/ 2>/dev/null || echo "(directory /dev/shm/hft/ not found)"

echo ""
echo "Done. All shared memory segments initialized."
