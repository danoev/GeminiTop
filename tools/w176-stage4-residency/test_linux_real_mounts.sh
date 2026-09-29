#!/bin/sh
# Privileged disposable Linux test of the production mount-selection function.
# A test-only copy changes the required base filesystem literal from yaffs2 to
# tmpfs; no production validator or target filesystem is modified.
set -eu

WORK=$(mktemp -d /tmp/w176-stage4b-mounts.XXXXXX)
BASE=$WORK/nvm
NESTED=$BASE/geminitop
SIBLING=$WORK/nvm2
EXTERNAL=$WORK/external
cleanup() {
    for MOUNTPOINT in "$NESTED" "$SIBLING" "$EXTERNAL"; do
        if mountpoint -q "$MOUNTPOINT"; then umount "$MOUNTPOINT" 2>/dev/null || true; fi
    done
    while mountpoint -q "$BASE"; do umount "$BASE" 2>/dev/null || break; done
    if ! mountpoint -q "$BASE" && ! mountpoint -q "$NESTED" &&
        ! mountpoint -q "$SIBLING" && ! mountpoint -q "$EXTERNAL"; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$BASE" "$SIBLING" "$EXTERNAL"
cp /src/payload/common.sh "$WORK/common.sh"
sed -i 's/fs!="yaffs2"/fs!="tmpfs"/; s/fs=="yaffs2"/fs=="tmpfs"/' "$WORK/common.sh"
[ "$(grep -c 'fs!="tmpfs"' "$WORK/common.sh")" -eq 1 ]
[ "$(grep -c 'fs=="tmpfs"' "$WORK/common.sh")" -eq 1 ]
. "$WORK/common.sh"

mount -t tmpfs -o rw tmpfs "$BASE"
NVM_ROOT=$BASE
EXPECTED_NVM_CANONICAL=$BASE
EXPECTED_NVM_SOURCE=tmpfs
NVM_ST_DEV=$(stat -c '%d' "$BASE")
MOUNTS_FILE=/proc/self/mounts
MOUNTINFO_FILE=/proc/self/mountinfo
INSTALL_PARENT=$NVM_ROOT/geminitop
INSTALL_DIR=$INSTALL_PARENT/w176
STAGE_DIR=$INSTALL_PARENT/.w176-stage4b-installing
DEST_BINARY=$INSTALL_DIR/geminitop-proofd
DEST_MANIFEST=$INSTALL_DIR/manifest.txt
NVM_RECORD=$(awk -v mountpoint="$BASE" '
    $2==mountpoint { found++; record=$1 "|" $2 "|" $3 "|" $4 }
    END { if (found==1) print record; else exit 1 }
' "$MOUNTS_FILE")
valid() { validate_nvm_path "$INSTALL_DIR"; }
reject() { if validate_nvm_path "$INSTALL_DIR"; then exit 1; fi; }
pass() { printf 'PASS %s\n' "$1"; }

valid
pass real_mount_valid_expected_only

mount -t tmpfs -o rw tmpfs "$SIBLING"
valid
umount "$SIBLING"
pass real_mount_sibling_nvm2_does_not_cover

mkdir "$NESTED"
mount -t tmpfs -o rw tmpfs "$NESTED"
reject
umount "$NESTED"
pass real_mount_nested_tmpfs_rw_rejected

truncate -s 16M "$WORK/ext4.img"
mkfs.ext4 -F -q "$WORK/ext4.img"
mount -t ext4 -o loop,ro "$WORK/ext4.img" "$NESTED"
reject
umount "$NESTED"
pass real_mount_nested_ext4_ro_rejected

mount -t tmpfs -o rw tmpfs "$NESTED"
reject
umount "$NESTED"
pass real_mount_nested_same_fstype_rejected

mount -t tmpfs -o rw tmpfs "$EXTERNAL"
mount --bind "$EXTERNAL" "$NESTED"
reject
umount "$NESTED"
umount "$EXTERNAL"
pass real_mount_external_bind_rejected

mkdir "$BASE/other"
mount --bind "$BASE/other" "$NESTED"
[ "$(stat -c '%d' "$NESTED")" = "$NVM_ST_DEV" ]
reject
umount "$NESTED"
pass real_mount_same_device_bind_rejected

EXPECTED_NVM_SOURCE=not-the-mounted-source
reject
EXPECTED_NVM_SOURCE=tmpfs
pass real_mount_source_mismatch_rejected

mount -t tmpfs -o rw tmpfs "$BASE"
reject
umount "$BASE"
pass real_mount_duplicate_base_records_rejected

cp "$MOUNTS_FILE" "$WORK/mounts-malformed"
printf 'malformed\n' >> "$WORK/mounts-malformed"
MOUNTS_FILE=$WORK/mounts-malformed
reject
pass real_mount_malformed_table_rejected

printf 'schema=1\nresult=PASS\nreal_mount_cases=10\n'
