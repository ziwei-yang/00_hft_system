#!/usr/bin/env bash
# Offline unit test suite for 00_sudo_script/00_grub_optimise.sh (13 scenarios).
# Runs on bash >= 4.3 (Ubuntu Linux / NUC isolated compile_check directory).
# Hard sandbox guards ensure real sudo, real update-grub, /etc/default/grub, and /sys are NEVER touched.
set -u

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "SKIP: test_grub_optimise.sh requires bash >= 4.3 (found ${BASH_VERSION}); run on Linux/NUC compile_check"
    exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/00_sudo_script/00_grub_optimise.sh"
if [[ ! -f "$SCRIPT" ]]; then
    echo "FATAL: script not found: $SCRIPT" >&2
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

cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
    exit 0
fi
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:?}"
exec "$@"
EOF
chmod +x "$T/bin/sudo"

cat > "$T/bin/update-grub" <<'EOF'
#!/usr/bin/env bash
printf 'update-grub\n' >> "${FAKE_UPDATE_GRUB_LOG:?}"
if [[ "${FAKE_UPDATE_GRUB_FAIL:-0}" == "1" ]]; then
    echo "fake update-grub failed" >&2
    exit 1
fi
echo "Generating grub configuration file ... done"
exit 0
EOF
chmod +x "$T/bin/update-grub"

cat > "$T/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_NPROC:-4}"
EOF
chmod +x "$T/bin/nproc"

export PATH="$T/bin:$PATH"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1 — $2"; FAIL=$((FAIL + 1)); }

assert_sandbox_guards() {
    local grub_path="$1"
    local sysfs_dir="$2"
    local pcore_file="$3"
    local grub_d_dir="$4"
    [[ "$(command -v sudo)" == "$T/bin/sudo" ]] || { echo "GUARD FAIL: sudo is $(command -v sudo)" >&2; exit 99; }
    [[ "$(command -v update-grub)" == "$T/bin/update-grub" ]] || { echo "GUARD FAIL: update-grub is $(command -v update-grub)" >&2; exit 99; }
    [[ "$grub_path" == "$T/"* ]] || { echo "GUARD FAIL: grub_path outside sandbox: $grub_path" >&2; exit 99; }
    [[ "$sysfs_dir" == "$T/"* ]] || { echo "GUARD FAIL: sysfs_dir outside sandbox: $sysfs_dir" >&2; exit 99; }
    [[ "$pcore_file" == "$T/"* ]] || { echo "GUARD FAIL: pcore_file outside sandbox: $pcore_file" >&2; exit 99; }
    [[ "$grub_d_dir" == "$T/"* ]] || { echo "GUARD FAIL: grub_d_dir outside sandbox: $grub_d_dir" >&2; exit 99; }
}

# Helper: build mock sysfs CPU tree
# Usage: make_sysfs <dir> <smt_active:0|1|none> <spec...>
# Each spec is "<cpu_id>:<siblings_list>[:online0|online1]"
make_sysfs() {
    local dir="$1"
    local smt="$2"
    shift 2
    rm -rf /tmp/"$(basename "$T")"/"$(basename "$dir")"
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

make_grub() {
    local f="$1"
    local def_line="$2"
    local linux_line="${3:-GRUB_CMDLINE_LINUX=\"\"}"
    cat > "$f" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=1
$def_line
$linux_line
EOF
}

run_case() {
    local name="$1"
    local grub_path="$2"
    local sysfs_dir="$3"
    local pcore_file="$4"
    local grub_d_dir="$5"
    local ec2_mode="$6"
    local nproc_val="$7"
    shift 7

    assert_sandbox_guards "$grub_path" "$sysfs_dir" "$pcore_file" "$grub_d_dir"
    : > "$T/sudo.log"
    : > "$T/update_grub.log"

    OUT_FILE="$T/${name}.out"
    set +e
    FAKE_SUDO_LOG="$T/sudo.log" \
    FAKE_UPDATE_GRUB_LOG="$T/update_grub.log" \
    FAKE_NPROC="$nproc_val" \
    HFT_GRUB_SYSFS_CPU_DIR="$sysfs_dir" \
    HFT_GRUB_PCORE_CPUS_FILE="$pcore_file" \
    HFT_GRUB_D_DIR="$grub_d_dir" \
    HFT_GRUB_EC2_MODE="$ec2_mode" \
    HFT_GRUB_SUDO="$T/bin/sudo" \
    HFT_GRUB_UPDATE_CMD="$T/bin/update-grub" \
        bash "$SCRIPT" "$grub_path" "$@" > "$OUT_FILE" 2>&1
    RC=$?
    set -e
}

get_default_cmdline() {
    grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$1" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"[[:space:]]*$/\1/'
}

# ==============================================================================
# Case 1: NUC 16 physical cores (8P adjacent HT 0-1..14-15 + 8E 16..23) + P-core check
# ==============================================================================
echo "=== Case 1: NUC 16 physical cores (8P HT + 8E) ==="
make_sysfs "$T/sys_nuc" 1 \
    0:0-1 1:0-1 2:2-3 3:2-3 4:4-5 5:4-5 6:6-7 7:6-7 \
    8:8-9 9:8-9 10:10-11 11:10-11 12:12-13 13:12-13 14:14-15 15:14-15 \
    16:16 17:17 18:18 19:19 20:20 21:21 22:22 23:23
echo "0-15" > "$T/pcore_nuc"
mkdir -p "$T/grubd_empty"
make_grub "$T/grub_c1" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash irqaffinity=0 nohz_full=1-2 isolcpus=1-2 rcu_nocbs=1-2 pcie_aspm=off pcie_aspm.policy=performance intel_idle.max_cstate=0 lockdown=none"'
run_case c1 "$T/grub_c1" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
cl=$(get_default_cmdline "$T/grub_c1")
if [[ $RC -eq 0 ]] \
   && [[ "$cl" == *"isolcpus=2-7"* ]] \
   && [[ "$cl" == *"nohz_full=2-7"* ]] \
   && [[ "$cl" == *"rcu_nocbs=2-7"* ]] \
   && [[ "$cl" == *"irqaffinity=0"* ]] \
   && [[ "$cl" == *"pcie_aspm=off"* ]] \
   && [[ "$cl" == *"intel_idle.max_cstate=0"* ]] \
   && [[ "$cl" == *"lockdown=none"* ]] \
   && grep -q "P-core check: PASS" "$OUT_FILE"; then
    ok "NUC 8P+8E HT -> isolcpus=2-7, preserves non-HFT params, P-core check PASS"
else
    bad "Case 1 NUC" "rc=$RC cl=[$cl] out=[$(tail -n 5 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 2: AWS c7i.2xlarge (4 phys / 8 vCPU strided HT: 0,4 / 1,5 / 2,6 / 3,7)
# ==============================================================================
echo "=== Case 2: AWS c7i.2xlarge (4 phys / 8 vCPU strided HT, EC2) ==="
make_sysfs "$T/sys_aws4_ht" 1 0:0,4 1:1,5 2:2,6 3:3,7 4:0,4 5:1,5 6:2,6 7:3,7
make_grub "$T/grub_c2" 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"'
run_case c2 "$T/grub_c2" "$T/sys_aws4_ht" "$T/no_pcore" "$T/grubd_empty" 1 8
cl=$(get_default_cmdline "$T/grub_c2")
if [[ $RC -eq 0 ]] \
   && [[ "$cl" == *"isolcpus=1-3,5-7"* ]] \
   && [[ "$cl" == *"nohz_full=1-3,5-7"* ]] \
   && [[ "$cl" == *"rcu_nocbs=1-3,5-7"* ]] \
   && [[ "$cl" == *"irqaffinity=0"* ]] \
   && [[ "$cl" == *"intel_pstate=disable"* ]] \
   && [[ "$cl" == *"processor.max_cstate=0"* ]] \
   && [[ "$cl" == *"idle=poll"* ]] \
   && grep -qi "idle=poll" "$OUT_FILE"; then
    ok "AWS 4-phys 8-vCPU strided HT -> 1-3,5-7 (0,4 untouched) + EC2 params"
else
    bad "Case 2 AWS 4p HT" "rc=$RC cl=[$cl]"
fi

# ==============================================================================
# Case 3: AWS 4 phys cores, HT OFF (ThreadsPerCore=1)
# ==============================================================================
echo "=== Case 3: AWS 4 phys cores, HT OFF ==="
make_sysfs "$T/sys_aws4_noht" 0 0:0 1:1 2:2 3:3
make_grub "$T/grub_c3" 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"'
run_case c3 "$T/grub_c3" "$T/sys_aws4_noht" "$T/no_pcore" "$T/grubd_empty" 1 4
cl=$(get_default_cmdline "$T/grub_c3")
if [[ $RC -eq 0 && "$cl" == *"isolcpus=1-3"* && "$cl" == *"nohz_full=1-3"* && "$cl" == *"rcu_nocbs=1-3"* ]]; then
    ok "AWS 4-phys HT OFF -> 1-3"
else
    bad "Case 3 AWS 4p no-HT" "rc=$RC cl=[$cl]"
fi

# ==============================================================================
# Case 4: AWS c7i.xlarge (2 phys / 4 vCPU strided HT: 0,2 / 1,3)
# ==============================================================================
echo "=== Case 4: AWS 2 phys / 4 vCPU strided HT ==="
make_sysfs "$T/sys_aws2_ht" 1 0:0,2 1:1,3 2:0,2 3:1,3
make_grub "$T/grub_c4" 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"'
run_case c4 "$T/grub_c4" "$T/sys_aws2_ht" "$T/no_pcore" "$T/grubd_empty" 1 4
cl=$(get_default_cmdline "$T/grub_c4")
if [[ $RC -eq 0 && "$cl" == *"isolcpus=1,3"* && "$cl" == *"nohz_full=1,3"* && "$cl" == *"rcu_nocbs=1,3"* ]]; then
    ok "AWS 2-phys 4-vCPU strided HT -> 1,3 (0,2 untouched)"
else
    bad "Case 4 AWS 2p HT" "rc=$RC cl=[$cl]"
fi

# ==============================================================================
# Case 5: AWS 2 phys cores, HT OFF
# ==============================================================================
echo "=== Case 5: AWS 2 phys cores, HT OFF ==="
make_sysfs "$T/sys_aws2_noht" 0 0:0 1:1
make_grub "$T/grub_c5" 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"'
run_case c5 "$T/grub_c5" "$T/sys_aws2_noht" "$T/no_pcore" "$T/grubd_empty" 1 2
cl=$(get_default_cmdline "$T/grub_c5")
if [[ $RC -eq 0 && "$cl" == *"isolcpus=1 "* || ( $RC -eq 0 && "$cl" =~ isolcpus=1($|[[:space:]]) ) ]]; then
    ok "AWS 2-phys HT OFF -> 1"
else
    bad "Case 5 AWS 2p no-HT" "rc=$RC cl=[$cl]"
fi

# ==============================================================================
# Case 6: 3 phys cores, HT ON (strided 0,3 / 1,4 / 2,5)
# ==============================================================================
echo "=== Case 6: 3 phys cores, HT ON ==="
make_sysfs "$T/sys_3p_ht" 1 0:0,3 1:1,4 2:2,5 3:0,3 4:1,4 5:2,5
make_grub "$T/grub_c6" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c6 "$T/grub_c6" "$T/sys_3p_ht" "$T/no_pcore" "$T/grubd_empty" 0 6
cl=$(get_default_cmdline "$T/grub_c6")
if [[ $RC -eq 0 && "$cl" == *"isolcpus=1-2,4-5"* ]]; then
    ok "3-phys HT ON -> 1-2,4-5"
else
    bad "Case 6 3p HT" "rc=$RC cl=[$cl]"
fi

# ==============================================================================
# Case 7: 1 phys core / 2 vCPU HT ON (e.g. c7i.large) -> must refuse
# ==============================================================================
echo "=== Case 7: 1 phys core / 2 vCPU HT -> fail-closed ==="
make_sysfs "$T/sys_1p_ht" 1 0:0-1 1:0-1
make_grub "$T/grub_c7" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c7 "$T/grub_c7" "$T/sys_1p_ht" "$T/no_pcore" "$T/grubd_empty" 1 2
if [[ $RC -ne 0 ]]; then
    ok "1-phys 2-vCPU HT refused (rc=$RC)"
else
    bad "Case 7 1p HT" "expected non-zero exit, got rc=0"
fi

# ==============================================================================
# Case 8a & 8b: nosmt (adjacent odd CPUs offline -> 2,4,6) vs partial offline (smt=1 -> refuse)
# ==============================================================================
echo "=== Case 8a/8b: nosmt vs partial offline ==="
make_sysfs "$T/sys_nosmt" 0 \
    0:0 1:1:online0 2:2 3:3:online0 4:4 5:5:online0 6:6 7:7:online0 8:8 9:9:online0
make_grub "$T/grub_c8a" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c8a "$T/grub_c8a" "$T/sys_nosmt" "$T/no_pcore" "$T/grubd_empty" 0 10
cl=$(get_default_cmdline "$T/grub_c8a")
if [[ $RC -eq 0 && "$cl" == *"isolcpus=2,4,6"* ]] && grep -qi "nosmt" "$OUT_FILE"; then
    ok "nosmt adjacent topology -> 2,4,6 + re-run warning"
else
    bad "Case 8a nosmt" "rc=$RC cl=[$cl] out=[$(tail -n 5 "$OUT_FILE")]"
fi

make_sysfs "$T/sys_part_off" 1 0:0-1 1:0-1 2:2-3 3:2-3:online0 4:4-5 5:4-5 6:6-7 7:6-7
make_grub "$T/grub_c8b" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c8b "$T/grub_c8b" "$T/sys_part_off" "$T/no_pcore" "$T/grubd_empty" 0 8
if [[ $RC -ne 0 ]]; then
    ok "partial offline while smt=1 refused (rc=$RC)"
else
    bad "Case 8b partial offline" "expected non-zero exit, got rc=0"
fi

# ==============================================================================
# Case 9: missing or malformed thread_siblings_list -> fail-closed
# ==============================================================================
echo "=== Case 9: missing / malformed thread_siblings_list ==="
make_sysfs "$T/sys_miss" 1 0:__MISSING__ 1:0-1 2:2-3 3:2-3
make_grub "$T/grub_c9a" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c9a "$T/grub_c9a" "$T/sys_miss" "$T/no_pcore" "$T/grubd_empty" 0 4
rc_miss=$RC

make_sysfs "$T/sys_bad1" 1 0:0-1 1:a-b 2:2-3 3:2-3
make_grub "$T/grub_c9b" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c9b "$T/grub_c9b" "$T/sys_bad1" "$T/no_pcore" "$T/grubd_empty" 0 4
rc_bad1=$RC

make_sysfs "$T/sys_bad2" 1 0:0-1 1:1-2-3 2:2-3 3:2-3
make_grub "$T/grub_c9c" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c9c "$T/grub_c9c" "$T/sys_bad2" "$T/no_pcore" "$T/grubd_empty" 0 4
rc_bad2=$RC

make_sysfs "$T/sys_bad3" 1 0:0-1 1:5-2 2:2-3 3:2-3
make_grub "$T/grub_c9d" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c9d "$T/grub_c9d" "$T/sys_bad3" "$T/no_pcore" "$T/grubd_empty" 0 4
rc_bad3=$RC

if [[ $rc_miss -ne 0 && $rc_bad1 -ne 0 && $rc_bad2 -ne 0 && $rc_bad3 -ne 0 ]]; then
    ok "missing / a-b / 1-2-3 / 5-2 siblings_list all refused"
else
    bad "Case 9 malformed siblings" "rcs=$rc_miss,$rc_bad1,$rc_bad2,$rc_bad3"
fi

# ==============================================================================
# Case 10: GRUB malformed quote / missing line / duplicate line -> fail-closed & untouched
# ==============================================================================
echo "=== Case 10: GRUB malformed / missing / duplicate DEFAULT ==="
make_grub "$T/grub_c10a" "GRUB_CMDLINE_LINUX_DEFAULT='quiet'"
cp "$T/grub_c10a" "$T/grub_c10a.orig"
run_case c10a "$T/grub_c10a" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
rc_10a=$RC

cat > "$T/grub_c10b" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX=""
EOF
cp "$T/grub_c10b" "$T/grub_c10b.orig"
run_case c10b "$T/grub_c10b" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
rc_10b=$RC

cat > "$T/grub_c10c" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX_DEFAULT="splash"
GRUB_CMDLINE_LINUX=""
EOF
cp "$T/grub_c10c" "$T/grub_c10c.orig"
run_case c10c "$T/grub_c10c" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
rc_10c=$RC

if [[ $rc_10a -ne 0 && $rc_10b -ne 0 && $rc_10c -ne 0 ]] \
   && cmp -s "$T/grub_c10a" "$T/grub_c10a.orig" \
   && cmp -s "$T/grub_c10b" "$T/grub_c10b.orig" \
   && cmp -s "$T/grub_c10c" "$T/grub_c10c.orig"; then
    ok "single-quote / missing / duplicate DEFAULT refused without modifying file"
else
    bad "Case 10 GRUB format" "rcs=$rc_10a,$rc_10b,$rc_10c"
fi

# ==============================================================================
# Case 11: grub.d/*.cfg override detection -> fail-closed
# ==============================================================================
echo "=== Case 11: grub.d/*.cfg override detection ==="
mkdir -p "$T/grubd_override"
cat > "$T/grubd_override/50-cloudimg-settings.cfg" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0"
EOF
make_grub "$T/grub_c11" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"'
run_case c11 "$T/grub_c11" "$T/sys_aws4_ht" "$T/no_pcore" "$T/grubd_override" 1 8
if [[ $RC -ne 0 ]] && grep -q "50-cloudimg-settings.cfg" "$OUT_FILE"; then
    ok "grub.d override detected and refused with filename"
else
    bad "Case 11 grub.d override" "rc=$RC out=[$(tail -n 5 "$OUT_FILE")]"
fi

# ==============================================================================
# Case 12: Real write + .bak + GRUB_CMDLINE_LINUX cleanup + 2nd run idempotent + --dry-run
# ==============================================================================
echo "=== Case 12: Real write, .bak, conflict cleanup, idempotency, --dry-run ==="
make_grub "$T/grub_c12" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_CMDLINE_LINUX="isolcpus=1-2 foo=bar"'
cp "$T/grub_c12" "$T/grub_c12.orig"
# First --dry-run must NOT modify file or invoke sudo
run_case c12_dry "$T/grub_c12" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24 --dry-run
rc_dry=$RC
dry_untouched=0
cmp -s "$T/grub_c12" "$T/grub_c12.orig" && [[ ! -s "$T/sudo.log" ]] && dry_untouched=1

# Real write
run_case c12_w1 "$T/grub_c12" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
rc_w1=$RC
bak_ok=0
cmp -s "$T/grub_c12.bak" "$T/grub_c12.orig" && bak_ok=1
linux_cleaned=0
grep -q '^GRUB_CMDLINE_LINUX="foo=bar"$' "$T/grub_c12" && linux_cleaned=1
cp "$T/grub_c12" "$T/grub_c12.after1"

# 2nd run must be idempotent and NOT invoke sudo or update-grub
run_case c12_w2 "$T/grub_c12" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
rc_w2=$RC
idem_ok=0
cmp -s "$T/grub_c12" "$T/grub_c12.after1" && [[ ! -s "$T/sudo.log" ]] && [[ ! -s "$T/update_grub.log" ]] && grep -q "No changes needed" "$OUT_FILE" && idem_ok=1

if [[ $rc_dry -eq 0 && $dry_untouched -eq 1 && $rc_w1 -eq 0 && $bak_ok -eq 1 && $linux_cleaned -eq 1 && $rc_w2 -eq 0 && $idem_ok -eq 1 ]]; then
    ok "--dry-run clean, real write + .bak + GRUB_CMDLINE_LINUX cleanup + 2nd run idempotent"
else
    bad "Case 12 write/idempotency" "dry=$rc_dry/$dry_untouched w1=$rc_w1 bak=$bak_ok clean=$linux_cleaned w2=$rc_w2 idem=$idem_ok"
fi

# ==============================================================================
# Case 13: update-grub failure -> auto-rollback $GRUB_FILE from .bak
# ==============================================================================
echo "=== Case 13: update-grub failure auto-rollback ==="
make_grub "$T/grub_c13" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet isolcpus=1-2"'
cp "$T/grub_c13" "$T/grub_c13.orig"
FAKE_UPDATE_GRUB_FAIL=1 run_case c13 "$T/grub_c13" "$T/sys_nuc" "$T/pcore_nuc" "$T/grubd_empty" 0 24
if [[ $RC -ne 0 ]] && cmp -s "$T/grub_c13" "$T/grub_c13.orig"; then
    ok "update-grub failure exited non-zero and restored original grub file"
else
    bad "Case 13 rollback" "rc=$RC cmp=$(cmp -s "$T/grub_c13" "$T/grub_c13.orig" && echo same || echo DIFF)"
fi

echo ""
echo "Summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
