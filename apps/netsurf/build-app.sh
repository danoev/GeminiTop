#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"
BUILD_DIR="$APP_DIR/build"
SRC_DIR="$BUILD_DIR/src"
PREFIX_DIR="$BUILD_DIR/prefix"
APP_OUT_DIR="$BUILD_DIR/app"
HOST="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.3.1"
CURL_VERSION="8.8.0"
EXPAT_VERSION="2.6.2"

if [ "${1:-}" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    exit 0
fi

mkdir -p "$SRC_DIR" "$PREFIX_DIR" "$APP_OUT_DIR"

clone_repo() {
    local url="$1"
    local dir="$2"

    if [ ! -d "$dir/.git" ]; then
        git clone "$url" "$dir"
    fi
}

download_archive() {
    local url="$1"
    local archive="$2"
    local unpack_dir="$3"

    if [ ! -f "$archive" ]; then
        curl -L --fail -o "$archive" "$url"
    fi

    if [ ! -d "$unpack_dir" ]; then
        tar -xf "$archive" -C "$(dirname "$unpack_dir")"
    fi
}

patch_buildsystem() {
    perl -0pi -e 's{/bin/which}{command -v}g' \
        "$PREFIX_DIR/share/netsurf-buildsystem/makefiles/Makefile.tools"
}

build_zlib() {
    local dir="$SRC_DIR/zlib-$ZLIB_VERSION"
    local archive="$SRC_DIR/zlib-$ZLIB_VERSION.tar.gz"

    download_archive \
        "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
        "$archive" \
        "$dir"

    (
        cd "$dir"
        make distclean >/dev/null 2>&1 || true
        CHOST="$HOST" ./configure --prefix="$PREFIX_DIR" --static
        make -j"$JOBS"
        make install
    )
}

build_openssl() {
    local dir="$SRC_DIR/openssl-$OPENSSL_VERSION"
    local archive="$SRC_DIR/openssl-$OPENSSL_VERSION.tar.gz"

    download_archive \
        "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" \
        "$archive" \
        "$dir"

    (
        cd "$dir"
        make clean >/dev/null 2>&1 || true
        perl ./Configure linux-armv4 no-shared no-tests no-asm \
            --cross-compile-prefix="${HOST}-" \
            --prefix="$PREFIX_DIR" \
            --openssldir="$PREFIX_DIR/ssl"
        make -j"$JOBS"
        make install_sw
    )
}

build_expat() {
    local dir="$SRC_DIR/expat-$EXPAT_VERSION"
    local archive="$SRC_DIR/expat-$EXPAT_VERSION.tar.xz"

    download_archive \
        "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-$EXPAT_VERSION.tar.xz" \
        "$archive" \
        "$dir"

    (
        cd "$dir"
        make distclean >/dev/null 2>&1 || true
        CC="${HOST}-gcc" \
        AR="${HOST}-ar" \
        RANLIB="${HOST}-ranlib" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX_DIR" \
            --disable-shared \
            --enable-static
        make -j"$JOBS"
        make install
    )
}

build_curl() {
    local dir="$SRC_DIR/curl-$CURL_VERSION"
    local archive="$SRC_DIR/curl-$CURL_VERSION.tar.xz"

    download_archive \
        "https://curl.se/download/curl-$CURL_VERSION.tar.xz" \
        "$archive" \
        "$dir"

    (
        cd "$dir"
        make distclean >/dev/null 2>&1 || true
        PKG_CONFIG_LIBDIR="$PREFIX_DIR/lib/pkgconfig" \
        CC="${HOST}-gcc" \
        AR="${HOST}-ar" \
        RANLIB="${HOST}-ranlib" \
        LIBS="-ldl -pthread -latomic" \
        ./configure \
            --host="$HOST" \
            --prefix="$PREFIX_DIR" \
            --disable-shared \
            --enable-static \
            --with-openssl="$PREFIX_DIR" \
            --with-zlib="$PREFIX_DIR" \
            --without-libpsl \
            --without-brotli \
            --without-zstd \
            --disable-ldap \
            --disable-ldaps \
            --disable-ftp \
            --disable-file \
            --disable-rtsp \
            --disable-dict \
            --disable-telnet \
            --disable-tftp \
            --disable-pop3 \
            --disable-imap \
            --disable-smb \
            --disable-smtp \
            --disable-gopher \
            --disable-manual \
            --disable-docs
        make -j"$JOBS"
        make install
    )
}

build_internal_lib() {
    local dir="$1"

    (
        cd "$dir"
        make clean >/dev/null 2>&1 || true
        PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        make -j"$JOBS" install \
            PREFIX="$PREFIX_DIR" \
            HOST="$HOST" \
            BUILD="$HOST" \
            CC="${HOST}-gcc" \
            AR="${HOST}-ar" \
            CXX="${HOST}-g++" \
            RANLIB="${HOST}-ranlib" \
            NSSHARED="$PREFIX_DIR/share/netsurf-buildsystem"
    )
}

build_libnsfb() {
    local dir="$SRC_DIR/libnsfb"

    cp "$APP_DIR/gemini_linux_surface.c" "$dir/src/surface/linux.c"
    if ! grep -q 'linux.c' "$dir/src/surface/Makefile"; then
        perl -0pi -e 's/SURFACE_HANDLER_yes := surface\.c ram\.c/SURFACE_HANDLER_yes := surface.c ram.c linux.c/' \
            "$dir/src/surface/Makefile"
    fi

    (
        cd "$dir"
        make clean >/dev/null 2>&1 || true
        PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CFLAGS="-I$REPO_DIR/libgemini${CFLAGS:+ $CFLAGS}" \
        make -j"$JOBS" install \
            PREFIX="$PREFIX_DIR" \
            HOST="$HOST" \
            BUILD="$HOST" \
            CC="${HOST}-gcc" \
            AR="${HOST}-ar" \
            CXX="${HOST}-g++" \
            RANLIB="${HOST}-ranlib" \
            NSSHARED="$PREFIX_DIR/share/netsurf-buildsystem"
    )

    perl -0pi -e "s{^Libs: (.*)\$}{Libs: \$1 -L$REPO_DIR/libgemini -lgemini -ldl}m" \
        "$PREFIX_DIR/lib/pkgconfig/libnsfb.pc"
}

build_netsurf() {
    local dir="$SRC_DIR/netsurf"
    local build_libpng_cflags
    local build_libpng_ldflags

    cp "$APP_DIR/netsurf.Makefile.config" "$dir/Makefile.config"

    build_libpng_cflags="$(pkg-config --cflags libpng)"
    build_libpng_ldflags="$(pkg-config --libs libpng)"

    (
        cd "$dir"
        # NetSurf's generated dependency files can be malformed on a
        # subsequent incremental build when cross-building from macOS.
        # Recreate only the frontend build tree so top-level packaging
        # remains repeatable without discarding downloaded deps.
        rm -rf build
        make clean >/dev/null 2>&1 || true
        PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        make -j"$JOBS" TARGET=framebuffer \
            HOST="$HOST" \
            CC="${HOST}-gcc" \
            CXX="${HOST}-g++" \
            AR="${HOST}-ar" \
            BUILD_CC=cc \
            BUILD_CXX=c++ \
            PREFIX="$PREFIX_DIR" \
            NSSHARED="$PREFIX_DIR/share/netsurf-buildsystem" \
            BUILD_LIBPNG_CFLAGS="$build_libpng_cflags" \
            BUILD_LIBPNG_LDFLAGS="$build_libpng_ldflags"
    )
}

prepare_output() {
    local netsurf_dir="$SRC_DIR/netsurf"

    rm -rf "$APP_OUT_DIR"
    mkdir -p "$APP_OUT_DIR/res"

    "${HOST}-gcc" -O2 -Wall -Wextra \
        -o "$APP_OUT_DIR/netsurf" \
        "$APP_DIR/netsurf_launcher.c"
    "${HOST}-strip" "$APP_OUT_DIR/netsurf"

    cp "$netsurf_dir/nsfb" "$APP_OUT_DIR/netsurf-bin"
    "${HOST}-strip" "$APP_OUT_DIR/netsurf-bin"

    cp -R "$netsurf_dir/resources/." "$APP_OUT_DIR/res/"
    cp "$netsurf_dir/frontends/framebuffer/res/en/Messages" "$APP_OUT_DIR/res/Messages"
}

clone_repo "git://git.netsurf-browser.org/buildsystem.git" "$SRC_DIR/buildsystem"
clone_repo "git://git.netsurf-browser.org/libwapcaplet.git" "$SRC_DIR/libwapcaplet"
clone_repo "git://git.netsurf-browser.org/libparserutils.git" "$SRC_DIR/libparserutils"
clone_repo "git://git.netsurf-browser.org/libhubbub.git" "$SRC_DIR/libhubbub"
clone_repo "git://git.netsurf-browser.org/libcss.git" "$SRC_DIR/libcss"
clone_repo "git://git.netsurf-browser.org/libdom.git" "$SRC_DIR/libdom"
clone_repo "git://git.netsurf-browser.org/libnsutils.git" "$SRC_DIR/libnsutils"
clone_repo "git://git.netsurf-browser.org/libnsfb.git" "$SRC_DIR/libnsfb"
clone_repo "git://git.netsurf-browser.org/netsurf.git" "$SRC_DIR/netsurf"

make -C "$REPO_DIR/libgemini" -j"$JOBS"
make -C "$SRC_DIR/buildsystem" install PREFIX="$PREFIX_DIR"
patch_buildsystem

build_zlib
build_openssl
build_expat
build_curl

build_internal_lib "$SRC_DIR/libwapcaplet"
build_internal_lib "$SRC_DIR/libparserutils"
build_internal_lib "$SRC_DIR/libhubbub"
build_internal_lib "$SRC_DIR/libcss"
build_internal_lib "$SRC_DIR/libdom"
build_internal_lib "$SRC_DIR/libnsutils"
build_libnsfb

build_netsurf
prepare_output
