# Independent Work safety review — Stage-4A v4

Copy the prompt below into a fresh, independent Work review. This file is a
documentation-only handoff, not the candidate to review.

---

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4A CAN/MCU topology capture. Use high reasoning and verify source and
test results yourself. Do not rely on the implementing session's recommendation.

Repository: https://github.com/danoev/GeminiTop
Development branch: feature/w176-stage4

EXACT FROZEN CANDIDATE TO REVIEW:
`d0f5d7ad651953f607414de956f24bff2d8889f9`

Do NOT substitute the later branch HEAD. The physical-run candidate that
received the previous independent GO was
`17557e6481d68799712779ca605b87e2da866e47`; preserve it as historical
evidence, not as the new candidate. Its operator-returned second physical
attempt was `INCOMPLETE`, mandatory failures 3: `owner_limit`, then two missing
required libraries. Summary: 130 processes inspected, 567 FD links, 17
matched owners against a maximum of 16, library bytes 0. No valid COMPLETE
was returned. A first attempt was interrupted by the operator and was also
INCOMPLETE. The original FAT objects were not inspected in the implementing
session; partial Launcher/gocsdk, serial, and network observations are not
validated topology evidence. Read
`docs/platform/w176-stage4a-physical-attempts.md` for precise provenance.

## Non-negotiable boundary

No vehicle or physical target action. Do not arm the payload, read CAN frames,
transmit CAN, open MCU/UART/CAN candidate streams, send MCU commands, write NVM,
execute/emulate target ARM code, run copied libraries, or alter tracked source.
Disposable host fixtures and native Linux container tests are permitted.
Stage-4B is out of scope and frozen: compare the exact candidate against
`84f7cfb7042be5ef485024d9474ac992bbb76b24` for
`tools/w176-stage4-residency/`, `docs/platform/w176-stage4-residency.md`, and
`docs/reviews/w176-stage4b-independent-review-prompt.md`. Require an empty
diff. Do not broaden into vehicle CAN IDs, illumination semantics, audio, or
MOST. Host PASS is not installed-target proof.

## Inspect exact source and records

- AGENTS.md and project safety/evidence rules;
- `tools/w176-stage4-topology/payload/gemn_auto.sh`;
- `tools/w176-stage4-topology/payload/mount_guard.sh`;
- `tools/w176-stage4-topology/payload/library_mount_guard.sh`;
- `tools/w176-stage4-topology/payload/stage4_topology.sh`;
- `tools/w176-stage4-topology/payload/ARM_STAGE4_CAN_MCU_TOPOLOGY.example`;
- `tools/w176-stage4-topology/analyze_topology.py`;
- all Stage-4A tests, especially `test_tgid_owners.py`,
  `test_stage4_topology.py`, `test_round2.py`, `reproduce_tgid_owner_limit.py`,
  `reproduce_round2.py`, and `test_linux_mounts.sh`;
- `tools/w176-stage4-topology/Test.Dockerfile` and README;
- `docs/platform/w176-stage4-topology.md`,
  `docs/platform/w176-stage4a-tgid-remediation.md`,
  `docs/platform/w176-stage4a-remediation-round2.md`, and
  `docs/platform/w176-stage4a-physical-attempts.md`.

Verify the old defect independently. Linux directly addresses non-leader
`/proc/<tid>` even when a directory listing omits it; `Tgid` in
`/proc/<id>/status` identifies the process/thread group. Reproduce the frozen
`17557e6` owner-limit failure in disposable synthetic proc only, never against
real device paths. One TGID with 20 addressable TIDs should explain how the
old model consumes 17 owner slots. Distinguish this CONFIRMED host code defect
from the physical TGID grouping, which remains UNKNOWN in the incomplete
return. Do not call the physical root cause proven by unreturned status fields.

## 1. TGID/process-owner remediation — priority audit

Audit bounded `/proc/<id>/status` reads for numeric IDs 1..4096, with no broad
proc glob and no unbounded read. Verify that exactly one numeric `Tgid:` is
required; missing, duplicate, malformed, nonnumeric, oversized, vanished,
zero/leading-zero, and out-of-range values are conservatively handled. The
collector attempts at most three 4096-byte reads, admits at most 8192 status
bytes, and must not chase out-of-range TGIDs. Verify actual shell/BusyBox
compatibility of the `dd`, `awk`, `stat`, and read operations.

Only `id == Tgid` may undergo FD-number inspection. Non-leader TIDs must not
increment `processes_inspected`, scan FDs, consume `MAX_OWNERS=16`, or capture
comm/cmdline/exe/maps. `processes_inspected` must count unique leaders actually
subjected to FD inspection; a leader with unavailable FD directory must be
OPTIONAL/not counted, not absence proof. IDs >4096 remain NOT_INSPECTED.

Check before/after bracketing for retained owners: leader PID==TGID, start
time, FD number, FD symlink target, safe FD-stat identity, bounded metadata,
then TGID, start, target and FD-stat recheck. Changed/disappeared identity must
discard owner evidence with a bounded optional race, not retry indefinitely.
PID reuse or a task becoming non-leader must never retain attribution.

One leader with multiple candidate FDs must use ONE owner slot and ONE group
of comm/cmdline/exe/maps, but TWO owner FD records. Separate real process
leaders with identical comm/exe must remain separate. Never deduplicate by
names, executable paths, or candidate path strings.

Independently test at least:

1. `/proc/<tid>` with `Tgid != tid` on native Linux;
2. one leader plus 20 threads: one inspected process, one owner, one FD scan;
3. two leaders plus many threads each: two owners;
4. one owner, two candidate FDs: one metadata group and two FD rows;
5. 16 genuine leaders PASS and 17 genuine leaders fail closed at owner_limit;
6. malformed/missing/duplicate/nonnumeric/oversized Tgid and status race;
7. non-leader disappearance, leader disappearance, FD directory unavailable;
8. TGID change, PID/start-time reuse, and FD replacement/disappearance;
9. in-range TID whose TGID is outside 4096: optional, no chase;
10. two genuine leaders with the same exe and comm: two owners;
11. physical-like Launcher/QThread and gocsdk worker TIDs with ttyS1/2/4
    links: complete capture, both libraries, inventory, checksums, clean
    STATUS and COMPLETE last, then analyser PASS.

Inspect the Linux `CLONE_FILES` limitation. Normal pthread FDs are visible
through the leader, but thread-specific unshared FD tables and a leader whose
main thread exited can make process-leader-only inspection incomplete. The
candidate must document this as a coverage limitation, not assert absence and
not silently reintroduce per-thread scans. Assess whether it is acceptable
for this metadata-only first physical capture.

## 2. Analyser and transaction semantics

Require checksum-covered `processes/leaders.txt` with exact schema
`PID|TGID|start`, unique bounded PID==TGID entries and count exactly equal to
`processes_inspected`. Require each owner row `PID|TGID|start|FD|candidate`
to match one roster identity, consistent start per PID, unique PID/FD identity,
at most 16 metadata groups, exactly four bounded metadata files per owner,
and multiple FD rows permitted. `matched_owners` must equal the unique owner
groups, not row count. Reject checksum-valid inflated process counts,
nonleader owners, inconsistent starts, duplicate metadata groups, or 17
genuine owner groups before producing ANY CASE. Check exact STATUS/SUMMARY
schema 3 and CAPABILITIES schema 4 with
`owner.identity=PID_EQUALS_TGID`; verify canonical checksum coverage includes
the leader roster.

Re-audit EVERY late mandatory operation: STATUS write and hash; checksum
command exit status versus output parsing; exact 11-byte COMPLETE temp;
manifest cleanup/commit; final required regular/non-symlink objects; empty
ERRORS; clean STATUS; final size check; last FAILURES==0 gate; exact hashed
COMPLETE temp renamed LAST. A failure after STATUS initially says COMPLETE
must still yield no valid COMPLETE. Rerun the prior 21 late-operation
injections, final failure-count gate and five STATUS-hash variants. Confirm
fresh-directory creation without stale reuse, USB-only output, marker
consumption and one-shot lock. A stopped USB activity LED is NOT a done
signal: only returned STATUS, checksums, COMPLETE and host analyser PASS are.

## 3. Effective read-only library boundary and special sources

For EACH exact approved installed library require effective deepest mount
membership in the canonical application read-only SquashFS, unique application
record, source/application st_dev match, and child revalidation before data
open. Reject writable/readonly covering nested mounts, including same-device
binds; accept unrelated and component-boundary mounts. Check finite bounded
mount-table parsing and truthful limitation that privileged hostile mount
races are not atomically defeated by shell. Require regular/non-symlink
preflight, then single-open descriptor-verified bounded snapshots. Test direct
FIFO, symlink-to-FIFO, symlink-to-MCU-FIFO, Unix socket, directory,
disappearance, character device, and mutable-mount swap sentinels. NO rejected
stream may be opened. Native Linux must cover macOS fixture skips.

## 4. Whole-candidate metadata and classification safety

Keep exactly 18 candidate device paths; no candidate stream opens, CAN receive
or transmit, MCU/UART reads/commands, unknown ioctls, interface changes,
process attachment, logging change, NVM write, or target ARM execution.
Inspect bounded `/proc/net/dev`, approved sysfs class metadata, real
`/proc/mounts -> self/mounts` compatibility, real class/net symlink layout,
type-280 handling, symlink containment, candidate limits and races.

CASE A confirms only a Linux ARPHRD_CAN/type-280 interface, not Mercedes CAN
connectivity, frames, bitrate, or semantics. MCU paths/owner FDs/library
strings are at most INFERENCE, not CASE B. CASE C needs independent
translated-semantic proof; no type-280 leaves CASE D/UNKNOWN. The failed
physical return must not be promoted to a topology conclusion.

Recheck every analyser invariant: interface/device counts and exact records;
FD link count >= retained rows; maps individual/aggregate bounds; both
library individual/aggregate bounds; optional row count; canonical exact
checksum set and capture-tree symlink rejection; logical final-size gate.
Construct checksum-valid inconsistent captures and require rejection.
Checksums establish consistency, not deliberate-rewrite authentication or
original FAT inode metadata from uploaded copies.

## 5. Output bounds and previous regressions

The reviewed output policy remains `output.final_capture.kib.max=2048`,
`output.write_ceiling=NOT_CLAIMED`, and
`all_writers.individually_bounded=1`. Audit every writer and temporary file,
including new status staging (at most 12288 bytes attempted/written, at most
8192 admitted), parsed TGID staging (21 bytes), and final leader roster
(16384 bytes). Recompute the conservative logical final-object bound rather
than reusing the historical 2,449,488-byte figure unchanged. Distinguish
per-file byte caps, FAT allocation, peak staging, aggregate final acceptance,
and unclaimed cumulative USB write volume. Verify native per-file `ulimit`
behavior, failure to set it, append admission, and finite loops.

Rerun the prior 13 frozen second-review reproductions in disposable fixtures
and confirm all corresponding HIGH fixes remain closed: final transaction,
effective mount, sysfs/proc behavior, analyser semantic validation, output
writer safety, stale output and symlink escapes. Include the real Linux
mount/topology assertions and full native Linux Stage-4A suite, not only macOS.

The implementing session reports: 69 Stage-4A tests passing on native Linux;
69 run on macOS with three host-sandbox skips covered in Linux; eight real
Linux mount/topology assertions passing; 13 frozen round-2 defects and the
new frozen owner-limit defect reproduced only in disposable host fixtures.
Historical regressions: Stage-1 56, Stage-2 43, Stage-3 24,
target-identification 10, firmware-inspector 10; Stage-4B static 8 and Linux
integration 15; Stage-3 and Stage-4B static ELF/ABI checks; Stage-3 FAT/RO
and 50-pair lock concurrency; sh/dash syntax, Python compileall and Git
diff/tracking audits. Treat these as leads, not independent conclusions.

## Required review return

1. Exact frozen candidate SHA and later branch HEAD, if different.
2. CRITICAL/HIGH/MEDIUM/LOW/INFO findings with exact file and line.
3. Old frozen owner-limit reproduction, and what is/not physically proven.
4. Independent TGID parse, leader selection, process count, owner count, FD
   scan and before/after bracket audit.
5. All one/two/many-thread, multiple-FD, 16/17-owner, malformed/race, and
   physical-shaped full-completion test results.
6. Analyser roster/schema/canonical-checksum and adversarial capture results.
7. Previous late-transaction, effective-mount, special-source, real proc/sysfs,
   output-writer and conservative CASE-policy regression results.
8. Exact test totals/skips; Stage-4B unchanged YES/NO; real arming marker
   absent YES/NO; proprietary/raw capture tracking absent YES/NO.
9. Remaining coverage/performance limitations and smallest required remedy.
10. Physical action and target ARM execution/emulation: MUST be NONE.

Finish with exactly one verdict:

PHYSICAL STAGE-4A TOPOLOGY CAPTURE: GO

or

PHYSICAL STAGE-4A TOPOLOGY CAPTURE: NO-GO

GO requires no unresolved HIGH or CRITICAL finding affecting this physical
path. Even a GO review does not itself arm or execute the payload; a separate
operator decision is required. Do not approve Stage-4B here.
