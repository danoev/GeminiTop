#!/bin/sh
# Fixed-whitelist W176 platform capture. Target reads only; USB writes only.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROCESS_ROOT=/proc
TARGET_ROOT=
COMMAND_POLL_INTERVAL=1
COMMAND_RUN_POLLS=5
COMMAND_TERM_POLLS=1
COMMAND_KILL_POLLS=1
SELFTEST_POLL_INTERVAL=1
SELFTEST_RUN_POLLS=1
SELFTEST_TERM_POLLS=1
SELFTEST_KILL_POLLS=1
SELFTEST_NATURAL_DELAY=10
MAX_TOTAL_SOURCE_BYTES=8388608
MAX_COPIED_SOURCE_BYTES=524288
MAX_TOTAL_CAPTURE_BYTES=1048576
OUTPUT_BLOCK_LIMIT=128
COPY_BLOCK_LIMIT=1024
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-stage2: cannot locate payload directory" >&2
    exit 1
}
GUARD="$SCRIPT_DIR/mount_guard.sh"
[ -f "$GUARD" ] && [ ! -L "$GUARD" ] || {
    printf '%s\n' "w176-stage2: mount guard must be a regular non-symlink file" >&2
    exit 1
}
[ "$#" -eq 1 ] || {
    printf '%s\n' "w176-stage2: exactly one USB root is required" >&2
    exit 1
}
USB_ROOT=$(/bin/sh "$GUARD" "$1") || exit 1
[ "$USB_ROOT" = "$SCRIPT_DIR" ] || {
    printf '%s\n' "w176-stage2: supplied root does not contain this payload" >&2
    exit 1
}

BASE="$USB_ROOT/stage2-platform"
OUT=
INDEX=0
while [ "$INDEX" -lt 100 ]; do
    if [ "$INDEX" -eq 0 ]; then CANDIDATE=$BASE; else CANDIDATE="$BASE-$INDEX"; fi
    if [ ! -e "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ]; then
        if mkdir "$CANDIDATE" 2>/dev/null; then OUT=$CANDIDATE; break; fi
        printf '%s\n' "w176-stage2: cannot create output directory on USB" >&2
        exit 1
    fi
    INDEX=$((INDEX + 1))
done
[ -n "$OUT" ] || {
    printf '%s\n' "w176-stage2: output directory limit reached" >&2
    exit 1
}

FILES_DIR="$OUT/files"
mkdir "$FILES_DIR" 2>/dev/null || {
    printf '%s\n' "w176-stage2: cannot create files directory on USB" >&2
    exit 1
}
[ -d "$FILES_DIR" ] && [ ! -L "$FILES_DIR" ] || exit 1

FAILURES=0
ERROR_INDEX=0
OPTIONAL_INDEX=0
ERROR_WORK="$OUT/.ERRORS.txt.work"
OPTIONAL_WORK="$OUT/.OPTIONAL.txt.work"
INVENTORY_WORK="$OUT/.capture-inventory.txt.work"
CHECKSUM_WORK="$OUT/.checksums.sha256.work"
SYMLINK_WORK="$OUT/.symlinks.txt.work"
STATUS_FILE="$OUT/STATUS.txt"
STATUS_TEMP="$OUT/.STATUS.txt.tmp"
MANIFESTS_FINALIZED=0
REQUIRED_WRITE_FAILED=0
TOTAL_SOURCE_BYTES=0
COPIED_SOURCE_BYTES=0

is_regular_nonsymlink() { [ -f "$1" ] && [ ! -L "$1" ]; }

commit_regular_file() {
    is_regular_nonsymlink "$1" || return 1
    mv "$1" "$2" || return 1
    is_regular_nonsymlink "$2"
}

for WORK in "$ERROR_WORK" "$OPTIONAL_WORK" "$INVENTORY_WORK" "$CHECKSUM_WORK" "$SYMLINK_WORK"; do
    : > "$WORK" || exit 1
    is_regular_nonsymlink "$WORK" || exit 1
done

write_status() {
    if ! printf '%s\n' \
        "schema=1" \
        "scope=w176-stage2-platform" \
        "status=$1" \
        "mandatory_failures=$FAILURES" \
        "errors=ERRORS.txt" \
        "optional=OPTIONAL.txt" > "$STATUS_TEMP"
    then
        return 1
    fi
    commit_regular_file "$STATUS_TEMP" "$STATUS_FILE"
}

record_failure() {
    FAILURES=$((FAILURES + 1))
    ERROR_INDEX=$((ERROR_INDEX + 1))
    if [ "$MANIFESTS_FINALIZED" -ne 0 ] ||
        ! printf 'error.%s=%s\n' "$ERROR_INDEX" "$1" >> "$ERROR_WORK" 2>/dev/null
    then
        REQUIRED_WRITE_FAILED=1
    fi
}

record_optional() {
    OPTIONAL_INDEX=$((OPTIONAL_INDEX + 1))
    if [ "$MANIFESTS_FINALIZED" -ne 0 ] ||
        ! printf 'optional.%s=%s\n' "$OPTIONAL_INDEX" "$1" >> "$OPTIONAL_WORK" 2>/dev/null
    then
        record_failure "cannot_write_optional_manifest"
    fi
}

finalize_manifests() {
    RESULT=0
    commit_regular_file "$INVENTORY_WORK" "$OUT/capture-inventory.txt" || RESULT=1
    commit_regular_file "$CHECKSUM_WORK" "$OUT/checksums.sha256" || RESULT=1
    commit_regular_file "$SYMLINK_WORK" "$OUT/symlinks.txt" || RESULT=1
    commit_regular_file "$OPTIONAL_WORK" "$OUT/OPTIONAL.txt" || RESULT=1
    commit_regular_file "$ERROR_WORK" "$OUT/ERRORS.txt" || RESULT=1
    MANIFESTS_FINALIZED=1
    return "$RESULT"
}

finish_incomplete() {
    [ "$MANIFESTS_FINALIZED" -ne 0 ] || finalize_manifests >/dev/null 2>&1 || true
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-stage2: mandatory collection failed; output incomplete: $OUT" >&2
    exit 1
}

write_status INCOMPLETE || exit 1

MISSING_COMMAND=0
for REQUIRED_COMMAND in awk cat cp mkdir mv readlink rm sha256sum sleep wc; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        record_failure "missing_command:$REQUIRED_COMMAND"
        MISSING_COMMAND=1
    fi
done
for REQUIRED_BUILTIN in kill wait; do
    if ! command -v "$REQUIRED_BUILTIN" >/dev/null 2>&1; then
        record_failure "missing_shell_primitive:$REQUIRED_BUILTIN"
        MISSING_COMMAND=1
    fi
done
[ -x /bin/sh ] || { record_failure "missing_shell:/bin/sh"; MISSING_COMMAND=1; }
[ "$MISSING_COMMAND" -eq 0 ] || finish_incomplete

read_current_process_id() {
    CURRENT_PROCESS_STAT=
    IFS= read -r CURRENT_PROCESS_STAT < "$PROCESS_ROOT/self/stat" 2>/dev/null || return 1
    CURRENT_PROCESS_PID=${CURRENT_PROCESS_STAT%% *}
    case "$CURRENT_PROCESS_PID" in ''|*[!0-9]*) return 1 ;; esac
}

observe_owned_child() {
    OBSERVED_PID=$1
    OBSERVED_STAT_FILE="$PROCESS_ROOT/$OBSERVED_PID/stat"
    OBSERVED_STAT_LINE=
    if ! IFS= read -r OBSERVED_STAT_LINE < "$OBSERVED_STAT_FILE" 2>/dev/null; then
        if [ ! -e "$OBSERVED_STAT_FILE" ]; then OWNED_CHILD_STATE=ABSENT; return 0; fi
        OWNED_CHILD_STATE=UNKNOWN
        return 1
    fi
    case "$OBSERVED_STAT_LINE" in
        *') '*) OBSERVED_STAT_TAIL=${OBSERVED_STAT_LINE##*) } ;;
        *) OWNED_CHILD_STATE=UNKNOWN; return 1 ;;
    esac
    set -- $OBSERVED_STAT_TAIL
    [ "$#" -ge 20 ] || { OWNED_CHILD_STATE=UNKNOWN; return 1; }
    OWNED_CHILD_CODE=$1
    OBSERVED_PARENT_PID=$2
    shift 19
    OBSERVED_START_TIME=$1
    case "$OBSERVED_PARENT_PID:$OBSERVED_START_TIME" in
        *[!0-9:]*) OWNED_CHILD_STATE=UNKNOWN; return 1 ;;
        :*|*:) OWNED_CHILD_STATE=UNKNOWN; return 1 ;;
    esac
    if [ -z "$OWNED_CHILD_PARENT_PID" ] &&
        [ "$OBSERVED_PARENT_PID" != "$OWNED_CHILD_EXPECTED_PARENT_PID" ]; then
        OWNED_CHILD_STATE=REPLACED
        return 0
    elif [ -z "$OWNED_CHILD_PARENT_PID" ]; then
        OWNED_CHILD_PARENT_PID=$OBSERVED_PARENT_PID
        OWNED_CHILD_START_TIME=$OBSERVED_START_TIME
    elif [ "$OBSERVED_PARENT_PID" != "$OWNED_CHILD_PARENT_PID" ] ||
        [ "$OBSERVED_START_TIME" != "$OWNED_CHILD_START_TIME" ]; then
        OWNED_CHILD_STATE=REPLACED
        return 0
    fi
    case "$OWNED_CHILD_CODE" in
        Z|X|x) OWNED_CHILD_STATE=EXITED ;;
        R|S|D|T|t|I|W|P) OWNED_CHILD_STATE=LIVE ;;
        *) OWNED_CHILD_STATE=UNKNOWN; return 1 ;;
    esac
}

poll_owned_child() {
    POLL_LIMIT=$1
    POLL_COUNT=0
    while [ "$POLL_COUNT" -lt "$POLL_LIMIT" ]; do
        sleep "$ACTIVE_POLL_INTERVAL" || return 2
        observe_owned_child "$BOUNDED_CHILD_PID" || return 2
        [ "$OWNED_CHILD_STATE" = LIVE ] || return 0
        POLL_COUNT=$((POLL_COUNT + 1))
    done
    return 1
}

force_owned_child_stop() {
    observe_owned_child "$BOUNDED_CHILD_PID" 2>/dev/null || true
    [ "$OWNED_CHILD_STATE" = LIVE ] || return 0
    kill -TERM "$BOUNDED_CHILD_PID" 2>/dev/null || true
    sleep "$ACTIVE_POLL_INTERVAL" 2>/dev/null || true
    observe_owned_child "$BOUNDED_CHILD_PID" 2>/dev/null || return 0
    [ "$OWNED_CHILD_STATE" = LIVE ] || return 0
    kill -KILL "$BOUNDED_CHILD_PID" 2>/dev/null || true
}

run_bounded() {
    ACTIVE_POLL_INTERVAL=$COMMAND_POLL_INTERVAL
    ACTIVE_RUN_POLLS=$COMMAND_RUN_POLLS
    ACTIVE_TERM_POLLS=$COMMAND_TERM_POLLS
    ACTIVE_KILL_POLLS=$COMMAND_KILL_POLLS
    LAST_BOUNDED_DETAIL=starting
    LAST_BOUNDED_KILL_LIVE=0
    LAST_BOUNDED_KILL_SENT=0
    LAST_BOUNDED_KILL_TERMINATED=0
    LAST_BOUNDED_CHILD_REAPED=0
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
        if ! observe_owned_child "$BOUNDED_CHILD_PID"; then
            BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=run_state_unavailable; break
        fi
        if [ "$OWNED_CHILD_STATE" != LIVE ]; then
            BOUNDED_OUTCOME=child; LAST_BOUNDED_DETAIL=child_completed; break
        fi
        sleep "$ACTIVE_POLL_INTERVAL" || {
            BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=run_poll_sleep_failed; break
        }
        RUN_POLL_COUNT=$((RUN_POLL_COUNT + 1))
    done
    if [ -z "$BOUNDED_OUTCOME" ]; then
        if ! observe_owned_child "$BOUNDED_CHILD_PID"; then
            BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=deadline_state_unavailable
        elif [ "$OWNED_CHILD_STATE" != LIVE ]; then
            BOUNDED_OUTCOME=child; LAST_BOUNDED_DETAIL=child_completed_at_deadline
        else
            BOUNDED_OUTCOME=timeout; LAST_BOUNDED_DETAIL=term_phase
            kill -TERM "$BOUNDED_CHILD_PID" 2>/dev/null || {
                BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=term_signal_failed
            }
        fi
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
                    if [ "$KILL_POLL_STATUS" -eq 0 ] && [ "$OWNED_CHILD_STATE" != LIVE ]; then
                        LAST_BOUNDED_KILL_TERMINATED=1
                    else
                        BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=child_survived_kill
                    fi
                else
                    BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=kill_signal_failed
                fi
                ;;
            *) BOUNDED_OUTCOME=internal; LAST_BOUNDED_DETAIL=term_poll_failed ;;
        esac
    fi
    [ "$BOUNDED_OUTCOME" != internal ] || force_owned_child_stop
    # SIGNAL BARRIER: no signal is sent below this point; reap exactly once.
    wait "$BOUNDED_CHILD_PID"
    LAST_BOUNDED_CHILD_STATUS=$?
    LAST_BOUNDED_CHILD_REAPED=1
    case "$BOUNDED_OUTCOME" in
        child) return "$LAST_BOUNDED_CHILD_STATUS" ;;
        timeout) return 124 ;;
        *) return 125 ;;
    esac
}

SELFTEST_PID_FILE="$OUT/.hard-timeout-selftest.pid"
SAVED_COMMAND_POLL_INTERVAL=$COMMAND_POLL_INTERVAL
SAVED_COMMAND_RUN_POLLS=$COMMAND_RUN_POLLS
SAVED_COMMAND_TERM_POLLS=$COMMAND_TERM_POLLS
SAVED_COMMAND_KILL_POLLS=$COMMAND_KILL_POLLS
COMMAND_POLL_INTERVAL=$SELFTEST_POLL_INTERVAL
COMMAND_RUN_POLLS=$SELFTEST_RUN_POLLS
COMMAND_TERM_POLLS=$SELFTEST_TERM_POLLS
COMMAND_KILL_POLLS=$SELFTEST_KILL_POLLS
run_bounded /bin/sh -c '
    printf "%s\n" "$$" > "$1" || exit 125
    trap "" TERM
    exec sleep "$2"
' sh "$SELFTEST_PID_FILE" "$SELFTEST_NATURAL_DELAY" >/dev/null 2>&1
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
is_regular_nonsymlink "$SELFTEST_PID_FILE" &&
    IFS= read -r SELFTEST_RECORDED_PID < "$SELFTEST_PID_FILE"
rm -f "$SELFTEST_PID_FILE" 2>/dev/null || true
if [ "$SELFTEST_STATUS" -ne 124 ] || [ "$SELFTEST_RECORDED_PID" != "$SELFTEST_CHILD_PID" ] ||
    [ "$SELFTEST_KILL_LIVE" -ne 1 ] || [ "$SELFTEST_KILL_SENT" -ne 1 ] ||
    [ "$SELFTEST_KILL_TERMINATED" -ne 1 ] || [ "$SELFTEST_REAPED" -ne 1 ] ||
    [ "$SELFTEST_CHILD_STATUS" -le 128 ] ||
    [ -e "$PROCESS_ROOT/$SELFTEST_RECORDED_PID/stat" ]; then
    record_failure "hard_timeout_selftest_failed"
    finish_incomplete
fi

CAPABILITIES_TEMP="$OUT/.CAPABILITIES.txt.tmp"
if ! printf '%s\n' \
    "schema=1" \
    "hard_timeout.backend=parent_proc_state_machine" \
    "hard_timeout.selftest=PASS" \
    "source_bytes.max=$MAX_TOTAL_SOURCE_BYTES" \
    "copied_bytes.max=$MAX_COPIED_SOURCE_BYTES" \
    "capture_bytes.max=$MAX_TOTAL_CAPTURE_BYTES" > "$CAPABILITIES_TEMP" ||
    ! commit_regular_file "$CAPABILITIES_TEMP" "$OUT/CAPABILITIES.txt"
then
    record_failure "capabilities:cannot_commit"
    finish_incomplete
fi

measure_source() {
    SOURCE_PATH=$1
    SOURCE_MAX=$2
    SOURCE_FULL="$TARGET_ROOT$SOURCE_PATH"
    MEASURE_WORK="$OUT/.measure.tmp"
    SOURCE_SIZE=
    if ! is_regular_nonsymlink "$SOURCE_FULL"; then return 2; fi
    rm -f "$MEASURE_WORK" 2>/dev/null || return 3
    if ! run_bounded wc -c "$SOURCE_FULL" > "$MEASURE_WORK" 2>/dev/null; then return 4; fi
    is_regular_nonsymlink "$MEASURE_WORK" || return 3
    SOURCE_SIZE=$(awk 'NR == 1 { value=$1 } NR > 1 { bad=1 } END { if (!bad) print value }' "$MEASURE_WORK") || return 3
    rm -f "$MEASURE_WORK" 2>/dev/null || return 3
    case "$SOURCE_SIZE" in ''|*[!0-9]*) return 3 ;; esac
    is_regular_nonsymlink "$SOURCE_FULL" || return 5
    [ "$SOURCE_SIZE" -le "$SOURCE_MAX" ] || return 6
    NEW_TOTAL=$((TOTAL_SOURCE_BYTES + SOURCE_SIZE))
    [ "$NEW_TOTAL" -le "$MAX_TOTAL_SOURCE_BYTES" ] || return 7
    TOTAL_SOURCE_BYTES=$NEW_TOTAL
    return 0
}

capture_copy() {
    LABEL=$1; SOURCE_PATH=$2; SOURCE_MAX=$3; OUTPUT_NAME=$4
    [ "$FAILURES" -eq 0 ] || return
    SOURCE_FULL="$TARGET_ROOT$SOURCE_PATH"
    DESTINATION="$FILES_DIR/$OUTPUT_NAME"
    TEMP_DESTINATION="$FILES_DIR/.$OUTPUT_NAME.tmp"
    measure_source "$SOURCE_PATH" "$SOURCE_MAX"
    MEASURE_STATUS=$?
    if [ "$MEASURE_STATUS" -ne 0 ]; then
        record_failure "$LABEL:source_validation_$MEASURE_STATUS"
        printf '%s|COPY|FAILED|%s|%s|-\n' "$LABEL" "$SOURCE_PATH" "$SOURCE_MAX" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
        return
    fi
    NEW_COPIED=$((COPIED_SOURCE_BYTES + SOURCE_SIZE))
    if [ "$NEW_COPIED" -gt "$MAX_COPIED_SOURCE_BYTES" ]; then
        record_failure "$LABEL:copied_total_limit"
        return
    fi
    rm -f "$TEMP_DESTINATION" 2>/dev/null || { record_failure "$LABEL:cannot_prepare"; return; }
    if ! run_bounded /bin/sh -c 'ulimit -f "$1" >/dev/null 2>&1 || exit 126; exec cp "$2" "$3"' \
        sh "$COPY_BLOCK_LIMIT" "$SOURCE_FULL" "$TEMP_DESTINATION" >/dev/null 2>&1
    then
        rm -f "$TEMP_DESTINATION" 2>/dev/null || true
        record_failure "$LABEL:copy_failed_or_timed_out"
        return
    fi
    if ! is_regular_nonsymlink "$TEMP_DESTINATION"; then
        record_failure "$LABEL:copy_not_regular"
        return
    fi
    COPIED_SIZE=$(run_bounded wc -c "$TEMP_DESTINATION" 2>/dev/null | awk 'NR == 1 { print $1 }') || COPIED_SIZE=
    case "$COPIED_SIZE" in ''|*[!0-9]*) record_failure "$LABEL:copied_size_invalid"; return ;; esac
    if [ "$COPIED_SIZE" -ne "$SOURCE_SIZE" ] || [ "$COPIED_SIZE" -gt "$SOURCE_MAX" ]; then
        record_failure "$LABEL:source_changed_or_copy_oversized"
        return
    fi
    if ! commit_regular_file "$TEMP_DESTINATION" "$DESTINATION"; then
        record_failure "$LABEL:cannot_commit_copy"
        return
    fi
    COPIED_SOURCE_BYTES=$NEW_COPIED
    printf '%s|COPY|OK|%s|%s|%s|files/%s\n' \
        "$LABEL" "$SOURCE_PATH" "$SOURCE_MAX" "$SOURCE_SIZE" "$OUTPUT_NAME" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
}

capture_hash() {
    LABEL=$1; SOURCE_PATH=$2; SOURCE_MAX=$3
    [ "$FAILURES" -eq 0 ] || return
    SOURCE_FULL="$TARGET_ROOT$SOURCE_PATH"
    HASH_TEMP="$OUT/.hash-$LABEL.tmp"
    measure_source "$SOURCE_PATH" "$SOURCE_MAX"
    MEASURE_STATUS=$?
    if [ "$MEASURE_STATUS" -ne 0 ]; then
        record_failure "$LABEL:source_validation_$MEASURE_STATUS"
        printf '%s|HASH|FAILED|%s|%s|-\n' "$LABEL" "$SOURCE_PATH" "$SOURCE_MAX" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
        return
    fi
    rm -f "$HASH_TEMP" 2>/dev/null || { record_failure "$LABEL:cannot_prepare"; return; }
    if ! (ulimit -f 8 >/dev/null 2>&1 || exit 126; run_bounded sha256sum "$SOURCE_FULL") > "$HASH_TEMP" 2>/dev/null; then
        rm -f "$HASH_TEMP" 2>/dev/null || true
        record_failure "$LABEL:hash_failed_or_timed_out"
        return
    fi
    is_regular_nonsymlink "$HASH_TEMP" || { record_failure "$LABEL:hash_output_invalid"; return; }
    DIGEST=$(awk -v expected="$SOURCE_FULL" '
        NR == 1 && $1 ~ /^[0-9a-fA-F]+$/ && length($1) == 64 && $2 == expected {
            value=tolower($1)
        }
        NR > 1 { bad=1 }
        END { if (!bad) print value }
    ' "$HASH_TEMP")
    rm -f "$HASH_TEMP" 2>/dev/null || { record_failure "$LABEL:cannot_cleanup"; return; }
    [ -n "$DIGEST" ] || { record_failure "$LABEL:hash_output_invalid"; return; }
    if ! is_regular_nonsymlink "$SOURCE_FULL"; then record_failure "$LABEL:source_changed"; return; fi
    printf '%s  %s\n' "$DIGEST" "$SOURCE_PATH" >> "$CHECKSUM_WORK" || REQUIRED_WRITE_FAILED=1
    printf '%s|HASH|OK|%s|%s|%s|-\n' \
        "$LABEL" "$SOURCE_PATH" "$SOURCE_MAX" "$SOURCE_SIZE" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
}

capture_symlink() {
    LABEL=$1; SOURCE_PATH=$2; SOURCE_FULL="$TARGET_ROOT$SOURCE_PATH"
    [ "$FAILURES" -eq 0 ] || return
    LINK_TEMP="$OUT/.link-$LABEL.tmp"
    if [ ! -L "$SOURCE_FULL" ]; then
        record_optional "$LABEL=NOT_A_SYMLINK"
        printf '%s|SYMLINK_METADATA|NOT_A_SYMLINK|%s|1024|-\n' "$LABEL" "$SOURCE_PATH" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
        return
    fi
    if ! (ulimit -f 2 >/dev/null 2>&1 || exit 126; run_bounded readlink "$SOURCE_FULL") > "$LINK_TEMP" 2>/dev/null; then
        rm -f "$LINK_TEMP" 2>/dev/null || true
        record_optional "$LABEL=READ_FAILED_OR_TIMED_OUT"
        return
    fi
    LINK_SIZE=$(run_bounded wc -c "$LINK_TEMP" 2>/dev/null | awk 'NR == 1 { print $1 }') || LINK_SIZE=
    case "$LINK_SIZE" in ''|*[!0-9]*) record_optional "$LABEL=INVALID_SIZE"; return ;; esac
    if [ "$LINK_SIZE" -gt 1024 ]; then record_optional "$LABEL=OVERSIZED"; return; fi
    LINK_TARGET=$(cat "$LINK_TEMP" 2>/dev/null) || { record_optional "$LABEL=READBACK_FAILED"; return; }
    rm -f "$LINK_TEMP" 2>/dev/null || { record_failure "$LABEL:cannot_cleanup"; return; }
    printf '%s|%s|%s\n' "$LABEL" "$SOURCE_PATH" "$LINK_TARGET" >> "$SYMLINK_WORK" || REQUIRED_WRITE_FAILED=1
    printf '%s|SYMLINK_METADATA|OK|%s|1024|%s|-\n' "$LABEL" "$SOURCE_PATH" "$LINK_SIZE" >> "$INVENTORY_WORK" || REQUIRED_WRITE_FAILED=1
}

# COPY: the only bytes retained for offline inspection.
capture_copy launcher /application/bin/Launcher 262144 application__bin__Launcher
capture_copy appinfo /application/appinfo.rc 4096 application__appinfo.rc
capture_copy init_rc /init.rc 32768 init.rc
capture_copy init_platform /init.platform.rc 4096 init.platform.rc
capture_copy init_gui /init.gui.rc 8192 init.gui.rc
capture_copy init_environ /init.environ.rc 8192 init.environ.rc
capture_copy inittab /etc/inittab 4096 etc__inittab
capture_copy rcs /etc/init.d/rcS 16384 etc__init.d__rcS
capture_copy fstab /etc/fstab 4096 etc__fstab
capture_copy mdev /etc/mdev.conf 4096 etc__mdev.conf
capture_copy usb_action /etc/usb_action_8368-U 16384 etc__usb_action_8368-U
capture_copy dynamic_loader /lib/ld-2.30.so 262144 lib__ld-2.30.so

# HASH: equality questions only; no binary bytes retained.
capture_hash libappframework /application/lib/libappframework.so.1.0.0 1048576
capture_hash libappmcucommunication /application/lib/libappmcucommunication.so.1.0.0 1048576
capture_hash servicemanager /usr/local/bin/servicemanager 65536
capture_hash resourcemanager /usr/local/bin/resourcemanager 524288
capture_hash networkmanager /usr/local/bin/networkmanager 524288
capture_hash device_server /usr/local/bin/device_server 524288
capture_hash pfc_server /usr/local/bin/pfc_server 65536
capture_hash libc /lib/libc-2.30.so 2097152
capture_hash libstdcxx /lib/libstdc++.so.6.0.28 2097152
capture_hash busybox /bin/busybox 1048576

# Optional link metadata only; never follows or copies through these links.
capture_symlink application_link /application
capture_symlink usr_local_link /usr/local
capture_symlink media_link /media
capture_symlink init_link /init
capture_symlink shell_link /bin/sh
capture_symlink dynamic_loader_link /lib/ld-linux-armhf.so.3
capture_symlink libc_link /lib/libc.so.6
capture_symlink libstdcxx_link /lib/libstdc++.so.6

SUMMARY_TEMP="$OUT/.SUMMARY.txt.tmp"
if ! printf '%s\n' \
    "schema=1" \
    "scope=w176-stage2-platform" \
    "source_bytes_processed=$TOTAL_SOURCE_BYTES" \
    "copied_payload_bytes=$COPIED_SOURCE_BYTES" \
    "mandatory_failures=$FAILURES" \
    "target_write_operations=0" \
    "raw_mtd_reads=0" \
    "nvm_userdata_reads=0" \
    "can_mcu_operations=0" > "$SUMMARY_TEMP" ||
    ! commit_regular_file "$SUMMARY_TEMP" "$OUT/SUMMARY.txt"
then
    record_failure "summary:cannot_commit"
fi

README_TEMP="$OUT/.README.txt.tmp"
if ! printf '%s\n' \
    "W176 Stage-2 selective platform capture finished." \
    "Require STATUS.txt status=COMPLETE, mandatory_failures=0, and a regular non-symlink COMPLETE." \
    "All output was written below the validated removable USB root." \
    "No target write, raw MTD/NVM/userdata read, CAN/MCU operation, network change, service change, or ARM execution was performed." > "$README_TEMP" ||
    ! commit_regular_file "$README_TEMP" "$OUT/README.txt"
then
    record_failure "readme:cannot_commit"
fi

validate_outputs() {
    for REQUIRED_OUTPUT in CAPABILITIES.txt SUMMARY.txt README.txt; do
        is_regular_nonsymlink "$OUT/$REQUIRED_OUTPUT" || return 1
    done
    for COPIED_OUTPUT in \
        application__bin__Launcher application__appinfo.rc init.rc init.platform.rc \
        init.gui.rc init.environ.rc etc__inittab etc__init.d__rcS etc__fstab \
        etc__mdev.conf etc__usb_action_8368-U lib__ld-2.30.so
    do
        is_regular_nonsymlink "$FILES_DIR/$COPIED_OUTPUT" || return 1
    done
    return 0
}

OUTPUT_TOTAL_BYTES=4096
add_output_size() {
    is_regular_nonsymlink "$1" || return 1
    ITEM_SIZE=$(run_bounded wc -c "$1" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 1
    case "$ITEM_SIZE" in ''|*[!0-9]*) return 1 ;; esac
    OUTPUT_TOTAL_BYTES=$((OUTPUT_TOTAL_BYTES + ITEM_SIZE))
}

for OUTPUT_ITEM in \
    "$STATUS_FILE" "$OUT/CAPABILITIES.txt" "$OUT/SUMMARY.txt" "$OUT/README.txt" \
    "$ERROR_WORK" "$OPTIONAL_WORK" "$INVENTORY_WORK" "$CHECKSUM_WORK" "$SYMLINK_WORK" \
    "$FILES_DIR/application__bin__Launcher" "$FILES_DIR/application__appinfo.rc" \
    "$FILES_DIR/init.rc" "$FILES_DIR/init.platform.rc" "$FILES_DIR/init.gui.rc" \
    "$FILES_DIR/init.environ.rc" "$FILES_DIR/etc__inittab" "$FILES_DIR/etc__init.d__rcS" \
    "$FILES_DIR/etc__fstab" "$FILES_DIR/etc__mdev.conf" "$FILES_DIR/etc__usb_action_8368-U" \
    "$FILES_DIR/lib__ld-2.30.so"
do
    add_output_size "$OUTPUT_ITEM" || { record_failure "capture_size_validation_failed"; break; }
done
[ "$OUTPUT_TOTAL_BYTES" -le "$MAX_TOTAL_CAPTURE_BYTES" ] || record_failure "capture_total_limit_exceeded"

if ! validate_outputs; then record_failure "required_outputs_missing_or_invalid"; fi
if [ "$FAILURES" -ne 0 ] || [ "$REQUIRED_WRITE_FAILED" -ne 0 ]; then finish_incomplete; fi
if ! finalize_manifests; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-stage2: cannot finalize manifests" >&2
    exit 1
fi

for FINAL_MANIFEST in ERRORS.txt OPTIONAL.txt capture-inventory.txt checksums.sha256 symlinks.txt; do
    is_regular_nonsymlink "$OUT/$FINAL_MANIFEST" || {
        write_status INCOMPLETE >/dev/null 2>&1 || true
        exit 1
    }
done
[ ! -s "$OUT/ERRORS.txt" ] || {
    write_status INCOMPLETE >/dev/null 2>&1 || true
    exit 1
}

status_is_complete() {
    is_regular_nonsymlink "$STATUS_FILE" || return 1
    run_bounded awk -F= '
        $1 == "status" { status=$2; sc++ }
        $1 == "mandatory_failures" { failures=$2; fc++ }
        END { if (sc != 1 || fc != 1 || status != "COMPLETE" || failures != "0") exit 1 }
    ' "$STATUS_FILE" >/dev/null 2>&1
}

if ! write_status COMPLETE || ! status_is_complete; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    exit 1
fi
COMPLETE_TEMP="$OUT/.COMPLETE.tmp"
COMPLETE_FILE="$OUT/COMPLETE"
if [ -e "$COMPLETE_FILE" ] || [ -L "$COMPLETE_FILE" ] ||
    ! validate_outputs || ! status_is_complete ||
    ! printf '%s\n' "complete=1" > "$COMPLETE_TEMP" ||
    ! commit_regular_file "$COMPLETE_TEMP" "$COMPLETE_FILE"
then
    if [ -e "$COMPLETE_FILE" ] || [ -L "$COMPLETE_FILE" ]; then
        mv "$COMPLETE_FILE" "$OUT/.COMPLETE.invalid" 2>/dev/null || true
    fi
    write_status INCOMPLETE >/dev/null 2>&1 || true
    exit 1
fi

printf '%s\n' "w176-stage2: complete: $OUT"
