#!/bin/bash
# build_launchers.sh — build native ARM launchers for DOSBox-X app entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CROSS_PREFIX="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}"
CC="${CC:-${CROSS_PREFIX}-gcc}"
CFLAGS="${CFLAGS:- -O2 -Wall -Wextra -std=c11}"
SOURCE="$SCRIPT_DIR/gemini/dosboxx_launcher.c"

build_launcher() {
    local out="$1"
    shift
    mkdir -p "$(dirname "$out")"
    "$CC" $CFLAGS "$SOURCE" "$@" -o "$out"
}

if [ "${1:-}" = "clean" ]; then
    rm -f \
        "$SCRIPT_DIR/build/dosboxx-launcher" \
        "$SCRIPT_DIR/../win31/build/win31-launcher" \
        "$SCRIPT_DIR/../win95/build/win95-launcher"
    exit 0
fi

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: $CC not found in PATH"
    exit 1
fi

build_launcher \
    "$SCRIPT_DIR/build/dosboxx-launcher" \
    -DLAUNCH_TARGET="\"dosbox-x\"" \
    -DLAUNCH_PRIMARY_CONF="\"dosbox-x.conf\""

build_launcher \
    "$SCRIPT_DIR/../win31/build/win31-launcher" \
    -DLAUNCH_TARGET="\"../dosboxx/dosbox-x\"" \
    -DLAUNCH_PRIMARY_CONF="\"win31.conf\"" \
    -DLAUNCH_FALLBACK_CONF="\"missing-media.conf\"" \
    -DLAUNCH_MEDIA_CHECK="\"images/system.img\""

build_launcher \
    "$SCRIPT_DIR/../win95/build/win95-launcher" \
    -DLAUNCH_TARGET="\"../dosboxx/dosbox-x\"" \
    -DLAUNCH_PRIMARY_CONF="\"win95.conf\"" \
    -DLAUNCH_FALLBACK_CONF="\"missing-media.conf\"" \
    -DLAUNCH_MEDIA_CHECK="\"images/system.img\""

echo "Launcher builds complete."
