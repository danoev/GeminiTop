# Fresh independent Work review — W176 Stage-4B capability metadata preflight v4

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B **metadata-only** capability preflight. Review the exact frozen
implementation below. Do not edit, arm, deploy, physically run or approve it.
Do not review or approve the separate Stage-4B residency installer.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen implementation to review:
`bf8b87d6164712c8fb1557d67a178e2563f8b1be`

Latest independently reviewed NO-GO implementation:
`d7fc83ab0e7e47d76fa0da0efaa343c6cbf267b3`

Read `AGENTS.md`, the full diff between those SHAs, the current
`docs/platform/w176-stage4b-capability-preflight.md`, the candidate README,
`analyze.py`, `test_preflight.py`, both mount guards, the collector and
`test_linux_mounts.sh`. The production `feature/w176-stage4b` branch remains
separate and NO-GO. Review the frozen implementation, not the later
documentation-only commit.

## Latest NO-GO findings to independently reproduce and evaluate

1. MEDIUM: three checksum-valid, otherwise coherent NVM captures gave
   `NVM_MOUNT_PRESENTATION=CONFIRMED` despite `/proc/mounts` options `rw,ro`,
   mountinfo per-mount options `rw,ro`, or mountinfo superblock options `ro`.
   Confirm exact comma-token parsing of **all three** option fields. Coherent
   RW in every field with no RO may confirm; explicit RO, duplicate/conflicting
   RW/RO, empty/missing/malformed fields, or cross-view contradiction must not.
   Test no NVM record, one missing view, malformed mountinfo separator,
   source/filesystem mismatch and the existing MTD/sysfs association matrix.
   No checksum-valid contradictory evidence may yield CONFIRMED.
2. MEDIUM: EI_VERSION=0 and an exported function `st_value=0xffffffff`
   previously yielded `TARGET_LIBC_WRAPPER_MEMFD_CREATE=OBSERVED`. Verify the
   new static proof for **memfd_create, execveat and fexecve**: ELF32 ARM
   little-endian ET_DYN and current identification/header version; bounded
   aligned non-overlapping PT_LOAD and bounded PT_DYNAMIC; finite one-hop
   libc provenance and SONAME; matching bounded dynamic symbol/string tables;
   defined externally visible function symbol in an executable section; and
   entry address plus stated nonzero size mapping to file-backed bytes of a
   PF_X load segment. Check overflow, outside-segment, non-executable and
   BSS-only values, malformed section/program headers, ET_REL/ET_EXEC,
   undefined/hidden symbols and absent/out-of-scope provenance. A Thumb
   function's low `st_value` bit is an instruction-state indicator and must
   be stripped for the address check; a valid Thumb fixture must remain
   OBSERVED. A zero-size function still needs a mapped entry byte. An
   unproven candidate must be UNKNOWN, not OBSERVED. NOT_OBSERVED does not
   imply the kernel syscall is unsupported. Challenge any fixture that
   passes for a reason other than the intended condition.

Confirm the previously closed HIGH short-read mount snapshot issue remains
closed: complete bounded views at validation time, LIMIT+1 oversize rejection,
native later-unsafe-record short reads, effective FAT identity and stacked
or deeper tmpfs rejection. This is **not** immunity to a privileged actor
remounting after validation. Also recheck kallsyms truncation, MTD type,
transaction false-COMPLETE, path/symlink containment, exact checksums and
inventory. No payload writer or mount guard changed in this remediation.

Independently recompute unchanged logical bounds: final schema 2,287,680
bytes; largest individual temporary 1,052,672 bytes; conservative
final-plus-temporaries 3,354,752 bytes; final acceptance 3072 KiB.
`output_write_ceiling=NOT_CLAIMED` is not a physical FAT write bound.

The implementing session first reproduced all five latest false positives
against `d7fc83a` with checksum-valid synthetic captures. Against the new
frozen implementation it reported 60/60 preflight tests, 83/83 historical
Stage-4A tests, native valid FAT PASS, exact-root and deeper tmpfs REJECT,
and native repeated-short-read/later-unsafe-record fixtures PASS. `sh -n`,
`dash -n`, Python compilation and content/whitespace audits passed.
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
