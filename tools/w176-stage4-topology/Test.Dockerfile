FROM debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3=3.11.2-1+b1 squashfs-tools=1:4.5.1-1 \
    && rm -rf /var/lib/apt/lists/*
CMD ["/bin/sh", "-c", "/bin/sh /repo/tools/w176-stage4-topology/test_linux_mounts.sh && python3 -m unittest discover -s /repo/tools/w176-stage4-topology -v"]
