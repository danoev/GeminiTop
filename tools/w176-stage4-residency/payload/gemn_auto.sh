#!/bin/sh
set -u

CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x')
IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

ROOT=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
cd -P "$ROOT" 2>/dev/null || exit 1
COUNT=0
ACTION=
for ENTRY in \
    "ARM_STAGE4B_INSTALL:install.sh" \
    "ARM_STAGE4B_VERIFY_AFTER_REMOVAL:verify_after_removal.sh" \
    "ARM_STAGE4B_UNINSTALL:uninstall.sh"
do
    MARKER=${ENTRY%%:*}; SCRIPT=${ENTRY#*:}
    if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then COUNT=$((COUNT + 1)); ACTION=$SCRIPT; fi
done
[ "$COUNT" -eq 1 ] || exit 1
for REQUIRED in mount_guard.sh common.sh "$ACTION"; do [ -f "$REQUIRED" ] && [ ! -L "$REQUIRED" ] || exit 1; done
exec /bin/sh "$ACTION" .
