#!/bin/bash
# build_dosboxx.sh — fetch, patch, cross-compile, and stage DOSBox-X for Gemini

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/dosbox-x-src"
OUT_BIN="$BUILD_DIR/dosbox-x"
SHARE_DIR="$BUILD_DIR/share"

DOSBOXX_REPO="https://github.com/joncampbell123/dosbox-x.git"
DOSBOXX_REF="6139ebb37ff52591017c0d511b6696be4029c853"

CROSS="${CROSS_PREFIX:-arm-unknown-linux-gnueabihf}"
CC="${CROSS}-gcc"
CXX="${CROSS}-g++"
AR="${CROSS}-ar"
RANLIB="${CROSS}-ranlib"
STRIP="${CROSS}-strip"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

ARCH_FLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
OPT_FLAGS="-Os"
WARN_FLAGS="-Wno-error=incompatible-pointer-types"
COMMON_CFLAGS="$ARCH_FLAGS $OPT_FLAGS $WARN_FLAGS"
COMMON_CXXFLAGS="$ARCH_FLAGS $OPT_FLAGS"

copy_if_different() {
    local src="$1"
    local dst="$2"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required tool '$1' not found in PATH"
        exit 1
    fi
}

fetch_source() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        mkdir -p "$BUILD_DIR"
        git clone --depth 1 "$DOSBOXX_REPO" "$SRC_DIR"
    fi

    if [ "$(git -C "$SRC_DIR" rev-parse HEAD)" != "$DOSBOXX_REF" ]; then
        git -C "$SRC_DIR" fetch --depth 1 origin "$DOSBOXX_REF"
        git -C "$SRC_DIR" checkout --force "$DOSBOXX_REF"
    fi
}

install_gemini_sdl_backend() {
    copy_if_different "$SCRIPT_DIR/gemini/SDL_nullvideo.c" "$SRC_DIR/vs/sdl/src/video/dummy/SDL_nullvideo.c"
    copy_if_different "$SCRIPT_DIR/gemini/SDL_nullvideo.h" "$SRC_DIR/vs/sdl/src/video/dummy/SDL_nullvideo.h"
    copy_if_different "$SCRIPT_DIR/gemini/SDL_nullevents.c" "$SRC_DIR/vs/sdl/src/video/dummy/SDL_nullevents.c"
    copy_if_different "$SCRIPT_DIR/gemini/SDL_nullevents_c.h" "$SRC_DIR/vs/sdl/src/video/dummy/SDL_nullevents_c.h"
    copy_if_different "$SCRIPT_DIR/gemini/SDL_dummyaudio.c" "$SRC_DIR/vs/sdl/src/audio/dummy/SDL_dummyaudio.c"
    copy_if_different "$SCRIPT_DIR/gemini/SDL_dummyaudio.h" "$SRC_DIR/vs/sdl/src/audio/dummy/SDL_dummyaudio.h"
}

run_autogen_if_needed() {
    if [ -f "$SRC_DIR/configure" ]; then
        return 0
    fi

    for tool in aclocal autoheader automake autoconf; do
        require_tool "$tool"
    done

    (cd "$SRC_DIR" && ./autogen.sh)
}

build_zlib() {
    local dir="$SRC_DIR/vs/zlib"
    local host_dir="$dir/linux-host"
    local build_subdir="$dir/linux-build"

    mkdir -p "$host_dir" "$build_subdir"
    if [ ! -f "$build_subdir/Makefile" ]; then
        (
            cd "$build_subdir"
            CHOST="$CROSS" \
            CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
            CFLAGS="$COMMON_CFLAGS" \
            ../configure --static --prefix="$host_dir"
        )
    fi
    make -C "$build_subdir" -j"$JOBS"
    make -C "$build_subdir" install
}

build_libpng() {
    local dir="$SRC_DIR/vs/libpng"
    local host_dir="$dir/linux-host"
    local build_subdir="$dir/linux-build"
    local cppflags="-I$SRC_DIR/vs/zlib/linux-host/include"
    local ldflags="-L$SRC_DIR/vs/zlib/linux-host/lib"

    mkdir -p "$host_dir" "$build_subdir"
    if [ ! -f "$build_subdir/Makefile" ]; then
        (
            cd "$build_subdir"
            CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
            CFLAGS="$COMMON_CFLAGS" CPPFLAGS="$cppflags" LDFLAGS="$ldflags" \
            "$dir/configure" --host="$CROSS" --srcdir="$dir" --prefix="$host_dir" \
                --enable-static --disable-shared
        )
    fi
    make -C "$build_subdir" -j"$JOBS"
    make -C "$build_subdir" install
}

build_freetype() {
    local dir="$SRC_DIR/vs/freetype"
    local host_dir="$dir/linux-host"
    local build_subdir="$dir/linux-build"
    local cppflags="-I$SRC_DIR/vs/zlib/linux-host/include"
    local ldflags="-L$SRC_DIR/vs/zlib/linux-host/lib"
    local pkg_config_path="$SRC_DIR/vs/zlib/linux-host/lib/pkgconfig"

    mkdir -p "$host_dir" "$build_subdir"
    if [ ! -f "$build_subdir/Makefile" ]; then
        (
            cd "$build_subdir"
            CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
            CFLAGS="$COMMON_CFLAGS" CPPFLAGS="$cppflags" LDFLAGS="$ldflags" \
            PKG_CONFIG_PATH="$pkg_config_path${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
            "$dir/configure" --host="$CROSS" --srcdir="$dir" --prefix="$host_dir" \
                --enable-static --disable-shared --with-bzip2=no --with-harfbuzz=no \
                --with-png=no --with-brotli=no
        )
    fi
    make -C "$build_subdir" -j"$JOBS"
    make -C "$build_subdir" install
}

patch_sdl_linker_metadata() {
    local sdl_config="$SRC_DIR/vs/sdl/linux-host/bin/sdl-config"
    local sdl_la="$SRC_DIR/vs/sdl/linux-host/lib/libSDL.la"
    local extra_flags="-L$REPO_DIR/libgemini -lgemini -ldl"
    local tmp_file

    if [ -f "$sdl_config" ] && ! grep -Fq -- "$extra_flags" "$sdl_config"; then
        tmp_file="$(mktemp)"
        awk -v extra="$extra_flags" '
            /^[[:space:]]*echo -L\$\{exec_prefix\}\/lib .* -lpthread/ && !patched {
                print $0 " " extra
                patched = 1
                next
            }
            { print }
        ' "$sdl_config" > "$tmp_file"
        mv "$tmp_file" "$sdl_config"
        chmod +x "$sdl_config"
    fi

    if [ -f "$sdl_la" ] && ! grep -Fq -- "$extra_flags" "$sdl_la"; then
        tmp_file="$(mktemp)"
        sed "s|^dependency_libs='\\(.*\\)'$|dependency_libs='\\1 $extra_flags'|" \
            "$sdl_la" > "$tmp_file"
        mv "$tmp_file" "$sdl_la"
    fi
}

append_lib_to_makefile() {
    local makefile="$1"
    local extra_lib="$2"
    local tmp_file

    if [ ! -f "$makefile" ] || grep -Fq -- "$extra_lib" "$makefile"; then
        return 0
    fi

    tmp_file="$(mktemp)"
    awk -v extra="$extra_lib" '
        /^LIBS =/ && !patched {
            print $0 " " extra
            patched = 1
            next
        }
        { print }
    ' "$makefile" > "$tmp_file"
    mv "$tmp_file" "$makefile"
}

patch_dosboxx_linker_metadata() {
    append_lib_to_makefile "$SRC_DIR/Makefile" "-lfreetype"
    append_lib_to_makefile "$SRC_DIR/src/Makefile" "-lfreetype"
}

build_sdl1() {
    local dir="$SRC_DIR/vs/sdl"
    local host_dir="$dir/linux-host"
    local build_subdir="$dir/linux-build"

    mkdir -p "$host_dir" "$build_subdir"
    chmod +x "$dir/configure"
    if [ ! -f "$build_subdir/Makefile" ]; then
        (
            cd "$build_subdir"
            CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
            CFLAGS="$COMMON_CFLAGS" CXXFLAGS="$COMMON_CXXFLAGS" \
            CPPFLAGS="-I$REPO_DIR/libgemini" \
            "$dir/configure" --host="$CROSS" --srcdir="$dir" --prefix="$host_dir" \
                --enable-static --disable-shared --disable-video-x11 \
                --disable-video-x11-xrandr --disable-video-x11-vm --disable-video-x11-xv
        )
    fi
    make -C "$build_subdir" -j"$JOBS"
    make -C "$build_subdir" install
    patch_sdl_linker_metadata
}

stage_share() {
    mkdir -p "$SHARE_DIR"
    cp "$SRC_DIR/dosbox-x.reference.conf" "$SHARE_DIR/"
    cp "$SRC_DIR/dosbox-x.reference.full.conf" "$SHARE_DIR/"
    cp "$SRC_DIR/CHANGELOG" "$SHARE_DIR/"
    mkdir -p "$SHARE_DIR/fonts"
    cp "$SRC_DIR/contrib/fonts/FREECG98.BMP" "$SHARE_DIR/fonts/"
}

build_dosboxx() {
    local path_prefix="$SRC_DIR/vs/sdl/linux-host/bin:$PATH"
    local cppflags="-I$SRC_DIR/vs/zlib/linux-host/include -I$SRC_DIR/vs/libpng/linux-host/include -I$SRC_DIR/vs/freetype/linux-host/include/freetype2"
    local ldflags="-L$SRC_DIR/vs/zlib/linux-host/lib -L$SRC_DIR/vs/libpng/linux-host/lib -L$SRC_DIR/vs/freetype/linux-host/lib"

    chmod +x "$SRC_DIR/configure"
    (
        cd "$SRC_DIR"
        PATH="$path_prefix" \
        CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
        CFLAGS="$COMMON_CFLAGS" CXXFLAGS="$COMMON_CXXFLAGS" \
        CPPFLAGS="$cppflags" LDFLAGS="$ldflags" INTERNAL_FREETYPE=1 \
        ./configure --host="$CROSS" --target="$CROSS" --prefix=/usr \
            --disable-sdlnet --disable-libslirp --disable-libfluidsynth \
            --disable-avcodec --disable-opengl --disable-x11 --disable-printer \
            --disable-gamelink --disable-mt32 --disable-screenshots \
            --disable-dynamic-core --disable-dynrec
    )

    patch_dosboxx_linker_metadata
    make -C "$SRC_DIR" -j"$JOBS"

    if [ ! -f "$SRC_DIR/src/dosbox-x" ]; then
        echo "ERROR: DOSBox-X binary not found after build"
        exit 1
    fi

    mkdir -p "$BUILD_DIR"
    cp "$SRC_DIR/src/dosbox-x" "$OUT_BIN"
    "$STRIP" "$OUT_BIN"
    stage_share
}

clean_build() {
    rm -rf "$BUILD_DIR"
}

if [ "${1:-}" = "clean" ]; then
    clean_build
    exit 0
fi

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$STRIP" git make perl; do
    require_tool "$tool"
done

make -C "$REPO_DIR/libgemini" -j"$JOBS"
fetch_source
install_gemini_sdl_backend
run_autogen_if_needed
build_zlib
build_libpng
build_freetype
build_sdl1
build_dosboxx

echo "DOSBox-X build complete: $OUT_BIN"
