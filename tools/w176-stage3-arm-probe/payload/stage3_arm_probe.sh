#!/bin/sh
# One-shot inert ARMHF loadability proof. Target interaction is prohibited.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROCESS_ROOT=/proc
FD_ROOT=/proc/self/fd
COMMAND_POLL_INTERVAL=1
COMMAND_RUN_POLLS=5
COMMAND_TERM_POLLS=1
COMMAND_KILL_POLLS=1
SELFTEST_POLL_INTERVAL=1
SELFTEST_RUN_POLLS=1
SELFTEST_TERM_POLLS=1
SELFTEST_KILL_POLLS=1
SELFTEST_NATURAL_DELAY=10
EXPECTED_BINARY_SHA256=662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789
EXPECTED_BINARY_SIZE=5556
MAX_BINARY_SIZE=65536
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-stage3: cannot locate payload directory" >&2
    exit 1
}
[ "$#" -eq 1 ] || {
    printf '%s\n' "w176-stage3: exactly one USB root is required" >&2
    exit 1
}
REQUESTED_ROOT=$1
REQUESTED_CANONICAL=$(cd -P "$REQUESTED_ROOT" 2>/dev/null && pwd -P) || exit 1
cd -P "$SCRIPT_DIR" 2>/dev/null || exit 1
ANCHOR_DISPLAY=$(pwd -P 2>/dev/null) || exit 1
[ "$REQUESTED_CANONICAL" = "$ANCHOR_DISPLAY" ] &&
    [ . -ef "$REQUESTED_CANONICAL" ] 2>/dev/null || {
    printf '%s\n' "w176-stage3: supplied root does not contain this payload" >&2
    exit 1
}
GUARD=./mount_guard.sh
[ -f "$GUARD" ] && [ ! -L "$GUARD" ] || exit 1
USB_ROOT=$(/bin/sh "$GUARD" .) || exit 1
[ "$USB_ROOT" = "$ANCHOR_DISPLAY" ] || exit 1
ARM_MARKER=./ARM_STAGE3_ARM_EXECUTION_PROBE
[ -f "$ARM_MARKER" ] && [ ! -L "$ARM_MARKER" ] || {
    printf '%s\n' "w176-stage3: not armed; reviewed marker is absent or invalid" >&2
    exit 1
}

BASE=stage3-arm-probe
OUT_NAME=
INDEX=0
while [ "$INDEX" -lt 100 ]; do
    if [ "$INDEX" -eq 0 ]; then CANDIDATE=$BASE; else CANDIDATE="$BASE-$INDEX"; fi
    if [ ! -e "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ]; then
        if mkdir "$CANDIDATE" 2>/dev/null; then OUT_NAME=$CANDIDATE; break; fi
        printf '%s\n' "w176-stage3: cannot create output directory on USB" >&2
        exit 1
    fi
    INDEX=$((INDEX + 1))
done
[ -n "$OUT_NAME" ] || exit 1
cd -P "$OUT_NAME" 2>/dev/null || exit 1
OUT_DISPLAY="$ANCHOR_DISPLAY/$OUT_NAME"

FAILURES=0
ERROR_INDEX=0
ERROR_WORK=./.ERRORS.txt.work
STATUS_FILE=./STATUS.txt
STATUS_TEMP=./.STATUS.txt.tmp
ERRORS_FINALIZED=0
REQUIRED_WRITE_FAILED=0
RUNNER_FATAL=0

is_regular_nonsymlink() { [ -f "$1" ] && [ ! -L "$1" ]; }
commit_regular_file() {
    is_regular_nonsymlink "$1" || return 1
    mv "$1" "$2" || return 1
    is_regular_nonsymlink "$2"
}
: > "$ERROR_WORK" || exit 1
is_regular_nonsymlink "$ERROR_WORK" || exit 1

write_status() {
    printf '%s\n' \
        "schema=1" \
        "scope=w176-stage3-arm-execution-probe" \
        "status=$1" \
        "mandatory_failures=$FAILURES" \
        "errors=ERRORS.txt" > "$STATUS_TEMP" || return 1
    commit_regular_file "$STATUS_TEMP" "$STATUS_FILE"
}
record_failure() {
    FAILURES=$((FAILURES + 1))
    ERROR_INDEX=$((ERROR_INDEX + 1))
    if [ "$ERRORS_FINALIZED" -ne 0 ] ||
        ! printf 'error.%s=%s\n' "$ERROR_INDEX" "$1" >> "$ERROR_WORK" 2>/dev/null
    then
        REQUIRED_WRITE_FAILED=1
    fi
}
finalize_errors() {
    commit_regular_file "$ERROR_WORK" ./ERRORS.txt || return 1
    ERRORS_FINALIZED=1
}
finish_incomplete() {
    [ "$ERRORS_FINALIZED" -ne 0 ] || finalize_errors >/dev/null 2>&1 || true
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-stage3: execution proof incomplete: $OUT_DISPLAY" >&2
    exit 1
}

write_status INCOMPLETE || exit 1

MISSING_COMMAND=0
for REQUIRED_COMMAND in awk chmod cmp dd mkdir mv rm sha256sum sleep stat; do
    command -v "$REQUIRED_COMMAND" >/dev/null 2>&1 || {
        record_failure "missing_command:$REQUIRED_COMMAND"
        MISSING_COMMAND=1
    }
done
for REQUIRED_BUILTIN in kill wait; do
    command -v "$REQUIRED_BUILTIN" >/dev/null 2>&1 || {
        record_failure "missing_shell_primitive:$REQUIRED_BUILTIN"
        MISSING_COMMAND=1
    }
done
[ -x /bin/sh ] || { record_failure "missing_shell:/bin/sh"; MISSING_COMMAND=1; }
[ . -ef . ] 2>/dev/null || { record_failure "missing_shell_primitive:file_identity"; MISSING_COMMAND=1; }
[ "$MISSING_COMMAND" -eq 0 ] || finish_incomplete

read_current_process_id() {
    CURRENT_PROCESS_STAT=
    IFS= read -r CURRENT_PROCESS_STAT 2>/dev/null < "$PROCESS_ROOT/self/stat" || return 1
    CURRENT_PROCESS_PID=${CURRENT_PROCESS_STAT%% *}
    case "$CURRENT_PROCESS_PID" in ''|*[!0-9]*) return 1 ;; esac
}
observe_owned_child() {
    OBSERVED_PID=$1
    OBSERVED_STAT_FILE="$PROCESS_ROOT/$OBSERVED_PID/stat"
    OBSERVED_STAT_LINE=
    if ! IFS= read -r OBSERVED_STAT_LINE 2>/dev/null < "$OBSERVED_STAT_FILE"; then
        if [ ! -e "$OBSERVED_STAT_FILE" ]; then OWNED_CHILD_STATE=ABSENT; return 0; fi
        OWNED_CHILD_STATE=UNKNOWN
        return 1
    fi
    case "$OBSERVED_STAT_LINE" in *') '*) OBSERVED_STAT_TAIL=${OBSERVED_STAT_LINE##*) } ;; *) OWNED_CHILD_STATE=UNKNOWN; return 1 ;; esac
    set -- $OBSERVED_STAT_TAIL
    [ "$#" -ge 20 ] || { OWNED_CHILD_STATE=UNKNOWN; return 1; }
    OWNED_CHILD_CODE=$1
    OBSERVED_PARENT_PID=$2
    shift 19
    OBSERVED_START_TIME=$1
    case "$OBSERVED_PARENT_PID:$OBSERVED_START_TIME" in *[!0-9:]*) OWNED_CHILD_STATE=UNKNOWN; return 1 ;; :*|*:) OWNED_CHILD_STATE=UNKNOWN; return 1 ;; esac
    if [ -z "$OWNED_CHILD_PARENT_PID" ] && [ "$OBSERVED_PARENT_PID" != "$OWNED_CHILD_EXPECTED_PARENT_PID" ]; then
        OWNED_CHILD_STATE=REPLACED
        return 0
    elif [ -z "$OWNED_CHILD_PARENT_PID" ]; then
        OWNED_CHILD_PARENT_PID=$OBSERVED_PARENT_PID
        OWNED_CHILD_START_TIME=$OBSERVED_START_TIME
    elif [ "$OBSERVED_PARENT_PID" != "$OWNED_CHILD_PARENT_PID" ] || [ "$OBSERVED_START_TIME" != "$OWNED_CHILD_START_TIME" ]; then
        OWNED_CHILD_STATE=REPLACED
        return 0
    fi
    case "$OWNED_CHILD_CODE" in Z|X|x) OWNED_CHILD_STATE=EXITED ;; R|S|D|T|t|I|W|P) OWNED_CHILD_STATE=LIVE ;; *) OWNED_CHILD_STATE=UNKNOWN; return 1 ;; esac
}
poll_owned_child() {
    POLL_LIMIT=$1
    POLL_COUNT=0
    while [ "$POLL_COUNT" -lt "$POLL_LIMIT" ]; do
        sleep "$ACTIVE_POLL_INTERVAL" || return 2
        observe_owned_child "$BOUNDED_CHILD_PID" || return 2
        case "$OWNED_CHILD_STATE" in ABSENT|EXITED) return 0 ;; LIVE) ;; *) return 2 ;; esac
        POLL_COUNT=$((POLL_COUNT + 1))
    done
    return 1
}
runner_fatal_no_wait() {
    RUNNER_FATAL=1
    LAST_BOUNDED_DETAIL=$1
    LAST_BOUNDED_CHILD_REAPED=0
    LAST_BOUNDED_WAIT_CALLED=0
    return 125
}
run_bounded() {
    [ "$RUNNER_FATAL" -eq 0 ] || { LAST_BOUNDED_DETAIL=runner_already_fatal; return 125; }
    ACTIVE_POLL_INTERVAL=$COMMAND_POLL_INTERVAL
    ACTIVE_RUN_POLLS=$COMMAND_RUN_POLLS
    ACTIVE_TERM_POLLS=$COMMAND_TERM_POLLS
    ACTIVE_KILL_POLLS=$COMMAND_KILL_POLLS
    LAST_BOUNDED_DETAIL=starting
    LAST_BOUNDED_KILL_LIVE=0
    LAST_BOUNDED_KILL_SENT=0
    LAST_BOUNDED_KILL_TERMINATED=0
    LAST_BOUNDED_CHILD_REAPED=0
    LAST_BOUNDED_WAIT_CALLED=0
    LAST_BOUNDED_CHILD_STATUS=125
    LAST_BOUNDED_CHILD_PID=
    OWNED_CHILD_PARENT_PID=
    OWNED_CHILD_START_TIME=
    read_current_process_id || { LAST_BOUNDED_DETAIL=parent_identity_unavailable; return 125; }
    OWNED_CHILD_EXPECTED_PARENT_PID=$CURRENT_PROCESS_PID
    "$@" &
    BOUNDED_CHILD_PID=$!
    LAST_BOUNDED_CHILD_PID=$BOUNDED_CHILD_PID
    BOUNDED_OUTCOME=
    RUN_POLL_COUNT=0
    while [ "$RUN_POLL_COUNT" -lt "$ACTIVE_RUN_POLLS" ]; do
        observe_owned_child "$BOUNDED_CHILD_PID" || { runner_fatal_no_wait run_state_unavailable; return 125; }
        case "$OWNED_CHILD_STATE" in ABSENT|EXITED) BOUNDED_OUTCOME=child; LAST_BOUNDED_DETAIL=child_completed; break ;; LIVE) ;; *) runner_fatal_no_wait run_state_uncertain; return 125 ;; esac
        sleep "$ACTIVE_POLL_INTERVAL" || { runner_fatal_no_wait run_poll_sleep_failed; return 125; }
        RUN_POLL_COUNT=$((RUN_POLL_COUNT + 1))
    done
    if [ -z "$BOUNDED_OUTCOME" ]; then
        observe_owned_child "$BOUNDED_CHILD_PID" || { runner_fatal_no_wait deadline_state_unavailable; return 125; }
        case "$OWNED_CHILD_STATE" in
            ABSENT|EXITED) BOUNDED_OUTCOME=child; LAST_BOUNDED_DETAIL=child_completed_at_deadline ;;
            LIVE)
                BOUNDED_OUTCOME=timeout
                LAST_BOUNDED_DETAIL=term_phase
                if ! kill -TERM "$BOUNDED_CHILD_PID" 2>/dev/null; then
                    observe_owned_child "$BOUNDED_CHILD_PID" 2>/dev/null || { runner_fatal_no_wait term_signal_failed_state_uncertain; return 125; }
                    case "$OWNED_CHILD_STATE" in ABSENT|EXITED) ;; *) runner_fatal_no_wait term_signal_failed; return 125 ;; esac
                fi ;;
            *) runner_fatal_no_wait deadline_state_uncertain; return 125 ;;
        esac
    fi
    if [ "$BOUNDED_OUTCOME" = timeout ]; then
        poll_owned_child "$ACTIVE_TERM_POLLS"
        TERM_POLL_STATUS=$?
        case "$TERM_POLL_STATUS:$OWNED_CHILD_STATE" in
            0:*) LAST_BOUNDED_DETAIL=term_terminated_child ;;
            1:LIVE)
                LAST_BOUNDED_KILL_LIVE=1
                if kill -KILL "$BOUNDED_CHILD_PID" 2>/dev/null; then
                    LAST_BOUNDED_KILL_SENT=1
                    poll_owned_child "$ACTIVE_KILL_POLLS"
                    KILL_POLL_STATUS=$?
                    if [ "$KILL_POLL_STATUS" -eq 0 ]; then LAST_BOUNDED_KILL_TERMINATED=1
                    elif [ "$KILL_POLL_STATUS" -eq 1 ]; then runner_fatal_no_wait child_survived_kill; return 125
                    else runner_fatal_no_wait kill_state_uncertain; return 125; fi
                else runner_fatal_no_wait kill_signal_failed; return 125; fi ;;
            *) runner_fatal_no_wait term_poll_failed; return 125 ;;
        esac
    fi
    LAST_BOUNDED_WAIT_CALLED=1
    wait "$BOUNDED_CHILD_PID"
    LAST_BOUNDED_CHILD_STATUS=$?
    LAST_BOUNDED_CHILD_REAPED=1
    case "$BOUNDED_OUTCOME" in child) return "$LAST_BOUNDED_CHILD_STATUS" ;; timeout) return 124 ;; *) return 125 ;; esac
}

SELFTEST_PID_FILE=./.hard-timeout-selftest.pid
SAVED_COMMAND_POLL_INTERVAL=$COMMAND_POLL_INTERVAL
SAVED_COMMAND_RUN_POLLS=$COMMAND_RUN_POLLS
SAVED_COMMAND_TERM_POLLS=$COMMAND_TERM_POLLS
SAVED_COMMAND_KILL_POLLS=$COMMAND_KILL_POLLS
COMMAND_POLL_INTERVAL=$SELFTEST_POLL_INTERVAL
COMMAND_RUN_POLLS=$SELFTEST_RUN_POLLS
COMMAND_TERM_POLLS=$SELFTEST_TERM_POLLS
COMMAND_KILL_POLLS=$SELFTEST_KILL_POLLS
run_bounded /bin/sh -c 'printf "%s\n" "$$" > "$1" || exit 125; trap "" TERM; exec sleep "$2"' sh "$SELFTEST_PID_FILE" "$SELFTEST_NATURAL_DELAY" >/dev/null 2>&1
SELFTEST_STATUS=$?
SELFTEST_CHILD_PID=$LAST_BOUNDED_CHILD_PID
SELFTEST_CHILD_STATUS=$LAST_BOUNDED_CHILD_STATUS
SELFTEST_REAPED=$LAST_BOUNDED_CHILD_REAPED
SELFTEST_KILL_LIVE=$LAST_BOUNDED_KILL_LIVE
SELFTEST_KILL_SENT=$LAST_BOUNDED_KILL_SENT
SELFTEST_KILL_TERMINATED=$LAST_BOUNDED_KILL_TERMINATED
COMMAND_POLL_INTERVAL=$SAVED_COMMAND_POLL_INTERVAL
COMMAND_RUN_POLLS=$SAVED_COMMAND_RUN_POLLS
COMMAND_TERM_POLLS=$SAVED_COMMAND_TERM_POLLS
COMMAND_KILL_POLLS=$SAVED_COMMAND_KILL_POLLS
SELFTEST_RECORDED_PID=
is_regular_nonsymlink "$SELFTEST_PID_FILE" && IFS= read -r SELFTEST_RECORDED_PID < "$SELFTEST_PID_FILE"
rm -f "$SELFTEST_PID_FILE" 2>/dev/null || true
if [ "$SELFTEST_STATUS" -ne 124 ] || [ "$SELFTEST_RECORDED_PID" != "$SELFTEST_CHILD_PID" ] ||
    [ "$SELFTEST_KILL_LIVE" -ne 1 ] || [ "$SELFTEST_KILL_SENT" -ne 1 ] ||
    [ "$SELFTEST_KILL_TERMINATED" -ne 1 ] || [ "$SELFTEST_REAPED" -ne 1 ] ||
    [ "$SELFTEST_CHILD_STATUS" -le 128 ] || [ -e "$PROCESS_ROOT/$SELFTEST_RECORDED_PID/stat" ]
then
    record_failure "hard_timeout_selftest_failed"
    finish_incomplete
fi

abort_after_runner_fatal() {
    record_failure "runner_fatal:$LAST_BOUNDED_DETAIL"
    finish_incomplete
}

BINARY=../arm_probe
if [ ! -f "$BINARY" ] || [ -L "$BINARY" ]; then
    record_failure "binary_absent_or_invalid"
    finish_incomplete
fi
exec 3< "$BINARY" || { record_failure "binary_open_failed"; finish_incomplete; }
[ -f "$FD_ROOT/3" ] || { record_failure "binary_fd_not_regular"; finish_incomplete; }
BINARY_META_BEFORE=$(stat -L -c '%d|%i|%f|%s|%Y|%Z' "$FD_ROOT/3" 2>/dev/null) || { record_failure "binary_stat_failed"; finish_incomplete; }
PATH_ID_BEFORE=$(stat -L -c '%d|%i' "$BINARY" 2>/dev/null) || { record_failure "binary_path_stat_failed"; finish_incomplete; }
case "$BINARY_META_BEFORE" in "$PATH_ID_BEFORE|"*) ;; *) record_failure "binary_identity_mismatch"; finish_incomplete ;; esac
OLD_IFS=$IFS
IFS='|'
set -- $BINARY_META_BEFORE
IFS=$OLD_IFS
[ "$#" -eq 6 ] || { record_failure "binary_metadata_invalid"; finish_incomplete; }
BINARY_SIZE=$4
case "$BINARY_SIZE" in ''|*[!0-9]*) record_failure "binary_size_invalid"; finish_incomplete ;; esac
[ "$BINARY_SIZE" -le "$MAX_BINARY_SIZE" ] || { record_failure "binary_oversized"; finish_incomplete; }
[ "$BINARY_SIZE" -eq "$EXPECTED_BINARY_SIZE" ] || { record_failure "binary_size_mismatch"; finish_incomplete; }

EXEC_BINARY=./.arm_probe.exec
SNAPSHOT_STATUS=0
run_bounded /bin/sh -c '
    umask 077
    dd if="$1" of="$2" bs=65536 count=1 2>/dev/null || exit 1
    chmod 700 "$2" || exit 1
' sh "$FD_ROOT/3" "$EXEC_BINARY" >/dev/null 2>&1 || SNAPSHOT_STATUS=$?
if [ "$SNAPSHOT_STATUS" -eq 125 ] && [ "$RUNNER_FATAL" -ne 0 ]; then abort_after_runner_fatal; fi
[ "$SNAPSHOT_STATUS" -eq 0 ] && is_regular_nonsymlink "$EXEC_BINARY" || { record_failure "binary_snapshot_failed"; finish_incomplete; }
EXEC_BINARY_SIZE=$(stat -L -c '%s' "$EXEC_BINARY" 2>/dev/null) || { record_failure "binary_snapshot_stat_failed"; finish_incomplete; }
[ "$EXEC_BINARY_SIZE" = "$EXPECTED_BINARY_SIZE" ] || { record_failure "binary_snapshot_size_mismatch"; finish_incomplete; }
SNAPSHOT_HASH_TEMP=./.snapshot-hash.tmp
SNAPSHOT_HASH_STATUS=0
run_bounded sha256sum "$EXEC_BINARY" > "$SNAPSHOT_HASH_TEMP" 2>/dev/null || SNAPSHOT_HASH_STATUS=$?
if [ "$SNAPSHOT_HASH_STATUS" -eq 125 ] && [ "$RUNNER_FATAL" -ne 0 ]; then abort_after_runner_fatal; fi
[ "$SNAPSHOT_HASH_STATUS" -eq 0 ] && is_regular_nonsymlink "$SNAPSHOT_HASH_TEMP" || { record_failure "binary_snapshot_hash_failed"; finish_incomplete; }
SNAPSHOT_SHA256=$(awk 'NR == 1 && $1 ~ /^[0-9a-fA-F]+$/ && length($1) == 64 { value=tolower($1) } NR > 1 { bad=1 } END { if (!bad) print value }' "$SNAPSHOT_HASH_TEMP")
rm -f "$SNAPSHOT_HASH_TEMP" || { record_failure "binary_snapshot_hash_cleanup_failed"; finish_incomplete; }
[ "$SNAPSHOT_SHA256" = "$EXPECTED_BINARY_SHA256" ] || { record_failure "binary_snapshot_hash_mismatch"; finish_incomplete; }
BINARY_SHA256=$SNAPSHOT_SHA256
printf '%s  %s\n' "$BINARY_SHA256" arm_probe > ./.binary.sha256.tmp || finish_incomplete
commit_regular_file ./.binary.sha256.tmp ./binary.sha256 || finish_incomplete
EXEC_BINARY_META_BEFORE=$(stat -L -c '%d|%i|%f|%s|%Y|%Z' "$EXEC_BINARY" 2>/dev/null) || { record_failure "binary_snapshot_metadata_failed"; finish_incomplete; }

CAPABILITIES_TEMP=./.CAPABILITIES.txt.tmp
printf '%s\n' \
    "schema=1" \
    "hard_timeout.backend=parent_proc_state_machine" \
    "hard_timeout.selftest=PASS" \
    "binary.execution=verified_fd_snapshot" \
    "binary.bytes.max=$MAX_BINARY_SIZE" > "$CAPABILITIES_TEMP" || finish_incomplete
commit_regular_file "$CAPABILITIES_TEMP" ./CAPABILITIES.txt || finish_incomplete

STDOUT_FILE=./probe.stdout.txt
STDERR_FILE=./probe.stderr.txt
: > "$STDOUT_FILE" || { record_failure "stdout_create_failed"; finish_incomplete; }
: > "$STDERR_FILE" || { record_failure "stderr_create_failed"; finish_incomplete; }
is_regular_nonsymlink "$STDOUT_FILE" && is_regular_nonsymlink "$STDERR_FILE" || { record_failure "capture_files_invalid"; finish_incomplete; }

EXEC_STATUS=0
run_bounded "$EXEC_BINARY" > "$STDOUT_FILE" 2> "$STDERR_FILE" || EXEC_STATUS=$?
if [ "$EXEC_STATUS" -eq 125 ] && [ "$RUNNER_FATAL" -ne 0 ]; then abort_after_runner_fatal; fi
[ "$EXEC_STATUS" -eq 0 ] || { record_failure "probe_exit_status:$EXEC_STATUS:$LAST_BOUNDED_DETAIL"; finish_incomplete; }

BINARY_META_AFTER=$(stat -L -c '%d|%i|%f|%s|%Y|%Z' "$FD_ROOT/3" 2>/dev/null) || { record_failure "binary_post_stat_failed"; finish_incomplete; }
PATH_ID_AFTER=$(stat -L -c '%d|%i' "$BINARY" 2>/dev/null) || { record_failure "binary_post_path_stat_failed"; finish_incomplete; }
[ "$BINARY_META_AFTER" = "$BINARY_META_BEFORE" ] || { record_failure "binary_changed_during_execution"; finish_incomplete; }
case "$BINARY_META_AFTER" in "$PATH_ID_AFTER|"*) ;; *) record_failure "binary_path_changed_during_execution"; finish_incomplete ;; esac
EXEC_BINARY_META_AFTER=$(stat -L -c '%d|%i|%f|%s|%Y|%Z' "$EXEC_BINARY" 2>/dev/null) || { record_failure "binary_snapshot_post_stat_failed"; finish_incomplete; }
[ "$EXEC_BINARY_META_AFTER" = "$EXEC_BINARY_META_BEFORE" ] || { record_failure "binary_snapshot_changed_during_execution"; finish_incomplete; }
exec 3<&-

EXPECTED_STDOUT=./.expected.stdout
printf '%s\n' \
    "schema=1" \
    "probe=w176-arm-loadability" \
    "started=1" \
    "result=PASS" > "$EXPECTED_STDOUT" || finish_incomplete
cmp -s "$EXPECTED_STDOUT" "$STDOUT_FILE" || { record_failure "probe_stdout_invalid"; finish_incomplete; }
rm -f "$EXPECTED_STDOUT" || { record_failure "expected_output_cleanup_failed"; finish_incomplete; }
[ ! -s "$STDERR_FILE" ] || { record_failure "probe_stderr_not_empty"; finish_incomplete; }
rm -f "$EXEC_BINARY" || { record_failure "binary_snapshot_cleanup_failed"; finish_incomplete; }

EXECUTION_TEMP=./.execution.txt.tmp
printf '%s\n' \
    "schema=1" \
    "probe.started=1" \
    "probe.exit_status=0" \
    "probe.binary.sha256=$BINARY_SHA256" \
    "probe.stdout.valid=1" \
    "probe.stderr.empty=1" > "$EXECUTION_TEMP" || finish_incomplete
commit_regular_file "$EXECUTION_TEMP" ./execution.txt || finish_incomplete

README_TEMP=./.README.txt.tmp
printf '%s\n' \
    "W176 Stage-3 inert ARMHF loadability probe finished." \
    "Require STATUS.txt status=COMPLETE, mandatory_failures=0, execution.txt, strict PASS stdout, and COMPLETE." \
    "All wrapper output was written relative to an anchored validated removable USB filesystem." > "$README_TEMP" || finish_incomplete
commit_regular_file "$README_TEMP" ./README.txt || finish_incomplete

[ "$FAILURES" -eq 0 ] && [ "$REQUIRED_WRITE_FAILED" -eq 0 ] || finish_incomplete
finalize_errors || finish_incomplete
[ ! -s ./ERRORS.txt ] || finish_incomplete
write_status COMPLETE || finish_incomplete

status_is_complete() {
    is_regular_nonsymlink "$STATUS_FILE" || return 1
    awk -F= '$1 == "status" { status=$2; sc++ } $1 == "mandatory_failures" { failures=$2; fc++ } END { if (sc != 1 || fc != 1 || status != "COMPLETE" || failures != "0") exit 1 }' "$STATUS_FILE"
}
for REQUIRED_OUTPUT in STATUS.txt ERRORS.txt CAPABILITIES.txt binary.sha256 probe.stdout.txt probe.stderr.txt execution.txt README.txt; do
    is_regular_nonsymlink "./$REQUIRED_OUTPUT" || finish_incomplete
done
status_is_complete || finish_incomplete
COMPLETE_TEMP=./.COMPLETE.tmp
printf '%s\n' "complete=1" > "$COMPLETE_TEMP" || finish_incomplete
commit_regular_file "$COMPLETE_TEMP" ./COMPLETE || finish_incomplete

printf '%s\n' "w176-stage3: complete: $OUT_DISPLAY"
