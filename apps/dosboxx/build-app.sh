#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "${1:-}" = "clean" ]; then
    bash build_dosboxx.sh clean
    bash build_launchers.sh clean
    exit 0
fi

bash build_dosboxx.sh
bash build_launchers.sh
