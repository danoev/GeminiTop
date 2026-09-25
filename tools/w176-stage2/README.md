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

Only the differently named `.example` marker is tracked; its scope line is a
human-readable review aid and is not opened by the target entrypoint. Do not
create or rename the real marker
until an independent review explicitly returns `PHYSICAL STAGE-2 PLATFORM
CAPTURE: GO` and the owner separately authorises that physical action.

Valid output is a fresh `stage2-platform[-N]` directory with `STATUS.txt`
showing `status=COMPLETE` and `mandatory_failures=0`, plus a regular non-symlink
`COMPLETE` marker. The marker is committed last. Any mandatory failure leaves
an incomplete directory and no completion marker.
