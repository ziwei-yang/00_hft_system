#!/usr/bin/env bash
# Layer 2 Step 03: Build static TLS libraries (WolfSSL 5.8.4, OpenSSL 3.6.0, LibreSSL 4.2.1).
# - Strictly zero sudo, non-root.
# - SHA-256 verified downloads, portable -O3 -march=native -mtune=native -pipe.
# - Per-library flock locking, isolated mktemp staging, zero *.so* assertion,
#   C++ static compile/link probe, manifest tracking, crash-safe legacy migration,
#   and atomic symlink swap (install -> releases/<ver>-<hash>).
set -euo pipefail

export HFT_NO_SUDO=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_bash43
require_ubuntu
require_not_root

# Verified official release versions and SHA-256 digests
WOLFSSL_VERSION="5.8.4"
WOLFSSL_SHA256="2b702b7a66b0067bfd284408827b1e59288b357b0dd758d0089c062395f2a522"
WOLFSSL_URL="https://github.com/wolfSSL/wolfssl/archive/refs/tags/v${WOLFSSL_VERSION}-stable.tar.gz"

OPENSSL_VERSION="3.6.0"
OPENSSL_SHA256="b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

LIBRESSL_VERSION="4.2.1"
LIBRESSL_SHA256="6d5c2f58583588ea791f4c8645004071d00dfa554a5bf788a006ca1eb5abd70b"
LIBRESSL_URL="https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz"

COMMON_CFLAGS="-O3 -march=native -mtune=native -pipe"
COMMON_LDFLAGS="-Wl,-O1 -Wl,--as-needed"
PROJ_DIR="${HOME}/Proj"
NPROC="${HFT_BUILD_NPROC:-$(nproc 2>/dev/null || echo 2)}"

usage() {
    cat <<EOF
Usage: 03_build_tls_libs.sh [wolfssl|openssl|libressl|all]

Builds static-only TLS libraries under ~/Proj/<lib>/releases/<ver>-<hash>
and atomically swaps ~/Proj/<lib>/install symlink. Strictly zero sudo.
EOF
}

TARGET="${1:-all}"
case "$TARGET" in
    wolfssl|openssl|libressl|all) ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown target '$TARGET' (expected wolfssl|openssl|libressl|all)" ;;
esac

banner "Layer 2 Step 03: Static TLS Library Builder (target=${TARGET})"

# Prerequisites: Layer 1 --live + Layer 2 Steps 01 & 02
if [[ "${HFT_SKIP_PREREQS:-0}" != "1" ]]; then
    bash "${SCRIPT_DIR}/../00_sudo_script/verify_all.sh" --live
    run_verify_chain "${SCRIPT_DIR}/verify_01_user_workspace.sh" "${SCRIPT_DIR}/verify_02_git_ssh_base.sh"
fi

safe_rm_user_file() {
    local target="$1"
    if [[ -z "$target" || "$target" == "/" || "$target" == *"/.."* || "$target" == *"../"* ]]; then
        die "Refusing unsafe user file removal: '$target'"
    fi
    case "$target" in
        /tmp/*)   rm -f /tmp/"${target#/tmp/}" ;;
        /home/*)  rm -f /home/"${target#/home/}" ;;
        /Users/*) rm -f /Users/"${target#/Users/}" ;;
        *)        die "Refusing removal outside /tmp, /home, /Users: '$target'" ;;
    esac
}

safe_rm_user_dir() {
    local target="$1"
    if [[ -z "$target" || "$target" == "/" || "$target" == *"/.."* || "$target" == *"../"* ]]; then
        die "Refusing unsafe user dir removal: '$target'"
    fi
    case "$target" in
        /tmp/*)   rm -rf /tmp/"${target#/tmp/}" ;;
        /home/*)  rm -rf /home/"${target#/home/}" ;;
        /Users/*) rm -rf /Users/"${target#/Users/}" ;;
        *)        die "Refusing dir removal outside /tmp, /home, /Users: '$target'" ;;
    esac
}

sha256_str() {
    if command -v "$HFT_SHA256SUM_CMD" >/dev/null 2>&1; then
        printf '%s' "$1" | "$HFT_SHA256SUM_CMD" | awk '{print $1}'
    else
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    fi
}

lib_meta() {
    local lib="$1"
    case "$lib" in
        wolfssl)
            LIB_VER="$WOLFSSL_VERSION"
            LIB_SHA="$WOLFSSL_SHA256"
            LIB_URL="$WOLFSSL_URL"
            LIB_CFG_FLAGS="--disable-shared --enable-static --enable-tls13 --enable-aesgcm --enable-chacha --enable-poly1305 --enable-curve25519 --enable-ed25519 --enable-sp --enable-sp-math-all --enable-harden"
            LIB_STATIC_FILES="lib/libwolfssl.a"
            ;;
        openssl)
            LIB_VER="$OPENSSL_VERSION"
            LIB_SHA="$OPENSSL_SHA256"
            LIB_URL="$OPENSSL_URL"
            LIB_CFG_FLAGS="linux-x86_64 no-shared --libdir=lib64 enable-ec_nistp_64_gcc_128 enable-ktls no-tests"
            LIB_STATIC_FILES="lib64/libssl.a lib64/libcrypto.a"
            ;;
        libressl)
            LIB_VER="$LIBRESSL_VERSION"
            LIB_SHA="$LIBRESSL_SHA256"
            LIB_URL="$LIBRESSL_URL"
            LIB_CFG_FLAGS="--disable-shared --enable-static --disable-tests"
            LIB_STATIC_FILES="lib/libssl.a lib/libcrypto.a"
            ;;
        *) die "Unknown lib: $lib" ;;
    esac
    local full_hash
    full_hash="$(sha256_str "${lib}|${LIB_VER}|${LIB_SHA}|${COMMON_CFLAGS}|${LIB_CFG_FLAGS}")"
    LIB_HASH="${full_hash:0:16}"
    LIB_REL_NAME="${LIB_VER}-${LIB_HASH}"
}

emit_expected_manifest() {
    cat <<EOF
lib=${1}
version=${LIB_VER}
tarball_sha256=${LIB_SHA}
cflags=${COMMON_CFLAGS}
configure_flags=${LIB_CFG_FLAGS}
build_hash=${LIB_HASH}
static_libs=${LIB_STATIC_FILES}
EOF
}

run_cxx_static_probe() {
    local lib="$1"
    local prefix="$2"

    if [[ -n "${HFT_TLS_TEST_PROBE:-}" ]]; then
        "$HFT_TLS_TEST_PROBE" "$lib" "$prefix"
        return $?
    fi

    case "$lib" in
        wolfssl)
            printf '#include <wolfssl/options.h>\n#include <wolfssl/ssl.h>\nint main(){ return wolfSSL_Init() == WOLFSSL_SUCCESS ? 0 : 1; }\n' | \
                "$HFT_CXX_CMD" -x c++ - -I"${prefix}/include" "${prefix}/lib/libwolfssl.a" -lpthread -o /dev/null
            ;;
        openssl)
            printf '#include <openssl/ssl.h>\nint main(){ const SSL_METHOD* m = TLS_client_method(); return m ? 0 : 1; }\n' | \
                "$HFT_CXX_CMD" -x c++ - -I"${prefix}/include" "${prefix}/lib64/libssl.a" "${prefix}/lib64/libcrypto.a" -lpthread -ldl -o /dev/null
            ;;
        libressl)
            printf '#include <openssl/ssl.h>\nint main(){ const SSL_METHOD* m = TLS_client_method(); return m ? 0 : 1; }\n' | \
                "$HFT_CXX_CMD" -x c++ - -I"${prefix}/include" "${prefix}/lib/libssl.a" "${prefix}/lib/libcrypto.a" -lpthread -o /dev/null
            ;;
    esac
}

fetch_and_verify_tarball() {
    local lib="$1"
    local url="$2"
    local expected_sha="$3"
    local dest="$4"

    # Allow offline test tarball injection
    local upper_lib
    upper_lib="$(printf '%s' "$lib" | tr '[:lower:]' '[:upper:]')"
    local env_var="HFT_TLS_TARBALL_${upper_lib}"
    local injected="${!env_var:-}"

    if [[ -n "$injected" ]]; then
        [[ -r "$injected" ]] || die "Injected tarball not readable: $injected"
        cp "$injected" "$dest"
    elif [[ -n "${HFT_TLS_CACHE_DIR:-}" && -r "${HFT_TLS_CACHE_DIR}/${lib}-${LIB_VER}.tar.gz" ]]; then
        cp "${HFT_TLS_CACHE_DIR}/${lib}-${LIB_VER}.tar.gz" "$dest"
    else
        log_info "Downloading ${lib} ${LIB_VER} from ${url}..."
        "$HFT_CURL_CMD" -fsSL --retry 3 "$url" -o "$dest"
    fi

    local actual_sha
    actual_sha="$(sha256_file "$dest")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        die "SHA-256 mismatch for ${lib} ${LIB_VER}: expected=${expected_sha}, actual=${actual_sha} (refusing corrupted tarball)"
    fi
    log_info "SHA-256 verified for ${lib} ${LIB_VER}: ${actual_sha}"
}

build_one_lib() {
    local lib="$1"
    lib_meta "$lib"

    local lib_dir="${PROJ_DIR}/${lib}"
    local rel_root="${lib_dir}/releases"
    local rel_target="${rel_root}/${LIB_REL_NAME}"
    local install_link="${lib_dir}/install"
    local mig_state="${lib_dir}/.install_migration.state"
    local lock_file="${lib_dir}/.build.lock"

    mkdir -p "$lib_dir" "$rel_root"

    # Acquire per-library exclusive lock (flock)
    local lock_fd
    exec {lock_fd}>"$lock_file"
    if [[ "${HFT_TLS_FLOCK_NONBLOCK:-0}" == "1" ]]; then
        if ! "$HFT_FLOCK_CMD" -n "$lock_fd"; then
            exec {lock_fd}>&-
            die "Lock busy for ${lib}: $lock_file"
        fi
    else
        "$HFT_FLOCK_CMD" -x "$lock_fd"
    fi

    # Inner subshell / cleanup handler ensures lock is released and /tmp staging removed
    local rc=0
    (
        set -euo pipefail

        # 1. Recover any previously interrupted legacy directory migration
        if [[ -f "$mig_state" ]]; then
            log_warn "Detected interrupted legacy migration state for ${lib}: ${mig_state}"
            local old_backup old_target
            old_backup="$(awk -F= '$1=="legacy_backup"{print $2; exit}' "$mig_state")"
            old_target="$(awk -F= '$1=="target"{print $2; exit}' "$mig_state")"
            if [[ -L "$install_link" ]]; then
                # Symlink swap had already succeeded before crash; clean state file
                safe_rm_user_file "$mig_state"
            elif [[ -d "$install_link" && ! -L "$install_link" ]]; then
                # Crash happened BEFORE moving legacy install dir; complete backup move now
                if [[ -n "$old_backup" && ! -e "${lib_dir}/${old_backup}" ]]; then
                    mv "$install_link" "${lib_dir}/${old_backup}"
                fi
                if [[ -n "$old_target" && -d "${lib_dir}/${old_target}" ]]; then
                    ln -sfn "$old_target" "${lib_dir}/install.next.$$"
                    mv -Tf "${lib_dir}/install.next.$$" "$install_link"
                    safe_rm_user_file "$mig_state"
                fi
            elif [[ ! -e "$install_link" ]]; then
                # Crash happened AFTER moving legacy install dir, BEFORE symlink swap
                if [[ -n "$old_target" && -d "${lib_dir}/${old_target}" ]]; then
                    ln -sfn "$old_target" "${lib_dir}/install.next.$$"
                    mv -Tf "${lib_dir}/install.next.$$" "$install_link"
                    safe_rm_user_file "$mig_state"
                elif [[ -n "$old_backup" && -d "${lib_dir}/${old_backup}" ]]; then
                    # Restore legacy dir if target release doesn't exist yet; will migrate cleanly below
                    mv "${lib_dir}/${old_backup}" "$install_link"
                    safe_rm_user_file "$mig_state"
                else
                    safe_rm_user_file "$mig_state"
                fi
            fi
        fi

        # 2. Idempotent skip if install symlink, manifest, static libs, and zero .so all match
        if [[ -L "$install_link" && ! -f "$mig_state" ]]; then
            local cur_target
            cur_target="$(readlink "$install_link")"
            if [[ "$cur_target" == "releases/${LIB_REL_NAME}" && -f "${install_link}/.hft_tls_manifest" ]]; then
                if diff -q <(emit_expected_manifest "$lib") "${install_link}/.hft_tls_manifest" >/dev/null 2>&1; then
                    local all_static=1 sf
                    for sf in $LIB_STATIC_FILES; do
                        [[ -f "${install_link}/${sf}" ]] || all_static=0
                    done
                    local so_cnt
                    so_cnt="$(find "${install_link}/" -name '*.so*' 2>/dev/null | wc -l | tr -d '[:space:]')"
                    if (( all_static == 1 && so_cnt == 0 )); then
                        log_success "${lib} ${LIB_VER} (${LIB_HASH}) already built and verified — skipping."
                        exit 0
                    fi
                fi
            fi
        fi

        # 3. Isolated staging directory under /tmp
        STAGE_TMP_CUR="$(mktemp -d "/tmp/hft_tls_${lib}.XXXXXX")"
        trap '[[ -n "${STAGE_TMP_CUR:-}" && -d "$STAGE_TMP_CUR" ]] && safe_rm_tmp "$STAGE_TMP_CUR"' EXIT

        local tarball="${STAGE_TMP_CUR}/${lib}-${LIB_VER}.tar.gz"
        local src_dir="${STAGE_TMP_CUR}/src"
        local stage_prefix="${STAGE_TMP_CUR}/prefix"
        mkdir -p "$src_dir" "$stage_prefix"

        fetch_and_verify_tarball "$lib" "$LIB_URL" "$LIB_SHA" "$tarball"

        # 4. Build into isolated staging prefix
        if [[ -n "${HFT_TLS_TEST_BUILDER:-}" ]]; then
            "$HFT_TLS_TEST_BUILDER" "$lib" "$LIB_VER" "$tarball" "$stage_prefix" "$COMMON_CFLAGS" "$LIB_CFG_FLAGS"
        else
            tar -xzf "$tarball" -C "$src_dir" --strip-components=1
            case "$lib" in
                wolfssl)
                    (
                        cd "$src_dir"
                        [[ -f autogen.sh ]] && ./autogen.sh
                        CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
                            ./configure --prefix="$stage_prefix" $LIB_CFG_FLAGS
                        make -j"$NPROC"
                        make install
                    )
                    ;;
                openssl)
                    (
                        cd "$src_dir"
                        CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
                            ./Configure --prefix="$stage_prefix" --openssldir="${stage_prefix}/ssl" $LIB_CFG_FLAGS
                        make -j"$NPROC"
                        make install_sw install_ssldirs
                    )
                    ;;
                libressl)
                    (
                        cd "$src_dir"
                        CFLAGS="${COMMON_CFLAGS} -ffunction-sections -fdata-sections" \
                        LDFLAGS="${COMMON_LDFLAGS} -Wl,--gc-sections" \
                            ./configure --prefix="$stage_prefix" $LIB_CFG_FLAGS
                        make -j"$NPROC"
                        make install
                    )
                    ;;
            esac
        fi

        # 5. Assert ZERO *.so* files in staging prefix (fail-closed)
        local found_so
        found_so="$(find "$stage_prefix" -name '*.so*' 2>/dev/null || true)"
        if [[ -n "$found_so" ]]; then
            die "Shared library contamination detected in ${lib} staging prefix: ${found_so}"
        fi

        # 6. Assert required static archives exist
        local sf
        for sf in $LIB_STATIC_FILES; do
            [[ -f "${stage_prefix}/${sf}" ]] || die "Missing expected static library ${stage_prefix}/${sf}"
        done

        # 7. Run library-level C++ static compile + link probe
        log_info "Running C++ static compile/link probe for ${lib}..."
        if ! run_cxx_static_probe "$lib" "$stage_prefix"; then
            die "C++ static compile/link probe failed for ${lib} in staging prefix"
        fi

        # 8. Write complete manifest into staging prefix
        emit_expected_manifest "$lib" > "${stage_prefix}/.hft_tls_manifest"

        # 9. Atomically place release under ~/Proj/<lib>/releases/<ver>-<hash>
        local rel_stage="${rel_root}/.staging-${LIB_REL_NAME}.$$"
        cp -a "$stage_prefix" "$rel_stage"
        if [[ -d "$rel_target" ]]; then
            local old_rel="${rel_root}/.replaced-${LIB_REL_NAME}.$$"
            mv "$rel_target" "$old_rel"
            mv -T "$rel_stage" "$rel_target"
            safe_rm_user_dir "$old_rel"
        else
            mv -T "$rel_stage" "$rel_target"
        fi

        # 10. Crash-safe legacy directory migration if install is a real directory
        if [[ -d "$install_link" && ! -L "$install_link" ]]; then
            local ts legacy_name
            ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "$$")"
            legacy_name="install.legacy.${ts}"
            cat > "$mig_state" <<MIG
legacy_backup=${legacy_name}
target=releases/${LIB_REL_NAME}
MIG
            mv "$install_link" "${lib_dir}/${legacy_name}"
            if [[ "${HFT_TLS_SIMULATE_CRASH_AFTER_MIGRATION_MV:-0}" == "1" ]]; then
                log_warn "Simulating crash after legacy install move (test hook)."
                exit 99
            fi
        fi

        # 11. Atomic symlink swap: ln -sfn + mv -Tf
        local next_link="${lib_dir}/install.next.$$"
        ln -sfn "releases/${LIB_REL_NAME}" "$next_link"
        mv -Tf "$next_link" "$install_link"

        if [[ -f "$mig_state" ]]; then
            safe_rm_user_file "$mig_state"
        fi

        log_success "Installed ${lib} ${LIB_VER} -> ${install_link} (releases/${LIB_REL_NAME})"
    ) || rc=$?

    "$HFT_FLOCK_CMD" -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-
    return "$rc"
}

case "$TARGET" in
    wolfssl)  build_one_lib wolfssl ;;
    openssl)  build_one_lib openssl ;;
    libressl) build_one_lib libressl ;;
    all)
        build_one_lib wolfssl
        build_one_lib openssl
        build_one_lib libressl
        ;;
esac

# Self-verify
bash "${SCRIPT_DIR}/verify_03_build_tls_libs.sh" "$TARGET"
log_success "Layer 2 Step 03 complete (target=${TARGET})."
