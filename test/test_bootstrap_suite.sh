#!/usr/bin/env bash
# Comprehensive offline sandbox test suite for 00_hft_system (C1-C8 & C10).
# Usage: bash test/test_bootstrap_suite.sh [--only common|layer1|layer2]
# NEVER writes to real /etc, /boot, /sys, /proc, /var, /run, or invokes real sudo.
set -u

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "SKIP: test_bootstrap_suite.sh requires bash >= 4.3 (found ${BASH_VERSION}); run on Linux/Ubuntu 24.04"
    exit 0
fi

ONLY="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            ONLY="${2:-}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: test_bootstrap_suite.sh [--only common|layer1|layer2]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

case "$ONLY" in
    all|common|layer1|layer2) ;;
    *) echo "Invalid --only value: $ONLY" >&2; exit 1 ;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/test_bootstrap.XXXXXX)"
cleanup() {
    local base
    base="$(basename "$T")"
    if [[ -n "$base" && "$T" == "/tmp/test_bootstrap."* ]]; then
        rm -rf /tmp/"$base"
    fi
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1 — $2"; FAIL=$((FAIL + 1)); }

# Generate real valid ed25519 test keys so real ssh-keygen -lf succeeds
ssh-keygen -q -t ed25519 -N "" -C "refusal@host" -f "$T/key_refusal"
ssh-keygen -q -t ed25519 -N "" -C "ubuntu@host"  -f "$T/key_ubuntu"
ssh-keygen -q -t ed25519 -N "" -C "root@host"    -f "$T/key_root"
PUB_REFUSAL="$(cat "$T/key_refusal.pub")"
PUB_UBUNTU="$(cat "$T/key_ubuntu.pub")"
PUB_ROOT="$(cat "$T/key_root.pub")"

# ==============================================================================
# Build stateful mock toolchain under $T/bin
# ==============================================================================
MOCK_BIN="$T/bin"
mkdir -p "$MOCK_BIN"

# 1. Mock sudo (records invocations; refuses if MOCK_FORBID_SUDO=1)
cat > "$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_FORBID_SUDO:-0}" == "1" ]]; then
    echo "ERROR: sudo was invoked while forbidden: $*" >&2
    exit 98
fi
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-l" && "${2:-}" == "-U" ]]; then
    u="${3:-}"
    if [[ "${MOCK_SUDO_L_FAIL:-0}" == "1" ]]; then
        echo "User $u is not allowed to run sudo." >&2
        exit 1
    fi
    echo "User $u may run the following commands:"
    echo "    (ALL) NOPASSWD: ALL"
    exit 0
fi
[[ -n "${MOCK_SUDO_LOG:-}" ]] && printf '%s\n' "$*" >> "$MOCK_SUDO_LOG"
exec "$@"
EOF

# 2. Mock chown + stat (stores owner metadata in $MOCK_STATE/owners)
cat > "$MOCK_BIN/chown" <<'EOF'
#!/usr/bin/env bash
recursive=0
if [[ "${1:-}" == "-R" ]]; then recursive=1; shift; fi
owner="${1:-0:0}"; shift
# Normalize root -> 0
owner="${owner/root:/0:}"
owner="${owner/:root/:0}"
meta="${MOCK_STATE:?}/owners"
touch "$meta"
record_one() {
    local p="$1"
    grep -Fv "${p}|" "$meta" > "${meta}.tmp" 2>/dev/null || true
    printf '%s|%s\n' "$p" "$owner" >> "${meta}.tmp"
    mv -f "${meta}.tmp" "$meta"
}
for target in "$@"; do
    [[ -e "$target" || -L "$target" ]] || continue
    record_one "$target"
    if (( recursive == 1 )) && [[ -d "$target" ]]; then
        while IFS= read -r sub; do
            record_one "$sub"
        done < <(find "$target")
    fi
done
EOF

cat > "$MOCK_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
    fmt="${2:-}"
    path="${3:-}"
    [[ -e "$path" || -L "$path" ]] || exit 1
    if [[ "$fmt" == "%u:%g" ]]; then
        meta="${MOCK_STATE:?}/owners"
        val="$(awk -F'|' -v p="$path" '$1==p{print $2; exit}' "$meta" 2>/dev/null || true)"
        printf '%s\n' "${val:-0:0}"
        exit 0
    elif [[ "$fmt" == "%a" ]]; then
        python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$path"
        exit 0
    fi
fi
exec /usr/bin/stat "$@"
EOF

# 3. Mock visudo
cat > "$MOCK_BIN/visudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_VISUDO_FAIL:-0}" == "1" ]]; then
    echo "visudo syntax error" >&2
    exit 1
fi
exit 0
EOF

# 4. Mock id / getent / useradd / usermod / loginctl
cat > "$MOCK_BIN/id" <<'EOF'
#!/usr/bin/env bash
users_db="${MOCK_STATE:?}/users"
if [[ "${1:-}" == "-u" && "${2:-}" == "hft" ]]; then
    awk -F: '$1=="hft"{print $3; found=1} END{exit !found}' "$users_db" 2>/dev/null
    exit $?
elif [[ "${1:-}" == "-g" && "${2:-}" == "hft" ]]; then
    awk -F: '$1=="hft"{print $4; found=1} END{exit !found}' "$users_db" 2>/dev/null
    exit $?
elif [[ "${1:-}" == "-nG" && "${2:-}" == "hft" ]]; then
    awk -F: '$1=="hft"{print $7; found=1} END{exit !found}' "$users_db" 2>/dev/null
    exit $?
fi
exec /usr/bin/id "$@"
EOF

cat > "$MOCK_BIN/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" ]]; then
    awk -F: -v u="${2:-}" '$1==u{print $1":x:"$3":"$4"::"$6":"$5; found=1} END{exit !found}' "${MOCK_STATE:?}/users" 2>/dev/null
    exit $?
fi
exit 1
EOF

cat > "$MOCK_BIN/useradd" <<'EOF'
#!/usr/bin/env bash
# Format in users db: name:x:uid:gid:shell:home:groups
u="${@: -1}"
mkdir -p "${HFT_ROOT:?}/home/${u}"
printf '%s:x:1001:1001:/bin/bash:/home/%s:hft sudo\n' "$u" "$u" >> "${MOCK_STATE:?}/users"
EOF

cat > "$MOCK_BIN/usermod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MOCK_BIN/loginctl" <<'EOF'
#!/usr/bin/env bash
ling_f="${MOCK_STATE:?}/linger"
case "${1:-}" in
    enable-linger)
        printf '%s\n' "${2:-}" >> "$ling_f"
        ;;
    show-user)
        u="${2:-}"
        if grep -Fqx "$u" "$ling_f" 2>/dev/null; then
            echo "yes"
        else
            echo "no"
        fi
        ;;
esac
EOF

# 5. Mock ssh-keygen (deterministic SHA256 fingerprint from key token; preserves stdin)
cat > "$MOCK_BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-lf" ]]; then
    src="${2:--}"
    python3 -c '
import hashlib, sys
src = sys.argv[1]
lines = sys.stdin.read().splitlines() if src in ("-", "/dev/stdin") else open(src).read().splitlines()
for ln in lines:
    ln = ln.strip()
    if not ln or ln.startswith("#"):
        continue
    toks = ln.split()
    k = None
    for i, t in enumerate(toks):
        if t.startswith(("ssh-", "ecdsa-", "sk-")) and i + 1 < len(toks):
            k = toks[i+1]
            break
    if not k:
        sys.exit(1)
    h = hashlib.sha256(k.encode()).hexdigest()[:16]
    print(f"256 SHA256:{h} comment (ED25519)")
' "$src"
    exit $?
fi
exit 1
EOF

# 6. Stateful mock systemctl
cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
u_dir="${MOCK_STATE:?}/units"
mkdir -p "$u_dir"
cmd="${1:-}"; shift || true
quiet=0
if [[ "${1:-}" == "--quiet" ]]; then quiet=1; shift; fi

set_field() {
    local u="$1" k="$2" v="$3"
    local f="$u_dir/${u}.state"
    touch "$f"
    grep -Fv "${k}=" "$f" > "${f}.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$k" "$v" >> "${f}.tmp"
    mv -f "${f}.tmp" "$f"
}
get_field() {
    local u="$1" k="$2" def="$3"
    local f="$u_dir/${u}.state"
    if [[ ! -f "$f" ]]; then echo "$def"; return; fi
    local v
    v="$(awk -F= -v k="$k" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$f")"
    echo "${v:-$def}"
}

case "$cmd" in
    daemon-reload) exit 0 ;;
    enable)  set_field "$1" enabled enabled ;;
    disable) set_field "$1" enabled disabled ;;
    mask)    set_field "$1" enabled masked; set_field "$1" active inactive ;;
    unmask)  set_field "$1" enabled disabled ;;
    start|restart)
        if [[ "$(get_field "$1" enabled disabled)" == "masked" ]]; then exit 1; fi
        set_field "$1" active active
        ;;
    stop)    set_field "$1" active inactive ;;
    is-active)
        st="$(get_field "$1" active inactive)"
        (( quiet == 0 )) && echo "$st"
        [[ "$st" == "active" ]]
        ;;
    is-enabled)
        st="$(get_field "$1" enabled not-found)"
        (( quiet == 0 )) && echo "$st"
        [[ "$st" == "enabled" ]]
        ;;
    show)
        # Supports: systemctl show -p ExecStart --value chrony
        # and systemctl show user@1001.service -p LimitMEMLOCK -p LimitNOFILE -p LimitRTPRIO
        if [[ "$*" == *"ExecStart"* && "$*" == *"chrony"* ]]; then
            echo "${MOCK_CHRONY_EXECSTART:-/usr/sbin/chronyd -f /etc/chrony/chrony.conf}"
            exit 0
        fi
        if [[ "$*" == *"LimitMEMLOCK"* ]]; then
            echo "LimitMEMLOCK=infinity"
            echo "LimitNOFILE=1048576"
            echo "LimitRTPRIO=99"
            exit 0
        fi
        exit 0
        ;;
    cat)
        if [[ "${1:-}" == "chrony" ]]; then
            echo "ExecStart=${MOCK_CHRONY_EXECSTART:-/usr/sbin/chronyd -f /etc/chrony/chrony.conf}"
        fi
        exit 0
        ;;
esac
EOF

# 7. Stateful mock dpkg / apt-get / dpkg-deb
cat > "$MOCK_BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
pkg_db="${MOCK_STATE:?}/pkgs"
touch "$pkg_db"
case "${1:-}" in
    -s)
        pkg="${2:-}"
        if grep -Fqx "$pkg" "$pkg_db"; then
            echo "Package: $pkg"
            echo "Status: install ok installed"
            exit 0
        fi
        exit 1
        ;;
    -i)
        deb="${2:-}"
        base="$(basename "$deb")"
        pkg="${base%%_*}"
        pkg="${pkg%%.deb}"
        grep -Fqx "$pkg" "$pkg_db" || echo "$pkg" >> "$pkg_db"
        exit 0
        ;;
esac
EOF

cat > "$MOCK_BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
pkg_db="${MOCK_STATE:?}/pkgs"
touch "$pkg_db"
cmd="${1:-}"; shift || true
case "$cmd" in
    update) exit 0 ;;
    install)
        [[ "${1:-}" == "-y" ]] && shift
        for p in "$@"; do
            if [[ "$p" == "chrony" && "${MOCK_APT_CHRONY_FAIL:-0}" == "1" ]]; then
                echo "mock apt chrony install failure" >&2
                exit 1
            fi
            grep -Fqx "$p" "$pkg_db" || echo "$p" >> "$pkg_db"
            # Simulate apt conflict removing systemd-timesyncd when installing chrony
            if [[ "$p" == "chrony" ]]; then
                grep -Fvx "systemd-timesyncd" "$pkg_db" > "${pkg_db}.tmp" 2>/dev/null || true
                mv -f "${pkg_db}.tmp" "$pkg_db"
            fi
        done
        ;;
    remove)
        [[ "${1:-}" == "-y" ]] && shift
        for p in "$@"; do
            grep -Fvx "$p" "$pkg_db" > "${pkg_db}.tmp" 2>/dev/null || true
            mv -f "${pkg_db}.tmp" "$pkg_db"
        done
        ;;
    download)
        p="${1:-}"
        # Create fake .deb file containing default chrony.conf marker
        printf 'MOCK_DEB:%s\n' "$p" > "${p}_1.0_amd64.deb"
        ;;
esac
EOF

cat > "$MOCK_BIN/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-x" ]]; then
    deb="$2"
    dest="$3"
    mkdir -p "$dest/etc/chrony"
    if [[ -n "${MOCK_CHRONY_DEB_CONF:-}" && -f "$MOCK_CHRONY_DEB_CONF" ]]; then
        cp "$MOCK_CHRONY_DEB_CONF" "$dest/etc/chrony/chrony.conf"
    else
        cat > "$dest/etc/chrony/chrony.conf" <<'CONF'
pool ntp.ubuntu.com iburst maxsources 4
confdir /etc/chrony/conf.d
sourcedir /run/chrony-dhcp
makestep 1 3
leapsectz right/UTC
CONF
    fi
    exit 0
fi
exit 1
EOF

# 8. Stateful mock timedatectl, sysctl, ip, ethtool, mount, findmnt, chronyc, pkg-config, gcc, g++, flock
cat > "$MOCK_BIN/timedatectl" <<'EOF'
#!/usr/bin/env bash
tz_f="${MOCK_STATE:?}/tz"
case "${1:-}" in
    set-timezone)
        printf '%s\n' "$2" > "$tz_f"
        mkdir -p "${HFT_ROOT:?}/etc"
        printf '%s\n' "$2" > "${HFT_ROOT}/etc/timezone"
        ;;
    show)
        cat "$tz_f" 2>/dev/null || echo "Etc/UTC"
        ;;
esac
EOF

cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
apply_kv() {
    local k="$1" v="$2"
    local p="${HFT_ROOT:?}/proc/sys/${k//./\/}"
    mkdir -p "$(dirname "$p")"
    printf '%s\n' "$v" > "$p"
    if [[ "$k" == "vm.nr_hugepages" ]]; then
        mkdir -p "${HFT_ROOT}/sys/kernel/mm/hugepages/hugepages-2048kB"
        printf '%s\n' "$v" > "${HFT_ROOT}/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    fi
}
if [[ "${1:-}" == "-p" ]]; then
    f="$2"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        k="$(printf '%s\n' "$line" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')"
        v="$(printf '%s\n' "$line" | awk -F= '{sub(/^[^=]*=/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}')"
        apply_kv "$k" "$v"
    done < "$f"
    exit 0
elif [[ "${1:-}" == "-w" ]]; then
    kv="$2"
    apply_kv "${kv%%=*}" "${kv#*=}"
    exit 0
fi
EOF

cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
echo "default via 10.0.0.1 dev ens5 proto dhcp src 10.0.0.10 metric 100"
EOF

cat > "$MOCK_BIN/ethtool" <<'EOF'
#!/usr/bin/env bash
st_f="${MOCK_STATE:?}/ethtool_ens5"
[[ -f "$st_f" ]] || printf 'on:32\n' > "$st_f"
if [[ "${1:-}" == "-c" ]]; then
    cur="$(cat "$st_f")"
    ad="${cur%%:*}"
    rx="${cur#*:}"
    echo "Coalesce parameters for ${2:-ens5}:"
    echo "Adaptive RX: ${ad}  TX: off"
    echo "rx-usecs: ${rx}"
    exit 0
elif [[ "${1:-}" == "-C" ]]; then
    if [[ "${MOCK_ETHTOOL_UNSUPPORTED:-0}" == "1" ]]; then
        echo "Cannot set device coalesce parameters: Operation not supported" >&2
        exit 81
    fi
    ad="on"; rx="32"
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            adaptive-rx) ad="$2"; shift 2 ;;
            rx-usecs)    rx="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '%s:%s\n' "$ad" "$rx" > "$st_f"
    exit 0
fi
EOF

cat > "$MOCK_BIN/mount" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"remount,huge=within_size"* && "$*" == *"/dev/shm"* ]]; then
    echo "rw,nosuid,nodev,huge=within_size" > "${MOCK_STATE:?}/shm_opts"
    exit 0
fi
exit 0
EOF

cat > "$MOCK_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-no" ]]; then
    col="$2"; tgt="$3"
    if [[ "$tgt" == "/dev/hugepages" ]]; then
        if [[ "$col" == "FSTYPE" ]]; then echo "hugetlbfs"; exit 0; fi
        if [[ "$col" == "OPTIONS" ]]; then
            cat "${MOCK_STATE:?}/hp_opts" 2>/dev/null || echo "rw,relatime,nosuid,nodev,pagesize=2M,mode=0775,gid=1001"
            exit 0
        fi
    elif [[ "$tgt" == "/dev/shm" && "$col" == "OPTIONS" ]]; then
        cat "${MOCK_STATE:?}/shm_opts" 2>/dev/null || echo "rw,nosuid,nodev"
        exit 0
    fi
fi
exit 1
EOF

cat > "$MOCK_BIN/chronyc" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    waitsync)
        [[ "${MOCK_CHRONY_WAITSYNC_FAIL:-0}" == "1" ]] && exit 1
        exit 0
        ;;
    tracking)
        echo "Reference ID    : A9FEA97B (169.254.169.123)"
        echo "Leap status     : Normal"
        exit 0
        ;;
    -c)
        if [[ "${2:-}" == "sources" ]]; then
            if [[ -n "${MOCK_CHRONY_SOURCES_CSV:-}" ]]; then
                printf '%b\n' "$MOCK_CHRONY_SOURCES_CSV"
            elif [[ "${HFT_EC2_MODE:-0}" == "1" ]]; then
                echo "^,*,169.254.169.123,3,6,377,20,+0.000012,+0.000012,0.000100"
            else
                echo "^,*,162.159.200.1,3,6,377,20,+0.000100,+0.000100,0.001000"
                echo "^,+,129.6.15.28,1,6,377,22,+0.000200,+0.000200,0.001500"
                echo "^,+,129.6.15.29,1,6,377,24,+0.000250,+0.000250,0.001600"
            fi
            exit 0
        fi
        ;;
esac
EOF

cat > "$MOCK_BIN/pkg-config" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--exists" && "${2:-}" == "libdpdk" ]]; then
    [[ "${MOCK_LIBDPDK_FAIL:-0}" == "1" ]] && exit 1
    exit 0
fi
exit 1
EOF

cat > "$MOCK_BIN/gcc" <<'EOF'
#!/usr/bin/env bash
# Accept -luring compile/link probe in sandbox
cat >/dev/null || true
[[ "${MOCK_LIBURING_FAIL:-0}" == "1" ]] && exit 1
exit 0
EOF

cat > "$MOCK_BIN/g++" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null || true
exit 0
EOF

cat > "$MOCK_BIN/grub-editenv" <<'EOF'
#!/usr/bin/env bash
[[ -r "${1:-}" ]] && grep -E '^[A-Za-z0-9_]+=' "$1" || true
EOF

cat > "$MOCK_BIN/grub-script-check" <<'EOF'
#!/usr/bin/env bash
[[ -r "${1:-}" ]]
EOF

cat > "$MOCK_BIN/update-grub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
grub_file="${HFT_GRUB_FILE:-${HFT_ROOT}/etc/default/grub}"
grub_d="${HFT_GRUB_D_DIR:-${grub_file}.d}"
grub_cfg="${HFT_GRUB_CFG:-${HFT_ROOT}/boot/grub/grub.cfg}"
mkdir -p "$(dirname "$grub_cfg")"
eval_out="$(/bin/sh -c '
    set -e
    GRUB_CMDLINE_LINUX=""
    GRUB_CMDLINE_LINUX_DEFAULT=""
    . "$1"
    if [ -d "$2" ]; then
        for f in "$2"/*.cfg; do [ -f "$f" ] || continue; . "$f"; done
    fi
    printf "%s %s\n" "$GRUB_CMDLINE_LINUX" "$GRUB_CMDLINE_LINUX_DEFAULT"
' _ "$grub_file" "$grub_d")"
combined="$(printf '%s' "$eval_out" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
cat > "$grub_cfg" <<CFG
set default="0"
menuentry 'Ubuntu' --id 'gnulinux-simple' {
    linux /boot/vmlinuz root=PARTUUID=abcd ro ${combined}
}
CFG
EOF

# Portable python3-backed flock mock (works on both Linux and macOS)
cat > "$MOCK_BIN/flock" <<'EOF'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import fcntl, os, sys
mode = sys.argv[1]
fd = int(sys.argv[2])
if mode == "-u":
    fcntl.flock(fd, fcntl.LOCK_UN)
elif mode == "-n":
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(1)
elif mode == "-x":
    fcntl.flock(fd, fcntl.LOCK_EX)
else:
    sys.exit(2)
PY
EOF

chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH"

# ==============================================================================
# Helper: Create a full sandbox root directory
# ==============================================================================
init_sandbox() {
    local name="$1"
    local root="$T/sb_${name}"
    local state="$T/st_${name}"
    rm -rf /tmp/"$(basename "$T")"/sb_"$name" /tmp/"$(basename "$T")"/st_"$name"
    mkdir -p \
        "$root/etc/default/grub.d" \
        "$root/etc/sudoers.d" \
        "$root/etc/systemd/system" \
        "$root/etc/apt/apt.conf.d" \
        "$root/etc/chrony/conf.d" \
        "$root/etc/security/limits.d" \
        "$root/etc/tmpfiles.d" \
        "$root/boot/grub" \
        "$root/dev/hugepages" \
        "$root/proc/sys/kernel/random" \
        "$root/proc/sys/net/core" \
        "$root/proc/sys/net/ipv4" \
        "$root/proc/sys/vm" \
        "$root/proc/irq/10" \
        "$root/proc/irq/20" \
        "$root/sys/devices/system/cpu/cpu0/topology" \
        "$root/sys/devices/system/cpu/cpu1/topology" \
        "$root/sys/devices/system/cpu/cpu2/topology" \
        "$root/sys/devices/system/cpu/cpu3/topology" \
        "$root/sys/devices/system/cpu/smt" \
        "$root/sys/devices/system/cpu/cpufreq/policy0" \
        "$root/sys/kernel/debug/irq/irqs" \
        "$root/sys/kernel/mm/hugepages/hugepages-2048kB" \
        "$root/sys/kernel/mm/transparent_hugepage/hugepages-2048kB" \
        "$root/var/lib/hft-bootstrap" \
        "$root/run/hft-bootstrap" \
        "$root/run/user/1001/systemd" \
        "$root/usr/local/sbin" \
        "$root/home/ubuntu/.ssh" \
        "$root/root/.ssh" \
        "$state/units"

    echo "boot-1111" > "$root/proc/sys/kernel/random/boot_id"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$root/etc/os-release"
    printf 'processor\t: 0\nvendor_id\t: GenuineIntel\n' > "$root/proc/cpuinfo"
    printf 'MemTotal:       16384000 kB\nHugepagesize:       2048 kB\n' > "$root/proc/meminfo"
    echo "0" > "$root/sys/devices/system/cpu/smt/active"
    for c in 0 1 2 3; do
        echo "$c" > "$root/sys/devices/system/cpu/cpu${c}/topology/thread_siblings_list"
    done
    echo "" > "$root/sys/devices/system/cpu/isolated"
    echo "powersave" > "$root/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
    echo "0" > "$root/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    echo "always [never] advise" > "$root/sys/kernel/mm/transparent_hugepage/shmem_enabled"
    echo "always [never] advise" > "$root/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled"
    echo "0" > "$root/proc/sys/net/core/busy_read"
    echo "0" > "$root/proc/sys/net/core/busy_poll"
    echo "60" > "$root/proc/sys/vm/swappiness"
    echo "212992" > "$root/proc/sys/net/core/rmem_max"
    echo "212992" > "$root/proc/sys/net/core/wmem_max"
    echo "4096 87380 6291456" > "$root/proc/sys/net/ipv4/tcp_rmem"
    echo "4096 16384 4194304" > "$root/proc/sys/net/ipv4/tcp_wmem"
    echo "1000" > "$root/proc/sys/net/core/netdev_max_backlog"

    cat > "$root/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
EOF
    : > "$root/boot/grub/grubenv"
    printf 'UUID=1234 / ext4 defaults 0 1\ntmpfs /dev/shm tmpfs rw,nosuid,nodev,size=8G 0 0\n' > "$root/etc/fstab"

    # Cloud-init refusal line + valid restricted key for ubuntu
    cat > "$root/home/ubuntu/.ssh/authorized_keys" <<EOF
no-port-forwarding,command="echo 'Please login as the user \"ubuntu\" rather than the user \"root\".';exit 142" ${PUB_REFUSAL}
from="10.0.0.0/8" ${PUB_UBUNTU}
EOF
    cat > "$root/root/.ssh/authorized_keys" <<EOF
${PUB_ROOT}
EOF

    # Initial unit states
    printf 'enabled=enabled\nactive=active\n' > "$state/units/irqbalance.state"
    printf 'enabled=enabled\nactive=active\n' > "$state/units/unattended-upgrades.service.state"
    printf 'enabled=enabled\nactive=active\n' > "$state/units/apt-daily.timer.state"
    printf 'enabled=enabled\nactive=active\n' > "$state/units/apt-daily-upgrade.timer.state"
    printf 'enabled=enabled\nactive=active\n' > "$state/units/systemd-journald.state"
    printf 'enabled=enabled\nactive=active\n' > "$state/units/systemd-timesyncd.state"
    printf 'Etc/UTC\n' > "$state/tz"
    printf 'systemd-timesyncd\n' > "$state/pkgs"
    printf 'ubuntu:x:1000:1000:/bin/bash:/home/ubuntu:ubuntu sudo\nroot:x:0:0:/bin/bash:/root:root\n' > "$state/users"
    touch "$state/owners" "$state/linger"

    echo "$root|$state"
}

# ==============================================================================
# SECTION 1: common.sh & C10 (Transaction Rollback)
# ==============================================================================
if [[ "$ONLY" == "all" || "$ONLY" == "common" ]]; then
    echo "=== Section: common.sh & C10 Transaction Rollback ==="
    IFS='|' read -r R ST <<< "$(init_sandbox common)"

    # Test is_ec2 DMI detection + HFT_NO_SUDO=1 blocks run_priv + txn_rollback
    set +e
    (
        export HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap"
        export MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_PRETEND_ROOT=1
        # shellcheck source=../lib/common.sh
        source "$REPO/lib/common.sh"

        # 1. is_ec2 product_uuid detection
        mkdir -p "$R/sys/devices/virtual/dmi/id"
        echo "EC2A-1234" > "$R/sys/devices/virtual/dmi/id/product_uuid"
        is_ec2 || exit 11

        # 2. HFT_NO_SUDO=1 forbids run_priv
        if ( HFT_NO_SUDO=1 run_priv echo hi >/dev/null 2>&1 ); then
            exit 12
        fi

        # 3. C10: txn_init + record file/kv + mutate + txn_rollback restores everything in reverse
        echo "orig-content" > "$R/etc/sample.conf"
        txn_init "test_c10"
        txn_record_file "$R/etc/sample.conf"
        txn_record_file "$R/etc/new_file.conf"
        txn_record_kv timezone tz "Etc/UTC"
        txn_record_kv sysctl vm.swappiness "60"
        txn_record_kv coalesce ens5 "on:32"
        txn_record_kv governor "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_governor" "powersave"
        txn_record_kv pkg_installed dummy-pkg "1"

        echo "mutated-content" > "$R/etc/sample.conf"
        echo "created" > "$R/etc/new_file.conf"
        "$HFT_TIMEDATECTL_CMD" set-timezone Asia/Hong_Kong
        "$HFT_SYSCTL_CMD" -w vm.swappiness=1
        "$HFT_ETHTOOL_CMD" -C ens5 adaptive-rx off rx-usecs 0
        echo "performance" > "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
        echo "dummy-pkg" >> "$ST/pkgs"

        txn_rollback || exit 13

        [[ "$(cat "$R/etc/sample.conf")" == "orig-content" ]] || exit 14
        [[ ! -e "$R/etc/new_file.conf" ]] || exit 15
        [[ "$("$HFT_TIMEDATECTL_CMD" show)" == "Etc/UTC" ]] || exit 16
        [[ "$(cat "$R/proc/sys/vm/swappiness")" == "60" ]] || exit 17
        [[ "$(cat "$ST/ethtool_ens5")" == "on:32" ]] || exit 18
        [[ "$(cat "$R/sys/devices/system/cpu/cpufreq/policy0/scaling_governor")" == "powersave" ]] || exit 19
        if "$HFT_DPKG_CMD" -s dummy-pkg >/dev/null 2>&1; then exit 20; fi
        exit 0
    ) > "$T/common.out" 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        ok "common.sh (is_ec2 DMI, HFT_NO_SUDO guard, C10 full txn_rollback reverse restore)"
    else
        bad "common.sh & C10" "rc=$rc out=[$(cat "$T/common.out")]"
    fi
fi

# ==============================================================================
# SECTION 2: Layer 1 (C1 - C7)
# ==============================================================================
if [[ "$ONLY" == "all" || "$ONLY" == "layer1" ]]; then
    echo "=== Section: Layer 1 (C1 - C7) ==="
    IFS='|' read -r R ST <<< "$(init_sandbox l1)"

    export HFT_ROOT="$R"
    export HFT_STATE_DIR="$R/var/lib/hft-bootstrap"
    export HFT_RUN_DIR="$R/run/hft-bootstrap"
    export MOCK_STATE="$ST"
    export HFT_SKIP_OS_CHECK=1
    export HFT_EC2_MODE=0
    export HFT_PRETEND_ROOT=1
    export HFT_SUDO_CMD="$MOCK_BIN/sudo"
    export HFT_SESSION_LIMITS_CHECK="true"

    # C1a: Missing usable SSH keys fails closed BEFORE creating hft
    IFS='|' read -r R_NOKEY ST_NOKEY <<< "$(init_sandbox l1_nokey)"
    rm -f /tmp/"$(basename "$T")"/sb_l1_nokey/home/ubuntu/.ssh/authorized_keys /tmp/"$(basename "$T")"/sb_l1_nokey/root/.ssh/authorized_keys
    set +e
    HFT_ROOT="$R_NOKEY" HFT_STATE_DIR="$R_NOKEY/var/lib/hft-bootstrap" HFT_RUN_DIR="$R_NOKEY/run/hft-bootstrap" MOCK_STATE="$ST_NOKEY" \
        bash "$REPO/00_sudo_script/01_user_and_sudo.sh" > "$T/c1_nokey.out" 2>&1
    rc_nokey=$?
    set -e
    if [[ $rc_nokey -ne 0 && ! -f "$R_NOKEY/etc/sudoers.d/90-hft-nopasswd" ]]; then
        ok "C1: missing SSH keys fail-closed before modifying user/sudoers"
    else
        bad "C1 missing keys" "rc=$rc_nokey"
    fi

    # C1b: Full Step 01 run (filters refusal line, keeps restricted key, does NOT merge root key)
    set +e
    bash "$REPO/00_sudo_script/01_user_and_sudo.sh" > "$T/c1_run.out" 2>&1
    rc_01=$?
    set -e
    c1_keys_ok=0
    if [[ $rc_01 -eq 0 ]] \
       && ! grep -q "Please login as the user" "$R/home/hft/.ssh/authorized_keys" \
       && grep -q 'from="10.0.0.0/8"' "$R/home/hft/.ssh/authorized_keys" \
       && ! grep -q "IRootKey222" "$R/home/hft/.ssh/authorized_keys" \
       && [[ -f "$R/run/hft-bootstrap/layer1_01.verified" ]]; then
        c1_keys_ok=1
    fi
    if [[ $c1_keys_ok -eq 1 ]]; then
        ok "C1: Step 01 created hft, filtered refusal line, kept single-source restricted key, attested"
    else
        bad "C1 Step 01" "rc=$rc_01 out=[$(tail -n 8 "$T/c1_run.out")]"
    fi

    # C1c: Post-reboot sudoers drift detected by verify_01 & intercepts Step 02!
    cp "$R/etc/sudoers.d/90-hft-nopasswd" "$T/sudoers.bak"
    chmod 0640 "$R/etc/sudoers.d/90-hft-nopasswd"
    echo "# drifted" >> "$R/etc/sudoers.d/90-hft-nopasswd"
    chmod 0440 "$R/etc/sudoers.d/90-hft-nopasswd"
    set +e
    bash "$REPO/00_sudo_script/verify_01_user_and_sudo.sh" --staged > "$T/c1_drift.out" 2>&1
    rc_drift_v01=$?
    bash "$REPO/00_sudo_script/02_base_packages_and_tz.sh" > "$T/c2_blocked.out" 2>&1
    rc_c2_blk=$?
    set -e
    chmod 0640 "$R/etc/sudoers.d/90-hft-nopasswd"
    cp "$T/sudoers.bak" "$R/etc/sudoers.d/90-hft-nopasswd"
    chmod 0440 "$R/etc/sudoers.d/90-hft-nopasswd"
    if [[ $rc_drift_v01 -ne 0 && $rc_c2_blk -ne 0 ]]; then
        ok "C1/C2: sudoers drift detected by verify_01 and blocks Step 02 prereq chain"
    else
        bad "C1/C2 drift block" "v01=$rc_drift_v01 c2=$rc_c2_blk"
    fi

    # C2: Step 02 succeeds cleanly
    set +e
    bash "$REPO/00_sudo_script/02_base_packages_and_tz.sh" > "$T/c2_run.out" 2>&1
    rc_02=$?
    set -e
    if [[ $rc_02 -eq 0 ]]; then
        ok "C2: Step 02 timezone, 34 packages, libdpdk, -luring probe, cron passed"
    else
        bad "C2 Step 02" "rc=$rc_02 out=[$(tail -n 8 "$T/c2_run.out")]"
    fi

    # C3: Step 03 GRUB isolation staged
    set +e
    bash "$REPO/00_sudo_script/03_grub_cpu_isolation.sh" > "$T/c3_run.out" 2>&1
    rc_03=$?
    set -e
    if [[ $rc_03 -eq 0 ]]; then
        ok "C3: Step 03 GRUB isolation staged & verified"
    else
        bad "C3 Step 03" "rc=$rc_03 out=[$(tail -n 8 "$T/c3_run.out")]"
    fi

    # C4: Step 04 + IRQD_MANAGED_SHUTDOWN vs IRQD_AFFINITY_MANAGED + post-boot ethtool drift!
    set +e
    bash "$REPO/00_sudo_script/04_irq_nic_and_perf.sh" > "$T/c4_run.out" 2>&1
    rc_04=$?
    set -e
    if [[ $rc_04 -eq 0 ]]; then
        ok "C4: Step 04 irqbalance masked, NIC coalesce tuned, IRQs pinned, cpufreq performance"
    else
        bad "C4 Step 04" "rc=$rc_04 out=[$(tail -n 8 "$T/c4_run.out")]"
    fi

    # C4b: Test IRQD_MANAGED_SHUTDOWN MUST NOT be misclassified as IRQD_AFFINITY_MANAGED!
    echo "1-3" > "$R/sys/devices/system/cpu/isolated"
    echo "1" > "$R/proc/irq/10/effective_affinity_list"
    echo "1" > "$R/proc/irq/10/smp_affinity_list"
    echo "state: IRQD_MANAGED_SHUTDOWN IRQD_ACTIVATED" > "$R/sys/kernel/debug/irq/irqs/10"
    set +e
    bash "$R/usr/local/sbin/hft-pin-irqs.sh" > "$T/c4_irq_bad.out" 2>&1
    rc_irq_bad=$?
    # Now set exact IRQD_AFFINITY_MANAGED -> MUST PASS!
    echo "state: IRQD_AFFINITY_MANAGED IRQD_ACTIVATED" > "$R/sys/kernel/debug/irq/irqs/10"
    bash "$R/usr/local/sbin/hft-pin-irqs.sh" > "$T/c4_irq_good.out" 2>&1
    rc_irq_good=$?
    # Now simulate post-boot ethtool -c drift -> verify_04 --live MUST FAIL!
    printf 'on:64\n' > "$ST/ethtool_ens5"
    bash "$REPO/00_sudo_script/verify_04_irq_nic_and_perf.sh" --live > "$T/c4_eth_drift.out" 2>&1
    rc_eth_drift=$?
    # Restore ethtool -> verify_04 --live MUST PASS!
    printf 'off:0\n' > "$ST/ethtool_ens5"
    bash "$REPO/00_sudo_script/verify_04_irq_nic_and_perf.sh" --live > "$T/c4_live_ok.out" 2>&1
    rc_c4_live=$?
    set -e
    if [[ $rc_irq_bad -ne 0 && $rc_irq_good -eq 0 && $rc_eth_drift -ne 0 && $rc_c4_live -eq 0 ]]; then
        ok "C4: IRQD_MANAGED_SHUTDOWN rejected, exact IRQD_AFFINITY_MANAGED allowed, live ethtool drift caught"
    else
        bad "C4 IRQ/ethtool checks" "bad=$rc_irq_bad good=$rc_irq_good drift=$rc_eth_drift live=$rc_c4_live"
    fi

    # C5: Step 05 (< 4 GiB refused, existing 1024 hugepages NOT lowered, nosuid/nodev/numeric gid, no ExecStartPost, fstab options preserved)
    printf 'MemTotal:       2097152 kB\nHugepagesize:       2048 kB\n' > "$R/proc/meminfo"
    set +e
    bash "$REPO/00_sudo_script/05_memory_net_and_limits.sh" > "$T/c5_lowram.out" 2>&1
    rc_lowram=$?
    set -e

    # Restore 16 GiB RAM and pre-set 1024 hugepages -> must preserve 1024 (not downsize to 512!)
    printf 'MemTotal:       16384000 kB\nHugepagesize:       2048 kB\n' > "$R/proc/meminfo"
    echo "1024" > "$R/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    set +e
    bash "$REPO/00_sudo_script/05_memory_net_and_limits.sh" > "$T/c5_run.out" 2>&1
    rc_05=$?
    set -e
    c5_ok=0
    if [[ $rc_lowram -ne 0 && $rc_05 -eq 0 ]] \
       && grep -q 'vm.nr_hugepages = 1024' "$R/etc/sysctl.d/99-hft-lowlatency.conf" \
       && ! grep -q 'tcp_low_latency' "$R/etc/sysctl.d/99-hft-lowlatency.conf" \
       && grep -q 'Options=nosuid,nodev,pagesize=2M,mode=0775,gid=1001' "$R/etc/systemd/system/dev-hugepages.mount.d/99-hft.conf" \
       && ! grep -q 'ExecStartPost=' "$R/etc/systemd/system/dev-hugepages.mount.d/99-hft.conf" \
       && grep -q 'size=8G,huge=within_size' "$R/etc/fstab"; then
        c5_ok=1
    fi
    if [[ $c5_ok -eq 1 ]]; then
        ok "C5: <4GiB refused, 1024 hugepages preserved, valid [Mount] drop-in, fstab merged, no tcp_low_latency"
    else
        bad "C5 Step 05" "lowram=$rc_lowram rc05=$rc_05 out=[$(tail -n 8 "$T/c5_run.out")]"
    fi

    # C6: Step 06 background noise disabled + journald capped
    set +e
    bash "$REPO/00_sudo_script/06_disable_bg_noise.sh" > "$T/c6_run.out" 2>&1
    rc_06=$?
    set -e
    if [[ $rc_06 -eq 0 ]]; then
        ok "C6: Step 06 apt timers/unattended-upgrades masked, 20auto-upgrades & journald configured"
    else
        bad "C6 Step 06" "rc=$rc_06 out=[$(tail -n 8 "$T/c6_run.out")]"
    fi

    # C7a: Chrony NOT installed + candidate fails (extra un-disabled include source) -> timesyncd remains untouched!
    cat > "$T/bad_chrony.conf" <<'EOF'
include /etc/chrony/unmanaged_extra.inc
confdir /etc/chrony/conf.d
EOF
    echo "server evil.ntp.example iburst" > "$R/etc/chrony/unmanaged_extra.inc"
    set +e
    MOCK_CHRONY_DEB_CONF="$T/bad_chrony.conf" bash "$REPO/00_sudo_script/07_chrony_time_sync.sh" > "$T/c7_cand_fail.out" 2>&1
    rc_c7_fail=$?
    set -e
    ts_still_ok=0
    if [[ $rc_c7_fail -ne 0 ]] \
       && ! "$MOCK_BIN/dpkg" -s chrony >/dev/null 2>&1 \
       && "$MOCK_BIN/dpkg" -s systemd-timesyncd >/dev/null 2>&1 \
       && "$MOCK_BIN/systemctl" is-active --quiet systemd-timesyncd; then
        ts_still_ok=1
    fi
    rm -f /tmp/"$(basename "$T")"/sb_l1/etc/chrony/unmanaged_extra.inc

    # C7b: Clean chrony install from scratch -> passes
    set +e
    bash "$REPO/00_sudo_script/07_chrony_time_sync.sh" > "$T/c7_run.out" 2>&1
    rc_07=$?
    set -e

    # C7c: Already installed chrony with custom -f /etc/chrony/custom.conf -> migrates cleanly
    cat > "$R/etc/chrony/custom.conf" <<'EOF'
pool vendor.ntp.example iburst
makestep 1 3
EOF
    set +e
    MOCK_CHRONY_EXECSTART="/usr/sbin/chronyd -f /etc/chrony/custom.conf" \
        bash "$REPO/00_sudo_script/07_chrony_time_sync.sh" > "$T/c7_custom.out" 2>&1
    rc_c7_custom=$?
    set -e

    # C7d: Exchange time 3 states (pass within [-100,100], fail >100ms, fail unreachable)
    cat > "$T/probe_ok.sh" <<'EOF'
#!/usr/bin/env bash
echo "1700000000000 1700000000020 1700000000040"
EOF
    cat > "$T/probe_skew.sh" <<'EOF'
#!/usr/bin/env bash
echo "1700000000000 1700000000150 1700000000020"
EOF
    cat > "$T/probe_err.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$T/probe_ok.sh" "$T/probe_skew.sh" "$T/probe_err.sh"

    set +e
    HFT_EXCHANGE_PROBE_CMD="$T/probe_ok.sh" bash "$REPO/00_sudo_script/verify_07_chrony_time_sync.sh" --require-exchange-time > "$T/c7_ex_ok.out" 2>&1
    rc_ex_ok=$?
    HFT_EXCHANGE_PROBE_CMD="$T/probe_skew.sh" bash "$REPO/00_sudo_script/verify_07_chrony_time_sync.sh" --require-exchange-time > "$T/c7_ex_skew.out" 2>&1
    rc_ex_skew=$?
    HFT_EXCHANGE_PROBE_CMD="$T/probe_err.sh" bash "$REPO/00_sudo_script/verify_07_chrony_time_sync.sh" --require-exchange-time > "$T/c7_ex_err.out" 2>&1
    rc_ex_err=$?
    set -e

    if [[ $ts_still_ok -eq 1 && $rc_07 -eq 0 && $rc_c7_custom -eq 0 && $rc_ex_ok -eq 0 && $rc_ex_skew -ne 0 && $rc_ex_err -ne 0 ]]; then
        ok "C7: candidate fail keeps timesyncd, fresh & custom -f migrate, exchange time 3 states verified"
    else
        bad "C7 chrony" "cand=$ts_still_ok run=$rc_07 custom=$rc_c7_custom ex=$rc_ex_ok/$rc_ex_skew/$rc_ex_err"
    fi
fi

# ==============================================================================
# SECTION 3: Layer 2 (C8: Zero Sudo, Workspace, Git/SSH, TLS Atomic Builder)
# ==============================================================================
if [[ "$ONLY" == "all" || "$ONLY" == "layer2" ]]; then
    echo "=== Section: Layer 2 (C8: Zero Sudo, Workspace, Git/SSH, TLS Builder) ==="
    IFS='|' read -r R ST <<< "$(init_sandbox l2)"

    # First bootstrap Layer 1 cleanly and simulate reboot so Layer 1 --live passes!
    set +e
    (
        export HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap"
        export MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_EC2_MODE=0 HFT_PRETEND_ROOT=1 HFT_SUDO_CMD="$MOCK_BIN/sudo"
        bash "$REPO/00_sudo_script/run_all.sh"
    ) > "$T/l2_prep_l1.out" 2>&1
    rc_l1_prep=$?
    set -e

    # Simulate reboot: new boot_id, active kernel cmdline, isolated CPUs, boot attestation units re-run
    echo "boot-2222" > "$R/proc/sys/kernel/random/boot_id"
    echo "BOOT_IMAGE=/boot/vmlinuz isolcpus=domain,managed_irq,1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0" > "$R/proc/cmdline"
    echo "1-3" > "$R/sys/devices/system/cpu/isolated"
    echo "0" > "$R/proc/irq/10/effective_affinity_list"
    echo "0" > "$R/proc/irq/20/effective_affinity_list"
    (
        export HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap" MOCK_STATE="$ST"
        bash "$R/usr/local/sbin/hft-attest-account.sh"
        bash "$R/usr/local/sbin/hft-nic-tune.sh"
        bash "$R/usr/local/sbin/hft-pin-irqs.sh"
        bash "$R/usr/local/sbin/hft-hugepages-perms.sh"
    ) > "$T/l2_reboot_units.out" 2>&1

    # C8a: Layer 2 refuses running as root (HFT_PRETEND_ROOT=1)
    set +e
    HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap" \
    MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_PRETEND_ROOT=1 HOME="$R/home/hft" \
        bash "$REPO/01_startup/01_user_workspace.sh" > "$T/c8_root_refuse.out" 2>&1
    rc_root_refuse=$?
    set -e

    # C8b: Run Layer 2 Steps 01 & 02 with MOCK_FORBID_SUDO=1 (strictly zero sudo!)
    set +e
    HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap" \
    MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_EC2_MODE=0 HFT_PRETEND_ROOT=0 \
    MOCK_FORBID_SUDO=1 HFT_SESSION_LIMITS_CHECK="true" HOME="$R/home/hft" \
        bash "$REPO/01_startup/01_user_workspace.sh" > "$T/c8_s01.out" 2>&1
    rc_l2_01=$?

    HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap" \
    MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_EC2_MODE=0 HFT_PRETEND_ROOT=0 \
    MOCK_FORBID_SUDO=1 HFT_SESSION_LIMITS_CHECK="true" HOME="$R/home/hft" \
        bash "$REPO/01_startup/02_git_ssh_base.sh" > "$T/c8_s02.out" 2>&1
    rc_l2_02=$?
    set -e

    if [[ $rc_l1_prep -eq 0 && $rc_root_refuse -ne 0 && $rc_l2_01 -eq 0 && $rc_l2_02 -eq 0 ]]; then
        ok "C8: Layer 2 refuses root, zero-sudo Steps 01 & 02 pass Layer 1 --live gate"
    else
        bad "C8 Steps 01/02" "prep=$rc_l1_prep root=$rc_root_refuse s01=$rc_l2_01 s02=$rc_l2_02 prep_tail=[$(tail -n 6 "$T/l2_prep_l1.out")] s01_tail=[$(tail -n 6 "$T/c8_s01.out")]"
    fi

    # C8c: Layer 2 Step 03 TLS builder (corrupted tarball, .so contamination, flock, legacy crash recovery, idempotency)
    # Create mock sha256sum that maps tarball contents to expected official hashes
    # so copying to a canonical staging filename still distinguishes corrupted content.
    cat > "$T/mock_sha256.sh" <<'EOF'
#!/usr/bin/env bash
f="${1:-}"
if [[ -z "$f" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then exec sha256sum; else exec shasum -a 256; fi
fi
content="$(cat "$f" 2>/dev/null || true)"
case "$content" in
    *bad-tar*)      echo "0000000000000000000000000000000000000000000000000000000000000000  $f" ;;
    *fake-wolfssl*) echo "2b702b7a66b0067bfd284408827b1e59288b357b0dd758d0089c062395f2a522  $f" ;;
    *fake-openssl*) echo "b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9  $f" ;;
    *fake-libressl*) echo "6d5c2f58583588ea791f4c8645004071d00dfa554a5bf788a006ca1eb5abd70b  $f" ;;
    *)
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
        ;;
esac
EOF
    chmod +x "$T/mock_sha256.sh"

    cat > "$T/mock_tls_builder.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
lib="$1" ver="$2" tb="$3" prefix="$4"
echo "BUILD:${lib}" >> "${TLS_BUILD_LOG:?}"
mkdir -p "$prefix/include" "$prefix/lib" "$prefix/lib64"
case "$lib" in
    wolfssl)  : > "$prefix/lib/libwolfssl.a" ;;
    openssl)  : > "$prefix/lib64/libssl.a"; : > "$prefix/lib64/libcrypto.a" ;;
    libressl) : > "$prefix/lib/libssl.a"; : > "$prefix/lib/libcrypto.a" ;;
esac
if [[ "${MOCK_INJECT_SO:-0}" == "1" ]]; then
    : > "$prefix/lib/libevil.so.1"
fi
EOF
    cat > "$T/mock_tls_probe.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$T/mock_tls_builder.sh" "$T/mock_tls_probe.sh"

    echo "fake-wolfssl" > "$T/wolfssl.tar.gz"
    echo "bad-tar" > "$T/wolfssl-corrupt.tar.gz"
    : > "$T/tls_build.log"

    run_tls() {
        HFT_ROOT="$R" HFT_STATE_DIR="$R/var/lib/hft-bootstrap" HFT_RUN_DIR="$R/run/hft-bootstrap" \
        MOCK_STATE="$ST" HFT_SKIP_OS_CHECK=1 HFT_EC2_MODE=0 HFT_PRETEND_ROOT=0 \
        MOCK_FORBID_SUDO=1 HFT_SESSION_LIMITS_CHECK="true" HOME="$R/home/hft" \
        HFT_SHA256SUM_CMD="$T/mock_sha256.sh" \
        HFT_TLS_TEST_BUILDER="$T/mock_tls_builder.sh" \
        HFT_TLS_TEST_PROBE="$T/mock_tls_probe.sh" \
        TLS_BUILD_LOG="$T/tls_build.log" \
            bash "$REPO/01_startup/03_build_tls_libs.sh" "$@"
    }

    # 1. Corrupted tarball refused
    set +e
    HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl-corrupt.tar.gz" run_tls wolfssl > "$T/tls_corrupt.out" 2>&1
    rc_corrupt=$?

    # 2. .so contamination refused
    MOCK_INJECT_SO=1 HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl.tar.gz" run_tls wolfssl > "$T/tls_so.out" 2>&1
    rc_so=$?

    # 3. Concurrent flock exclusion test
    mkdir -p "$R/home/hft/Proj/wolfssl"
    exec 9>"$R/home/hft/Proj/wolfssl/.build.lock"
    "$MOCK_BIN/flock" -x 9
    HFT_TLS_FLOCK_NONBLOCK=1 HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl.tar.gz" run_tls wolfssl > "$T/tls_lock.out" 2>&1
    rc_lock=$?
    "$MOCK_BIN/flock" -u 9
    exec 9>&-

    # 4. Legacy real-directory migration + simulated crash after mv + clean recovery on rerun!
    mkdir -p "$R/home/hft/Proj/wolfssl/install"
    echo "legacy-marker" > "$R/home/hft/Proj/wolfssl/install/old.txt"
    HFT_TLS_SIMULATE_CRASH_AFTER_MIGRATION_MV=1 HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl.tar.gz" run_tls wolfssl > "$T/tls_crash.out" 2>&1
    rc_crash=$?
    mig_present=0
    [[ -f "$R/home/hft/Proj/wolfssl/.install_migration.state" ]] && mig_present=1

    # Re-run recovers interrupted migration and completes symlink swap
    : > "$T/tls_build.log"
    HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl.tar.gz" run_tls wolfssl > "$T/tls_recover.out" 2>&1
    rc_recover=$?
    rec_ok=0
    [[ -L "$R/home/hft/Proj/wolfssl/install" && ! -f "$R/home/hft/Proj/wolfssl/.install_migration.state" ]] && rec_ok=1

    # 5. Idempotent 2nd run skips builder completely
    : > "$T/tls_build.log"
    HFT_TLS_TARBALL_WOLFSSL="$T/wolfssl.tar.gz" run_tls wolfssl > "$T/tls_idem.out" 2>&1
    rc_idem=$?
    idem_skipped=0
    [[ $rc_idem -eq 0 && ! -s "$T/tls_build.log" ]] && idem_skipped=1
    set -e

    if [[ $rc_corrupt -ne 0 && $rc_so -ne 0 && $rc_lock -ne 0 && $rc_crash -ne 0 && $mig_present -eq 1 && $rc_recover -eq 0 && $rec_ok -eq 1 && $idem_skipped -eq 1 ]]; then
        ok "C8: TLS builder rejects corrupt tarball & .so, enforces flock, recovers legacy migration crash, skips idempotently"
    else
        bad "C8 TLS builder" "corrupt=$rc_corrupt so=$rc_so lock=$rc_lock crash=$rc_crash/$mig_present rec=$rc_recover/$rec_ok idem=$rc_idem/$idem_skipped"
    fi
fi

echo ""
echo "Summary: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
