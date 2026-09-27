FROM debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

COPY toolchain/ /opt/toolchain/

ENV TOOLCHAIN_ROOT=/opt/toolchain/gcc-arm-9.2-2019.12-aarch64-arm-none-linux-gnueabihf
ENV PATH=${TOOLCHAIN_ROOT}/bin:${PATH}

WORKDIR /src
