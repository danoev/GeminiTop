#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$SCRIPT_DIR/../quake_shared"
BUILD_DIR="$SCRIPT_DIR/build"
CC="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}-gcc"
STRIP="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}-strip"
ARCH_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"

if [ "${1:-}" = "clean" ]; then
    bash "$SHARED_DIR/build_tyrquake.sh" clean
    rm -rf "$BUILD_DIR"
    exit 0
fi

bash "$SHARED_DIR/build_tyrquake.sh"

mkdir -p "$BUILD_DIR"
"$CC" -std=gnu11 -Os $ARCH_FLAGS -D_DEFAULT_SOURCE \
    "$SHARED_DIR/quake_launcher.c" \
    -o "$BUILD_DIR/quake-launcher"
"$STRIP" "$BUILD_DIR/quake-launcher"
