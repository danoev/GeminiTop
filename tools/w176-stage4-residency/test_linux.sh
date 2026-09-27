#!/bin/sh
set -eu

CDPATH=
export CDPATH
SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd -P)
IMAGE=debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

exec docker run --rm --platform linux/arm64 \
    --mount "type=bind,src=$SCRIPT_DIR,dst=/src,readonly" \
    "$IMAGE" /bin/sh /src/test_linux_residency.sh
