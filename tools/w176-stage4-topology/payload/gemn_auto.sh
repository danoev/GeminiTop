#!/bin/sh
# Stock USB entrypoint for the separately armed Stage-4A topology capture.

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
cd -P "$SCRIPT_DIR" 2>/dev/null || exit 1
ANCHOR=$(pwd -P 2>/dev/null) || exit 1
GUARD=./mount_guard.sh
STAGE=./stage4_topology.sh
for FILE in "$GUARD" "$STAGE"; do [ -f "$FILE" ] && [ ! -L "$FILE" ] || exit 1; done
USB_ROOT=$(/bin/sh "$GUARD" .) || exit 1
[ "$USB_ROOT" = "$ANCHOR" ] || exit 1
exec /bin/sh "$STAGE" .
