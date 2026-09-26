#!/bin/sh
# Stock USB entrypoint for the separately armed inert ARM loadability probe.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || {
    printf '%s\n' "w176-stage3: USB root not found" >&2
    exit 1
}
cd -P "$SCRIPT_DIR" 2>/dev/null || {
    printf '%s\n' "w176-stage3: cannot anchor USB root" >&2
    exit 1
}
ANCHOR_DISPLAY=$(pwd -P 2>/dev/null) || exit 1
GUARD=./mount_guard.sh
STAGE3=./stage3_arm_probe.sh
BINARY=./arm_probe
ARM_MARKER=./ARM_STAGE3_ARM_EXECUTION_PROBE

for PAYLOAD_FILE in "$GUARD" "$STAGE3" "$BINARY"; do
    if [ ! -f "$PAYLOAD_FILE" ] || [ -L "$PAYLOAD_FILE" ]; then
        printf '%s\n' "w176-stage3: payload files must be regular non-symlinks" >&2
        exit 1
    fi
done
USB_ROOT=$(/bin/sh "$GUARD" .) || exit 1
[ "$USB_ROOT" = "$ANCHOR_DISPLAY" ] || {
    printf '%s\n' "w176-stage3: validated root mismatch" >&2
    exit 1
}
if [ ! -f "$ARM_MARKER" ] || [ -L "$ARM_MARKER" ]; then
    printf '%s\n' "w176-stage3: not armed; reviewed marker is absent or invalid" >&2
    exit 1
fi

exec /bin/sh "$STAGE3" .
