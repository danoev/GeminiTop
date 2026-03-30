#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/tyrquake-src"
RUNTIME_DIR="$BUILD_DIR/runtime"

UPSTREAM_REPO="https://github.com/sezero/tyrquake.git"
UPSTREAM_REF="653157915975b196e36980a1ef7146485509b69a"

CROSS="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}"
CC="${CROSS}-gcc"
AR="${CROSS}-ar"
STRIP="${CROSS}-strip"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

ARCH_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
COMMON_CFLAGS="-std=gnu11 -O2 $ARCH_FLAGS -D_DEFAULT_SOURCE -DGEMINI"

copy_if_different() {
    local src="$1"
    local dst="$2"

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}

fetch_source() {
    mkdir -p "$BUILD_DIR"

    if [ ! -d "$SRC_DIR/.git" ]; then
        git clone "$UPSTREAM_REPO" "$SRC_DIR"
    fi

    git -C "$SRC_DIR" fetch origin "$UPSTREAM_REF"
    git -C "$SRC_DIR" checkout --force "$UPSTREAM_REF"
    git -C "$SRC_DIR" clean -fdx
}

install_gemini_backend() {
    copy_if_different "$REPO_DIR/libgemini/gemini.h" "$SRC_DIR/include/gemini.h"
    copy_if_different "$SCRIPT_DIR/gemini/vid_gemini.c" "$SRC_DIR/common/vid_gemini.c"
    copy_if_different "$SCRIPT_DIR/gemini/in_gemini.c" "$SRC_DIR/common/in_gemini.c"
    copy_if_different "$SCRIPT_DIR/gemini/snd_gemini.c" "$SRC_DIR/common/snd_gemini.c"
}

apply_patches() {
    local patch

    for patch in "$SCRIPT_DIR"/patches/*.patch; do
        git -C "$SRC_DIR" apply "$patch"
    done
}

build_libgemini() {
    make -C "$REPO_DIR/libgemini" \
        CROSS_PREFIX="$CROSS"
}

build_tyrquake() {
    make -C "$SRC_DIR" -j"$JOBS" \
        CC="$CC" \
        AR="$AR" \
        STRIP="$STRIP" \
        TARGET_OS=UNIX \
        TARGET_UNIX=linux \
        USE_X86_ASM=N \
        OPTIMIZED_CFLAGS=Y \
        QBASEDIR=. \
        VID_TARGET=gemini \
        IN_TARGET=gemini \
        SND_TARGET=gemini \
        CD_TARGET=null \
        CFLAGS="$COMMON_CFLAGS" \
        COMMON_LFLAGS="-L$REPO_DIR/libgemini" \
        COMMON_LIBS="gemini dl m" \
        bin/tyr-quake \
        bin/tyr-qwcl
}

stage_runtime() {
    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR/bin" \
             "$RUNTIME_DIR/id1" \
             "$RUNTIME_DIR/qw" \
             "$RUNTIME_DIR/.tyrquake/id1" \
             "$RUNTIME_DIR/.tyrquake/qw"

    cp "$SRC_DIR/bin/tyr-quake" "$RUNTIME_DIR/bin/"
    cp "$SRC_DIR/bin/tyr-qwcl" "$RUNTIME_DIR/bin/"
    cp "$SCRIPT_DIR/assets/README-GAME-FILES.txt" "$RUNTIME_DIR/"
    cp "$SCRIPT_DIR/assets/QW-LIVE-SERVERS.txt" "$RUNTIME_DIR/"
    cp "$SCRIPT_DIR/assets/autoexec.cfg" "$RUNTIME_DIR/.tyrquake/id1/autoexec.cfg"
    cp "$SCRIPT_DIR/assets/autoexec.cfg" "$RUNTIME_DIR/.tyrquake/qw/autoexec.cfg"
    cp "$SCRIPT_DIR/assets/video.cfg" "$RUNTIME_DIR/.tyrquake/id1/video.cfg"
    cp "$SCRIPT_DIR/assets/video.cfg" "$RUNTIME_DIR/.tyrquake/qw/video.cfg"
    cp "$SRC_DIR/readme.txt" "$RUNTIME_DIR/TYRQUAKE-README.txt"

    "$STRIP" "$RUNTIME_DIR/bin/tyr-quake"
    "$STRIP" "$RUNTIME_DIR/bin/tyr-qwcl"
}

clean_all() {
    rm -rf "$BUILD_DIR"
}

if [ "${1:-}" = "clean" ]; then
    clean_all
    exit 0
fi

fetch_source
install_gemini_backend
apply_patches
build_libgemini
build_tyrquake
stage_runtime
