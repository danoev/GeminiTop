# Fresh independent Work review — W176 Stage-4B capability metadata preflight v3

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B **metadata-only** capability preflight. Do not arm, prepare a USB,
deploy, physically run, or modify it. Do not review or approve the separate
Stage-4B residency installer. No vehicle or RoadTop action is authorised.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen implementation to review:
`d7fc83ab0e7e47d76fa0da0efaa343c6cbf267b3`

Previous second NO-GO frozen implementation:
`d5a608a1dadb94e1c50daeca0c72a6d765e4b991`

Earlier frozen implementation:
`0f65de871a5d45623989b1c6f3e19028ab9fdf2a`

Read `AGENTS.md`, the complete frozen diff, `docs/platform/w176-stage4b-capability-preflight.md`,
`tools/w176-stage4b-capability-probe/README.md`, both guard scripts, the
collector, analyser, `test_preflight.py`, and `test_linux_mounts.sh`. Review
the exact frozen implementation, not the later documentation-only commit.
The production `feature/w176-stage4b` branch remains separate and NO-GO.

## Required independent finding checks

1. HIGH — bounded mount snapshots were incomplete under short successful
   reads. Recreate the old `bs=4096 count=17/33` later-overmount bypass on a
   disposable Linux fixture, then verify that `bs=1 count=LIMIT+1` reaches
   EOF within each limit or rejects oversize. Inspect both `/proc/mounts` and
   `/proc/self/mountinfo`, exact-limit, LIMIT+1, short reads, later unsafe
   mount, incomplete final line, producer nonzero, line/record bounds,
   malformed and contradictory views. Verify all checks precede the first
   lock/marker/output mutation. Check the associated collector's mount/MTD
   byte-granularity reads too. Establish BusyBox 1.29.3 compatibility without
   assuming optional GNU flags. Review mount-validation-to-first-write TOCTOU:
   complete views and effective identity are at validation time only, not
   immunity to a privileged concurrent remount.
2. MEDIUM — checksum-valid malformed `mtd12-type.txt` previously left
   `NVM_MOUNT_PRESENTATION=CONFIRMED`. Test malformed, other recognized,
   missing and coherent NAND-family type. Audit every captured NVM association
   field: mounts/mountinfo source, path, YAFFS2/RW and major:minor; NVM
   `st_dev`; block node `rdev`; `/media` symlink; `/sys/dev/block` and
   `/sys/class/block` links; `/proc/mtd` mtd12 name/size/erase; and sysfs
   name/size/dev/erase/type. No checksum-valid contradictory capture may
   yield CONFIRMED. Do not promote Linux upstream type strings to an observed
   value on the installed unit.
3. MEDIUM — a provenance-linked ET_REL object previously yielded
   `TARGET_LIBC_WRAPPER_MEMFD_CREATE=OBSERVED`. Test ET_DYN, ET_REL, ET_EXEC,
   malformed program headers/dynamic tags, PT_LOAD/PT_DYNAMIC coverage,
   SONAME, matching bounded dynamic tables, defined/undefined/hidden/missing
   symbols and finite `/lib/libc.so.6` provenance for **memfd_create,
   execveat, fexecve**. Malformed or unproven image/provenance must be UNKNOWN.
   NOT_OBSERVED is not proof of missing kernel syscall support.

Verify the previously closed stacked/deeper mount, kallsyms truncation,
transaction COMPLETE, symlink/containment and output-inventory protections.
Recompute final logical schema maximum 2,287,680 bytes, largest single
temporary 1,052,672 bytes and conservative final-plus-temporaries 3,354,752
bytes. The 3072-KiB final acceptance is not a physical FAT write ceiling;
`output_write_ceiling=NOT_CLAIMED` must remain.

The implementing session reproduced all three latest findings against
`d5a608a`, then reported 53/53 preflight fixtures against the new frozen
commit. Its native Linux FAT fixture passed; stacked tmpfs at the exact USB
root and a deeper child was rejected. Native FIFO fixtures exercise repeated
short reads and later unsafe records. The historical Stage-4A suite passed
83/83 tests. Independently rerun or challenge these claims. Host fixtures do
not establish physical target safety.

Return findings by CRITICAL/HIGH/MEDIUM/LOW/INFO with exact file/line
evidence. State READY FOR FRESH PHYSICAL REVIEW or NO-GO for this metadata-only
preflight; unresolved HIGH/CRITICAL means NO-GO. Do **not** grant physical GO.
The analyser must still report:

`SEALED_RUNTIME_EXECUTION=NOT_TESTED`

`EXECUTION_HIGH=OPEN`

No target ARM code execution, memfd/sealing/execveat runtime experiment, NVM
write, remount, CAN/MCU/UART access, networking or stock-file change is part
of this remediation. Metadata cannot prove the future seal-verify-execute
sequence succeeds on the RoadTop.
