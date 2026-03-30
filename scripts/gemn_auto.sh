#!/bin/sh
# gemn_auto.sh — firmware entrypoint, hands off to the native orchestrator.

USB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -z "$USB" ] && USB="$(df 2>/dev/null | awk '/\/dev\/sd/ { print $6; exit }')"

if [ -z "$USB" ] || [ ! -d "$USB" ]; then
    echo "gemn_auto: usb root not found" >&2
    exit 1
fi

ORCH="$USB/geminiorchestrator"
chmod +x "$ORCH" 2>/dev/null

if [ ! -f "$ORCH" ]; then
    echo "gemn_auto: missing orchestrator at $ORCH" >&2
    exit 1
fi

exec "$ORCH" --usb "$USB"
