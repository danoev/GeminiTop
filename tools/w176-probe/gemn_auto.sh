#!/bin/sh
# Stock firmware USB entrypoint for the reviewed Stage-1 inventory probe.
# This does not launch GeminiTop or replace the stock Launcher.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-probe: USB root not found" >&2
    exit 1
}
GUARD="$SCRIPT_DIR/mount_guard.sh"
STAGE1="$SCRIPT_DIR/stage1_probe.sh"

if [ ! -f "$GUARD" ] || [ -L "$GUARD" ] || [ ! -f "$STAGE1" ] || [ -L "$STAGE1" ]; then
    printf '%s\n' "w176-probe: probe scripts must be regular non-symlink files" >&2
    exit 1
fi

USB_ROOT=$(/bin/sh "$GUARD" "$SCRIPT_DIR") || exit 1
[ "$USB_ROOT" = "$SCRIPT_DIR" ] || {
    printf '%s\n' "w176-probe: validated root mismatch" >&2
    exit 1
}

exec /bin/sh "$STAGE1" "$USB_ROOT"
