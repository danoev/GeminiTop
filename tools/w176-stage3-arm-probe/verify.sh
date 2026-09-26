#!/bin/sh
set -eu

CDPATH=
export CDPATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd -P)
BINARY=${1:-"$SCRIPT_DIR/payload/arm_probe"}
EXPECTED_SHA256=662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789
EXPECTED_SIZE=5556
IMAGE=geminitop-w176-stage3-toolchain:9.2-2019.12-arm64

for REQUIRED_COMMAND in docker file grep sed sha256sum sort stat; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || {
        printf '%s\n' "missing command: $REQUIRED_COMMAND" >&2
        exit 1
    }
done
[ -f "$BINARY" ] && [ ! -L "$BINARY" ] || exit 1
[ "$(sha256sum "$BINARY" | sed 's/[[:space:]].*$//')" = "$EXPECTED_SHA256" ] || exit 1
[ "$(stat -f '%z' "$BINARY" 2>/dev/null || stat -c '%s' "$BINARY")" = "$EXPECTED_SIZE" ] || exit 1
file "$BINARY" | grep -F 'ELF 32-bit LSB executable, ARM, EABI5' >/dev/null
docker image inspect "$IMAGE" >/dev/null

inspect() {
    docker run --rm --platform linux/arm64 \
        --mount "type=bind,src=$SCRIPT_DIR,dst=/src,readonly" \
        "$IMAGE" "$@"
}

HEADER=$(inspect arm-none-linux-gnueabihf-readelf -h /src/payload/arm_probe)
ATTRIBUTES=$(inspect arm-none-linux-gnueabihf-readelf -A /src/payload/arm_probe)
PROGRAMS=$(inspect arm-none-linux-gnueabihf-readelf -l /src/payload/arm_probe)
DYNAMIC=$(inspect arm-none-linux-gnueabihf-readelf -d /src/payload/arm_probe)
VERSIONS=$(inspect arm-none-linux-gnueabihf-readelf -V /src/payload/arm_probe)
SYMBOLS=$(inspect arm-none-linux-gnueabihf-readelf -Ws /src/payload/arm_probe)
OBJDUMP_PRIVATE=$(inspect arm-none-linux-gnueabihf-objdump -p /src/payload/arm_probe)
OBJDUMP_DYNAMIC=$(inspect arm-none-linux-gnueabihf-objdump -T /src/payload/arm_probe)
STRINGS=$(inspect arm-none-linux-gnueabihf-strings -a /src/payload/arm_probe)

printf '%s\n' "$HEADER" | grep -F 'Class:                             ELF32' >/dev/null
printf '%s\n' "$HEADER" | grep -F "Data:                              2's complement, little endian" >/dev/null
printf '%s\n' "$HEADER" | grep -F 'Machine:                           ARM' >/dev/null
printf '%s\n' "$HEADER" | grep -F 'Flags:                             0x5000400, Version5 EABI, hard-float ABI' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_CPU_arch: v7' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_CPU_arch_profile: Application' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_ARM_ISA_use: Yes' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_THUMB_ISA_use: Thumb-2' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_FP_arch: VFPv3' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_Advanced_SIMD_arch: NEONv1' >/dev/null
printf '%s\n' "$ATTRIBUTES" | grep -F 'Tag_ABI_VFP_args: VFP registers' >/dev/null
printf '%s\n' "$PROGRAMS" | grep -F '[Requesting program interpreter: /lib/ld-linux-armhf.so.3]' >/dev/null

[ "$(printf '%s\n' "$DYNAMIC" | grep -c '(NEEDED)')" -eq 1 ]
printf '%s\n' "$DYNAMIC" | grep -F 'Shared library: [libc.so.6]' >/dev/null
if printf '%s\n' "$DYNAMIC" | grep -E '(RPATH|RUNPATH)' >/dev/null; then exit 1; fi
[ "$(printf '%s\n' "$VERSIONS" | grep -o 'Name: [A-Z][A-Z0-9_.]*' | sort -u)" = 'Name: GLIBC_2.4' ]
printf '%s\n' "$OBJDUMP_PRIVATE" | grep -F 'private flags = 5000400: [Version5 EABI] [hard-float ABI]' >/dev/null
[ "$(printf '%s\n' "$OBJDUMP_PRIVATE" | grep -c 'NEEDED')" -eq 1 ]
printf '%s\n' "$OBJDUMP_PRIVATE" | grep -F 'NEEDED               libc.so.6' >/dev/null
if printf '%s\n' "$OBJDUMP_PRIVATE" | grep -E '(RPATH|RUNPATH)' >/dev/null; then exit 1; fi

for IMPORT in '__gmon_start__' 'write@GLIBC_2.4' 'abort@GLIBC_2.4' '__libc_start_main@GLIBC_2.4'; do
    printf '%s\n' "$SYMBOLS" | grep -F "UND $IMPORT" >/dev/null
done
[ "$(printf '%s\n' "$SYMBOLS" | grep -c ' UND ')" -eq 5 ]
[ "$(printf '%s\n' "$OBJDUMP_DYNAMIC" | grep -c '\*UND\*')" -eq 4 ]
for IMPORT in '__gmon_start__' 'GLIBC_2.4   write' 'GLIBC_2.4   abort' 'GLIBC_2.4   __libc_start_main'; do
    printf '%s\n' "$OBJDUMP_DYNAMIC" | grep -F "$IMPORT" >/dev/null
done

printf '%s\n' "$STRINGS" | grep -F 'schema=1' >/dev/null
printf '%s\n' "$STRINGS" | grep -F 'probe=w176-arm-loadability' >/dev/null
printf '%s\n' "$STRINGS" | grep -F 'result=PASS' >/dev/null
if printf '%s\n' "$STRINGS" | grep -E '(/dev/|/media/|/proc/|/sys/|socket|connect|mount|Launcher)' >/dev/null; then
    exit 1
fi

printf '%s\n' "static ABI verification: PASS"
