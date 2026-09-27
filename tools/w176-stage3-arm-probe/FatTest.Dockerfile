FROM debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

RUN apt-get update \
    && apt-get install -y --no-install-recommends dosfstools=4.2-1 \
    && rm -rf /var/lib/apt/lists/*

COPY test_fat_ro_window.sh /test_fat_ro_window.sh
COPY test_fat_lock_concurrency.sh /test_fat_lock_concurrency.sh

CMD ["/bin/sh", "-c", "/bin/sh /test_fat_ro_window.sh && /bin/sh /test_fat_lock_concurrency.sh"]
