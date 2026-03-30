#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
IMAGE_NAME=${IMAGE_NAME:-gemini-top-dev-builder}

cd "$SCRIPT_DIR"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found in PATH"
    echo "Install Docker Desktop or Docker Engine, then re-run ./docker_build.sh"
    exit 1
fi

docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

USER_ARGS=""
if command -v id >/dev/null 2>&1; then
    USER_ARGS="--user $(id -u):$(id -g)"
fi

TTY_ARGS="-i"
if [ -t 0 ] && [ -t 1 ]; then
    TTY_ARGS="-it"
fi

if [ -n "${JOBS:-}" ]; then
    JOBS_ARG="-e JOBS=$JOBS"
else
    JOBS_ARG=""
fi

docker run --rm $TTY_ARGS \
    $USER_ARGS \
    -e CROSS_PREFIX="${CROSS_PREFIX:-arm-linux-gnueabihf}" \
    $JOBS_ARG \
    -v "$SCRIPT_DIR":/work \
    -w /work \
    "$IMAGE_NAME" \
    ./build.sh "$@"
