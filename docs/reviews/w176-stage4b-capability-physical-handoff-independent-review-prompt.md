# Fresh independent Work review — W176 Stage-4B capability physical handoff

Perform a **fresh, read-only, independent physical-handoff safety review** of
one proposed **metadata-only** capability capture on the installed W176
RoadTop. Do not interact with the vehicle, prepare or arm a USB, create the
live marker, run target code, modify the repository, or grant Stage-4B
persistent-residency approval. This review concerns a procedure, not a
physical test.

Repository: https://github.com/danoev/GeminiTop

Dedicated branch: `codex/w176-stage4b-capability-preflight`

Exact frozen implementation previously found READY FOR FRESH PHYSICAL REVIEW
in an independent **host** review:
`465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed`.
That result is **not physical GO**. Review this frozen implementation, not
the moving branch tip. The later handoff commit changes documentation only.
The production `feature/w176-stage4b` branch is separate and remains NO-GO.

Read `AGENTS.md`,
`docs/platform/w176-stage4b-capability-physical-handoff.md`,
`docs/platform/w176-stage4b-capability-preflight.md`, the frozen candidate
README, all four frozen USB scripts, frozen `analyze.py`, and relevant frozen
tests. Recalculate sizes and SHA-256 directly from Git blobs at the frozen
SHA. The proposed USB-root inventory is:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `gemn_auto.sh` | 602 | `3cbe48aed6188606d701c774b19251e659ae31dae8942359496cdb78f1235c44` |
| `mount_guard.sh` | 5,536 | `7401bc34c9e85b0091f5d994169949e5af915cec87034c0bd97e236f83e4ad5c` |
| `root_mount_guard.sh` | 1,632 | `acfebdbf0dbdbe5135d453a3e41b8829c49fa8510117b35c960bebd9fe154d06` |
| `capability_probe.sh` | 16,907 | `5281d55b407c33ccb712fd83c358fee6386f4dfc235fdd4ea091dfe782bc8de6` |

All are under `tools/w176-stage4b-capability-probe/payload/` and have Git
mode 100755. Confirm which executable bits are actually needed by the stock
autorun and shell invocations, and whether macOS FAT mount permissions can
meet them. The tracked 77-byte
`ARM_STAGE4B_CAPABILITY_PREFLIGHT.example` is inert and must not be copied.
There must be no tracked or prepared live
`ARM_STAGE4B_CAPABILITY_PREFLIGHT` marker. The live marker is consumed; the
`.stage4b-capability.lock` directory is retained. Independently check that
an unarmed insertion can create the lock and must therefore be prohibited.

Review the complete Mac procedure line by line for wrong-device, symlink,
stale-result, partial-copy, failed-hash, permissions, shell-state, cleanup,
host-backup and evidence-contamination hazards. Challenge the `diskutil`
identity fields, the exact-name cleanup with full backup and acknowledgement,
the direct frozen-blob extraction, no-clobber behavior, byte-for-byte and
SHA-256 checks, the final unarmed inventory, and all stop conditions. Do not
assume that the operator can safely reuse an old USB if its contents are
ambiguous; a dedicated clean USB is preferred. Evaluate whether the procedure
could delete unrelated data, silently prepare the wrong device, or accidentally
create a live marker.

Independently trace target action order in the frozen scripts. The proposed
order is stock USB autorun, entrypoint and effective removable-FAT mount
validation, collector revalidation, one-shot lock creation (the first target
filesystem mutation), live-marker validation and consumption, fresh result
transaction with INCOMPLETE, bounded metadata reads and USB-only writes,
inventory/checksums, then COMPLETE last. Identify every target-side mutation
and any validation-to-write race. Confirm no NVM/MTD/stock write, remount,
experimental memfd/seal/execveat call, custom ARM execution, CAN/MCU/UART
stream access, process attachment/signalling or networking is present.

Review the future operator sequence without performing it: explicit separate
authorisation, one arming command marked DO NOT RUN UNTIL SEPARATELY
AUTHORISED, stable RoadTop power, one insertion only, no interaction during
collection, conservative waiting, USB LED not a completion signal, no early
removal or automatic retry. Challenge the suggested 20-minute wait as a
conservative choice, not a measured deadline; the engine is not established
as a technical prerequisite, and safety/battery concerns must override an
attempt.

Review the immediate **read-only** return-to-Mac inspection of marker, lock,
result directories, STATUS, COMPLETE, ERRORS and OPTIONAL. Then review the
timestamped **whole-USB-root** host preservation, source/copy comparison,
copied transaction hashes, and provenance statement recording the frozen
SHA, time, volume label, one-shot state and operator's one-attempt account.
The original returned USB must remain unchanged by the prescribed commands;
distinguish this from unpreventable macOS housekeeping and do not claim that
a host copy proves original FAT inode metadata.

The frozen host analyser is
`tools/w176-stage4b-capability-probe/analyze.py` at the frozen SHA, 28,530
bytes, SHA-256
`4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566`.
Check that it is extracted and verified from Git, run only on the preserved
host copy, and sends stdout, stderr, exit status and JSON outside the copied
transaction. Challenge classification precedence: unexpected/ambiguous
conditions require MANUAL REVIEW; ordinary incomplete or rejected transaction
is INCOMPLETE; VALID COMPLETE requires coherent one-shot state, zero mandatory
failures, a regular COMPLETE, empty ERRORS, copy agreement and analyser
acceptance. No category authorises an automatic physical retry.

If a valid metadata capture is eventually returned, it may inform kernel,
mount, MTD, libc/loader and static feature-support questions. It cannot prove
that the installed unit successfully creates, seals or executes a resident
payload. The analyser and conclusions must retain:

`SEALED_RUNTIME_EXECUTION=NOT_TESTED`

`EXECUTION_HIGH=OPEN`

Report findings by CRITICAL/HIGH/MEDIUM/LOW/INFO with exact file/line and a
minimal corrective action. State whether the *handoff procedure*, including
operator and return-evidence steps, is safe enough for **one separately
authorised controlled metadata-only attempt**. A GO here does **not** authorise
Stage-4B residency, boot persistence, NVM writes, custom ARM execution or any
other experiment. Do not perform the attempt yourself. End your response with
exactly one of these two verdicts, and no text after it:

```text
PHYSICAL STAGE-4B CAPABILITY METADATA CAPTURE:
GO
```

or

```text
PHYSICAL STAGE-4B CAPABILITY METADATA CAPTURE:
NO-GO
```
