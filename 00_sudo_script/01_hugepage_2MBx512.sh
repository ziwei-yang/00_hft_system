#!/bin/bash
# Configure 512 x 2MB = 1GB hugepages

set -euo pipefail

# Check sudo without password
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
    exit 1
fi

REQUIRED=512
CURRENT=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)

if [ "$CURRENT" -ge "$REQUIRED" ]; then
    echo "Hugepages already configured: $CURRENT x 2MB"
    exit 0
fi

echo "Configuring $REQUIRED x 2MB hugepages..."

# Apply runtime change (scoped to this setting only)
sudo sysctl -w vm.nr_hugepages=$REQUIRED > /dev/null

# Permanent - update or add vm.nr_hugepages in /etc/sysctl.conf
sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak
echo "Backup: /etc/sysctl.conf.bak"

if grep -q "^vm.nr_hugepages" /etc/sysctl.conf; then
    # Update existing line
    sudo sed -i "s/^vm.nr_hugepages.*/vm.nr_hugepages = $REQUIRED/" /etc/sysctl.conf
else
    # Add new line
    echo "vm.nr_hugepages = $REQUIRED" | sudo tee -a /etc/sysctl.conf > /dev/null
fi

# Verify
ACTUAL=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
if [ "$ACTUAL" -lt "$REQUIRED" ]; then
    echo "Warning: Only allocated $ACTUAL hugepages (requested $REQUIRED)" >&2
    echo "Try rebooting or freeing memory" >&2
    exit 1
fi

echo "Done. Hugepages configured: $ACTUAL x 2MB"
echo ""
echo "=== Verification ==="
cat /proc/meminfo | grep -i huge
