#!/bin/sh
# Disposable privileged native Linux container only. No ARM execution.
set -eu
GUARD=/repo/tools/w176-stage4-topology/payload/library_mount_guard.sh
WORK=$(mktemp -d /tmp/w176-topology-mount.XXXXXX)
APP="$WORK/application"
mkdir -p "$WORK/source/lib" "$APP"
printf 'host fixture only\n' > "$WORK/source/lib/libappframework.so.1.0.0"
mkdir "$WORK/source/lib2"
mksquashfs "$WORK/source" "$WORK/app.sqfs" -noappend -processors 1 >/dev/null
mount -t squashfs -o loop,ro "$WORK/app.sqfs" "$APP"
cleanup() {
    umount "$APP/lib" 2>/dev/null || true
    umount "$APP/lib2" 2>/dev/null || true
    umount "$APP" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
SOURCE="$APP/lib/libappframework.so.1.0.0"
[ -L /proc/mounts ] && [ -f /proc/self/mounts ]
/bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null
printf 'PASS real_proc_self_mounts_and_squashfs\n'
/bin/sh "$GUARD" "$SOURCE" "$APP" /proc/mounts >/dev/null
printf 'PASS normal_proc_mounts_symlink\n'
mount -t tmpfs tmpfs "$APP/lib2"
/bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null
umount "$APP/lib2"
printf 'PASS unrelated_component_boundary_nested_mount\n'
mount -t tmpfs tmpfs "$APP/lib"
printf 'mutable fixture\n' > "$SOURCE"
if /bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null; then exit 1; fi
printf 'PASS real_nested_tmpfs_rejected\n'
mount -o remount,ro "$APP/lib"
if /bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null; then exit 1; fi
printf 'PASS real_nested_readonly_mount_rejected\n'
umount "$APP/lib"
mount --bind "$APP/lib" "$APP/lib"
if /bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null; then exit 1; fi
printf 'PASS nested_same_device_bind_mount_rejected\n'
umount "$APP/lib"
/bin/sh "$GUARD" "$SOURCE" "$APP" /proc/self/mounts >/dev/null
printf 'PASS restored_mount_topology\n'
# Real sysfs class links are metadata only; no device stream access.
for ENTRY in /sys/class/net/*; do
    [ -L "$ENTRY" ] || continue
    RESOLVED=$(cd -P "$ENTRY" && pwd -P)
    case "$RESOLVED/" in /sys/devices/*) ;; *) exit 1 ;; esac
    [ -f "$RESOLVED/type" ]
done
printf 'PASS real_sysfs_class_link_layout\n'
