#!/bin/sh
# Shared Stage-4B validation. Sourced only by the reviewed payload scripts.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MOUNTS_FILE=/proc/mounts
MTD_FILE=/proc/mtd
KERNEL_RELEASE_FILE=/proc/sys/kernel/osrelease
PROCESS_ROOT=/proc
FD_ROOT=/proc/self/fd
NVM_ROOT=/media/flash/nvm
LAUNCHER_PATH=/application/bin/Launcher
APPINFO_PATH=/application/appinfo.rc
EXPECTED_KERNEL_RELEASE=4.9.217
EXPECTED_LAUNCHER_SHA256=5ff83ac9cf9fb2ccb21c90c9b2edb2952581153ec5d5ab4a299787243e1e0c56
EXPECTED_LAUNCHER_SIZE=92416
EXPECTED_BINARY_SHA256=57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6
EXPECTED_BINARY_SIZE=5556
EXPECTED_NVM_BYTES_HEX=00800000
INSTALL_PARENT=$NVM_ROOT/geminitop
INSTALL_DIR=$INSTALL_PARENT/w176
STAGE_DIR=$INSTALL_PARENT/.w176-stage4b-installing
DEST_BINARY=$INSTALL_DIR/geminitop-proofd
DEST_MANIFEST=$INSTALL_DIR/manifest.txt
HEARTBEAT=/tmp/geminitop-proofd.status
HEARTBEAT_TEMP=/tmp/.geminitop-proofd.status.tmp
MAX_PROCESSES=256
MINIMUM_FREE_KIB=128
export PATH

is_regular_nonsymlink() { [ -f "$1" ] && [ ! -L "$1" ]; }

validate_hash() {
    HASH_PATH=$1; EXPECTED_HASH=$2; EXPECTED_SIZE=$3
    is_regular_nonsymlink "$HASH_PATH" || return 1
    [ "$(stat -L -c '%s' "$HASH_PATH" 2>/dev/null)" = "$EXPECTED_SIZE" ] || return 1
    [ "$(sha256sum "$HASH_PATH" 2>/dev/null | awk '{print $1}')" = "$EXPECTED_HASH" ]
}

validate_target() {
    SPACE_MODE=${1:-metadata_only}
    for COMMAND in awk chmod dd grep mkdir mv pwd readlink rm rmdir sed sha256sum sleep stat wc; do
        command -v "$COMMAND" >/dev/null 2>&1 || return 10
    done
    if [ "$SPACE_MODE" = require_space ]; then command -v df >/dev/null 2>&1 || return 10; fi
    [ -r "$MOUNTS_FILE" ] && [ -r "$MTD_FILE" ] || return 11
    [ -d "$NVM_ROOT" ] && [ ! -L "$NVM_ROOT" ] && [ -w "$NVM_ROOT" ] || return 12
    NVM_CANONICAL=$(cd -P "$NVM_ROOT" 2>/dev/null && pwd -P) || return 12
    [ "$NVM_CANONICAL" = "$NVM_ROOT" ] && [ "$NVM_ROOT" -ef "$NVM_CANONICAL" ] 2>/dev/null || return 12
    NVM_RECORD=$(awk -v mountpoint="$NVM_ROOT" '
        $2 == mountpoint { count++; record=$1 "|" $2 "|" $3 "|" $4 }
        END { if (count == 1) print record; else exit 1 }
    ' "$MOUNTS_FILE" 2>/dev/null) || return 13
    OLD_IFS=$IFS; IFS='|'; set -- $NVM_RECORD; IFS=$OLD_IFS
    [ "$#" -eq 4 ] || return 13
    NVM_DEVICE=$1; NVM_MOUNT=$2; NVM_FSTYPE=$3; NVM_OPTIONS=$4
    [ "$NVM_MOUNT" = "$NVM_ROOT" ] && [ "$NVM_FSTYPE" = yaffs2 ] || return 14
    case ",$NVM_OPTIONS," in *,rw,*) ;; *) return 14 ;; esac
    case ",$NVM_OPTIONS," in *,ro,*) return 14 ;; esac
    NVM_LINES=$(awk '$1 == "mtd12:" && $4 == "\"nvm\"" { count++; line=$0; size=$2 } END { if (count == 1) print size "|" line; else exit 1 }' "$MTD_FILE" 2>/dev/null) || return 15
    NVM_SIZE_HEX=${NVM_LINES%%|*}
    [ "$NVM_SIZE_HEX" = "$EXPECTED_NVM_BYTES_HEX" ] || return 15
    KERNEL_RELEASE=$(dd if="$KERNEL_RELEASE_FILE" bs=129 count=1 2>/dev/null | sed -n '1p') || return 16
    [ "$KERNEL_RELEASE" = "$EXPECTED_KERNEL_RELEASE" ] || return 16
    validate_hash "$LAUNCHER_PATH" "$EXPECTED_LAUNCHER_SHA256" "$EXPECTED_LAUNCHER_SIZE" || return 17
    is_regular_nonsymlink "$APPINFO_PATH" || return 18
    APPINFO_TEXT=$(dd if="$APPINFO_PATH" bs=4097 count=1 2>/dev/null) || return 18
    [ "$(printf '%s' "$APPINFO_TEXT" | wc -c)" -le 4096 ] || return 18
    printf '%s\n' "$APPINFO_TEXT" | grep -F 'gemini_8368_XU_evb_def_config' >/dev/null || return 18
    FREE_KIB=NOT_CHECKED
    if [ "$SPACE_MODE" = require_space ]; then
        FREE_KIB=$(df -Pk "$NVM_ROOT" 2>/dev/null | awk -v mountpoint="$NVM_ROOT" '$6 == mountpoint { count++; free=$4 } END { if (count == 1) print free; else exit 1 }') || return 19
        case "$FREE_KIB" in ''|*[!0-9]*) return 19 ;; esac
        [ "$FREE_KIB" -ge "$MINIMUM_FREE_KIB" ] || return 20
    fi
    return 0
}

read_process_identity() {
    IDENTITY_PID=$1
    case "$IDENTITY_PID" in ''|*[!0-9]*) return 1 ;; esac
    STAT_LINE=$(dd if="$PROCESS_ROOT/$IDENTITY_PID/stat" bs=8193 count=1 2>/dev/null) || return 1
    [ "$(printf '%s' "$STAT_LINE" | wc -c)" -le 8192 ] || return 1
    case "$STAT_LINE" in *') '*) STAT_TAIL=${STAT_LINE##*) } ;; *) return 1 ;; esac
    set -- $STAT_TAIL
    [ "$#" -ge 20 ] || return 1
    PROCESS_STATE=$1
    shift 19
    PROCESS_START=$1
    case "$PROCESS_START" in ''|*[!0-9]*) return 1 ;; esac
    PROCESS_EXE_ONE=$(readlink "$PROCESS_ROOT/$IDENTITY_PID/exe" 2>/dev/null) || return 1
    PROCESS_EXE_TWO=$(readlink "$PROCESS_ROOT/$IDENTITY_PID/exe" 2>/dev/null) || return 1
    [ "$PROCESS_EXE_ONE" = "$PROCESS_EXE_TWO" ] || return 1
    return 0
}

validate_heartbeat() {
    EXPECTED_PID=$1
    is_regular_nonsymlink "$HEARTBEAT" || return 1
    [ "$(stat -L -c '%s' "$HEARTBEAT" 2>/dev/null)" -le 512 ] || return 1
    HEARTBEAT_VALUES=$(awk -F= -v pid="$EXPECTED_PID" -v hash="$EXPECTED_BINARY_SHA256" '
        $1 == "schema" && $2 == "1" { schema++ }
        $1 == "process" && $2 == "geminitop-proofd" { process++ }
        $1 == "version" && $2 == "w176-stage4b-proofd-v1" { version++ }
        $1 == "pid" && $2 == pid { found_pid++ }
        $1 == "started" && $2 == "1" { started++ }
        $1 == "state" && $2 == "running" { running++ }
        $1 == "heartbeat_sequence" && $2 ~ /^[0-9]+$/ { sequence=$2; sequences++ }
        $1 == "binary_sha256" && $2 == hash { found_hash++ }
        END { if (schema==1 && process==1 && version==1 && found_pid==1 && started==1 && running==1 && sequences==1 && found_hash==1) print sequence; else exit 1 }
    ' "$HEARTBEAT" 2>/dev/null) || return 1
    case "$HEARTBEAT_VALUES" in ''|*[!0-9]*) return 1 ;; esac
    HEARTBEAT_SEQUENCE=$HEARTBEAT_VALUES
    return 0
}

validate_owned_heartbeat() {
    OWNED_PID=$1
    is_regular_nonsymlink "$HEARTBEAT" || return 1
    [ "$(stat -L -c '%s' "$HEARTBEAT" 2>/dev/null)" -le 512 ] || return 1
    awk -F= -v pid="$OWNED_PID" -v hash="$EXPECTED_BINARY_SHA256" '
        $1=="schema"&&$2=="1"{schema++}
        $1=="process"&&$2=="geminitop-proofd"{process++}
        $1=="pid"&&$2==pid{found_pid++}
        $1=="state"&&($2=="running"||$2=="stopped"){state++}
        $1=="binary_sha256"&&$2==hash{found_hash++}
        END{exit !(schema==1&&process==1&&found_pid==1&&state==1&&found_hash==1)}
    ' "$HEARTBEAT" >/dev/null 2>&1
}

validate_manifest() {
    MANIFEST_PATH=$1
    is_regular_nonsymlink "$MANIFEST_PATH" || return 1
    [ "$(stat -L -c '%s' "$MANIFEST_PATH" 2>/dev/null)" -le 1024 ] || return 1
    awk -F= -v hash="$EXPECTED_BINARY_SHA256" -v size="$EXPECTED_BINARY_SIZE" -v path="$DEST_BINARY" '
        $1=="schema" && $2=="1" {schema++}
        $1=="owner" && $2=="GeminiTop" {owner++}
        $1=="target" && $2=="w176-ntg5" {target++}
        $1=="component" && $2=="geminitop-proofd" {component++}
        $1=="version" && $2=="w176-stage4b-proofd-v1" {version++}
        $1=="binary_sha256" && $2==hash {found_hash++}
        $1=="binary_size" && $2==size {found_size++}
        $1=="installed_path" && $2==path {found_path++}
        {lines++}
        END {exit !(lines==8&&schema==1&&owner==1&&target==1&&component==1&&version==1&&found_hash==1&&found_size==1&&found_path==1)}
    ' "$MANIFEST_PATH" >/dev/null 2>&1
}

validate_process_detached_from_usb() {
    DETACHED_PID=$1
    PROCESS_CWD_ONE=$(readlink "$PROCESS_ROOT/$DETACHED_PID/cwd" 2>/dev/null) || return 1
    PROCESS_CWD_TWO=$(readlink "$PROCESS_ROOT/$DETACHED_PID/cwd" 2>/dev/null) || return 1
    [ "$PROCESS_CWD_ONE" = /tmp ] && [ "$PROCESS_CWD_TWO" = /tmp ] || return 1
    DETACHED_FD_COUNT=0
    for DETACHED_FD in "$PROCESS_ROOT/$DETACHED_PID/fd"/*; do
        [ -L "$DETACHED_FD" ] || continue
        DETACHED_FD_COUNT=$((DETACHED_FD_COUNT + 1))
        [ "$DETACHED_FD_COUNT" -le 64 ] || return 1
        DETACHED_TARGET=$(readlink "$DETACHED_FD" 2>/dev/null) || return 1
        case "$DETACHED_TARGET" in "$USB_ROOT"|"$USB_ROOT"/*) return 1 ;; esac
    done
    return 0
}

begin_action() {
    ACTION_NAME=$1; MARKER_NAME=$2; MARKER_CONTENT=$3; OUTPUT_NAME=$4; SCOPE=$5; REQUESTED_ROOT=$6
    SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
    REQUESTED_CANONICAL=$(cd -P "$REQUESTED_ROOT" 2>/dev/null && pwd -P) || exit 1
    cd -P "$SCRIPT_DIR" 2>/dev/null || exit 1
    USB_ROOT=$(pwd -P) || exit 1
    [ "$REQUESTED_CANONICAL" = "$USB_ROOT" ] && [ . -ef "$USB_ROOT" ] 2>/dev/null || exit 1
    [ -f ./mount_guard.sh ] && [ ! -L ./mount_guard.sh ] || exit 1
    [ "$(/bin/sh ./mount_guard.sh .)" = "$USB_ROOT" ] || exit 1
    LOCK_PATH="./.stage4b-$ACTION_NAME.lock"
    mkdir "$LOCK_PATH" 2>/dev/null || exit 1
    [ -d "$USB_ROOT/.stage4b-$ACTION_NAME.lock" ] && [ ! -L "$USB_ROOT/.stage4b-$ACTION_NAME.lock" ] || exit 1
    MARKER_PATH="./$MARKER_NAME"
    is_regular_nonsymlink "$MARKER_PATH" || exit 1
    [ "$(dd if="$MARKER_PATH" bs=129 count=1 2>/dev/null)" = "$MARKER_CONTENT" ] || exit 1
    [ "$(stat -L -c '%s' "$MARKER_PATH" 2>/dev/null)" -le 128 ] || exit 1
    rm -f "$MARKER_PATH" || exit 1
    [ ! -e "$MARKER_PATH" ] && [ ! -L "$MARKER_PATH" ] || exit 1
    [ ! -e "$OUTPUT_NAME" ] && [ ! -L "$OUTPUT_NAME" ] || exit 1
    mkdir "$OUTPUT_NAME" || exit 1
    cd "$OUTPUT_NAME" || exit 1
    OUT_DISPLAY="$USB_ROOT/$OUTPUT_NAME"
    FAILURES=0
    : > .ERRORS.txt.work || exit 1
    write_status INCOMPLETE || exit 1
}

write_status() {
    STATUS_VALUE=$1
    printf '%s\n' "schema=1" "scope=$SCOPE" "status=$STATUS_VALUE" "mandatory_failures=$FAILURES" > .STATUS.txt.tmp || return 1
    mv .STATUS.txt.tmp STATUS.txt || return 1
    is_regular_nonsymlink STATUS.txt
}

record_failure() {
    FAILURES=$((FAILURES + 1))
    printf 'error.%s=%s\n' "$FAILURES" "$1" >> .ERRORS.txt.work 2>/dev/null || true
}

finish_incomplete() {
    is_regular_nonsymlink .ERRORS.txt.work && mv .ERRORS.txt.work ERRORS.txt 2>/dev/null || true
    write_status INCOMPLETE 2>/dev/null || true
    exit 1
}

finish_complete() {
    [ "$FAILURES" -eq 0 ] || finish_incomplete
    mv .ERRORS.txt.work ERRORS.txt || exit 1
    is_regular_nonsymlink ERRORS.txt && [ ! -s ERRORS.txt ] || exit 1
    write_status COMPLETE || exit 1
    awk -F= '$1=="status" {s=$2;n++} $1=="mandatory_failures" {f=$2;m++} END {exit !(n==1&&m==1&&s=="COMPLETE"&&f=="0")}' STATUS.txt || exit 1
    printf 'complete=1\n' > .COMPLETE.tmp && mv .COMPLETE.tmp COMPLETE || exit 1
    is_regular_nonsymlink COMPLETE || exit 1
    printf '%s\n' "w176-stage4b: complete: $OUT_DISPLAY"
}
