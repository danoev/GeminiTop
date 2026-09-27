#!/bin/sh
# Separately armed exact-allowlist Stage-4B uninstall/recovery payload.
set -u

[ "$#" -eq 1 ] || exit 1
REQUESTED_ROOT=$1
SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
[ -f "$SCRIPT_DIR/common.sh" ] && [ ! -L "$SCRIPT_DIR/common.sh" ] || exit 1
. "$SCRIPT_DIR/common.sh"

SCOPE=w176-stage4b-residency-uninstall
begin_action uninstall ARM_STAGE4B_UNINSTALL stage4b_uninstall=1 stage4b-uninstall "$SCOPE" "$REQUESTED_ROOT"

validate_target
TARGET_STATUS=$?
[ "$TARGET_STATUS" -eq 0 ] || { record_failure "target_validation:$TARGET_STATUS"; finish_incomplete; }
[ -d "$INSTALL_PARENT" ] && [ ! -L "$INSTALL_PARENT" ] || { record_failure "install_parent_missing_or_invalid"; finish_incomplete; }
[ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ] || { record_failure "install_directory_missing_or_invalid"; finish_incomplete; }

PARENT_ENTRIES=0
for ENTRY in "$INSTALL_PARENT"/* "$INSTALL_PARENT"/.[!.]* "$INSTALL_PARENT"/..?*; do
    [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || continue
    PARENT_ENTRIES=$((PARENT_ENTRIES + 1))
    [ "$ENTRY" = "$INSTALL_DIR" ] || { record_failure "unexpected_parent_entry:${ENTRY##*/}"; finish_incomplete; }
done
[ "$PARENT_ENTRIES" -eq 1 ] || { record_failure "unexpected_parent_entry_count"; finish_incomplete; }

INSTALL_ENTRIES=0
for ENTRY in "$INSTALL_DIR"/* "$INSTALL_DIR"/.[!.]* "$INSTALL_DIR"/..?*; do
    [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || continue
    INSTALL_ENTRIES=$((INSTALL_ENTRIES + 1))
    case "$ENTRY" in "$DEST_BINARY"|"$DEST_MANIFEST") ;; *) record_failure "unexpected_install_entry:${ENTRY##*/}"; finish_incomplete ;; esac
done
[ "$INSTALL_ENTRIES" -eq 2 ] || { record_failure "unexpected_install_entry_count"; finish_incomplete; }
validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || { record_failure "destination_hash_mismatch"; finish_incomplete; }
validate_manifest "$DEST_MANIFEST" || { record_failure "manifest_invalid"; finish_incomplete; }

MATCHED_PID=
MATCHED_START=
PROCESS_COUNT=0
MATCH_COUNT=0
for PROCESS_DIR in "$PROCESS_ROOT"/[0-9]*; do
    [ -d "$PROCESS_DIR" ] || continue
    PROCESS_COUNT=$((PROCESS_COUNT + 1))
    [ "$PROCESS_COUNT" -le "$MAX_PROCESSES" ] || { record_failure "process_limit"; finish_incomplete; }
    CANDIDATE_PID=${PROCESS_DIR##*/}
    CANDIDATE_EXE=$(readlink "$PROCESS_DIR/exe" 2>/dev/null) || continue
    [ "$CANDIDATE_EXE" = "$DEST_BINARY" ] || continue
    read_process_identity "$CANDIDATE_PID" || { record_failure "matched_process_identity_race:$CANDIDATE_PID"; finish_incomplete; }
    [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || { record_failure "matched_process_exe_race:$CANDIDATE_PID"; finish_incomplete; }
    MATCH_COUNT=$((MATCH_COUNT + 1))
    [ "$MATCH_COUNT" -le 1 ] || { record_failure "multiple_matching_processes"; finish_incomplete; }
    MATCHED_PID=$CANDIDATE_PID
    MATCHED_START=$PROCESS_START
done

if [ "$MATCH_COUNT" -eq 1 ]; then
    validate_process_detached_from_usb "$MATCHED_PID" || { record_failure "process_usb_reference"; finish_incomplete; }
    validate_heartbeat "$MATCHED_PID" || { record_failure "running_heartbeat_invalid"; finish_incomplete; }
    kill -TERM "$MATCHED_PID" 2>/dev/null || { record_failure "term_failed"; finish_incomplete; }
    STOPPED=0
    STOP_POLLS=0
    while [ "$STOP_POLLS" -lt 5 ]; do
        sleep 1 || { record_failure "term_wait_failed"; finish_incomplete; }
        if ! read_process_identity "$MATCHED_PID"; then STOPPED=1; break; fi
        if [ "$PROCESS_START" != "$MATCHED_START" ]; then STOPPED=1; break; fi
        STOP_POLLS=$((STOP_POLLS + 1))
    done
    [ "$STOPPED" -eq 1 ] || { record_failure "process_did_not_terminate"; finish_incomplete; }
fi

if [ -e "$HEARTBEAT_TEMP" ] || [ -L "$HEARTBEAT_TEMP" ]; then
    record_failure "heartbeat_temp_remains"
    finish_incomplete
fi
if [ -e "$HEARTBEAT" ] || [ -L "$HEARTBEAT" ]; then
    is_regular_nonsymlink "$HEARTBEAT" || { record_failure "heartbeat_invalid_object"; finish_incomplete; }
    [ "$(stat -L -c '%s' "$HEARTBEAT" 2>/dev/null)" -le 512 ] || { record_failure "heartbeat_oversized"; finish_incomplete; }
    awk -F= -v hash="$EXPECTED_BINARY_SHA256" '
        $1=="schema"&&$2=="1"{schema++}
        $1=="process"&&$2=="geminitop-proofd"{process++}
        $1=="binary_sha256"&&$2==hash{found_hash++}
        END{exit !(schema==1&&process==1&&found_hash==1)}
    ' "$HEARTBEAT" >/dev/null 2>&1 || { record_failure "heartbeat_ownership_unverified"; finish_incomplete; }
fi

validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || { record_failure "destination_changed_before_remove"; finish_incomplete; }
validate_manifest "$DEST_MANIFEST" || { record_failure "manifest_changed_before_remove"; finish_incomplete; }
[ ! -e "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || rm -f "$HEARTBEAT" || { record_failure "heartbeat_remove_failed"; finish_incomplete; }
rm -f "$DEST_MANIFEST" || { record_failure "manifest_remove_failed"; finish_incomplete; }
rm -f "$DEST_BINARY" || { record_failure "binary_remove_failed"; finish_incomplete; }
rmdir "$INSTALL_DIR" || { record_failure "install_directory_not_empty"; finish_incomplete; }
rmdir "$INSTALL_PARENT" || { record_failure "install_parent_not_empty"; finish_incomplete; }

printf '%s\n' \
    "schema=1" \
    "result=PASS" \
    "matched_processes=$MATCH_COUNT" \
    "term_used=$MATCH_COUNT" \
    "kill_used=0" \
    "removed.binary=$DEST_BINARY" \
    "removed.manifest=$DEST_MANIFEST" \
    "removed.install_directory=$INSTALL_DIR" \
    "removed.parent_directory=$INSTALL_PARENT" \
    "stock_files_modified=0" > RESULT.txt || { record_failure "result_write_failed"; finish_incomplete; }
finish_complete
