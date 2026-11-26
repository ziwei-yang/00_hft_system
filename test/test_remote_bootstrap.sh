#!/usr/bin/env bash
# Offline test suite for remote_bootstrap.sh (RA1-RA5).
#
# Compatible with macOS /bin/bash 3.2.57 AND Ubuntu bash 5.2.
# NEVER contacts a real host and NEVER invokes real sudo / apt-get:
#   - a mock `ssh` (HFT_RB_SSH_BIN) records every argv and, for the Step 1
#     `sh -s` call, pipes the generated payload into a REAL `/bin/sh -s`;
#   - the "remote" side runs inside a sandbox PATH with mock sudo / apt-get /
#     id / rm and a logging git wrapper, against a real local bare git repo;
#   - Step 2 / Step 3 calls are answered by a mock server model that only
#     authenticates when the isolated bare-key options are actually present.
#
# Usage: /bin/bash test/test_remote_bootstrap.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RB="$REPO/remote_bootstrap.sh"
README="$REPO/README.md"
RUN_BASH="${BASH:-/bin/bash}"

T="$(mktemp -d /tmp/test_rb_sandbox.XXXXXX)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
TAG="${T#/tmp/test_rb_sandbox.}"
case "$TAG" in
    [A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;;
    *) echo "FATAL: unexpected sandbox path: $T" >&2; exit 2 ;;
esac
cleanup() {
    rm -rf "/tmp/test_rb_sandbox.${TAG}"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1 -- $2"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "== $1 =="; }

# ------------------------------------------------------------------------------
# Hermetic environment
# ------------------------------------------------------------------------------
REAL_GIT="$(command -v git || true)"
REAL_ID="$(command -v id || true)"
if [ -z "$REAL_GIT" ] || [ -z "$REAL_ID" ] || ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "FATAL: git, id and ssh-keygen are required to run this suite" >&2
    exit 2
fi

mkdir -p "$T/home/.ssh" "$T/bin" "$T/rbin" "$T/keys"
chmod 0700 "$T/home/.ssh"
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
: > "$GIT_CONFIG_GLOBAL"
unset SSH_AUTH_SOCK 2>/dev/null || true
unset HFT_RB_ALLOW_LOCAL_REPO_URL HFT_RB_TEST_OS_RELEASE HFT_RB_TEST_CA_CERT 2>/dev/null || true

M="$T/mock"
export MOCK_DIR="$M"
export MOCK_REMOTE_BIN="$T/rbin"
export MOCK_REAL_GIT="$REAL_GIT"
export MOCK_REAL_ID="$REAL_ID"
export FAKE_RUNALL_DIR="$M/runall"
export HFT_RB_SSH_BIN="$T/bin/ssh"
export HFT_RB_SKIP_TTY_CHECK=1
export HFT_RB_ALLOW_LOCAL_REPO_URL=1

printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' > "$T/os-release-2404"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="22.04"\n' > "$T/os-release-2204"
printf 'NAME="Debian GNU/Linux"\nID=debian\nVERSION_ID="12"\n' > "$T/os-release-debian"
printf 'dummy ca bundle for offline tests\n' > "$T/ca.crt"
export HFT_RB_TEST_OS_RELEASE="$T/os-release-2404"
export HFT_RB_TEST_CA_CERT="$T/ca.crt"

# ------------------------------------------------------------------------------
# Test keys (generated fresh; never real credentials)
# ------------------------------------------------------------------------------
K="$T/keys"
ssh-keygen -q -t ed25519 -N "" -C "hft-test" -f "$K/hft" </dev/null
ssh-keygen -q -t ed25519 -N "" -C "other-test" -f "$K/other" </dev/null
ssh-keygen -q -t ed25519 -N "" -C "ec2-login-test" -f "$K/ec2login" </dev/null
ssh-keygen -q -t ed25519 -N "offline-test-passphrase" -C "enc-test" -f "$K/enc" </dev/null
ssh-keygen -q -t ecdsa -b 256 -N "" -C "ecdsa-test" -f "$K/ecdsa" </dev/null
ssh-keygen -q -t rsa -b 2048 -N "" -C "rsa-test" -f "$K/rsa" </dev/null
cp "$K/hft" "$HOME/.ssh/id_ed25519"
cp "$K/hft.pub" "$HOME/.ssh/id_ed25519.pub"
chmod 0600 "$HOME/.ssh/id_ed25519"

fp_pub() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }
fp_priv() { ssh-keygen -y -P "" -f "$1" </dev/null 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'; }
FP_HFT="$(fp_pub "$K/hft.pub")"
FP_EC2="$(fp_pub "$K/ec2login.pub")"
export MOCK_HFT_FP="$FP_HFT"

# ------------------------------------------------------------------------------
# Mock local ssh (records argv; Step 1 pipes payload into a REAL /bin/sh -s)
# ------------------------------------------------------------------------------
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
M="${MOCK_DIR:?}"
mkdir -p "$M"
if [ "${1:-}" = "-V" ] && [ $# -eq 1 ]; then
    printf '%s\n' "${MOCK_SSH_VERSION:-OpenSSH_9.6p1, LibreSSL 3.3.6}" >&2
    exit 0
fi
n=0
[ -f "$M/count" ] && n="$(cat "$M/count")"
n=$((n + 1))
printf '%s\n' "$n" > "$M/count"
: > "$M/call.$n.args"
for a in "$@"; do printf '%s\n' "$a" >> "$M/call.$n.args"; done

opts=""
ident=""
cfg=""
dest=""
rcmd=""
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; dest="${1:-}"; [ $# -gt 0 ] && shift; rcmd="$*"; break ;;
        -o) opts="${opts}${2:-}
"; shift 2 ;;
        -i) ident="${2:-}"; shift 2 ;;
        -F) cfg="${2:-}"; shift 2 ;;
        -p|-l|-c|-m|-J|-E) shift 2 ;;
        -*) shift ;;
        *) dest="$1"; shift; rcmd="$*"; break ;;
    esac
done
printf '%s\n' "$rcmd" > "$M/call.$n.cmd"
printf '%s\n' "$dest" > "$M/call.$n.dest"
has_opt() { printf '%s' "$opts" | grep -Fqx -- "$1"; }

if [ "$rcmd" = "sh -s" ]; then
    cat > "$M/payload.$n.sh"
    if [ -n "${MOCK_SSH_SED:-}" ]; then
        sed -e "$MOCK_SSH_SED" "$M/payload.$n.sh" > "$M/payload.$n.run.sh"
    else
        cp "$M/payload.$n.sh" "$M/payload.$n.run.sh"
    fi
    # Feed through a PIPE (non-seekable) exactly like sshd would.
    cat "$M/payload.$n.run.sh" | PATH="${MOCK_REMOTE_BIN:?}:$PATH" /bin/sh -s
    exit $?
fi

# Mock server model for Step 2 / Step 3 (hft@host).
authed=0
case "${MOCK_SERVER_ACCEPTS:-hft_key}" in
    hft_key)
        if [ -n "$ident" ] && [ -n "${MOCK_HFT_FP:-}" ]; then
            ifp="$(ssh-keygen -y -P "" -f "$ident" </dev/null 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
            [ "$ifp" = "$MOCK_HFT_FP" ] && authed=1
        fi
        ;;
    agent_only)
        # Another key from ~/.ssh/config or ssh-agent would be offered unless strictly isolated.
        if [ "$cfg" != "/dev/null" ] || ! has_opt "IdentitiesOnly=yes" || ! has_opt "IdentityAgent=none"; then
            authed=1
        fi
        ;;
    cert_only)
        # An SSH certificate would be offered unless certificates are disabled & algos are bare.
        if ! has_opt "CertificateFile=none" \
           || ! printf '%s' "$opts" | grep -q '^PubkeyAcceptedAlgorithms=' \
           || printf '%s' "$opts" | grep '^PubkeyAcceptedAlgorithms=' | grep -q 'cert-v01'; then
            authed=1
        fi
        ;;
    none) ;;
esac
if [ "$authed" != "1" ]; then
    echo "${dest}: Permission denied (publickey)." >&2
    exit 255
fi
case "$rcmd" in
    'sudo -n true && id -un')
        printf '%s\n' "${MOCK_VERIFY_STDOUT:-hft}"
        exit "${MOCK_VERIFY_RC:-0}"
        ;;
    'sudo -n reboot')
        echo "REBOOT $dest" >> "$M/reboot.log"
        exit 0
        ;;
    *)
        echo "mock ssh: unexpected remote command: $rcmd" >&2
        exit 97
        ;;
esac
EOF
chmod +x "$T/bin/ssh"

# ------------------------------------------------------------------------------
# Mock "remote" PATH tools
# ------------------------------------------------------------------------------
cat > "$T/rbin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DIR:?}/remote_sudo.log"
[ "${1:-}" = "-n" ] && shift
if [ "${MOCK_SUDO_OK:-1}" != "1" ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
[ $# -eq 0 ] && exit 1
exec "$@"
EOF
cat > "$T/rbin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DIR:?}/remote_apt.log"
exit 0
EOF
cat > "$T/rbin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DIR:?}/remote_git.log"
exec "${MOCK_REAL_GIT:?}" "$@"
EOF
cat > "$T/rbin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ] && [ $# -eq 1 ] && [ -n "${MOCK_ID_U:-}" ]; then
    printf '%s\n' "$MOCK_ID_U"
    exit 0
fi
exec "${MOCK_REAL_ID:?}" "$@"
EOF
# rm wrapper: counts remote cleanups; only ever removes /tmp/hft_rb_run.<6 alnum>.
cat > "$T/rbin/rm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_DIR:?}/remote_rm.log"
if [ $# -eq 2 ] && [ "$1" = "-rf" ]; then
    case "$2" in
        /tmp/hft_rb_run.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
            sfx="${2#/tmp/hft_rb_run.}"
            exec /bin/rm -rf "/tmp/hft_rb_run.${sfx}"
            ;;
    esac
fi
echo "mock rm: refusing unexpected removal: $*" >&2
exit 1
EOF
chmod +x "$T/rbin/sudo" "$T/rbin/apt-get" "$T/rbin/git" "$T/rbin/id" "$T/rbin/rm"

# ------------------------------------------------------------------------------
# Real local git repository (bare) with a fake Layer 1 entrypoint
# ------------------------------------------------------------------------------
write_fake_runall() {
    # $1 = destination, $2 = 1 to include --no-managed-irq in the static contract
    {
        echo '#!/usr/bin/env bash'
        echo '# Fake Layer 1 entrypoint for offline remote_bootstrap tests.'
        echo '# Supported: --ssh-key-source --max-phys-cores --enable-idle-poll'
        if [ "$2" = "1" ]; then
            echo '# Supported: --no-managed-irq'
        fi
        cat <<'EOS'
set -u
L="${FAKE_RUNALL_DIR:?}"
mkdir -p "$L"
printf '%s\n' "$@" > "$L/runall.args"
bytes="$(cat | wc -c | tr -d '[:space:]')"
printf '%s\n' "$bytes" > "$L/runall.stdin_bytes"
src=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-key-source) src="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$src" ] && cp "$src" "$L/runall.pubkey"
git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse HEAD > "$L/runall.head" 2>/dev/null
case "${FAKE_RUNALL_MODE:-ok}" in
    ok)   echo "fake run_all: ok"; exit 0 ;;
    fail) echo "fake run_all: failing with 7" >&2; exit 7 ;;
    term) kill -TERM "$PPID"; sleep 1; echo "child-done" > "$L/runall.after_term"; exit 0 ;;
esac
exit 3
EOS
    } > "$1"
    chmod +x "$1"
}

S="$T/src"
g() { "$REAL_GIT" -C "$S" -c user.name=hft-test -c user.email=hft-test@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
mkdir -p "$S"
"$REAL_GIT" init -q "$S"
g symbolic-ref HEAD refs/heads/main
mkdir -p "$S/00_sudo_script"
write_fake_runall "$S/00_sudo_script/run_all.sh" 1
echo c1 > "$S/marker"
g add -A && g commit -q -m c1
C1="$(g rev-parse HEAD)"
g tag -a v1.0 -m "annotated v1.0"
TAG_OBJ="$(g rev-parse v1.0)"
g checkout -q -b feat
echo feat > "$S/marker"
g commit -q -am feat
C3="$(g rev-parse HEAD)"
g checkout -q main
echo c2 > "$S/marker"
g commit -q -am c2
C2="$(g rev-parse HEAD)"
g branch amb "$C1"
g tag amb "$C2"
g checkout -q -b noopt
write_fake_runall "$S/00_sudo_script/run_all.sh" 0
g commit -q -am noopt
C4="$(g rev-parse HEAD)"
g checkout -q main
"$REAL_GIT" clone -q --bare "$S" "$T/repo.git"
URL="file://$T/repo.git"

# ------------------------------------------------------------------------------
# Runner helpers
# ------------------------------------------------------------------------------
RC=0
OUT=""
# run_rb <name> [VAR=value ...] -- <remote_bootstrap args...>
run_rb() {
    local name="$1"
    shift
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    [ $# -gt 0 ] && shift
    rm -rf "/tmp/test_rb_sandbox.${TAG}/mock"
    mkdir -p "$M" "$FAKE_RUNALL_DIR"
    OUT="$T/out.$name"
    ( cd "$T" && env ${envs[@]+"${envs[@]}"} "$RUN_BASH" "$RB" "$@" ) </dev/null > "$OUT" 2>&1
    RC=$?
}
calls() { if [ -f "$M/count" ]; then cat "$M/count"; else echo 0; fi; }
has() { grep -Fq -- "$1" "$OUT"; }
lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else echo 0; fi; }
remote_run_dir() { sed -n 's/^HFT_REMOTE_RUN_DIR=//p' "$OUT" | head -n 1; }
args_has_seq() {
    # args_has_seq <call_no> <a> <b>: consecutive argv pair present
    awk -v a="$2" -v b="$3" 'prev==a && $0==b {f=1} {prev=$0} END{exit !f}' "$M/call.$1.args" 2>/dev/null
}
tail_out() { tail -n 6 "$OUT" 2>/dev/null | tr '\n' '|'; }
b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
reject_local() {
    # reject_local <label> <name>: expects rc!=0 and zero ssh connections
    if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ]; then
        ok "$1"
    else
        bad "$1" "rc=$RC calls=$(calls) out=[$(tail_out)]"
    fi
}

PW=(--hft-identity "$K/hft" --pubkey "$K/hft.pub" --repo-url "$URL")
HOST="192.0.2.10"

if [ ! -f "$RB" ]; then
    echo "NOTE: $RB does not exist yet (TDD red phase)."
fi

# ==============================================================================
section "RA1: local fail-closed safety gates (before any SSH)"
# ==============================================================================
run_rb ra1_privkey -- --hft-identity "$K/hft" --pubkey "$K/hft" --ref "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && has "PRIVATE KEY"; then
    ok "private key passed to --pubkey rejected"
else
    bad "private key to --pubkey" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

run_rb ra1_missing_pub -- --hft-identity "$K/hft" --pubkey "$T/nope.pub" --ref "$C2" "root@$HOST"
reject_local "missing --pubkey file rejected"

printf 'this is not an ssh key\n' > "$T/garbage.pub"
run_rb ra1_bad_pub -- --hft-identity "$K/hft" --pubkey "$T/garbage.pub" --ref "$C2" "root@$HOST"
reject_local "malformed --pubkey line rejected"

{ cat "$K/hft.pub"; printf 'ssh-ed25519 AAAA@@@notbase64\n'; } > "$T/mixed.pub"
run_rb ra1_mixed_pub -- --hft-identity "$K/hft" --pubkey "$T/mixed.pub" --ref "$C2" "root@$HOST"
reject_local "--pubkey with one valid + one invalid line rejected"

: > "$T/empty.pub"
run_rb ra1_empty_pub -- --hft-identity "$K/hft" --pubkey "$T/empty.pub" --ref "$C2" "root@$HOST"
reject_local "empty --pubkey rejected"

run_rb ra1_enc_hft -- --hft-identity "$K/enc" --pubkey "$K/enc.pub" --ref "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && grep -qi 'encrypted' "$OUT"; then
    ok "passphrase-protected --hft-identity rejected before SSH (clear message)"
else
    bad "encrypted --hft-identity" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

run_rb ra1_enc_login -- -i "$K/enc" --hft-identity "$K/hft" --pubkey "$K/hft.pub" --ref "$C2" "ubuntu@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && grep -qi 'encrypted' "$OUT"; then
    ok "passphrase-protected -i login key rejected before SSH"
else
    bad "encrypted -i" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

run_rb ra1_fp_mismatch -- --hft-identity "$K/hft" --pubkey "$K/other.pub" --ref "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && grep -qi 'fingerprint' "$OUT"; then
    ok "--pubkey not matching --hft-identity fingerprint rejected"
else
    bad "fingerprint mismatch" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

bad_targets_ok=1
bad_target_detail=""
i=0
for tgt in "noatsign" "a@b@c" "-oProxyCommand=x@h" "root@-oProxyCommand=x" "Root@host" "root@" "@host" \
           "root@ho st" "root@[::1" "root@[zz::1]" "root@[]" "root@[192.0.2.10]" "root@::1" "1root@host" \
           "root@host$(printf '\t')x" "root@host]" ; do
    i=$((i + 1))
    run_rb "ra1_target_$i" -- "${PW[@]}" --ref "$C2" "$tgt"
    if [ "$RC" -eq 0 ] || [ "$(calls)" != "0" ]; then
        bad_targets_ok=0
        bad_target_detail="${bad_target_detail} [$tgt rc=$RC]"
    fi
done
if [ "$bad_targets_ok" = "1" ]; then
    ok "malformed / injection targets rejected (16 variants)"
else
    bad "bad targets" "$bad_target_detail"
fi

run_rb ra1_lead_dash -- "${PW[@]}" --ref "$C2" -- "-oProxyCommand=evil"
reject_local "target with leading '-' after -- rejected"

bad_urls_ok=1
bad_url_detail=""
i=0
for u in "http://example.com/x.git" "ftp://example.com/x.git" "-oProxyCommand=evil" "--upload-pack=evil" \
         "https://example.com/a b.git" "ext::sh -c evil" "file:///tmp/x.git" "/tmp/x.git" ""; do
    i=$((i + 1))
    run_rb "ra1_url_$i" HFT_RB_ALLOW_LOCAL_REPO_URL=0 -- --hft-identity "$K/hft" --pubkey "$K/hft.pub" \
        --repo-url "$u" --ref "$C2" "root@$HOST"
    if [ "$RC" -eq 0 ] || [ "$(calls)" != "0" ]; then
        bad_urls_ok=0
        bad_url_detail="${bad_url_detail} [$u rc=$RC]"
    fi
done
if [ "$bad_urls_ok" = "1" ]; then
    ok "bad repo URL schemes / -o injection / local paths without test env rejected (9 variants)"
else
    bad "bad repo URLs" "$bad_url_detail"
fi

run_rb ra1_custom_url HFT_RB_ALLOW_LOCAL_REPO_URL=0 -- --hft-identity "$K/hft" --pubkey "$K/hft.pub" \
    --repo-url "https://example.com/fork/00_hft_system.git" --ref "$C2" --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && grep -qi 'warning' "$OUT" && has "https://example.com/fork/00_hft_system.git"; then
    ok "non-default https URL accepted with explicit security warning"
else
    bad "custom URL warning" "rc=$RC out=[$(tail_out)]"
fi

run_rb ra1_unpinned -- "${PW[@]}" --ref main "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && grep -qi 'expected-commit' "$OUT"; then
    ok "branch ref without --expected-commit / approved file / --allow-unpinned-ref rejected"
else
    bad "unpinned ref" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

run_rb ra1_unpinned_ok -- "${PW[@]}" --ref main --allow-unpinned-ref --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && grep -qi 'warning' "$OUT" && [ "$(calls)" = "0" ]; then
    ok "--allow-unpinned-ref break-glass accepted with warning"
else
    bad "--allow-unpinned-ref" "rc=$RC out=[$(tail_out)]"
fi

printf '# approved commits\nother_repo=%s\n00_hft_system=%s\n' "$C1" "$C2" > "$T/approved.txt"
run_rb ra1_approved -- "${PW[@]}" --ref main --approved-commits-file "$T/approved.txt" --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && has "$C2"; then
    ok "--approved-commits-file loads 00_hft_system=<sha>"
else
    bad "--approved-commits-file" "rc=$RC out=[$(tail_out)]"
fi

printf '00_hft_system=%s\n' "$C1" > "$T/approved_c1.txt"
run_rb ra1_approved_conflict -- "${PW[@]}" --ref main --approved-commits-file "$T/approved_c1.txt" \
    --expected-commit "$C2" --dry-run "root@$HOST"
reject_local "--approved-commits-file conflicting with --expected-commit rejected"

printf 'garbage line here\n' > "$T/approved_bad.txt"
run_rb ra1_approved_bad -- "${PW[@]}" --ref main --approved-commits-file "$T/approved_bad.txt" "root@$HOST"
reject_local "malformed --approved-commits-file rejected"

run_rb ra1_sha_mismatch -- "${PW[@]}" --ref "$C1" --expected-commit "$C2" "root@$HOST"
reject_local "40-hex --ref differing from --expected-commit rejected"

run_rb ra1_bad_expected -- "${PW[@]}" --ref main --expected-commit "deadbeef" "root@$HOST"
reject_local "non-40-hex --expected-commit rejected"

run_rb ra1_local_head -- "${PW[@]}" --ref HEAD --allow-unpinned-ref "root@$HOST"
reject_local "--ref HEAD rejected locally"
run_rb ra1_local_ohead -- "${PW[@]}" --ref origin/HEAD --allow-unpinned-ref "root@$HOST"
reject_local "--ref origin/HEAD rejected locally"
run_rb ra1_ref_dash -- "${PW[@]}" --ref "-oevil" --allow-unpinned-ref "root@$HOST"
reject_local "--ref with leading '-' rejected"

run_rb ra1_shkc_no -- "${PW[@]}" --ref "$C2" --strict-host-key-checking no "root@$HOST"
reject_local "--strict-host-key-checking no rejected"
run_rb ra1_shkc_bad -- "${PW[@]}" --ref "$C2" --strict-host-key-checking off "root@$HOST"
reject_local "--strict-host-key-checking off rejected"

run_rb ra1_old_ssh MOCK_SSH_VERSION="OpenSSH_7.4p1, OpenSSL 1.0.2k-fips  26 Jan 2017" -- \
    "${PW[@]}" --ref "$C2" --strict-host-key-checking accept-new --dry-run "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "0" ] && grep -qi 'accept-new' "$OUT"; then
    ok "accept-new refused on OpenSSH 7.4 (< 7.6)"
else
    bad "old OpenSSH accept-new" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra1_weird_ssh MOCK_SSH_VERSION="SomeOtherSSH 1.0" -- \
    "${PW[@]}" --ref "$C2" --strict-host-key-checking accept-new --dry-run "root@$HOST"
reject_local "accept-new refused when ssh -V is unparseable"
run_rb ra1_new_ssh MOCK_SSH_VERSION="OpenSSH_7.6p1 Ubuntu" -- \
    "${PW[@]}" --ref "$C2" --strict-host-key-checking accept-new --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(calls)" = "0" ] && has "accept-new"; then
    ok "accept-new allowed on OpenSSH 7.6"
else
    bad "OpenSSH 7.6 accept-new" "rc=$RC out=[$(tail_out)]"
fi

bad_ports_ok=1
bad_port_detail=""
i=0
for p in 0 65536 abc -1 "22 " "" 022 99999999999999999999; do
    i=$((i + 1))
    run_rb "ra1_port_$i" -- "${PW[@]}" --ref "$C2" -p "$p" "root@$HOST"
    if [ "$RC" -eq 0 ] || [ "$(calls)" != "0" ]; then
        bad_ports_ok=0
        bad_port_detail="${bad_port_detail} [$p rc=$RC]"
    fi
done
if [ "$bad_ports_ok" = "1" ]; then
    ok "invalid ports rejected (8 variants)"
else
    bad "bad ports" "$bad_port_detail"
fi

bad_cores_ok=1
for c in 0 257 x -3 ""; do
    run_rb ra1_cores -- "${PW[@]}" --ref "$C2" --max-phys-cores "$c" "root@$HOST"
    if [ "$RC" -eq 0 ] || [ "$(calls)" != "0" ]; then bad_cores_ok=0; fi
done
if [ "$bad_cores_ok" = "1" ]; then
    ok "invalid --max-phys-cores rejected (0, 257, x, -3, empty)"
else
    bad "bad --max-phys-cores" "last rc=$RC"
fi

run_rb ra1_unknown -- "${PW[@]}" --ref "$C2" --bogus-flag "root@$HOST"
reject_local "unknown option rejected"

run_rb ra1_kh_bad -- "${PW[@]}" --ref "$C2" --known-hosts-file "/tmp/a b" "root@$HOST"
reject_local "--known-hosts-file with whitespace rejected"

# Zero optional flags (bash 3.2 set -u empty-array safety): default identity ~/.ssh/id_ed25519
run_rb ra1_zero_flags -- --ref "$C2" --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(calls)" = "0" ] && has "$HOME/.ssh/id_ed25519" && has "$FP_HFT" \
   && ! grep -q 'unbound variable' "$OUT"; then
    ok "zero optional flags under set -u: defaults to ~/.ssh/id_ed25519(.pub)"
else
    bad "zero optional flags" "rc=$RC out=[$(tail_out)]"
fi

run_rb ra1_help -- --help
if [ "$RC" -eq 0 ] && has "Usage" && [ "$(calls)" = "0" ]; then
    ok "--help prints usage without connecting"
else
    bad "--help" "rc=$RC"
fi

# ==============================================================================
section "RA2: --dry-run summary (zero SSH calls)"
# ==============================================================================
run_rb ra2_dry -- --hft-identity "$K/hft" --pubkey "$K/hft.pub" --repo-url "$URL" --ref "$C2" \
    --max-phys-cores 2 --enable-idle-poll -p 2222 --dry-run "root@[::1]"
dry_ok=1
dry_miss=""
for needle in "$FP_HFT" "ssh-ed25519" "::1" "2222" "$C2" "$URL" "--max-phys-cores 2" "--enable-idle-poll" \
              "sh -s" "PUBKEY_B64=" "StrictHostKeyChecking=ask" "$K/hft"; do
    if ! has "$needle"; then dry_ok=0; dry_miss="$dry_miss [$needle]"; fi
done
if [ "$RC" -eq 0 ] && [ "$(calls)" = "0" ] && [ "$dry_ok" = "1" ] && ! has "[::1]"; then
    ok "--dry-run prints fingerprint, bare algos, normalized ::1, commit, pass-through, payload preview; 0 ssh calls"
else
    bad "--dry-run summary" "rc=$RC calls=$(calls) missing=$dry_miss"
fi

run_rb ra2_rsa -- --hft-identity "$K/rsa" --repo-url "$URL" --ref "$C2" --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && has "rsa-sha2-512,rsa-sha2-256" && has "$(fp_pub "$K/rsa.pub")"; then
    ok "RSA identity maps to rsa-sha2-512,rsa-sha2-256 (pubkey derived from --hft-identity)"
else
    bad "RSA algos" "rc=$RC out=[$(tail_out)]"
fi

run_rb ra2_ecdsa -- --hft-identity "$K/ecdsa" --repo-url "$URL" --ref "$C2" --dry-run "root@$HOST"
if [ "$RC" -eq 0 ] && has "ecdsa-sha2-nistp256"; then
    ok "ECDSA P-256 identity maps to ecdsa-sha2-nistp256"
else
    bad "ECDSA algos" "rc=$RC out=[$(tail_out)]"
fi

run_rb ra2_ec2_dry -- -i "$K/ec2login" --repo-url "$URL" --ref "$C2" --dry-run "ubuntu@$HOST"
if [ "$RC" -eq 0 ] && has "StrictHostKeyChecking=yes" && has "$FP_EC2" && [ "$(calls)" = "0" ]; then
    ok "--dry-run with -i shows StrictHostKeyChecking=yes and derived pubkey fingerprint"
else
    bad "EC2 dry-run" "rc=$RC out=[$(tail_out)]"
fi

# ==============================================================================
section "RA3: Step 1 pure-stream protocol against a real /bin/sh -s"
# ==============================================================================
run_rb ra3_main -- "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
RUN_DIR_SEEN="$(remote_run_dir)"
printf '%s\n' -F /dev/null -T -a -x -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no \
    -o ForwardX11=no -o ClearAllForwardings=yes -o ServerAliveInterval=15 -o StrictHostKeyChecking=ask \
    -p 22 -- "root@$HOST" "sh -s" > "$T/expected_call1"
if [ "$RC" -eq 0 ] && [ "$(calls)" = "2" ] && cmp -s "$T/expected_call1" "$M/call.1.args"; then
    ok "password mode: exactly 1 main (exact -F /dev/null -T -a -x ... 'sh -s') + 1 verify call"
else
    bad "main call argv" "rc=$RC calls=$(calls) out=[$(tail_out)] argv=[$(tr '\n' ' ' < "$M/call.1.args" 2>/dev/null)]"
fi
if cmp -s "$K/hft.pub" "$FAKE_RUNALL_DIR/runall.pubkey"; then
    ok "deployed pubkey byte-for-byte identical to --pubkey"
else
    bad "pubkey bytes" "deployed file differs or missing"
fi
if [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C2" ] && has "HFT_RESOLVED_COMMIT=$C2"; then
    ok "default branch 'main' resolved, approved and checked out at expected commit"
else
    bad "main resolution" "head=$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)"
fi
printf '%s\n' --ssh-key-source "$RUN_DIR_SEEN/authorized_key.pub" > "$T/expected_runall_args"
if [ -n "$RUN_DIR_SEEN" ] && cmp -s "$T/expected_runall_args" "$FAKE_RUNALL_DIR/runall.args"; then
    ok "run_all.sh invoked with only --ssh-key-source <RUN_DIR>/authorized_key.pub (zero optional flags)"
else
    bad "run_all args" "got=[$(tr '\n' ' ' < "$FAKE_RUNALL_DIR/runall.args" 2>/dev/null)]"
fi
if [ "$(cat "$FAKE_RUNALL_DIR/runall.stdin_bytes" 2>/dev/null)" = "0" ]; then
    ok "stdin-eating child (cat) sees 0 bytes: run_all.sh runs with </dev/null"
else
    bad "stdin isolation" "bytes=$(cat "$FAKE_RUNALL_DIR/runall.stdin_bytes" 2>/dev/null)"
fi
if [ -n "$RUN_DIR_SEEN" ] && [ ! -e "$RUN_DIR_SEEN" ] && [ "$(lines_of "$M/remote_rm.log")" = "1" ]; then
    ok "remote RUN_DIR cleaned exactly once on success"
else
    bad "success cleanup" "dir=$RUN_DIR_SEEN rm_lines=$(lines_of "$M/remote_rm.log")"
fi
if [ "$(tail -n 1 "$M/payload.1.sh" 2>/dev/null)" = "hft_rb_main" ] \
   && grep -q '^hft_rb_main() {' "$M/payload.1.sh" 2>/dev/null \
   && ! LC_ALL=C grep -q '[^[:print:][:space:]]' "$M/payload.1.sh" 2>/dev/null; then
    ok "payload is pure ASCII, wrapped in hft_rb_main() and invoked on the very last line"
else
    bad "payload structure" "last=[$(tail -n 1 "$M/payload.1.sh" 2>/dev/null)]"
fi
if [ ! -f "$M/remote_apt.log" ] && grep -qx -- '-n true' "$M/remote_sudo.log" 2>/dev/null; then
    ok "privilege probe 'sudo -n true' used; apt-get skipped when git + CA bundle present"
else
    bad "apt/sudo probe" "apt=$(cat "$M/remote_apt.log" 2>/dev/null) sudo=$(tr '\n' ';' < "$M/remote_sudo.log" 2>/dev/null)"
fi
if [ "$(cat "$M/call.2.dest" 2>/dev/null)" = "hft@$HOST" ] && has "verify_all.sh --live" \
   && has "--require-exchange-time" && has "01_startup/run_all.sh" && ! [ -f "$M/reboot.log" ]; then
    ok "Step 2 targets hft@host; next-step guide printed; no reboot without --reboot"
else
    bad "step2/guide" "dest=$(cat "$M/call.2.dest" 2>/dev/null)"
fi

# Corrupted base64 payload -> abort before git / apt-get / run_all.sh
run_rb ra3_corrupt MOCK_SSH_SED="s|^\\([[:space:]]*PUBKEY_B64=\\).*|\\1'@@corrupt@@'|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "1" ] && [ ! -f "$M/remote_git.log" ] && [ ! -f "$M/remote_apt.log" ] \
   && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "corrupted PUBKEY_B64 aborts before git/apt-get/run_all.sh and before Step 2"
else
    bad "corrupt base64" "rc=$RC calls=$(calls) git=$([ -f "$M/remote_git.log" ] && echo y)"
fi
run_rb ra3_corrupt2 MOCK_SSH_SED="s|^\\([[:space:]]*REPO_URL_B64=\\).*|\\1'abc'|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/remote_git.log" ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "truncated REPO_URL_B64 aborts before git"
else
    bad "corrupt repo url b64" "rc=$RC"
fi
run_rb ra3_remote_url MOCK_SSH_SED="s|^\\([[:space:]]*REPO_URL_B64=\\).*|\\1'$(b64 "http://example.com/x.git")'|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/remote_git.log" ]; then
    ok "remote re-validates repo URL scheme whitelist (http:// injected -> rejected before git)"
else
    bad "remote URL whitelist" "rc=$RC"
fi
run_rb ra3_remote_local_url MOCK_SSH_SED="s|^\\([[:space:]]*ALLOW_LOCAL_URL=\\).*|\\10|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/remote_git.log" ]; then
    ok "remote rejects file:// URL unless ALLOW_LOCAL_URL=1 was embedded"
else
    bad "remote local URL gate" "rc=$RC"
fi

# Port + IPv6 normalisation
run_rb ra3_ipv6 -- "${PW[@]}" --ref main --expected-commit "$C2" -p 2222 "root@[::1]"
if [ "$RC" -eq 0 ] && args_has_seq 1 -p 2222 && args_has_seq 2 -p 2222 \
   && [ "$(cat "$M/call.1.dest" 2>/dev/null)" = "root@::1" ] && [ "$(cat "$M/call.2.dest" 2>/dev/null)" = "hft@::1" ]; then
    ok "-p 2222 and [::1] -> ::1 used consistently for Step 1 and Step 2"
else
    bad "port/ipv6" "rc=$RC d1=$(cat "$M/call.1.dest" 2>/dev/null) d2=$(cat "$M/call.2.dest" 2>/dev/null)"
fi

run_rb ra3_kh -- "${PW[@]}" --ref main --expected-commit "$C2" --known-hosts-file "$T/kh" "root@$HOST"
if [ "$RC" -eq 0 ] && args_has_seq 1 -o "UserKnownHostsFile=$T/kh" && args_has_seq 2 -o "UserKnownHostsFile=$T/kh"; then
    ok "--known-hosts-file passed consistently to Step 1 and Step 2"
else
    bad "known hosts" "rc=$RC"
fi

# TERM mid-run
run_rb ra3_term FAKE_RUNALL_MODE=term -- "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
RUN_DIR_SEEN="$(remote_run_dir)"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "1" ] && [ -n "$RUN_DIR_SEEN" ] && [ ! -e "$RUN_DIR_SEEN" ] \
   && [ "$(lines_of "$M/remote_rm.log")" = "1" ] && ! has "Step 2"; then
    ok "TERM mid-run: non-zero exit (rc=$RC), single cleanup, no Step 2"
else
    bad "TERM handling" "rc=$RC calls=$(calls) dir=$RUN_DIR_SEEN rm_lines=$(lines_of "$M/remote_rm.log")"
fi

# OS / privilege fail-closed
for osf in os-release-2204 os-release-debian; do
    run_rb "ra3_$osf" HFT_RB_TEST_OS_RELEASE="$T/$osf" -- "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
    if [ "$RC" -ne 0 ] && [ ! -f "$M/remote_git.log" ] && [ ! -f "$M/remote_apt.log" ] \
       && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ] && [ "$(calls)" = "1" ]; then
        ok "non-Ubuntu-24.04 target ($osf) fail-closed before apt/git/run_all"
    else
        bad "OS gate $osf" "rc=$RC"
    fi
done
run_rb ra3_nosudo MOCK_SUDO_OK=0 -- "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/remote_git.log" ] && [ ! -f "$M/remote_apt.log" ] \
   && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "non-root without passwordless sudo fail-closed before apt/git/run_all"
else
    bad "no-sudo gate" "rc=$RC"
fi

# Missing CA bundle -> apt-get via sudo -n (non-root) / direct (root)
run_rb ra3_apt_sudo HFT_RB_TEST_CA_CERT="$T/missing-ca.crt" -- "${PW[@]}" --ref main --expected-commit "$C2" "ubuntu@$HOST"
if [ "$RC" -eq 0 ] && grep -q 'install -y --no-install-recommends git ca-certificates' "$M/remote_apt.log" 2>/dev/null \
   && grep -q 'apt-get' "$M/remote_sudo.log" 2>/dev/null; then
    ok "missing CA bundle: apt-get update/install git ca-certificates via sudo -n"
else
    bad "apt via sudo" "rc=$RC apt=[$(tr '\n' ';' < "$M/remote_apt.log" 2>/dev/null)]"
fi
run_rb ra3_apt_root MOCK_ID_U=0 MOCK_SUDO_OK=0 HFT_RB_TEST_CA_CERT="$T/missing-ca.crt" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -eq 0 ] && grep -q '^update' "$M/remote_apt.log" 2>/dev/null \
   && ! grep -q 'apt-get' "$M/remote_sudo.log" 2>/dev/null; then
    ok "root target: apt-get runs directly (no sudo) and Layer 1 proceeds"
else
    bad "apt as root" "rc=$RC out=[$(tail_out)]"
fi

# Ref resolution matrix against a real bare repo
run_rb ra3_heads_feat -- "${PW[@]}" --ref refs/heads/feat --expected-commit "$C3" "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C3" ]; then
    ok "refs/heads/feat resolved via refs/remotes/origin/feat"
else
    bad "refs/heads/feat" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_bare_feat -- "${PW[@]}" --ref feat --expected-commit "$C3" "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C3" ]; then
    ok "bare branch name 'feat' resolved"
else
    bad "bare feat" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_tag_name -- "${PW[@]}" --ref v1.0 --expected-commit "$C1" "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C1" ]; then
    ok "annotated tag name 'v1.0' peeled to its commit"
else
    bad "tag name" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_refs_tags -- "${PW[@]}" --ref refs/tags/v1.0 --expected-commit "$C1" "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C1" ]; then
    ok "refs/tags/v1.0 peeled to its commit"
else
    bad "refs/tags" "rc=$RC out=[$(tail_out)]"
fi
UPPER_C1="$(printf '%s' "$C1" | tr '[:lower:]' '[:upper:]')"
run_rb ra3_sha -- "${PW[@]}" --ref "$UPPER_C1" "root@$HOST"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_RUNALL_DIR/runall.head" 2>/dev/null)" = "$C1" ] && has "HFT_RESOLVED_COMMIT=$C1"; then
    ok "40-hex commit --ref (uppercase input) is its own approval and is lowercased"
else
    bad "sha ref" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_tag_obj -- "${PW[@]}" --ref "$TAG_OBJ" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ] && [ "$(calls)" = "1" ]; then
    ok "annotated tag OBJECT 40-hex rejected (cat-file -t != commit)"
else
    bad "tag object sha" "rc=$RC"
fi
run_rb ra3_remote_head MOCK_SSH_SED="s|^\\([[:space:]]*REF_B64=\\).*|\\1'$(b64 HEAD)'|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "remote rejects HEAD even if it reaches the payload"
else
    bad "remote HEAD" "rc=$RC"
fi
run_rb ra3_remote_ohead MOCK_SSH_SED="s|^\\([[:space:]]*REF_B64=\\).*|\\1'$(b64 origin/HEAD)'|" -- \
    "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "remote rejects origin/HEAD"
else
    bad "remote origin/HEAD" "rc=$RC"
fi
run_rb ra3_refs_other -- "${PW[@]}" --ref refs/remotes/origin/main --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "unsupported refs/* namespace rejected"
else
    bad "refs/remotes namespace" "rc=$RC"
fi
run_rb ra3_amb -- "${PW[@]}" --ref amb --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ] && grep -qi 'ambiguous' "$OUT"; then
    ok "bare name that is both tag and branch rejected as ambiguous"
else
    bad "ambiguous ref" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_missing -- "${PW[@]}" --ref nope --expected-commit "$C2" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "missing ref rejected"
else
    bad "missing ref" "rc=$RC"
fi
run_rb ra3_mismatch -- "${PW[@]}" --ref main --expected-commit "$C1" "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ] && [ "$(calls)" = "1" ] && grep -qi 'mismatch' "$OUT"; then
    ok "resolved commit != --expected-commit aborts before checkout/run_all.sh"
else
    bad "expected-commit mismatch" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_noopt -- "${PW[@]}" --ref noopt --expected-commit "$C4" --no-managed-irq "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "static contract: run_all.sh lacking --no-managed-irq rejected without executing it"
else
    bad "static missing option" "rc=$RC"
fi
run_rb ra3_noopt_ok -- "${PW[@]}" --ref noopt --expected-commit "$C4" --max-phys-cores 2 "root@$HOST"
if [ "$RC" -eq 0 ] && [ -f "$FAKE_RUNALL_DIR/runall.args" ]; then
    ok "static contract satisfied when only supported options are requested"
else
    bad "static contract ok" "rc=$RC out=[$(tail_out)]"
fi
run_rb ra3_passthrough -- "${PW[@]}" --ref main --expected-commit "$C2" --max-phys-cores 2 --enable-idle-poll \
    --no-managed-irq "root@$HOST"
RUN_DIR_SEEN="$(remote_run_dir)"
printf '%s\n' --ssh-key-source "$RUN_DIR_SEEN/authorized_key.pub" --max-phys-cores 2 --enable-idle-poll \
    --no-managed-irq > "$T/expected_pt"
if [ "$RC" -eq 0 ] && cmp -s "$T/expected_pt" "$FAKE_RUNALL_DIR/runall.args"; then
    ok "pass-through flags forwarded as pure data in order"
else
    bad "pass-through" "got=[$(tr '\n' ' ' < "$FAKE_RUNALL_DIR/runall.args" 2>/dev/null)]"
fi

# Exit-code preservation + cleanup on failure
run_rb ra3_fail FAKE_RUNALL_MODE=fail -- "${PW[@]}" --ref main --expected-commit "$C2" "root@$HOST"
RUN_DIR_SEEN="$(remote_run_dir)"
if [ "$RC" -eq 7 ] && [ "$(calls)" = "1" ] && [ -n "$RUN_DIR_SEEN" ] && [ ! -e "$RUN_DIR_SEEN" ] \
   && [ "$(lines_of "$M/remote_rm.log")" = "1" ]; then
    ok "Layer 1 failure: exit code 7 preserved end-to-end, single cleanup, no Step 2"
else
    bad "failure rc/cleanup" "rc=$RC calls=$(calls) rm_lines=$(lines_of "$M/remote_rm.log")"
fi

# ==============================================================================
section "RA4: EC2 Key Pair mode + independent bare-key hft verification"
# ==============================================================================
EC2ARGS=(-i "$K/ec2login" --repo-url "$URL" --ref main --expected-commit "$C2")
run_rb ra4_ec2 MOCK_HFT_FP="$FP_EC2" -- "${EC2ARGS[@]}" "ubuntu@$HOST"
printf '%s\n' -F /dev/null -T -a -x -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no \
    -o ForwardX11=no -o ClearAllForwardings=yes -o ServerAliveInterval=15 -o StrictHostKeyChecking=yes \
    -p 22 -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o CertificateFile=none \
    -i "$K/ec2login" -- "ubuntu@$HOST" "sh -s" > "$T/expected_ec2_call1"
printf '%s\n' -F /dev/null -T -a -x -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no \
    -o ForwardX11=no -o ClearAllForwardings=yes -o ServerAliveInterval=15 -o StrictHostKeyChecking=yes \
    -p 22 -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o CertificateFile=none \
    -o PubkeyAcceptedAlgorithms=ssh-ed25519 -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i "$K/ec2login" \
    -- "hft@$HOST" "sudo -n true && id -un" > "$T/expected_ec2_call2"
if [ "$RC" -eq 0 ] && cmp -s "$T/expected_ec2_call1" "$M/call.1.args"; then
    ok "EC2 -i: Step 1 uses StrictHostKeyChecking=yes + BatchMode/IdentitiesOnly/IdentityAgent=none/CertificateFile=none"
else
    bad "EC2 step1 argv" "rc=$RC argv=[$(tr '\n' ' ' < "$M/call.1.args" 2>/dev/null)] out=[$(tail_out)]"
fi
if cmp -s "$T/expected_ec2_call2" "$M/call.2.args"; then
    ok "Step 2 isolated bare-key options exact (-F /dev/null, IdentitiesOnly, IdentityAgent=none, CertificateFile=none, PubkeyAcceptedAlgorithms)"
else
    bad "EC2 step2 argv" "argv=[$(tr '\n' ' ' < "$M/call.2.args" 2>/dev/null)]"
fi
ssh-keygen -y -P "" -f "$K/ec2login" </dev/null > "$T/ec2_derived.pub" 2>/dev/null
if cmp -s "$T/ec2_derived.pub" "$FAKE_RUNALL_DIR/runall.pubkey"; then
    ok "EC2 -i without --pubkey deploys pubkey derived via ssh-keygen -y"
else
    bad "EC2 derived pubkey" "differs"
fi

run_rb ra4_bypass_agent MOCK_SERVER_ACCEPTS=agent_only -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "2" ] && [ ! -f "$M/reboot.log" ]; then
    ok "bypass 1: config/agent key would work but \$HFT_IDENTITY does not -> FAIL, no reboot"
else
    bad "agent bypass" "rc=$RC calls=$(calls)"
fi
run_rb ra4_bypass_cert MOCK_SERVER_ACCEPTS=cert_only -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "2" ] && [ ! -f "$M/reboot.log" ]; then
    ok "bypass 2: *-cert-v01 certificate would work but bare pubkey does not -> FAIL, no reboot"
else
    bad "cert bypass" "rc=$RC calls=$(calls)"
fi
run_rb ra4_wrong_user MOCK_VERIFY_STDOUT=root -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/reboot.log" ]; then
    ok "Step 2 stdout 'root' (not hft) -> FAIL, no reboot"
else
    bad "wrong user" "rc=$RC"
fi
run_rb ra4_extra_line MOCK_VERIFY_STDOUT="hft
extra" -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/reboot.log" ]; then
    ok "Step 2 stdout with extra lines -> FAIL, no reboot"
else
    bad "extra lines" "rc=$RC"
fi
run_rb ra4_rc1 MOCK_VERIFY_RC=1 -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ ! -f "$M/reboot.log" ]; then
    ok "Step 2 non-zero exit (sudo -n fails) -> FAIL, no reboot"
else
    bad "verify rc" "rc=$RC"
fi
run_rb ra4_step1_fail FAKE_RUNALL_MODE=fail -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
if [ "$RC" -ne 0 ] && [ "$(calls)" = "1" ] && [ ! -f "$M/reboot.log" ]; then
    ok "Step 1 failure never reaches Step 2 or reboot"
else
    bad "step1 fail reboot" "rc=$RC calls=$(calls)"
fi
run_rb ra4_reboot -- "${PW[@]}" --ref main --expected-commit "$C2" --reboot "root@$HOST"
sed '$d' "$M/call.2.args" > "$T/c2_opts" 2>/dev/null
sed '$d' "$M/call.3.args" > "$T/c3_opts" 2>/dev/null
if [ "$RC" -eq 0 ] && [ "$(calls)" = "3" ] && [ -f "$M/reboot.log" ] && cmp -s "$T/c2_opts" "$T/c3_opts" \
   && [ "$(cat "$M/call.3.cmd" 2>/dev/null)" = "sudo -n reboot" ] && has "$C2"; then
    ok "double pass + --reboot: 'sudo -n reboot' with identical isolated options; guide cites commit"
else
    bad "reboot" "rc=$RC calls=$(calls) out=[$(tail_out)]"
fi

# ==============================================================================
section "RA5: README.md clickable TOC integrity"
# ==============================================================================
if [ -f "$README" ]; then
    ( cd "$REPO" && find . -name '*.sh' -not -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort ) > "$T/sh_files"
    n_sh="$(lines_of "$T/sh_files")"
    grep -o '<a id="[^"]*"></a>' "$README" | sed 's/^<a id="//; s/"><\/a>$//' | LC_ALL=C sort > "$T/anchors"
    dup="$(uniq -d "$T/anchors" | tr '\n' ' ')"
    toc_ok=1
    toc_detail=""
    : > "$T/script_anchors"
    while IFS= read -r rel; do
        row="$(grep -F "\`$rel\`" "$README" | grep -F '](#script-' | head -n 1)"
        if [ -z "$row" ]; then
            toc_ok=0
            toc_detail="$toc_detail [no TOC row: $rel]"
            continue
        fi
        anc="$(printf '%s\n' "$row" | grep -o '](#script-[A-Za-z0-9_-]*)' | head -n 1 | sed 's/^](#//; s/)$//')"
        if ! grep -Fqx -- "$anc" "$T/anchors"; then
            toc_ok=0
            toc_detail="$toc_detail [undefined anchor $anc for $rel]"
        fi
        printf '%s\n' "$anc" >> "$T/script_anchors"
    done < "$T/sh_files"
    n_distinct="$(LC_ALL=C sort -u "$T/script_anchors" | wc -l | tr -d '[:space:]')"
    if [ "$n_sh" = "29" ] && [ "$toc_ok" = "1" ] && [ "$n_distinct" = "29" ]; then
        ok "all 29 .sh files listed in README TOC with distinct, defined #script-* anchors"
    else
        bad "README TOC coverage" "n_sh=$n_sh distinct=$n_distinct$toc_detail"
    fi
    if [ -z "$dup" ] && [ -s "$T/anchors" ] && grep -Fqx toc "$T/anchors"; then
        ok "all <a id> anchors unique (including #toc)"
    else
        bad "anchor uniqueness" "dups=[$dup]"
    fi
    grep -o '](#[^)]*)' "$README" | sed 's/^](#//; s/)$//' | LC_ALL=C sort -u > "$T/links"
    dangling=""
    while IFS= read -r l; do
        grep -Fqx -- "$l" "$T/anchors" || dangling="$dangling $l"
    done < "$T/links"
    if [ -s "$T/links" ] && [ -z "$dangling" ]; then
        ok "all internal [..](#..) links resolve ($(lines_of "$T/links") distinct targets, zero dangling)"
    else
        bad "dangling links" "[$dangling]"
    fi
else
    bad "README" "missing $README"
fi

echo ""
echo "Summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
