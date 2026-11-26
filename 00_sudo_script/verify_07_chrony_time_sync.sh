#!/usr/bin/env bash
# Pure read-only verifier for Layer 1 Step 07 (chrony config, quorum, optional exchange clock check).
# NEVER writes any file and NEVER mutates system state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu

REQUIRE_EXCHANGE_TIME=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --require-exchange-time) REQUIRE_EXCHANGE_TIME=true; shift ;;
        --staged|--live) shift ;;
        -h|--help)
            echo "Usage: verify_07_chrony_time_sync.sh [--require-exchange-time] [--staged|--live]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

EC2_MODE=false
if is_ec2; then
    EC2_MODE=true
fi

# 1. chrony active + enabled
c_act="$("$HFT_SYSTEMCTL_CMD" is-active chrony 2>/dev/null || true)"
c_en="$("$HFT_SYSTEMCTL_CMD" is-enabled chrony 2>/dev/null || true)"
if [[ "$c_act" == "active" && "$c_en" == "enabled" ]]; then
    pass_check "chrony is active and enabled"
else
    fail_check "chrony state invalid (active=${c_act:-unknown}, enabled=${c_en:-unknown})"
fi

# 2. systemd-timesyncd inactive + masked (or not-found)
ts_act="$("$HFT_SYSTEMCTL_CMD" is-active systemd-timesyncd 2>/dev/null || true)"
[[ -z "$ts_act" ]] && ts_act="inactive"
ts_en="$("$HFT_SYSTEMCTL_CMD" is-enabled systemd-timesyncd 2>/dev/null || true)"
[[ -z "$ts_en" ]] && ts_en="not-found"
if [[ "$ts_act" != "active" && ( "$ts_en" == "masked" || "$ts_en" == "not-found" ) ]]; then
    pass_check "systemd-timesyncd inactive and masked/not-found (active=$ts_act enabled=$ts_en)"
else
    fail_check "systemd-timesyncd not disabled/masked (active=$ts_act enabled=$ts_en)"
fi

# 3. Active main config byte-exact neutralisation + canonical drop-in + recursive zero-extra-sources
MAIN_CONF="$(chrony_resolve_main_conf)"
DROPIN_PATH="${HFT_ROOT}/etc/chrony/conf.d/07-hft.conf"

expected_dropin() {
    if [[ "$EC2_MODE" == true ]]; then
        cat <<'EOF'
# Managed by 07_chrony_time_sync.sh (EC2 mode) — do not edit by hand.
server 169.254.169.123 prefer iburst minpoll 2 maxpoll 4
EOF
    else
        cat <<'EOF'
# Managed by 07_chrony_time_sync.sh (Bare-metal mode) — do not edit by hand.
# Verified non-smearing UTC sources (Cloudflare anycast + NIST stratum-1).
pool   time.cloudflare.com  iburst minpoll 4 maxpoll 6 maxsources 2
server time-a-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-b-g.nist.gov    iburst minpoll 4 maxpoll 6
server time-c-g.nist.gov    iburst minpoll 4 maxpoll 6
EOF
    fi
}

if [[ -r "$DROPIN_PATH" ]] && diff -q <(expected_dropin) "$DROPIN_PATH" >/dev/null 2>&1; then
    pass_check "Drop-in $DROPIN_PATH matches canonical HFT config"
else
    fail_check "Drop-in $DROPIN_PATH missing or drifted from canonical config"
fi

if [[ -r "$MAIN_CONF" ]]; then
    if diff -q <(chrony_neutralise_main_conf_stdout "$MAIN_CONF") "$MAIN_CONF" >/dev/null 2>&1; then
        pass_check "Main config $MAIN_CONF matches byte-exact neutralised form"
    else
        fail_check "Main config $MAIN_CONF has unneutralised drift"
    fi

    exp_src="$(expected_dropin | awk '/^[[:space:]]*(server|pool|peer|refclock)[[:space:]]+/{gsub(/^[[:space:]]+|[[:space:]]+$/,""); gsub(/[[:space:]]+/," "); print}' | sort)"
    act_src="$(chrony_expand_effective_sources "$MAIN_CONF" | sort)"
    if [[ "$act_src" == "$exp_src" ]]; then
        pass_check "Recursive chrony effective config has zero extraneous sources"
    else
        fail_check "Extraneous or missing sources in recursive chrony config (got: $(printf '%s' "$act_src" | tr '\n' ';'))"
    fi
else
    fail_check "Cannot read active chrony main config: $MAIN_CONF"
fi

# 4. waitsync + Leap status Normal
if "$HFT_CHRONYC_CMD" waitsync 60 0.05 10 1 >/dev/null 2>&1; then
    pass_check "chronyc waitsync converged"
else
    fail_check "chronyc waitsync failed"
fi

TRACKING_OUT="$("$HFT_CHRONYC_CMD" tracking 2>/dev/null || true)"
if printf '%s\n' "$TRACKING_OUT" | grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal$'; then
    pass_check "chronyc tracking reports Leap status: Normal"
else
    fail_check "chronyc tracking does not report Leap status: Normal"
fi

# 5. Source selection & quorum verification
SOURCES_CSV="$("$HFT_CHRONYC_CMD" -c sources 2>/dev/null || true)"
if [[ "$EC2_MODE" == true ]]; then
    sel_list="$(printf '%s\n' "$SOURCES_CSV" | awk -F, '$2=="*" {print $3}')"
    other_active="$(printf '%s\n' "$SOURCES_CSV" | awk -F, '$2 ~ /^[*+]$/ && $3 != "169.254.169.123" {print $3}')"
    if [[ "$sel_list" == "169.254.169.123" && -z "$other_active" ]]; then
        pass_check "EC2 chrony exclusively synced to ^* 169.254.169.123"
    else
        fail_check "EC2 chrony source check failed (selected='${sel_list}', others='${other_active}')"
    fi
else
    has_sel="$(printf '%s\n' "$SOURCES_CSV" | awk -F, '$2=="*" {c++} END{print c+0}')"
    n_reach="$(printf '%s\n' "$SOURCES_CSV" | awk -F, '$2 ~ /^[*+\-]$/ {c++} END{print c+0}')"
    # Count distinct providers from chronyc sources (CSV $3 is IP or hostname; classify by domain or IP/subnet prefix)
    n_providers="$(printf '%s\n' "$SOURCES_CSV" | awk -F, '
        $2 ~ /^[*+\-]$/ {
            src = $3
            if (src ~ /cloudflare/ || src ~ /^162\.159\./) prov["cloudflare"] = 1
            else if (src ~ /nist\.gov/ || src ~ /^129\.6\./ || src ~ /^132\.163\./) prov["nist"] = 1
            else {
                # Group arbitrary IPs by /16 or hostname by last two labels
                if (src ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                    split(src, o, ".")
                    prov[o[1] "." o[2]] = 1
                } else {
                    n = split(src, p, ".")
                    if (n >= 2) prov[p[n-1] "." p[n]] = 1
                    else prov[src] = 1
                }
            }
        }
        END {
            c = 0
            for (k in prov) c++
            print c
        }
    ')"
    if (( has_sel >= 1 && n_reach >= 3 && n_providers >= 2 )); then
        pass_check "Bare-metal chrony quorum met (selected=$has_sel, reachable=$n_reach >= 3, providers=$n_providers >= 2)"
    else
        fail_check "Bare-metal chrony quorum NOT met (selected=$has_sel, reachable=$n_reach, providers=$n_providers)"
    fi
fi

# 6. Optional exchange time verification (--require-exchange-time)
# Samples Binance and OKX >= 3 times each; asserts EVERY sample's full interval
# [offset - rtt/2, offset + rtt/2] lies within [-100ms, +100ms].
if [[ "$REQUIRE_EXCHANGE_TIME" == true ]]; then
    SAMPLES="${HFT_EXCHANGE_SAMPLES:-3}"
    (( SAMPLES >= 3 )) || SAMPLES=3
    BINANCE_URL="${HFT_BINANCE_TIME_URL:-https://api.binance.com/api/v3/time}"
    OKX_URL="${HFT_OKX_TIME_URL:-https://www.okx.com/api/v5/public/time}"

    probe_exchange() {
        local ex="$1"
        local url="$2"
        local i t0 srv t1
        for (( i = 1; i <= SAMPLES; i++ )); do
            if [[ -n "${HFT_EXCHANGE_PROBE_CMD:-}" ]]; then
                read -r t0 srv t1 < <("$HFT_EXCHANGE_PROBE_CMD" "$ex" "$url" "$i") || {
                    fail_check "Exchange time UNVERIFIED: probe failed for $ex sample $i"
                    return 1
                }
            else
                # Pure read-only HTTP probe using python3 urllib
                read -r t0 srv t1 < <(python3 - "$ex" "$url" <<'PY'
import json, sys, time, urllib.request
ex, url = sys.argv[1], sys.argv[2]
t0 = int(time.time() * 1000)
req = urllib.request.Request(url, headers={"User-Agent": "hft-bootstrap-verify/1.0"})
with urllib.request.urlopen(req, timeout=5) as resp:
    body = json.loads(resp.read().decode("utf-8"))
t1 = int(time.time() * 1000)
if ex == "binance":
    srv = int(body["serverTime"])
else:
    srv = int(body["data"][0]["ts"])
print(t0, srv, t1)
PY
                ) || {
                    fail_check "Exchange time UNVERIFIED: HTTP fetch/parse failed for $ex sample $i"
                    return 1
                }
            fi

            # Validate integer bounds and interval [offset - rtt/2, offset + rtt/2] subset of [-100, +100]
            # Multiply by 2 to keep exact integer arithmetic:
            # 2*offset = 2*srv - (t0 + t1), rtt = t1 - t0
            # lower*2 = 2*offset - rtt = 2*(srv - t1), upper*2 = 2*offset + rtt = 2*(srv - t0)
            # Equivalently: both (srv - t1) and (srv - t0) MUST be in [-100, +100] ms!
            if [[ ! "$t0" =~ ^[0-9]+$ || ! "$srv" =~ ^[0-9]+$ || ! "$t1" =~ ^[0-9]+$ ]] || (( t1 < t0 )); then
                fail_check "Exchange time UNVERIFIED: invalid timestamps for $ex sample $i (t0=$t0 srv=$srv t1=$t1)"
                return 1
            fi
            local low_ms=$(( srv - t1 ))
            local high_ms=$(( srv - t0 ))
            if (( low_ms < -100 || high_ms > 100 )); then
                fail_check "Exchange time UNVERIFIED: $ex sample $i interval [${low_ms}ms, ${high_ms}ms] outside [-100ms, +100ms]"
                return 1
            fi
        done
        pass_check "Exchange time verified for $ex (${SAMPLES} samples all within [-100ms, +100ms])"
        return 0
    }

    probe_exchange binance "$BINANCE_URL" || true
    probe_exchange okx "$OKX_URL" || true
fi

if (( FAIL > 0 )); then
    log_error "verify_07_chrony_time_sync: ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_07_chrony_time_sync: ALL CHECKS PASSED."
