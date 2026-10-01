# Fresh independent Work re-review — W176 Stage-4B capability physical handoff

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
An earlier physical-handoff review returned NO-GO with two HIGH findings
(host destination resolving to USB; recursive cleanup crossing a nested
mount) and one MEDIUM (VALID COMPLETE lacking return provenance). The
procedure-only remediation was
`29c303632419817db062c70f9360a725602a61d5`.
The latest independent review accepted those closures but returned **NO-GO**
for one new HIGH: final arming checked the four scripts and known one-shot
names, yet could allow an extra root object such as `UNEXPECTED.BIN`. It also
reported one LOW: host readability/executability was not rechecked just before
arming. Review the new documentation-only root-inventory remediation commit:
`8136c566f69a7480204489a6f1fddb7d773853e7`.
The host-review result is **not physical GO**. Review the exact frozen
implementation and the remediated handoff procedure, not the moving branch
tip. These later commits change documentation only.
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

First independently reproduce or challenge the prior findings against
documentation commit `8209812124b46015ff5663ca29ff2f9993186b16`:
an ancestor symlink could make a lexical host path resolve onto USB; the
optional recursive result deletion could cross a nested mount; NO or UNKNOWN
one-attempt statements were informational; and returned payload files were
not rehashed against frozen Git blobs. No actual nested mount or real USB is
needed to review the old deletion risk.

Review the revised Mac procedure line by line. It must require a **dedicated
clean USB** and provide no reuse, backup/cleanup, recursive deletion, or
retry path for removable media. Check the exact accepted macOS housekeeping
names/types; any old payload, result, lock, live marker or unexplained object
must STOP without deletion. Challenge the direct frozen-blob extraction,
noclobber behavior, byte/size/hash checks, final unarmed inventory, and
partial-preparation stop rule. Verify the Mac code cannot accidentally create
a live marker during preparation.

Independently challenge the reusable host-storage guard. It canonicalises
the entire existing parent, including symlinked ancestors; identifies the
effective filesystem with `df -P` and cross-checks `diskutil info -plist`;
requires an internal, nonremovable, writable backing volume; and rejects
USB/repository/cloud locations and a host destination on the same
filesystem/device as USB. Check the APFS System/Data firmlink case, for which
`st_dev` alone can be ambiguous. Check whether a path or mount swap between
validation and copying remains possible and whether fail-closed rechecks
are sufficient for one controlled attempt. No `/Users` pathname by itself
establishes internal storage or absence of cloud synchronisation.

Check the pre-arm host-only manifest: frozen SHA, preparation UTC time,
dedicated-clean root state, four exact filenames and Git-derived hashes/sizes,
and USB identity. The required `VolumeUUID` is treated as a persistent
volume identifier only when available; a missing value must STOP. The
comparison also uses label, filesystem, capacity, USB bus and removable
flags. `DeviceIdentifier`, `DeviceNode`, mountpoint and `st_dev` are
session-local and must not be required to match across eject/reinsert.

First reproduce the latest HIGH against the earlier procedure commit
`29c303632419817db062c70f9360a725602a61d5`: after preparation, add
`UNEXPECTED.BIN` to a **disposable host fixture**. Confirm the four frozen
scripts still pass `frozen_provenance_gate` and the former arming name-only
check does not reject the extra object. Do not run the old marker-creation
command. Then inspect the new `final_root_inventory_gate` independently.
It must load the exact pre-arm record from validated internal host storage,
require the frozen SHA, schema, stable identity, four payload names and
well-formed `clean_usb_initial_root` mapping, and require the current USB
root's complete `lstat` name/type mapping to equal precisely:

`clean_usb_initial_root` + four frozen regular-file scripts.

The gate must not invent or extend a housekeeping allowlist after
preparation. A new `.Spotlight-*`, `.Trashes`, `._foo`, arbitrary file,
directory, symlink or special object must STOP, as must a missing/renamed
payload or a name/type change of prepared housekeeping. Housekeeping
contents are not claimed immutable; the asserted boundary is root names and
types. Confirm the independent frozen-byte/size/SHA gate still runs before
the root gate and cannot be replaced by it.

Review the exact future arming order: revalidate host destination and USB
identity; compare stable identity to pre-arm; verify frozen payload; verify
exact unarmed root; check all four scripts readable on the current Mac mount
and `gemn_auto.sh` executable; independently reject marker/lock/result
state; recheck current host/media identity; only then create the live marker
with noclobber. Marker creation must be the first intended USB mutation of
the arming phase. Confirm the post-marker check requires a regular
non-symlink marker and the exact prepared baseline plus scripts plus marker,
with no lock/result/extra object. A post-marker failure means STOP, MANUAL
REVIEW and **NO INSERTION**—never automatic marker removal or repair.
Distinguish host-side read/execute presentation from the still-unknown
effective policy of this future RoadTop FAT mount. The checks address
non-malicious operator/preparation drift, not malicious privileged concurrent
mutation or hardware substitution after validation.
Challenge whether these fields are sufficient and accurately described as
corroboration, **not** physical-device authentication.

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
result directories, STATUS, COMPLETE, ERRORS and OPTIONAL. Before any copy,
the returned stable USB identity must be compared programmatically against
the pre-arm record. Then challenge the revalidated canonical internal host
destination, its separate effective filesystem, the timestamped
**whole-USB-root** copy with `rsync -a -x`, the bounded no-symlink/no-nested-
mount source/copy comparer, and copied transaction hashes. Independently
verify all four returned and copied payload files against the exact frozen
Git blobs as regular non-symlink objects, including exact bytes, size and
SHA-256. Reports must be outside the pristine copied transaction. The
original USB must remain a read-only source from the procedure's point of
view; macOS housekeeping may still occur, and a host copy does not prove
original FAT inode metadata.

The frozen host analyser is
`tools/w176-stage4b-capability-probe/analyze.py` at the frozen SHA, 28,530
bytes, SHA-256
`4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566`.
Check that it is extracted and verified from Git, run only on the preserved
host copy, and sends stdout, stderr, exit status and JSON outside the copied
transaction. Challenge classification precedence and the final executable
host gate: unavailable/mismatched identity, unsafe destination, payload
mismatch, operator answer other than exact YES, unexpected objects, multiple
results, ambiguous lock/marker, copy mismatch or analyser discrepancy must
be MANUAL REVIEW REQUIRED. Only with sound provenance may a known incomplete
transaction or frozen analyser structural/checksum rejection be INCOMPLETE.
VALID COMPLETE requires every provenance gate, exactly one expected result,
consumed marker, retained real lock, STATUS complete with zero mandatory
failures, regular COMPLETE, empty ERRORS, copy agreement, and frozen analyser
acceptance. No category authorises an automatic physical retry.

Re-run or challenge the disposable host fixtures: ancestor symlink to USB
STOP; external or same-device host STOP; separate internal host PASS; dirty
or nested old result STOP with no deletion; stable identity match PASS and
mismatch MANUAL; returned frozen payload match PASS and modified/symlinked
payload MANUAL; operator YES eligible, NO/UNKNOWN MANUAL; missing COMPLETE
INCOMPLETE. Check all documented Bash blocks with `bash -n`, Python block
syntax, and the absence of any `rm -R` or `rm -rf` against removable media.
The implementing session also reports a read-only test of the effective
host-volume lookup selecting `/System/Volumes/Data` for `/Users/daniel`.
These fixtures and host checks are not physical RoadTop evidence.

Run or challenge the new committed-in-document A–P disposable fixture harness.
It must never touch a real USB or target. In particular verify: exact root
PASS; extra file/directory/symlink/FIFO/new housekeeping STOP; missing or
type-changed prepared housekeeping STOP; missing/symlinked payload STOP;
changed payload bytes STOP through frozen provenance even when root names
still match; unreadable or non-executable host fixture STOP; exact unarmed
root eligible; exact armed root PASS; late extra object STOP/MANUAL. Check
documented Bash and Python syntax again and confirm no removable-media
recursive deletion path has reappeared.

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
