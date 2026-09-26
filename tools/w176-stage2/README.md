# W176 Stage-2 platform capture payload

This is a separately armed, read-only-on-target selective platform/ABI capture.
Its purpose is to support the patchability route decision, beginning with the
most reversible USB-loaded option. It is not a
physical-use approval. See `docs/platform/w176-stage2-platform-capture.md` for
the evidence rationale, exact whitelist, limits, and review state.

The stock RoadTop mechanism requires a root-level script named `gemn_auto.sh`.
This entrypoint refuses to collect unless all of these conditions hold:

1. exactly one `/dev/sd*` partition is mounted, marked removable in sysfs, and
   formatted FAT;
2. the script directory is that exact canonical mount root;
3. payload scripts are regular non-symlinks; and
4. a regular non-symlink `ARM_STAGE2_PLATFORM_CAPTURE` is deliberately present.

Both the stock entrypoint and direct capture entry anchor their working
directory inside the prospective USB filesystem before validation. The guard
proves that this already-open directory is the exact removable FAT mount.
Collection then creates and enters a fresh output directory and uses only
relative output paths. If the original mount pathname is detached or rebound
after validation, later writes therefore remain attached to the original
filesystem object or fail; they cannot fall through to the underlying RoadTop
directory.

Only the differently named `.example` marker is tracked; its scope line is a
human-readable review aid and is not opened by the target entrypoint. Do not
create or rename the real marker
until an independent review explicitly returns `PHYSICAL STAGE-2 PLATFORM
CAPTURE: GO` and the owner separately authorises that physical action.

Valid output is a fresh `stage2-platform[-N]` directory with `STATUS.txt`
showing `status=COMPLETE` and `mandatory_failures=0`, plus a regular non-symlink
`COMPLETE` marker. The marker is committed last. Any mandatory failure leaves
an incomplete directory and no completion marker.

Each mandatory source is opened once inside the bounded child, checked through
its open descriptor, and copied for exactly its approved size to a temporary
USB snapshot. COPY items commit that snapshot; HASH items hash it and then
remove it. Final retained capture bytes are capped at 1,048,576, one transient
snapshot at 2,097,152, and total transient USB file bytes at 3,145,728.
