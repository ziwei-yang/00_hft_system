#!/usr/bin/env bash
# Offline sandbox test suite for 00_sudo_script/03_grub_cpu_isolation.sh and verify_03_grub_cpu_isolation.sh.
# Requires GNU bash >= 4.3. NEVER touches real /etc, /boot, /sys, /proc, /var, or real sudo.
set -u

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "SKIP: test_grub_optimise.sh requires bash >= 4.3 (found ${BASH_VERSION}); run on Linux/Ubuntu 24.04"
    exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/00_sudo_script/03_grub_cpu_isolation.sh"
VERIFIER="$REPO/00_sudo_script/verify_03_grub_cpu_isolation.sh"
if [[ ! -f "$SCRIPT" || ! -f "$VERIFIER" ]]; then
    echo "FATAL: missing $SCRIPT or $VERIFIER" >&2
    exit 2
fi

T="$(mktemp -d /tmp/test_grub_optimise.XXXXXX)"
cleanup() {
    local base
    base="$(basename "$T")"
    if [[ -n "$base" && "$T" == "/tmp/test_grub_optimise."* ]]; then
        rm -rf /tmp/"$base"
    fi
}
trap cleanup EXIT

mkdir -p "$T/bin"

# Mock sudo: logs command and runs directly inside sandbox
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
    exit 0
fi
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
exec "$@"
EOF
chmod +x "$T/bin/sudo"

# Mock chown: no-op in unprivileged sandbox
cat > "$T/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/chown"

# Mock grub-editenv: prints key=val lines from grubenv
cat > "$T/bin/grub-editenv" <<'EOF'
#!/usr/bin/env bash
env_file="${1:-}"
cmd="${2:-list}"
if [[ "$cmd" == "list" && -r "$env_file" ]]; then
    grep -E '^[A-Za-z0-9_]+=' "$env_file" || true
fi
EOF
chmod +x "$T/bin/grub-editenv"

# Mock grub-script-check: checks balanced braces or forced failure flag
cat > "$T/bin/grub-script-check" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_GRUB_SCRIPT_CHECK_FAIL:-0}" == "1" ]]; then
    echo "fake grub-script-check syntax error" >&2
    exit 1
fi
[[ -r "${1:-}" ]]
EOF
chmod +x "$T/bin/grub-script-check"

# Realistic POSIX /bin/sh update-grub mock:
# Sources HFT_GRUB_FILE and all sorted HFT_GRUB_D_DIR/*.cfg via /bin/sh,
# then generates a real grub.cfg honoring FAKE_GRUB_DEFAULT_EXPR & FAKE_GRUB_EXTRA_ENTRIES.
cat > "$T/bin/update-grub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'update-grub\n' >> "${FAKE_UPDATE_GRUB_LOG:?}"
if [[ "${FAKE_UPDATE_GRUB_FAIL:-0}" == "1" ]]; then
    echo "fake update-grub failed" >&2
    exit 1
fi

grub_file="${HFT_GRUB_FILE:?}"
grub_d="${HFT_GRUB_D_DIR:?}"
grub_cfg="${HFT_GRUB_CFG:?}"
mkdir -p "$(dirname "$grub_cfg")"

eval_out="$(/bin/sh -c '
    set -e
    GRUB_DEFAULT="0"
    GRUB_CMDLINE_LINUX=""
    GRUB_CMDLINE_LINUX_DEFAULT=""
    . "$1"
    if [ -d "$2" ]; then
        for f in "$2"/*.cfg; do
            [ -f "$f" ] || continue
            . "$f"
        done
    fi
    printf "DEF=%s\n" "$GRUB_DEFAULT"
    printf "LINUX=%s\n" "$GRUB_CMDLINE_LINUX"
    printf "LINUX_DEF=%s\n" "$GRUB_CMDLINE_LINUX_DEFAULT"
' _ "$grub_file" "$grub_d")"

def_val="$(printf '%s\n' "$eval_out" | awk -F= '$1=="DEF"{sub(/^DEF=/,""); print; exit}')"
lin_val="$(printf '%s\n' "$eval_out" | awk -F= '$1=="LINUX"{sub(/^LINUX=/,""); print; exit}')"
lin_def="$(printf '%s\n' "$eval_out" | awk -F= '$1=="LINUX_DEF"{sub(/^LINUX_DEF=/,""); print; exit}')"

combined="$(printf '%s %s' "$lin_val" "$lin_def" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
if [[ "${FAKE_GRUB_DROP_CONSOLE:-0}" == "1" ]]; then
    combined="$(printf '%s\n' "$combined" | sed -E 's/console=[^ ]+//g')"
fi

default_stmt="${FAKE_GRUB_DEFAULT_STMT:-set default=\"${def_val}\"}"
cat > "$grub_cfg" <<CFG
if [ "\${next_entry}" ] ; then
   set default="\${next_entry}"
else
   ${default_stmt}
fi
menuentry 'Ubuntu' --class ubuntu --id 'gnulinux-simple-ubuntu' {
    linux /boot/vmlinuz-6.8.0 root=PARTUUID=1111-2222 ro ${combined}
    initrd /boot/initrd.img-6.8.0
}
menuentry 'Ubuntu (recovery mode)' --class ubuntu --id 'gnulinux-recovery-ubuntu' {
    linux /boot/vmlinuz-6.8.0 root=PARTUUID=1111-2222 ro recovery nomodeset
    initrd /boot/initrd.img-6.8.0
}
submenu 'Advanced options for Ubuntu' --id 'gnulinux-advanced-ubuntu' {
    menuentry 'Ubuntu, with Linux 6.8.0' --id 'gnulinux-6.8.0-advanced' {
        linux /boot/vmlinuz-6.8.0 root=PARTUUID=1111-2222 ro ${combined}
    }
}
CFG
EOF
chmod +x "$T/bin/update-grub"

export PATH="$T/bin:$PATH"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1 — $2"; FAIL=$((FAIL + 1)); }

make_sysfs() {
    local dir="$1"
    local smt="$2"
    shift 2
    rm -rf /tmp/"$(basename "$T")"/"${dir#$T/}"
    mkdir -p "$dir"
    if [[ "$smt" != "none" ]]; then
        mkdir -p "$dir/smt"
        echo "$smt" > "$dir/smt/active"
    fi
    local spec cpu sib onl
    for spec in "$@"; do
        IFS=':' read -r cpu sib onl <<< "$spec"
        mkdir -p "$dir/cpu${cpu}/topology"
        if [[ "$sib" != "__MISSING__" ]]; then
            echo "$sib" > "$dir/cpu${cpu}/topology/thread_siblings_list"
        fi
        if [[ "$onl" == "online0" ]]; then
            echo "0" > "$dir/cpu${cpu}/online"
        elif [[ "$onl" == "online1" ]]; then
            echo "1" > "$dir/cpu${cpu}/online"
        fi
    done
}

# Build a fresh case root directory under $T/<name>
init_case_root() {
    local name="$1"
    local vendor="$2"
    local boot_id="${3:-boot-id-1111}"
    local root="$T/case_${name}"
    rm -rf /tmp/"$(basename "$T")"/case_"$name"
    mkdir -p "$root/etc/default/grub.d" "$root/boot/grub" "$root/proc/sys/kernel/random" "$root/sys/devices/system/cpu" "$root/var/lib/hft-bootstrap"
    echo "$boot_id" > "$root/proc/sys/kernel/random/boot_id"
    printf 'processor\t: 0\nvendor_id\t: %s\n' "$vendor" > "$root/proc/cpuinfo"
    cat > "$root/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
EOF
    : > "$root/boot/grub/grubenv"
    printf '%s\n' "$root"
}

run_case() {
    local name="$1"
    local root="$2"
    local ec2="$3"
    local pcore="$4"
    shift 4

    [[ "$root" == "$T/"* ]] || { echo "GUARD FAIL: root outside sandbox: $root" >&2; exit 99; }
    : > "$T/sudo.log"
    : > "$T/update_grub.log"
    OUT_FILE="$T/${name}.out"

    set +e
    FAKE_SUDO_LOG="$T/sudo.log" \
    FAKE_UPDATE_GRUB_LOG="$T/update_grub.log" \
    HFT_ROOT="$root" \
    HFT_STATE_DIR="$root/var/lib/hft-bootstrap" \
    HFT_SKIP_OS_CHECK=1 \
    HFT_SKIP_PREREQS=1 \
    HFT_EC2_MODE="$ec2" \
    HFT_SUDO_CMD="$T/bin/sudo" \
    HFT_CHOWN_CMD="$T/bin/chown" \
    HFT_UPDATE_GRUB_CMD="$T/bin/update-grub" \
    HFT_GRUB_SCRIPT_CHECK_CMD="$T/bin/grub-script-check" \
    HFT_GRUB_EDITENV_CMD="$T/bin/grub-editenv" \
    HFT_GRUB_FILE="$root/etc/default/grub" \
    HFT_GRUB_D_DIR="$root/etc/default/grub.d" \
    HFT_GRUB_CFG="$root/boot/grub/grub.cfg" \
    HFT_GRUB_ENV="$root/boot/grub/grubenv" \
    HFT_GRUB_SYSFS_CPU_DIR="$root/sys/devices/system/cpu" \
    HFT_GRUB_PCORE_CPUS_FILE="$pcore" \
        bash "$SCRIPT" "$@" > "$OUT_FILE" 2>&1
    RC=$?
    set -e
}

# ==============================================================================
# Case 1: NUC 8P+8E HT + P-core check + preserves existing params
# ==============================================================================
echo "=== Case 1: NUC 8P+8E HT + P-core check ==="
R="$(init_case_root c1 GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 1 \
    0:0-1 1:0-1 2:2-3 3:2-3 4:4-5 5:4-5 6:6-7 7:6-7 \
    8:8-9 9:8-9 10:10-11 11:10-11 12:12-13 13:12-13 14:14-15 15:14-15 \
    16:16 17:17 18:18 19:19 20:20 21:21 22:22 23:23
echo "0-15" > "$R/pcore"
cat > "$R/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash isolcpus=1-2 pcie_aspm=off lockdown=none"
GRUB_CMDLINE_LINUX="rcu_nocbs=1-2 foo=bar"
EOF
run_case c1 "$R" 0 "$R/pcore"
if [[ $RC -eq 0 ]] \
   && grep -q "isolcpus=domain,managed_irq,2-7" "$R/boot/grub/grub.cfg" \
   && grep -q "nohz_full=2-7" "$R/boot/grub/grub.cfg" \
   && grep -q "rcu_nocbs=2-7" "$R/boot/grub/grub.cfg" \
   && grep -q "irqaffinity=0" "$R/boot/grub/grub.cfg" \
   && grep -q "pcie_aspm=off" "$R/boot/grub/grub.cfg" \
   && grep -q "foo=bar" "$R/boot/grub/grub.cfg" \
   && ! grep -q "intel_pstate=disable" "$R/boot/grub/grub.cfg" \
   && ! grep -q "idle=poll" "$R/boot/grub/grub.cfg" \
   && /bin/sh -n "$R/etc/default/grub.d/99-hft-isolation.cfg" \
   && grep -q "P-core check: PASS" "$OUT_FILE"; then
    ok "NUC 8P+8E -> isolcpus=domain,managed_irq,2-7 via POSIX drop-in, strips old keys, preserves non-HFT"
else
    bad "Case 1 NUC" "rc=$RC out=[$(tail -n 6 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 2: Intel EC2 4c/8vCPU + 50-cloudimg-settings.cfg preserved
# ==============================================================================
echo "=== Case 2: Intel EC2 4c/8vCPU + 50-cloudimg-settings.cfg ==="
R="$(init_case_root c2 GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 1 0:0,4 1:1,5 2:2,6 3:3,7 4:0,4 5:1,5 6:2,6 7:3,7
cat > "$R/etc/default/grub.d/50-cloudimg-settings.cfg" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295"
EOF
run_case c2 "$R" 1 "$R/no_pcore"
if [[ $RC -eq 0 ]] \
   && grep -q "console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295" "$R/boot/grub/grub.cfg" \
   && grep -q "isolcpus=domain,managed_irq,1-3,5-7" "$R/boot/grub/grub.cfg" \
   && grep -q "intel_pstate=disable" "$R/boot/grub/grub.cfg" \
   && ! grep -q "idle=poll" "$R/boot/grub/grub.cfg"; then
    ok "Intel EC2 4c/8vCPU preserves 50-cloudimg-settings.cfg + intel_pstate=disable, NO default idle=poll"
else
    bad "Case 2 Intel EC2" "rc=$RC out=[$(tail -n 6 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 3: AMD EC2 4c/8vCPU & 2c/4vCPU -> NO intel_pstate=disable, NO default idle=poll
# ==============================================================================
echo "=== Case 3: AMD EC2 4c & 2c + explicit --enable-idle-poll / --no-managed-irq ==="
R="$(init_case_root c3a AuthenticAMD)"
make_sysfs "$R/sys/devices/system/cpu" 1 0:0,4 1:1,5 2:2,6 3:3,7 4:0,4 5:1,5 6:2,6 7:3,7
run_case c3a "$R" 1 "$R/no_pcore"
ok_4c=0
if [[ $RC -eq 0 ]] \
   && grep -q "isolcpus=domain,managed_irq,1-3,5-7" "$R/boot/grub/grub.cfg" \
   && ! grep -q "intel_pstate=disable" "$R/boot/grub/grub.cfg" \
   && ! grep -q "idle=poll" "$R/boot/grub/grub.cfg"; then
    ok_4c=1
fi

R2="$(init_case_root c3b AuthenticAMD)"
make_sysfs "$R2/sys/devices/system/cpu" 1 0:0,2 1:1,3 2:0,2 3:1,3
run_case c3b "$R2" 1 "$R2/no_pcore" --enable-idle-poll --no-managed-irq
ok_2c=0
if [[ $RC -eq 0 ]] \
   && grep -q "isolcpus=1,3 " "$R2/boot/grub/grub.cfg" \
   && ! grep -q "managed_irq" "$R2/boot/grub/grub.cfg" \
   && ! grep -q "intel_pstate=disable" "$R2/boot/grub/grub.cfg" \
   && grep -q "idle=poll" "$R2/boot/grub/grub.cfg"; then
    ok_2c=1
fi

if [[ $ok_4c -eq 1 && $ok_2c -eq 1 ]]; then
    ok "AMD EC2 4c/2c omits intel_pstate=disable; --enable-idle-poll & --no-managed-irq work"
else
    bad "Case 3 AMD EC2" "ok_4c=$ok_4c ok_2c=$ok_2c out=[$(tail -n 6 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 4: 1-phys-core / partial offline / malformed siblings -> fail-closed
# ==============================================================================
echo "=== Case 4: Topology safety invariants (1p, partial offline, malformed siblings) ==="
R="$(init_case_root c4a GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 1 0:0-1 1:0-1
run_case c4a "$R" 1 "$R/no_pcore"
rc_1p=$RC

R="$(init_case_root c4b GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 1 0:0-1 1:0-1 2:2-3 3:2-3:online0
run_case c4b "$R" 0 "$R/no_pcore"
rc_part=$RC

R="$(init_case_root c4c GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 1 0:0-1 1:5-2 2:2-3 3:2-3
run_case c4c "$R" 0 "$R/no_pcore"
rc_bad=$RC

if [[ $rc_1p -ne 0 && $rc_part -ne 0 && $rc_bad -ne 0 ]]; then
    ok "1-phys-core, partial offline (smt=1), and inverted siblings all fail-closed"
else
    bad "Case 4 invariants" "rcs=$rc_1p,$rc_part,$rc_bad"
fi

# ==============================================================================
# Case 5: Post-99 grub.d override rejected fail-closed
# ==============================================================================
echo "=== Case 5: Post-99 grub.d/*.cfg override rejected ==="
R="$(init_case_root c5 GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
cat > "$R/etc/default/grub.d/99-zz-override.cfg" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
EOF
run_case c5 "$R" 0 "$R/no_pcore"
if [[ $RC -ne 0 ]] && grep -q "99-zz-override.cfg" "$OUT_FILE"; then
    ok "Later override 99-zz-override.cfg rejected fail-closed"
else
    bad "Case 5 post-99 override" "rc=$RC out=[$(tail -n 5 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 6: saved_entry, next_entry, submenu (>), recovery, dynamic default
# ==============================================================================
echo "=== Case 6: saved_entry / next_entry / submenu / recovery / dynamic default ==="
# 6a: valid saved_entry=gnulinux-simple-ubuntu -> PASS
R="$(init_case_root c6a GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
echo "saved_entry=gnulinux-simple-ubuntu" > "$R/boot/grub/grubenv"
FAKE_GRUB_DEFAULT_STMT='set default="${saved_entry}"' run_case c6a "$R" 0 "$R/no_pcore"
rc_6a=$RC

# 6b: next_entry pointing into submenu (contains '>') -> FAIL + rollback
R="$(init_case_root c6b GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
echo "next_entry=gnulinux-advanced-ubuntu>gnulinux-6.8.0-advanced" > "$R/boot/grub/grubenv"
echo "# orig grub.cfg" > "$R/boot/grub/grub.cfg"
cp "$R/boot/grub/grub.cfg" "$R/grub.cfg.orig"
run_case c6b "$R" 0 "$R/no_pcore"
rc_6b=$RC
rb_6b=0
[[ ! -e "$R/etc/default/grub.d/99-hft-isolation.cfg" ]] && cmp -s "$R/boot/grub/grub.cfg" "$R/grub.cfg.orig" && rb_6b=1

# 6c: next_entry pointing to recovery entry -> FAIL
R="$(init_case_root c6c GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
echo "next_entry=gnulinux-recovery-ubuntu" > "$R/boot/grub/grubenv"
run_case c6c "$R" 0 "$R/no_pcore"
rc_6c=$RC

# 6d: dynamic default expression -> FAIL
R="$(init_case_root c6d GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
FAKE_GRUB_DEFAULT_STMT='set default="${custom_dynamic_var}"' run_case c6d "$R" 0 "$R/no_pcore"
rc_6d=$RC

if [[ $rc_6a -eq 0 && $rc_6b -ne 0 && $rb_6b -eq 1 && $rc_6c -ne 0 && $rc_6d -ne 0 ]]; then
    ok "saved_entry passes; submenu (>), recovery, and dynamic default fail-closed with 3-state rollback"
else
    bad "Case 6 grubenv/submenu" "6a=$rc_6a 6b=$rc_6b(rb=$rb_6b) 6c=$rc_6c 6d=$rc_6d"
fi

# ==============================================================================
# Case 7: 3-state rollback on update-grub / grub-script-check failure
# ==============================================================================
echo "=== Case 7: 3-state rollback on update-grub & grub-script-check failure ==="
R="$(init_case_root c7 GenuineIntel)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3
echo "# previous dropin" > "$R/etc/default/grub.d/99-hft-isolation.cfg"
echo "# previous grub.cfg" > "$R/boot/grub/grub.cfg"
cp "$R/etc/default/grub" "$R/g.orig"
cp "$R/etc/default/grub.d/99-hft-isolation.cfg" "$R/d.orig"
cp "$R/boot/grub/grub.cfg" "$R/c.orig"

FAKE_GRUB_SCRIPT_CHECK_FAIL=1 run_case c7 "$R" 0 "$R/no_pcore"
if [[ $RC -ne 0 ]] \
   && cmp -s "$R/etc/default/grub" "$R/g.orig" \
   && cmp -s "$R/etc/default/grub.d/99-hft-isolation.cfg" "$R/d.orig" \
   && cmp -s "$R/boot/grub/grub.cfg" "$R/c.orig"; then
    ok "3-state originals (grub, 99-hft-isolation.cfg, grub.cfg) fully restored on verification failure"
else
    bad "Case 7 3-state rollback" "rc=$RC"
fi

# ==============================================================================
# Case 8: --dry-run, idempotency, and verify_03 --live boot_id reboot gate
# ==============================================================================
echo "=== Case 8: --dry-run, idempotency, and verify_03 --live boot_id gate ==="
R="$(init_case_root c8 GenuineIntel boot-id-AAAA)"
make_sysfs "$R/sys/devices/system/cpu" 0 0:0 1:1 2:2 3:3

# Dry-run writes nothing, no sudo
run_case c8_dry "$R" 0 "$R/no_pcore" --dry-run
dry_ok=0
[[ $RC -eq 0 && ! -e "$R/etc/default/grub.d/99-hft-isolation.cfg" && ! -s "$T/sudo.log" ]] && dry_ok=1

# Real apply
run_case c8_apply "$R" 0 "$R/no_pcore"
apply_ok=0
[[ $RC -eq 0 && -f "$R/var/lib/hft-bootstrap/grub_staged.state" ]] && apply_ok=1

# 2nd run idempotent (no update-grub)
run_case c8_idem "$R" 0 "$R/no_pcore"
idem_ok=0
[[ $RC -eq 0 && ! -s "$T/update_grub.log" ]] && grep -q "No changes needed" "$OUT_FILE" && idem_ok=1

# Prepare live /proc/cmdline & sysfs isolated BEFORE changing boot_id -> MUST FAIL reboot gate
echo "BOOT_IMAGE=/boot/vmlinuz isolcpus=domain,managed_irq,1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0" > "$R/proc/cmdline"
echo "1-3" > "$R/sys/devices/system/cpu/isolated"

set +e
HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_SKIP_OS_CHECK=1 \
HFT_GRUB_SCRIPT_CHECK_CMD="$T/bin/grub-script-check" HFT_GRUB_EDITENV_CMD="$T/bin/grub-editenv" \
    bash "$VERIFIER" --live > "$T/c8_live_before.out" 2>&1
rc_before_reboot=$?

# Simulate reboot by rotating boot_id
echo "boot-id-BBBB" > "$R/proc/sys/kernel/random/boot_id"
HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_SKIP_OS_CHECK=1 \
HFT_GRUB_SCRIPT_CHECK_CMD="$T/bin/grub-script-check" HFT_GRUB_EDITENV_CMD="$T/bin/grub-editenv" \
    bash "$VERIFIER" --live > "$T/c8_live_after.out" 2>&1
rc_after_reboot=$?
set -e

if [[ $dry_ok -eq 1 && $apply_ok -eq 1 && $idem_ok -eq 1 && $rc_before_reboot -ne 0 && $rc_after_reboot -eq 0 ]]; then
    ok "--dry-run clean, 2nd run idempotent, --live blocks pre-reboot and passes post-reboot"
else
    bad "Case 8 gate/idem" "dry=$dry_ok apply=$apply_ok idem=$idem_ok pre_rb=$rc_before_reboot post_rb=$rc_after_reboot"
fi

echo ""
echo "Summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
