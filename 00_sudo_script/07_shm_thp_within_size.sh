#!/bin/bash
# Enable transparent hugepages (2MB) for /dev/shm tmpfs: huge=within_size.
#
# Why: the MktEvent ring (websocket_pb, 2 GiB at 2KB slots) and the other
# hftshm rings live on /dev/shm. With default 4KB pages a 2 GiB ring is
# ~524k TLB entries — wrap-around access DTLB-misses constantly. With
# huge=within_size the kernel backs tmpfs files with 2MB THP pages up to
# each file's size (2 GiB ring -> ~1024 entries, fits DTLB).
#
# This is a DIFFERENT mechanism from 01_hugepage_2MBx512.sh: that script
# reserves an explicit hugetlbfs pool (vm.nr_hugepages) for DPDK UMEM.
# THP pages come from the general page pool via compaction and do NOT
# consume that reservation. Both coexist.
#
# On 6.x mTHP kernels the mount option alone is not sufficient: the sysfs
# chain (global shmem_enabled + per-size hugepages-2048kB/shmem_enabled)
# gates shmem THP as well — this script sets all of them to within_size
# and persists the sysfs knobs via /etc/tmpfiles.d/.
#
# Effect on running processes: none at remount time — existing mappings
# keep their 4KB pages; 2MB pages appear when a file's pages are next
# faulted (e.g. the pipeline recreates its ring on restart).
# Verify after a ring recreation:
#   grep ShmemPmdMapped /proc/<pid-mapping-the-ring>/smaps  (should be ~RSS)
# MEASUREMENT GOTCHA: probe from a process with THP_enabled: 1
# (grep THP /proc/self/status) — some sandboxes/daemons set
# PR_SET_THP_DISABLE, which children inherit and which silently zeroes
# every THP probe result.

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Error: Linux only." >&2
    exit 1
fi

# Check sudo without password
if ! sudo -n true 2>/dev/null; then
    echo "Error: sudo requires password. Configure NOPASSWD or run 'sudo -v' first" >&2
    exit 1
fi

FSTAB_LINE='tmpfs  /dev/shm  tmpfs  defaults,huge=within_size  0  0'

# 1) Runtime: remount with the option (idempotent; preserves contents and
#    running mappings).
if mount | grep -E '^tmpfs on /dev/shm ' | grep -q 'huge=within_size'; then
    echo "/dev/shm already mounted with huge=within_size"
else
    echo "Remounting /dev/shm with huge=within_size..."
    sudo mount -o remount,huge=within_size /dev/shm
fi

# 2) Persistence: ensure the fstab entry exists (systemd's fstab-generator
#    overrides the default dev-shm.mount with it).
if grep -Eq '^\s*tmpfs\s+/dev/shm\s+tmpfs\s+.*huge=within_size' /etc/fstab; then
    echo "/etc/fstab already carries the huge=within_size entry"
elif grep -Eq '^\s*tmpfs\s+/dev/shm\s' /etc/fstab; then
    echo "Error: /etc/fstab has a /dev/shm line WITHOUT huge=within_size —" >&2
    echo "       edit it manually (refusing to rewrite an existing entry)." >&2
    exit 1
else
    sudo cp /etc/fstab /etc/fstab.bak
    echo "Backup: /etc/fstab.bak"
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
    echo "Added to /etc/fstab: $FSTAB_LINE"
fi

# 3) sysfs THP chain (mTHP kernels): global + PMD-size shmem_enabled.
#    Runtime writes + persistence via systemd-tmpfiles.
for knob in /sys/kernel/mm/transparent_hugepage/shmem_enabled \
            /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled; do
    if [ -f "$knob" ]; then
        if grep -q '\[within_size\]' "$knob"; then
            echo "$knob already within_size"
        else
            echo within_size | sudo tee "$knob" > /dev/null
            echo "set $knob = within_size"
        fi
    fi
done

TMPFILES=/etc/tmpfiles.d/hft-shm-thp.conf
if [ -f "$TMPFILES" ]; then
    echo "$TMPFILES already present"
else
    sudo tee "$TMPFILES" > /dev/null <<'CONF'
# hft: shmem transparent hugepages (pairs with the /dev/shm huge=within_size
# fstab entry; see 00_hft_system/00_sudo_script/07_shm_thp_within_size.sh)
w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - within_size
w /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled - - - - within_size
CONF
    echo "Wrote $TMPFILES"
fi

echo ""
echo "=== Verification ==="
mount | grep '/dev/shm'
grep '/dev/shm' /etc/fstab
cat /sys/kernel/mm/transparent_hugepage/shmem_enabled
cat /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled 2>/dev/null
echo ""
echo "Done. 2MB THP takes effect per-file on next page fault (e.g. ring"
echo "recreation at the next pipeline restart)."
