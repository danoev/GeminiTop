#!/bin/sh
# Separately armed Stage-4B installer. The only persistent target writes are
# the dedicated GeminiTop directory, proof binary, and manifest.
set -u

[ "$#" -eq 1 ] || exit 1
REQUESTED_ROOT=$1
SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
[ -f "$SCRIPT_DIR/common.sh" ] && [ ! -L "$SCRIPT_DIR/common.sh" ] || exit 1
. "$SCRIPT_DIR/common.sh"

SCOPE=w176-stage4b-residency-install
begin_action install ARM_STAGE4B_INSTALL stage4b_install=1 stage4b-install "$SCOPE" "$REQUESTED_ROOT"
SOURCE_BINARY="$USB_ROOT/geminitop-proofd"
PROCESS_PID=
PROCESS_START_TIME=
PARENT_CREATED=0
STAGE_CREATED=0
INSTALL_CREATED=0

abort_install() {
    trap - HUP INT TERM
    record_failure "$1"
    if [ "$PARENT_CREATED" -eq 1 ] || [ "$STAGE_CREATED" -eq 1 ] ||
        [ "$INSTALL_CREATED" -eq 1 ] || [ -n "$PROCESS_PID" ]; then
        record_failure "manual_review_required:persistent_state_or_process_uncertain"
    fi
    # Never auto-delete NVM after the first write. An uncertain launched
    # process may still execute the destination; only a separate reviewed
    # recovery action may change persistent state.
    finish_incomplete
}

trap 'abort_install interrupted' HUP INT TERM

validate_target require_space
TARGET_STATUS=$?
[ "$TARGET_STATUS" -eq 0 ] || abort_install "target_validation:$TARGET_STATUS"
validate_hash "$SOURCE_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || abort_install "source_binary_invalid"
[ ! -e "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || abort_install "heartbeat_conflict"
[ ! -e "$HEARTBEAT_TEMP" ] && [ ! -L "$HEARTBEAT_TEMP" ] || abort_install "heartbeat_temp_conflict"
[ ! -e "$INSTALL_PARENT" ] && [ ! -L "$INSTALL_PARENT" ] || abort_install "install_parent_conflict"

printf '%s\n' \
    "schema=1" \
    "target.kernel=$EXPECTED_KERNEL_RELEASE" \
    "target.launcher_sha256=$EXPECTED_LAUNCHER_SHA256" \
    "nvm.device=$NVM_DEVICE" \
    "nvm.mount=$NVM_MOUNT" \
    "nvm.filesystem=$NVM_FSTYPE" \
    "nvm.options=$NVM_OPTIONS" \
    "nvm.size_hex=$NVM_SIZE_HEX" \
    "nvm.free_kib=$FREE_KIB" > TARGET.txt || abort_install "target_evidence_write"

mkdir "$INSTALL_PARENT" || abort_install "install_parent_create"
PARENT_CREATED=1
validate_nvm_path "$INSTALL_PARENT" || abort_install "install_parent_mount_changed"
mkdir "$STAGE_DIR" || abort_install "stage_directory_create"
STAGE_CREATED=1
validate_nvm_path "$STAGE_DIR" || abort_install "stage_mount_changed"

COPY_TEMP="$STAGE_DIR/geminitop-proofd.tmp"
validate_nvm_path "$COPY_TEMP" || abort_install "copy_destination_mount_changed"
COPY_RESULT="$OUT_DISPLAY/.copy.result"
rm -f "$COPY_RESULT" 2>/dev/null || abort_install "copy_result_prepare"
/bin/sh -c '
    SOURCE=$1; DESTINATION=$2; RESULT=$3; FD_ROOT=$4; EXPECTED_SIZE=$5
    exec 3< "$SOURCE" || exit 20
    [ -f "$FD_ROOT/3" ] && [ ! -L "$SOURCE" ] || exit 21
    BEFORE=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 22
    PATH_ID=$(stat -L -c "%d|%i" "$SOURCE") || exit 23
    case "$BEFORE" in "$PATH_ID|"*) ;; *) exit 23 ;; esac
    OLD_IFS=$IFS; IFS="|"; set -- $BEFORE; IFS=$OLD_IFS
    [ "$#" -eq 6 ] && [ "$4" = "$EXPECTED_SIZE" ] || exit 24
    BLOCKS=$((EXPECTED_SIZE / 4096)); REST=$((EXPECTED_SIZE % 4096)); : > "$DESTINATION" || exit 25
    [ "$BLOCKS" -eq 0 ] || dd bs=4096 count="$BLOCKS" <&3 > "$DESTINATION" 2>/dev/null || exit 25
    [ "$REST" -eq 0 ] || dd bs=1 count="$REST" <&3 >> "$DESTINATION" 2>/dev/null || exit 25
    AFTER=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 26
    [ "$AFTER" = "$BEFORE" ] && [ ! -L "$SOURCE" ] || exit 26
    [ "$(stat -L -c "%d|%i" "$SOURCE")" = "$PATH_ID" ] || exit 26
    [ "$(stat -L -c "%s" "$DESTINATION")" = "$EXPECTED_SIZE" ] || exit 27
    printf "copied=1\n" > "$RESULT" || exit 28
' sh "$SOURCE_BINARY" "$COPY_TEMP" "$COPY_RESULT" "$FD_ROOT" "$EXPECTED_BINARY_SIZE" || abort_install "copy_interrupted_or_source_changed"
is_regular_nonsymlink "$COPY_RESULT" && [ "$(dd if="$COPY_RESULT" bs=32 count=1 2>/dev/null)" = copied=1 ] || abort_install "copy_result_invalid"
rm -f "$COPY_RESULT" || abort_install "copy_result_cleanup"
validate_hash "$COPY_TEMP" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || abort_install "destination_temp_hash_mismatch"
chmod 755 "$COPY_TEMP" || abort_install "destination_permission_failed"
validate_nvm_path "$STAGE_DIR/geminitop-proofd" || abort_install "staged_binary_mount_changed"
mv "$COPY_TEMP" "$STAGE_DIR/geminitop-proofd" || abort_install "destination_commit_failed"

printf '%s\n' \
    "schema=1" \
    "owner=GeminiTop" \
    "target=w176-ntg5" \
    "component=geminitop-proofd" \
    "version=w176-stage4b-proofd-v1" \
    "binary_sha256=$EXPECTED_BINARY_SHA256" \
    "binary_size=$EXPECTED_BINARY_SIZE" \
    "installed_path=$DEST_BINARY" > "$STAGE_DIR/manifest.txt.tmp" || abort_install "manifest_write_failed"
chmod 444 "$STAGE_DIR/manifest.txt.tmp" || abort_install "manifest_permission_failed"
validate_nvm_path "$STAGE_DIR/manifest.txt" || abort_install "staged_manifest_mount_changed"
mv "$STAGE_DIR/manifest.txt.tmp" "$STAGE_DIR/manifest.txt" || abort_install "manifest_commit_failed"
validate_nvm_path "$INSTALL_DIR" || abort_install "final_directory_mount_changed"
mv "$STAGE_DIR" "$INSTALL_DIR" || abort_install "install_directory_commit_failed"
STAGE_CREATED=0
INSTALL_CREATED=1
validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || abort_install "destination_hash_mismatch"
validate_manifest "$DEST_MANIFEST" || abort_install "manifest_invalid"
validate_nvm_path "$DEST_BINARY" || abort_install "destination_mount_changed"
validate_nvm_path "$DEST_MANIFEST" || abort_install "manifest_mount_changed"

(cd /tmp && exec "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" </dev/null >/dev/null 2>&1) &
PROCESS_PID=$!
START_POLLS=0
PROCESS_READY=0
while [ "$START_POLLS" -lt 5 ]; do
    sleep 1 || abort_install "launch_wait_failed"
    if read_process_identity "$PROCESS_PID" && [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ]; then
        PROCESS_START_TIME=$PROCESS_START
        if validate_process_detached_from_usb "$PROCESS_PID" && validate_heartbeat "$PROCESS_PID"; then PROCESS_READY=1; break; fi
    fi
    START_POLLS=$((START_POLLS + 1))
done
[ "$PROCESS_READY" -eq 1 ] || abort_install "process_launch_or_heartbeat_failed"
INITIAL_SEQUENCE=$HEARTBEAT_SEQUENCE
validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || abort_install "running_destination_hash_mismatch"

printf '%s\n' \
    "schema=1" \
    "pid=$PROCESS_PID" \
    "start_time=$PROCESS_START_TIME" \
    "exe=$DEST_BINARY" \
    "cwd=/tmp" \
    "binary_sha256=$EXPECTED_BINARY_SHA256" \
    "heartbeat_sequence=$INITIAL_SEQUENCE" \
    "usb_fd_references=0" > PROCESS.txt || abort_install "process_evidence_write"
printf '%s\n' \
    "schema=1" \
    "result=PASS" \
    "persistent_path=$INSTALL_DIR" \
    "stock_files_modified=0" \
    "path_shadowing=0" \
    "library_shadowing=0" \
    "boot_persistence=0" \
    "can_mcu_access=0" \
    "network_access=0" > RESULT.txt || abort_install "result_evidence_write"

PARENT_CREATED=0
INSTALL_CREATED=0
trap - HUP INT TERM
finish_complete
