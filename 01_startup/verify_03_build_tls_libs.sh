#!/usr/bin/env bash
# Pure read-only verifier for Layer 2 Step 03 (static TLS libraries).
# Strictly zero sudo, non-root, NEVER writes any file.
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

WOLFSSL_VERSION="5.8.4"
WOLFSSL_SHA256="2b702b7a66b0067bfd284408827b1e59288b357b0dd758d0089c062395f2a522"
OPENSSL_VERSION="3.6.0"
OPENSSL_SHA256="b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9"
LIBRESSL_VERSION="4.2.1"
LIBRESSL_SHA256="6d5c2f58583588ea791f4c8645004071d00dfa554a5bf788a006ca1eb5abd70b"

COMMON_CFLAGS="-O3 -march=native -mtune=native -pipe"
PROJ_DIR="${HOME}/Proj"

TARGET="${1:-all}"
case "$TARGET" in
    wolfssl|openssl|libressl|all) ;;
    -h|--help)
        echo "Usage: verify_03_build_tls_libs.sh [wolfssl|openssl|libressl|all]"
        exit 0
        ;;
    *) die "Unknown target '$TARGET'" ;;
esac

FAIL=0
fail_check() { log_error "FAIL: $*"; FAIL=$((FAIL + 1)); }
pass_check() { log_ok "PASS: $*"; }

sha256_str() {
    if command -v "$HFT_SHA256SUM_CMD" >/dev/null 2>&1; then
        printf '%s' "$1" | "$HFT_SHA256SUM_CMD" | awk '{print $1}'
    else
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    fi
}

verify_one_lib() {
    local lib="$1"
    local ver sha cfg_flags static_files
    case "$lib" in
        wolfssl)
            ver="$WOLFSSL_VERSION"
            sha="$WOLFSSL_SHA256"
            cfg_flags="--disable-shared --enable-static --enable-tls13 --enable-aesgcm --enable-chacha --enable-poly1305 --enable-curve25519 --enable-ed25519 --enable-sp --enable-sp-math-all --enable-harden"
            static_files="lib/libwolfssl.a"
            ;;
        openssl)
            ver="$OPENSSL_VERSION"
            sha="$OPENSSL_SHA256"
            cfg_flags="linux-x86_64 no-shared --libdir=lib64 enable-ec_nistp_64_gcc_128 enable-ktls no-tests"
            static_files="lib64/libssl.a lib64/libcrypto.a"
            ;;
        libressl)
            ver="$LIBRESSL_VERSION"
            sha="$LIBRESSL_SHA256"
            cfg_flags="--disable-shared --enable-static --disable-tests"
            static_files="lib/libssl.a lib/libcrypto.a"
            ;;
    esac

    local full_hash hash rel_name
    full_hash="$(sha256_str "${lib}|${ver}|${sha}|${COMMON_CFLAGS}|${cfg_flags}")"
    hash="${full_hash:0:16}"
    rel_name="${ver}-${hash}"

    local lib_dir="${PROJ_DIR}/${lib}"
    local install_link="${lib_dir}/install"
    local mig_state="${lib_dir}/.install_migration.state"

    if [[ -f "$mig_state" ]]; then
        fail_check "${lib}: unfinished legacy migration state present ($mig_state)"
    fi

    if [[ -L "$install_link" ]]; then
        local target
        target="$(readlink "$install_link")"
        if [[ "$target" == "releases/${rel_name}" ]]; then
            pass_check "${lib}: install symlink points to releases/${rel_name}"
        else
            fail_check "${lib}: install symlink points to '${target}' (expected releases/${rel_name})"
        fi
    else
        fail_check "${lib}: $install_link is missing or not a symlink"
        return 0
    fi

    local manifest="${install_link}/.hft_tls_manifest"
    local expected_manifest
    expected_manifest="$(cat <<EOF
lib=${lib}
version=${ver}
tarball_sha256=${sha}
cflags=${COMMON_CFLAGS}
configure_flags=${cfg_flags}
build_hash=${hash}
static_libs=${static_files}
EOF
)"
    if [[ -r "$manifest" ]] && diff -q <(printf '%s\n' "$expected_manifest") "$manifest" >/dev/null 2>&1; then
        pass_check "${lib}: manifest verified"
    else
        fail_check "${lib}: manifest missing or mismatched ($manifest)"
    fi

    local sf
    for sf in $static_files; do
        if [[ -f "${install_link}/${sf}" ]]; then
            pass_check "${lib}: static archive present (${sf})"
        else
            fail_check "${lib}: missing static archive ${install_link}/${sf}"
        fi
    done

    local found_so
    found_so="$(find "${install_link}/" -name '*.so*' 2>/dev/null || true)"
    if [[ -z "$found_so" ]]; then
        pass_check "${lib}: zero *.so* shared libraries under install/"
    else
        fail_check "${lib}: unexpected *.so* found: ${found_so}"
    fi

    # Pure read-only C++ static compile/link probe (-o /dev/null)
    local probe_rc=0
    if [[ -n "${HFT_TLS_TEST_PROBE:-}" ]]; then
        "$HFT_TLS_TEST_PROBE" "$lib" "$install_link" || probe_rc=$?
    else
        case "$lib" in
            wolfssl)
                printf '#include <wolfssl/options.h>\n#include <wolfssl/ssl.h>\nint main(){ return wolfSSL_Init() == WOLFSSL_SUCCESS ? 0 : 1; }\n' | \
                    "$HFT_CXX_CMD" -x c++ - -I"${install_link}/include" "${install_link}/lib/libwolfssl.a" -lpthread -o /dev/null 2>/dev/null || probe_rc=$?
                ;;
            openssl)
                printf '#include <openssl/ssl.h>\nint main(){ const SSL_METHOD* m = TLS_client_method(); return m ? 0 : 1; }\n' | \
                    "$HFT_CXX_CMD" -x c++ - -I"${install_link}/include" "${install_link}/lib64/libssl.a" "${install_link}/lib64/libcrypto.a" -lpthread -ldl -o /dev/null 2>/dev/null || probe_rc=$?
                ;;
            libressl)
                printf '#include <openssl/ssl.h>\nint main(){ const SSL_METHOD* m = TLS_client_method(); return m ? 0 : 1; }\n' | \
                    "$HFT_CXX_CMD" -x c++ - -I"${install_link}/include" "${install_link}/lib/libssl.a" "${install_link}/lib/libcrypto.a" -lpthread -o /dev/null 2>/dev/null || probe_rc=$?
                ;;
        esac
    fi
    if (( probe_rc == 0 )); then
        pass_check "${lib}: C++ static compile/link probe passed"
    else
        fail_check "${lib}: C++ static compile/link probe failed"
    fi
}

case "$TARGET" in
    wolfssl)  verify_one_lib wolfssl ;;
    openssl)  verify_one_lib openssl ;;
    libressl) verify_one_lib libressl ;;
    all)
        verify_one_lib wolfssl
        verify_one_lib openssl
        verify_one_lib libressl
        ;;
esac

if (( FAIL > 0 )); then
    log_error "verify_03_build_tls_libs (${TARGET}): ${FAIL} check(s) failed."
    exit 1
fi
log_success "verify_03_build_tls_libs (${TARGET}): ALL CHECKS PASSED."
