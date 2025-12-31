#!/bin/bash
set -euo pipefail

# =============================================================================
# SSL Libraries Build Script for HFT Systems
# Builds optimized: WolfSSL 5.8.4, OpenSSL 3.6, LibreSSL 4.2.1
# Target: Linux + Intel i9/XEON CPUs with AVX2, AES-NI, etc.
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Versions
WOLFSSL_VERSION="5.8.4"
OPENSSL_VERSION="3.6.0"
LIBRESSL_VERSION="4.2.1"

# Directories
PROJ_DIR="$HOME/Proj"
WOLFSSL_DIR="$PROJ_DIR/wolfssl"
OPENSSL_DIR="$PROJ_DIR/openssl"
LIBRESSL_DIR="$PROJ_DIR/libressl"

# Build parallelism
NPROC=$(nproc)

# Detect CPU microarchitecture for -march/-mtune
detect_march() {
    local cpu_model
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | tr -d ' ')

    # Check for specific Intel generations
    if grep -q "avx512" /proc/cpuinfo; then
        # Skylake-X, Ice Lake, Sapphire Rapids, etc.
        if grep -q "avx512vbmi2" /proc/cpuinfo; then
            echo "icelake-server"
        else
            echo "skylake-avx512"
        fi
    elif grep -q "avx2" /proc/cpuinfo; then
        # Haswell and later
        echo "haswell"
    elif grep -q "avx" /proc/cpuinfo; then
        echo "sandybridge"
    else
        echo "native"
    fi
}

MARCH=$(detect_march)
echo -e "${BLUE}Detected CPU microarchitecture: ${MARCH}${NC}"

# Common optimized CFLAGS for Intel i9/XEON
COMMON_CFLAGS="-O3 -march=${MARCH} -mtune=${MARCH} -maes -mpclmul -msha -mavx2 -mbmi -mbmi2 -mpopcnt"
# Add VAES/VPCLMULQDQ only if supported (Ice Lake+)
if grep -q "vaes" /proc/cpuinfo 2>/dev/null; then
    COMMON_CFLAGS="$COMMON_CFLAGS -mvaes -mvpclmulqdq"
fi
COMMON_CFLAGS="$COMMON_CFLAGS -flto=auto -fno-semantic-interposition -funroll-loops -fomit-frame-pointer -pipe -fno-plt"

COMMON_LDFLAGS="-Wl,-O1 -Wl,--as-needed"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking build dependencies..."
    local deps=(build-essential autoconf automake libtool git wget curl pkg-config)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! dpkg -s "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        log_info "Installing missing dependencies..."
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi

    log_success "All dependencies satisfied"
}

cleanup_build() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        log_info "Cleaning up existing directory: $dir"
        rm -rf "$dir"
    fi
}

# =============================================================================
# WolfSSL 5.8.4 Build
# =============================================================================

build_wolfssl() {
    log_info "=========================================="
    log_info "Building WolfSSL ${WOLFSSL_VERSION}"
    log_info "=========================================="

    local src_dir="$WOLFSSL_DIR/src"
    local install_dir="$WOLFSSL_DIR/install"

    # Cleanup and create directories
    cleanup_build "$WOLFSSL_DIR"
    mkdir -p "$src_dir" "$install_dir"

    cd "$src_dir"

    # Download WolfSSL
    log_info "Downloading WolfSSL ${WOLFSSL_VERSION}..."
    wget -q --show-progress "https://github.com/wolfSSL/wolfssl/archive/refs/tags/v${WOLFSSL_VERSION}-stable.tar.gz" -O wolfssl.tar.gz
    tar -xzf wolfssl.tar.gz --strip-components=1
    rm wolfssl.tar.gz

    # Run autogen if needed
    if [[ -f autogen.sh ]]; then
        log_info "Running autogen.sh..."
        ./autogen.sh
    fi

    # WolfSSL specific CFLAGS
    local WOLFSSL_CFLAGS="${COMMON_CFLAGS}"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DGCM_TABLE_4BIT"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DUSE_INTEL_SPEEDUP"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DWOLFSSL_AESNI_BY8"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DHAVE_INTEL_AVX1"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DHAVE_INTEL_AVX2"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DHAVE_INTEL_MULX"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DWOLFSSL_SP_X86_64_ASM"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DTFM_X86_64"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DTFM_SSE2"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DTFM_ECC384"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DTFM_ECC521"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DFP_ECC"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DHAVE_INTEL_RDSEED"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DWOLFSSL_SP_FAST_MODEXP"
    WOLFSSL_CFLAGS="$WOLFSSL_CFLAGS -DWOLFSSL_STATIC_MEMORY"

    log_info "Configuring WolfSSL..."
    log_info "CFLAGS: $WOLFSSL_CFLAGS"

    CFLAGS="$WOLFSSL_CFLAGS" \
    LDFLAGS="$COMMON_LDFLAGS" \
    ./configure \
        --prefix="$install_dir" \
        --enable-all-asm \
        --enable-intelasm \
        --enable-aesni \
        --enable-intelrand \
        --enable-sp \
        --enable-sp-asm \
        --enable-sp-math-all \
        --enable-fasthugemath \
        --enable-aesgcm \
        --enable-chacha \
        --enable-poly1305 \
        --enable-tls13 \
        --enable-singlethreaded \
        --enable-harden \
        --enable-curve25519 \
        --enable-ed25519 \
        --enable-curve448 \
        --enable-eccencrypt \
        --enable-fpecc \
        --enable-eccsi \
        --disable-shared \
        --enable-static

    log_info "Building WolfSSL (using $NPROC cores)..."
    make -j"$NPROC"

    log_info "Installing WolfSSL..."
    make install

    log_success "WolfSSL ${WOLFSSL_VERSION} installed to $install_dir"

    # Verify installation
    if [[ -f "$install_dir/lib/libwolfssl.a" ]]; then
        local lib_size
        lib_size=$(du -h "$install_dir/lib/libwolfssl.a" | cut -f1)
        log_success "Static library: $install_dir/lib/libwolfssl.a ($lib_size)"
    fi
}

# =============================================================================
# OpenSSL 3.6 Build
# =============================================================================

build_openssl() {
    log_info "=========================================="
    log_info "Building OpenSSL ${OPENSSL_VERSION}"
    log_info "=========================================="

    local src_dir="$OPENSSL_DIR/src"
    local install_dir="$OPENSSL_DIR/install"

    # Cleanup and create directories
    cleanup_build "$OPENSSL_DIR"
    mkdir -p "$src_dir" "$install_dir"

    cd "$src_dir"

    # Download OpenSSL
    log_info "Downloading OpenSSL ${OPENSSL_VERSION}..."
    wget -q --show-progress "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" -O openssl.tar.gz
    tar -xzf openssl.tar.gz --strip-components=1
    rm openssl.tar.gz

    # OpenSSL specific CFLAGS
    local OPENSSL_CFLAGS="${COMMON_CFLAGS}"

    log_info "Configuring OpenSSL..."
    log_info "CFLAGS: $OPENSSL_CFLAGS"

    CFLAGS="$OPENSSL_CFLAGS" \
    LDFLAGS="$COMMON_LDFLAGS" \
    ./Configure \
        --prefix="$install_dir" \
        --openssldir="$install_dir/ssl" \
        linux-x86_64 \
        enable-ec_nistp_64_gcc_128 \
        enable-ktls \
        enable-afalgeng \
        no-shared \
        no-tests

    log_info "Building OpenSSL (using $NPROC cores)..."
    make -j"$NPROC"

    log_info "Installing OpenSSL..."
    make install_sw install_ssldirs

    log_success "OpenSSL ${OPENSSL_VERSION} installed to $install_dir"

    # Verify installation
    if [[ -f "$install_dir/lib64/libssl.a" ]]; then
        local lib_size
        lib_size=$(du -h "$install_dir/lib64/libssl.a" | cut -f1)
        log_success "Static library: $install_dir/lib64/libssl.a ($lib_size)"
    elif [[ -f "$install_dir/lib/libssl.a" ]]; then
        local lib_size
        lib_size=$(du -h "$install_dir/lib/libssl.a" | cut -f1)
        log_success "Static library: $install_dir/lib/libssl.a ($lib_size)"
    fi

    # Show version
    if [[ -x "$install_dir/bin/openssl" ]]; then
        log_info "OpenSSL version:"
        "$install_dir/bin/openssl" version
    fi
}

# =============================================================================
# LibreSSL 4.2.1 Build
# =============================================================================

build_libressl() {
    log_info "=========================================="
    log_info "Building LibreSSL ${LIBRESSL_VERSION}"
    log_info "=========================================="

    local src_dir="$LIBRESSL_DIR/src"
    local install_dir="$LIBRESSL_DIR/install"

    # Cleanup and create directories
    cleanup_build "$LIBRESSL_DIR"
    mkdir -p "$src_dir" "$install_dir"

    cd "$src_dir"

    # Download LibreSSL
    log_info "Downloading LibreSSL ${LIBRESSL_VERSION}..."
    wget -q --show-progress "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL_VERSION}.tar.gz" -O libressl.tar.gz
    tar -xzf libressl.tar.gz --strip-components=1
    rm libressl.tar.gz

    # LibreSSL specific CFLAGS - add section gc flags
    local LIBRESSL_CFLAGS="${COMMON_CFLAGS} -ffunction-sections -fdata-sections"
    local LIBRESSL_LDFLAGS="${COMMON_LDFLAGS} -Wl,--gc-sections"

    log_info "Configuring LibreSSL..."
    log_info "CFLAGS: $LIBRESSL_CFLAGS"

    CFLAGS="$LIBRESSL_CFLAGS" \
    LDFLAGS="$LIBRESSL_LDFLAGS" \
    ./configure \
        --prefix="$install_dir" \
        --disable-shared \
        --enable-static \
        --disable-hardening \
        --disable-tests

    log_info "Building LibreSSL (using $NPROC cores)..."
    make -j"$NPROC"

    log_info "Installing LibreSSL..."
    make install

    log_success "LibreSSL ${LIBRESSL_VERSION} installed to $install_dir"

    # Verify installation
    if [[ -f "$install_dir/lib/libssl.a" ]]; then
        local lib_size
        lib_size=$(du -h "$install_dir/lib/libssl.a" | cut -f1)
        log_success "Static library: $install_dir/lib/libssl.a ($lib_size)"
    fi

    # Show version
    if [[ -x "$install_dir/bin/openssl" ]]; then
        log_info "LibreSSL version:"
        "$install_dir/bin/openssl" version
    fi
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "SSL Libraries Build Complete"
    echo -e "==========================================${NC}"
    echo ""
    echo -e "${BLUE}WolfSSL ${WOLFSSL_VERSION}:${NC}"
    echo "  Install: $WOLFSSL_DIR/install"
    echo "  Headers: $WOLFSSL_DIR/install/include"
    echo "  Library: $WOLFSSL_DIR/install/lib/libwolfssl.a"
    echo "  Pkg-config: PKG_CONFIG_PATH=$WOLFSSL_DIR/install/lib/pkgconfig"
    echo ""
    echo -e "${BLUE}OpenSSL ${OPENSSL_VERSION}:${NC}"
    echo "  Install: $OPENSSL_DIR/install"
    echo "  Headers: $OPENSSL_DIR/install/include"
    echo "  Library: $OPENSSL_DIR/install/lib64/libssl.a (or lib/)"
    echo "  Binary:  $OPENSSL_DIR/install/bin/openssl"
    echo ""
    echo -e "${BLUE}LibreSSL ${LIBRESSL_VERSION}:${NC}"
    echo "  Install: $LIBRESSL_DIR/install"
    echo "  Headers: $LIBRESSL_DIR/install/include"
    echo "  Library: $LIBRESSL_DIR/install/lib/libssl.a"
    echo "  Binary:  $LIBRESSL_DIR/install/bin/openssl"
    echo ""
    echo -e "${YELLOW}Usage in CMake:${NC}"
    echo "  set(WOLFSSL_ROOT \$ENV{HOME}/Proj/wolfssl/install)"
    echo "  set(OPENSSL_ROOT_DIR \$ENV{HOME}/Proj/openssl/install)"
    echo "  set(LIBRESSL_ROOT \$ENV{HOME}/Proj/libressl/install)"
    echo ""
    echo -e "${YELLOW}CPU Optimization:${NC}"
    echo "  Architecture: ${MARCH}"
    echo "  CFLAGS: ${COMMON_CFLAGS}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${BLUE}=========================================="
    echo -e "HFT SSL Libraries Build Script"
    echo -e "==========================================${NC}"
    echo ""
    echo "Versions:"
    echo "  WolfSSL:  ${WOLFSSL_VERSION}"
    echo "  OpenSSL:  ${OPENSSL_VERSION}"
    echo "  LibreSSL: ${LIBRESSL_VERSION}"
    echo ""
    echo "Target directories:"
    echo "  WolfSSL:  ${WOLFSSL_DIR}"
    echo "  OpenSSL:  ${OPENSSL_DIR}"
    echo "  LibreSSL: ${LIBRESSL_DIR}"
    echo ""

    # Check dependencies
    check_dependencies

    # Create project directory if needed
    mkdir -p "$PROJ_DIR"

    # Build all libraries
    build_wolfssl
    echo ""

    build_openssl
    echo ""

    build_libressl
    echo ""

    # Print summary
    print_summary
}

# Allow building individual libraries
case "${1:-all}" in
    wolfssl)
        check_dependencies
        build_wolfssl
        ;;
    openssl)
        check_dependencies
        build_openssl
        ;;
    libressl)
        check_dependencies
        build_libressl
        ;;
    all)
        main
        ;;
    *)
        echo "Usage: $0 [wolfssl|openssl|libressl|all]"
        echo "  wolfssl  - Build only WolfSSL ${WOLFSSL_VERSION}"
        echo "  openssl  - Build only OpenSSL ${OPENSSL_VERSION}"
        echo "  libressl - Build only LibreSSL ${LIBRESSL_VERSION}"
        echo "  all      - Build all libraries (default)"
        exit 1
        ;;
esac
