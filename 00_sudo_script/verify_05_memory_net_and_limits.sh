#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 05 (hugepages, /dev/shm THP, sysctls, hft limits).
# NEVER writes any file and NEVER mutates system state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

MODE="staged"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --live)   MODE="live";   shift ;;
        -h|--help)
            echo "Usage: verify_05_memory_net_and_limits.sh [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

HFT_UID="$("$HFT_ID_CMD" -u hft 2>/dev/null || true)"
HFT_GID="$("$HFT_ID_CMD" -g hft 2>/dev/null || true)"
if [[ ! "$HFT_UID" =~ ^[0-9]+$ || ! "$HFT_GID" =~ ^[0-9]+$ ]]; then
    fail_check "Cannot resolve numeric UID/GID for user hft"
    exit 1
fi

hft_entry="$("$HFT_GETENT_CMD" passwd hft 2>/dev/null || true)"
if [[ -n "$hft_entry" ]]; then
    HFT_HOME="$(printf '%s\n' "$hft_entry" | awk -F: '{print $6}')"
    if [[ -n "$HFT_ROOT" && "$HFT_HOME" != "${HFT_ROOT}"* ]]; then
        HFT_HOME="${HFT_ROOT}${HFT_HOME}"
    fi
else
    HFT_HOME="${HFT_ROOT}/home/hft"
fi

# 1. Verify dev-hugepages.mount.d/99-hft.conf
HP_DROPIN="${HFT_ROOT}/etc/systemd/system/dev-hugepages.mount.d/99-hft.conf"
EXPECTED_OPTS="Options=nosuid,nodev,pagesize=2M,mode=0775,gid=${HFT_GID}"
if [[ -r "$HP_DROPIN" ]]; then
    if grep -Fq "$EXPECTED_OPTS" "$HP_DROPIN" && ! grep -Eq '^[[:space:]]*ExecStartPost=' "$HP_DROPIN"; then
        pass_check "dev-hugepages.mount drop-in valid (numeric gid=${HFT_GID}, nosuid,nodev, no ExecStartPost)"
    else
        fail_check "dev-hugepages.mount drop-in invalid or contains ExecStartPost: $HP_DROPIN"
    fi
else
    fail_check "Missing $HP_DROPIN"
fi

# 2. Verify hft-hugepages-perms.service enabled
en="$("$HFT_SYSTEMCTL_CMD" is-enabled hft-hugepages-perms.service 2>/dev/null || true)"
if [[ "$en" == "enabled" ]]; then
    pass_check "hft-hugepages-perms.service is enabled"
else
    fail_check "hft-hugepages-perms.service is not enabled (state=${en:-unknown})"
fi

# 3. Verify /dev/hugepages is hugetlbfs and 0775 root:${HFT_GID}
HP_DIR="${HFT_ROOT}/dev/hugepages"
hp_fstype="$("$HFT_FINDMNT_CMD" -no FSTYPE /dev/hugepages 2>/dev/null || true)"
if [[ "$hp_fstype" == "hugetlbfs" ]]; then
    pass_check "/dev/hugepages fstype is hugetlbfs"
else
    fail_check "/dev/hugepages fstype is '${hp_fstype:-unknown}' (expected hugetlbfs)"
fi

if [[ -d "$HP_DIR" ]]; then
    hp_ug="$(stat_ug "$HP_DIR" || true)"
    hp_mode="$(stat_mode "$HP_DIR" || true)"
    if [[ "$hp_ug" == "0:${HFT_GID}" && ( "$hp_mode" == "775" || "$hp_mode" == "0775" ) ]]; then
        pass_check "/dev/hugepages owner=0:${HFT_GID} mode=$hp_mode"
    else
        fail_check "/dev/hugepages owner/mode mismatch (owner=${hp_ug:-?} mode=${hp_mode:-?}, expected 0:${HFT_GID} 775)"
    fi
else
    fail_check "Missing directory $HP_DIR"
fi

# 4. Verify hugepages-2048kB/nr_hugepages >= 512
LIVE_HP_FILE="${HFT_ROOT}/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
if [[ -r "$LIVE_HP_FILE" ]]; then
    live_hp="$(tr -d '[:space:]' < "$LIVE_HP_FILE")"
    if [[ "$live_hp" =~ ^[0-9]+$ ]] && (( live_hp >= 512 )); then
        pass_check "hugepages-2048kB/nr_hugepages=${live_hp} (>= 512)"
    else
        fail_check "hugepages-2048kB/nr_hugepages=${live_hp:-?} (< 512)"
    fi
else
    fail_check "Cannot read $LIVE_HP_FILE"
fi

# 5. Verify /dev/shm fstab + live mount + THP sysfs + tmpfiles.d
FSTAB="${HFT_ROOT}/etc/fstab"
if [[ -r "$FSTAB" ]] && awk '$1 !~ /^#/ && $2 == "/dev/shm" && $4 ~ /(^|,)huge=within_size(,|$)/ {found=1} END{exit !found}' "$FSTAB"; then
    pass_check "/etc/fstab /dev/shm entry carries huge=within_size"
else
    fail_check "/etc/fstab missing /dev/shm huge=within_size"
fi

shm_opts="$("$HFT_FINDMNT_CMD" -no OPTIONS /dev/shm 2>/dev/null || true)"
if [[ ",${shm_opts}," == *",huge=within_size,"* ]]; then
    pass_check "Live /dev/shm mount has huge=within_size"
else
    fail_check "Live /dev/shm mount missing huge=within_size (opts='${shm_opts:-}')"
fi

for knob in \
    "${HFT_ROOT}/sys/kernel/mm/transparent_hugepage/shmem_enabled" \
    "${HFT_ROOT}/sys/kernel/mm/transparent_hugepage/hugepages-2048kB/shmem_enabled"; do
    if [[ -r "$knob" ]]; then
        if grep -q '\[within_size\]' "$knob" || { [[ -n "$HFT_ROOT" ]] && grep -Eq '^[[:space:]]*within_size[[:space:]]*$' "$knob"; }; then
            pass_check "$knob is within_size"
        else
            fail_check "$knob is not within_size (got '$(cat "$knob")')"
        fi
    fi
done

if [[ -r "${HFT_ROOT}/etc/tmpfiles.d/hft-shm-thp.conf" ]]; then
    pass_check "/etc/tmpfiles.d/hft-shm-thp.conf exists"
else
    fail_check "Missing /etc/tmpfiles.d/hft-shm-thp.conf"
fi

# 6. Verify 99-hft-lowlatency.conf has NO tcp_low_latency and every key matches live /proc/sys
SYSCTL_FILE="${HFT_ROOT}/etc/sysctl.d/99-hft-lowlatency.conf"
if [[ -r "$SYSCTL_FILE" ]]; then
    if grep -q 'tcp_low_latency' "$SYSCTL_FILE"; then
        fail_check "Deprecated tcp_low_latency found in $SYSCTL_FILE"
    fi
    sysctl_ok=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key="$(printf '%s\n' "$line" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')"
        exp="$(printf '%s\n' "$line" | awk -F= '{sub(/^[^=]*=/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); gsub(/[[:space:]]+/," "); print}')"
        [[ -n "$key" ]] || continue
        proc_p="${HFT_ROOT}/proc/sys/${key//./\/}"
        if [[ ! -r "$proc_p" ]]; then
            fail_check "Missing live sysctl path $proc_p for $key"
            sysctl_ok=0
            continue
        fi
        actual="$(tr '\t' ' ' < "$proc_p" | sed -E 's/[[:space:]]+/ /g; s/^ | $//g')"
        if [[ "$actual" != "$exp" ]]; then
            fail_check "Live sysctl mismatch for $key (live='$actual' expected='$exp')"
            sysctl_ok=0
        fi
    done < "$SYSCTL_FILE"
    (( sysctl_ok == 1 )) && pass_check "All sysctl keys in $SYSCTL_FILE match live /proc/sys values"
else
    fail_check "Missing $SYSCTL_FILE"
fi

# 7. Verify all 3 hft-scoped limits files (and NO global * wildcard)
LIMITS_PAM="${HFT_ROOT}/etc/security/limits.d/99-hft.conf"
LIMITS_USER_UNIT="${HFT_ROOT}/etc/systemd/system/user@${HFT_UID}.service.d/99-hft-limits.conf"
LIMITS_USER_SVC="${HFT_HOME}/.config/systemd/user/service.d/99-hft-limits.conf"

if [[ -r "$LIMITS_PAM" ]] \
   && grep -Eq '^hft[[:space:]]+soft[[:space:]]+memlock[[:space:]]+unlimited' "$LIMITS_PAM" \
   && grep -Eq '^hft[[:space:]]+soft[[:space:]]+nofile[[:space:]]+1048576' "$LIMITS_PAM" \
   && grep -Eq '^hft[[:space:]]+soft[[:space:]]+rtprio[[:space:]]+99' "$LIMITS_PAM" \
   && ! grep -Eq '^[[:space:]]*\*[[:space:]]' "$LIMITS_PAM"; then
    pass_check "PAM limits file $LIMITS_PAM valid and hft-scoped"
else
    fail_check "PAM limits file $LIMITS_PAM invalid or missing"
fi

for uf in "$LIMITS_USER_UNIT" "$LIMITS_USER_SVC"; do
    if [[ -r "$uf" ]] \
       && grep -Fq 'LimitMEMLOCK=infinity' "$uf" \
       && grep -Fq 'LimitNOFILE=1048576' "$uf" \
       && grep -Fq 'LimitRTPRIO=99' "$uf"; then
        pass_check "Systemd limits drop-in valid: $uf"
    else
        fail_check "Systemd limits drop-in missing or incomplete: $uf"
    fi
done

# 8. Live-only checks (post-reboot mount options, boot stamp, active service, live limits)
if [[ "$MODE" == "live" ]]; then
    CUR_BOOT_ID="$(current_boot_id || true)"

    hp_opts="$("$HFT_FINDMNT_CMD" -no OPTIONS /dev/hugepages 2>/dev/null || true)"
    if [[ ",${hp_opts}," == *",nosuid,"* && ",${hp_opts}," == *",nodev,"* && ",${hp_opts}," == *",pagesize=2M,"* ]]; then
        pass_check "Live /dev/hugepages mount options include nosuid,nodev,pagesize=2M"
    else
        fail_check "Live /dev/hugepages mount options missing required flags (got '${hp_opts:-}')"
    fi

    act="$("$HFT_SYSTEMCTL_CMD" is-active hft-hugepages-perms.service 2>/dev/null || true)"
    if [[ "$act" == "active" ]]; then
        pass_check "hft-hugepages-perms.service is active"
    else
        fail_check "hft-hugepages-perms.service is not active (state=${act:-unknown})"
    fi

    HP_OK="${HFT_RUN_DIR}/hugepages.ok"
    if [[ -r "$HP_OK" ]]; then
        ug="$(stat_ug "$HP_OK" || true)"
        mode="$(stat_mode "$HP_OK" || true)"
        hp_boot="$(awk -F= '$1=="boot_id"{print $2; exit}' "$HP_OK")"
        if [[ "$ug" == "0:0" && ( "$mode" == "644" || "$mode" == "0644" ) && "$hp_boot" == "$CUR_BOOT_ID" ]]; then
            pass_check "hugepages.ok stamp valid for current boot"
        else
            fail_check "hugepages.ok stamp invalid (owner=${ug:-?} mode=${mode:-?} boot='${hp_boot:-}' cur='${CUR_BOOT_ID:-}')"
        fi
    else
        fail_check "Missing $HP_OK"
    fi

    # Check live user@<uid>.service limits
    u_lim="$("$HFT_SYSTEMCTL_CMD" show "user@${HFT_UID}.service" -p LimitMEMLOCK -p LimitNOFILE -p LimitRTPRIO 2>/dev/null || true)"
    u_mem="$(printf '%s\n' "$u_lim" | awk -F= '$1=="LimitMEMLOCK"{print $2; exit}')"
    u_nof="$(printf '%s\n' "$u_lim" | awk -F= '$1=="LimitNOFILE"{print $2; exit}')"
    u_rtp="$(printf '%s\n' "$u_lim" | awk -F= '$1=="LimitRTPRIO"{print $2; exit}')"
    if [[ ( "$u_mem" == "infinity" || "$u_mem" == "18446744073709551615" ) \
       && "$u_nof" =~ ^[0-9]+$ && "$u_nof" -ge 1048576 \
       && "$u_rtp" =~ ^[0-9]+$ && "$u_rtp" -ge 99 ]]; then
        pass_check "Live user@${HFT_UID}.service limits effective (MEMLOCK=${u_mem}, NOFILE=${u_nof}, RTPRIO=${u_rtp})"
    else
        fail_check "Live user@${HFT_UID}.service limits insufficient (MEMLOCK='${u_mem:-}', NOFILE='${u_nof:-}', RTPRIO='${u_rtp:-}')"
    fi

    # Check live hft session limits (pure read-only, zero sudo)
    if [[ -n "${HFT_SESSION_LIMITS_CHECK:-}" ]]; then
        if bash -c "$HFT_SESSION_LIMITS_CHECK"; then
            pass_check "Live hft session limits verified via injected probe"
        else
            fail_check "Live hft session limits probe failed"
        fi
    elif [[ "$(id -un 2>/dev/null || true)" == "hft" ]]; then
        s_mem="$(ulimit -l 2>/dev/null || true)"
        s_nof="$(ulimit -n 2>/dev/null || true)"
        s_rtp="$(ulimit -r 2>/dev/null || true)"
        if [[ "$s_mem" == "unlimited" && "$s_nof" =~ ^[0-9]+$ && "$s_nof" -ge 1048576 && "$s_rtp" =~ ^[0-9]+$ && "$s_rtp" -ge 99 ]]; then
            pass_check "Live hft shell session limits effective (memlock=$s_mem, nofile=$s_nof, rtprio=$s_rtp)"
        else
            fail_check "Live hft shell session limits insufficient (memlock='${s_mem:-}', nofile='${s_nof:-}', rtprio='${s_rtp:-}')"
        fi
    fi
fi

if (( FAIL > 0 )); then
    log_error "verify_05_memory_net_and_limits (${MODE}): ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_05_memory_net_and_limits (${MODE}): ALL CHECKS PASSED."
