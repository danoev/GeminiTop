#!/bin/sh
# Read-only system inventory. All output paths remain below one validated USB root.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
if [ "${W176_PROBE_TEST_MODE:-0}" = "1" ]; then
    PATH="${W176_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
    PROC_ROOT="${W176_TEST_PROC_ROOT:-/proc}"
    SYS_ROOT="${W176_TEST_SYS_ROOT:-/sys}"
    INTERNAL_ROOT="${W176_TEST_INTERNAL_ROOT:-}"
    COMMAND_TIMEOUT="${W176_TEST_TIMEOUT_SECONDS:-1}"
else
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    PROC_ROOT=/proc
    SYS_ROOT=/sys
    INTERNAL_ROOT=
    COMMAND_TIMEOUT=5
fi
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-probe: cannot locate probe directory" >&2
    exit 1
}
GUARD="$SCRIPT_DIR/mount_guard.sh"
if [ ! -f "$GUARD" ] || [ -L "$GUARD" ]; then
    printf '%s\n' "w176-probe: mount guard must be a regular non-symlink file" >&2
    exit 1
fi

[ "$#" -eq 1 ] || {
    printf '%s\n' "w176-probe: exactly one USB root is required" >&2
    exit 1
}
USB_ROOT=$(/bin/sh "$GUARD" "$1") || exit 1
[ "$USB_ROOT" = "$SCRIPT_DIR" ] || {
    printf '%s\n' "w176-probe: supplied root does not contain this probe" >&2
    exit 1
}

BASE="$USB_ROOT/stage1-probe"
OUT=
INDEX=0
MAX_OUTPUT_DIRECTORIES=100
while [ "$INDEX" -lt "$MAX_OUTPUT_DIRECTORIES" ]; do
    if [ "$INDEX" -eq 0 ]; then
        CANDIDATE=$BASE
    else
        CANDIDATE="$BASE-$INDEX"
    fi
    if [ ! -e "$CANDIDATE" ] && [ ! -L "$CANDIDATE" ]; then
        if mkdir "$CANDIDATE" 2>/dev/null; then
            OUT=$CANDIDATE
            break
        fi
        printf '%s\n' "w176-probe: cannot create output directory on USB" >&2
        exit 1
    fi
    INDEX=$((INDEX + 1))
done
[ -n "$OUT" ] || {
    printf '%s\n' "w176-probe: output directory limit reached" >&2
    exit 1
}

FAILURES=0
ERROR_INDEX=0
OPTIONAL_INDEX=0
ERROR_FILE="$OUT/ERRORS.txt"
OPTIONAL_FILE="$OUT/OPTIONAL.txt"
STATUS_FILE="$OUT/STATUS.txt"
OUTPUT_BLOCK_LIMIT=512
MAX_INTERNAL_FILE_BYTES=67108864
MAX_APPINFO_BYTES=1048576
MAX_HANDLER_CANDIDATES=64

if ! : > "$ERROR_FILE" || ! : > "$OPTIONAL_FILE"; then
    printf '%s\n' "w176-probe: cannot initialize status files" >&2
    exit 1
fi

write_status() {
    STATUS_VALUE=$1
    {
        printf '%s\n' "schema=1"
        printf '%s\n' "status=$STATUS_VALUE"
        printf '%s\n' "mandatory_failures=$FAILURES"
        printf '%s\n' "errors=ERRORS.txt"
        printf '%s\n' "optional=OPTIONAL.txt"
    } > "$STATUS_FILE"
}

record_failure() {
    FAILURES=$((FAILURES + 1))
    ERROR_INDEX=$((ERROR_INDEX + 1))
    printf 'error.%s=%s\n' "$ERROR_INDEX" "$1" >> "$ERROR_FILE" 2>/dev/null || true
}

record_optional() {
    OPTIONAL_INDEX=$((OPTIONAL_INDEX + 1))
    printf 'optional.%s=%s\n' "$OPTIONAL_INDEX" "$1" >> "$OPTIONAL_FILE" 2>/dev/null || record_failure "cannot_write_optional_manifest"
}

if ! write_status INCOMPLETE; then
    printf '%s\n' "w176-probe: cannot write status manifest" >&2
    exit 1
fi

MISSING_COMMAND=0
for REQUIRED_COMMAND in awk cat cp ls mkdir mv ps uname wc; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        record_failure "missing_command:$REQUIRED_COMMAND"
        MISSING_COMMAND=1
    fi
done

TIMEOUT_MODE=
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_MODE=timeout
elif command -v busybox >/dev/null 2>&1 && busybox timeout --help >/dev/null 2>&1; then
    TIMEOUT_MODE=busybox
else
    record_failure "missing_command:timeout"
    MISSING_COMMAND=1
fi

if [ "$MISSING_COMMAND" -ne 0 ]; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: mandatory command unavailable; output incomplete: $OUT" >&2
    exit 1
fi

run_bounded() {
    if [ "$TIMEOUT_MODE" = timeout ]; then
        timeout "$COMMAND_TIMEOUT" "$@"
    else
        busybox timeout "$COMMAND_TIMEOUT" "$@"
    fi
}

capture_mandatory() {
    LABEL=$1
    OUTPUT_FILE=$2
    shift 2
    TEMP_FILE="$OUT/.$OUTPUT_FILE.tmp"
    if (ulimit -f "$OUTPUT_BLOCK_LIMIT"; run_bounded "$@") > "$TEMP_FILE" 2>&1; then
        if ! mv "$TEMP_FILE" "$OUT/$OUTPUT_FILE"; then
            record_failure "$LABEL:cannot_commit_output"
        fi
    else
        mv "$TEMP_FILE" "$OUT/$OUTPUT_FILE" 2>/dev/null || true
        record_failure "$LABEL:collection_failed_or_timed_out"
    fi
}

capture_mandatory uname uname.txt uname -a
capture_mandatory cpuinfo cpuinfo.txt cat "$PROC_ROOT/cpuinfo"
capture_mandatory mtd mtd.txt cat "$PROC_ROOT/mtd"
capture_mandatory cmdline cmdline.txt cat "$PROC_ROOT/cmdline"
capture_mandatory mounts mounts.txt cat "$PROC_ROOT/mounts"
capture_mandatory input_devices input-devices.txt cat "$PROC_ROOT/bus/input/devices"
capture_mandatory input_nodes input-nodes.txt ls -la "$INTERNAL_ROOT/dev/input"
capture_mandatory applications applications.txt ls -la "$INTERNAL_ROOT/application/bin" "$INTERNAL_ROOT/usr/local/bin"
capture_mandatory services services.txt ps

FRAMEBUFFER_TEMP="$OUT/.framebuffer.txt.tmp"
if {
    for ATTRIBUTE in virtual_size bits_per_pixel stride name; do
        VALUE=UNKNOWN
        ATTRIBUTE_PATH="$SYS_ROOT/class/graphics/fb0/$ATTRIBUTE"
        if [ -r "$ATTRIBUTE_PATH" ]; then
            VALUE=$(run_bounded cat "$ATTRIBUTE_PATH" 2>/dev/null) || VALUE=UNKNOWN
        fi
        printf '%s=%s\n' "$ATTRIBUTE" "$VALUE"
    done
} > "$FRAMEBUFFER_TEMP"; then
    if command -v fbset >/dev/null 2>&1; then
        if (ulimit -f "$OUTPUT_BLOCK_LIMIT"; run_bounded fbset) >> "$FRAMEBUFFER_TEMP" 2>&1; then
            record_optional "fbset=OK"
        else
            record_optional "fbset=SKIPPED:failed_or_timed_out"
        fi
    else
        record_optional "fbset=SKIPPED:command_unavailable"
    fi
    mv "$FRAMEBUFFER_TEMP" "$OUT/framebuffer.txt" || record_failure "framebuffer:cannot_commit_output"
else
    record_failure "framebuffer:cannot_write_output"
fi

APPINFO_SOURCE=
for CANDIDATE in \
    "$INTERNAL_ROOT/application/etc/appinfo.rc" \
    "$INTERNAL_ROOT/usr/local/etc/appinfo.rc" \
    "$INTERNAL_ROOT/system/etc/appinfo.rc" \
    "$INTERNAL_ROOT/etc/appinfo.rc"
do
    [ -e "$CANDIDATE" ] || [ -L "$CANDIDATE" ] || continue
    if [ ! -f "$CANDIDATE" ] || [ -L "$CANDIDATE" ]; then
        record_optional "appinfo:$CANDIDATE=SKIPPED:non_regular_or_symlink"
        continue
    fi
    APPINFO_SIZE=$(run_bounded wc -c < "$CANDIDATE" 2>/dev/null) || {
        record_optional "appinfo:$CANDIDATE=SKIPPED:size_check_failed"
        continue
    }
    case "$APPINFO_SIZE" in
        ''|*[!0-9]*) record_optional "appinfo:$CANDIDATE=SKIPPED:invalid_size"; continue ;;
    esac
    if [ "$APPINFO_SIZE" -gt "$MAX_APPINFO_BYTES" ]; then
        record_optional "appinfo:$CANDIDATE=SKIPPED:too_large"
        continue
    fi
    if run_bounded cp "$CANDIDATE" "$OUT/.appinfo.rc.tmp" 2>/dev/null && mv "$OUT/.appinfo.rc.tmp" "$OUT/appinfo.rc"; then
        APPINFO_SOURCE=$CANDIDATE
        record_optional "appinfo:$CANDIDATE=OK"
        break
    fi
    record_optional "appinfo:$CANDIDATE=SKIPPED:copy_failed_or_timed_out"
done
[ -n "$APPINFO_SOURCE" ] || record_optional "appinfo=SKIPPED:no_safe_candidate"

HASH_MODE=
if command -v sha256sum >/dev/null 2>&1; then
    HASH_MODE=sha256sum
elif command -v busybox >/dev/null 2>&1 && busybox sha256sum --help >/dev/null 2>&1; then
    HASH_MODE=busybox
fi

hash_file_bounded() {
    if [ "$HASH_MODE" = sha256sum ]; then
        run_bounded sha256sum "$1"
    else
        run_bounded busybox sha256sum "$1"
    fi
}

if [ -n "$HASH_MODE" ]; then
    if ! : > "$OUT/usb-handlers.sha256"; then
        record_failure "usb_handler_hashes:cannot_create_output"
    else
        HANDLER_COUNT=0
        for CANDIDATE in \
            "$INTERNAL_ROOT"/usr/local/bin/*usb* \
            "$INTERNAL_ROOT"/usr/local/bin/*Usb* \
            "$INTERNAL_ROOT"/application/bin/*usb* \
            "$INTERNAL_ROOT"/application/bin/*Usb*
        do
            [ -e "$CANDIDATE" ] || [ -L "$CANDIDATE" ] || continue
            HANDLER_COUNT=$((HANDLER_COUNT + 1))
            if [ "$HANDLER_COUNT" -gt "$MAX_HANDLER_CANDIDATES" ]; then
                record_optional "usb_handlers=SKIPPED:candidate_limit_reached"
                break
            fi
            if [ ! -f "$CANDIDATE" ] || [ -L "$CANDIDATE" ]; then
                record_optional "usb_handler:$CANDIDATE=SKIPPED:non_regular_or_symlink"
                continue
            fi
            HANDLER_SIZE=$(run_bounded wc -c < "$CANDIDATE" 2>/dev/null) || {
                record_optional "usb_handler:$CANDIDATE=SKIPPED:size_check_failed"
                continue
            }
            case "$HANDLER_SIZE" in
                ''|*[!0-9]*) record_optional "usb_handler:$CANDIDATE=SKIPPED:invalid_size"; continue ;;
            esac
            if [ "$HANDLER_SIZE" -gt "$MAX_INTERNAL_FILE_BYTES" ]; then
                record_optional "usb_handler:$CANDIDATE=SKIPPED:too_large"
                continue
            fi
            if hash_file_bounded "$CANDIDATE" >> "$OUT/usb-handlers.sha256" 2>/dev/null; then
                record_optional "usb_handler:$CANDIDATE=OK"
            else
                record_optional "usb_handler:$CANDIDATE=SKIPPED:hash_failed_or_timed_out"
            fi
        done
    fi
    if [ -f "$OUT/appinfo.rc" ] && [ ! -L "$OUT/appinfo.rc" ]; then
        if ! hash_file_bounded "$OUT/appinfo.rc" > "$OUT/appinfo.sha256" 2>/dev/null; then
            record_optional "appinfo_hash=SKIPPED:hash_failed_or_timed_out"
        fi
    fi
else
    record_optional "hashing=SKIPPED:sha256_command_unavailable"
fi

HARDWARE=$(awk -F: '/^Hardware[[:space:]]*:/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' "$OUT/cpuinfo.txt" 2>/dev/null)
KERNEL_RELEASE=$(awk '$1 == "Linux" { print $3; exit }' "$OUT/uname.txt" 2>/dev/null)
NVM_HEX=$(awk '/"nvm"/ { print $2; exit }' "$OUT/mtd.txt" 2>/dev/null)
FB_SIZE=$(awk -F= '$1 == "virtual_size" { print $2; exit }' "$OUT/framebuffer.txt" 2>/dev/null)
FB_BPP=$(awk -F= '$1 == "bits_per_pixel" { print $2; exit }' "$OUT/framebuffer.txt" 2>/dev/null)

SUMMARY_TEMP="$OUT/.stage1-summary.txt.tmp"
if {
    printf '%s\n' "# GeminiTop W176 Stage-1 normalized hints"
    [ -n "$HARDWARE" ] && printf 'identity.hardware=%s\n' "$HARDWARE"
    [ -n "$KERNEL_RELEASE" ] && printf 'kernel.release=%s\n' "$KERNEL_RELEASE"
    if [ -n "$NVM_HEX" ]; then
        case "$NVM_HEX" in
            *[!0-9a-fA-F]*) ;;
            *) printf 'mtd.nvm_hex=%s\n' "$NVM_HEX" ;;
        esac
    fi
    [ -n "$FB_SIZE" ] && [ "$FB_SIZE" != UNKNOWN ] && printf 'framebuffer.virtual_size=%s\n' "$FB_SIZE"
    [ -n "$FB_BPP" ] && [ "$FB_BPP" != UNKNOWN ] && printf 'framebuffer.bits_per_pixel=%s\n' "$FB_BPP"
    [ -n "$APPINFO_SOURCE" ] && printf 'appinfo.source=%s\n' "$APPINFO_SOURCE"
    :
} > "$SUMMARY_TEMP" && mv "$SUMMARY_TEMP" "$OUT/stage1-summary.txt"; then
    :
else
    record_failure "summary:cannot_write_output"
fi

README_TEMP="$OUT/.README.txt.tmp"
if {
    printf '%s\n' "Stage-1 probe collection finished."
    printf '%s\n' "Consult STATUS.txt and require both status=COMPLETE and the COMPLETE marker."
    printf '%s\n' "Output was written only to: $OUT"
    printf '%s\n' "No raw CAN, NVM/MTD payload, network, MCU, or Roadtop filesystem write was performed."
} > "$README_TEMP" && mv "$README_TEMP" "$OUT/README.txt"; then
    :
else
    record_failure "readme:cannot_write_output"
fi

if [ "$FAILURES" -ne 0 ]; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: mandatory collection failed; output incomplete: $OUT" >&2
    exit 1
fi

if ! write_status COMPLETE; then
    record_failure "status:cannot_write_complete_manifest"
    write_status INCOMPLETE >/dev/null 2>&1 || true
    exit 1
fi
if ! : > "$OUT/.COMPLETE.tmp" || ! mv "$OUT/.COMPLETE.tmp" "$OUT/COMPLETE"; then
    record_failure "complete_marker:cannot_create"
    write_status INCOMPLETE >/dev/null 2>&1 || true
    exit 1
fi

printf '%s\n' "w176-probe: complete: $OUT"
