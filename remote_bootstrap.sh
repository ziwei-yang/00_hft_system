#!/usr/bin/env bash
# remote_bootstrap.sh -- run on the operator's macOS / Linux CONTROL TERMINAL to
# bootstrap a remote Ubuntu 24.04 LTS target (AWS EC2 or bare metal) with ONE SSH
# authentication:
#   Step 1: one `ssh ... 'sh -s'` call streams a generated POSIX sh payload that
#           clones this repo at an approved commit and runs Layer 1
#           (00_sudo_script/run_all.sh --ssh-key-source <deployed pubkey>).
#   Step 2: independent non-interactive bare-key login as `hft` asserting
#           `sudo -n true && id -un` prints exactly `hft`.
#   Step 3: optional `--reboot` (only after Steps 1 and 2 succeed) + next-step guide.
#
# Never accepts plaintext passwords, never uses sshpass, never copies local private
# keys, never uses ControlMaster, direct connections only (-F /dev/null).
# Compatible with macOS /bin/bash 3.2.57 and bash 5.x.
set -euo pipefail

LC_ALL=C
export LC_ALL

PROG="remote_bootstrap.sh"
DEFAULT_REPO_URL="https://github.com/ziwei-yang/00_hft_system.git"
SSH_BIN="${HFT_RB_SSH_BIN:-ssh}"
SSH_KEYGEN_BIN="ssh-keygen"

log()  { printf '[remote_bootstrap] %s\n' "$*" >&2; }
warn() { printf '[remote_bootstrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '[remote_bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: ${PROG} [options] <user@host>

Run on your macOS / Linux control terminal. Bootstraps a remote Ubuntu 24.04 LTS
target (Layer 1: 00_sudo_script/run_all.sh) over ONE SSH authentication, then
independently verifies key-only login + passwordless sudo for user 'hft'.

Target:
  <user@host>                     user matches ^[a-z_][a-z0-9_.-]*\$; host is a hostname,
                                  IPv4 address, or bracketed IPv6 literal such as [::1]

Authentication / keys:
  -i, --identity <path>           Login private key for the initial account (EC2 Key Pair
                                  mode: Step 1 uses BatchMode=yes). Without -i, OpenSSH
                                  prompts once for the password on /dev/tty.
      --hft-identity <path>       Local private key used for the Step 2 'hft' verification
                                  (and Step 3 --reboot). Must be unencrypted (BatchMode).
      --pubkey <path>             Local public key file deployed to hft's authorized_keys.
                                  Defaults: with -i only -> --hft-identity=<-i key>, pubkey
                                  derived via ssh-keygen -y; without -i -> --pubkey <x>.pub
                                  implies --hft-identity <x>; otherwise ~/.ssh/id_ed25519
                                  and ~/.ssh/id_ed25519.pub.

Connection:
  -p, --port <port>               SSH port (1..65535, default 22)
      --known-hosts-file <path>   Explicit UserKnownHostsFile for all SSH calls
      --strict-host-key-checking <ask|yes|accept-new>
                                  Default: ask (password mode) / yes (with -i).
                                  'no' is always refused; accept-new needs OpenSSH >= 7.6.

Source pinning:
      --repo-url <url>            Default ${DEFAULT_REPO_URL}
                                  (https://, ssh:// or git@ only)
      --ref <ref>                 Branch, tag, refs/heads/*, refs/tags/* or 40-hex commit
                                  (default: main)
      --expected-commit <sha>     Approved 40-hex commit the ref must resolve to
      --approved-commits-file <f> File with a '00_hft_system=<sha>' (or bare <sha>) line
      --allow-unpinned-ref        Break-glass: allow a non-SHA ref without approval

Layer 1 pass-through (forwarded to 00_sudo_script/run_all.sh):
      --max-phys-cores <N>        1..256
      --enable-idle-poll
      --no-managed-irq

Other:
      --dry-run                   Run all local checks, print summary, never call ssh
      --reboot                    After Steps 1 and 2 succeed, run 'sudo -n reboot' as hft
  -h, --help                      Show this help

Examples:
  ./${PROG} --ref <40-hex-commit> root@<host>
  ./${PROG} -i ~/.ssh/ec2-key.pem --ref <40-hex-commit> ubuntu@<host>
EOF
}

# ------------------------------------------------------------------------------
# Small helpers (bash 3.2 safe)
# ------------------------------------------------------------------------------
has_bad_chars() {
    case "$1" in
        *[[:space:]]*|*[[:cntrl:]]*) return 0 ;;
    esac
    return 1
}

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

HEX40_RE='^[0-9a-fA-F]{40}$'
USER_RE='^[a-z_][a-z0-9_.-]*$'
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'
IPV6_RE='^[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?$'
PORT_RE='^[1-9][0-9]{0,4}$'
CORES_RE='^[1-9][0-9]{0,2}$'
REF_RE='^[A-Za-z0-9._/-]+$'
APPROVED_RE='^00_hft_system=([0-9a-fA-F]{40})$'
OTHER_APPROVED_RE='^[A-Za-z0-9_.-]+=[0-9a-fA-F]{40}$'
PUBLINE_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/]+={0,2})([[:space:]].*)?$'
B64_RE='^[A-Za-z0-9+/]*={0,2}$'
SSHV_RE='OpenSSH_([0-9]+)\.([0-9]+)'
SAFE_ARG_RE='^[A-Za-z0-9_./:=@,+%-]+$'

fmt_cmd() {
    local out="" a
    for a in "$@"; do
        if [[ "$a" =~ $SAFE_ARG_RE ]]; then
            out="${out} ${a}"
        else
            out="${out} '${a}'"
        fi
    done
    printf '%s\n' "${out# }"
}

need_val() {
    [ $# -ge 2 ] || die "$1 requires a value"
}

# ------------------------------------------------------------------------------
# CLI parsing
# ------------------------------------------------------------------------------
LOGIN_IDENTITY=""
HFT_IDENTITY=""
PUBKEY_FILE=""
PORT="22"
KNOWN_HOSTS_FILE=""
KNOWN_HOSTS_SET=0
REPO_URL="$DEFAULT_REPO_URL"
REF="main"
EXPECTED_COMMIT=""
APPROVED_COMMITS_FILE=""
APPROVED_SET=0
ALLOW_UNPINNED=0
SHKC=""
MAX_PHYS_CORES=""
MAX_PHYS_CORES_SET=0
ENABLE_IDLE_POLL=0
NO_MANAGED_IRQ=0
DRY_RUN=0
DO_REBOOT=0
TARGET=""
TARGET_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--identity)            need_val "$@"; LOGIN_IDENTITY="$2"; [ -n "$2" ] || die "$1 must not be empty"; shift 2 ;;
        --hft-identity)           need_val "$@"; HFT_IDENTITY="$2"; [ -n "$2" ] || die "$1 must not be empty"; shift 2 ;;
        --pubkey)                 need_val "$@"; PUBKEY_FILE="$2"; [ -n "$2" ] || die "$1 must not be empty"; shift 2 ;;
        -p|--port)                need_val "$@"; PORT="$2"; shift 2 ;;
        --known-hosts-file)       need_val "$@"; KNOWN_HOSTS_FILE="$2"; KNOWN_HOSTS_SET=1; shift 2 ;;
        --repo-url)               need_val "$@"; REPO_URL="$2"; shift 2 ;;
        --ref)                    need_val "$@"; REF="$2"; shift 2 ;;
        --expected-commit)        need_val "$@"; EXPECTED_COMMIT="$2"; [ -n "$2" ] || die "$1 must not be empty"; shift 2 ;;
        --approved-commits-file)  need_val "$@"; APPROVED_COMMITS_FILE="$2"; APPROVED_SET=1; shift 2 ;;
        --allow-unpinned-ref)     ALLOW_UNPINNED=1; shift ;;
        --strict-host-key-checking) need_val "$@"; SHKC="$2"; [ -n "$2" ] || die "$1 must not be empty"; shift 2 ;;
        --max-phys-cores)         need_val "$@"; MAX_PHYS_CORES="$2"; MAX_PHYS_CORES_SET=1; shift 2 ;;
        --enable-idle-poll)       ENABLE_IDLE_POLL=1; shift ;;
        --no-managed-irq)         NO_MANAGED_IRQ=1; shift ;;
        --dry-run)                DRY_RUN=1; shift ;;
        --reboot)                 DO_REBOOT=1; shift ;;
        -h|--help)                usage; exit 0 ;;
        --)
            shift
            [ $# -eq 1 ] || die "exactly one <user@host> target is required after --"
            [ "$TARGET_SET" = "0" ] || die "target given twice"
            TARGET="$1"; TARGET_SET=1
            shift
            ;;
        -*) die "Unknown option: $1 (see --help)" ;;
        *)
            [ "$TARGET_SET" = "0" ] || die "Unexpected extra argument: $1"
            TARGET="$1"; TARGET_SET=1
            shift
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Target <user@host>
# ------------------------------------------------------------------------------
[ "$TARGET_SET" = "1" ] && [ -n "$TARGET" ] || die "missing <user@host> target (see --help)"
if has_bad_chars "$TARGET"; then die "target must not contain whitespace or control characters"; fi
case "$TARGET" in -*) die "target must not start with '-'" ;; esac
case "$TARGET" in *@*) ;; *) die "target must be <user@host> (missing '@')" ;; esac
SSH_USER="${TARGET%%@*}"
RAW_HOST="${TARGET#*@}"
case "$RAW_HOST" in *@*) die "target must contain exactly one '@'" ;; esac
[[ "$SSH_USER" =~ $USER_RE ]] || die "invalid user '$SSH_USER' (must match ^[a-z_][a-z0-9_.-]*\$)"
[ -n "$RAW_HOST" ] || die "empty host in target"
case "$RAW_HOST" in -*) die "host must not start with '-'" ;; esac
case "$RAW_HOST" in
    \[*)
        case "$RAW_HOST" in *\]) ;; *) die "unterminated bracketed IPv6 host: $RAW_HOST" ;; esac
        SSH_HOST="${RAW_HOST#\[}"
        SSH_HOST="${SSH_HOST%\]}"
        [[ "$SSH_HOST" =~ $IPV6_RE ]] || die "invalid bracketed IPv6 literal: $RAW_HOST"
        case "$SSH_HOST" in *:*) ;; *) die "bracketed host must be an IPv6 literal: $RAW_HOST" ;; esac
        ;;
    *)
        case "$RAW_HOST" in *\[*|*\]*) die "brackets are only allowed around a full IPv6 literal: $RAW_HOST" ;; esac
        [[ "$RAW_HOST" =~ $HOST_RE ]] || die "invalid host '$RAW_HOST' (hostname / IPv4, or [IPv6])"
        SSH_HOST="$RAW_HOST"
        ;;
esac

# ------------------------------------------------------------------------------
# Port, pass-through flags, known_hosts, host key policy
# ------------------------------------------------------------------------------
if ! [[ "$PORT" =~ $PORT_RE ]] || [ "$PORT" -gt 65535 ]; then
    die "invalid --port '$PORT' (integer 1..65535)"
fi

if [ "$MAX_PHYS_CORES_SET" = "1" ]; then
    if ! [[ "$MAX_PHYS_CORES" =~ $CORES_RE ]] || [ "$MAX_PHYS_CORES" -gt 256 ]; then
        die "invalid --max-phys-cores '$MAX_PHYS_CORES' (integer 1..256)"
    fi
fi

if [ "$KNOWN_HOSTS_SET" = "1" ]; then
    [ -n "$KNOWN_HOSTS_FILE" ] || die "--known-hosts-file must not be empty"
    if has_bad_chars "$KNOWN_HOSTS_FILE"; then die "--known-hosts-file must not contain whitespace or control characters"; fi
    case "$KNOWN_HOSTS_FILE" in -*) die "--known-hosts-file must not start with '-'" ;; esac
fi

if [ -z "$SHKC" ]; then
    if [ -n "$LOGIN_IDENTITY" ]; then SHKC="yes"; else SHKC="ask"; fi
fi
case "$SHKC" in
    ask|yes|accept-new) ;;
    *) die "--strict-host-key-checking must be ask, yes or accept-new (got '$SHKC'; 'no' is never allowed)" ;;
esac
if [ "$SHKC" = "accept-new" ]; then
    SSH_VERSION_OUT="$("$SSH_BIN" -V 2>&1 || true)"
    if [[ "$SSH_VERSION_OUT" =~ $SSHV_RE ]]; then
        SSHV_MAJOR="${BASH_REMATCH[1]}"
        SSHV_MINOR="${BASH_REMATCH[2]}"
        if [ "$SSHV_MAJOR" -lt 7 ] || { [ "$SSHV_MAJOR" -eq 7 ] && [ "$SSHV_MINOR" -lt 6 ]; }; then
            die "StrictHostKeyChecking=accept-new requires OpenSSH >= 7.6 (found ${SSHV_MAJOR}.${SSHV_MINOR}); pre-seed known_hosts and use the default 'yes'/'ask'"
        fi
    else
        die "cannot determine OpenSSH version from '${SSH_BIN} -V' ('${SSH_VERSION_OUT}'); refusing accept-new"
    fi
fi

# ------------------------------------------------------------------------------
# Repo URL whitelist
# ------------------------------------------------------------------------------
ALLOW_LOCAL_URL=0
if [ "${HFT_RB_ALLOW_LOCAL_REPO_URL:-0}" = "1" ]; then
    ALLOW_LOCAL_URL=1
fi
[ -n "$REPO_URL" ] || die "--repo-url must not be empty"
case "$REPO_URL" in -*) die "--repo-url must not start with '-'" ;; esac
if has_bad_chars "$REPO_URL"; then die "--repo-url must not contain whitespace or control characters"; fi
case "$REPO_URL" in
    https://?*|ssh://?*|git@?*) ;;
    file://?*|/?*)
        [ "$ALLOW_LOCAL_URL" = "1" ] || die "--repo-url '$REPO_URL': local file:// or absolute paths are only allowed in offline test mode"
        ;;
    *) die "--repo-url '$REPO_URL' must start with https://, ssh:// or git@" ;;
esac
if [ "$REPO_URL" != "$DEFAULT_REPO_URL" ]; then
    warn "non-default --repo-url '$REPO_URL' -- make sure you trust this source; it will run as root on the target"
fi

# ------------------------------------------------------------------------------
# Ref + commit approval gate (before any SSH)
# ------------------------------------------------------------------------------
[ -n "$REF" ] || die "--ref must not be empty"
case "$REF" in -*) die "--ref must not start with '-'" ;; esac
if has_bad_chars "$REF"; then die "--ref must not contain whitespace or control characters"; fi
[[ "$REF" =~ $REF_RE ]] || die "--ref '$REF' contains unsupported characters"
case "$REF" in
    HEAD|origin/HEAD) die "--ref '$REF' is refused (symbolic HEAD refs are not deterministic)" ;;
    *..*|*//*|*/|/*|*.lock|.*|*/.*) die "--ref '$REF' is not a valid ref name" ;;
esac

if [ -n "$EXPECTED_COMMIT" ]; then
    [[ "$EXPECTED_COMMIT" =~ $HEX40_RE ]] || die "--expected-commit must be a 40-hex commit SHA (got '$EXPECTED_COMMIT')"
    EXPECTED_COMMIT="$(to_lower "$EXPECTED_COMMIT")"
fi

if [ "$APPROVED_SET" = "1" ]; then
    [ -n "$APPROVED_COMMITS_FILE" ] && [ -f "$APPROVED_COMMITS_FILE" ] && [ -r "$APPROVED_COMMITS_FILE" ] \
        || die "--approved-commits-file '$APPROVED_COMMITS_FILE' must be a readable regular file"
    FILE_COMMIT=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$line" in ''|\#*) continue ;; esac
        cand=""
        if [[ "$line" =~ $HEX40_RE ]]; then
            cand="$line"
        elif [[ "$line" =~ $APPROVED_RE ]]; then
            cand="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $OTHER_APPROVED_RE ]]; then
            continue
        else
            die "malformed line in --approved-commits-file: '$line'"
        fi
        cand="$(to_lower "$cand")"
        if [ -n "$FILE_COMMIT" ] && [ "$FILE_COMMIT" != "$cand" ]; then
            die "--approved-commits-file lists conflicting commits for 00_hft_system"
        fi
        FILE_COMMIT="$cand"
    done < "$APPROVED_COMMITS_FILE"
    [ -n "$FILE_COMMIT" ] || die "--approved-commits-file has no '00_hft_system=<40-hex>' entry"
    if [ -n "$EXPECTED_COMMIT" ] && [ "$EXPECTED_COMMIT" != "$FILE_COMMIT" ]; then
        die "--expected-commit $EXPECTED_COMMIT conflicts with --approved-commits-file ($FILE_COMMIT)"
    fi
    EXPECTED_COMMIT="$FILE_COMMIT"
fi

if [[ "$REF" =~ $HEX40_RE ]]; then
    REF="$(to_lower "$REF")"
    if [ -n "$EXPECTED_COMMIT" ] && [ "$EXPECTED_COMMIT" != "$REF" ]; then
        die "--ref $REF does not match approved commit $EXPECTED_COMMIT"
    fi
    EXPECTED_COMMIT="$REF"
elif [ -z "$EXPECTED_COMMIT" ]; then
    if [ "$ALLOW_UNPINNED" = "1" ]; then
        warn "--allow-unpinned-ref: '$REF' will run WITHOUT commit approval (break-glass). Whatever it resolves to will execute as root."
    else
        die "--ref '$REF' is not a 40-hex commit: pass --expected-commit <sha> or --approved-commits-file <file> (or explicit --allow-unpinned-ref)"
    fi
fi

# ------------------------------------------------------------------------------
# Identity binding + fail-closed key validation (before any SSH)
# ------------------------------------------------------------------------------
if [ -n "$LOGIN_IDENTITY" ] && [ -z "$HFT_IDENTITY" ] && [ -z "$PUBKEY_FILE" ]; then
    HFT_IDENTITY="$LOGIN_IDENTITY"
elif [ -z "$HFT_IDENTITY" ]; then
    if [ -n "$PUBKEY_FILE" ]; then
        case "$PUBKEY_FILE" in
            ?*.pub) HFT_IDENTITY="${PUBKEY_FILE%.pub}" ;;
            *) die "cannot infer --hft-identity from --pubkey '$PUBKEY_FILE' (no .pub suffix); pass --hft-identity" ;;
        esac
    else
        HFT_IDENTITY="${HOME}/.ssh/id_ed25519"
        PUBKEY_FILE="${HFT_IDENTITY}.pub"
    fi
fi

load_private_key() {
    # $1 = path, $2 = label; prints the derived public key line
    local p="$1" label="$2" out=""
    if [ ! -f "$p" ] || [ ! -r "$p" ]; then
        die "$label '$p' must be an existing readable regular file"
    fi
    if ! out="$("$SSH_KEYGEN_BIN" -y -P "" -f "$p" </dev/null 2>/dev/null)" || [ -z "$out" ]; then
        die "$label '$p' cannot be loaded non-interactively: encrypted (passphrase-protected) private keys are not supported because BatchMode=yes verification cannot prompt; corrupt or unsupported key files are refused as well"
    fi
    printf '%s\n' "$out"
}

key_fp() {
    # stdin: "<type> <blob>" -> SHA256 fingerprint
    "$SSH_KEYGEN_BIN" -lf - 2>/dev/null | awk 'NR==1{print $2}'
}

if [ -n "$LOGIN_IDENTITY" ]; then
    load_private_key "$LOGIN_IDENTITY" "-i/--identity" >/dev/null || exit 1
fi
HFT_DERIVED="$(load_private_key "$HFT_IDENTITY" "--hft-identity")" || exit 1
HFT_KEY_TYPE="$(printf '%s\n' "$HFT_DERIVED" | awk 'NR==1{print $1}')"
HFT_KEY_BLOB="$(printf '%s\n' "$HFT_DERIVED" | awk 'NR==1{print $2}')"
case "$HFT_KEY_TYPE" in
    ssh-ed25519)                        HFT_BARE_PUBKEY_ALGOS="ssh-ed25519" ;;
    ssh-rsa)                            HFT_BARE_PUBKEY_ALGOS="rsa-sha2-512,rsa-sha2-256" ;;
    ecdsa-sha2-nistp256)                HFT_BARE_PUBKEY_ALGOS="ecdsa-sha2-nistp256" ;;
    ecdsa-sha2-nistp384)                HFT_BARE_PUBKEY_ALGOS="ecdsa-sha2-nistp384" ;;
    ecdsa-sha2-nistp521)                HFT_BARE_PUBKEY_ALGOS="ecdsa-sha2-nistp521" ;;
    sk-ssh-ed25519@openssh.com)         HFT_BARE_PUBKEY_ALGOS="sk-ssh-ed25519@openssh.com" ;;
    sk-ecdsa-sha2-nistp256@openssh.com) HFT_BARE_PUBKEY_ALGOS="sk-ecdsa-sha2-nistp256@openssh.com" ;;
    *-cert-v01@openssh.com) die "--hft-identity '$HFT_IDENTITY' is a certificate type ($HFT_KEY_TYPE); only bare keys are accepted" ;;
    *) die "--hft-identity '$HFT_IDENTITY' has unsupported key type '${HFT_KEY_TYPE:-unknown}'" ;;
esac
HFT_FP="$(printf '%s %s\n' "$HFT_KEY_TYPE" "$HFT_KEY_BLOB" | key_fp)"
[ -n "$HFT_FP" ] || die "cannot compute fingerprint of --hft-identity '$HFT_IDENTITY'"

PUBKEY_FPS=""
if [ -n "$PUBKEY_FILE" ]; then
    [ -f "$PUBKEY_FILE" ] && [ -r "$PUBKEY_FILE" ] || die "--pubkey '$PUBKEY_FILE' must be an existing readable regular file"
    [ -s "$PUBKEY_FILE" ] || die "--pubkey '$PUBKEY_FILE' is empty"
    if grep -q 'PRIVATE KEY' "$PUBKEY_FILE"; then
        die "--pubkey '$PUBKEY_FILE' contains a PRIVATE KEY; pass the .pub public key file (private keys never leave this machine)"
    fi
    n_valid=0
    fp_match=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in \#*) continue ;; esac
        if [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ]; then continue; fi
        [[ "$line" =~ $PUBLINE_RE ]] || die "--pubkey '$PUBKEY_FILE' has an invalid SSH public key line: '${line:0:60}'"
        lfp="$(printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" | key_fp)"
        [ -n "$lfp" ] || die "--pubkey '$PUBKEY_FILE' has a line rejected by ssh-keygen -lf: '${line:0:60}'"
        n_valid=$((n_valid + 1))
        PUBKEY_FPS="${PUBKEY_FPS:+${PUBKEY_FPS},}${lfp}"
        if [ "$lfp" = "$HFT_FP" ]; then fp_match=1; fi
    done < "$PUBKEY_FILE"
    [ "$n_valid" -gt 0 ] || die "--pubkey '$PUBKEY_FILE' contains no SSH public key"
    [ "$fp_match" = "1" ] || die "fingerprint mismatch: no key in --pubkey '$PUBKEY_FILE' ($PUBKEY_FPS) matches --hft-identity '$HFT_IDENTITY' ($HFT_FP)"
    PUBKEY_B64="$(base64 < "$PUBKEY_FILE" | tr -d '\r\n')"
    PUBKEY_SOURCE_DESC="$PUBKEY_FILE"
else
    PUBKEY_FPS="$HFT_FP"
    PUBKEY_B64="$(printf '%s\n' "$HFT_DERIVED" | base64 | tr -d '\r\n')"
    PUBKEY_SOURCE_DESC="derived from $HFT_IDENTITY via ssh-keygen -y"
fi

b64_str() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
REPO_URL_B64="$(b64_str "$REPO_URL")"
REF_B64="$(b64_str "$REF")"
EXPECTED_COMMIT_B64="$(b64_str "$EXPECTED_COMMIT")"
for v in "$PUBKEY_B64" "$REPO_URL_B64" "$REF_B64" "$EXPECTED_COMMIT_B64"; do
    [[ "$v" =~ $B64_RE ]] || die "internal error: base64 encoding produced unexpected characters"
done
[ -n "$PUBKEY_B64" ] || die "internal error: empty public key payload"

# ------------------------------------------------------------------------------
# Remote POSIX sh payload (pure ASCII; body wrapped in hft_rb_main, invoked last)
# ------------------------------------------------------------------------------
emit_remote_script() {
    cat <<'HFT_RB_HEAD'
#!/bin/sh
# Generated by remote_bootstrap.sh and fed to `sh -s` over stdin (pure ASCII).
# The entire body lives in hft_rb_main(), invoked on the very last line, so the
# shell reads the whole payload before executing a single command.
hft_rb_main() {
    set -eu
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true
    RUN_DIR=""
    RUN_SUFFIX=""
    # --- BEGIN EMBEDDED DATA (validated locally; passed as pure data) ---
HFT_RB_HEAD
    printf "    PUBKEY_B64='%s'\n" "$PUBKEY_B64"
    printf "    REPO_URL_B64='%s'\n" "$REPO_URL_B64"
    printf "    REF_B64='%s'\n" "$REF_B64"
    printf "    EXPECTED_COMMIT_B64='%s'\n" "$EXPECTED_COMMIT_B64"
    printf "    ALLOW_LOCAL_URL=%s\n" "$ALLOW_LOCAL_URL"
    printf "    MAX_PHYS_CORES='%s'\n" "$MAX_PHYS_CORES"
    printf "    ENABLE_IDLE_POLL=%s\n" "$ENABLE_IDLE_POLL"
    printf "    NO_MANAGED_IRQ=%s\n" "$NO_MANAGED_IRQ"
    cat <<'HFT_RB_BODY'
    # --- END EMBEDDED DATA ---

    hft_rb_log() { printf '[remote_bootstrap] %s\n' "$*" >&2; }
    hft_rb_fail() { printf '[remote_bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
    hft_rb_on_signal() { exit "$1"; }
    hft_rb_cleanup() {
        rc=$?
        if [ -n "$RUN_SUFFIX" ]; then
            case "$RUN_SUFFIX" in
                ??????) rm -rf "/tmp/hft_rb_run.${RUN_SUFFIX}" || echo "[remote_bootstrap] WARNING: failed to remove /tmp/hft_rb_run.${RUN_SUFFIX}" >&2 ;;
            esac
        fi
        exit "$rc"
    }
    trap 'hft_rb_on_signal 130' INT
    trap 'hft_rb_on_signal 143' TERM
    trap 'hft_rb_on_signal 129' HUP
    trap hft_rb_cleanup EXIT

    RUN_DIR="$(mktemp -d /tmp/hft_rb_run.XXXXXX)" || hft_rb_fail "mktemp -d /tmp/hft_rb_run.XXXXXX failed"
    case "$RUN_DIR" in
        /tmp/hft_rb_run.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
        *) hft_rb_fail "unexpected run directory path: $RUN_DIR" ;;
    esac
    RUN_SUFFIX="${RUN_DIR#/tmp/hft_rb_run.}"
    chmod 0700 "$RUN_DIR"
    if [ ! -d "$RUN_DIR" ] || [ -L "$RUN_DIR" ] || [ ! -O "$RUN_DIR" ]; then
        hft_rb_fail "$RUN_DIR is not a directory owned by the login user"
    fi
    printf 'HFT_REMOTE_RUN_DIR=%s\n' "$RUN_DIR"

    # --- System & privilege checks BEFORE any package / file change ---
    OS_RELEASE_FILE="${HFT_RB_TEST_OS_RELEASE:-/etc/os-release}"
    [ -r "$OS_RELEASE_FILE" ] || hft_rb_fail "cannot read $OS_RELEASE_FILE"
    OS_ID="$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d "\"'")"
    OS_VER="$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d "\"'")"
    if [ "$OS_ID" != "ubuntu" ] || [ "$OS_VER" != "24.04" ]; then
        hft_rb_fail "target must be Ubuntu 24.04 LTS (found ID=${OS_ID:-unknown} VERSION_ID=${OS_VER:-unknown})"
    fi
    IS_ROOT=0
    if [ "$(id -u)" = "0" ]; then
        IS_ROOT=1
    elif sudo -n true </dev/null >/dev/null 2>&1; then
        IS_ROOT=0
    else
        hft_rb_fail "login user is neither root nor has passwordless sudo (sudo -n true failed)"
    fi
    hft_rb_priv() {
        if [ "$IS_ROOT" = "1" ]; then
            "$@"
        else
            sudo -n "$@"
        fi
    }

    # --- Strict base64 decode via explicit pipe (invalid input ALWAYS fails) ---
    hft_rb_b64_decode() {
        _hft_b64_in="$(cat)"
        case "$_hft_b64_in" in
            *[!A-Za-z0-9+/=]*) return 1 ;;
            *=*[!=]*) return 1 ;;
        esac
        if [ $(( ${#_hft_b64_in} % 4 )) -ne 0 ]; then
            return 1
        fi
        if [ -z "$_hft_b64_in" ]; then
            return 0
        fi
        if printf 'QQ==' | base64 -d >/dev/null 2>&1; then
            printf '%s' "$_hft_b64_in" | base64 -d
        else
            printf '%s' "$_hft_b64_in" | base64 -D
        fi
    }
    hft_rb_is_hex40() {
        case "$1" in
            *[!0-9a-f]*) return 1 ;;
        esac
        [ "${#1}" -eq 40 ]
    }

    if ! printf '%s' "$PUBKEY_B64" | hft_rb_b64_decode > "$RUN_DIR/authorized_key.pub"; then
        hft_rb_fail "PUBKEY_B64 payload is not valid base64; aborting before any change"
    fi
    chmod 0600 "$RUN_DIR/authorized_key.pub"
    [ -s "$RUN_DIR/authorized_key.pub" ] || hft_rb_fail "decoded public key is empty"
    REPO_URL="$(printf '%s' "$REPO_URL_B64" | hft_rb_b64_decode)" || hft_rb_fail "REPO_URL_B64 payload is not valid base64"
    REF="$(printf '%s' "$REF_B64" | hft_rb_b64_decode)" || hft_rb_fail "REF_B64 payload is not valid base64"
    EXPECTED_COMMIT="$(printf '%s' "$EXPECTED_COMMIT_B64" | hft_rb_b64_decode)" || hft_rb_fail "EXPECTED_COMMIT_B64 payload is not valid base64"

    case "$REPO_URL" in
        ''|-*|*[[:space:]]*|*[[:cntrl:]]*) hft_rb_fail "repo URL rejected by remote whitelist" ;;
        https://?*|ssh://?*|git@?*) ;;
        file://?*|/?*)
            [ "$ALLOW_LOCAL_URL" = "1" ] || hft_rb_fail "local repo URLs are only allowed in offline test mode"
            ;;
        *) hft_rb_fail "repo URL scheme rejected by remote whitelist (https://, ssh://, git@ only)" ;;
    esac
    if [ -n "$EXPECTED_COMMIT" ] && ! hft_rb_is_hex40 "$EXPECTED_COMMIT"; then
        hft_rb_fail "embedded expected commit is not a lowercase 40-hex SHA"
    fi
    case "$MAX_PHYS_CORES" in
        '') ;;
        *[!0-9]*) hft_rb_fail "embedded --max-phys-cores is not numeric" ;;
    esac
    case "$ENABLE_IDLE_POLL$NO_MANAGED_IRQ" in
        00|01|10|11) ;;
        *) hft_rb_fail "embedded boolean flags are malformed" ;;
    esac

    # --- Ensure git + CA bundle (apt-get only when missing) ---
    CA_BUNDLE="${HFT_RB_TEST_CA_CERT:-/etc/ssl/certs/ca-certificates.crt}"
    if ! command -v git >/dev/null 2>&1 || [ ! -f "$CA_BUNDLE" ]; then
        hft_rb_log "installing git + ca-certificates via apt-get"
        hft_rb_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update </dev/null
        hft_rb_priv env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --no-install-recommends git ca-certificates </dev/null
        command -v git >/dev/null 2>&1 || hft_rb_fail "git is still unavailable after apt-get install"
    fi

    # --- Deterministic clone + ref resolution ---
    REPO_DIR="$RUN_DIR/repo"
    git clone --no-checkout -- "$REPO_URL" "$REPO_DIR" </dev/null || hft_rb_fail "git clone failed"
    hft_rb_is_symref() { git -C "$REPO_DIR" symbolic-ref -q "$1" >/dev/null 2>&1 </dev/null; }
    hft_rb_ref_exists() { git -C "$REPO_DIR" show-ref --verify --quiet "$1" </dev/null; }
    hft_rb_peel() { git -C "$REPO_DIR" rev-parse --verify --quiet "$1^{commit}" </dev/null; }

    case "$REF" in
        ''|-*|HEAD|origin/HEAD) hft_rb_fail "refusing ref '$REF' (empty, option-like, HEAD or origin/HEAD)" ;;
    esac
    if hft_rb_is_symref "$REF"; then
        hft_rb_fail "refusing symbolic ref '$REF'"
    fi
    RESOLVED_COMMIT=""
    if hft_rb_is_hex40 "$REF"; then
        obj_type="$(git -C "$REPO_DIR" cat-file -t "$REF" 2>/dev/null </dev/null || true)"
        if [ "$obj_type" != "commit" ]; then
            hft_rb_fail "ref $REF is not a commit object (type=${obj_type:-missing}); tag/tree/blob object ids are refused"
        fi
        RESOLVED_COMMIT="$REF"
    else
        case "$REF" in
            refs/heads/?*)
                branch="${REF#refs/heads/}"
                if hft_rb_is_symref "refs/remotes/origin/${branch}"; then
                    hft_rb_fail "refusing symbolic ref refs/remotes/origin/${branch}"
                fi
                RESOLVED_COMMIT="$(hft_rb_peel "refs/remotes/origin/${branch}")" || hft_rb_fail "branch '$branch' not found on remote"
                ;;
            refs/tags/?*)
                RESOLVED_COMMIT="$(hft_rb_peel "$REF")" || hft_rb_fail "tag '$REF' not found"
                ;;
            refs/*)
                hft_rb_fail "unsupported ref namespace '$REF' (use refs/heads/*, refs/tags/*, a bare name or a 40-hex commit)"
                ;;
            *)
                tag_ref="refs/tags/${REF}"
                br_ref="refs/remotes/origin/${REF}"
                if hft_rb_is_symref "$tag_ref" || hft_rb_is_symref "$br_ref"; then
                    hft_rb_fail "refusing symbolic ref for '$REF'"
                fi
                has_tag=0
                has_br=0
                if hft_rb_ref_exists "$tag_ref"; then has_tag=1; fi
                if hft_rb_ref_exists "$br_ref"; then has_br=1; fi
                if [ "$has_tag" = "1" ] && [ "$has_br" = "1" ]; then
                    hft_rb_fail "ambiguous ref '$REF': exists as both tag and branch; use refs/tags/$REF or refs/heads/$REF"
                elif [ "$has_tag" = "1" ]; then
                    RESOLVED_COMMIT="$(hft_rb_peel "$tag_ref")" || hft_rb_fail "tag '$REF' does not peel to a commit"
                elif [ "$has_br" = "1" ]; then
                    RESOLVED_COMMIT="$(hft_rb_peel "$br_ref")" || hft_rb_fail "branch '$REF' does not resolve to a commit"
                else
                    hft_rb_fail "ref '$REF' not found as tag or branch"
                fi
                ;;
        esac
    fi
    RESOLVED_COMMIT="$(printf '%s' "$RESOLVED_COMMIT" | tr 'ABCDEF' 'abcdef')"
    hft_rb_is_hex40 "$RESOLVED_COMMIT" || hft_rb_fail "ref '$REF' did not resolve to a 40-hex commit"

    # --- Commit approval BEFORE checkout and BEFORE running any repo file ---
    if [ -n "$EXPECTED_COMMIT" ]; then
        if [ "$RESOLVED_COMMIT" != "$EXPECTED_COMMIT" ]; then
            hft_rb_fail "commit approval mismatch: '$REF' resolved to $RESOLVED_COMMIT but approved commit is $EXPECTED_COMMIT"
        fi
    else
        hft_rb_log "WARNING: unpinned ref '$REF' resolved to $RESOLVED_COMMIT (no approval gate)"
    fi
    git -C "$REPO_DIR" checkout --detach "$RESOLVED_COMMIT" </dev/null || hft_rb_fail "git checkout failed"
    printf 'HFT_RESOLVED_COMMIT=%s\n' "$RESOLVED_COMMIT"

    # --- Pure static entrypoint contract check (never executes run_all.sh --help) ---
    ENTRY="$REPO_DIR/00_sudo_script/run_all.sh"
    if [ ! -f "$ENTRY" ] || [ -L "$ENTRY" ] || [ ! -r "$ENTRY" ]; then
        hft_rb_fail "00_sudo_script/run_all.sh is missing or not a readable regular file"
    fi
    hft_rb_require_opt() {
        grep -Fq -- "$1" "$ENTRY" || hft_rb_fail "00_sudo_script/run_all.sh at $RESOLVED_COMMIT does not support $1 (static contract check)"
    }
    hft_rb_require_opt --ssh-key-source
    if [ -n "$MAX_PHYS_CORES" ]; then hft_rb_require_opt --max-phys-cores; fi
    if [ "$ENABLE_IDLE_POLL" = "1" ]; then hft_rb_require_opt --enable-idle-poll; fi
    if [ "$NO_MANAGED_IRQ" = "1" ]; then hft_rb_require_opt --no-managed-irq; fi

    # --- Execute Layer 1 (stdin isolated) ---
    set -- --ssh-key-source "$RUN_DIR/authorized_key.pub"
    if [ -n "$MAX_PHYS_CORES" ]; then set -- "$@" --max-phys-cores "$MAX_PHYS_CORES"; fi
    if [ "$ENABLE_IDLE_POLL" = "1" ]; then set -- "$@" --enable-idle-poll; fi
    if [ "$NO_MANAGED_IRQ" = "1" ]; then set -- "$@" --no-managed-irq; fi
    hft_rb_log "executing Layer 1: bash 00_sudo_script/run_all.sh $*"
    hft_rb_l1_rc=0
    bash "$ENTRY" "$@" </dev/null || hft_rb_l1_rc=$?
    if [ "$hft_rb_l1_rc" -ne 0 ]; then
        printf '[remote_bootstrap] ERROR: Layer 1 run_all.sh failed (exit %s)\n' "$hft_rb_l1_rc" >&2
        exit "$hft_rb_l1_rc"
    fi
    hft_rb_log "Layer 1 staged bootstrap finished on the target"
}
hft_rb_main
HFT_RB_BODY
}

L1_ARGS_DESC="--ssh-key-source <RUN_DIR>/authorized_key.pub"
if [ -n "$MAX_PHYS_CORES" ]; then L1_ARGS_DESC="$L1_ARGS_DESC --max-phys-cores $MAX_PHYS_CORES"; fi
if [ "$ENABLE_IDLE_POLL" = "1" ]; then L1_ARGS_DESC="$L1_ARGS_DESC --enable-idle-poll"; fi
if [ "$NO_MANAGED_IRQ" = "1" ]; then L1_ARGS_DESC="$L1_ARGS_DESC --no-managed-irq"; fi

# ------------------------------------------------------------------------------
# SSH option sets
# ------------------------------------------------------------------------------
SSH_COMMON=(-F /dev/null -T -a -x
    -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no -o ForwardX11=no
    -o ClearAllForwardings=yes -o ServerAliveInterval=15
    -o "StrictHostKeyChecking=${SHKC}" -p "$PORT")
if [ -n "$KNOWN_HOSTS_FILE" ]; then
    SSH_COMMON+=(-o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}")
fi
STEP1_EXTRA=()
if [ -n "$LOGIN_IDENTITY" ]; then
    STEP1_EXTRA=(-o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o CertificateFile=none
        -i "$LOGIN_IDENTITY")
fi
HFT_SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o CertificateFile=none
    -o "PubkeyAcceptedAlgorithms=${HFT_BARE_PUBKEY_ALGOS}" -o PreferredAuthentications=publickey
    -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
    -i "$HFT_IDENTITY")
LOGIN_DEST="${SSH_USER}@${SSH_HOST}"
HFT_DEST="hft@${SSH_HOST}"
VERIFY_CMD='sudo -n true && id -un'
REBOOT_CMD='sudo -n reboot'

# ------------------------------------------------------------------------------
# --dry-run
# ------------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
    if [ -n "$LOGIN_IDENTITY" ]; then
        AUTH_DESC="EC2 key pair $LOGIN_IDENTITY (BatchMode=yes, no password)"
    else
        AUTH_DESC="password typed ONCE at the standard OpenSSH prompt"
    fi
    PAYLOAD_TEXT="$(emit_remote_script)"
    echo "=== ${PROG} --dry-run: all local checks passed; NO SSH connection is made ==="
    echo "Target (normalized)      : ${LOGIN_DEST}"
    echo "Host / port              : ${SSH_HOST} / ${PORT}"
    echo "Host key policy          : StrictHostKeyChecking=${SHKC}"
    echo "Known hosts file         : ${KNOWN_HOSTS_FILE:-(OpenSSH default)}"
    echo "Step 1 authentication    : ${AUTH_DESC}"
    echo "hft identity (Step 2/3)  : ${HFT_IDENTITY}"
    echo "hft bare key type        : ${HFT_KEY_TYPE} (fingerprint ${HFT_FP})"
    echo "PubkeyAcceptedAlgorithms : ${HFT_BARE_PUBKEY_ALGOS}"
    echo "Deployed pubkey          : ${PUBKEY_SOURCE_DESC}"
    echo "Deployed fingerprint(s)  : ${PUBKEY_FPS}"
    echo "Repo URL                 : ${REPO_URL}"
    echo "Ref                      : ${REF}"
    echo "Expected commit          : ${EXPECTED_COMMIT:-(UNPINNED: --allow-unpinned-ref)}"
    echo "Layer 1 run_all.sh args  : ${L1_ARGS_DESC}"
    echo "Reboot after Step 2      : $([ "$DO_REBOOT" = "1" ] && echo yes || echo no)"
    echo "Step 1 command           : $(fmt_cmd "$SSH_BIN" "${SSH_COMMON[@]}" ${STEP1_EXTRA[@]+"${STEP1_EXTRA[@]}"} -- "$LOGIN_DEST" 'sh -s')  < payload"
    echo "Step 2 command           : $(fmt_cmd "$SSH_BIN" "${SSH_COMMON[@]}" "${HFT_SSH_OPTS[@]}" -- "$HFT_DEST" "$VERIFY_CMD")"
    if [ "$DO_REBOOT" = "1" ]; then
        echo "Step 3 command           : $(fmt_cmd "$SSH_BIN" "${SSH_COMMON[@]}" "${HFT_SSH_OPTS[@]}" -- "$HFT_DEST" "$REBOOT_CMD")"
    fi
    echo "Remote command (static)  : 'sh -s' ($(printf '%s\n' "$PAYLOAD_TEXT" | wc -l | tr -d '[:space:]') payload lines on stdin)"
    echo "Remote payload preview (header + embedded data):"
    printf '%s\n' "$PAYLOAD_TEXT" | sed -n '1,/END EMBEDDED DATA/p' | sed 's/^/  | /'
    echo "  | ..."
    printf '%s\n' "$PAYLOAD_TEXT" | tail -n 2 | sed 's/^/  | /'
    exit 0
fi

# ------------------------------------------------------------------------------
# Local scratch dir (payload + Step 1 transcript), always cleaned up
# ------------------------------------------------------------------------------
LOCAL_SUFFIX=""
local_cleanup() {
    if [ -n "$LOCAL_SUFFIX" ]; then
        case "$LOCAL_SUFFIX" in
            ??????) rm -rf "/tmp/hft_rb_local.${LOCAL_SUFFIX}" ;;
        esac
    fi
}
trap local_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
LOCAL_TMP="$(mktemp -d /tmp/hft_rb_local.XXXXXX)" || die "mktemp failed"
case "$LOCAL_TMP" in
    /tmp/hft_rb_local.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
    *) die "unexpected local scratch path: $LOCAL_TMP" ;;
esac
LOCAL_SUFFIX="${LOCAL_TMP#/tmp/hft_rb_local.}"
chmod 0700 "$LOCAL_TMP"
PAYLOAD_FILE="$LOCAL_TMP/payload.sh"
STEP1_LOG="$LOCAL_TMP/step1.log"
emit_remote_script > "$PAYLOAD_FILE"

# ------------------------------------------------------------------------------
# Step 1: single SSH call, payload over stdin, output streamed live + captured
# ------------------------------------------------------------------------------
if [ -z "$LOGIN_IDENTITY" ]; then
    if [ "${HFT_RB_SKIP_TTY_CHECK:-0}" != "1" ]; then
        if ! { [ -r /dev/tty ] && [ -w /dev/tty ]; }; then
            die "password mode needs an interactive terminal (/dev/tty) so OpenSSH can ask for host key confirmation and the password once"
        fi
    fi
    log "Password mode: OpenSSH will prompt on your terminal."
    log "  1) FIRST compare the host key fingerprint it shows with your trusted console / provisioning record before typing 'yes'."
    log "  2) Then type the SSH password for ${LOGIN_DEST} ONCE. It is never stored and never passed to this script."
fi
log "Step 1/3: streaming Layer 1 bootstrap payload to ${LOGIN_DEST} (port ${PORT}, ref ${REF}, approved commit ${EXPECTED_COMMIT:-UNPINNED})"
set +e
"$SSH_BIN" "${SSH_COMMON[@]}" ${STEP1_EXTRA[@]+"${STEP1_EXTRA[@]}"} -- "$LOGIN_DEST" 'sh -s' < "$PAYLOAD_FILE" | tee "$STEP1_LOG"
STEP1_PIPE=("${PIPESTATUS[@]}")
set -e
STEP1_RC="${STEP1_PIPE[0]}"
if [ "$STEP1_RC" -ne 0 ]; then
    log "ERROR: Step 1 failed on the target (exit ${STEP1_RC}); hft verification and reboot are skipped."
    exit "$STEP1_RC"
fi
if [ "${STEP1_PIPE[1]:-0}" -ne 0 ]; then
    die "could not capture Step 1 output locally (tee failed)"
fi
RESOLVED_LIST="$(sed -n 's/^HFT_RESOLVED_COMMIT=//p' "$STEP1_LOG" | sort -u)"
if [ -z "$RESOLVED_LIST" ] || [ "$(printf '%s\n' "$RESOLVED_LIST" | wc -l | tr -d '[:space:]')" != "1" ]; then
    die "Step 1 did not report exactly one HFT_RESOLVED_COMMIT"
fi
HFT_RESOLVED_COMMIT="$RESOLVED_LIST"
[[ "$HFT_RESOLVED_COMMIT" =~ $HEX40_RE ]] || die "Step 1 reported a malformed HFT_RESOLVED_COMMIT"
if [ -n "$EXPECTED_COMMIT" ] && [ "$HFT_RESOLVED_COMMIT" != "$EXPECTED_COMMIT" ]; then
    die "Step 1 reported commit $HFT_RESOLVED_COMMIT but approved commit is $EXPECTED_COMMIT"
fi
log "Step 1 OK: Layer 1 staged at commit ${HFT_RESOLVED_COMMIT}"

# ------------------------------------------------------------------------------
# Step 2: independent non-interactive bare-key hft verification
# ------------------------------------------------------------------------------
log "Step 2/3: verifying key-only login + passwordless sudo as ${HFT_DEST} (${HFT_BARE_PUBKEY_ALGOS}, ${HFT_FP})"
set +e
VERIFY_OUT="$("$SSH_BIN" "${SSH_COMMON[@]}" "${HFT_SSH_OPTS[@]}" -- "$HFT_DEST" "$VERIFY_CMD" </dev/null)"
VERIFY_RC=$?
set -e
if [ "$VERIFY_RC" -ne 0 ]; then
    die "Step 2 FAILED (exit ${VERIFY_RC}): '${HFT_IDENTITY}' could not log in as hft with only its bare key, or sudo -n failed. Do NOT reboot; fix access from the still-working initial account first."
fi
if [ "$VERIFY_OUT" != "hft" ]; then
    die "Step 2 FAILED: expected stdout exactly 'hft', got '$(printf '%s' "$VERIFY_OUT" | tr '\n' ' ')'. Do NOT reboot."
fi
log "Step 2 OK: hft key-only login and passwordless sudo verified"

# ------------------------------------------------------------------------------
# Step 3: optional reboot + next-step guide
# ------------------------------------------------------------------------------
REBOOTED=0
if [ "$DO_REBOOT" = "1" ]; then
    log "Step 3/3: rebooting the target as hft (sudo -n reboot)"
    set +e
    "$SSH_BIN" "${SSH_COMMON[@]}" "${HFT_SSH_OPTS[@]}" -- "$HFT_DEST" "$REBOOT_CMD" </dev/null
    REBOOT_RC=$?
    set -e
    if [ "$REBOOT_RC" -eq 0 ]; then
        REBOOTED=1
    elif [ "$REBOOT_RC" -eq 255 ]; then
        REBOOTED=1
        warn "ssh exited 255 while issuing reboot (connection dropped by the rebooting host is expected)"
    else
        die "Step 3: 'sudo -n reboot' failed (exit ${REBOOT_RC})"
    fi
fi

SSH_HINT="ssh"
if [ "$PORT" != "22" ]; then SSH_HINT="${SSH_HINT} -p ${PORT}"; fi
SSH_HINT="${SSH_HINT} -i ${HFT_IDENTITY} ${HFT_DEST}"
echo ""
echo "=== Layer 1 staged + hft verified. Approved commit: ${HFT_RESOLVED_COMMIT} ==="
echo "Next steps:"
if [ "$REBOOTED" = "1" ]; then
    echo "  1. Reboot issued. Wait for the host to come back."
else
    echo "  1. Reboot the target:  ${SSH_HINT} 'sudo -n reboot'"
fi
echo "  2. Log in as hft:      ${SSH_HINT}"
echo "  3. Clone the SAME commit:"
echo "       git clone ${REPO_URL} ~/Proj/00_hft_system"
echo "       cd ~/Proj/00_hft_system && git checkout --detach ${HFT_RESOLVED_COMMIT}"
echo "  4. Post-reboot live gate:"
echo "       ./00_sudo_script/verify_all.sh --live"
echo "       ./00_sudo_script/verify_07_chrony_time_sync.sh --require-exchange-time"
echo "  5. Layer 2 as hft (zero sudo):"
echo "       ./01_startup/run_all.sh"
