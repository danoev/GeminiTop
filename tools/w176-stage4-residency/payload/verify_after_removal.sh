#!/bin/sh
# Read-only target verification after the operator has removed and reinserted
# the installer USB. Writes evidence only to validated removable USB.
set -u

[ "$#" -eq 1 ] || exit 1
REQUESTED_ROOT=$1
SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
[ -f "$SCRIPT_DIR/common.sh" ] && [ ! -L "$SCRIPT_DIR/common.sh" ] || exit 1
. "$SCRIPT_DIR/common.sh"

SCOPE=w176-stage4b-verify-after-usb-removal
begin_action verify ARM_STAGE4B_VERIFY_AFTER_REMOVAL usb_removed_and_reinserted=1 stage4b-verify-after-removal "$SCOPE" "$REQUESTED_ROOT"

validate_target
TARGET_STATUS=$?
[ "$TARGET_STATUS" -eq 0 ] || { record_failure "target_validation:$TARGET_STATUS"; finish_incomplete; }
validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || { record_failure "destination_hash_mismatch"; finish_incomplete; }
validate_manifest "$DEST_MANIFEST" || { record_failure "manifest_invalid"; finish_incomplete; }

validate_install_record || { record_failure "install_transaction_invalid"; finish_incomplete; }

read_process_identity "$ORIGINAL_PID" || { record_failure "resident_process_missing"; finish_incomplete; }
[ "$PROCESS_START" = "$ORIGINAL_START" ] && [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || { record_failure "resident_process_identity_changed"; finish_incomplete; }
validate_process_detached_from_usb "$ORIGINAL_PID" || { record_failure "resident_process_retains_usb_reference"; finish_incomplete; }
validate_heartbeat "$ORIGINAL_PID" || { record_failure "heartbeat_invalid"; finish_incomplete; }
SEQUENCE_ONE=$HEARTBEAT_SEQUENCE
[ "$SEQUENCE_ONE" -gt "$ORIGINAL_SEQUENCE" ] || { record_failure "heartbeat_not_advanced_after_removal"; finish_incomplete; }
sleep 3 || { record_failure "heartbeat_wait_failed"; finish_incomplete; }
read_process_identity "$ORIGINAL_PID" || { record_failure "resident_process_disappeared"; finish_incomplete; }
[ "$PROCESS_START" = "$ORIGINAL_START" ] && [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || { record_failure "resident_process_identity_changed_after_wait"; finish_incomplete; }
validate_process_detached_from_usb "$ORIGINAL_PID" || { record_failure "resident_process_usb_reference_after_wait"; finish_incomplete; }
validate_heartbeat "$ORIGINAL_PID" || { record_failure "heartbeat_invalid_after_wait"; finish_incomplete; }
SEQUENCE_TWO=$HEARTBEAT_SEQUENCE
[ "$SEQUENCE_TWO" -gt "$SEQUENCE_ONE" ] || { record_failure "heartbeat_did_not_continue"; finish_incomplete; }

printf '%s\n' \
    "schema=1" \
    "result=PASS" \
    "operator_marker.usb_removed_and_reinserted=1" \
    "pid=$ORIGINAL_PID" \
    "start_time=$ORIGINAL_START" \
    "exe=$DEST_BINARY" \
    "cwd=/tmp" \
    "usb_fd_references=0" \
    "initial_sequence=$ORIGINAL_SEQUENCE" \
    "reinsert_sequence=$SEQUENCE_ONE" \
    "continued_sequence=$SEQUENCE_TWO" \
    "destination_sha256=$EXPECTED_BINARY_SHA256" > RESULT.txt || { record_failure "result_write_failed"; finish_incomplete; }
finish_complete
