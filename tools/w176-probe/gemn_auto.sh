#!/bin/sh
# Stock firmware USB entrypoint for the reviewed Stage-1 inventory probe.
# This does not launch GeminiTop or replace the stock Launcher.

USB_ROOT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$USB_ROOT" ] || [ ! -d "$USB_ROOT" ]; then
    echo "w176-probe: USB root not found" >&2
    exit 1
fi

exec /bin/sh "$USB_ROOT/stage1_probe.sh" "$USB_ROOT"
