#!/bin/sh
# Privileged metadata-only block-node fixture. Never opens the device node.
set -eu

WORK=$(mktemp -d /tmp/w176-stage4b-mtd.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
. /src/payload/common.sh

EXPECTED_NVM_SOURCE=$WORK/mtdblock12
SYS_BLOCK_CLASS=$WORK/sys/class/block/mtdblock12
SYS_DEV_BLOCK_ROOT=$WORK/sys/dev/block
SYS_MTD_CLASS=$WORK/sys/class/mtd/mtd12
mkdir -p "$SYS_BLOCK_CLASS" "$SYS_DEV_BLOCK_ROOT" "$SYS_MTD_CLASS" "$WORK/other-block"
mknod "$EXPECTED_NVM_SOURCE" b 7 12
printf '7:12\n' > "$SYS_BLOCK_CLASS/dev"
printf 'nvm\n' > "$SYS_MTD_CLASS/name"
printf '8388608\n' > "$SYS_MTD_CLASS/size"
ln -s "$SYS_BLOCK_CLASS" "$SYS_DEV_BLOCK_ROOT/7:12"

reject() { if validate_mtd_binding; then exit 1; fi; }
validate_mtd_binding
printf 'PASS real_block_special_major_minor_sysfs_binding\n'

printf '7:13\n' > "$SYS_BLOCK_CLASS/dev"
reject
printf '7:12\n' > "$SYS_BLOCK_CLASS/dev"
printf 'PASS real_block_special_wrong_minor_rejected\n'

rm "$SYS_DEV_BLOCK_ROOT/7:12"
ln -s "$WORK/other-block" "$SYS_DEV_BLOCK_ROOT/7:12"
reject
rm "$SYS_DEV_BLOCK_ROOT/7:12"
ln -s "$SYS_BLOCK_CLASS" "$SYS_DEV_BLOCK_ROOT/7:12"
printf 'PASS real_block_special_wrong_sysfs_object_rejected\n'

printf 'userdata\n' > "$SYS_MTD_CLASS/name"
reject
printf 'nvm\n' > "$SYS_MTD_CLASS/name"
printf 'PASS real_block_special_wrong_mtd_name_rejected\n'

printf '8388609\n' > "$SYS_MTD_CLASS/size"
reject
printf '8388608\n' > "$SYS_MTD_CLASS/size"
printf 'PASS real_block_special_wrong_mtd_size_rejected\n'

mv "$EXPECTED_NVM_SOURCE" "$WORK/real-block"
ln -s "$WORK/real-block" "$EXPECTED_NVM_SOURCE"
reject
rm "$EXPECTED_NVM_SOURCE"
printf 'PASS real_block_special_symlink_node_rejected\n'

printf 'fixture\n' > "$EXPECTED_NVM_SOURCE"
reject
printf 'PASS real_block_special_regular_node_rejected\n'

printf 'schema=1\nresult=PASS\nblock_binding_cases=7\n'
