#!/bin/sh
# Run ONLY inside a disposable privileged Linux container with a FAT16 image
# supplied on stdin. Container mounts/devices are isolated from the host.
set -eu
ROOT=/tmp/stage4b-native-usb
IMAGE=/tmp/stage4b-native-fat.img
SYSROOT=/tmp/stage4b-native-sys/block
GUARD=/tmp/stage4b-native-guard.sh
SOURCE=/dev/sdz9
LOOP=
CREATED_NODE=0
cleanup() {
    cd /tmp || :
    umount "$ROOT/stage4b-capability" 2>/dev/null || :
    umount "$ROOT" 2>/dev/null || :
    umount "$ROOT" 2>/dev/null || :
    [ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null || :
    [ "$CREATED_NODE" -eq 0 ] || rm -f "$SOURCE"
}
trap cleanup EXIT INT TERM
dd of="$IMAGE" bs=1M status=none
mkdir -p "$ROOT" "$SYSROOT/sdz"
printf '1\n' > "$SYSROOT/sdz/removable"
[ ! -e "$SOURCE" ] || exit 1
LOOP=$(losetup --find --show "$IMAGE")
MAJOR_HEX=$(stat -c '%t' "$LOOP")
MINOR_HEX=$(stat -c '%T' "$LOOP")
MAJOR=$(printf '%d' "0x$MAJOR_HEX")
MINOR=$(printf '%d' "0x$MINOR_HEX")
mknod "$SOURCE" b "$MAJOR" "$MINOR"
CREATED_NODE=1
mount -t vfat "$SOURCE" "$ROOT"
sed "s@SYS_BLOCK_ROOT=/sys/block@SYS_BLOCK_ROOT=$SYSROOT@" \
    /src/tools/w176-stage4b-capability-probe/payload/mount_guard.sh > "$GUARD"
cd "$ROOT"
[ "$(/bin/sh "$GUARD" .)" = "$ROOT" ]
printf 'native FAT effective mount: PASS\n'

mount -t tmpfs tmpfs "$ROOT"
cd "$ROOT"
if /bin/sh "$GUARD" . >/dev/null 2>&1; then exit 1; fi
printf 'native exact stacked tmpfs: REJECT\n'
cd /tmp
umount "$ROOT"
mkdir "$ROOT/stage4b-capability"
mount -t tmpfs tmpfs "$ROOT/stage4b-capability"
cd "$ROOT"
if /bin/sh "$GUARD" . >/dev/null 2>&1; then exit 1; fi
printf 'native deeper covering tmpfs: REJECT\n'
cd /tmp
umount "$ROOT/stage4b-capability"
umount "$ROOT"
