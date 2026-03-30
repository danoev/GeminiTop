#!/bin/bash
# build_retroarch.sh — Download, patch, and cross-compile RetroArch for Gemini SP7021
#
# Downloads RetroArch source if missing, installs Gemini integration sources,
# applies source registration edits, then cross-compiles for ARMv7-a NEON.
#
# Our code stays in gemini/ — the upstream source is downloaded into build/.
#
# Output: build/retroarch (stripped ARM ELF binary)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RETROARCH_REPO="https://github.com/libretro/RetroArch.git"
RETROARCH_TAG="v1.22.2"
SRC_DIR="$SCRIPT_DIR/build/retroarch-src"
OUT_BIN="$SCRIPT_DIR/build/retroarch"

CROSS=arm-unknown-linux-gnueabihf
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CROSS="${CROSS_PREFIX:-$CROSS}"
CC="${CROSS}-gcc"
CXX="${CROSS}-g++"
STRIP="${CROSS}-strip"

ARCH_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
OPT_FLAGS="-Os"

copy_if_different() {
    local src="$1"
    local dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    cp -v "$src" "$dst"
}

if ! command -v "$CC" &>/dev/null; then
    echo "ERROR: $CC not found in PATH"
    echo "macOS:  brew tap messense/macos-cross-toolchains && brew install arm-unknown-linux-gnueabihf"
    echo "Linux:  apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf"
    echo "If needed: CROSS_PREFIX=arm-linux-gnueabihf bash apps/retroarch/build_retroarch.sh"
    exit 1
fi

for REQ in git make perl; do
    if ! command -v "$REQ" &>/dev/null; then
        echo "ERROR: $REQ not found in PATH"
        exit 1
    fi
done

echo "========================================="
echo "  RetroArch — Build for Gemini SP7021"
echo "========================================="
echo ""

# ---------- step 1: download source ----------
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[1/4] Cloning RetroArch ${RETROARCH_TAG}..."
    rm -rf "$SRC_DIR"
    mkdir -p build
    git clone --depth 1 --branch "$RETROARCH_TAG" "$RETROARCH_REPO" "$SRC_DIR" 2>&1 | tail -3
    echo ""
else
    echo "[1/4] RetroArch source already present at $SRC_DIR"
    echo ""
fi

# ---------- step 2: copy Gemini integration sources ----------
echo "[2/4] Installing Gemini platform drivers..."
copy_if_different "$SCRIPT_DIR/gemini/gemini_video.c" "$SRC_DIR/gfx/drivers/gemini_gfx.c"
copy_if_different "$SCRIPT_DIR/gemini/gemini_audio.c" "$SRC_DIR/audio/drivers/gemini_audio.c"
copy_if_different "$SCRIPT_DIR/gemini/gemini_input.c" "$SRC_DIR/input/drivers/gemini_input.c"
echo ""

# ---------- step 3: register drivers in upstream source ----------
echo "[3/4] Registering Gemini drivers in RetroArch..."

cd "$SRC_DIR"

# Makefile.common — add build rules for our driver objects
if ! grep -q 'HAVE_GEMINI' Makefile.common 2>/dev/null; then
    cat >> Makefile.common << 'PATCH_EOF'

# Gemini SP7021 platform drivers
ifeq ($(HAVE_GEMINI), 1)
   OBJ += gfx/drivers/gemini_gfx.o
   OBJ += audio/drivers/gemini_audio.o
   OBJ += input/drivers/gemini_input.o
   DEFINES += -DHAVE_GEMINI
endif
PATCH_EOF
    echo "  Makefile.common: added HAVE_GEMINI build rules"
fi

# video_driver.c — register video_gemini
if ! grep -q 'video_gemini' gfx/video_driver.c 2>/dev/null; then
    perl -i -pe '
        if (/video_driver_t\s+\*video_drivers\[\]/ && !$done_extern_v) {
            print "#ifdef HAVE_GEMINI\nextern video_driver_t video_gemini;\n#endif\n";
            $done_extern_v = 1;
        }
        if (/&video_null,/ && !$done_entry_v) {
            print "#ifdef HAVE_GEMINI\n   \&video_gemini,\n#endif\n";
            $done_entry_v = 1;
        }
    ' gfx/video_driver.c
    echo "  gfx/video_driver.c: registered video_gemini"
fi

# audio_driver.c — register audio_gemini
if ! grep -q 'audio_gemini' audio/audio_driver.c 2>/dev/null; then
    perl -i -pe '
        if (/audio_driver_t\s+\*audio_drivers\[\]/ && !$done_extern_a) {
            print "#ifdef HAVE_GEMINI\nextern audio_driver_t audio_gemini;\n#endif\n";
            $done_extern_a = 1;
        }
        if (/&audio_null,/ && !$done_entry_a) {
            print "#ifdef HAVE_GEMINI\n   \&audio_gemini,\n#endif\n";
            $done_entry_a = 1;
        }
    ' audio/audio_driver.c
    echo "  audio/audio_driver.c: registered audio_gemini"
fi

# input_driver.c — register input_gemini
if ! grep -q 'input_gemini' input/input_driver.c 2>/dev/null; then
    perl -i -pe '
        if (/input_driver_t\s+\*input_drivers\[\]/ && !$done_extern_i) {
            print "#ifdef HAVE_GEMINI\nextern input_driver_t input_gemini;\n#endif\n";
            $done_extern_i = 1;
        }
        if (/&input_null,/ && !$done_entry_i) {
            print "#ifdef HAVE_GEMINI\n   \&input_gemini,\n#endif\n";
            $done_entry_i = 1;
        }
    ' input/input_driver.c
    echo "  input/input_driver.c: registered input_gemini"
fi

echo ""

# ---------- step 4: configure and build ----------
echo "[4/4] Configuring and building..."

export CC="$CC"
export CXX="$CXX"
export CFLAGS="$ARCH_FLAGS $OPT_FLAGS"
export CXXFLAGS="$ARCH_FLAGS $OPT_FLAGS"

if [ ! -f config.mk ]; then
    ./configure \
        --host="$CROSS" \
        --disable-opengl --disable-opengl1 --disable-opengl_core \
        --disable-vulkan \
        --disable-kms \
        --disable-x11 \
        --disable-wayland \
        --disable-sdl --disable-sdl2 \
        --disable-pulse --disable-alsa --disable-oss --disable-jack \
        --disable-v4l2 \
        --disable-freetype \
        --disable-ffmpeg \
        --disable-networkgamepad \
        --disable-networking \
        --disable-systemd \
        --disable-udev \
        --enable-rgui \
        --disable-materialui --disable-xmb --disable-ozone \
        --disable-qt \
        --enable-threads \
        --enable-neon \
        --disable-ssa \
        --disable-discord \
        --disable-translate \
        --enable-floathard

    # fix macOS host flags leaking into cross-compile
    sed -i.bak 's/-mmacosx-version-min=[^ ]*//g' config.mk
    sed -i.bak 's/-stdlib=libc++//g' config.mk
    sed -i.bak 's/^OS = Darwin/OS = Linux/' config.mk
    rm -f config.mk.bak
else
    echo "  Reusing existing config.mk"
fi

grep -Fqx "HAVE_GEMINI = 1" config.mk || echo "HAVE_GEMINI = 1" >> config.mk

make -j"$JOBS" V=1 2>&1 | tail -20

if [ -f retroarch ]; then
    "$STRIP" retroarch
    mkdir -p "$SCRIPT_DIR/build"
    cp retroarch "$OUT_BIN"
    echo ""
    echo "=== RetroArch build complete ==="
    ls -la "$OUT_BIN"
else
    echo ""
    echo "ERROR: retroarch binary not found after build"
    exit 1
fi
