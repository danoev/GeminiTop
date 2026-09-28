# W176 Stage-4B fresh safety audit — 2026-09-28

**Decision: STAGE-4B NOT READY.** This is a host-side audit of historical
baseline `3a920c87cfca71cb845fc75c9c868f99d621ef59`, not a new frozen
implementation or a physical approval. Do not arm/install/verify/uninstall the
historical payload on the RoadTop. The prior review prompt is superseded as a
candidate handoff; no v2 independent-review prompt is issued until the HIGH
findings below are closed and retested together.

## What remains sound but narrow

The installed Stage-1/2 evidence supports `mtd12` named `nvm`, size 8 MiB,
and `/media/flash/nvm` as a YAFFS2 RW mount. The proposed private path is
`/media/flash/nvm/geminitop/w176`, not `nvm/bin` or `nvm/lib`. The old C source
is inert: an idle two-second loop, volatile `/tmp` status, TERM/INT handling,
no device/network access or boot hook. Its 5,556-byte ARMHF ELF has SHA-256
`57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6`.
Two fresh clean outputs from the existing pinned local Linux/arm64 toolchain
container matched that exact hash and size; the existing static ELF/import
verification passed. The binary was not executed or emulated. The container
image was already present locally; this audit did not independently reacquire
the official archive, so archive provenance remains the previously recorded
pin rather than a fresh download verification.

Existing tests pass: eight static tests and 15 disposable Linux integration
cases, all using a host-native process stand-in. These tests do **not** cover
the full current Stage-4B safety matrix. Passing them does not close the
findings below.

## Unresolved HIGH findings

1. **First-write mount identity is not proved.** `common.sh:53-65` checks a
   unique pathname, YAFFS2, RW, and an independent `mtd12` record, but never
   binds the mount source to that partition. It does not calculate the
   effective deepest mount for `geminitop`, `w176`, or staging paths, so a
   covering nested mount can redirect the first persistent write. The
   sanitised Stage-2 record does not preserve the exact physical mount-source
   token needed for a strict binding. That value must be recovered from the
   original validated Stage-2 capture or a separately reviewed read-only
   metadata capture; do not guess it from reference firmware.
2. **Mandatory command failures can be masked.** `common.sh:40` pipes
   `sha256sum` into `awk`, and lines 66 and 75 similarly pipe `dd`/`df` into
   parsers. With no `pipefail` in POSIX sh, a producer that prints plausible
   output and exits nonzero can be accepted. Hash and free-space checks are
   first-write gates. All producer exit codes and exact output syntax need
   separate validation, with adversarial producer fixtures.
3. **Process identity and USB-FD absence are not fail-closed.**
   `read_process_identity` reads start time and two exe links but does not
   require `PID=TGID`, reject zombie/dead states, or bracket a complete FD
   scan. `validate_process_detached_from_usb` skips entries that fail `-L`,
   permits a disappearing/replaced FD to be treated as absent, and has no
   stable process identity check around the loop. This cannot prove a live
   detached daemon with no USB references.
4. **Install rollback can delete a still-running destination.** On a failed
   post-launch gate, `safe_stop_process` returns success when identity cannot
   be established (`install.sh:21-37`). `abort_install` then calls the tree
   remover regardless (`install.sh:59-73`). A running process, identity race,
   or uncertain executable must leave NVM intact for manual review, not
   trigger deletion. The rollback also removes named files before proving the
   committed directory contains no unexpected entries.
5. **Uninstall can confuse uninspectable processes with absence.**
   `uninstall.sh:42-55` skips any `/proc/<pid>/exe` readlink failure and then
   accepts zero matches. It has no process-leader/TGID coverage model, so a
   live process can be missed and its executable removed. The TERM path does
   not immediately revalidate PID/start/exe before signalling, does not reject
   zombie state, and lacks a conservative response to PID reuse or inaccessible
   processes. Recovery is part of the install GO gate, not a later detail.
6. **Uninstall may remove an unproven heartbeat.**
   `uninstall.sh:76-89` accepts a heartbeat matching only schema, process name,
   and hash, without matching the installed PID/start identity or an exact
   record shape. It can delete a colliding `/tmp` file not proved to belong to
   this run.
7. **Partial transactions lack a safe state machine.** A result-output failure
   after the daemon starts invokes automatic rollback, while the safe-stop
   path can fail open. Interrupted creation/rename/uninstall states lack a
   documented `SAFE TO RETRY / VERIFY / UNINSTALL / MANUAL REVIEW` mapping.
   The currently retained one-shot lock prevents replay but does not by itself
   establish a recoverable route for each partial state.

These are safety findings from source inspection; this audit does not claim a
physical failure was observed. No physical Stage-4B action should occur with
any of them unresolved.

## Required remediation and regression gate

Use exact effective-mount matching at each prospective NVM object, including
covering nested-mount rejection and a physical source/partition identity;
separate command execution from output parsing; verify source descriptor and
destination hash without masked status; require exact object types and an
allowlisted empty parent before first write. Treat uncertain process identity
or incomplete FD coverage as **UNKNOWN**, never absence. Install cleanup must
leave any uncertain committed NVM object untouched. A separately armed
uninstaller must validate the complete directory first, bind the process to
the recorded PID/TGID/start/exe, TERM only when stable, verify termination,
revalidate objects, and delete only exact owned files. Every state transition
needs an explicit recovery rule and host failure-injection test.

The current persistent *content* budget is one 5,556-byte executable plus an
eight-line manifest (exact bytes depend on its literal path/hash) and
directory metadata. The private staging file is renamed into place, so
intended payload data is one executable copy, not a second persistent binary.
YAFFS2 metadata, journal/write amplification, and flash wear cannot be bounded
from this host analysis. The `>=128 KiB` free-space condition is a safety
margin only and must be measured on the exact effective NVM mount with checked
command status.

Required unadded tests include wrong mount-source and nested mounts;
checksum/`df`/kernel-release producer failures after plausible output;
source mutation and special files; symlink/path replacement; every staging and
rename failure; zombie, PID/TGID reuse, FD disappearance/replacement, USB FD,
heartbeat collision/malformed sequence, TERM failure, partial-install and
partial-uninstall recovery, unexpected objects before **any** removal, and
false COMPLETE/output collision. A disposable Linux filesystem fixture should
exercise actual mount behaviour. Full historical regression and a new
independent review are still required after remediation.

## Recovery classification for the historical design

| Observed state | Safe automatic action now |
| --- | --- |
| No `geminitop` parent and no running proof | A new reviewed install may be considered only after all gates pass. |
| Private staging directory exists | **MANUAL REVIEW REQUIRED**; old payload must not auto-delete it. |
| Final `w176` directory committed, launch unproved | **REQUIRE VERIFY / MANUAL REVIEW**; no blind retry or deletion. |
| Process identity or FD coverage uncertain | **MANUAL REVIEW REQUIRED**; do not signal or remove files. |
| Exact installed process and files positively verified | A newly reviewed separate uninstall may act; old uninstaller is not approved. |

No stock files were intentionally changed in the design or host fixtures.
PATH/library shadowing, boot persistence, CAN/MCU access, networking, and
target ARM execution/emulation were not introduced by this audit. The historical
payload remains unarmed in Git. This document does not authorise target writes.
