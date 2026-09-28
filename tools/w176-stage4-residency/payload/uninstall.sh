#!/bin/sh
# Separately armed exact-allowlist recovery. Unknown process or object state
# requires manual review; no negative inference from an unreadable /proc entry.
set -u

[ "$#" -eq 1 ] || exit 1
REQUESTED_ROOT=$1
SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
[ -f "$SCRIPT_DIR/common.sh" ] && [ ! -L "$SCRIPT_DIR/common.sh" ] || exit 1
. "$SCRIPT_DIR/common.sh"

SCOPE=w176-stage4b-residency-uninstall
begin_action uninstall ARM_STAGE4B_UNINSTALL stage4b_uninstall=1 stage4b-uninstall "$SCOPE" "$REQUESTED_ROOT"

uninstall_stop() { record_failure "$1"; finish_incomplete; }

validate_target || uninstall_stop "target_validation"
validate_install_record || uninstall_stop "install_transaction_invalid"
validate_install_inventory || uninstall_stop "install_inventory_invalid"
[ ! -e "$HEARTBEAT_TEMP" ] && [ ! -L "$HEARTBEAT_TEMP" ] || uninstall_stop "heartbeat_temp_conflict"

# Require the original exact run. After reboot or missing evidence, recovery is
# a separate manual-review problem; this action does not scan/guess a process.
read_process_identity "$ORIGINAL_PID" || uninstall_stop "original_process_uninspectable_or_not_live"
[ "$PROCESS_START" = "$ORIGINAL_START" ] &&
    [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || uninstall_stop "original_process_identity_mismatch"
validate_process_detached_from_usb "$ORIGINAL_PID" || uninstall_stop "usb_fd_coverage_unknown"
validate_heartbeat "$ORIGINAL_PID" || uninstall_stop "heartbeat_not_bound_to_live_run"
read_process_identity "$ORIGINAL_PID" || uninstall_stop "pre_term_identity_unknown"
[ "$PROCESS_START" = "$ORIGINAL_START" ] &&
    [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || uninstall_stop "pre_term_identity_changed"
validate_install_inventory || uninstall_stop "pre_term_inventory_changed"

# Final identity check immediately before TERM. No KILL fallback.
read_process_identity "$ORIGINAL_PID" || uninstall_stop "last_pre_term_identity_unknown"
[ "$PROCESS_START" = "$ORIGINAL_START" ] &&
    [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ] || uninstall_stop "last_pre_term_identity_changed"
kill -TERM "$ORIGINAL_PID" 2>/dev/null || uninstall_stop "term_failed"

STOPPED=0
STOP_POLLS=0
while [ "$STOP_POLLS" -lt 5 ]; do
    sleep 1 || uninstall_stop "term_wait_failed"
    if [ ! -d "$PROCESS_ROOT/$ORIGINAL_PID" ]; then
        STOPPED=1
        break
    fi
    # A terminal state for this exact PID/TGID/start is accepted. A reused PID,
    # an unreadable status/stat, or an unknown state is never called stopped.
    POST_STATUS=$(dd if="$PROCESS_ROOT/$ORIGINAL_PID/status" bs=1 count=16385 2>/dev/null && printf x) || uninstall_stop "post_term_status_unknown"
    POST_STATUS=${POST_STATUS%x}
    [ "${#POST_STATUS}" -le 16384 ] || uninstall_stop "post_term_status_oversized"
    POST_STATE=$(awk -v pid="$ORIGINAL_PID" '
        $1=="Pid:" {p++; if($2!=pid) bad=1}
        $1=="Tgid:" {t++; if($2!=pid) bad=1}
        $1=="State:" {s++; state=$2}
        END {if(!bad&&p==1&&t==1&&s==1&&state ~ /^[RSDTtIZXx]$/) print state; else exit 1}
    ' <<EOF
$POST_STATUS
EOF
    ) || uninstall_stop "post_term_state_unknown"
    POST_STAT=$(dd if="$PROCESS_ROOT/$ORIGINAL_PID/stat" bs=1 count=8193 2>/dev/null && printf x) || uninstall_stop "post_term_stat_unknown"
    POST_STAT=${POST_STAT%x}
    [ "${#POST_STAT}" -le 8192 ] || uninstall_stop "post_term_stat_oversized"
    case "$POST_STAT" in *') '*) POST_TAIL=${POST_STAT##*) } ;; *) uninstall_stop "post_term_stat_malformed" ;; esac
    set -- $POST_TAIL
    [ "$#" -ge 20 ] || uninstall_stop "post_term_stat_short"
    [ "$1" = "$POST_STATE" ] || uninstall_stop "post_term_state_race"
    shift 19
    [ "$1" = "$ORIGINAL_START" ] || uninstall_stop "post_term_pid_reused"
    case "$POST_STATE" in Z|X|x) STOPPED=1; break ;; esac
    STOP_POLLS=$((STOP_POLLS + 1))
done
[ "$STOPPED" -eq 1 ] || uninstall_stop "term_ignored_or_process_still_live"

# No persistent delete until every object and the stopped heartbeat validate.
validate_install_inventory || uninstall_stop "post_term_inventory_changed"
[ ! -e "$HEARTBEAT_TEMP" ] && [ ! -L "$HEARTBEAT_TEMP" ] || uninstall_stop "post_term_heartbeat_temp_conflict"
validate_owned_heartbeat "$ORIGINAL_PID" || uninstall_stop "post_term_heartbeat_ownership_unknown"
validate_nvm_path "$DEST_MANIFEST" || uninstall_stop "manifest_mount_changed"
rm "$DEST_MANIFEST" || uninstall_stop "partial_uninstall_manifest_remove_failed"
# From this point, any failure is PARTIAL_UNINSTALL / MANUAL_REVIEW_REQUIRED.
validate_nvm_path "$DEST_BINARY" || uninstall_stop "partial_uninstall_binary_mount_changed"
validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" || uninstall_stop "partial_uninstall_binary_changed"
rm "$DEST_BINARY" || uninstall_stop "partial_uninstall_binary_remove_failed"
validate_nvm_path "$INSTALL_DIR" || uninstall_stop "partial_uninstall_directory_mount_changed"
rmdir "$INSTALL_DIR" || uninstall_stop "partial_uninstall_directory_not_empty"
# Parent ownership metadata was not retained, so leave its empty directory.
[ -d "$INSTALL_PARENT" ] && [ ! -L "$INSTALL_PARENT" ] || uninstall_stop "parent_changed"
[ ! -e "$DEST_BINARY" ] && [ ! -L "$DEST_BINARY" ] &&
    [ ! -e "$DEST_MANIFEST" ] && [ ! -L "$DEST_MANIFEST" ] || uninstall_stop "installed_files_remain"

printf '%s\n' \
    "schema=1" \
    "result=PASS" \
    "original_pid=$ORIGINAL_PID" \
    "original_start=$ORIGINAL_START" \
    "term_used=1" \
    "kill_used=0" \
    "removed.binary=$DEST_BINARY" \
    "removed.manifest=$DEST_MANIFEST" \
    "removed.install_directory=$INSTALL_DIR" \
    "retained.empty_parent=$INSTALL_PARENT" \
    "retained.volatile_heartbeat=$HEARTBEAT" \
    "stock_files_modified=0" > RESULT.txt || uninstall_stop "result_write_failed"
finish_complete
