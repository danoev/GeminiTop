#!/bin/sh
# W176 Stage-4B metadata-only capability preflight.
set -u
CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
ulimit -f 4096 || exit 1
ROOT=
PROC=/proc
SYS=/sys
DEV=/dev
MAX_TOTAL_KIB=3072
fail() { printf '%s\n' "w176-stage4b-capability: $1" >&2; exit 1; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }

[ "$#" -eq 1 ] || fail "one USB root required"
ANCHOR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || fail "payload anchor"
REQUESTED=$(cd -P "$1" 2>/dev/null && pwd -P) || fail "requested root"
cd "$ANCHOR" || fail "anchor chdir"
[ "$ANCHOR" = "$REQUESTED" ] && [ . -ef "$REQUESTED" ] 2>/dev/null || fail "root mismatch"
regular ./mount_guard.sh || fail "mount guard missing"
regular ./root_mount_guard.sh || fail "root mount guard missing"
[ "$(/bin/sh ./mount_guard.sh .)" = "$ANCHOR" ] || fail "USB validation"
LOCK=./.stage4b-capability.lock
mkdir "$LOCK" 2>/dev/null || fail "one-shot lock unavailable"
[ -d "$LOCK" ] && [ ! -L "$LOCK" ] || fail "lock ambiguous"
MARKER=./ARM_STAGE4B_CAPABILITY_PREFLIGHT
regular "$MARKER" || fail "not armed"
rm -f "$MARKER" || fail "marker consumption"
[ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || fail "marker remains"
OUT=
N=0
while [ "$N" -lt 100 ]; do
    if [ "$N" -eq 0 ]; then CANDIDATE=stage4b-capability
    else CANDIDATE="stage4b-capability-$N"; fi
    if mkdir "$CANDIDATE" 2>/dev/null; then OUT=$CANDIDATE; break; fi
    [ -e "$CANDIDATE" ] || [ -L "$CANDIDATE" ] || fail "mkdir failed"
    N=$((N + 1))
done
[ -n "$OUT" ] || fail "output names exhausted"
cd "$OUT" || fail "output chdir"
mkdir kernel mounts metadata userspace || exit 1
: > ERRORS.txt
: > OPTIONAL.txt
: > .paths
FAILURES=0
OPTIONALS=0

status() {
    printf 'schema=1\nscope=w176-stage4b-capability-metadata\nstatus=%s\nmandatory_failures=%s\noptional_unknowns=%s\n' \
        "$1" "$FAILURES" "$OPTIONALS" > .status.tmp || return 1
    regular .status.tmp && mv .status.tmp STATUS.txt && regular STATUS.txt
}
status INCOMPLETE || exit 1
append_line() {
    FILE=$1; LIMIT=$2; LINE=$3
    SIZE=$(stat -c '%s' "$FILE" 2>/dev/null) || return 1
    [ $((SIZE + ${#LINE} + 1)) -le "$LIMIT" ] || return 1
    printf '%s\n' "$LINE" >> "$FILE"
}
mandatory_fail() {
    FAILURES=$((FAILURES + 1))
    append_line ERRORS.txt 8192 "failure.$FAILURES=$1" || exit 1
}
optional_unknown() {
    OPTIONALS=$((OPTIONALS + 1))
    append_line OPTIONAL.txt 8192 "optional.$OPTIONALS=$1" || mandatory_fail optional_log_full
}
incomplete() {
    [ ! -e COMPLETE ] && [ ! -L COMPLETE ] || rm -f COMPLETE 2>/dev/null || true
    status INCOMPLETE 2>/dev/null || true
    exit 1
}
register() {
    FILE=$1
    regular "$FILE" || return 1
    grep -F -x "$FILE" .paths >/dev/null 2>&1 && return 1
    append_line .paths 4096 "$FILE"
}

# Ordinary/proc/sysfs regular-file snapshot, one descriptor, bounded read.
capture() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST=$4; NEED=$5
    [ "$FAILURES" -eq 0 ] || return 1
    GUARD_ROOT=$ROOT
    [ -n "$GUARD_ROOT" ] || GUARD_ROOT=/
    SAFE=$(/bin/sh ../root_mount_guard.sh "$SOURCE" "$GUARD_ROOT" "$PROC/self/mounts" 2>/dev/null) || {
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:root_mount"
        else optional_unknown "$LABEL:root_mount"; fi
        return 1
    }
    [ "$SAFE" = "$SOURCE" ] || { mandatory_fail "$LABEL:canonical_mismatch"; return 1; }
    PARENT=$(dirname "$SOURCE") || { mandatory_fail "$LABEL:parent"; return 1; }
    [ -d "$PARENT" ] && [ ! -L "$PARENT" ] &&
        [ "$(cd -P "$PARENT" 2>/dev/null && pwd -P)" = "$PARENT" ] || {
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:parent_unsafe"
        else optional_unknown "$LABEL:parent_unsafe"; fi
        return 1
    }
    [ ! -L "$SOURCE" ] && [ -f "$SOURCE" ] || {
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:absent_or_unsafe"
        else optional_unknown "$LABEL:absent_or_unsafe"; fi
        return 1
    }
    TYPE=$(stat -c '%F' "$SOURCE" 2>/dev/null) || TYPE=unknown
    SIZE=$(stat -c '%s' "$SOURCE" 2>/dev/null) || SIZE=unknown
    [ "$TYPE" = "regular file" ] || {
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:not_regular"
        else optional_unknown "$LABEL:not_regular"; fi
        return 1
    }
    case "$SIZE" in ''|*[!0-9]*) mandatory_fail "$LABEL:bad_size"; return 1 ;; esac
    if [ "$SIZE" -gt "$LIMIT" ]; then
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:pre_size_limit"
        else optional_unknown "$LABEL:pre_size_limit"; fi
        return 1
    fi
    BEFORE=$(stat -c '%d|%i|%f|%s|%Y|%Z' "$SOURCE" 2>/dev/null) || {
        mandatory_fail "$LABEL:pre_stat"; return 1;
    }
    TEMP="$DEST.tmp"
    rm -f "$TEMP" 2>/dev/null || { mandatory_fail "$LABEL:temp_cleanup"; return 1; }
    # Post-open descriptor identity/type precedes data read. Read admission
    # maximum is LIMIT+4096; oversize output is removed and never committed.
    if /bin/sh -c '
        source=$1; before=$2; limit=$3; temp=$4; guard=$5; root=$6; mounts=$7
        safe=$(/bin/sh "$guard" "$source" "$root" "$mounts") || exit 20
        [ "$safe" = "$source" ] || exit 20
        exec 3< "$source" || exit 21
        [ -f /proc/self/fd/3 ] || exit 22
        opened=$(stat -L -c "%d|%i|%f|%s|%Y|%Z" /proc/self/fd/3) || exit 23
        [ "$opened" = "$before" ] && [ ! -L "$source" ] || exit 24
        blocks=$((limit / 4096 + 1))
        dd bs=4096 count="$blocks" <&3 > "$temp" 2>/dev/null || exit 25
        actual=$(stat -c "%s" "$temp") || exit 26
        [ "$actual" -le "$limit" ] || exit 27
        [ "$(stat -L -c "%d|%i|%f|%s|%Y|%Z" /proc/self/fd/3)" = "$before" ] || exit 28
        [ "$(stat -c "%d|%i|%f|%s|%Y|%Z" "$source")" = "$before" ] || exit 29
    ' sh "$SOURCE" "$BEFORE" "$LIMIT" "$TEMP" ../root_mount_guard.sh "$GUARD_ROOT" "$PROC/self/mounts"; then :; else
        rm -f "$TEMP" 2>/dev/null || true
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:bounded_read_failed"
        else optional_unknown "$LABEL:bounded_read_failed"; fi
        return 1
    fi
    regular "$TEMP" && mv "$TEMP" "$DEST" && register "$DEST" || {
        mandatory_fail "$LABEL:output_commit"; return 1;
    }
}
capture_virtual() {
    LABEL=$1; SOURCE=$2; LIMIT=$3; DEST=$4; NEED=$5
    [ "$FAILURES" -eq 0 ] || return 1
    [ ! -L "$SOURCE" ] && [ -f "$SOURCE" ] &&
        [ "$(stat -c '%F' "$SOURCE" 2>/dev/null)" = "regular file" ] || {
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:absent_or_unsafe"
        else optional_unknown "$LABEL:absent_or_unsafe"; fi
        return 1
    }
    TEMP="$DEST.tmp"
    rm -f "$TEMP" 2>/dev/null || { mandatory_fail "$LABEL:temp_cleanup"; return 1; }
    case "$DEST" in
        mounts/proc-mounts.txt|mounts/mountinfo.txt|mounts/proc-mtd.txt|metadata/mtd12-*.txt)
            # These files can support NVM CONFIRMED. Do not accept a
            # short-read prefix as a complete association view.
            BLOCK_SIZE=1; BLOCKS=$((LIMIT + 1)) ;;
        *) BLOCK_SIZE=4096; BLOCKS=$((LIMIT / 4096 + 1)) ;;
    esac
    if dd if="$SOURCE" of="$TEMP" bs="$BLOCK_SIZE" count="$BLOCKS" 2>/dev/null; then :; else
        rm -f "$TEMP"
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:producer_failed"
        else optional_unknown "$LABEL:producer_failed"; fi
        return 1
    fi
    ACTUAL=$(stat -c '%s' "$TEMP" 2>/dev/null) || ACTUAL=99999999
    if [ "$ACTUAL" -gt "$LIMIT" ]; then
        rm -f "$TEMP"
        if [ "$NEED" = mandatory ]; then mandatory_fail "$LABEL:limit"
        else optional_unknown "$LABEL:limit"; fi
        return 1
    fi
    regular "$TEMP" && mv "$TEMP" "$DEST" && register "$DEST" || mandatory_fail "$LABEL:output_commit"
}
metadata_line() {
    LABEL=$1; OBJECT=$2
    if [ -e "$OBJECT" ] || [ -L "$OBJECT" ]; then
        RESULT=$(stat -c '%F|%d|%i|%f|%s|%a|%t|%T' "$OBJECT" 2>/dev/null) || {
            optional_unknown "$LABEL:stat_failed"; return 1;
        }
        [ "${#RESULT}" -le 512 ] || { mandatory_fail "$LABEL:stat_overlong"; return 1; }
        append_line metadata/objects.txt 16384 "$LABEL|$RESULT" || mandatory_fail metadata_full
        if [ -L "$OBJECT" ]; then
            LINK=$(readlink "$OBJECT" 2>/dev/null) || { optional_unknown "$LABEL:readlink_failed"; return 1; }
            [ "${#LINK}" -le 4096 ] || { mandatory_fail "$LABEL:link_overlong"; return 1; }
            append_line metadata/objects.txt 16384 "$LABEL.link|$LINK" || mandatory_fail metadata_full
        fi
    else
        append_line metadata/objects.txt 16384 "$LABEL|ABSENT" || mandatory_fail metadata_full
        optional_unknown "$LABEL:absent"
    fi
}

for CMD in awk dd dirname du grep mkdir mv pwd readlink rm sha256sum stat uname; do
    command -v "$CMD" >/dev/null 2>&1 || mandatory_fail "missing_command:$CMD"
done
[ "$FAILURES" -eq 0 ] || incomplete
if uname -a > kernel/uname.txt 2>/dev/null &&
   [ "$(stat -c '%s' kernel/uname.txt)" -le 4096 ]; then
    register kernel/uname.txt || mandatory_fail uname_output
else mandatory_fail uname_failed; fi
capture_virtual proc_version "$PROC/version" 8192 kernel/proc-version.txt mandatory
capture_virtual osrelease "$PROC/sys/kernel/osrelease" 1024 kernel/osrelease.txt mandatory
capture_virtual filesystems "$PROC/filesystems" 16384 kernel/filesystems.txt mandatory
capture_virtual mounts "$PROC/self/mounts" 65536 mounts/proc-mounts.txt mandatory
capture_virtual mountinfo "$PROC/self/mountinfo" 131072 mounts/mountinfo.txt mandatory
capture_virtual mtd "$PROC/mtd" 16384 mounts/proc-mtd.txt mandatory

# Optional config sources: exact reviewed names only; no wildcard/search.
: > metadata/objects.txt || mandatory_fail metadata_create
metadata_line proc_config "$PROC/config.gz"
metadata_line boot_config "$ROOT/boot/config-4.9.217"
metadata_line kallsyms "$PROC/kallsyms"
capture_virtual proc_config "$PROC/config.gz" 262144 kernel/proc-config.gz optional
capture boot_config "$ROOT/boot/config-4.9.217" 524288 kernel/boot-config.txt optional

# Read limit+one block; only complete newline-terminated records within the
# accepted 512 KiB prefix may contribute positive symbols. Never export
# addresses, and never infer absence from this bounded view.
if [ ! -L "$PROC/kallsyms" ] && [ -f "$PROC/kallsyms" ]; then
    if dd if="$PROC/kallsyms" of=.kallsyms-prefix.tmp bs=4096 count=129 2>/dev/null; then
        RAW_SIZE=$(stat -c '%s' .kallsyms-prefix.tmp 2>/dev/null) || RAW_SIZE=0
        if [ "$RAW_SIZE" -gt 524288 ]; then
            if dd if=.kallsyms-prefix.tmp of=.kallsyms-cut.tmp bs=4096 count=128 2>/dev/null; then
                SYMBOL_SOURCE=.kallsyms-cut.tmp
                SYMBOL_SIZE=524288
                optional_unknown "kallsyms:truncated_prefix"
            else SYMBOL_SOURCE=; optional_unknown "kallsyms:truncate_failed"; fi
        else
            SYMBOL_SOURCE=.kallsyms-prefix.tmp
            SYMBOL_SIZE=$RAW_SIZE
            optional_unknown "kallsyms:bounded_no_absence_claim"
        fi
        COMPLETE_LINE=0
        if [ -n "$SYMBOL_SOURCE" ] && [ "$SYMBOL_SIZE" -gt 0 ]; then
            LAST=$(dd if="$SYMBOL_SOURCE" bs=1 skip=$((SYMBOL_SIZE - 1)) count=1 2>/dev/null && printf x) || LAST=
            NEWLINE_X=$(printf '\nx')
            [ "$LAST" = "$NEWLINE_X" ] && COMPLETE_LINE=1
        fi
        if [ -n "$SYMBOL_SOURCE" ] &&
           awk -v complete="$COMPLETE_LINE" '
               NF >= 3 && $3 ~ /(^|_)(memfd_create|execveat|shmem_add_seals|shmem_get_seals)$/ { found[NR]=$3 }
               END { for (i=1; i<=NR; i++) if ((i<NR || complete==1) && (i in found)) {
                   if (used + length(found[i]) + 1 > 8192) exit 2
                   print found[i]; used += length(found[i]) + 1
               } }
           ' "$SYMBOL_SOURCE" > kernel/symbol-names.txt &&
           [ "$(stat -c '%s' kernel/symbol-names.txt)" -le 8192 ]; then
            register kernel/symbol-names.txt || mandatory_fail symbols_output
        else
            rm -f kernel/symbol-names.txt || mandatory_fail symbols_cleanup
            optional_unknown "kallsyms:filter_or_limit"
        fi
    else optional_unknown "kallsyms:read_failed"; fi
else optional_unknown "kallsyms:absent_or_unsafe"; fi
rm -f .kallsyms-prefix.tmp || mandatory_fail kallsyms_temp
rm -f .kallsyms-cut.tmp || mandatory_fail kallsyms_cut_temp

metadata_line media "$ROOT/media"
metadata_line nvm "$ROOT/tmp/sp/media/flash/nvm"
metadata_line mtdblock12 "$DEV/mtdblock12"
metadata_line mtd12 "$SYS/class/mtd/mtd12"
metadata_line class_block "$SYS/class/block/mtdblock12"
metadata_line proc_self_fd "$PROC/self/fd"
metadata_line libc_link "$ROOT/lib/libc.so.6"
metadata_line loader_link "$ROOT/lib/ld-linux-armhf.so.3"
metadata_line libc_file "$ROOT/lib/libc-2.30.so"
metadata_line loader_file "$ROOT/lib/ld-2.30.so"
# A one-hop, in-scope runtime libc link is recorded explicitly. No arbitrary
# symlink chain is traversed. Anything else leaves host wrapper proof UNKNOWN.
LIBC_RESOLVED=UNKNOWN
if [ -L "$ROOT/lib/libc.so.6" ]; then
    LIBC_TARGET=$(readlink "$ROOT/lib/libc.so.6" 2>/dev/null) || LIBC_TARGET=
    case "$LIBC_TARGET" in
        libc-2.30.so|/lib/libc-2.30.so) LIBC_RESOLVED=/lib/libc-2.30.so ;;
    esac
fi
append_line metadata/objects.txt 16384 "libc_resolved|$LIBC_RESOLVED" || mandatory_fail metadata_full
if [ -b "$DEV/mtdblock12" ] && [ ! -L "$DEV/mtdblock12" ]; then
    MAJOR_HEX=$(stat -c '%t' "$DEV/mtdblock12" 2>/dev/null) || MAJOR_HEX=
    MINOR_HEX=$(stat -c '%T' "$DEV/mtdblock12" 2>/dev/null) || MINOR_HEX=
    case "$MAJOR_HEX:$MINOR_HEX" in *[!0-9a-fA-F:]*|:|*::*) optional_unknown dev_block_bad_numbers ;;
    *) MAJOR_DEC=$(printf '%d' "0x$MAJOR_HEX" 2>/dev/null) || MAJOR_DEC=
       MINOR_DEC=$(printf '%d' "0x$MINOR_HEX" 2>/dev/null) || MINOR_DEC=
       if [ -n "$MAJOR_DEC" ] && [ -n "$MINOR_DEC" ]; then
           metadata_line sys_dev_block "$SYS/dev/block/$MAJOR_DEC:$MINOR_DEC"
       else optional_unknown dev_block_conversion; fi ;;
    esac
else optional_unknown mtdblock12_not_block; fi
register metadata/objects.txt || mandatory_fail metadata_register
for ATTRIBUTE in name type size erasesize dev; do
    capture_virtual "mtd12_$ATTRIBUTE" "$SYS/class/mtd/mtd12/$ATTRIBUTE" 4096 \
        "metadata/mtd12-$ATTRIBUTE.txt" optional
done

# Static-analysis data only. Exact filenames observed in Stage-2; no search.
capture libc_file "$ROOT/lib/libc-2.30.so" 1048576 userspace/libc-2.30.so optional
capture loader_file "$ROOT/lib/ld-2.30.so" 131072 userspace/ld-2.30.so optional
printf '%s\n' 'schema=1' 'scope=w176-stage4b-capability-metadata' \
    'sealed_runtime_execution=NOT_TESTED' 'feature_syscalls.invoked=0' \
    'nvm.writes=0' 'device_streams.opened=0' > SUMMARY.txt || mandatory_fail summary_write
printf '%s\n' 'schema=1' 'max_final_kib=3072' \
    'config_proc_max=262144' 'config_boot_max=524288' \
    'kallsyms_prefix_max=524288' 'libc_max=1048576' 'loader_max=131072' \
    'all_sources_exact_allowlist=1' 'producer_status_checked=1' \
    'output_write_ceiling=NOT_CLAIMED' > CAPABILITIES.txt || mandatory_fail capabilities_write
register SUMMARY.txt || mandatory_fail summary_register
register CAPABILITIES.txt || mandatory_fail capabilities_register
register ERRORS.txt || mandatory_fail errors_register
register OPTIONAL.txt || mandatory_fail optional_register
[ "$FAILURES" -eq 0 ] || incomplete

mv .paths INVENTORY.txt || incomplete
regular INVENTORY.txt || incomplete
status COMPLETE || incomplete
hash_one() {
    SOURCE=$1; DISPLAY=$2
    sha256sum "$SOURCE" > .hash.tmp 2>/dev/null || return 1
    regular .hash.tmp || return 1
    [ "$(stat -c '%s' .hash.tmp)" -le 512 ] || return 1
    DIGEST=$(awk -v expected="$SOURCE" '
        NR == 1 && NF == 2 && length($1) == 64 && $1 !~ /[^0-9a-f]/ &&
        $2 == expected && $0 == $1 "  " expected { print $1; ok=1 }
        END { if (NR != 1 || !ok) exit 1 }
    ' .hash.tmp) || return 1
    [ "${#DIGEST}" -eq 64 ] || return 1
    printf '%s  %s\n' "$DIGEST" "$DISPLAY" >> .checksums.tmp
    rm -f .hash.tmp
}
: > .checksums.tmp || incomplete
while IFS= read -r FILE; do
    regular "$FILE" || incomplete
    hash_one "$FILE" "$FILE" || incomplete
done < INVENTORY.txt
hash_one INVENTORY.txt INVENTORY.txt || incomplete
hash_one STATUS.txt STATUS.txt || incomplete
printf 'complete=1\n' > .COMPLETE.tmp || incomplete
hash_one .COMPLETE.tmp COMPLETE || incomplete
rm -f .hash.tmp || incomplete
regular .checksums.tmp && mv .checksums.tmp checksums.sha256 || incomplete
[ ! -s ERRORS.txt ] || incomplete
du -sk . > .du.tmp 2>/dev/null || incomplete
KIB=$(awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; ok=1 } END { if (NR != 1 || !ok) exit 1 }' .du.tmp) || incomplete
[ "$KIB" -le "$MAX_TOTAL_KIB" ] || incomplete
rm -f .du.tmp || incomplete
[ ! -e COMPLETE ] && [ ! -L COMPLETE ] || incomplete
regular .COMPLETE.tmp && mv .COMPLETE.tmp COMPLETE || incomplete
exit 0
