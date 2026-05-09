#!/bin/bash
#
# 02_set_irq_to_cpu_zero.sh - Move all IRQs from isolated CPUs to CPU 0
#
# This script automatically moves all movable IRQs from isolated CPUs to CPU 0
# to prevent interrupt-induced latency on latency-sensitive processes.
#
# Usage: sudo ./02_set_irq_to_cpu_zero.sh
#
# No user input required - runs automatically.
#

set -u

# Target CPU for all IRQs
TARGET_CPU=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}=== Moving IRQs from Isolated CPUs to CPU $TARGET_CPU ===${NC}"
echo

# Get isolated CPUs
get_isolated_cpus() {
    local isolated=""
    if [ -f /sys/devices/system/cpu/isolated ]; then
        isolated=$(cat /sys/devices/system/cpu/isolated)
    fi
    if [ -z "$isolated" ]; then
        isolated=$(cat /proc/cmdline | grep -oP 'isolcpus=\K[^ ]+' || echo "")
    fi
    echo "$isolated"
}

# Expand CPU range (e.g., "1-10" -> "1 2 3 ... 10")
expand_cpu_range() {
    local range="$1"
    local result=""
    IFS=',' read -ra parts <<< "$range"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            local start=${part%-*}
            local end=${part#*-}
            for ((i=start; i<=end; i++)); do
                result="$result $i"
            done
        else
            result="$result $part"
        fi
    done
    echo $result
}

# Check if CPU is isolated
is_isolated_cpu() {
    local cpu=$1
    local isolated_list="$2"
    for iso_cpu in $isolated_list; do
        if [ "$cpu" -eq "$iso_cpu" ] 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Get isolated CPU list
isolated_range=$(get_isolated_cpus)
if [ -z "$isolated_range" ]; then
    echo -e "${YELLOW}No isolated CPUs found. Nothing to do.${NC}"
    exit 0
fi

isolated_cpus=$(expand_cpu_range "$isolated_range")
echo -e "Isolated CPUs: ${GREEN}$isolated_range${NC}"
echo -e "Target CPU:    ${GREEN}$TARGET_CPU${NC}"
echo

# Counters
moved=0
managed=0
failed=0

# Find and move IRQs
for irq_dir in /proc/irq/[0-9]*; do
    irq_num=$(basename "$irq_dir")
    [[ "$irq_num" =~ ^[0-9]+$ ]] || continue

    aff_file="$irq_dir/smp_affinity_list"
    [ -f "$aff_file" ] || continue

    aff=$(cat "$aff_file" 2>/dev/null) || continue
    aff_cpus=$(expand_cpu_range "$aff")

    # Check if any affinity CPU is isolated
    needs_move=0
    for cpu in $aff_cpus; do
        if is_isolated_cpu "$cpu" "$isolated_cpus"; then
            needs_move=1
            break
        fi
    done

    [ $needs_move -eq 0 ] && continue

    # Get device info
    device=$(awk -v irq="$irq_num:" '$1==irq {print $(NF-1), $NF}' /proc/interrupts 2>/dev/null)
    count=$(awk -v irq="$irq_num:" '$1==irq {sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}' /proc/interrupts 2>/dev/null)

    # Try to move IRQ
    if echo "$TARGET_CPU" > "$aff_file" 2>/dev/null; then
        echo -e "  IRQ $irq_num -> CPU $TARGET_CPU: ${GREEN}OK${NC} ($device, count: ${count:-0})"
        moved=$((moved + 1))
    else
        # Check if it's a managed IRQ (try writing current value back)
        if ! echo "$aff" > "$aff_file" 2>/dev/null; then
            echo -e "  IRQ $irq_num: ${YELLOW}MANAGED${NC} - driver-controlled ($device, count: ${count:-0})"
            managed=$((managed + 1))
        else
            echo -e "  IRQ $irq_num -> CPU $TARGET_CPU: ${RED}FAILED${NC} ($device)"
            failed=$((failed + 1))
        fi
    fi
done

echo
echo -e "${CYAN}=== Summary ===${NC}"
echo -e "  ${GREEN}Moved:   $moved${NC}"
echo -e "  ${YELLOW}Managed: $managed${NC} (driver-controlled, cannot move)"
echo -e "  ${RED}Failed:  $failed${NC}"

# Verify isolated CPUs are clean
echo
echo -e "${CYAN}=== Remaining IRQs on Isolated CPUs ===${NC}"
remaining=0
for irq_dir in /proc/irq/[0-9]*; do
    irq_num=$(basename "$irq_dir")
    [[ "$irq_num" =~ ^[0-9]+$ ]] || continue

    aff_file="$irq_dir/smp_affinity_list"
    [ -f "$aff_file" ] || continue

    aff=$(cat "$aff_file" 2>/dev/null) || continue
    aff_cpus=$(expand_cpu_range "$aff")

    for cpu in $aff_cpus; do
        if is_isolated_cpu "$cpu" "$isolated_cpus"; then
            count=$(awk -v irq="$irq_num:" '$1==irq {sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}' /proc/interrupts 2>/dev/null)
            device=$(awk -v irq="$irq_num:" '$1==irq {print $NF}' /proc/interrupts 2>/dev/null)
            echo -e "  IRQ $irq_num on CPU $aff: $device (count: ${count:-0})"
            remaining=$((remaining + 1))
            break
        fi
    done
done

if [ $remaining -eq 0 ]; then
    echo -e "  ${GREEN}None - all isolated CPUs are clean!${NC}"
else
    echo -e "  ${YELLOW}$remaining IRQs remain (managed by drivers, low interrupt count is OK)${NC}"
fi

echo
echo -e "${GREEN}Done.${NC}"
