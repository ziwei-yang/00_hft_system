#!/bin/bash
set -euo pipefail

# =============================================================================
# Chrony installer + tuner for HFT Linux boxes
# - Replaces systemd-timesyncd with chrony.
# - Configures verified non-smearing UTC sources (Cloudflare anycast + NIST).
# - Neutralises vendor / DHCP source directives in main /etc/chrony/chrony.conf
#   for deterministic timekeeping.
# - Idempotent: re-runs are no-ops once configured; full state is verified.
#
# Plan: /home/hft/.claude/plans/crontab-l-optimized-riddle.md
# Target: Debian / Ubuntu (apt). RHEL/Fedora/Arch refused with a clear error.
#
# Sudo discipline: every privileged command is `sudo`-prefixed individually.
# The script itself must NOT be invoked under sudo.
# =============================================================================

# --- Colors / log helpers (mirroring 06_customise_ssl.sh) ---------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
banner()      { echo -e "\n${BLUE}=== $1 ===${NC}"; }
die()         { log_error "$1"; exit 1; }

# --- OS guards ---------------------------------------------------------------
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

is_debian_family() {
    [[ -f /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian"   || "${ID:-}" == "ubuntu" ]] && return 0
    [[ " ${ID_LIKE:-} " =~ " debian " ]] && return 0
    return 1
}

# --- Canonical drop-in content (single source of truth) ----------------------
DROPIN_PATH="/etc/chrony/conf.d/05-hft.conf"
MAIN_CONF="/etc/chrony/chrony.conf"
MAIN_CONF_BACKUP="${MAIN_CONF}.pre-hft"

dropin_canonical() {
    cat <<'EOF'
# Managed by 05_chrony_time_sync.sh — do not edit by hand.
# Verified non-smearing UTC sources (Cloudflare anycast + NIST stratum-1).
# pool.ntp.org excluded: members have unpredictable smearing behaviour.
# Leap-second handling: see `leapsectz right/UTC` in main chrony.conf.
pool   time.cloudflare.com  iburst minpoll 4 maxpoll 6 maxsources 2
server time-a-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-b-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-c-g.nist.gov    iburst minpoll 4 maxpoll 6

# Intentionally NO `makestep` override here — the default `makestep 1 3`
# in /etc/chrony/chrony.conf handles boot-time large offsets. Restarts of
# chrony by this script are gated on config changes (operator-authorised
# maintenance), so the step path cannot fire mid-trading-day in practice.
EOF
}

# --- Awk neutraliser ---------------------------------------------------------
# Round-trip-stable transform of /etc/chrony/chrony.conf:
#   1. Strip leading `# HFT-NEUT: ` sentinel from any previously-neutralised
#      line — restores unmanaged baseline.
#   2. Strip the previous HFT-managed block.
#   3. Walk remaining lines; comment vendor (server|pool|peer) and any
#      sourcedir not pointing at /etc/chrony/conf.d, by prepending the
#      `# HFT-NEUT: ` sentinel. Inventory the lines for the block.
#   4. Note whether `confdir /etc/chrony/conf.d` is present in the
#      unmanaged section. If absent, the block emits an active confdir.
#   5. Append the canonical managed block.
neutralise_main_conf() {
    local in="$1" out="$2"
    awk '
        BEGIN {
            sentinel = "# HFT-NEUT: "
            inblock  = 0
            confdir_seen = 0
            n_neut = 0
        }
        # Step 2: skip prior managed block
        /^# === BEGIN HFT chrony tuning/ { inblock = 1; next }
        /^# === END HFT chrony tuning/   { inblock = 0; next }
        inblock { next }
        {
            line = $0
            # Step 1: restore baseline (strip sentinel prefix)
            if (line ~ /^[[:space:]]*#[[:space:]]*HFT-NEUT:[[:space:]]?/) {
                sub(/^[[:space:]]*#[[:space:]]*HFT-NEUT:[[:space:]]?/, "", line)
            }
            # Step 4: detect existing confdir line
            if (line ~ /^[[:space:]]*confdir[[:space:]]+\/etc\/chrony\/conf\.d([[:space:]]|$)/) {
                confdir_seen = 1
                print line
                next
            }
            # Step 3: comment vendor source directives
            if (line ~ /^[[:space:]]*(server|pool|peer)[[:space:]]+/) {
                neut[n_neut++] = line
                print sentinel line
                next
            }
            # sourcedir: comment unless it targets /etc/chrony/conf.d
            if (line ~ /^[[:space:]]*sourcedir[[:space:]]+/) {
                # parse path (2nd field)
                path = $2
                if (path != "/etc/chrony/conf.d") {
                    neut[n_neut++] = line
                    print sentinel line
                    next
                }
            }
            print line
        }
        END {
            print "# === BEGIN HFT chrony tuning (managed by 05_chrony_time_sync.sh) ==="
            print "# Vendor/DHCP source directives have been neutralised in-place"
            print "# with a `# HFT-NEUT: ` sentinel prefix; replacements live in"
            print "# /etc/chrony/conf.d/05-hft.conf."
            if (n_neut > 0) {
                print "# Inventory of neutralised directives (informational only):"
                for (i = 0; i < n_neut; i++) print "#   - " neut[i]
            } else {
                print "# (No vendor directives needed neutralisation.)"
            }
            if (!confdir_seen) {
                print "# `confdir /etc/chrony/conf.d` was missing in the unmanaged"
                print "# section above; injecting it now (active line below):"
                print "confdir /etc/chrony/conf.d"
            }
            print "# === END HFT chrony tuning ==="
        }
    ' "$in" > "$out"
}

# --- Quorum check ------------------------------------------------------------
# Returns count of sources whose chronyc -c CSV state column ($2) is one of
# `*` (selected), `+` (combined), `-` (selectable not combined).
count_reachable_sources() {
    chronyc -c sources 2>/dev/null | awk -F, '$2 ~ /^[*+\-]$/' | wc -l
}

# --- Main --------------------------------------------------------------------
main() {
    banner "Chrony Time Sync Setup for HFT"

    # ---------- 1. Preflight ----------
    is_linux         || die "This script only runs on Linux."
    is_debian_family || die "Unsupported distro. This script is apt-based (Debian/Ubuntu). TODO: add dnf path for RHEL/Fedora."

    if ! sudo -n true 2>/dev/null; then
        die "sudo requires password. Run 'sudo -v' first, then re-run this script."
    fi

    # Full-state early-exit check.
    early_exit_ok() {
        command -v chronyc >/dev/null 2>&1 || return 1
        systemctl is-active --quiet chrony || return 1
        local ts_active ts_enabled
        # systemctl is-active prints state to stdout AND exits non-zero
        # for non-active units; capture the state, swallow the exit, and
        # only fall back to the placeholder when stdout was empty.
        ts_active="$(systemctl is-active systemd-timesyncd 2>/dev/null || true)"
        [[ -z "$ts_active" ]] && ts_active="unknown"
        ts_enabled="$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)"
        [[ -z "$ts_enabled" ]] && ts_enabled="not-found"
        [[ "$ts_active" == "inactive" || "$ts_active" == "unknown" ]] || return 1
        [[ "$ts_enabled" == "masked" || "$ts_enabled" == "not-found" ]] || return 1
        local tmp_dropin tmp_main
        tmp_dropin="$(mktemp)"; tmp_main="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_dropin' '$tmp_main'" RETURN
        dropin_canonical > "$tmp_dropin"
        cmp -s "$tmp_dropin" "$DROPIN_PATH" 2>/dev/null || return 1
        grep -qE '^[[:space:]]*confdir[[:space:]]+/etc/chrony/conf\.d' "$MAIN_CONF" || return 1
        neutralise_main_conf "$MAIN_CONF" "$tmp_main" || return 1
        cmp -s "$tmp_main" "$MAIN_CONF" || return 1
        chronyc waitsync 60 0.05 0 1 >/dev/null 2>&1 || return 1
        local n
        n="$(count_reachable_sources)"
        [[ "$n" -ge 3 ]] || return 1
        return 0
    }

    if early_exit_ok; then
        log_success "Already configured. chrony active, timesyncd masked+inactive, drop-in matches, ≥3 reachable sources."
        exit 0
    fi

    log_info "Preflight: not fully configured; proceeding with repair/install."

    # `changed=1` flag tracks whether anything was modified this run.
    # chrony is restarted only when it's set (step 7).
    changed=0

    # ---------- 2. Install chrony ----------
    banner "Step 2: Install chrony"
    if dpkg -s chrony >/dev/null 2>&1; then
        log_info "chrony already installed."
    else
        log_info "Installing chrony via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y chrony
        changed=1
    fi
    command -v chronyc >/dev/null 2>&1 || die "chronyc not found after install."
    log_success "chrony available: $(command -v chronyc)"

    # ---------- 3. Stop + disable + mask systemd-timesyncd ----------
    banner "Step 3: Disable systemd-timesyncd"
    # is-active/is-enabled emit the state to stdout AND return non-zero
    # for non-active states. `|| true` swallows the exit; empty stdout
    # (unit not installed at all on minimal images) falls back below.
    timesyncd_active="$(systemctl is-active systemd-timesyncd 2>/dev/null || true)"
    [[ -z "$timesyncd_active" ]] && timesyncd_active="unknown"
    timesyncd_enabled="$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)"
    [[ -z "$timesyncd_enabled" ]] && timesyncd_enabled="not-found"
    log_info "timesyncd state: active=$timesyncd_active enabled=$timesyncd_enabled"

    if [[ "$timesyncd_active" == "active" ]]; then
        sudo systemctl stop systemd-timesyncd
        log_success "Stopped systemd-timesyncd."
        changed=1
    fi
    if [[ "$timesyncd_enabled" != "masked" && "$timesyncd_enabled" != "not-found" ]]; then
        sudo systemctl disable systemd-timesyncd 2>/dev/null || true
        sudo systemctl mask systemd-timesyncd
        log_success "Disabled and masked systemd-timesyncd."
        changed=1
    fi

    # ---------- 4. Write chrony drop-in ----------
    banner "Step 4: Write chrony drop-in"
    sudo install -d -m 0755 /etc/chrony/conf.d
    tmp_dropin="$(mktemp)"
    dropin_canonical > "$tmp_dropin"
    if cmp -s "$tmp_dropin" "$DROPIN_PATH" 2>/dev/null; then
        log_info "Drop-in $DROPIN_PATH already canonical."
    else
        sudo install -m 0644 "$tmp_dropin" "$DROPIN_PATH"
        log_success "Wrote $DROPIN_PATH"
        changed=1
    fi
    rm -f "$tmp_dropin"

    # ---------- 5. Neutralise vendor / DHCP sources in main config ----------
    banner "Step 5: Neutralise vendor / DHCP sources in main config"
    [[ -f "$MAIN_CONF" ]] || die "$MAIN_CONF missing — chrony install incomplete?"
    tmp_main="$(mktemp)"
    neutralise_main_conf "$MAIN_CONF" "$tmp_main"
    if cmp -s "$tmp_main" "$MAIN_CONF"; then
        log_info "$MAIN_CONF already neutralised; no change."
    else
        # First-apply backup (preserve pristine vendor copy).
        if [[ ! -e "$MAIN_CONF_BACKUP" ]]; then
            sudo install -m 0644 "$MAIN_CONF" "$MAIN_CONF_BACKUP"
            log_info "Backed up vendor config to $MAIN_CONF_BACKUP"
        fi
        sudo install -m 0644 "$tmp_main" "$MAIN_CONF"
        log_success "Updated $MAIN_CONF"
        changed=1
    fi
    rm -f "$tmp_main"

    # Report what's neutralised, for operator visibility.
    neut_count="$(grep -c '^# HFT-NEUT: ' "$MAIN_CONF" || true)"
    log_info "Neutralised vendor directives in main config: $neut_count"

    # ---------- 6. (folded into step 5) ----------

    # ---------- 7. Enable + restart chrony ----------
    banner "Step 7: Enable + start chrony"
    if ! systemctl is-enabled --quiet chrony 2>/dev/null; then
        sudo systemctl enable chrony
        changed=1
    fi
    if ! systemctl is-active --quiet chrony; then
        sudo systemctl start chrony
        changed=1
    fi
    if [[ "$changed" == 1 ]]; then
        log_info "Config changed — restarting chrony to apply..."
        sudo systemctl restart chrony
    else
        log_info "No config change — skipping chrony restart."
    fi

    # ---------- 8. Wait for first sync + verify ----------
    banner "Step 8: Wait for sync + verify"
    log_info "Waiting for chrony to sync (chronyc waitsync 60 0.05 0 1)..."
    if ! chronyc waitsync 60 0.05 0 1 >/dev/null; then
        log_error "chronyc waitsync timed out. Current state:"
        chronyc tracking || true
        chronyc sources -v || true
        die "chrony did not converge within 60 s."
    fi
    log_success "chrony reports max-correction ≤ 50 ms."

    n_reachable="$(count_reachable_sources)"
    if [[ "$n_reachable" -lt 3 ]]; then
        log_error "Quorum: only $n_reachable reachable sources (need ≥3 for falseticker resistance)."
        chronyc sources -v || true
        die "Provider-diverse quorum NOT met — investigate network reachability."
    fi
    log_success "Quorum: $n_reachable reachable sources (≥3 required for falseticker resistance)."

    echo
    log_info "chronyc tracking:"
    chronyc tracking
    echo
    log_info "chronyc sources -v:"
    chronyc sources -v
    echo
    log_info "timedatectl status:"
    timedatectl status | grep -E "System clock synchronized|NTP service|Time zone" || true

    # Final one-line summary.
    ref_id="$(chronyc tracking 2>/dev/null | awk -F: '/^Reference ID/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    sys_off="$(chronyc tracking 2>/dev/null | awk -F: '/^System time/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    echo
    log_success "chrony synced via ${ref_id:-unknown}, ${n_reachable} reachable sources, system offset ${sys_off:-unknown}."
    log_info "Sub-ms convergence will continue over the next several minutes."
}

main "$@"
