#!/bin/sh
# Stock USB entrypoint for the separately armed W176 Stage-2 platform capture.
# This does not launch GeminiTop, alter services, or replace the stock Launcher.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-stage2: USB root not found" >&2
    exit 1
}
GUARD="$SCRIPT_DIR/mount_guard.sh"
STAGE2="$SCRIPT_DIR/stage2_platform_capture.sh"
ARM_MARKER="$SCRIPT_DIR/ARM_STAGE2_PLATFORM_CAPTURE"

if [ ! -f "$GUARD" ] || [ -L "$GUARD" ] || [ ! -f "$STAGE2" ] || [ -L "$STAGE2" ]; then
    printf '%s\n' "w176-stage2: payload scripts must be regular non-symlink files" >&2
    exit 1
fi
USB_ROOT=$(/bin/sh "$GUARD" "$SCRIPT_DIR") || exit 1
[ "$USB_ROOT" = "$SCRIPT_DIR" ] || {
    printf '%s\n' "w176-stage2: validated root mismatch" >&2
    exit 1
}
if [ ! -f "$ARM_MARKER" ] || [ -L "$ARM_MARKER" ]; then
    printf '%s\n' "w176-stage2: not armed; reviewed marker is absent or invalid" >&2
    exit 1
fi

exec /bin/sh "$STAGE2" "$USB_ROOT"
