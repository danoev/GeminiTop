#!/bin/sh
# Validate one exact, removable FAT filesystem mount. Prints its canonical root.

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

fail() {
    printf '%s\n' "w176-stage2: mount validation failed: $1" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "exactly one USB root is required"
REQUESTED_ROOT=$1
[ -n "$REQUESTED_ROOT" ] || fail "USB root is empty"
[ -d "$REQUESTED_ROOT" ] || fail "USB root is not a directory"
[ -r "$MOUNTS_FILE" ] || fail "mount table is unavailable"
[ . -ef . ] 2>/dev/null || fail "shell lacks required anchored-identity test"

for REQUIRED_COMMAND in awk dirname pwd sed; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || fail "missing command: $REQUIRED_COMMAND"
done

CANONICAL_ROOT=$(cd -P "$REQUESTED_ROOT" 2>/dev/null && pwd -P) || fail "cannot canonicalize USB root"
[ -n "$CANONICAL_ROOT" ] || fail "canonical USB root is empty"
[ "$REQUESTED_ROOT" -ef "$CANONICAL_ROOT" ] 2>/dev/null ||
    fail "anchored directory no longer matches its mount pathname"

MOUNT_RECORDS=$(awk '$1 ~ /^\/dev\/sd[a-z]+[0-9]+$/ { print $1 "|" $2 "|" $3 }' "$MOUNTS_FILE") || fail "cannot read mount table"
CANDIDATE_COUNT=0
CANDIDATE_DEVICE=
CANDIDATE_MOUNT=
CANDIDATE_FSTYPE=

OLD_IFS=$IFS
IFS='
'
for RECORD in $MOUNT_RECORDS; do
    DEVICE=${RECORD%%|*}
    REST=${RECORD#*|}
    MOUNT_POINT=${REST%%|*}
    FSTYPE=${REST#*|}
    DEVICE_NAME=${DEVICE#/dev/}
    DISK_NAME=$(printf '%s\n' "$DEVICE_NAME" | sed 's/[0-9][0-9]*$//')
    PARTITION=${DEVICE_NAME#"$DISK_NAME"}
    case "$DISK_NAME" in
        sd[a-z]*) ;;
        *) continue ;;
    esac
    case "$PARTITION" in
        ''|*[!0-9]*) continue ;;
    esac
    REMOVABLE_FILE="$SYS_BLOCK_ROOT/$DISK_NAME/removable"
    [ -r "$REMOVABLE_FILE" ] || continue
    REMOVABLE=$(awk 'NR == 1 { print $1; exit }' "$REMOVABLE_FILE" 2>/dev/null)
    [ "$REMOVABLE" = "1" ] || continue
    DEVICE_PATH="$DEV_ROOT/$DEVICE_NAME"
    if [ "$DEVICE_TEST" = "-b" ]; then
        [ -b "$DEVICE_PATH" ] || continue
    else
        [ -e "$DEVICE_PATH" ] || continue
    fi
    CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
    CANDIDATE_DEVICE=$DEVICE
    CANDIDATE_MOUNT=$MOUNT_POINT
    CANDIDATE_FSTYPE=$FSTYPE
done
IFS=$OLD_IFS

[ "$CANDIDATE_COUNT" -eq 1 ] || fail "expected one removable /dev/sd partition mount, found $CANDIDATE_COUNT"
[ "$CANDIDATE_MOUNT" = "$CANONICAL_ROOT" ] || fail "script directory is not the exact removable mount point"
case "$CANDIDATE_FSTYPE" in
    vfat|msdos|fat) ;;
    *) fail "filesystem $CANDIDATE_FSTYPE is not approved" ;;
esac

# This is the final validation operation. If the namespace path was rebound or
# detached before validation completed, the open working directory and a fresh
# lookup of the mount pathname no longer name the same filesystem object.
[ . -ef "$CANDIDATE_MOUNT" ] 2>/dev/null ||
    fail "validated mount pathname no longer names the anchored directory"

printf '%s\n' "$CANONICAL_ROOT"
