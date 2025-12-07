#!/bin/bash
# Build and install hft-shm

set -euo pipefail

# Check sudo without password
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HFT_SHM_DIR="$PROJECT_DIR/hft-shm"
INSTALL_PATH="/usr/local/bin/hft-shm"

echo "Building hft-shm..."
cd "$HFT_SHM_DIR"
make clean
make cli

echo "Installing to $INSTALL_PATH..."
sudo cp "$HFT_SHM_DIR/build/hft-shm" "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"

echo "Verifying installation..."
if [ -x "$INSTALL_PATH" ]; then
    echo "Done. hft-shm installed at $INSTALL_PATH"
    "$INSTALL_PATH" --help | head -5
    echo ""
    echo "Note: Ensure /usr/local/bin is in your PATH"
else
    echo "Error: Installation failed - $INSTALL_PATH not executable" >&2
    exit 1
fi
