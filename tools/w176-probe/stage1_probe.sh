#!/bin/sh
# Read-only system inventory. All output paths remain below one validated USB root.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
PROC_ROOT=/proc
SYS_ROOT=/sys
INTERNAL_ROOT=
COMMAND_TIMEOUT=5
COMMAND_KILL_GRACE=1
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
ERROR_WORK="$OUT/.ERRORS.txt.work"
OPTIONAL_WORK="$OUT/.OPTIONAL.txt.work"
ERROR_FILE="$OUT/ERRORS.txt"
OPTIONAL_FILE="$OUT/OPTIONAL.txt"
STATUS_FILE="$OUT/STATUS.txt"
STATUS_TEMP="$OUT/.STATUS.txt.tmp"
ERROR_LOG_FAILED=0
REQUIRED_WRITE_FAILED=0
MANIFESTS_FINALIZED=0
OUTPUT_BLOCK_LIMIT=512
MAX_INTERNAL_FILE_BYTES=67108864
MAX_APPINFO_BYTES=1048576
MAX_HANDLER_CANDIDATES=64

is_regular_nonsymlink() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

commit_regular_file() {
    COMMIT_SOURCE=$1
    COMMIT_DESTINATION=$2
    is_regular_nonsymlink "$COMMIT_SOURCE" || return 1
    mv "$COMMIT_SOURCE" "$COMMIT_DESTINATION" || return 1
    is_regular_nonsymlink "$COMMIT_DESTINATION"
}

invalidate_complete() {
    if [ -e "$OUT/COMPLETE" ] || [ -L "$OUT/COMPLETE" ]; then
        mv "$OUT/COMPLETE" "$OUT/.COMPLETE.invalid" 2>/dev/null || return 1
    fi
    return 0
}

if ! : > "$ERROR_WORK" || ! : > "$OPTIONAL_WORK" ||
    ! is_regular_nonsymlink "$ERROR_WORK" || ! is_regular_nonsymlink "$OPTIONAL_WORK"
then
    printf '%s\n' "w176-probe: cannot initialize status files" >&2
    exit 1
fi

write_status() {
    STATUS_VALUE=$1
    if ! printf '%s\n' \
        "schema=1" \
        "status=$STATUS_VALUE" \
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
        ERROR_LOG_FAILED=1
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
    MANIFEST_RESULT=0
    if ! commit_regular_file "$OPTIONAL_WORK" "$OPTIONAL_FILE"; then
        record_failure "optional_manifest:cannot_commit"
        MANIFEST_RESULT=1
    fi
    if ! commit_regular_file "$ERROR_WORK" "$ERROR_FILE"; then
        record_failure "error_manifest:cannot_commit"
        MANIFEST_RESULT=1
    fi
    MANIFESTS_FINALIZED=1
    return "$MANIFEST_RESULT"
}

finish_incomplete() {
    if [ "$MANIFESTS_FINALIZED" -eq 0 ]; then
        finalize_manifests >/dev/null 2>&1 || true
    fi
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: mandatory collection failed; output incomplete: $OUT" >&2
    exit 1
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
if command -v timeout >/dev/null 2>&1 &&
    timeout -k 1 1 /bin/sh -c ':' >/dev/null 2>&1
then
    TIMEOUT_MODE=timeout
elif command -v busybox >/dev/null 2>&1 &&
    busybox timeout -k 1 1 /bin/sh -c ':' >/dev/null 2>&1
then
    TIMEOUT_MODE=busybox
else
    record_failure "missing_hard_timeout:TERM_then_KILL"
    MISSING_COMMAND=1
fi

if [ "$MISSING_COMMAND" -ne 0 ]; then
    finish_incomplete
fi

run_bounded() {
    if [ "$TIMEOUT_MODE" = timeout ]; then
        timeout -k "$COMMAND_KILL_GRACE" "$COMMAND_TIMEOUT" "$@"
    else
        busybox timeout -k "$COMMAND_KILL_GRACE" "$COMMAND_TIMEOUT" "$@"
    fi
}

capture_mandatory() {
    LABEL=$1
    OUTPUT_FILE=$2
    shift 2
    TEMP_FILE="$OUT/.$OUTPUT_FILE.tmp"
    if (ulimit -f "$OUTPUT_BLOCK_LIMIT"; run_bounded "$@") > "$TEMP_FILE" 2>&1; then
        if ! commit_regular_file "$TEMP_FILE" "$OUT/$OUTPUT_FILE"; then
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
FRAMEBUFFER_WRITE_OK=1
if ! : > "$FRAMEBUFFER_TEMP"; then
    FRAMEBUFFER_WRITE_OK=0
else
    for ATTRIBUTE in virtual_size bits_per_pixel stride name; do
        VALUE=UNKNOWN
        ATTRIBUTE_PATH="$SYS_ROOT/class/graphics/fb0/$ATTRIBUTE"
        if [ -r "$ATTRIBUTE_PATH" ]; then
            VALUE=$(run_bounded cat "$ATTRIBUTE_PATH" 2>/dev/null) || VALUE=UNKNOWN
        fi
        if ! printf '%s=%s\n' "$ATTRIBUTE" "$VALUE" >> "$FRAMEBUFFER_TEMP"; then
            FRAMEBUFFER_WRITE_OK=0
            break
        fi
    done
fi
if [ "$FRAMEBUFFER_WRITE_OK" -eq 1 ]; then
    if command -v fbset >/dev/null 2>&1; then
        if (ulimit -f "$OUTPUT_BLOCK_LIMIT"; run_bounded fbset) >> "$FRAMEBUFFER_TEMP" 2>&1; then
            record_optional "fbset=OK"
        else
            record_optional "fbset=SKIPPED:failed_or_timed_out"
        fi
    else
        record_optional "fbset=SKIPPED:command_unavailable"
    fi
    commit_regular_file "$FRAMEBUFFER_TEMP" "$OUT/framebuffer.txt" || record_failure "framebuffer:cannot_commit_output"
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
    APPINFO_SIZE_OUTPUT=$(run_bounded wc -c "$CANDIDATE" 2>/dev/null) || {
        record_optional "appinfo:$CANDIDATE=SKIPPED:size_check_failed"
        continue
    }
    APPINFO_SIZE=$(printf '%s\n' "$APPINFO_SIZE_OUTPUT" | awk '
        NR == 1 { value = $1; valid = ($1 ~ /^[0-9]+$/) }
        END { if (NR == 1 && valid) print value }
    ')
    case "$APPINFO_SIZE" in
        ''|*[!0-9]*) record_optional "appinfo:$CANDIDATE=SKIPPED:invalid_size"; continue ;;
    esac
    if [ "$APPINFO_SIZE" -gt "$MAX_APPINFO_BYTES" ]; then
        record_optional "appinfo:$CANDIDATE=SKIPPED:too_large"
        continue
    fi
    if run_bounded cp "$CANDIDATE" "$OUT/.appinfo.rc.tmp" 2>/dev/null &&
        commit_regular_file "$OUT/.appinfo.rc.tmp" "$OUT/appinfo.rc"
    then
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
    HANDLER_CANDIDATES="$OUT/usb-handler-candidates.txt"
    HANDLER_WORK="$OUT/.usb-handler-work.tmp"
    if ! : > "$HANDLER_CANDIDATES" || ! : > "$HANDLER_WORK"; then
        record_failure "usb_handler_hashes:cannot_initialize_output"
    else
        for HANDLER_DIRECTORY in \
            "$INTERNAL_ROOT/usr/local/bin" \
            "$INTERNAL_ROOT/application/bin"
        do
            [ -d "$HANDLER_DIRECTORY" ] || continue
            if (ulimit -f "$OUTPUT_BLOCK_LIMIT"; run_bounded ls -1 "$HANDLER_DIRECTORY") > "$HANDLER_WORK" 2>/dev/null; then
                if ! awk -v prefix="$HANDLER_DIRECTORY/" \
                    'index($0, "usb") || index($0, "Usb") { print prefix $0 }' \
                    "$HANDLER_WORK" >> "$HANDLER_CANDIDATES"
                then
                    record_failure "usb_handlers:cannot_write_candidate_list"
                fi
            else
                record_optional "usb_handlers:$HANDLER_DIRECTORY=SKIPPED:enumeration_failed_or_timed_out"
            fi
        done

        if ! : > "$HANDLER_WORK"; then
            record_failure "usb_handler_hashes:cannot_initialize_hash_output"
        fi
        HANDLER_COUNT=0
        while IFS= read -r CANDIDATE || [ -n "$CANDIDATE" ]; do
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
            HANDLER_SIZE_OUTPUT=$(run_bounded wc -c "$CANDIDATE" 2>/dev/null) || {
                record_optional "usb_handler:$CANDIDATE=SKIPPED:size_check_failed"
                continue
            }
            HANDLER_SIZE=$(printf '%s\n' "$HANDLER_SIZE_OUTPUT" | awk '
                NR == 1 { value = $1; valid = ($1 ~ /^[0-9]+$/) }
                END { if (NR == 1 && valid) print value }
            ')
            case "$HANDLER_SIZE" in
                ''|*[!0-9]*) record_optional "usb_handler:$CANDIDATE=SKIPPED:invalid_size"; continue ;;
            esac
            if [ "$HANDLER_SIZE" -gt "$MAX_INTERNAL_FILE_BYTES" ]; then
                record_optional "usb_handler:$CANDIDATE=SKIPPED:too_large"
                continue
            fi
            if hash_file_bounded "$CANDIDATE" >> "$HANDLER_WORK" 2>/dev/null; then
                record_optional "usb_handler:$CANDIDATE=OK"
            else
                record_optional "usb_handler:$CANDIDATE=SKIPPED:hash_failed_or_timed_out"
            fi
        done < "$HANDLER_CANDIDATES"
        if ! commit_regular_file "$HANDLER_WORK" "$OUT/usb-handlers.sha256"; then
            record_failure "usb_handler_hashes:cannot_commit_output"
        fi
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
SUMMARY_WRITE_OK=1
if ! : > "$SUMMARY_TEMP" ||
    ! printf '%s\n' "# GeminiTop W176 Stage-1 normalized hints" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$HARDWARE" ] &&
    ! printf 'identity.hardware=%s\n' "$HARDWARE" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$KERNEL_RELEASE" ] &&
    ! printf 'kernel.release=%s\n' "$KERNEL_RELEASE" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$NVM_HEX" ]; then
    case "$NVM_HEX" in
        *[!0-9a-fA-F]*) ;;
        *) printf 'mtd.nvm_hex=%s\n' "$NVM_HEX" >> "$SUMMARY_TEMP" || SUMMARY_WRITE_OK=0 ;;
    esac
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$FB_SIZE" ] && [ "$FB_SIZE" != UNKNOWN ] &&
    ! printf 'framebuffer.virtual_size=%s\n' "$FB_SIZE" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$FB_BPP" ] && [ "$FB_BPP" != UNKNOWN ] &&
    ! printf 'framebuffer.bits_per_pixel=%s\n' "$FB_BPP" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -eq 1 ] && [ -n "$APPINFO_SOURCE" ] &&
    ! printf 'appinfo.source=%s\n' "$APPINFO_SOURCE" >> "$SUMMARY_TEMP"
then
    SUMMARY_WRITE_OK=0
fi
if [ "$SUMMARY_WRITE_OK" -ne 1 ] ||
    ! commit_regular_file "$SUMMARY_TEMP" "$OUT/stage1-summary.txt"
then
    record_failure "summary:cannot_write_output"
fi

README_TEMP="$OUT/.README.txt.tmp"
if ! printf '%s\n' \
    "Stage-1 probe collection finished." \
    "Consult STATUS.txt and require both status=COMPLETE and a regular non-symlink COMPLETE marker." \
    "Output was written only to: $OUT" \
    "No raw CAN, NVM/MTD payload, network, MCU, or Roadtop filesystem write was performed." > "$README_TEMP" ||
    ! commit_regular_file "$README_TEMP" "$OUT/README.txt"
then
    record_failure "readme:cannot_write_output"
fi

validate_collection_outputs() {
    for REQUIRED_OUTPUT in \
        uname.txt cpuinfo.txt mtd.txt cmdline.txt mounts.txt \
        input-devices.txt input-nodes.txt applications.txt services.txt \
        framebuffer.txt stage1-summary.txt README.txt
    do
        is_regular_nonsymlink "$OUT/$REQUIRED_OUTPUT" || return 1
    done
    if [ -n "$HASH_MODE" ]; then
        is_regular_nonsymlink "$OUT/usb-handler-candidates.txt" || return 1
        is_regular_nonsymlink "$OUT/usb-handlers.sha256" || return 1
    fi
    return 0
}

status_is_complete() {
    is_regular_nonsymlink "$STATUS_FILE" || return 1
    run_bounded awk -F= '
        $1 == "status" { status = $2; status_count++ }
        $1 == "mandatory_failures" { failures = $2; failure_count++ }
        END {
            if (status_count != 1 || failure_count != 1 ||
                status != "COMPLETE" || failures != "0") exit 1
        }
    ' "$STATUS_FILE" >/dev/null 2>&1
}

if ! validate_collection_outputs; then
    record_failure "required_outputs:missing_non_regular_or_symlink"
fi

if [ "$FAILURES" -ne 0 ] || [ "$REQUIRED_WRITE_FAILED" -ne 0 ] || [ "$ERROR_LOG_FAILED" -ne 0 ]; then
    finish_incomplete
fi

if ! finalize_manifests; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: cannot finalize manifests; output incomplete: $OUT" >&2
    exit 1
fi
if [ "$FAILURES" -ne 0 ] || [ "$REQUIRED_WRITE_FAILED" -ne 0 ] || [ "$ERROR_LOG_FAILED" -ne 0 ] ||
    ! is_regular_nonsymlink "$ERROR_FILE" || ! is_regular_nonsymlink "$OPTIONAL_FILE"
then
    invalidate_complete >/dev/null 2>&1 || true
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: manifest validation failed; output incomplete: $OUT" >&2
    exit 1
fi

if ! write_status COMPLETE || ! status_is_complete; then
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: cannot commit complete status; output incomplete: $OUT" >&2
    exit 1
fi

COMPLETE_TEMP="$OUT/.COMPLETE.tmp"
COMPLETE_FILE="$OUT/COMPLETE"
if [ -e "$COMPLETE_FILE" ] || [ -L "$COMPLETE_FILE" ] ||
    ! validate_collection_outputs ||
    ! is_regular_nonsymlink "$ERROR_FILE" ||
    ! is_regular_nonsymlink "$OPTIONAL_FILE" ||
    ! status_is_complete ||
    ! printf '%s\n' "complete=1" > "$COMPLETE_TEMP" ||
    ! commit_regular_file "$COMPLETE_TEMP" "$COMPLETE_FILE"
then
    invalidate_complete >/dev/null 2>&1 || true
    write_status INCOMPLETE >/dev/null 2>&1 || true
    printf '%s\n' "w176-probe: cannot create validated completion marker; output incomplete: $OUT" >&2
    exit 1
fi

printf '%s\n' "w176-probe: complete: $OUT"
