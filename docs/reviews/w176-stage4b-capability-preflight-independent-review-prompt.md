# Independent Work review — W176 Stage-4B capability metadata preflight

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B capability metadata preflight candidate. Do not edit, arm, run, or
deploy it. Do not review the uncommitted production Stage-4B remediation as
though it were part of this candidate.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Frozen implementation commit: `0f65de871a5d45623989b1c6f3e19028ab9fdf2a`

Base: `a5034afef4a258813c202e72904cce2f70abee2e`

Stage-4B residency remains NO-GO. This candidate only gathers bounded
installed-target metadata, using stock shell/userspace commands, to reduce
UNKNOWNs about kernel identity, config/symbol evidence, libc wrappers and
NVM mount presentation. It cannot close the same-inode mutation HIGH or
prove sealed descriptor execution. It has never run on the RoadTop. The
payload contains only an inert example arming marker; do not create a live
marker.

Review these exact files at the frozen implementation commit:

- `docs/platform/w176-stage4b-capability-preflight.md`
- `tools/w176-stage4b-capability-probe/README.md`
- `tools/w176-stage4b-capability-probe/analyze.py`
- `tools/w176-stage4b-capability-probe/payload/ARM_STAGE4B_CAPABILITY_PREFLIGHT.example`
- `tools/w176-stage4b-capability-probe/payload/capability_probe.sh`
- `tools/w176-stage4b-capability-probe/payload/gemn_auto.sh`
- `tools/w176-stage4b-capability-probe/payload/mount_guard.sh`
- `tools/w176-stage4b-capability-probe/payload/root_mount_guard.sh`
- `tools/w176-stage4b-capability-probe/test_preflight.py`

Use the repo's `AGENTS.md`, prior Stage-4A transaction safety model, and
`docs/platform/w176-stage4b-architecture-feasibility.md` as context. The
last independently reviewed production Stage-4B implementation was
`052332973c1e28566395483b52ba11eda72db772`; it is not newly approved
by this metadata work.

Audit, with exact file/line evidence:

1. The complete physical path from USB entrypoint through guard, one-shot
   lock/marker consumption, fresh atomic output, INCOMPLETE/COMPLETE
   ordering, checksum manifest and exact inventory. Verify no false COMPLETE
   or internal-storage fallback on any failure.
2. Every source path, path traversal/symlink, pre-read type/provenance check,
   per-source read ceiling, aggregate output ceiling, producer exit status,
   and failure mode. Check the RO SquashFS guard for optional `/lib` and
   `/boot` copies. Check that no device stream, target library, or ARM binary
   is executed or emulated.
3. Whether the collector makes any NVM/MTD write, remount, stock-file or
   process change, networking change, CAN/MCU/UART access, or memfd/sealing/
   descriptor-exec syscall experiment. These are prohibited.
4. Whether missing/unreadable/truncated/ambiguous optional data remains
   UNKNOWN. In particular, absence from a bounded kallsyms prefix or lack
   of a libc wrapper cannot prove kernel syscall absence.
5. The host analyser's exact schema, checksum, inventory, size, duplicate,
   path containment, and symlink checks. Probe malformed or adversarial
   results, including a forged COMPLETE marker, and verify that it never
   outputs `SEALED_RUNTIME_EXECUTION=CONFIRMED`.
6. Whether ELF wrapper inspection is static, bounded, structurally sound,
   and limited to the copied installed libc. Assess the inference threshold
   for `SUPPORTED_BY_METADATA` and the mount-presentation classification.
7. Host test coverage and reproducibility. Run shell syntax/static tests,
   the disposable preflight fixtures and relevant Stage-4A regressions if
   available, without executing target ARM code.

Use `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `INFO` severity. State exactly what
each source can and cannot prove using CONFIRMED / REFERENCE ONLY / INFERENCE /
UNKNOWN. Give a clear recommendation for **independent approval of a later
metadata-only physical capture**: READY FOR PHYSICAL REVIEW or NO-GO. Do not
grant physical GO yourself. An unresolved HIGH or CRITICAL on the capture
path means NO-GO.

Explicitly answer: Can this stock-shell metadata-only capture close the
remaining Stage-4B sealed-execution HIGH? The expected evidence boundary is
that actual memfd creation, sealing, rejected writes and descriptor execution
would still require a separately reviewed runtime experiment. Do not design
or implement that experiment in this review.
