# Fresh independent Work review — W176 Stage-4B capability metadata preflight v5

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B **metadata-only** capability preflight. Review the exact frozen
implementation below. Do not edit, arm, deploy, physically run or approve it.
Do not review or approve the separate Stage-4B residency installer.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen implementation to review:
`3da1e4820a32940448c926197764e8ebe6646bcb`

Latest independently reviewed NO-GO implementation:
`bf8b87d6164712c8fb1557d67a178e2563f8b1be`

Read `AGENTS.md`, the full implementation diff between those SHAs,
`docs/platform/w176-stage4b-capability-preflight.md`, the candidate README,
`analyze.py`, `test_preflight.py`, both mount guards, the collector and
`test_linux_mounts.sh`. Review the frozen implementation, not this later
documentation-only commit. The production `feature/w176-stage4b` branch
remains separate and NO-GO.

## Latest NO-GO finding to independently reproduce and evaluate

The independent reviewer reported one MEDIUM: checksum-valid, otherwise
coherent captures with `rw,ro\x00` or `rw,\x00` in any one of the three
required option fields still yielded `NVM_MOUNT_PRESENTATION=CONFIRMED` at
`bf8b87d`. The implementing session reproduced all six false positives
against the unchanged frozen analyser before editing it. Independently
reproduce or challenge that baseline, then test the new implementation.

Inspect the explicit option-field parser and raw mount-view parser. A valid
option field must be nonempty, comma-delimited into nonempty visible tokens,
contain no literal controls/DEL/whitespace, have no duplicate tokens, and
have nonempty sides of any `key=value` form. Printable paths, visible
backslash escape text and `key=value` must remain admissible. No malformed
captured text may be stripped, truncated or whitespace-normalised into
positive RW evidence. Check all three views: `/proc/mounts` options,
mountinfo per-mount options and mountinfo superblock options. Each must have
exactly one `rw` token, no `ro`, and a coherent source/type association.
Malformed required evidence is `CONTRADICTORY`, never `CONFIRMED`.

Challenge checksum-valid fixtures with NUL, every ASCII control byte
`0x00`–`0x1f`, DEL, empty/duplicate comma tokens, empty field, tab, carriage
return, malformed key/value, duplicate `rw`, duplicate `ro`, and any `rw`/`ro`
conflict in each option field. Confirm ordinary positive forms (`rw`,
`rw,noatime`, `rw,relatime`, `rw,foo=bar`) remain eligible when all other
installed-evidence fields agree. Inspect the fixtures to prove each mutation
reaches the analyser's consumed capture file and that its hash inventory is
recomputed; do not accept a pass caused only by invalid checksums or a
different missing association.

## Regression and safety boundary

Recheck the previously closed findings: effective USB stacked-root and deeper
covering mount rejection; complete bounded mount snapshots and later-record
short reads; LIMIT+1, producer failure and kallsyms incomplete-line handling;
MTD type and MTD/sysfs association; ordinary cross-view RW/RO contradiction;
libc provenance and ELF header/version/ET_DYN/program-header/entry mapping,
Thumb, BSS, undefined/hidden-symbol controls; transaction false-COMPLETE;
path/symlink containment; exact checksums and inventory. No payload writer,
mount guard or ELF parser changed in this remediation. Native mount fixtures
exercise a disposable Linux/FAT container, not the RoadTop.

Independently recompute unchanged logical bounds: final schema 2,287,680
bytes; largest individual temporary 1,052,672 bytes; conservative
final-plus-temporaries 3,354,752 bytes; final acceptance 3072 KiB.
`output_write_ceiling=NOT_CLAIMED` is not a physical FAT write bound.

The implementing session reports 63/63 preflight tests (60 baseline plus
three new methods), 83/83 historical Stage-4A tests, native valid FAT PASS,
exact-root stacked tmpfs REJECT, deeper covering tmpfs REJECT, and short-read
fixtures PASS against the frozen SHA. It also reports `sh -n`, `dash -n`,
Python compilation, whitespace and tracked-content audits passing.
Independently rerun or challenge those claims. Host fixtures are not physical
RoadTop evidence.

Return findings as CRITICAL/HIGH/MEDIUM/LOW/INFO with exact file/line evidence.
State READY FOR FRESH PHYSICAL REVIEW or NO-GO for this **metadata-only**
capture, but do **not** grant physical GO. The analyser must retain:

`SEALED_RUNTIME_EXECUTION=NOT_TESTED`

`EXECUTION_HIGH=OPEN`

No target ARM execution, memfd/sealing/execveat runtime experiment, NVM
write, remount, CAN/MCU/UART access, networking or stock-file change occurred
or is authorised here. Metadata cannot prove the installed RoadTop completes
the later seal-verify-execute sequence. Stage-4B residency remains NO-GO.
