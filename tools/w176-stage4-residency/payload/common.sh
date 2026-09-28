#!/bin/sh
# Shared Stage-4B validation. Sourced only by the reviewed payload scripts.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MOUNTS_FILE=/proc/mounts
MOUNTINFO_FILE=/proc/self/mountinfo
MTD_FILE=/proc/mtd
KERNEL_RELEASE_FILE=/proc/sys/kernel/osrelease
PROCESS_ROOT=/proc
FD_ROOT=/proc/self/fd
NVM_ROOT=/media/flash/nvm
MEDIA_LINK_PATH=/media
EXPECTED_MEDIA_LINK=/tmp/sp/media/
EXPECTED_NVM_CANONICAL=/tmp/sp/media/flash/nvm
EXPECTED_NVM_SOURCE=/dev/mtdblock12
NVM_SOURCE_TEST=-b
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
    HASH_SIZE=$(stat -L -c '%s' "$HASH_PATH" 2>/dev/null) || return 1
    [ "$HASH_SIZE" = "$EXPECTED_SIZE" ] || return 1
    HASH_RECORD=$(sha256sum "$HASH_PATH" 2>/dev/null) || return 1
    [ "$HASH_RECORD" = "$EXPECTED_HASH  $HASH_PATH" ]
}

# Mount names are kernel paths. /media is an installed symlink, so the
# canonical kernel mount is /tmp/sp/media/flash/nvm, not the logical NVM_ROOT.
# Call for every prospective persistent child before each write/delete phase.
validate_nvm_path() {
    CHECK_PATH=$1
    case "$CHECK_PATH" in "$NVM_ROOT"|"$NVM_ROOT"/*) ;; *) return 1 ;; esac
    CANONICAL_CHECK=$EXPECTED_NVM_CANONICAL${CHECK_PATH#"$NVM_ROOT"}
    MOUNT_TABLE=$(dd if="$MOUNTS_FILE" bs=1 count=131073 2>/dev/null && printf x) || return 1
    MOUNT_TABLE=${MOUNT_TABLE%x}
    [ "${#MOUNT_TABLE}" -le 131072 ] || return 1
    EFFECTIVE_RECORD=$(awk -v path="$CANONICAL_CHECK" -v root="$EXPECTED_NVM_CANONICAL" \
        -v source="$EXPECTED_NVM_SOURCE" '
        function covers(m,p) { return m=="/" || p==m || index(p,m"/")==1 }
        length($0)>4096 { bad=1; exit }
        NF==0 { next }
        ++records>1024 || NF!=6 { bad=1; exit }
        {
            if ($2 ~ /\\/ || substr($2,1,1)!="/") { bad=1; exit }
            if (covers($2,path)) {
                if (seen[$2]++) { bad=1; exit }
                if (length($2)>longest) { longest=length($2); effective=$2 }
            }
            if ($2==root) {
                found++; device=$1; fs=$3; options=$4
            }
        }
        END {
            n=split(options,opt,","); rw=0; ro=0
            for (i=1;i<=n;i++) { if (opt[i]=="rw") rw=1; if (opt[i]=="ro") ro=1 }
            if (bad || found!=1 || effective!=root || device!=source || fs!="yaffs2" || !rw || ro) exit 1
            print device "|" root "|" fs "|" options
        }
    ' <<EOF
$MOUNT_TABLE
EOF
    ) || return 1
    [ "$EFFECTIVE_RECORD" = "$NVM_RECORD" ] || return 1
    MOUNTINFO_TABLE=$(dd if="$MOUNTINFO_FILE" bs=1 count=131073 2>/dev/null && printf x) || return 1
    MOUNTINFO_TABLE=${MOUNTINFO_TABLE%x}
    [ "${#MOUNTINFO_TABLE}" -le 131072 ] || return 1
    # The mountinfo root field must be /: a bind of another subtree from the
    # same YAFFS2 device is not the original NVM root even if st_dev matches.
    awk -v path="$CANONICAL_CHECK" -v root="$EXPECTED_NVM_CANONICAL" '
        function covers(m,p) { return m=="/" || p==m || index(p,m"/")==1 }
        length($0)>4096 { bad=1; exit }
        NF==0 { next }
        ++records>1024 { bad=1; exit }
        {
            separator=0
            for (i=7;i<=NF;i++) if ($i=="-") { separator=i; break }
            if (separator==0 || separator+3!=NF) { bad=1; exit }
            if (covers($5,path)) {
                if (seen[$5]++) { bad=1; exit }
                if (length($5)>longest) { longest=length($5); effective=$5 }
            }
            if ($5==root) {
                found++; mountroot=$4; fs=$(separator+1)
            }
        }
        END { exit !(!bad && found==1 && effective==root && mountroot=="/" && fs=="yaffs2") }
    ' <<EOF || return 1
$MOUNTINFO_TABLE
EOF
    for COMPONENT in "$INSTALL_PARENT" "$INSTALL_DIR" "$STAGE_DIR" "$DEST_BINARY" "$DEST_MANIFEST"; do
        case "$CHECK_PATH" in "$COMPONENT"|"$COMPONENT"/*) ;;
            *) continue ;;
        esac
        [ ! -L "$COMPONENT" ] || return 1
        if [ -e "$COMPONENT" ]; then
            COMPONENT_DEVICE=$(stat -c '%d' "$COMPONENT" 2>/dev/null) || return 1
            [ "$COMPONENT_DEVICE" = "$NVM_ST_DEV" ] || return 1
        fi
    done
    return 0
}

validate_target() {
    SPACE_MODE=${1:-metadata_only}
    for COMMAND in awk chmod dd grep mkdir mv pwd readlink rm rmdir sed sha256sum sleep stat wc; do
        command -v "$COMMAND" >/dev/null 2>&1 || return 10
    done
    if [ "$SPACE_MODE" = require_space ]; then command -v df >/dev/null 2>&1 || return 10; fi
    [ -r "$MOUNTS_FILE" ] && [ -r "$MOUNTINFO_FILE" ] && [ -r "$MTD_FILE" ] || return 11
    [ -L "$MEDIA_LINK_PATH" ] &&
        [ "$(readlink "$MEDIA_LINK_PATH" 2>/dev/null)" = "$EXPECTED_MEDIA_LINK" ] || return 12
    [ -d "$NVM_ROOT" ] && [ ! -L "$NVM_ROOT" ] && [ -w "$NVM_ROOT" ] || return 12
    NVM_CANONICAL=$(cd -P "$NVM_ROOT" 2>/dev/null && pwd -P) || return 12
    [ "$NVM_CANONICAL" = "$EXPECTED_NVM_CANONICAL" ] &&
        [ "$NVM_ROOT" -ef "$NVM_CANONICAL" ] 2>/dev/null || return 12
    NVM_ST_DEV=$(stat -c '%d' "$NVM_CANONICAL" 2>/dev/null) || return 12
    MOUNT_TABLE=$(dd if="$MOUNTS_FILE" bs=1 count=131073 2>/dev/null && printf x) || return 13
    MOUNT_TABLE=${MOUNT_TABLE%x}
    [ "${#MOUNT_TABLE}" -le 131072 ] || return 13
    NVM_RECORD=$(awk -v mountpoint="$EXPECTED_NVM_CANONICAL" '
        NF==0 { next }
        length($0)>4096 || NF!=6 { bad=1; exit }
        ++records>1024 { bad=1; exit }
        $2 == mountpoint { count++; record=$1 "|" $2 "|" $3 "|" $4 }
        END { if (!bad && count == 1) print record; else exit 1 }
    ' <<EOF
$MOUNT_TABLE
EOF
    ) || return 13
    OLD_IFS=$IFS; IFS='|'; set -- $NVM_RECORD; IFS=$OLD_IFS
    [ "$#" -eq 4 ] || return 13
    NVM_DEVICE=$1; NVM_MOUNT=$2; NVM_FSTYPE=$3; NVM_OPTIONS=$4
    [ "$NVM_DEVICE" = "$EXPECTED_NVM_SOURCE" ] &&
        [ "$NVM_MOUNT" = "$EXPECTED_NVM_CANONICAL" ] &&
        [ "$NVM_FSTYPE" = yaffs2 ] || return 14
    case ",$NVM_OPTIONS," in *,rw,*) ;; *) return 14 ;; esac
    case ",$NVM_OPTIONS," in *,ro,*) return 14 ;; esac
    NVM_LINES=$(awk '$1 == "mtd12:" && $4 == "\"nvm\"" { count++; line=$0; size=$2 } END { if (count == 1) print size "|" line; else exit 1 }' "$MTD_FILE" 2>/dev/null) || return 15
    NVM_SIZE_HEX=${NVM_LINES%%|*}
    [ "$NVM_SIZE_HEX" = "$EXPECTED_NVM_BYTES_HEX" ] || return 15
    if [ "$NVM_SOURCE_TEST" = -b ]; then
        [ -b "$EXPECTED_NVM_SOURCE" ] || return 15
    else
        [ -e "$EXPECTED_NVM_SOURCE" ] || return 15
    fi
    validate_nvm_path "$INSTALL_PARENT" || return 15
    validate_nvm_path "$INSTALL_DIR" || return 15
    validate_nvm_path "$STAGE_DIR" || return 15
    validate_nvm_path "$DEST_BINARY" || return 15
    validate_nvm_path "$DEST_MANIFEST" || return 15
    KERNEL_RELEASE=$(dd if="$KERNEL_RELEASE_FILE" bs=1 count=129 2>/dev/null) || return 16
    [ "${#KERNEL_RELEASE}" -le 128 ] || return 16
    [ "$KERNEL_RELEASE" = "$EXPECTED_KERNEL_RELEASE" ] || return 16
    validate_hash "$LAUNCHER_PATH" "$EXPECTED_LAUNCHER_SHA256" "$EXPECTED_LAUNCHER_SIZE" || return 17
    is_regular_nonsymlink "$APPINFO_PATH" || return 18
    APPINFO_TEXT=$(dd if="$APPINFO_PATH" bs=1 count=4097 2>/dev/null && printf x) || return 18
    APPINFO_TEXT=${APPINFO_TEXT%x}
    [ "${#APPINFO_TEXT}" -le 4096 ] || return 18
    case "$APPINFO_TEXT" in *gemini_8368_XU_evb_def_config*) ;; *) return 18 ;; esac
    FREE_KIB=NOT_CHECKED
    if [ "$SPACE_MODE" = require_space ]; then
        DF_OUTPUT=$(df -Pk "$NVM_ROOT" 2>/dev/null) || return 19
        [ "${#DF_OUTPUT}" -le 4096 ] || return 19
        FREE_KIB=$(awk -v source="$EXPECTED_NVM_SOURCE" -v mountpoint="$EXPECTED_NVM_CANONICAL" '
            NR==1 { if ($1!="Filesystem" || NF!=7) bad=1; next }
            NF!=6 { bad=1; next }
            { records++; if ($1!=source || $6!=mountpoint || $4 !~ /^[0-9]+$/) bad=1; free=$4 }
            END { if (!bad && records==1) print free; else exit 1 }
        ' <<EOF
$DF_OUTPUT
EOF
        ) || return 19
        case "$FREE_KIB" in ''|*[!0-9]*) return 19 ;; esac
        [ "$FREE_KIB" -ge "$MINIMUM_FREE_KIB" ] || return 20
    fi
    return 0
}

read_process_identity() {
    IDENTITY_PID=$1
    case "$IDENTITY_PID" in ''|*[!0-9]*) return 1 ;; esac
    STATUS_TEXT=$(dd if="$PROCESS_ROOT/$IDENTITY_PID/status" bs=1 count=16385 2>/dev/null && printf x) || return 1
    STATUS_TEXT=${STATUS_TEXT%x}
    [ "${#STATUS_TEXT}" -le 16384 ] || return 1
    STATUS_VALUES=$(awk -v pid="$IDENTITY_PID" '
        $1=="Pid:" { if ($2!=pid || $2 !~ /^[0-9]+$/) bad=1; p++; }
        $1=="Tgid:" { if ($2!=pid || $2 !~ /^[0-9]+$/) bad=1; t++; }
        $1=="State:" { state=$2; s++; }
        END { if (!bad && p==1 && t==1 && s==1 && state ~ /^[RSDTtI]$/) print state; else exit 1 }
    ' <<EOF
$STATUS_TEXT
EOF
    ) || return 1
    STAT_LINE=$(dd if="$PROCESS_ROOT/$IDENTITY_PID/stat" bs=1 count=8193 2>/dev/null && printf x) || return 1
    STAT_LINE=${STAT_LINE%x}
    [ "${#STAT_LINE}" -le 8192 ] || return 1
    case "$STAT_LINE" in *') '*) STAT_TAIL=${STAT_LINE##*) } ;; *) return 1 ;; esac
    set -- $STAT_TAIL
    [ "$#" -ge 20 ] || return 1
    PROCESS_STATE=$1
    [ "$PROCESS_STATE" = "$STATUS_VALUES" ] || return 1
    shift 19
    PROCESS_START=$1
    case "$PROCESS_START" in ''|*[!0-9]*) return 1 ;; esac
    PROCESS_EXE_ONE=$(readlink "$PROCESS_ROOT/$IDENTITY_PID/exe" 2>/dev/null) || return 1
    PROCESS_EXE_TWO=$(readlink "$PROCESS_ROOT/$IDENTITY_PID/exe" 2>/dev/null) || return 1
    [ "$PROCESS_EXE_ONE" = "$PROCESS_EXE_TWO" ] || return 1
    PROCESS_IDENTITY="$IDENTITY_PID|$PROCESS_START|$PROCESS_EXE_ONE"
    return 0
}

validate_heartbeat() {
    EXPECTED_PID=$1
    is_regular_nonsymlink "$HEARTBEAT" || return 1
    [ "$(stat -L -c '%s' "$HEARTBEAT" 2>/dev/null)" -le 512 ] || return 1
    HEARTBEAT_VALUES=$(awk -F= -v pid="$EXPECTED_PID" -v hash="$EXPECTED_BINARY_SHA256" '
        { lines++; if (NF!=2) bad=1 }
        $1 == "schema" && $2 == "1" { schema++ }
        $1 == "process" && $2 == "geminitop-proofd" { process++ }
        $1 == "version" && $2 == "w176-stage4b-proofd-v1" { version++ }
        $1 == "pid" && $2 == pid { found_pid++ }
        $1 == "started" && $2 == "1" { started++ }
        $1 == "state" && $2 == "running" { running++ }
        $1 == "heartbeat_sequence" && $2 ~ /^[0-9]+$/ { sequence=$2; sequences++ }
        $1 == "binary_sha256" && $2 == hash { found_hash++ }
        END { if (!bad && lines==8 && schema==1 && process==1 && version==1 && found_pid==1 && started==1 && running==1 && sequences==1 && found_hash==1) print sequence; else exit 1 }
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
        {lines++; if(NF!=2) bad=1}
        $1=="schema"&&$2=="1"{schema++}
        $1=="process"&&$2=="geminitop-proofd"{process++}
        $1=="version"&&$2=="w176-stage4b-proofd-v1"{version++}
        $1=="pid"&&$2==pid{found_pid++}
        $1=="started"&&$2=="1"{started++}
        $1=="state"&&$2=="stopped"{state++}
        $1=="heartbeat_sequence"&&$2 ~ /^[0-9]+$/{sequence++}
        $1=="binary_sha256"&&$2==hash{found_hash++}
        END{exit !(!bad&&lines==8&&schema==1&&process==1&&version==1&&found_pid==1&&started==1&&state==1&&sequence==1&&found_hash==1)}
    ' "$HEARTBEAT" >/dev/null 2>&1
}

validate_install_record() {
    INSTALL_RECORD="$USB_ROOT/stage4b-install/PROCESS.txt"
    INSTALL_STATUS="$USB_ROOT/stage4b-install/STATUS.txt"
    INSTALL_COMPLETE="$USB_ROOT/stage4b-install/COMPLETE"
    INSTALL_HASHES="$USB_ROOT/stage4b-install/HASHES.txt"
    is_regular_nonsymlink "$INSTALL_RECORD" &&
        is_regular_nonsymlink "$INSTALL_STATUS" &&
        is_regular_nonsymlink "$INSTALL_COMPLETE" &&
        is_regular_nonsymlink "$INSTALL_HASHES" || return 1
    [ "$(stat -L -c '%s' "$INSTALL_HASHES" 2>/dev/null)" -le 1024 ] || return 1
    awk '{ if (NR==1&&$2!="TARGET.txt") bad=1;
           if (NR==2&&$2!="PROCESS.txt") bad=1;
           if (NR==3&&$2!="RESULT.txt") bad=1;
           if (NR==4&&$2!="ERRORS.txt") bad=1;
           if (NR==5&&$2!="STATUS.txt") bad=1;
           if (length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || NF!=2) bad=1 }
         END { exit !(NR==5 && !bad) }' "$INSTALL_HASHES" 2>/dev/null || return 1
    (cd "$USB_ROOT/stage4b-install" && sha256sum -c HASHES.txt >/dev/null 2>&1) || return 1
    [ "$(stat -L -c '%s' "$INSTALL_RECORD" 2>/dev/null)" -le 1024 ] || return 1
    [ "$(stat -L -c '%s' "$INSTALL_STATUS" 2>/dev/null)" -le 256 ] || return 1
    [ "$(stat -L -c '%s' "$INSTALL_COMPLETE" 2>/dev/null)" = 11 ] || return 1
    INSTALL_COMPLETE_TEXT=$(dd if="$INSTALL_COMPLETE" bs=12 count=1 2>/dev/null) || return 1
    [ "$INSTALL_COMPLETE_TEXT" = complete=1 ] || return 1
    awk -F= '
        {lines++; if(NF!=2) bad=1}
        $1=="schema"&&$2=="1"{schema++}
        $1=="scope"&&$2=="w176-stage4b-residency-install"{scope++}
        $1=="status"&&$2=="COMPLETE"{status++}
        $1=="mandatory_failures"&&$2=="0"{failures++}
        END{exit !(!bad&&lines==4&&schema==1&&scope==1&&status==1&&failures==1)}
    ' "$INSTALL_STATUS" || return 1
    INSTALL_VALUES=$(awk -F= -v hash="$EXPECTED_BINARY_SHA256" -v exe="$DEST_BINARY" '
        {lines++; if(NF!=2) bad=1}
        $1=="schema"&&$2=="1"{schema++}
        $1=="pid"&&$2 ~ /^[0-9]+$/{pid=$2;p++}
        $1=="start_time"&&$2 ~ /^[0-9]+$/{start=$2;s++}
        $1=="exe"&&$2==exe{e++}
        $1=="cwd"&&$2=="/tmp"{cwd++}
        $1=="binary_sha256"&&$2==hash{h++}
        $1=="heartbeat_sequence"&&$2 ~ /^[0-9]+$/{sequence=$2;q++}
        $1=="usb_fd_references"&&$2=="0"{fd++}
        END {if(!bad&&lines==8&&schema==1&&p==1&&s==1&&e==1&&cwd==1&&h==1&&q==1&&fd==1) print pid "|" start "|" sequence; else exit 1}
    ' "$INSTALL_RECORD" 2>/dev/null) || return 1
    OLD_IFS=$IFS; IFS='|'; set -- $INSTALL_VALUES; IFS=$OLD_IFS
    [ "$#" -eq 3 ] || return 1
    ORIGINAL_PID=$1; ORIGINAL_START=$2; ORIGINAL_SEQUENCE=$3
    return 0
}

validate_manifest() {
    MANIFEST_PATH=$1
    is_regular_nonsymlink "$MANIFEST_PATH" || return 1
    [ "$(stat -L -c '%s' "$MANIFEST_PATH" 2>/dev/null)" -le 1024 ] || return 1
    awk -F= -v hash="$EXPECTED_BINARY_SHA256" -v size="$EXPECTED_BINARY_SIZE" -v path="$DEST_BINARY" '
        NF!=2 {bad=1}
        $1=="schema" && $2=="1" {schema++}
        $1=="owner" && $2=="GeminiTop" {owner++}
        $1=="target" && $2=="w176-ntg5" {target++}
        $1=="component" && $2=="geminitop-proofd" {component++}
        $1=="version" && $2=="w176-stage4b-proofd-v1" {version++}
        $1=="binary_sha256" && $2==hash {found_hash++}
        $1=="binary_size" && $2==size {found_size++}
        $1=="installed_path" && $2==path {found_path++}
        {lines++}
        END {exit !(!bad&&lines==8&&schema==1&&owner==1&&target==1&&component==1&&version==1&&found_hash==1&&found_size==1&&found_path==1)}
    ' "$MANIFEST_PATH" >/dev/null 2>&1
}

validate_install_inventory() {
    validate_nvm_path "$INSTALL_PARENT" &&
        validate_nvm_path "$INSTALL_DIR" &&
        validate_nvm_path "$DEST_BINARY" &&
        validate_nvm_path "$DEST_MANIFEST" || return 1
    [ -d "$INSTALL_PARENT" ] && [ ! -L "$INSTALL_PARENT" ] &&
        [ -d "$INSTALL_DIR" ] && [ ! -L "$INSTALL_DIR" ] || return 1
    PARENT_ENTRIES=0
    for ENTRY in "$INSTALL_PARENT"/* "$INSTALL_PARENT"/.[!.]* "$INSTALL_PARENT"/..?*; do
        [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || continue
        PARENT_ENTRIES=$((PARENT_ENTRIES + 1))
        [ "$PARENT_ENTRIES" -le 2 ] && [ "$ENTRY" = "$INSTALL_DIR" ] || return 1
    done
    [ "$PARENT_ENTRIES" -eq 1 ] || return 1
    INSTALL_ENTRIES=0
    for ENTRY in "$INSTALL_DIR"/* "$INSTALL_DIR"/.[!.]* "$INSTALL_DIR"/..?*; do
        [ -e "$ENTRY" ] || [ -L "$ENTRY" ] || continue
        INSTALL_ENTRIES=$((INSTALL_ENTRIES + 1))
        [ "$INSTALL_ENTRIES" -le 3 ] || return 1
        case "$ENTRY" in "$DEST_BINARY"|"$DEST_MANIFEST") ;; *) return 1 ;; esac
        is_regular_nonsymlink "$ENTRY" || return 1
    done
    [ "$INSTALL_ENTRIES" -eq 2 ] || return 1
    validate_hash "$DEST_BINARY" "$EXPECTED_BINARY_SHA256" "$EXPECTED_BINARY_SIZE" &&
        validate_manifest "$DEST_MANIFEST"
}

validate_process_detached_from_usb() {
    DETACHED_PID=$1
    read_process_identity "$DETACHED_PID" || return 1
    DETACHED_IDENTITY_PRE=$PROCESS_IDENTITY
    PROCESS_CWD_ONE=$(readlink "$PROCESS_ROOT/$DETACHED_PID/cwd" 2>/dev/null) || return 1
    PROCESS_CWD_TWO=$(readlink "$PROCESS_ROOT/$DETACHED_PID/cwd" 2>/dev/null) || return 1
    [ "$PROCESS_CWD_ONE" = /tmp ] && [ "$PROCESS_CWD_TWO" = /tmp ] || return 1
    [ -d "$PROCESS_ROOT/$DETACHED_PID/fd" ] && [ -r "$PROCESS_ROOT/$DETACHED_PID/fd" ] || return 1
    DETACHED_FD_COUNT=0
    DETACHED_FD_NAMES=
    for DETACHED_FD in "$PROCESS_ROOT/$DETACHED_PID/fd"/[0-9]*; do
        case "$DETACHED_FD" in *'/[0-9]*') continue ;; esac
        [ -L "$DETACHED_FD" ] || return 1
        DETACHED_FD_NUMBER=${DETACHED_FD##*/}
        case "$DETACHED_FD_NUMBER" in ''|*[!0-9]*) return 1 ;; esac
        [ "$DETACHED_FD_NUMBER" -le 127 ] || return 1
        DETACHED_FD_COUNT=$((DETACHED_FD_COUNT + 1))
        [ "$DETACHED_FD_COUNT" -le 64 ] || return 1
        DETACHED_TARGET_ONE=$(readlink "$DETACHED_FD" 2>/dev/null) || return 1
        DETACHED_TARGET_TWO=$(readlink "$DETACHED_FD" 2>/dev/null) || return 1
        [ "$DETACHED_TARGET_ONE" = "$DETACHED_TARGET_TWO" ] || return 1
        case "$DETACHED_TARGET_ONE" in "$USB_ROOT"|"$USB_ROOT"/*) return 1 ;; esac
        DETACHED_FD_NAMES="$DETACHED_FD_NAMES $DETACHED_FD_NUMBER"
    done
    DETACHED_FD_NAMES_POST=
    for DETACHED_FD in "$PROCESS_ROOT/$DETACHED_PID/fd"/[0-9]*; do
        case "$DETACHED_FD" in *'/[0-9]*') continue ;; esac
        [ -L "$DETACHED_FD" ] || return 1
        DETACHED_FD_NAMES_POST="$DETACHED_FD_NAMES_POST ${DETACHED_FD##*/}"
    done
    [ "$DETACHED_FD_NAMES" = "$DETACHED_FD_NAMES_POST" ] || return 1
    read_process_identity "$DETACHED_PID" || return 1
    [ "$PROCESS_IDENTITY" = "$DETACHED_IDENTITY_PRE" ] || return 1
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
    : > .HASHES.txt.tmp || exit 1
    if [ "$SCOPE" = w176-stage4b-residency-install ]; then
        for RESULT_FILE in TARGET.txt PROCESS.txt RESULT.txt ERRORS.txt STATUS.txt; do
            is_regular_nonsymlink "$RESULT_FILE" || exit 1
            sha256sum "$RESULT_FILE" >> .HASHES.txt.tmp || exit 1
        done
    else
        for RESULT_FILE in RESULT.txt ERRORS.txt STATUS.txt; do
            is_regular_nonsymlink "$RESULT_FILE" || exit 1
            sha256sum "$RESULT_FILE" >> .HASHES.txt.tmp || exit 1
        done
    fi
    mv .HASHES.txt.tmp HASHES.txt || exit 1
    sha256sum -c HASHES.txt >/dev/null 2>&1 || exit 1
    printf 'complete=1\n' > .COMPLETE.tmp && mv .COMPLETE.tmp COMPLETE || exit 1
    is_regular_nonsymlink COMPLETE || exit 1
    printf '%s\n' "w176-stage4b: complete: $OUT_DISPLAY"
}
