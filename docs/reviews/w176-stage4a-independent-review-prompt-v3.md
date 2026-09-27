# Independent Work safety review — Stage-4A v3

Copy the complete prompt below into a fresh independent Work review.

---

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4A CAN/MCU topology capture, after the second NO-GO remediation.
Use high reasoning. Do not rely on the implementing session's recommendation.

Repository: https://github.com/danoev/GeminiTop
Development branch: feature/w176-stage4

EXACT FROZEN CANDIDATE TO REVIEW:
17557e6481d68799712779ca605b87e2da866e47

Do NOT substitute branch HEAD. The prompt is a later documentation-only
commit. Inspect source and tests at the exact candidate above.

Starting SHA before this remediation:
82b7d36fce4428ed91eabe4013c95917ce4662d2

Second NO-GO candidate:
11376fc13f61cf0f05a3bfd45ab287e5f42982d0

Original NO-GO:
ff5eab20c8959863ff805a331775807c4ce80322

Stage-4A base:
00e65f75662d5051558f2ae4bf4f07145732f30c

## Non-negotiable boundary

No physical target access, vehicle action, CAN receive/transmit, MCU/UART
stream access, NVM write, target ARM execution or emulation. Do not arm a
payload. Do not alter tracked repository content. Disposable host fixtures and
native Linux container test tools are permitted; target libraries are data.
Do not interpret host PASS as installed-target evidence.

Stage-4B is out of scope and frozen. Require an empty diff from starting SHA
for tools/w176-stage4-residency/, docs/platform/w176-stage4-residency.md, and
docs/reviews/w176-stage4b-independent-review-prompt.md. Stop and report any
change there. Do not broaden into audio, MOST or illumination semantics.

The eventual Stage-4A payload is separately armed and metadata-only:
/proc/net/dev; approved sysfs interface metadata; exactly 18 candidate device
paths; bounded production FD ownership metadata; and bounded installed-library
snapshots. Candidate device streams must NEVER be opened.

## Inspect exact files

- AGENTS.md
- tools/w176-stage4-topology/payload/gemn_auto.sh
- tools/w176-stage4-topology/payload/mount_guard.sh
- tools/w176-stage4-topology/payload/library_mount_guard.sh
- tools/w176-stage4-topology/payload/stage4_topology.sh
- tools/w176-stage4-topology/payload/ARM_STAGE4_CAN_MCU_TOPOLOGY.example
- tools/w176-stage4-topology/analyze_topology.py
- tools/w176-stage4-topology/test_stage4_topology.py
- tools/w176-stage4-topology/test_round2.py
- tools/w176-stage4-topology/reproduce_round2.py
- tools/w176-stage4-topology/test_linux_mounts.sh
- tools/w176-stage4-topology/Test.Dockerfile
- tools/w176-stage4-topology/README.md
- docs/platform/w176-stage4-topology.md
- docs/platform/w176-stage4a-remediation-round2.md
- docs/workstreams/w176-platform.md

Read the second NO-GO source independently. All 13 requested findings were
reproduced by the implementing session against that exact frozen source using
temporary fixtures BEFORE remediation. Reproduce independently where practical;
never run the vulnerable source against real device paths.

## 1. Final transaction — previously HIGH

Audit every operation after the last general clean-failure gate. Require:

- every mandatory operation immediately stops on failure;
- final STATUS write and hash explicitly require success;
- checksum exit status is separate from parsing (valid-looking nonzero is FAIL);
- COMPLETE temp content is exactly 11 bytes, complete=1 followed by newline;
- temp size/content command statuses are checked separately;
- temp hash is recorded under logical path COMPLETE;
- checksum cleanup and manifest commit must succeed;
- all final required objects must be regular/non-symlink;
- ERRORS must be empty; STATUS must reparse as clean COMPLETE;
- final size measurement/parse/read/limit/cleanup must succeed;
- no recorded failure can subsequently create COMPLETE;
- the final FAILURES==0 gate immediately precedes the COMPLETE rename;
- the exact hashed temp is renamed LAST;
- no operation after that rename is mandatory for success.

Retest all 21 individually injected late operations, the final recorded-failure
gate, and the five STATUS checksum variants: nonzero empty, nonzero valid,
malformed, truncated, extra pathname. Include actual checksum failures rather
than relying solely on whole-operation replacement. A capture with no valid
COMPLETE must result from EVERY failure, including one after STATUS initially
says COMPLETE. Independently inspect failure cleanup/error reporting.

## 2. Effective library mount — previously HIGH

Do not accept proving only that /application itself is ro SquashFS.
For EACH approved exact canonical library path require the effective deepest
proper-path-component mountpoint to equal the established canonical application
mount. Reject every covering nested mount, including ro and same-st_dev bind
mounts. Require SquashFS, ro, NOT rw, a unique application record, and matching
source/application st_dev. Require child revalidation before any data open,
and a canonical pathname open followed by descriptor/path/mutation checks.

Retest:

A. application SquashFS ro, no covering nested mount: PASS.
B. application/lib tmpfs rw: fail BEFORE OPEN.
C. application/lib ext4 ro: fail BEFORE OPEN.
D. unrelated nested mount and application/lib2 boundary: approved sources pass.
E. mismatched source st_dev: fail BEFORE OPEN.
F. mount topology changes before child revalidation: fail BEFORE OPEN.
G. mutable covering mount plus modeled swap to FIFO: swap/open sentinels untouched.
H. nested same-device bind mount: fail BEFORE OPEN.
I. duplicate/escaped/oversized mount table: fail closed.

Inspect bounded /proc/self/mounts parsing (131072 bytes, 1024 records, 4096-byte
lines, six fields), trailing-newline handling, short-read handling, ambiguity
policy, and proper component boundaries. The helper conservatively rejects
all escaped mountpoints, including unrelated ones: assess that documented
compatibility limitation honestly.

The threat model is a normal non-hostile stock system; privileged root changing
mounts or paths between validation and open is not atomically defeated by shell.
Assess whether this is acceptable for the proposed physical metadata capture;
do not silently claim hostile-root-safe openat/O_NOFOLLOW behavior.

## 3. Real Linux proc/sysfs compatibility

Production library mount source must be /proc/self/mounts, not a demand that
normal /proc/mounts be a nonsymlink. Test /proc/mounts -> self/mounts with no
weakening of returned capture-tree symlink rejection.

Test class/net/can0 -> ../../devices/virtual/net/can0, type=280. Metadata must
be retained and CASE A available after validation. Require metadata-only
resolution into canonical /sys/devices, allowlisted bounded ordinary attrs
(type, operstate, mtu, flags, uevent, address), OPTIONAL for unavailable attrs,
and fail closed on an out-of-root class link. No device stream open.

Where practical run the pinned native Linux image with real proc/sysfs,
generated host-fixture SquashFS, nested tmpfs and same-device bind mounts.
Only the repository is bound read-only; do not bind host device trees.

## 4. Independent analyser semantic validation

Checksums alone are not sufficient. Before ANY CASE output require:

- interfaces <=32 AND == declaration count; no duplicates/conflicts;
- device_candidates <=18 AND == records; exact allowlist, no duplicates;
- processes_inspected <=256 and not less than retained owner count;
- fd_links_inspected <=4096 and not less than retained ownership rows;
- matched_owners <=16 AND == actual inventory/owners groups;
- library_bytes <=720896 AND == actual approved library bytes;
- STATUS optional_findings == sequential valid OPTIONAL row count;
- one PID has one start time; one PID/FD has one target/start identity;
- <=16 unique owner PIDs, exact four metadata files each, no undeclared files;
- maps <=65536 per owner AND <=524288 aggregate;
- framework <=393216, MCU <=327680, aggregate <=720896;
- exact reviewed CAPABILITIES schema-3 keys/values;
- exact canonical checksum set; leaf/parent symlink rejection;
- conservative logical final byte acceptance, without claiming FAT inode or
  allocation reconstruction from copied evidence.

Construct checksum-valid inconsistent captures for EACH requirement, including
999999 processes, 17 owner groups, excessive aggregate maps, conflicting starts,
OPTIONAL mismatch, and incorrect library total. Expect validation FAIL and NO
topology classification output.

CASE A means only confirmed Linux ARPHRD_CAN/type 280; physical Mercedes CAN
connection, traffic, bus identity, bitrate and semantics remain UNKNOWN.
MCU paths/FDs/library strings remain INFERENCE, not CASE B proof. CASE C needs
independent translated-semantic proof; absent type280 remains CASE D.

## 5. Output bounds and every writer

Chosen Option B:
output.final_capture.kib.max=2048
output.write_ceiling=NOT_CLAIMED
all_writers.individually_bounded=1

Require the 2048-KiB final acceptance test; do not call it hard write admission.
Audit EVERY writer including proc snapshot, interfaces, devices, owners,
comm/cmdline/exe/maps, both libraries, inventory, OPTIONAL, ERRORS, SUMMARY,
CAPABILITIES, STATUS, checksums, COMPLETE and all temporary files.

Independently recompute the conservative logical final object sum:
2,449,488 bytes before the separate aggregate acceptance gate (zero ERRORS;
64-byte conservative COMPLETE allowance). Distinguish byte caps, FAT allocation,
temporary consumption, and cumulative write volume. Verify bounded append
admission, finite numeric scans, bounded diagnostics, and per-file ulimit
behavior in native Linux/BusyBox terms; inability to set the limit must stop.
Do not accept merely post-hoc individual limits on an unbounded writer.

## 6. Preserve all previous HIGH/MEDIUM fixes

Retest exact 18 device paths, no broad globs, finite PID/FD ranges, PID/FD
before/after bracketing, complete canonical checksum coverage, stale output
exhaustion without reuse, result-parent/leaf symlink escapes, special source
preflight, and conservative CASE policy.

Special-source matrix: direct FIFO, symlink to FIFO, symlink to MCU FIFO,
Unix socket, directory, source disappearance, disposable character device,
and rejected mutable nested mount with attempted FIFO replacement.
Every stream sentinel must remain untouched. Do not treat macOS permission
skips as proof: native Linux must cover socket and character-device fixtures.

## Tests and evidence reported by implementing session

Stage-4A: 53 tests PASS native Linux with no skips; macOS 53 run/51 pass and
two sandbox skips covered in Linux. Eight real Linux mount/topology assertions
PASS. Late transaction 21 operation failures plus final gate PASS; five STATUS
hash forms PASS. Historical suites: Stage1 56, Stage2 43, Stage3 24,
target-identify 10, firmware-inspector 10. Stage4B static 8 and Linux integration
15 PASS. Stage3 static ABI, real FAT RO/RW, 50 concurrent FAT pairs and paused-RO
contender PASS. sh/dash syntax, compileall, whitespace/staged-data audits PASS.
Stage4B has an empty diff against starting SHA. Real marker absent.

Treat these as review leads, not your independent conclusion. Run/inspect the
exact frozen revision. Test.Dockerfile pins Debian base digest and top-level
Python/SquashFS package versions; transitive apt dependencies are not all frozen.

## Required return

1. Exact candidate SHA inspected; branch HEAD if different.
2. Findings with CRITICAL/HIGH/MEDIUM/LOW/INFO severity and exact file/line.
3. Reproductions and final-transaction failure matrix results.
4. Effective mount proof and mutable-mount no-open sentinel outcome.
5. proc/sysfs compatibility and type-280 fixture outcome.
6. Every semantic inconsistency regression outcome.
7. Every-writer bound audit, theoretical size and truthful output semantics.
8. Previous safety regressions, special-source matrix and test totals/skips.
9. Stage4B unchanged YES/NO; marker absent YES/NO.
10. Physical action / target ARM execution: MUST be NONE.
11. Remaining assumptions/limitations and exact remediation if needed.

Finish with ONE verdict:

PHYSICAL STAGE-4A TOPOLOGY CAPTURE:
GO

or

PHYSICAL STAGE-4A TOPOLOGY CAPTURE:
NO-GO

GO requires no unresolved HIGH or CRITICAL finding on the physical path.
The review verdict itself does not execute/arm the payload: physical action
still requires the separate operator decision. Do not approve Stage-4B here.
