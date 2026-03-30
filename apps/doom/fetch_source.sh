#!/bin/bash
# fetch_source.sh — Download doomgeneric engine source and doom1.wad if missing
#
# Upstream: https://github.com/ozkl/doomgeneric
# doom1.wad: DOOM shareware WAD from id Software (freely distributable)
#
# Our Gemini integration code lives in gemini/ and is NOT touched by this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DOOMGENERIC_REPO="https://github.com/ozkl/doomgeneric.git"
DOOMGENERIC_DIR="$SCRIPT_DIR/doomgeneric"
DOOM1_WAD="$SCRIPT_DIR/doom1.wad"
DOOM1_WAD_URL="https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad"

# ---------- doomgeneric engine source ----------
if [ ! -d "$DOOMGENERIC_DIR" ]; then
    echo "  Downloading doomgeneric engine source..."
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "$DOOMGENERIC_REPO" "$TMPDIR/doomgeneric" 2>&1 | tail -3
    # we only need the doomgeneric/ subdirectory (the engine source)
    mv "$TMPDIR/doomgeneric/doomgeneric" "$DOOMGENERIC_DIR"
    rm -rf "$TMPDIR"
    # Patch out SDL_mixer.h include — we use our own Gemini audio module.
    sed -i.bak 's|^#include <SDL_mixer.h>|/* SDL_mixer.h removed — using GEMINI_SOUND */|' "$DOOMGENERIC_DIR/i_sound.c"
    rm -f "$DOOMGENERIC_DIR/i_sound.c.bak"
    echo "  doomgeneric source ready."
else
    echo "  doomgeneric source already present."
fi

# ---------- doom1.wad (shareware) ----------
if [ ! -f "$DOOM1_WAD" ]; then
    echo "  Downloading doom1.wad (DOOM shareware)..."
    if command -v curl &>/dev/null; then
        curl -fSL -o "$DOOM1_WAD" "$DOOM1_WAD_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O "$DOOM1_WAD" "$DOOM1_WAD_URL"
    else
        echo "ERROR: curl or wget required to download doom1.wad"
        exit 1
    fi
    echo "  doom1.wad ready."
else
    echo "  doom1.wad already present."
fi
