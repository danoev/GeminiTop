#!/bin/sh
# W176 Stage-4A CAN/MCU topology metadata capture. Never opens device streams.
set -u

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
TARGET_ROOT=/
PROCESS_ROOT=/proc
FD_ROOT=/proc/self/fd
SYS_NET_ROOT=/sys/class/net
SYS_DEV_CHAR_ROOT=/sys/dev/char
DEV_ROOT=/dev
MAX_PROCESSES=256
MAX_FDS_PER_PROCESS=128
MAX_TOTAL_FD_LINKS=4096
MAX_OWNERS=16
MAX_MAPS_PER_PROCESS=65536
MAX_TOTAL_MAPS=524288
MAX_INTERFACES=32
MAX_DEVICE_CANDIDATES=64
MAX_FRAMEWORK_BYTES=393216
MAX_MCU_LIBRARY_BYTES=327680
MAX_TOTAL_LIBRARY_BYTES=720896
MAX_TEXT_BYTES=65536
MAX_CONFIG_CANDIDATES=32
MAX_TOTAL_OUTPUT_KIB=2048
export PATH

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

OUT=stage4-topology
INDEX=0
while [ "$INDEX" -lt 100 ]; do
    [ "$INDEX" -eq 0 ] && CANDIDATE=$OUT || CANDIDATE="$OUT-$INDEX"
    if [ ! -e "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ]; then mkdir "$CANDIDATE" 2>/dev/null && { OUT=$CANDIDATE; break; }; exit 1; fi
    INDEX=$((INDEX + 1))
done
[ -d "$OUT" ] || exit 1
cd "$OUT" || exit 1
mkdir network devices processes files metadata || exit 1

FAILURES=0
OPTIONALS=0
ERROR_WORK=.ERRORS.txt.work
OPTIONAL_WORK=.OPTIONAL.txt.work
INVENTORY_WORK=.capture-inventory.txt.work
CHECKSUM_WORK=.checksums.sha256.work
: > "$ERROR_WORK" && : > "$OPTIONAL_WORK" && : > "$INVENTORY_WORK" && : > "$CHECKSUM_WORK" || exit 1

commit_file() { is_regular_nonsymlink "$1" && mv "$1" "$2" && is_regular_nonsymlink "$2"; }
status_write() {
    printf '%s\n' "schema=1" "scope=w176-stage4a-can-mcu-topology" "status=$1" \
        "mandatory_failures=$FAILURES" "optional_findings=$OPTIONALS" > .STATUS.txt.tmp &&
        commit_file .STATUS.txt.tmp STATUS.txt
}
record_failure() { FAILURES=$((FAILURES + 1)); printf 'error.%s=%s\n' "$FAILURES" "$1" >> "$ERROR_WORK" || true; }
record_optional() { OPTIONALS=$((OPTIONALS + 1)); printf 'optional.%s=%s\n' "$OPTIONALS" "$1" >> "$OPTIONAL_WORK" || true; }
finish_incomplete() {
    commit_file "$ERROR_WORK" ERRORS.txt 2>/dev/null || true
    commit_file "$OPTIONAL_WORK" OPTIONAL.txt 2>/dev/null || true
    status_write INCOMPLETE 2>/dev/null || true
    exit 1
}
status_write INCOMPLETE || exit 1

for COMMAND in awk dd du grep mkdir mv readlink rm sed sha256sum stat tr wc; do
    command -v "$COMMAND" >/dev/null 2>&1 || record_failure "missing_command:$COMMAND"
done
[ "$FAILURES" -eq 0 ] || finish_incomplete

capture_text() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST=$4; REQUIRED=$5
    TEMP="$DEST.tmp"
    rm -f "$TEMP" 2>/dev/null || return 1
    if [ ! -f "$SOURCE" ] || [ -L "$SOURCE" ]; then
        [ "$REQUIRED" = required ] && record_failure "$LABEL:invalid_source" || record_optional "$LABEL:absent"
        return 1
    fi
    dd if="$SOURCE" of="$TEMP" bs=$((LIMIT + 1)) count=1 2>/dev/null || {
        rm -f "$TEMP"; [ "$REQUIRED" = required ] && record_failure "$LABEL:read_failed" || record_optional "$LABEL:read_failed"; return 1;
    }
    SIZE=$(stat -L -c '%s' "$TEMP" 2>/dev/null) || return 1
    [ "$SIZE" -le "$LIMIT" ] || { rm -f "$TEMP"; record_failure "$LABEL:limit_exceeded"; return 1; }
    commit_file "$TEMP" "$DEST" || { record_failure "$LABEL:commit_failed"; return 1; }
    DIGEST=$(sha256sum "$DEST" | awk '{print $1}') || { record_failure "$LABEL:hash_failed"; return 1; }
    printf '%s  %s\n' "$DIGEST" "$DEST" >> "$CHECKSUM_WORK" || record_failure "checksums_write"
    printf '%s|TEXT|OK|%s|%s|%s\n' "$LABEL" "$SOURCE" "$SIZE" "$DEST" >> "$INVENTORY_WORK" || record_failure "inventory_write"
}

capture_text proc_net_dev "$TARGET_ROOT/proc/net/dev" "$MAX_TEXT_BYTES" network/proc-net-dev.txt required

INTERFACE_COUNT=0
: > network/interfaces.txt
for ENTRY in "$SYS_NET_ROOT"/*; do
    [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || continue
    INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
    [ "$INTERFACE_COUNT" -le "$MAX_INTERFACES" ] || { record_failure "network_interface_limit"; break; }
    NAME=${ENTRY##*/}
    case "$NAME" in ''|*[!A-Za-z0-9_.:-]*) record_optional "interface_name_rejected:$NAME"; continue ;; esac
    printf 'interface=%s\n' "$NAME" >> network/interfaces.txt || record_failure "interfaces_write"
    for ATTRIBUTE in type operstate mtu flags uevent address; do
        SOURCE="$ENTRY/$ATTRIBUTE"
        if [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
            VALUE=$(dd if="$SOURCE" bs=4097 count=1 2>/dev/null | tr '\000\n' '  ')
            [ "$(printf '%s' "$VALUE" | wc -c)" -le 4096 ] || { record_failure "interface_attribute_limit:$NAME:$ATTRIBUTE"; continue; }
            printf '%s.%s=%s\n' "$NAME" "$ATTRIBUTE" "$VALUE" >> network/interfaces.txt || record_failure "interfaces_write"
        fi
    done
    for LINK in device device/driver; do
        [ -L "$ENTRY/$LINK" ] || continue
        VALUE=$(readlink "$ENTRY/$LINK" 2>/dev/null) || { record_optional "interface_link_race:$NAME:$LINK"; continue; }
        printf '%s.%s=%s\n' "$NAME" "$LINK" "$VALUE" >> network/interfaces.txt || record_failure "interfaces_write"
    done
done

CANDIDATE_PATHS=.device-candidates.paths
: > "$CANDIDATE_PATHS"
: > devices/device-nodes.txt
DEVICE_COUNT=0
add_device() {
    PATHNAME=$1
    [ -e "$PATHNAME" ] || [ -L "$PATHNAME" ] || return 0
    grep -F -x "$PATHNAME" "$CANDIDATE_PATHS" >/dev/null 2>&1 && return 0
    DEVICE_COUNT=$((DEVICE_COUNT + 1))
    [ "$DEVICE_COUNT" -le "$MAX_DEVICE_CANDIDATES" ] || { record_failure "device_candidate_limit"; return 1; }
    printf '%s\n' "$PATHNAME" >> "$CANDIDATE_PATHS" || return 1
    META=$(stat -c '%F|%a|%u|%g|%t|%T' "$PATHNAME" 2>/dev/null) || { record_optional "device_stat_race:$PATHNAME"; return 0; }
    LINK_TARGET=-; [ ! -L "$PATHNAME" ] || LINK_TARGET=$(readlink "$PATHNAME" 2>/dev/null || printf '%s' RACE)
    OLD_IFS=$IFS; IFS='|'; set -- $META; IFS=$OLD_IFS
    [ "$#" -eq 6 ] || { record_failure "device_stat_format:$PATHNAME"; return 1; }
    TYPE=$1; MODE=$2; NODE_UID=$3; NODE_GID=$4; MAJOR_HEX=$5; MINOR_HEX=$6; SYS_LINK=-
    if [ -c "$PATHNAME" ] && [ ! -L "$PATHNAME" ]; then
        MAJOR=$((0x$MAJOR_HEX)); MINOR=$((0x$MINOR_HEX))
        [ ! -L "$SYS_DEV_CHAR_ROOT/$MAJOR:$MINOR" ] || SYS_LINK=$(readlink "$SYS_DEV_CHAR_ROOT/$MAJOR:$MINOR" 2>/dev/null || printf '%s' RACE)
    else MAJOR=-; MINOR=-; fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$PATHNAME" "$TYPE" "$MODE" "$NODE_UID" "$NODE_GID" "$MAJOR" "$MINOR" "$LINK_TARGET" "$SYS_LINK" >> devices/device-nodes.txt || record_failure "devices_write"
}

for EXACT in "$DEV_ROOT/canbox_protocol_dev" "$DEV_ROOT/hc_mcu_dev" "$DEV_ROOT/ttyS1"; do add_device "$EXACT"; done
for PATHNAME in "$DEV_ROOT"/*; do
    NAME=${PATHNAME##*/}
    case "$NAME" in can*|canbox*|*mcu*|hc*|uart*|ttyS*) add_device "$PATHNAME" ;; esac
done

matches_candidate() { grep -F -x "$1" "$CANDIDATE_PATHS" >/dev/null 2>&1; }
read_start_time() {
    STAT_LINE=$(dd if="$1/stat" bs=8193 count=1 2>/dev/null) || return 1
    [ "$(printf '%s' "$STAT_LINE" | wc -c)" -le 8192 ] || return 1
    case "$STAT_LINE" in *') '*) TAIL=${STAT_LINE##*) } ;; *) return 1 ;; esac
    set -- $TAIL; [ "$#" -ge 20 ] || return 1; shift 19; START_TIME=$1
    case "$START_TIME" in ''|*[!0-9]*) return 1 ;; esac
}

: > processes/owners.txt
: > .owners-seen
PROCESS_COUNT=0; TOTAL_FD_LINKS=0; OWNER_COUNT=0; TOTAL_MAPS=0
for PDIR in "$PROCESS_ROOT"/[0-9]*; do
    [ -d "$PDIR" ] || continue
    PROCESS_COUNT=$((PROCESS_COUNT + 1)); [ "$PROCESS_COUNT" -le "$MAX_PROCESSES" ] || { record_failure "process_limit"; break; }
    PID=${PDIR##*/}; read_start_time "$PDIR" || { record_optional "pid_race:$PID"; continue; }; START_BEFORE=$START_TIME
    FD_COUNT=0
    for FD_PATH in "$PDIR/fd"/*; do
        [ -L "$FD_PATH" ] || continue
        FD_COUNT=$((FD_COUNT + 1)); TOTAL_FD_LINKS=$((TOTAL_FD_LINKS + 1))
        [ "$FD_COUNT" -le "$MAX_FDS_PER_PROCESS" ] || { record_failure "fd_per_process_limit:$PID"; break; }
        [ "$TOTAL_FD_LINKS" -le "$MAX_TOTAL_FD_LINKS" ] || { record_failure "total_fd_limit"; break; }
        TARGET_ONE=$(readlink "$FD_PATH" 2>/dev/null) || { record_optional "fd_disappeared:$PID:${FD_PATH##*/}"; continue; }
        matches_candidate "$TARGET_ONE" || continue
        TARGET_TWO=$(readlink "$FD_PATH" 2>/dev/null) || { record_optional "fd_disappeared:$PID:${FD_PATH##*/}"; continue; }
        [ "$TARGET_ONE" = "$TARGET_TWO" ] || { record_optional "fd_replaced:$PID:${FD_PATH##*/}"; continue; }
        read_start_time "$PDIR" || { record_optional "pid_disappeared:$PID"; continue; }
        [ "$START_TIME" = "$START_BEFORE" ] || { record_optional "pid_reused:$PID"; continue; }
        if ! grep -F -x "$PID|$START_BEFORE" .owners-seen >/dev/null 2>&1; then
            OWNER_COUNT=$((OWNER_COUNT + 1)); [ "$OWNER_COUNT" -le "$MAX_OWNERS" ] || { record_failure "owner_limit"; break; }
            printf '%s|%s\n' "$PID" "$START_BEFORE" >> .owners-seen || record_failure "owner_state_write"
            capture_text "owner_comm_$PID" "$PDIR/comm" 4096 "processes/$PID-comm.txt" optional
            capture_text "owner_cmdline_$PID" "$PDIR/cmdline" 16384 "processes/$PID-cmdline.bin" optional
            EXE=$(readlink "$PDIR/exe" 2>/dev/null || printf '%s' RACE)
            printf '%s\n' "$EXE" > "processes/$PID-exe.txt" || record_failure "owner_exe_write:$PID"
            MAP_DEST="processes/$PID-maps.txt"
            capture_text "owner_maps_$PID" "$PDIR/maps" "$MAX_MAPS_PER_PROCESS" "$MAP_DEST" optional
            if [ -f "$MAP_DEST" ]; then MAP_SIZE=$(stat -L -c '%s' "$MAP_DEST"); TOTAL_MAPS=$((TOTAL_MAPS + MAP_SIZE)); [ "$TOTAL_MAPS" -le "$MAX_TOTAL_MAPS" ] || record_failure "total_maps_limit"; fi
        fi
        printf '%s|%s|%s|%s\n' "$PID" "$START_BEFORE" "${FD_PATH##*/}" "$TARGET_ONE" >> processes/owners.txt || record_failure "owners_write"
    done
    [ "$FAILURES" -eq 0 ] || break
done

TOTAL_LIBRARY_BYTES=0
snapshot_library() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST="files/${SOURCE##*/}"; TEMP="$DEST.tmp"; RESULT=".$LABEL.result"
    rm -f "$TEMP" "$RESULT" 2>/dev/null || return 1
    /bin/sh -c '
        SOURCE=$1
        LIMIT=$2
        SNAPSHOT=$3
        RESULT=$4
        FD_ROOT=$5
        exec 3< "$SOURCE" || exit 20
        [ -f "$FD_ROOT/3" ] && [ ! -L "$SOURCE" ] || exit 21
        BEFORE=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 22
        PATH_ID=$(stat -L -c "%d|%i" "$SOURCE") || exit 23
        case "$BEFORE" in "$PATH_ID|"*) ;; *) exit 23 ;; esac
        OLD_IFS=$IFS
        IFS="|"
        set -- $BEFORE
        IFS=$OLD_IFS
        [ "$#" -eq 6 ] || exit 24
        SIZE=$4
        case "$SIZE" in ""|*[!0-9]*) exit 24 ;; esac
        [ "$SIZE" -le "$LIMIT" ] || exit 25
        BLOCKS=$((SIZE / 4096)); REST=$((SIZE % 4096)); : > "$SNAPSHOT" || exit 26
        [ "$BLOCKS" -eq 0 ] || dd bs=4096 count="$BLOCKS" <&3 > "$SNAPSHOT" 2>/dev/null || exit 26
        [ "$REST" -eq 0 ] || dd bs=1 count="$REST" <&3 >> "$SNAPSHOT" 2>/dev/null || exit 26
        AFTER=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" "$FD_ROOT/3") || exit 27
        [ "$AFTER" = "$BEFORE" ] && [ ! -L "$SOURCE" ] || exit 27
        [ "$(stat -L -c "%d|%i" "$SOURCE")" = "$PATH_ID" ] || exit 27
        [ "$(stat -L -c "%s" "$SNAPSHOT")" = "$SIZE" ] || exit 28
        printf "size=%s\n" "$SIZE" > "$RESULT" || exit 29
    ' sh "$SOURCE" "$LIMIT" "$TEMP" "$RESULT" "$FD_ROOT" || { record_failure "$LABEL:snapshot_failed"; rm -f "$TEMP" "$RESULT"; return 1; }
    LINE=$(dd if="$RESULT" bs=128 count=1 2>/dev/null); SIZE=${LINE#size=}; case "$SIZE" in ''|*[!0-9]*) record_failure "$LABEL:size_result"; return 1 ;; esac
    TOTAL_LIBRARY_BYTES=$((TOTAL_LIBRARY_BYTES + SIZE)); [ "$TOTAL_LIBRARY_BYTES" -le "$MAX_TOTAL_LIBRARY_BYTES" ] || { record_failure "library_total_limit"; return 1; }
    commit_file "$TEMP" "$DEST" || { record_failure "$LABEL:commit_failed"; return 1; }
    rm -f "$RESULT"
    DIGEST=$(sha256sum "$DEST" | awk '{print $1}') || { record_failure "$LABEL:hash_failed"; return 1; }
    printf '%s  %s\n' "$DIGEST" "$DEST" >> "$CHECKSUM_WORK"
    printf '%s|COPY|OK|%s|%s|%s\n' "$LABEL" "$SOURCE" "$SIZE" "$DEST" >> "$INVENTORY_WORK"
}
snapshot_library appframework "$TARGET_ROOT/application/lib/libappframework.so.1.0.0" "$MAX_FRAMEWORK_BYTES"
snapshot_library appmcu "$TARGET_ROOT/application/lib/libappmcucommunication.so.1.0.0" "$MAX_MCU_LIBRARY_BYTES"

: > metadata/candidates.txt
CONFIG_COUNT=0
for DIR in "$TARGET_ROOT/application" "$TARGET_ROOT/application/etc" "$TARGET_ROOT/usr/local/etc"; do
    [ -d "$DIR" ] || continue
    for ITEM in "$DIR"/*; do
        [ -e "$ITEM" ] || [ -L "$ITEM" ] || continue
        NAME=${ITEM##*/}
        case "$NAME" in *[Mm][Cc][Uu]*|*[Cc][Aa][Nn]*|*[Vv]ehicle*|*[Vv]ersion*) ;;
            *) continue ;; esac
        CONFIG_COUNT=$((CONFIG_COUNT + 1)); [ "$CONFIG_COUNT" -le "$MAX_CONFIG_CANDIDATES" ] || { record_failure "config_candidate_limit"; break; }
        if [ -L "$ITEM" ]; then META="symlink|-|$(readlink "$ITEM" 2>/dev/null || printf RACE)"
        else META=$(stat -c '%F|%s|-' "$ITEM" 2>/dev/null || printf 'RACE|-|-'); fi
        printf '%s|%s\n' "$ITEM" "$META" >> metadata/candidates.txt || record_failure "metadata_write"
    done
done

printf '%s\n' \
    "schema=1" \
    "scope=w176-stage4a-can-mcu-topology" \
    "interfaces=$INTERFACE_COUNT" \
    "device_candidates=$DEVICE_COUNT" \
    "processes_inspected=$PROCESS_COUNT" \
    "fd_links_inspected=$TOTAL_FD_LINKS" \
    "matched_owners=$OWNER_COUNT" \
    "library_bytes=$TOTAL_LIBRARY_BYTES" > SUMMARY.txt || record_failure "summary_write"

printf '%s\n' \
    "schema=1" \
    "device_streams.opened=0" \
    "can_frames.received=0" \
    "can_frames.transmitted=0" \
    "mcu_commands.sent=0" \
    "logging.capture=DEFERRED" \
    "processes.max=$MAX_PROCESSES" \
    "fds.per_process.max=$MAX_FDS_PER_PROCESS" \
    "fd_links.total.max=$MAX_TOTAL_FD_LINKS" \
    "owners.max=$MAX_OWNERS" \
    "maps.per_process.bytes.max=$MAX_MAPS_PER_PROCESS" \
    "maps.total.bytes.max=$MAX_TOTAL_MAPS" \
    "interfaces.max=$MAX_INTERFACES" \
    "devices.max=$MAX_DEVICE_CANDIDATES" \
    "libappframework.bytes.max=$MAX_FRAMEWORK_BYTES" \
    "libappmcucommunication.bytes.max=$MAX_MCU_LIBRARY_BYTES" \
    "libraries.total.bytes.max=$MAX_TOTAL_LIBRARY_BYTES" \
    "output.kib.max=$MAX_TOTAL_OUTPUT_KIB" > CAPABILITIES.txt || record_failure "capabilities_write"

hash_output() {
    OUTPUT_PATH=$1
    is_regular_nonsymlink "$OUTPUT_PATH" || { record_failure "output_invalid:$OUTPUT_PATH"; return 1; }
    OUTPUT_DIGEST=$(sha256sum "$OUTPUT_PATH" | awk '{print $1}') || { record_failure "output_hash_failed:$OUTPUT_PATH"; return 1; }
    printf '%s  %s\n' "$OUTPUT_DIGEST" "$OUTPUT_PATH" >> "$CHECKSUM_WORK" || record_failure "checksums_write:$OUTPUT_PATH"
}
for OUTPUT_PATH in network/interfaces.txt devices/device-nodes.txt processes/owners.txt metadata/candidates.txt SUMMARY.txt CAPABILITIES.txt; do
    hash_output "$OUTPUT_PATH"
done

OUTPUT_KIB=$(du -sk . 2>/dev/null | awk '{print $1}') || record_failure "output_size_unavailable"
case "$OUTPUT_KIB" in ''|*[!0-9]*) record_failure "output_size_invalid" ;; *) [ "$OUTPUT_KIB" -le "$MAX_TOTAL_OUTPUT_KIB" ] || record_failure "output_limit" ;; esac

for REQUIRED_OUTPUT in CAPABILITIES.txt SUMMARY.txt network/proc-net-dev.txt network/interfaces.txt devices/device-nodes.txt processes/owners.txt files/libappframework.so.1.0.0 files/libappmcucommunication.so.1.0.0; do
    is_regular_nonsymlink "$REQUIRED_OUTPUT" || record_failure "required_output_invalid:$REQUIRED_OUTPUT"
done

commit_file "$INVENTORY_WORK" capture-inventory.txt || record_failure "inventory_commit"
commit_file "$CHECKSUM_WORK" checksums.sha256 || record_failure "checksums_commit"
commit_file "$OPTIONAL_WORK" OPTIONAL.txt || record_failure "optional_commit"
commit_file "$ERROR_WORK" ERRORS.txt || { FAILURES=$((FAILURES + 1)); }
[ "$FAILURES" -eq 0 ] || { status_write INCOMPLETE || true; exit 1; }
status_write COMPLETE || exit 1
for REQUIRED in STATUS.txt ERRORS.txt OPTIONAL.txt CAPABILITIES.txt SUMMARY.txt capture-inventory.txt checksums.sha256 network/proc-net-dev.txt network/interfaces.txt devices/device-nodes.txt processes/owners.txt files/libappframework.so.1.0.0 files/libappmcucommunication.so.1.0.0; do
    is_regular_nonsymlink "$REQUIRED" || { status_write INCOMPLETE || true; exit 1; }
done
[ ! -s ERRORS.txt ] || { status_write INCOMPLETE || true; exit 1; }
awk -F= '
    $1 == "status" { status=$2; sc++ }
    $1 == "mandatory_failures" { failures=$2; fc++ }
    END { if (sc != 1 || fc != 1 || status != "COMPLETE" || failures != "0") exit 1 }
' STATUS.txt >/dev/null 2>&1 || { status_write INCOMPLETE || true; exit 1; }
COMPLETE_TEMP=.COMPLETE.tmp
printf 'complete=1\n' > "$COMPLETE_TEMP" && commit_file "$COMPLETE_TEMP" COMPLETE || exit 1
printf '%s\n' "w176-stage4a: complete: $ANCHOR/$OUT"
