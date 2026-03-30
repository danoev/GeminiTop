#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "${1:-}" = "clean" ]; then
    exit 0
fi

if [ ! -f build/win31-launcher ]; then
    bash ../dosboxx/build_launchers.sh
fi
