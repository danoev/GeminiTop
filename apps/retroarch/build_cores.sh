#!/bin/bash
# build_cores.sh — Download and cross-compile libretro cores for Gemini SP7021
#
# Builds each core as a .so that RetroArch loads at runtime.
# All cores use the standard libretro Makefile interface:
#   make -f Makefile.libretro platform=unix
#
# Output: build/cores/*.so
#
# Cores built:
#   pcsx_rearmed  — PlayStation 1 (ARM dynarec + NEON GPU, the reason we're here)
#   fceumm        — NES/Famicom (lightweight, accurate)
#   snes9x2002    — SNES (optimized for slow ARM, formerly PocketSNES)
#   gambatte      — Game Boy / Game Boy Color
#   gpsp          — Game Boy Advance (ARM dynarec)
#   picodrive     — Sega Genesis / Mega Drive / Sega CD (ARM dynarec)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CORES_DIR="$BUILD_DIR/cores"
SRC_BASE="$BUILD_DIR/core-src"

# cross-compiler
CROSS=arm-unknown-linux-gnueabihf
CROSS="${CROSS_PREFIX:-$CROSS}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CC="${CROSS}-gcc"
STRIP="${CROSS}-strip"

ARCH_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"

if ! command -v "$CC" &>/dev/null; then
    echo "ERROR: $CC not found in PATH"
    exit 1
fi

mkdir -p "$CORES_DIR" "$SRC_BASE"

echo "========================================="
echo "  Libretro Cores — Build for Gemini"
echo "========================================="
echo ""

# helper: clone (shallow) if not present
clone_core() {
    local name="$1" url="$2"
    if [ ! -d "$SRC_BASE/$name" ]; then
        echo "  Cloning $name..."
        git clone --depth 1 "$url" "$SRC_BASE/$name" 2>&1 | tail -1
    fi
}

# helper: build a libretro core
build_core() {
    local name="$1"
    local makefile="$2"    # e.g. Makefile.libretro or Makefile
    local extra_args="$3"  # additional make variables
    local output_so="$4"   # expected .so filename
    local plat="${5:-unix}" # platform override (default: unix)

    echo "  Building $name..."
    cd "$SRC_BASE/$name"

    # export as env vars so Makefile ?= picks them up but += still appends
    # (passing on command line would override all Makefile CFLAGS += additions)
    export CC="$CC"
    export CXX="${CROSS}-g++"
    export CFLAGS="$ARCH_FLAGS -Os"
    export CXXFLAGS="$ARCH_FLAGS -Os"

    make -f "$makefile" \
        platform="$plat" \
        $extra_args \
        -j"$JOBS" \
        2>&1 | tail -5

    if [ -f "$output_so" ]; then
        "$STRIP" "$output_so"
        cp "$output_so" "$CORES_DIR/"
        echo "  -> $(ls -la "$CORES_DIR/$(basename $output_so)" | awk '{print $5, $9}')"
    else
        echo "  WARNING: $output_so not found, build may have failed"
    fi
    echo ""
}

# --- PCSX-ReARMed (PS1) — the primary target ---
echo "[1/6] PCSX-ReARMed (PlayStation 1)"
clone_core "pcsx_rearmed" "https://github.com/libretro/pcsx_rearmed.git"
build_core "pcsx_rearmed" \
    "Makefile.libretro" \
    "DYNAREC=ari64 HAVE_NEON=1 BUILTIN_GPU=neon THREAD_RENDERING=1" \
    "pcsx_rearmed_libretro.so"

# --- FCEUmm (NES) ---
echo "[2/6] FCEUmm (NES)"
clone_core "fceumm" "https://github.com/libretro/libretro-fceumm.git"
build_core "fceumm" \
    "Makefile.libretro" \
    "" \
    "fceumm_libretro.so"

# --- Snes9x 2002 (SNES — lightweight) ---
echo "[3/6] Snes9x 2002 (SNES)"
clone_core "snes9x2002" "https://github.com/libretro/snes9x2002.git"
build_core "snes9x2002" \
    "Makefile" \
    "" \
    "snes9x2002_libretro.so"

# --- Gambatte (Game Boy / GBC) ---
echo "[4/6] Gambatte (Game Boy)"
clone_core "gambatte" "https://github.com/libretro/gambatte-libretro.git"
build_core "gambatte" \
    "Makefile.libretro" \
    "" \
    "gambatte_libretro.so"

# --- gpSP (GBA) ---
echo "[5/6] gpSP (Game Boy Advance)"
clone_core "gpsp" "https://github.com/libretro/gpsp.git"
build_core "gpsp" \
    "Makefile" \
    "HAVE_DYNAREC=1" \
    "gpsp_libretro.so" \
    "armv-hardfloat"

# --- PicoDrive (Genesis / Mega Drive) ---
echo "[6/6] PicoDrive (Sega Genesis)"
clone_core "picodrive" "https://github.com/libretro/picodrive.git"
(cd "$SRC_BASE/picodrive" && git submodule update --init 2>/dev/null || true)
build_core "picodrive" \
    "Makefile.libretro" \
    "use_sh2drc=1" \
    "picodrive_libretro.so"

# summary
echo "========================================="
echo "  Core build complete"
echo "========================================="
echo ""
echo "Built cores in $CORES_DIR:"
ls -la "$CORES_DIR/"*.so 2>/dev/null || echo "  (none)"
echo ""
echo "To add more cores: clone into $SRC_BASE/<name> and call build_core()"
echo ""
echo "Required BIOS files (user-provided, place in system/ directory):"
echo "  PS1:  scph1001.bin (or scph5500.bin, scph5501.bin, scph5502.bin)"
echo "  GBA:  gba_bios.bin"
echo "  Other cores generally don't require BIOS files."
