# Fresh independent Work review — W176 Stage-4B capability metadata preflight v2

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the remediated
GeminiTop W176 Stage-4B metadata-only capability preflight. Do not edit,
arm, deploy or run the payload. Do not review or approve the separate
Stage-4B residency installer as part of this request.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen remediated probe implementation:
`d5a608a1dadb94e1c50daeca0c72a6d765e4b991`

Previously reviewed NO-GO implementation:
`0f65de871a5d45623989b1c6f3e19028ab9fdf2a`

Prior branch review brief: `d693ed15e724fbe09422761e1e360e5850c0c869`

Production Stage-4B remains separately at `feature/w176-stage4b` and is
NO-GO. No physical capture, live arming marker, NVM write, custom ARM code,
memfd/sealing/exec experiment, CAN/MCU/UART access, networking or vehicle
interaction occurred in the remediation.

At the frozen implementation commit, inspect the complete diff and these
files, plus repo `AGENTS.md`:

- `docs/platform/w176-stage4b-capability-preflight.md`
- `tools/w176-stage4b-capability-probe/README.md`
- `tools/w176-stage4b-capability-probe/payload/gemn_auto.sh`
- `tools/w176-stage4b-capability-probe/payload/mount_guard.sh`
- `tools/w176-stage4b-capability-probe/payload/root_mount_guard.sh`
- `tools/w176-stage4b-capability-probe/payload/capability_probe.sh`
- `tools/w176-stage4b-capability-probe/analyze.py`
- `tools/w176-stage4b-capability-probe/test_preflight.py`
- `tools/w176-stage4b-capability-probe/test_linux_mounts.sh`

The independent NO-GO reported one HIGH and four MEDIUM findings. Reproduce
or independently assess every closure with exact file/line evidence:

1. HIGH: a removable FAT record existed below a different effective mount.
   Confirm that bounded `/proc/mounts` and `/proc/self/mountinfo` snapshots,
   duplicate/deeper mount rejection, source and filesystem cross-checks,
   output-root `st_dev`/mountinfo major:minor, and block-node rdev all agree
   BEFORE lock creation, marker unlink or any output write. Scrutinise mount
   races, bind mounts, symlinked roots, malformed or inconsistent views and
   whether any failure can fall back to internal storage. The original
   stacked-mount regression failed against `0f65de8` and now passes.
2. MEDIUM: NVM mount presentation was over-classified. Test coherent,
   partial, contradictory and absent evidence across `/media`, canonical
   NVM mount, YAFFS2/RW source, mountinfo major:minor, `/dev/mtdblock12`,
   `/proc/mtd`, `/sys/dev/block`, `/sys/class/block/mtdblock12`, and mtd12
   name/size/dev/erase attributes. No missing or contradictory association
   may yield CONFIRMED. Check host-independent Linux dev_t decoding.
3. MEDIUM: undefined libc imports were called observed wrappers. Check
   ELF32 ARM bounds, dynamic symbol definition, binding, type, visibility,
   and one-hop `/lib/libc.so.6` provenance to the copied regular libc.
   Missing/out-of-scope/unparseable provenance must yield UNKNOWN, and
   NOT_OBSERVED must not mean kernel syscall unavailable.
4. MEDIUM: a truncated `kallsyms` line became a false positive. Check the
   512-KiB limit plus one-block read, complete-line detection, removal of
   partial final records, bounded symbol output, producer status and
   explicit truncation/UNKNOWN treatment. Absence in a prefix is no proof.
5. MEDIUM: USB mount scan was unbounded. Verify read byte ceilings,
   limit+oversize behavior, record-count and line-length limits, and a
   producer that emits plausible data but exits nonzero. Both mount views
   must fail closed before the first mutation.

Inspect the exact transaction order, output inventory/checksums, false
COMPLETE prevention, symlink/path escape checks, and optional evidence
handling. Recompute final schema maximum (2,287,680 logical bytes), maximum
individual temporary file (1,052,672 bytes), and the conservative
final-plus-temporaries sum (under 3,355,000 logical bytes). The 3072-KiB
final acceptance check is NOT a peak physical FAT-write ceiling;
`output_write_ceiling=NOT_CLAIMED` must remain honest.

Host evidence at the frozen implementation commit: 43 preflight fixture
tests passed; `sh -n`, `dash -n` and Python compilation passed; a disposable
native Linux FAT mount passed, while tmpfs stacked at the exact USB root or
at a deeper child was rejected. The historical Stage-4A suite passed all 83
tests against this frozen implementation commit. Verify these independently
where practical. Never execute target ARM code.

Return findings with CRITICAL/HIGH/MEDIUM/LOW/INFO severity and exact
evidence. State READY FOR FRESH PHYSICAL REVIEW or NO-GO for the
**metadata-only capture**; unresolved HIGH/CRITICAL means NO-GO. Do not
grant physical GO. Explicitly retain:

`SEALED_RUNTIME_EXECUTION=NOT_TESTED`

`EXECUTION_HIGH=OPEN`

Metadata cannot prove the installed RoadTop completes memfd creation,
sealing, write rejection and descriptor execution. Any runtime experiment
requires its own later design, authorisation and independent review.
