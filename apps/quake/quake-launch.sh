#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/../quake-data"

export HOME="$BASE_DIR"
mkdir -p "$BASE_DIR/id1" "$BASE_DIR/qw" \
         "$HOME/.tyrquake/id1" "$HOME/.tyrquake/qw"

exec "$BASE_DIR/bin/tyr-quake" \
    -basedir "$BASE_DIR" \
    -heapsize 32768 \
    -nocdaudio \
    -sndmono \
    -sndspeed 22050 \
    "$@"

