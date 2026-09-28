# W176 Stage-4B remediation status (2026-09-28)

**NOT READY FOR PHYSICAL REVIEW OR EXECUTION.** This branch contains
host-side hardening of the historical NO-GO candidate
`3a920c87cfca71cb845fc75c9c868f99d621ef59`. It is not a newly frozen
payload. Do not create live arming markers or place this directory on the
RoadTop USB. The Stage-4A branch and physical evidence are unchanged.

## Physical storage provenance and intended gate

The successful Stage-1 physical backup records
`/dev/mtdblock12 /tmp/sp/media/flash/nvm yaffs2 rw,noatime 0 0` in
`stage1-probe/mounts.txt:9` and `mtd12: 00800000 00020000 "nvm"` in
`stage1-probe/mtd.txt:14`. The successful Stage-2 backup records the `/media`
symlink to `/tmp/sp/media/`. Full provenance is in
`w176-stage4b-nvm-mount-source.md`. This is operator-returned physical
evidence, not a fresh observation from this Codex session on the target.

The hardened host candidate requires that the logical
`/media/flash/nvm/geminitop/w176` path resolve to the exact observed
canonical NVM mount, with source `/dev/mtdblock12`, `yaffs2`, RW, `mtd12`
name/size, matching mountinfo root `/`, and no deeper covering mount for each
proposed child. A same-device bind of another subtree is rejected. These
checks passed disposable Linux fixtures; target `/proc/self/mountinfo` and
`df` presentation remain physically unverified, so a mismatch must fail
closed.

Mandatory hash, kernel, mount and free-space producers are now status-checked
before parsing. The source binary is hash-checked, then copied through one
descriptor with metadata/path consistency checks into private NVM staging;
the staged and committed destination hashes are checked. No arbitrary
existing parent or staged state is overwritten. Failure after the first NVM
mutation never performs automatic persistent deletion.

## Current conservative state/recovery model

All states are derived from exact filesystem objects, USB transaction files,
live `/proc` identity, and volatile heartbeat. No mutable state database is
written to NVM. A consumed action marker and one-shot lock are not reset.

| State | Evidence | Retry / verify / uninstall policy |
| --- | --- | --- |
| PRE-INSTALL CLEAN | Private parent absent; target and USB gates pass | First install only, using a fresh armed USB. |
| STAGING_CREATED | Private parent/staging exists | No automatic retry or delete; manual review. |
| STAGING_BINARY_COMPLETE | Staged copy exists, no verified manifest | No automatic retry or delete; manual review. |
| STAGING_VERIFIED | Staged binary/hash/manifest checked | No replay if interrupted; manual review. |
| INSTALL_COMMITTED_NOT_LAUNCHED | Final directory exists without a proved live run | Preserve files; manual review. |
| PROCESS_LAUNCHED_UNVERIFIED | Launch attempted, identity or heartbeat uncertain | Preserve files and process; manual review. |
| PROCESS_VERIFIED_USB_ATTACHED | Exact PID/start/exe and finite FD scan pass | Install transaction may COMPLETE; physically remove USB next. |
| USB_REMOVAL_VERIFICATION_PENDING | Install COMPLETE, no separate post-removal proof | Verify action may run after operator removal/reinsertion; no reinstall. |
| RESIDENCY_VERIFIED | Same run and advancing heartbeat after reinsertion | Separately armed uninstall may be considered. |
| STOP_REQUESTED | TERM sent to exact run | Wait boundedly; never KILL; no deletion if uncertain. |
| PROCESS_TERMINATED | Exact run absent or same-run terminal state | Revalidate complete NVM inventory and stopped heartbeat. |
| UNINSTALL_VALIDATED | Exact two-file inventory/hash/manifest and run checks pass | Explicit file removal only. |
| PARTIAL_UNINSTALL | Any delete succeeded but later step failed | No replay by this payload; manual review. |
| UNINSTALLED | Exact binary/manifest/final directory removed | Empty parent and stopped `/tmp` heartbeat deliberately retained. |
| MANUAL_REVIEW_REQUIRED | Any unclassified, conflicting, or uninspectable state | No automatic retry, cleanup, signal, or overwrite. |

The uninstall action requires a valid checksummed install COMPLETE transaction
and a *currently live* original PID/TGID/start/exe. It does not infer process
absence from an unreadable `/proc` entry or attempt post-reboot cleanup. It
validates the entire parent/final directory before TERM and again before any
persistent delete; TERM is preceded by an immediate identity check. It accepts
only proven absence or terminal state of the same run. It removes the explicit
manifest, binary and empty `w176` directory in order, stopping on the first
failure. The empty `geminitop` parent is retained because parent ownership
metadata was not persisted. The stopped heartbeat is retained because the
historical ARM binary has no kernel start-time field in its heartbeat; deleting
it cannot yet meet the stronger exact-run ownership standard. Retention is
safer than deleting a colliding `/tmp` object.

Each successful action creates an independent removable-USB transaction:
INCOMPLETE status at start, checked SHA-256 manifest of its exact result files,
and `COMPLETE` last. A transaction or late result failure never triggers NVM
rollback.

## Write budget and provenance limits

The unchanged ARM binary is **5,556 bytes** and has SHA-256
`57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6`.
The literal eight-line manifest is **260 bytes** with the current path/hash.
Final intended persistent user-data content is **5,816 bytes**, plus two
directory entries and YAFFS2 metadata. The private staging binary is renamed
into the final directory; intended peak file content is also 5,816 bytes,
with transient copy/manifest staging names and metadata. The host cannot
bound physical YAFFS2 flash-write amplification. Heartbeat and action reports
are volatile `/tmp` and removable USB respectively; no persistent log or boot
hook is installed.

Software cannot cryptographically prove the operator physically removed USB.
It can prove same process identity, heartbeat advancement and finite FD
detachment at verification. The physical-removal interval remains operator
provenance.

## Remaining blockers before a v2 review prompt or frozen candidate

The 28-case disposable Linux suite covers the clean cycle and selected
mount/producer/process/collision failures. It does **not** cover every required
failure injection from the independent review: FD disappear/replacement,
TGID and zombie mutation at each action boundary, PID reuse immediately before
TERM, ignored TERM, every interrupted stage, partial-delete recovery, and real
disposable nested/bind mount behaviour. The suite now checks late USB-result
hash failure and a first-file-delete partial uninstall, but not every variant.
The historical daemon's heartbeat has no kernel start-time field; exact-run
heartbeat ownership and post-TERM cleanup semantics require a reviewed design
decision. Changing the ARM binary would violate this task's exact-binary
retention gate until explicitly evaluated and rebuilt twice. Further full
historical regression and static ABI verification are also required after
these changes. Thus no v2 independent review prompt is issued and physical
Stage-4B remains **NO-GO**.

No stock file, init, Launcher, NVM `bin`/`lib`, MTD payload, CAN/MCU, network,
or boot-persistence path is intentionally touched. Host tests execute only
native stand-ins, never the target ARM binary.
