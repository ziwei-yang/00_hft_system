#!/bin/bash
set -euo pipefail

# Check sudo without password
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
    exit 1
fi

GRUB_FILE="${1:-/etc/default/grub}"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect OS
is_linux() {
    [[ "$(uname -s)" == "Linux" ]]
}

is_ubuntu() {
    [[ -f /etc/os-release ]] && grep -qi "ubuntu" /etc/os-release
}

is_ec2() {
    [[ -f /sys/devices/virtual/dmi/id/board_asset_tag ]] && \
    grep -q "^i-" /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null
}

# Check OS requirements
if ! is_linux; then
    echo "Error: This script only runs on Linux"
    exit 1
fi

if ! is_ubuntu; then
    echo "Error: This script only supports Ubuntu"
    exit 1
fi

# Detect environment
EC2_MODE=false
if is_ec2; then
    EC2_MODE=true
    echo "=== GRUB HFT Optimization Script (EC2 Mode) ==="
else
    echo "=== GRUB HFT Optimization Script (Non-EC2 Mode) ==="
fi

# CPU isolation range: cores 1-16 for HFT workloads (or 1-NUM if fewer cores)
# Core 0 reserved for system, cores 17+ available for general use
TOTAL_CORES=$(nproc --all)
if [[ $TOTAL_CORES -lt 2 ]]; then
    echo "Error: Need at least 2 CPU cores for isolation (found $TOTAL_CORES)"
    exit 1
fi

ISOLATE_START=1
if [[ $TOTAL_CORES -gt 16 ]]; then
    ISOLATE_END=16
else
    ISOLATE_END=$((TOTAL_CORES - 1))
fi

echo "Detected $TOTAL_CORES CPU cores"
if [[ $TOTAL_CORES -gt 16 ]]; then
    echo "Will isolate cores ${ISOLATE_START}-${ISOLATE_END} (core 0 for system, cores 17+ for general use)"
else
    echo "Will isolate cores ${ISOLATE_START}-${ISOLATE_END} (core 0 for system)"
fi
echo ""

# HFT kernel parameters based on environment
declare -A HFT_PARAMS

if [[ "$EC2_MODE" == true ]]; then
    # Full optimization for EC2
    echo "Applying FULL optimization (EC2):"
    echo "  isolcpus, nohz_full, rcu_nocbs, irqaffinity, intel_pstate, processor.max_cstate, idle"
    HFT_PARAMS=(
        ["isolcpus"]="${ISOLATE_START}-${ISOLATE_END}"
        ["nohz_full"]="${ISOLATE_START}-${ISOLATE_END}"
        ["rcu_nocbs"]="${ISOLATE_START}-${ISOLATE_END}"
        ["irqaffinity"]="0"
        ["intel_pstate"]="disable"
        ["processor.max_cstate"]="0"
        ["idle"]="poll"
    )
else
    # Reduced optimization for non-EC2
    echo "Applying REDUCED optimization (non-EC2):"
    echo "  isolcpus, nohz_full, rcu_nocbs, irqaffinity"
    HFT_PARAMS=(
        ["isolcpus"]="${ISOLATE_START}-${ISOLATE_END}"
        ["nohz_full"]="${ISOLATE_START}-${ISOLATE_END}"
        ["rcu_nocbs"]="${ISOLATE_START}-${ISOLATE_END}"
        ["irqaffinity"]="0"
    )
fi
echo ""

# Check if grub file exists
if [[ ! -f "$GRUB_FILE" ]]; then
    echo "Error: $GRUB_FILE not found"
    exit 1
fi

# Store original content for comparison
ORIGINAL_CONTENT=$(cat "$GRUB_FILE")

# Single backup file (overwrite previous)
BACKUP_FILE="${GRUB_FILE}.bak"

# Track modifications
MODIFIED=false
declare -a CHANGES=()

# Function: Update cmdline with HFT params
update_cmdline_with_hft() {
    local original="$1"
    local -A parsed=()
    local result=""
    local -A handled=()

    # Parse original cmdline
    for opt in $original; do
        if [[ "$opt" == *"="* ]]; then
            local key="${opt%%=*}"
            local val="${opt#*=}"
            parsed["$key"]="$val"
        else
            parsed["$opt"]="__FLAG__"
        fi
    done

    # Apply HFT parameters (override existing)
    for key in "${!HFT_PARAMS[@]}"; do
        parsed["$key"]="${HFT_PARAMS[$key]}"
    done

    # Rebuild: preserve original order first
    for opt in $original; do
        local key
        if [[ "$opt" == *"="* ]]; then
            key="${opt%%=*}"
        else
            key="$opt"
        fi

        [[ -v "handled[$key]" ]] && continue
        [[ ! -v "parsed[$key]" ]] && continue
        handled["$key"]=1

        if [[ "${parsed[$key]}" == "__FLAG__" ]]; then
            result="$result $key"
        else
            result="$result $key=${parsed[$key]}"
        fi
    done

    # Add new params not in original
    for key in "${!HFT_PARAMS[@]}"; do
        if [[ ! -v "handled[$key]" ]]; then
            result="$result $key=${HFT_PARAMS[$key]}"
        fi
    done

    echo "$result" | sed 's/^ *//;s/ *$//'
}

# Function: Remove HFT params from cmdline (for GRUB_CMDLINE_LINUX cleanup)
remove_hft_from_cmdline() {
    local original="$1"
    local result=""

    for opt in $original; do
        local key
        if [[ "$opt" == *"="* ]]; then
            key="${opt%%=*}"
        else
            key="$opt"
        fi

        # Skip if it's an HFT param
        [[ -v "HFT_PARAMS[$key]" ]] && continue

        result="$result $opt"
    done

    echo "$result" | sed 's/^ *//;s/ *$//'
}

# Read and process the grub file
echo "Processing $GRUB_FILE..."
echo ""

TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
    # Check for GRUB_CMDLINE_LINUX_DEFAULT
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT= ]]; then
        # Extract value between quotes
        if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"$ ]]; then
            old_value="${BASH_REMATCH[1]}"
        else
            old_value=""
        fi

        new_value=$(update_cmdline_with_hft "$old_value")

        if [[ "$old_value" != "$new_value" ]]; then
            MODIFIED=true
            CHANGES+=("GRUB_CMDLINE_LINUX_DEFAULT:")
            CHANGES+=("  Old: \"$old_value\"")
            CHANGES+=("  New: \"$new_value\"")
        fi

        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"" >> "$TEMP_FILE"

    # Check for GRUB_CMDLINE_LINUX (non-default) - remove HFT params to avoid conflict
    elif [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
        # Extract value between quotes
        if [[ "$line" =~ ^GRUB_CMDLINE_LINUX=\"(.*)\"$ ]]; then
            old_value="${BASH_REMATCH[1]}"
        else
            old_value=""
        fi

        # Remove HFT params from this line to avoid conflicts
        new_value=$(remove_hft_from_cmdline "$old_value")

        if [[ "$old_value" != "$new_value" ]]; then
            MODIFIED=true
            CHANGES+=("GRUB_CMDLINE_LINUX (cleaned conflicts):")
            CHANGES+=("  Old: \"$old_value\"")
            CHANGES+=("  New: \"$new_value\"")
        fi

        echo "GRUB_CMDLINE_LINUX=\"$new_value\"" >> "$TEMP_FILE"

    # Check for commented GRUB_CMDLINE_LINUX - leave as is
    elif [[ "$line" =~ ^#[[:space:]]*GRUB_CMDLINE_LINUX ]]; then
        echo "$line" >> "$TEMP_FILE"

    # All other lines: pass through unchanged
    else
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$GRUB_FILE"

# Check if file was modified
if [[ "$MODIFIED" == true ]]; then
    # Create backup before modifying
    sudo cp "$GRUB_FILE" "$BACKUP_FILE"
    echo "Backup: $BACKUP_FILE"
    echo ""

    # Write the new file (use cat to preserve original permissions)
    cat "$TEMP_FILE" | sudo tee "$GRUB_FILE" > /dev/null

    echo -e "${BLUE}=== GRUB Configuration Updated ===${NC}"
    echo ""
    for change in "${CHANGES[@]}"; do
        echo -e "${BLUE}${change}${NC}"
    done
    echo ""

    echo -e "${BLUE}Current GRUB_CMDLINE settings:${NC}"
    grep "^GRUB_CMDLINE" "$GRUB_FILE" | while read -r line; do
        echo -e "${BLUE}  $line${NC}"
    done
    echo ""

    # Run update-grub
    echo "Running update-grub..."
    sudo update-grub
    echo ""

    echo -e "${GREEN}GRUB updated successfully. Changes will take effect after reboot.${NC}"
else
    echo -e "${GREEN}No changes needed. GRUB configuration is already optimized.${NC}"
fi
