FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV CROSS_PREFIX=arm-linux-gnueabihf

RUN dpkg --add-architecture armhf \
    && apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bc \
    binutils-arm-linux-gnueabihf \
    build-essential \
    bzip2 \
    ca-certificates \
    cpio \
    curl \
    file \
    flex \
    g++-arm-linux-gnueabihf \
    gcc-arm-linux-gnueabihf \
    gawk \
    git \
    libcrypt-dev:armhf \
    make \
    ncurses-bin \
    patch \
    perl \
    python3 \
    rsync \
    unzip \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
