#!/bin/sh
# Host-only Stage-4B safety matrix. Never executes the target ARMHF ELF.
set -eu

CDPATH=
export CDPATH
SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd -P)
WORK=$(mktemp -d /tmp/w176-stage4b-matrix.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

if ! "$SCRIPT_DIR/test_linux.sh" > "$WORK/linux.log" 2>&1; then
    sed -n '1,240p' "$WORK/linux.log"
    exit 1
fi

for TEST_NAME in test_linux_real_mounts.sh test_linux_mtd_binding.sh; do
    if ! docker run --rm --privileged --platform linux/arm64 \
        --mount "type=bind,src=$SCRIPT_DIR,dst=/src,readonly" \
        geminitop-w176-topology-test:round2 \
        /bin/sh "/src/$TEST_NAME" > "$WORK/$TEST_NAME.log" 2>&1; then
        sed -n '1,240p' "$WORK/$TEST_NAME.log"
        exit 1
    fi
done

sed -n '1,240p' "$WORK/linux.log"
sed -n '1,120p' "$WORK/test_linux_real_mounts.sh.log"
sed -n '1,120p' "$WORK/test_linux_mtd_binding.sh.log"
python3 "$SCRIPT_DIR/verify_matrix.py" \
    --log "$WORK/linux.log" \
    --log "$WORK/test_linux_real_mounts.sh.log" \
    --log "$WORK/test_linux_mtd_binding.sh.log"
python3 "$SCRIPT_DIR/verify_recovery_states.py" --log "$WORK/linux.log"
