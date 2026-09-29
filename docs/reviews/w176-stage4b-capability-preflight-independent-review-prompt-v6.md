# Fresh independent Work review — W176 Stage-4B capability metadata preflight v6

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B **metadata-only** capability preflight. Review the exact frozen
implementation below. Do not edit, arm, deploy, physically run or approve it.
Do not review or approve the separate Stage-4B residency installer.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen implementation to review:
`465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed`

Latest independently reviewed NO-GO implementation:
`3da1e4820a32940448c926197764e8ebe6646bcb`

Read `AGENTS.md`, the full implementation diff between those SHAs,
`docs/platform/w176-stage4b-capability-preflight.md`, the candidate README,
`analyze.py`, `test_preflight.py`, both mount guards, the collector and
`test_linux_mounts.sh`. Review the frozen implementation, not this later
documentation-only commit. The production `feature/w176-stage4b` branch
remains separate and NO-GO.

## Latest NO-GO finding to independently reproduce and evaluate

The independent reviewer reported one MEDIUM: four checksum-valid, otherwise
coherent captures with `bad` in mountinfo mount ID, mountinfo parent ID,
`/proc/mounts` dump/freq, or `/proc/mounts` pass still yielded
`NVM_MOUNT_PRESENTATION=CONFIRMED` at `3da1e48`. The implementing session
reproduced all four false positives against the unchanged analyser before
editing it. Independently reproduce or challenge that baseline, then test
the new implementation. The previous mount-option/control-byte MEDIUM was
reported closed by the latest independent review; confirm it remains closed.

Inspect the new separation between complete raw-record structural validation
and NVM semantic reconciliation. For `/proc/mounts`, check exactly six fields:
source, mountpoint, filesystem, validated options, ASCII-decimal dump and pass.
For mountinfo, check ASCII-decimal mount/parent IDs, decimal `major:minor`,
root, mountpoint, per-mount options, zero or more structurally valid unknown
`tag[:value]` optional fields, the separator in its required position,
filesystem, source and superblock options. Zero IDs are syntactically accepted
without claiming they were observed on the installed unit. Challenge missing,
extra, empty, signed, junk-suffixed and duplicate-separator fields. Check
that unknown optional tags are not needlessly whitelisted.

All textual fields must remain raw: no stripping, truncation, whitespace
normalisation or escape decoding. A literal backslash must introduce three
octal digits; valid visible escaped paths and sources remain admissible.
Check that malformed escapes and literal controls cannot be ignored, including
in an unrelated record preceding an otherwise coherent NVM record. A malformed
record in either required captured view is `CONTRADICTORY` before selected
fields can support `CONFIRMED`. Duplicate/ambiguous NVM candidates must remain
fail-closed. Independently inspect whether this conservative whole-view rule
could reject real Linux output, and label upstream kernel syntax REFERENCE ONLY
for the installed vendor build.

Challenge the checksum-valid fixture matrix: 58 malformed structural record
cases, 264 control-byte injections (`0x00`–`0x1f` and DEL in eight textual
positions), nine positive structural cases, and the four explicit original
false-positive reproductions. Ensure each mutation reaches the consumed raw
capture and has its checksum inventory recomputed. Do not count a rejection
caused only by a bad checksum or unrelated missing association as proof of
the intended grammar check. Repeat representative valid forms including
`rw`, `rw,noatime`, `rw,relatime`, `rw,foo=bar`, visible backslash option text,
multiple unknown optional tags and escaped paths.

## Regression and safety boundary

Recheck the previously closed findings: effective USB mount proof and
root-stacked/deeper covering mounts; complete bounded snapshots, LIMIT+1,
producer failure and later-record short reads; kallsyms incomplete line;
MTD type/sysfs association; exact RW/RO across all three option fields;
libc provenance and ELF version, ARM ET_DYN, bounded program/dynamic tables,
executable file-backed entry mapping, Thumb bit, BSS/out-of-range/hidden or
undefined symbol rejection; transaction false-COMPLETE; path/symlink
containment; exact checksums and inventory. No collector, mount guard, ELF
parser or target payload changed in this remediation.

Independently recompute unchanged logical bounds: final schema 2,287,680
bytes; largest individual temporary 1,052,672 bytes; conservative
final-plus-temporaries 3,354,752 bytes; final acceptance 3072 KiB.
`output_write_ceiling=NOT_CLAIMED` is not a physical FAT write bound.

The implementing session reports 67/67 preflight tests (63 baseline plus
four new test methods), 83/83 historical Stage-4A tests, native valid FAT
PASS, exact-root stacked tmpfs REJECT, deeper covering tmpfs REJECT, and
native FIFO later-unsafe-record/short-read fixtures PASS against the frozen
SHA. It also reports `sh -n`, `dash -n`, Python compilation, whitespace and
tracked-content audits passing. Independently rerun or challenge those
claims. Host fixtures are not physical RoadTop evidence.

Return findings as CRITICAL/HIGH/MEDIUM/LOW/INFO with exact file/line evidence.
State READY FOR FRESH PHYSICAL REVIEW or NO-GO for this **metadata-only**
capture, but do **not** grant physical GO. The analyser must retain:

`SEALED_RUNTIME_EXECUTION=NOT_TESTED`

`EXECUTION_HIGH=OPEN`

No target ARM execution, memfd/sealing/execveat runtime experiment, NVM
write, remount, CAN/MCU/UART access, networking or stock-file change occurred
or is authorised here. Metadata cannot prove the installed RoadTop completes
the later seal-verify-execute sequence. Stage-4B residency remains NO-GO.
