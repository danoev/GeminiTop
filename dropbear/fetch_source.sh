#!/bin/bash
# fetch_source.sh — Download dropbear source if not already present
#
# Downloads from the official dropbear release site.
# The auth bypass patch (patch_auth.py) is applied separately during build.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DROPBEAR_VERSION="2025.88"
DROPBEAR_DIR="$SCRIPT_DIR/dropbear-${DROPBEAR_VERSION}"
DROPBEAR_TAR="$SCRIPT_DIR/dropbear-${DROPBEAR_VERSION}.tar.bz2"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2"

if [ -d "$DROPBEAR_DIR" ]; then
    echo "  dropbear-${DROPBEAR_VERSION} source already present."
    exit 0
fi

echo "  Downloading dropbear-${DROPBEAR_VERSION}..."
if [ ! -f "$DROPBEAR_TAR" ]; then
    if command -v curl &>/dev/null; then
        curl -fSL -o "$DROPBEAR_TAR" "$DROPBEAR_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O "$DROPBEAR_TAR" "$DROPBEAR_URL"
    else
        echo "ERROR: curl or wget required to download dropbear"
        exit 1
    fi
fi

echo "  Extracting..."
tar xjf "$DROPBEAR_TAR" -C "$SCRIPT_DIR/"
rm -f "$DROPBEAR_TAR"
echo "  dropbear-${DROPBEAR_VERSION} source ready."
