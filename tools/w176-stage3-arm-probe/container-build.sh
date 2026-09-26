#!/bin/sh
set -eu

[ "$#" -eq 1 ] || exit 2

arm-none-linux-gnueabihf-gcc \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -fno-ident \
    -fno-asynchronous-unwind-tables \
    -fno-unwind-tables \
    -fno-pie \
    -march=armv7-a \
    -mfpu=neon \
    -mfloat-abi=hard \
    -mthumb \
    -no-pie \
    -Wl,--build-id=none \
    -Wl,--as-needed \
    -Wl,--hash-style=both \
    -Wl,-z,relro \
    -Wl,-z,now \
    -o "$1" \
    /src/probe.c

arm-none-linux-gnueabihf-strip --strip-all "$1"
