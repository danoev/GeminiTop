#!/bin/sh

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MOUNTS_FILE=/proc/mounts
SYS_BLOCK_ROOT=/sys/block
DEV_ROOT=/dev
DEVICE_TEST=-b
export PATH

fail() { printf '%s\n' "w176-stage4b: USB validation failed: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail "exactly one USB root is required"
REQUESTED_ROOT=$1
[ -n "$REQUESTED_ROOT" ] && [ -d "$REQUESTED_ROOT" ] || fail "invalid USB root"
[ -r "$MOUNTS_FILE" ] || fail "mount table unavailable"
[ . -ef . ] 2>/dev/null || fail "anchored identity test unavailable"
for COMMAND in awk pwd sed; do command -v "$COMMAND" >/dev/null 2>&1 || fail "missing $COMMAND"; done

CANONICAL_ROOT=$(cd -P "$REQUESTED_ROOT" 2>/dev/null && pwd -P) || fail "cannot canonicalize USB root"
[ "$REQUESTED_ROOT" -ef "$CANONICAL_ROOT" ] 2>/dev/null || fail "root identity changed"
RECORDS=$(awk '$1 ~ /^\/dev\/sd[a-z]+[0-9]+$/ { print $1 "|" $2 "|" $3 "|" $4 }' "$MOUNTS_FILE") || fail "cannot read mounts"
COUNT=0
OLD_IFS=$IFS
IFS='
'
for RECORD in $RECORDS; do
    DEVICE=${RECORD%%|*}; REST=${RECORD#*|}; MOUNT=${REST%%|*}; REST=${REST#*|}; FSTYPE=${REST%%|*}; OPTIONS=${REST#*|}
    NAME=${DEVICE#/dev/}; DISK=$(printf '%s\n' "$NAME" | sed 's/[0-9][0-9]*$//'); PART=${NAME#"$DISK"}
    case "$DISK" in sd[a-z]*) ;; *) continue ;; esac
    case "$PART" in ''|*[!0-9]*) continue ;; esac
    [ -r "$SYS_BLOCK_ROOT/$DISK/removable" ] || continue
    [ "$(awk 'NR == 1 { print $1; exit }' "$SYS_BLOCK_ROOT/$DISK/removable" 2>/dev/null)" = 1 ] || continue
    if [ "$DEVICE_TEST" = -b ]; then [ -b "$DEV_ROOT/$NAME" ] || continue; else [ -e "$DEV_ROOT/$NAME" ] || continue; fi
    COUNT=$((COUNT + 1)); FOUND_MOUNT=$MOUNT; FOUND_FSTYPE=$FSTYPE; FOUND_OPTIONS=$OPTIONS
done
IFS=$OLD_IFS
[ "$COUNT" -eq 1 ] || fail "expected one removable partition, found $COUNT"
[ "$FOUND_MOUNT" = "$CANONICAL_ROOT" ] || fail "payload is not at exact removable mount root"
case "$FOUND_FSTYPE" in vfat|msdos|fat) ;; *) fail "filesystem is not approved FAT" ;; esac
case ",$FOUND_OPTIONS," in *,rw,*) ;; *) fail "USB is not read-write" ;; esac
case ",$FOUND_OPTIONS," in *,ro,*) fail "USB reports read-only" ;; esac
case ",$FOUND_OPTIONS," in *,dirsync,*) ;; *) fail "USB lacks required dirsync option" ;; esac
[ . -ef "$FOUND_MOUNT" ] 2>/dev/null || fail "mount pathname identity changed"
printf '%s\n' "$CANONICAL_ROOT"
