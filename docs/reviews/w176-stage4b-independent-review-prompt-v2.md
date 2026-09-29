# Independent Work safety review — W176 Stage-4B v2 residency candidate

Perform a **FRESH, READ-ONLY, INDEPENDENT** safety review of the GeminiTop
Mercedes-Benz W176 / NTG5*1 Stage-4B first persistent-residency candidate.
Do not rely on the implementing Codex session's PASS claims. Work from source,
reproduce the tests where practical, invent adversarial cases, and give a
physical-test verdict for the exact frozen implementation below.

Repository: https://github.com/danoev/GeminiTop

Branch: `feature/w176-stage4b`

**Frozen implementation commit:**
`052332973c1e28566395483b52ba11eda72db772`

**Exact inert ARMHF daemon:** 5,556 bytes, SHA-256
`684afd86a067a6e175ed6b7d6c2a0281f1d44c67f62d86431589d1d7bd8c41b8`.

The separately pushed `8e8e136cf414f09deed51a8a697001e3eb4e2edd`
was a **NO-GO host-only progress checkpoint**. Historical candidate
`3a920c87cfca71cb845fc75c9c868f99d621ef59` remains NO-GO and must not
be mistaken for the frozen v2 candidate. Review this exact SHA without
amending it. A later documentation-only prompt commit is not part of the
implementation.

## Non-negotiable safety boundary

Do not interact with the vehicle or RoadTop. Do not create a real arming
marker, install to NVM, execute or emulate any ARMHF target binary, send CAN
or MCU commands, open serial/device streams, flash firmware, or change stock
files. Host-native stand-ins, static ELF inspection, and disposable Linux
mount/filesystem fixtures are permitted. Do not treat a host PASS, reference
firmware fact, or operator-returned report as a new physical observation.

The proposed target writes, if separately approved later, must be limited to
`/media/flash/nvm/geminitop/w176/geminitop-proofd` and `manifest.txt`, with
private staging under `/media/flash/nvm/geminitop/`. No stock `Launcher`, init,
`nvm/bin`, `nvm/lib`, PATH/library shadowing, networking, boot persistence,
CAN/MCU/UART, or firmware modification is in scope.

## Evidence to verify rather than assume

Read `AGENTS.md`, the frozen diff, `docs/platform/w176-stage4b-nvm-mount-source.md`,
`docs/platform/w176-stage4b-fresh-safety-audit.md`,
`docs/platform/w176-stage4b-remediation-status.md`, and
`docs/platform/w176-stage4b-v2-matrix-status.md`. Operator-returned Stage-1
evidence says `/dev/mtdblock12 /tmp/sp/media/flash/nvm yaffs2 rw,noatime`
and `mtd12` is the 8 MiB `nvm` partition. Stage-2 evidence says `/media` is
a symlink to `/tmp/sp/media/`. The exact installed vendor kernel's block
sysfs and mountinfo presentation is **UNKNOWN**; the installer must stop
before its first NVM write if that binding cannot be proved.

Independently reproduce the static ABI audit. Rebuild twice in clean Linux/arm64
environments using the pinned official Arm GNU A-profile 9.2-2019.12
AArch64-hosted `arm-none-linux-gnueabihf` toolchain and compare exact bytes.
Check ELF class, ARMv7-A EABI5 hard-float attributes, interpreter
`/lib/ld-linux-armhf.so.3`, one NEEDED `libc.so.6`, `GLIBC_2.4` ceiling,
all undefined imports, RELRO, non-executable stack, and absence of RPATH/
RUNPATH or unexpected device/network/stock-program strings. Do **not** run
the target binary.

## Re-open all seven original HIGH classes

1. **First-write NVM identity:** trace mount source to the exact block node,
   block major/minor, sysfs object, `mtd12` name/size, YAFFS2 RW root, logical
   `/media` symlink, effective deepest mount for every created/renamed child,
   and free space. Try nested tmpfs, RO ext4, same-fstype nested mounts,
   external and same-device bind mounts, sibling mounts, malformed/duplicate
   mount records, symlinks, wrong source, wrong MTD, and wrong sysfs object.
   Prove fail-closed behavior *before* the first persistent write.
2. **Masked producers:** inject plausible output followed by nonzero exit for
   SHA-256, kernel release, `df`, mount/stat/sysfs reads, and late output
   checks. Verify exact parsing and command-status handling.
3. **Process and USB-FD proof:** test PID/TGID/start/exe identity, zombies,
   unknown state, duplicate installed-executable runs, process/FD appearance
   and disappearance, readlink failure, target replacement, unstable scans,
   unavailable FD directory, and USB FD reacquisition after reinsertion.
   Confirm descriptors above 127 are `NOT_INSPECTED` and force an UNKNOWN/
   incomplete result rather than a false detached claim.
4. **Install rollback:** after any staging, committed-copy, launch, identity,
   heartbeat, source-copy, or USB-result failure, prove no automatic NVM
   deletion can remove a potentially running destination binary. Check the
   one-descriptor source-copy race and both staged/final destination hashes.
5. **Uninstall process coverage:** require a complete exact live-leader scan,
   immediate final PID/TGID/start/exe revalidation before TERM, deterministic
   PID reuse and zombie at that boundary, ignored TERM, identity change during
   the bounded wait, and no SIGKILL. Uninspectable live processes must not be
   confused with absence.
6. **Heartbeat ownership:** check the seven-key v2 schema, exact PID and
   kernel start ticks, build/run collisions, malformed/duplicate/extra keys,
   stale sequence, disappearance, mutation after TERM, and replacement
   between ownership parse and first NVM delete. The volatile heartbeat must
   not need deletion for safe persistent-file cleanup.
7. **Partial-state recovery:** inspect all interrupted creation, rename,
   launch, verify, TERM, and uninstall states. For each, decide whether a
   fresh install, verify, uninstall, replay, or automatic deletion is allowed
   and whether manual review is required. No retained lock or incomplete
   USB result may silently replay; no unexpected file/dir/symlink may be
   removed. Confirm first-delete partial uninstall stops without a second
   destructive attempt or parent cleanup.

## Required host checks

Run and challenge `tools/w176-stage4-residency/run_matrix.sh`. Inspect its
`matrix.psv` and `recovery_states.psv` row by row; do not accept a count alone.
The implementing run claimed `REQUIRED_MATRIX=88 PASS=88 FAIL=0 SKIP=0
PARTIAL=0` and `RECOVERY_STATES=20 PASS=20 FAIL=0 SKIP=0 PARTIAL=0` from 120
Linux residency cases, 18 process/FD cases, 10 privileged real-mount cases,
and 7 privileged block-metadata cases. Confirm each mapped marker actually
tests its claim. In particular, scrutinize the shared state-I/J marker and
the test-only YAFFS2-to-tmpfs substitution used solely for real mount
semantics. Run `test_matrix_verifiers.py` and mutate logs to prove missing,
duplicate, FAIL, SKIP, PARTIAL, XFAIL, and NOT RUN markers cannot pass.

Independently inject late failures into **each** install, verify, and uninstall
USB result transaction: initial and final STATUS, evidence and manifest
hashes, checksum commit, required-file validation, COMPLETE temp creation,
COMPLETE hash, and COMPLETE rename. Prove COMPLETE is last, canonical, and
absent on failure. Verify persistent state is left for manual review after
late install/uninstall uncertainty. Exercise a disposable second-USB fixture
against retained partial NVM and all three one-shot locks/consumed markers.

Run the historical Stage-1, Stage-2, Stage-3, Stage-4A, target-identification,
and firmware-inspector regressions, plus Stage-3 FAT RO/RW and 50-pair lock
tests and Stage-4A native process/mount tests. Use native Linux for kernel
semantics; a macOS skip or timeout is not a substitute. Run `sh -n`, `dash -n`,
Python compilation, JSON parsing, `git diff --check`, and tracked/staged
content audits. Confirm there is no real arming marker or proprietary raw
firmware/NVM content in the candidate.

## Required response

Report the checked commit and binary hash; exact tests and totals; evidence
classes (`CONFIRMED`, `REFERENCE ONLY`, `INFERENCE`, `UNKNOWN`); each original
HIGH finding's current disposition; any new CRITICAL/HIGH/MEDIUM/LOW/INFO
findings with file/line and reproduction; the 88-row and 20-state results;
the three USB transaction-fault results; unresolved physical presentation
unknowns; and whether stock files, networking, CAN/MCU, boot hooks, or NVM
`bin`/`lib` would be touched. A physical test must not proceed with an
unresolved HIGH or CRITICAL finding on its path.

End with **exactly one** of these verdicts for the frozen implementation:

```text
PHYSICAL STAGE-4B RESIDENCY PROOF:
GO
```

or

```text
PHYSICAL STAGE-4B RESIDENCY PROOF:
NO-GO
```

This independent verdict is a review recommendation only. It does not itself
create an arming marker or authorise physical action; the operator retains
that separate decision.
