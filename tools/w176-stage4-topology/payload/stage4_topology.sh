#!/bin/sh
# W176 Stage-4A CAN/MCU topology metadata capture. Never opens device streams.
set -u

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET_ROOT=/
TARGET_MOUNTS_FILE=/proc/self/mounts
PROCESS_ROOT=/proc
FD_ROOT=/proc/self/fd
SYS_NET_ROOT=/sys/class/net
SYS_DEVICES_ROOT=/sys/devices
SYS_DEV_CHAR_ROOT=/sys/dev/char
DEV_ROOT=/dev
PID_SCAN_MAX=4096
MAX_PROCESSES=256
FD_NUMBER_MAX=127
MAX_TOTAL_FD_LINKS=4096
MAX_OWNERS=16
MAX_MAPS_PER_PROCESS=65536
MAX_TOTAL_MAPS=524288
MAX_INTERFACES=32
MAX_DEVICE_CANDIDATES=18
MAX_SYMLINK_BYTES=4096
MAX_FRAMEWORK_BYTES=393216
MAX_MCU_LIBRARY_BYTES=327680
MAX_TOTAL_LIBRARY_BYTES=720896
MAX_TEXT_BYTES=65536
MAX_TOTAL_OUTPUT_KIB=2048
export PATH
LC_ALL=C
export LC_ALL
# Every regular-file writer, including diagnostic command stdout, has a
# per-file emergency ceiling. POSIX shells use 512 or 1024-byte units:
# conservatively <= 1 MiB. Smaller semantic caps are enforced below.
ulimit -f 1024 || exit 1

fail_early() { printf '%s\n' "w176-stage4a: $1" >&2; exit 1; }
is_regular_nonsymlink() { [ -f "$1" ] && [ ! -L "$1" ]; }

[ "$#" -eq 1 ] || fail_early "exactly one USB root is required"
SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || fail_early "payload root unavailable"
REQUESTED=$(cd -P "$1" 2>/dev/null && pwd -P) || fail_early "requested root unavailable"
cd -P "$SCRIPT_DIR" 2>/dev/null || exit 1
ANCHOR=$(pwd -P 2>/dev/null) || exit 1
[ "$REQUESTED" = "$ANCHOR" ] && [ . -ef "$REQUESTED" ] 2>/dev/null || fail_early "root identity mismatch"
GUARD=./mount_guard.sh
[ -f "$GUARD" ] && [ ! -L "$GUARD" ] || exit 1
[ "$(/bin/sh "$GUARD" .)" = "$ANCHOR" ] || exit 1

LOCK_PATH=./.stage4a-topology.lock
LOCK_DISPLAY="$ANCHOR/.stage4a-topology.lock"
LOCK_OWNED=0
if mkdir "$LOCK_PATH" 2>/dev/null; then LOCK_OWNED=1; else fail_early "one-shot lock unavailable"; fi
owns_lock() { [ "$LOCK_OWNED" -eq 1 ] && [ -d "$LOCK_DISPLAY" ] && [ ! -L "$LOCK_DISPLAY" ]; }
owns_lock || fail_early "lock ownership unverifiable"

MARKER=./ARM_STAGE4_CAN_MCU_TOPOLOGY
owns_lock && [ -f "$MARKER" ] && [ ! -L "$MARKER" ] || fail_early "not armed"
rm -f "$MARKER" || fail_early "cannot consume marker"
[ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || fail_early "marker remains"

# Atomic mkdir is the sole selector. Existing output is never reused or removed.
OUT=
INDEX=0
while [ "$INDEX" -lt 100 ]; do
    [ "$INDEX" -eq 0 ] && CANDIDATE=stage4-topology || CANDIDATE="stage4-topology-$INDEX"
    if mkdir "$CANDIDATE" 2>/dev/null; then OUT=$CANDIDATE; break; fi
    [ -e "$CANDIDATE" ] || [ -L "$CANDIDATE" ] || fail_early "fresh output mkdir failed"
    INDEX=$((INDEX + 1))
done
[ -n "$OUT" ] || fail_early "all output names occupied"
cd "$OUT" || exit 1
mkdir network devices processes files || exit 1

FAILURES=0
OPTIONALS=0
ERROR_WORK=.ERRORS.txt.work
OPTIONAL_WORK=.OPTIONAL.txt.work
INVENTORY_WORK=.capture-inventory.txt.work
CHECKSUM_WORK=.checksums.sha256.work
CHECKSUM_PATHS=.checksum-paths
: > "$ERROR_WORK" && : > "$OPTIONAL_WORK" && : > "$INVENTORY_WORK" &&
    : > "$CHECKSUM_WORK" && : > "$CHECKSUM_PATHS" || exit 1

commit_file() { is_regular_nonsymlink "$1" && mv "$1" "$2" && is_regular_nonsymlink "$2"; }
status_write() {
    printf '%s\n' "schema=3" "scope=w176-stage4a-can-mcu-topology" "status=$1" \
        "mandatory_failures=$FAILURES" "optional_findings=$OPTIONALS" > .STATUS.txt.tmp &&
        commit_file .STATUS.txt.tmp STATUS.txt
}
append_bounded() {
    APPEND_FILE=$1; APPEND_MAX=$2; APPEND_LINE=$3
    APPEND_SIZE=$(stat -c '%s' "$APPEND_FILE" 2>/dev/null) || return 1
    [ $((APPEND_SIZE + ${#APPEND_LINE} + 1)) -le "$APPEND_MAX" ] || return 1
    printf '%s\n' "$APPEND_LINE" >> "$APPEND_FILE"
}
record_failure() {
    FAILURES=$((FAILURES + 1)); DETAIL=$1
    [ "${#DETAIL}" -le 256 ] || DETAIL=detail_overlong
    append_bounded "$ERROR_WORK" 65536 "error.$FAILURES=$DETAIL" || true
}
record_optional() {
    DETAIL=$1; [ "${#DETAIL}" -le 256 ] || { record_failure optional_detail_overlong; return 1; }
    append_bounded "$OPTIONAL_WORK" 65536 "optional.$((OPTIONALS + 1))=$DETAIL" || { record_failure optional_limit; return 1; }
    OPTIONALS=$((OPTIONALS + 1))
}
finish_incomplete() {
    [ ! -e COMPLETE ] && [ ! -L COMPLETE ] || rm -f COMPLETE 2>/dev/null || true
    [ ! -f "$ERROR_WORK" ] || commit_file "$ERROR_WORK" ERRORS.txt 2>/dev/null || true
    [ ! -f "$OPTIONAL_WORK" ] || commit_file "$OPTIONAL_WORK" OPTIONAL.txt 2>/dev/null || true
    status_write INCOMPLETE 2>/dev/null || true
    exit 1
}
status_write INCOMPLETE || exit 1

for COMMAND in awk dd dirname du grep mkdir mv pwd readlink rm sha256sum stat tr; do
    command -v "$COMMAND" >/dev/null 2>&1 || record_failure "missing_command:$COMMAND"
done
[ "$FAILURES" -eq 0 ] || finish_incomplete

# Hashing is deliberately not a pipeline. The command status and exact output
# structure are checked independently before the digest is accepted.
strict_sha256() {
    HASH_SOURCE=$1; HASH_DISPLAY=$2
    HASH_OUTPUT=.sha256-output.tmp; HASH_DIGEST=.sha256-digest.tmp
    rm -f "$HASH_OUTPUT" "$HASH_DIGEST" 2>/dev/null || return 1
    if sha256sum "$HASH_SOURCE" > "$HASH_OUTPUT" 2>/dev/null; then :; else return 1; fi
    is_regular_nonsymlink "$HASH_OUTPUT" || return 1
    HASH_OUTPUT_SIZE=$(stat -L -c '%s' "$HASH_OUTPUT" 2>/dev/null) || return 1
    [ "$HASH_OUTPUT_SIZE" -ge 67 ] && [ "$HASH_OUTPUT_SIZE" -le 512 ] || return 1
    if awk -v expected="$HASH_SOURCE" '
        NR != 1 { exit 1 }
        {
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 != expected) exit 1
            if ($0 != $1 "  " expected) exit 1
            print $1
        }
        END { if (NR != 1) exit 1 }
    ' "$HASH_OUTPUT" > "$HASH_DIGEST"; then :; else return 1; fi
    is_regular_nonsymlink "$HASH_DIGEST" || return 1
    IFS= read -r HASH_VALUE < "$HASH_DIGEST" 2>/dev/null || return 1
    case "$HASH_VALUE" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#HASH_VALUE}" -eq 64 ] || return 1
    case "$HASH_DISPLAY" in ''|/*|*'..'*|*'|'*) return 1 ;; esac
    if grep -F -x "$HASH_DISPLAY" "$CHECKSUM_PATHS" >/dev/null 2>&1; then return 1; fi
    append_bounded "$CHECKSUM_PATHS" 65536 "$HASH_DISPLAY" || return 1
    append_bounded "$CHECKSUM_WORK" 65536 "$HASH_VALUE  $HASH_DISPLAY" || return 1
    rm -f "$HASH_OUTPUT" "$HASH_DIGEST" || return 1
}

hash_committed() {
    HASH_PATH=$1
    is_regular_nonsymlink "$HASH_PATH" || { record_failure "output_invalid:$HASH_PATH"; return 1; }
    strict_sha256 "$HASH_PATH" "$HASH_PATH" || { record_failure "output_hash_failed:$HASH_PATH"; return 1; }
}

inventory_row() {
    append_bounded "$INVENTORY_WORK" 131072 "$1|$2|OK|$3|$4|$5" ||
        record_failure "inventory_write:$1"
}

capture_text() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST=$4; REQUIRED=$5
    TEMP="$DEST.tmp"
    rm -f "$TEMP" 2>/dev/null || return 1
    if [ ! -f "$SOURCE" ] || [ -L "$SOURCE" ]; then
        [ "$REQUIRED" = required ] && record_failure "$LABEL:invalid_source" || record_optional "$LABEL:absent"
        return 1
    fi
    if dd if="$SOURCE" of="$TEMP" bs=$((LIMIT + 1)) count=1 2>/dev/null; then :; else
        rm -f "$TEMP"; [ "$REQUIRED" = required ] && record_failure "$LABEL:read_failed" || record_optional "$LABEL:read_failed"; return 1
    fi
    SIZE=$(stat -L -c '%s' "$TEMP" 2>/dev/null) || { record_failure "$LABEL:size_failed"; return 1; }
    [ "$SIZE" -le "$LIMIT" ] || { rm -f "$TEMP"; record_failure "$LABEL:limit_exceeded"; return 1; }
    commit_file "$TEMP" "$DEST" || { record_failure "$LABEL:commit_failed"; return 1; }
    hash_committed "$DEST" || return 1
    inventory_row "$LABEL" TEXT "$SOURCE" "$SIZE" "$DEST"
}

bounded_readlink() {
    LINK_PATH=$1; LINK_TEMP=$2
    rm -f "$LINK_TEMP" "$LINK_TEMP.value" 2>/dev/null || return 1
    LINK_VALID=0
    if readlink "$LINK_PATH" > "$LINK_TEMP" 2>/dev/null &&
       is_regular_nonsymlink "$LINK_TEMP" &&
       LINK_SIZE=$(stat -L -c '%s' "$LINK_TEMP" 2>/dev/null) &&
       [ "$LINK_SIZE" -ge 1 ] && [ "$LINK_SIZE" -le $((MAX_SYMLINK_BYTES + 1)) ] &&
       awk 'NR == 1 { value=$0 } NR > 1 { exit 1 } END { if (NR != 1) exit 1; print value }' \
           "$LINK_TEMP" > "$LINK_TEMP.value" &&
       IFS= read -r LINK_VALUE < "$LINK_TEMP.value" 2>/dev/null; then LINK_VALID=1; fi
    rm -f "$LINK_TEMP" "$LINK_TEMP.value" || return 1
    [ "$LINK_VALID" -eq 1 ]
}

capture_text proc_net_dev "$TARGET_ROOT/proc/net/dev" "$MAX_TEXT_BYTES" network/proc-net-dev.txt required

# Interface names come only from the already bounded /proc/net/dev snapshot.
if awk -F: -v maximum="$MAX_INTERFACES" '
    NR <= 2 { next }
    {
        name=$1; gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (name == "" || length(name)>15 || name ~ /[^A-Za-z0-9_.-]/ || seen[name]++) exit 41
        count++; if (count > maximum) exit 42
        print name
    }
' network/proc-net-dev.txt > .interface-names; then :; else record_failure "interface_name_parse"; fi

: > network/interfaces.txt || record_failure "interfaces_create"
INTERFACE_COUNT=0
while IFS= read -r NAME; do
    [ -n "$NAME" ] || continue
    INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
    ENTRY="$SYS_NET_ROOT/$NAME"
    append_bounded network/interfaces.txt 262144 "interface=$NAME" || record_failure interfaces_write
    [ -d "$ENTRY" ] || { record_optional "interface_sysfs_absent:$NAME"; continue; }
    ENTRY=$(cd -P "$ENTRY" 2>/dev/null && pwd -P) || { record_failure interface_sysfs_resolve; continue; }
    DEVICES_CANONICAL=$(cd -P "$SYS_DEVICES_ROOT" 2>/dev/null && pwd -P) || { record_failure sysfs_devices_absent; continue; }
    case "$ENTRY/" in "$DEVICES_CANONICAL/"*) ;; *) record_failure "interface_outside_sysfs:$NAME"; continue ;; esac
    for ATTRIBUTE in type operstate mtu flags uevent address; do
        SOURCE="$ENTRY/$ATTRIBUTE"; VALUE_TEMP=.interface-value.tmp; NORMAL_TEMP=.interface-normal.tmp
        [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || { record_optional "interface_attribute_absent:$NAME:$ATTRIBUTE"; continue; }
        rm -f "$VALUE_TEMP" "$NORMAL_TEMP" 2>/dev/null || { record_failure "interface_temp:$NAME:$ATTRIBUTE"; continue; }
        if dd if="$SOURCE" of="$VALUE_TEMP" bs=4097 count=1 2>/dev/null; then :; else record_failure "interface_attribute_read:$NAME:$ATTRIBUTE"; continue; fi
        VALUE_SIZE=$(stat -L -c '%s' "$VALUE_TEMP" 2>/dev/null) || { record_failure "interface_attribute_stat:$NAME:$ATTRIBUTE"; continue; }
        [ "$VALUE_SIZE" -le 4096 ] || { record_failure "interface_attribute_limit:$NAME:$ATTRIBUTE"; continue; }
        if tr '\000\n' '  ' < "$VALUE_TEMP" > "$NORMAL_TEMP"; then :; else record_failure "interface_attribute_normalize:$NAME:$ATTRIBUTE"; continue; fi
        if VALUE=$(dd if="$NORMAL_TEMP" bs=4097 count=1 2>/dev/null); then :; else record_failure "interface_attribute_result:$NAME:$ATTRIBUTE"; continue; fi
        append_bounded network/interfaces.txt 262144 "$NAME.$ATTRIBUTE=$VALUE" || record_failure "interfaces_write"
    done
    for LINK in device device/driver; do
        [ -L "$ENTRY/$LINK" ] || continue
        if bounded_readlink "$ENTRY/$LINK" .interface-link.tmp; then
            append_bounded network/interfaces.txt 262144 "$NAME.$LINK=$LINK_VALUE" || record_failure "interfaces_write"
        else record_optional "interface_link_race:$NAME:$LINK"; fi
    done
done < .interface-names

CANDIDATE_PATHS=.device-candidates.paths
: > "$CANDIDATE_PATHS" || record_failure "candidate_state_create"
: > devices/device-nodes.txt || record_failure "devices_create"
DEVICE_COUNT=0
add_device() {
    ACTUAL=$1; LOGICAL=$2
    [ -e "$ACTUAL" ] || [ -L "$ACTUAL" ] || return 0
    META=$(stat -c '%F|%a|%u|%g|%t|%T' "$ACTUAL" 2>/dev/null) || { record_optional "device_stat_race:$LOGICAL"; return 0; }
    LINK_TARGET=-
    if [ -L "$ACTUAL" ]; then bounded_readlink "$ACTUAL" .device-link.tmp || { record_optional "device_link_race:$LOGICAL"; return 0; }; LINK_TARGET=$LINK_VALUE; fi
    OLD_IFS=$IFS; IFS='|'; set -- $META; IFS=$OLD_IFS
    [ "$#" -eq 6 ] || { record_failure "device_stat_format:$LOGICAL"; return 1; }
    TYPE=$1; MODE=$2; NODE_UID=$3; NODE_GID=$4; MAJOR_HEX=$5; MINOR_HEX=$6; SYS_LINK=-
    if [ -c "$ACTUAL" ] && [ ! -L "$ACTUAL" ]; then
        case "$MAJOR_HEX:$MINOR_HEX" in *[!0-9a-fA-F:]*) record_failure "device_number_format:$LOGICAL"; return 1 ;; esac
        MAJOR=$((0x$MAJOR_HEX)); MINOR=$((0x$MINOR_HEX))
        if [ -L "$SYS_DEV_CHAR_ROOT/$MAJOR:$MINOR" ]; then
            bounded_readlink "$SYS_DEV_CHAR_ROOT/$MAJOR:$MINOR" .sys-device-link.tmp || { record_optional "sys_device_link_race:$LOGICAL"; return 0; }
            SYS_LINK=$LINK_VALUE
        fi
    else MAJOR=-; MINOR=-; fi
    DEVICE_COUNT=$((DEVICE_COUNT + 1))
    [ "$DEVICE_COUNT" -le "$MAX_DEVICE_CANDIDATES" ] || { record_failure "device_candidate_limit"; return 1; }
    append_bounded "$CANDIDATE_PATHS" 65536 "$ACTUAL|$LOGICAL" || record_failure candidate_state_limit
    append_bounded devices/device-nodes.txt 65536 "$LOGICAL|$TYPE|$MODE|$NODE_UID|$NODE_GID|$MAJOR|$MINOR|$LINK_TARGET|$SYS_LINK" || record_failure "devices_write"
}

# Exact finite set: two RoadTop candidates plus can0..can7 and ttyS0..ttyS7.
add_device "$DEV_ROOT/canbox_protocol_dev" /dev/canbox_protocol_dev
add_device "$DEV_ROOT/hc_mcu_dev" /dev/hc_mcu_dev
for NUMBER in 0 1 2 3 4 5 6 7; do
    add_device "$DEV_ROOT/can$NUMBER" "/dev/can$NUMBER"
    add_device "$DEV_ROOT/ttyS$NUMBER" "/dev/ttyS$NUMBER"
done

matches_candidate() {
    MATCH_OUTPUT=.candidate-match.tmp
    if awk -F'|' -v actual="$1" '$1 == actual { found++; value=$2 } END { if (found != 1) exit 1; print value }' \
        "$CANDIDATE_PATHS" > "$MATCH_OUTPUT"; then :; else return 1; fi
    IFS= read -r MATCHED_LOGICAL < "$MATCH_OUTPUT" 2>/dev/null || return 1
}

read_start_time() {
    STAT_SOURCE=$1/stat; STAT_TEMP=.proc-stat.tmp
    [ -f "$STAT_SOURCE" ] && [ ! -L "$STAT_SOURCE" ] || return 1
    if dd if="$STAT_SOURCE" of="$STAT_TEMP" bs=8193 count=1 2>/dev/null; then :; else return 1; fi
    STAT_SIZE=$(stat -L -c '%s' "$STAT_TEMP" 2>/dev/null) || return 1
    [ "$STAT_SIZE" -le 8192 ] || return 1
    if STAT_LINE=$(dd if="$STAT_TEMP" bs=8193 count=1 2>/dev/null); then :; else return 1; fi
    case "$STAT_LINE" in *') '*) TAIL=${STAT_LINE##*) } ;; *) return 1 ;; esac
    set -- $TAIL; [ "$#" -ge 20 ] || return 1; shift 19; START_TIME=$1
    case "$START_TIME" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#START_TIME}" -le 20 ] || return 1
}

# /proc/<tid> is directly addressable even for a non-leader. One bounded
# kernel status read supplies both the thread-group identity and task state.
read_task_status() {
    TASK_SOURCE=$1/status; TASK_TEMP=.proc-status.tmp; TASK_VALUE=.proc-task-value.tmp
    [ -f "$TASK_SOURCE" ] && [ ! -L "$TASK_SOURCE" ] || return 1
    rm -f "$TASK_TEMP" "$TASK_VALUE" 2>/dev/null || return 1
    # Three bounded records cover short proc reads without per-byte FAT writes.
    dd if="$TASK_SOURCE" of="$TASK_TEMP" bs=4096 count=3 2>/dev/null || return 1
    TASK_SIZE=$(stat -c '%s' "$TASK_TEMP" 2>/dev/null) || return 1
    [ "$TASK_SIZE" -gt 0 ] && [ "$TASK_SIZE" -le 8192 ] || return 1
    awk '
        /^Tgid:/ {
            tgids++; tgid=substr($0, 6); gsub(/^[ \t]+|[ \t]+$/, "", tgid)
            if (tgid !~ /^[0-9]+$/ || length(tgid)>20) bad=1
        }
        /^State:/ {
            states++; value=substr($0, 7); gsub(/^[ \t]+|[ \t]+$/, "", value)
            if (value !~ /^[A-Za-z] \([^()]+\)$/) bad=1
            state=substr(value, 1, 1)
        }
        END { if (tgids!=1 || states!=1 || bad) exit 1; print tgid "|" state }
    ' "$TASK_TEMP" > "$TASK_VALUE" || return 1
    IFS= read -r TASK_PAIR < "$TASK_VALUE" 2>/dev/null || return 1
    case "$TASK_PAIR" in *'|'*) TGID=${TASK_PAIR%%|*}; TASK_STATE=${TASK_PAIR#*|} ;; *) return 1 ;; esac
    [ -n "$TGID" ] && [ "${#TASK_STATE}" -eq 1 ] || return 1
}

task_state_live() {
    case "$TASK_STATE" in R|S|D|T|t|I) return 0 ;; *) return 1 ;; esac
}

record_coverage_gap() {
    PROCESS_FD_COVERAGE=PARTIAL
    record_optional "$1"
}

stage_owner_text() {
    OWNER_SOURCE=$1; OWNER_LIMIT=$2; OWNER_TEMP=$3
    [ -f "$OWNER_SOURCE" ] && [ ! -L "$OWNER_SOURCE" ] || return 1
    rm -f "$OWNER_TEMP" 2>/dev/null || return 1
    if dd if="$OWNER_SOURCE" of="$OWNER_TEMP" bs=$((OWNER_LIMIT + 1)) count=1 2>/dev/null; then :; else return 1; fi
    OWNER_SIZE=$(stat -L -c '%s' "$OWNER_TEMP" 2>/dev/null) || return 1
    [ "$OWNER_SIZE" -le "$OWNER_LIMIT" ] || return 1
}

commit_owner_file() {
    OWNER_LABEL=$1; OWNER_SOURCE=$2; OWNER_TEMP=$3; OWNER_DEST=$4
    OWNER_SIZE=$(stat -L -c '%s' "$OWNER_TEMP" 2>/dev/null) || { record_failure "$OWNER_LABEL:size"; return 1; }
    commit_file "$OWNER_TEMP" "$OWNER_DEST" || { record_failure "$OWNER_LABEL:commit"; return 1; }
    hash_committed "$OWNER_DEST" || return 1
    inventory_row "$OWNER_LABEL" OWNER "$OWNER_SOURCE" "$OWNER_SIZE" "$OWNER_DEST"
}

: > processes/owners.txt || record_failure "owners_create"
: > processes/leaders.txt || record_failure "leaders_create"
: > .owners-seen || record_failure "owner_state_create"
PROCESS_COUNT=0; TOTAL_FD_LINKS=0; OWNER_COUNT=0; TOTAL_MAPS=0; PROCESS_FD_COVERAGE=COMPLETE
cleanup_leader_stage() {
    rm -f .leader-fds.tmp \
        ".owner-$PID-comm.tmp" ".owner-$PID-cmdline.tmp" ".owner-$PID-maps.tmp" \
        ".owner-$PID-exe.tmp" ".owner-$PID-exe-link.tmp" ".owner-$PID-exe-link.tmp.value" \
        .fd-link-before.tmp .fd-link-before.tmp.value \
        .fd-link-after.tmp .fd-link-after.tmp.value
}
PID=1
while [ "$PID" -le "$PID_SCAN_MAX" ]; do
    PDIR="$PROCESS_ROOT/$PID"
    if [ -d "$PDIR" ] && [ ! -L "$PDIR" ]; then
        if ! read_task_status "$PDIR"; then record_coverage_gap "pid_status_unusable:$PID"; PID=$((PID + 1)); continue; fi
        case "$TGID" in 0|0*) record_coverage_gap "pid_tgid_invalid:$PID"; PID=$((PID + 1)); continue ;; esac
        if [ "${#TGID}" -gt 4 ] || [ "$TGID" -gt "$PID_SCAN_MAX" ]; then
            record_coverage_gap "pid_tgid_outside_scan:$PID"; PID=$((PID + 1)); continue
        fi
        [ "$TGID" -eq "$PID" ] || { PID=$((PID + 1)); continue; }
        if ! task_state_live; then
            record_coverage_gap "process_leader_uninspectable:$PID:$TASK_STATE"; PID=$((PID + 1)); continue
        fi
        if read_start_time "$PDIR"; then START_BEFORE=$START_TIME; else record_coverage_gap "pid_race:$PID"; PID=$((PID + 1)); continue; fi
        [ -d "$PDIR/fd" ] && [ ! -L "$PDIR/fd" ] && [ -r "$PDIR/fd" ] && [ -x "$PDIR/fd" ] || {
            record_coverage_gap "leader_fd_unavailable:$PID"; PID=$((PID + 1)); continue
        }
        cleanup_leader_stage || { record_failure "leader_stage_cleanup:$PID"; break; }
        : > .leader-fds.tmp || { record_failure "leader_stage_create:$PID"; break; }
        LEADER_FD_LINKS=0; LEADER_HAS_OWNER=0; LEADER_UNUSABLE=0
        [ "$FAILURES" -eq 0 ] || break
        FD_NUMBER=0
        while [ "$FD_NUMBER" -le "$FD_NUMBER_MAX" ]; do
            FD_PATH="$PDIR/fd/$FD_NUMBER"
            if [ -L "$FD_PATH" ]; then
                LEADER_FD_LINKS=$((LEADER_FD_LINKS + 1))
                [ $((TOTAL_FD_LINKS + LEADER_FD_LINKS)) -le "$MAX_TOTAL_FD_LINKS" ] || { record_failure "total_fd_limit"; break; }
                if ! bounded_readlink "$FD_PATH" .fd-link-before.tmp; then
                    record_coverage_gap "fd_disappeared:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                fi
                TARGET_BEFORE=$LINK_VALUE
                if ! matches_candidate "$TARGET_BEFORE"; then FD_NUMBER=$((FD_NUMBER + 1)); continue; fi
                LOGICAL_TARGET=$MATCHED_LOGICAL
                FD_ID_BEFORE=$(stat -L -c '%d|%i|%f' "$FD_PATH" 2>/dev/null) || {
                    record_coverage_gap "fd_stat_race:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                }
                if [ "$LEADER_HAS_OWNER" -eq 0 ]; then
                    if stage_owner_text "$PDIR/comm" 4096 ".owner-$PID-comm.tmp" &&
                       stage_owner_text "$PDIR/cmdline" 16384 ".owner-$PID-cmdline.tmp" &&
                       stage_owner_text "$PDIR/maps" "$MAX_MAPS_PER_PROCESS" ".owner-$PID-maps.tmp" &&
                       bounded_readlink "$PDIR/exe" ".owner-$PID-exe-link.tmp" &&
                       printf '%s\n' "$LINK_VALUE" > ".owner-$PID-exe.tmp"; then
                        LEADER_HAS_OWNER=1
                    else
                        record_coverage_gap "owner_race_unusable:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                    fi
                fi
                # Per-FD identity bracket; the whole group is still staged.
                if ! read_task_status "$PDIR" || [ "$TGID" != "$PID" ] || ! task_state_live ||
                   ! read_start_time "$PDIR" || [ "$START_TIME" != "$START_BEFORE" ] ||
                   ! bounded_readlink "$FD_PATH" .fd-link-after.tmp || [ "$LINK_VALUE" != "$TARGET_BEFORE" ]; then
                    record_coverage_gap "owner_race_unusable:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                fi
                FD_ID_AFTER=$(stat -L -c '%d|%i|%f' "$FD_PATH" 2>/dev/null) || {
                    record_coverage_gap "owner_race_unusable:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                }
                if [ "$FD_ID_AFTER" != "$FD_ID_BEFORE" ]; then
                    record_coverage_gap "owner_race_unusable:$PID:$FD_NUMBER"; LEADER_UNUSABLE=1; break
                fi
                append_bounded .leader-fds.tmp 16384 "$PID|$PID|$START_BEFORE|$FD_NUMBER|$LOGICAL_TARGET" || record_failure "leader_fd_stage:$PID"
                [ "$FAILURES" -eq 0 ] || break
            fi
            FD_NUMBER=$((FD_NUMBER + 1))
        done
        [ "$FAILURES" -eq 0 ] || break
        if [ "$LEADER_UNUSABLE" -ne 0 ]; then
            cleanup_leader_stage || record_failure "leader_stage_cleanup:$PID"
            PID=$((PID + 1)); continue
        fi
        # Only a complete 0..127 scan of the same live leader is retained.
        if ! read_task_status "$PDIR" || [ "$TGID" != "$PID" ] || ! task_state_live ||
           ! read_start_time "$PDIR" || [ "$START_TIME" != "$START_BEFORE" ] ||
           [ ! -d "$PDIR/fd" ] || [ -L "$PDIR/fd" ] || [ ! -r "$PDIR/fd" ] || [ ! -x "$PDIR/fd" ]; then
            record_coverage_gap "process_leader_race:$PID"
            cleanup_leader_stage || record_failure "leader_stage_cleanup:$PID"
            PID=$((PID + 1)); continue
        fi
        PROCESS_COUNT=$((PROCESS_COUNT + 1))
        [ "$PROCESS_COUNT" -le "$MAX_PROCESSES" ] || { record_failure "process_limit"; break; }
        TOTAL_FD_LINKS=$((TOTAL_FD_LINKS + LEADER_FD_LINKS))
        append_bounded processes/leaders.txt 16384 "$PID|$PID|$START_BEFORE" || record_failure "leaders_write"
        [ "$FAILURES" -eq 0 ] || break
        if [ "$LEADER_HAS_OWNER" -eq 1 ]; then
            OWNER_COUNT=$((OWNER_COUNT + 1))
            [ "$OWNER_COUNT" -le "$MAX_OWNERS" ] || { record_failure "owner_limit"; break; }
            MAP_SIZE=$(stat -L -c '%s' ".owner-$PID-maps.tmp" 2>/dev/null) || { record_failure "owner_maps_size:$PID"; break; }
            TOTAL_MAPS=$((TOTAL_MAPS + MAP_SIZE))
            [ "$TOTAL_MAPS" -le "$MAX_TOTAL_MAPS" ] || { record_failure "total_maps_limit"; break; }
            commit_owner_file "owner_comm_$PID" "$PDIR/comm" ".owner-$PID-comm.tmp" "processes/$PID-comm.txt"
            commit_owner_file "owner_cmdline_$PID" "$PDIR/cmdline" ".owner-$PID-cmdline.tmp" "processes/$PID-cmdline.bin"
            commit_owner_file "owner_exe_$PID" "$PDIR/exe" ".owner-$PID-exe.tmp" "processes/$PID-exe.txt"
            commit_owner_file "owner_maps_$PID" "$PDIR/maps" ".owner-$PID-maps.tmp" "processes/$PID-maps.txt"
            append_bounded .owners-seen 4096 "$PID|$START_BEFORE" || record_failure "owner_state_write"
            while IFS= read -r OWNER_ROW; do
                append_bounded processes/owners.txt 131072 "$OWNER_ROW" || record_failure "owners_write"
            done < .leader-fds.tmp
        fi
        cleanup_leader_stage || record_failure "leader_stage_cleanup:$PID"
    fi
    [ "$FAILURES" -eq 0 ] || break
    PID=$((PID + 1))
done
cleanup_leader_stage || record_failure "leader_stage_cleanup_final"

validate_application_boundary() {
    APP_PATH="$TARGET_ROOT/application"
    [ -d "$APP_PATH" ] || return 1
    APP_CANONICAL=$(cd -P "$APP_PATH" 2>/dev/null && pwd -P) || return 1
    LIBRARY_GUARD=../library_mount_guard.sh
    is_regular_nonsymlink "$LIBRARY_GUARD" || return 1
}

validate_application_boundary || record_failure "application_boundary_unavailable"
TOTAL_LIBRARY_BYTES=0
snapshot_library() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST=$4; TEMP="$DEST.tmp"; RESULT=".$LABEL.result"
    rm -f "$TEMP" "$RESULT" 2>/dev/null || return 1
    case "$LABEL:$SOURCE:$DEST" in
        "appframework:$TARGET_ROOT/application/lib/libappframework.so.1.0.0:files/libappframework.so.1.0.0"|\
        "appmcu:$TARGET_ROOT/application/lib/libappmcucommunication.so.1.0.0:files/libappmcucommunication.so.1.0.0") ;;
        *) record_failure "$LABEL:source_not_allowlisted"; return 1 ;;
    esac
    [ "$FAILURES" -eq 0 ] || return 1
    # Metadata-only preflight. There is no descriptor/data open before it passes.
    [ ! -L "$SOURCE" ] || { record_failure "$LABEL:source_symlink"; return 1; }
    SOURCE_TYPE=$(stat -c '%F' "$SOURCE" 2>/dev/null) || { record_failure "$LABEL:source_stat"; return 1; }
    [ "$SOURCE_TYPE" = "regular file" ] || { record_failure "$LABEL:source_not_regular"; return 1; }
    SOURCE_PARENT=$(cd -P "$(dirname "$SOURCE")" 2>/dev/null && pwd -P) || { record_failure "$LABEL:source_parent"; return 1; }
    case "$SOURCE_PARENT/" in "$APP_CANONICAL/"*) ;; *) record_failure "$LABEL:outside_application"; return 1 ;; esac
    /bin/sh "$LIBRARY_GUARD" "$SOURCE" "$APP_CANONICAL" "$TARGET_MOUNTS_FILE" > .application-mount.tmp ||
        { record_failure "$LABEL:effective_mount_invalid"; return 1; }
    /bin/sh -c '
        SOURCE=$1; LIMIT=$2; SNAPSHOT=$3; RESULT=$4; FD_ROOT=$5; APP_ROOT=$6; MOUNTS=$7; GUARD=$8
        [ ! -L "$SOURCE" ] || exit 20
        [ "$(stat -c "%F" "$SOURCE")" = "regular file" ] || exit 21
        PARENT=$(cd -P "$(dirname "$SOURCE")" 2>/dev/null && pwd -P) || exit 22
        case "$PARENT/" in "$APP_ROOT/"*) ;; *) exit 22 ;; esac
        CANONICAL=$(/bin/sh "$GUARD" "$SOURCE" "$APP_ROOT" "$MOUNTS") || exit 23
        [ "$CANONICAL" = "$PARENT/${SOURCE##*/}" ] || exit 23
        SOURCE=$CANONICAL
        PREOPEN=$(stat -c "%d|%i|%f|%s|%Y|%Z" "$SOURCE") || exit 24
        exec 3< "$SOURCE" || exit 25
        [ -f "$FD_ROOT/3" ] && [ ! -L "$SOURCE" ] || exit 26
        BEFORE=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 27
        [ "$BEFORE" = "$PREOPEN" ] || exit 27
        OLD_IFS=$IFS; IFS="|"; set -- $BEFORE; IFS=$OLD_IFS
        [ "$#" -eq 6 ] || exit 28
        SIZE=$4; case "$SIZE" in ""|*[!0-9]*) exit 28 ;; esac
        [ "$SIZE" -le "$LIMIT" ] || exit 29
        BLOCKS=$((SIZE / 4096)); REST=$((SIZE % 4096)); : > "$SNAPSHOT" || exit 30
        [ "$BLOCKS" -eq 0 ] || dd bs=4096 count="$BLOCKS" <&3 > "$SNAPSHOT" 2>/dev/null || exit 30
        [ "$REST" -eq 0 ] || dd bs=1 count="$REST" <&3 >> "$SNAPSHOT" 2>/dev/null || exit 30
        AFTER=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 31
        [ "$AFTER" = "$BEFORE" ] && [ ! -L "$SOURCE" ] || exit 31
        [ "$(stat -c "%d|%i|%f|%s|%Y|%Z" "$SOURCE")" = "$BEFORE" ] || exit 31
        [ "$(stat -L -c "%s" "$SNAPSHOT")" = "$SIZE" ] || exit 32
        printf "size=%s\n" "$SIZE" > "$RESULT" || exit 33
    ' sh "$SOURCE" "$LIMIT" "$TEMP" "$RESULT" "$FD_ROOT" "$APP_CANONICAL" "$TARGET_MOUNTS_FILE" "$LIBRARY_GUARD" || {
        record_failure "$LABEL:snapshot_failed"; rm -f "$TEMP" "$RESULT"; return 1;
    }
    is_regular_nonsymlink "$RESULT" || { record_failure "$LABEL:result_invalid"; return 1; }
    IFS= read -r LINE < "$RESULT" 2>/dev/null || { record_failure "$LABEL:size_result"; return 1; }
    SIZE=${LINE#size=}; case "$LINE:$SIZE" in size=:*|*:*[!0-9]*) record_failure "$LABEL:size_result"; return 1 ;; esac
    TOTAL_LIBRARY_BYTES=$((TOTAL_LIBRARY_BYTES + SIZE))
    [ "$TOTAL_LIBRARY_BYTES" -le "$MAX_TOTAL_LIBRARY_BYTES" ] || { record_failure "library_total_limit"; return 1; }
    commit_file "$TEMP" "$DEST" || { record_failure "$LABEL:commit_failed"; return 1; }
    rm -f "$RESULT"
    hash_committed "$DEST" || return 1
    inventory_row "$LABEL" COPY "$SOURCE" "$SIZE" "$DEST"
}
snapshot_library appframework "$TARGET_ROOT/application/lib/libappframework.so.1.0.0" "$MAX_FRAMEWORK_BYTES" files/libappframework.so.1.0.0
snapshot_library appmcu "$TARGET_ROOT/application/lib/libappmcucommunication.so.1.0.0" "$MAX_MCU_LIBRARY_BYTES" files/libappmcucommunication.so.1.0.0

printf '%s\n' \
    "schema=4" "scope=w176-stage4a-can-mcu-topology" \
    "interfaces=$INTERFACE_COUNT" "device_candidates=$DEVICE_COUNT" \
    "processes_inspected=$PROCESS_COUNT" "fd_links_inspected=$TOTAL_FD_LINKS" \
    "matched_owners=$OWNER_COUNT" "process_fd_coverage=$PROCESS_FD_COVERAGE" \
    "library_bytes=$TOTAL_LIBRARY_BYTES" > SUMMARY.txt || record_failure "summary_write"

printf '%s\n' \
    "schema=4" "device_streams.opened=0" "can_frames.received=0" \
    "can_frames.transmitted=0" "mcu_commands.sent=0" "logging.capture=DEFERRED" \
    "pid.scan.max=$PID_SCAN_MAX" "processes.present.max=$MAX_PROCESSES" \
    "fd.number.max=$FD_NUMBER_MAX" "fd_links.total.max=$MAX_TOTAL_FD_LINKS" \
    "owners.max=$MAX_OWNERS" "maps.per_process.bytes.max=$MAX_MAPS_PER_PROCESS" \
    "maps.total.bytes.max=$MAX_TOTAL_MAPS" "interfaces.max=$MAX_INTERFACES" \
    "devices.max=$MAX_DEVICE_CANDIDATES" "symlink.bytes.max=$MAX_SYMLINK_BYTES" \
    "libappframework.bytes.max=$MAX_FRAMEWORK_BYTES" \
    "libappmcucommunication.bytes.max=$MAX_MCU_LIBRARY_BYTES" \
    "libraries.total.bytes.max=$MAX_TOTAL_LIBRARY_BYTES" "owner.identity=PID_EQUALS_TGID" \
    "output.final_capture.kib.max=$MAX_TOTAL_OUTPUT_KIB" \
    "output.write_ceiling=NOT_CLAIMED" "all_writers.individually_bounded=1" \
    "application.boundary=effective-mount-exact-squashfs,ro" "process_pid_above_scan_max=NOT_INSPECTED" \
    "fd_number_above_max=NOT_INSPECTED" > CAPABILITIES.txt || record_failure "capabilities_write"

for OUTPUT_PATH in network/interfaces.txt devices/device-nodes.txt processes/leaders.txt processes/owners.txt SUMMARY.txt CAPABILITIES.txt; do hash_committed "$OUTPUT_PATH"; done

if du -sk . > .du-output.tmp 2>/dev/null; then :; else record_failure "output_size_unavailable"; fi
if awk 'NR == 1 && NF >= 1 && $1 ~ /^[0-9]+$/ { print $1; ok=1 } END { if (!ok || NR != 1) exit 1 }' \
    .du-output.tmp > .du-value.tmp; then :; else record_failure "output_size_invalid"; fi
if IFS= read -r OUTPUT_KIB < .du-value.tmp 2>/dev/null; then [ "$OUTPUT_KIB" -le "$MAX_TOTAL_OUTPUT_KIB" ] || record_failure "output_limit"; else record_failure "output_size_missing"; fi

rm -f .interface-names .interface-value.tmp .interface-normal.tmp .interface-link.tmp \
    .interface-link.tmp.value .device-candidates.paths .device-link.tmp .device-link.tmp.value \
    .sys-device-link.tmp .sys-device-link.tmp.value .candidate-match.tmp \
    .proc-stat.tmp .proc-status.tmp .proc-task-value.tmp .leader-fds.tmp \
    .fd-link-before.tmp .fd-link-before.tmp.value .fd-link-after.tmp .fd-link-after.tmp.value .owners-seen \
    .application-mount.tmp .du-output.tmp .du-value.tmp 2>/dev/null || record_failure "temporary_cleanup"

for REQUIRED_OUTPUT in CAPABILITIES.txt SUMMARY.txt network/proc-net-dev.txt network/interfaces.txt devices/device-nodes.txt processes/leaders.txt processes/owners.txt files/libappframework.so.1.0.0 files/libappmcucommunication.so.1.0.0; do
    is_regular_nonsymlink "$REQUIRED_OUTPUT" || record_failure "required_output_invalid:$REQUIRED_OUTPUT"
done

commit_file "$INVENTORY_WORK" capture-inventory.txt || record_failure "inventory_commit"
hash_committed capture-inventory.txt
commit_file "$OPTIONAL_WORK" OPTIONAL.txt || record_failure "optional_commit"
commit_file "$ERROR_WORK" ERRORS.txt || { FAILURES=$((FAILURES + 1)); }
hash_committed OPTIONAL.txt
hash_committed ERRORS.txt
[ "$FAILURES" -eq 0 ] || finish_incomplete

# Each late operation is fail-closed; no successful marker precedes this gate.
final_transaction() {
    status_write COMPLETE || finish_incomplete
    hash_committed STATUS.txt || finish_incomplete
    [ "$FAILURES" -eq 0 ] || finish_incomplete
    COMPLETE_TEMP=.COMPLETE.tmp
    printf 'complete=1\n' > "$COMPLETE_TEMP" || finish_incomplete
    COMPLETE_SIZE=$(stat -c '%s' "$COMPLETE_TEMP") || finish_incomplete
    [ "$COMPLETE_SIZE" = 11 ] || finish_incomplete
    COMPLETE_CONTENT=$(dd if="$COMPLETE_TEMP" bs=12 count=1 2>/dev/null) || finish_incomplete
    [ "$COMPLETE_CONTENT" = 'complete=1' ] || finish_incomplete
    strict_sha256 "$COMPLETE_TEMP" COMPLETE || finish_incomplete
    rm -f "$CHECKSUM_PATHS" .sha256-output.tmp .sha256-digest.tmp 2>/dev/null || finish_incomplete
    commit_file "$CHECKSUM_WORK" checksums.sha256 || finish_incomplete
    for REQUIRED in STATUS.txt ERRORS.txt OPTIONAL.txt CAPABILITIES.txt SUMMARY.txt capture-inventory.txt checksums.sha256 network/proc-net-dev.txt network/interfaces.txt devices/device-nodes.txt processes/leaders.txt processes/owners.txt files/libappframework.so.1.0.0 files/libappmcucommunication.so.1.0.0; do
        is_regular_nonsymlink "$REQUIRED" || finish_incomplete
    done
    [ ! -s ERRORS.txt ] || finish_incomplete
    awk -F= '$1 == "status" { status=$2; sc++ } $1 == "mandatory_failures" { failures=$2; fc++ } END { if (sc != 1 || fc != 1 || status != "COMPLETE" || failures != "0") exit 1 }' STATUS.txt >/dev/null 2>&1 || finish_incomplete
    # Final acceptance, not a write-admission budget; include control records.
    du -sk . > .du-output.tmp 2>/dev/null || finish_incomplete
    awk 'NR == 1 && NF >= 1 && $1 ~ /^[0-9]+$/ { print $1; ok=1 } END { if (!ok || NR != 1) exit 1 }' .du-output.tmp > .du-value.tmp || finish_incomplete
    IFS= read -r OUTPUT_KIB < .du-value.tmp || finish_incomplete
    [ "$OUTPUT_KIB" -le "$MAX_TOTAL_OUTPUT_KIB" ] || finish_incomplete
    rm -f .du-output.tmp .du-value.tmp || finish_incomplete
    is_regular_nonsymlink "$COMPLETE_TEMP" || finish_incomplete
    [ ! -e COMPLETE ] && [ ! -L COMPLETE ] || finish_incomplete
    [ "$FAILURES" -eq 0 ] || finish_incomplete
    # Exact hashed temp is renamed LAST. No post-rename operation is mandatory.
    mv "$COMPLETE_TEMP" COMPLETE || finish_incomplete
    exit 0
}
final_transaction
