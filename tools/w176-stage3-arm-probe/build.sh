#!/bin/sh
set -eu

CDPATH=
export CDPATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd -P)
OUTPUT=${1:-"$SCRIPT_DIR/payload/arm_probe"}
TOOLCHAIN_FILE=gcc-arm-9.2-2019.12-aarch64-arm-none-linux-gnueabihf.tar.xz
TOOLCHAIN_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/9.2-2019.12/binrel/$TOOLCHAIN_FILE
TOOLCHAIN_MD5_URL=$TOOLCHAIN_URL.asc
TOOLCHAIN_SHA256=9f333ede9ba09d1bd266e110c1a0b69aa0fd4543696b5132ff238c20124b0dcb
TOOLCHAIN_MD5=571432175db6e28442e4610da92fe5cc
BASE_IMAGE=debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
IMAGE=geminitop-w176-stage3-toolchain:9.2-2019.12-arm64
CACHE_ROOT=${W176_TOOLCHAIN_CACHE:-${TMPDIR:-/tmp}/geminitop-w176-toolchains}
ARCHIVE=$CACHE_ROOT/$TOOLCHAIN_FILE
SIDECAR=$ARCHIVE.asc

for REQUIRED_COMMAND in cp curl dirname docker id mkdir mktemp mv rm sed sha256sum tar; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || {
        printf '%s\n' "missing command: $REQUIRED_COMMAND" >&2
        exit 1
    }
done

mkdir -p "$CACHE_ROOT"
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 3 -o "$ARCHIVE.part" "$TOOLCHAIN_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
if [ ! -f "$SIDECAR" ]; then
    curl -fL --retry 3 -o "$SIDECAR.part" "$TOOLCHAIN_MD5_URL"
    mv "$SIDECAR.part" "$SIDECAR"
fi

ACTUAL_SHA256=$(sha256sum "$ARCHIVE" | sed 's/[[:space:]].*$//')
[ "$ACTUAL_SHA256" = "$TOOLCHAIN_SHA256" ] || {
    printf '%s\n' "toolchain SHA-256 mismatch" >&2
    exit 1
}
PUBLISHED_MD5=$(sed 's/[[:space:]].*$//' "$SIDECAR")
[ "$PUBLISHED_MD5" = "$TOOLCHAIN_MD5" ] || {
    printf '%s\n' "official checksum sidecar mismatch" >&2
    exit 1
}
if command -v md5 >/dev/null 2>&1; then
    ACTUAL_MD5=$(md5 -q "$ARCHIVE")
elif command -v md5sum >/dev/null 2>&1; then
    ACTUAL_MD5=$(md5sum "$ARCHIVE" | sed 's/[[:space:]].*$//')
else
    printf '%s\n' "missing MD5 verification command" >&2
    exit 1
fi
[ "$ACTUAL_MD5" = "$TOOLCHAIN_MD5" ] || {
    printf '%s\n' "toolchain MD5 mismatch" >&2
    exit 1
}

CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/w176-stage3-context.XXXXXX")
BUILD_ONE=$(mktemp -d "$SCRIPT_DIR/.build-one.XXXXXX")
BUILD_TWO=$(mktemp -d "$SCRIPT_DIR/.build-two.XXXXXX")
cleanup() {
    rm -rf "$CONTEXT" "$BUILD_ONE" "$BUILD_TWO"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$CONTEXT/toolchain"
tar -xJf "$ARCHIVE" -C "$CONTEXT/toolchain"
cp "$SCRIPT_DIR/Dockerfile" "$CONTEXT/Dockerfile"
docker build --platform linux/arm64 --tag "$IMAGE" "$CONTEXT"

build_once() {
    BUILD_OUTPUT=$1
    docker run --rm --platform linux/arm64 \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=$SCRIPT_DIR,dst=/src,readonly" \
        --mount "type=bind,src=$BUILD_OUTPUT,dst=/out" \
        "$IMAGE" \
        /bin/sh /src/container-build.sh /out/arm_probe
}

build_once "$BUILD_ONE"
build_once "$BUILD_TWO"
HASH_ONE=$(sha256sum "$BUILD_ONE/arm_probe" | sed 's/[[:space:]].*$//')
HASH_TWO=$(sha256sum "$BUILD_TWO/arm_probe" | sed 's/[[:space:]].*$//')
[ "$HASH_ONE" = "$HASH_TWO" ] || {
    printf '%s\n' "clean rebuild hashes differ: $HASH_ONE $HASH_TWO" >&2
    exit 1
}

OUTPUT_DIR=$(dirname "$OUTPUT")
mkdir -p "$OUTPUT_DIR"
cp "$BUILD_ONE/arm_probe" "$OUTPUT"
printf '%s\n' "toolchain.sha256=$TOOLCHAIN_SHA256"
printf '%s\n' "base.image=$BASE_IMAGE"
printf '%s\n' "binary.sha256=$HASH_ONE"
