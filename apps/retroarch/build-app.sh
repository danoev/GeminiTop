#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "${1:-}" = "clean" ]; then
    rm -rf build
    exit 0
fi

bash build_retroarch.sh
bash build_cores.sh
