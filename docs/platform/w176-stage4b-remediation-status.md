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
closed. The current host-only revision additionally requires a non-symlink
block-special `/dev/mtdblock12`, compares its `st_rdev` major/minor with
`/sys/class/block/mtdblock12/dev`, checks that `/sys/dev/block/<major>:<minor>`
resolves to that same block-class object, and requires
`/sys/class/mtd/mtd12/{name,size}` to be `nvm` and 8,388,608 bytes. Linux's
[MTD block driver](https://github.com/torvalds/linux/blob/master/drivers/mtd/mtdblock.c)
sets block `devnum` from `mtd->index`; this is a kernel-source relationship,
not a fresh observation of the installed vendor kernel. The mount table,
`/proc/mtd`, node, and sysfs checks must all agree before first write.

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

| State | Persistent shape; possible process | Next action | Retry install / verify / uninstall / auto-delete | Manual-review trigger |
| --- | --- | --- | --- | --- |
| PRE_INSTALL_CLEAN | No private parent; no proof process or heartbeat | First separately armed install | YES / NO / NO / NO | Any conflicting object/process |
| STAGING_CREATED | Parent and empty private staging; no launch intended | Stop and inspect off-target evidence | NO / NO / NO / NO | Interrupted parent/stage creation |
| STAGING_BINARY_COMPLETE | Staged temporary or renamed binary; no launch intended | Stop and inspect | NO / NO / NO / NO | Interrupted/short/changed copy |
| STAGING_VERIFIED | Staged binary and manifest; no launch intended | Stop and inspect | NO / NO / NO / NO | Interrupted pre-commit rename |
| INSTALL_COMMITTED_NOT_LAUNCHED | Final binary/manifest; no proven process | Preserve installation | NO / NO / NO / NO | Interrupted post-commit, pre-launch |
| PROCESS_LAUNCHED_UNVERIFIED | Final files; zero/one/multiple or uncertain processes | Preserve files and uncertain run | NO / NO / NO / NO | Any launch, PID, FD, heartbeat, or USB-result uncertainty |
| PROCESS_VERIFIED_USB_ATTACHED | Final files; exactly one bound live process | Finish install USB transaction | NO / NO / NO / NO | COMPLETE or output transaction fails |
| USB_REMOVAL_VERIFICATION_PENDING | Final files; install COMPLETE, process may be live | Operator removal/reinsertion, then separately armed read-only verify | NO / YES / conditional* / NO | Original run cannot be rebound |
| RESIDENCY_VERIFIED | Final files; one same live run after USB return | Separately armed uninstall if desired | NO / YES / YES / NO | Identity, inventory, or heartbeat changes |
| STOP_REQUESTED | Final files; original run may remain live | Bounded TERM-only observation | NO / NO / NO / NO | Ignored TERM, reuse, or unreadability |
| PROCESS_TERMINATED | Final files; original run absent or terminal | Recheck no matching live process, complete inventory, stopped heartbeat | NO / NO / NO / NO | Duplicate, collision, or uncertain coverage |
| UNINSTALL_VALIDATED | Final two files checked; no matching live execution | Explicit manifest, binary, empty-final-directory removal | NO / NO / NO / NO | Any mutation/pre-delete recheck fails |
| PARTIAL_UNINSTALL | Some allowlisted files absent; no automatic assumptions | Manual recovery only | NO / NO / NO / NO | Any failure after first persistent delete |
| UNINSTALLED | Final directory/files absent; empty parent retained; stopped `/tmp` heartbeat may remain | No automatic action | NO / NO / NO / NO | Unexpected remaining persistent object |
| MANUAL_REVIEW_REQUIRED | Any unexpected shape or uncertain process | Stop; separately design recovery | NO / NO / NO / NO | Unknown/colliding objects or lost transaction |

*Uninstall is allowed only when the original checksummed install transaction,
exact currently live run, exact inventory, heartbeat, and unique-process scan
all validate. A separate successful verify transaction is not presently an
uninstall prerequisite; loss of the original run blocks this payload.

The uninstall action requires a valid checksummed install COMPLETE transaction
and a *currently live* original PID/TGID/start/exe. It does not infer process
absence from an unreadable `/proc` entry or attempt post-reboot cleanup. It
validates the entire parent/final directory before TERM and again before any
persistent delete; TERM is preceded by an immediate identity check and a
bounded leader scan must find exactly one execution of the installed inode.
It accepts only proven absence or terminal state of the same run, followed by
a bounded scan finding no remaining matching live execution. It removes the explicit
manifest, binary and empty `w176` directory in order, stopping on the first
failure. The empty `geminitop` parent is retained because parent ownership
metadata was not persisted. The stopped heartbeat is intentionally retained:
even with the v2 PID/start-ticks binding, deleting a volatile object is
unnecessary for proving persistent-file cleanup and could race an unrelated
writer. A collision or ambiguous ownership causes uninstall to stop before
persistent deletion.

Each successful action creates an independent removable-USB transaction:
INCOMPLETE status at start, checked SHA-256 manifest of its exact result files,
and `COMPLETE` last. A transaction or late result failure never triggers NVM
rollback.

## Write budget and provenance limits

The proposed v2 ARM binary is **5,556 bytes** and has SHA-256
`684afd86a067a6e175ed6b7d6c2a0281f1d44c67f62d86431589d1d7bd8c41b8`.
Its historical predecessor was also 5,556 bytes, SHA-256
`57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6`.
The literal v2 eight-line manifest is **260 bytes** with the current path/hash.
Final intended persistent user-data content is **5,816 bytes**, plus two
directory entries and YAFFS2 metadata. The private staging binary is renamed
into the final directory; intended peak file content is also 5,816 bytes,
with transient copy/manifest staging names and metadata. The host cannot
bound physical YAFFS2 flash-write amplification. Heartbeat and action reports
are volatile `/tmp` and removable USB respectively; no persistent log or boot
hook is installed.

The pinned official Arm GNU A-profile 9.2-2019.12 archive SHA-256 is
`9f333ede9ba09d1bd266e110c1a0b69aa0fd4543696b5132ff238c20124b0dcb`;
the Linux/arm64 Debian base is pinned at
`sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251`.
The build script checks archive SHA-256 and published MD5, compiles in two
separate clean output directories, and requires byte-identical results.
Static readelf/objdump inspection of the v2 binary reports ELF32 little-endian
ARMv7-A EABI5 hard-float, VFP-register arguments, interpreter
`/lib/ld-linux-armhf.so.3`, one NEEDED entry (`libc.so.6`), only
`GLIBC_2.4`, no RPATH/RUNPATH, non-executable GNU stack and GNU RELRO.
Undefined dynamic imports are `read`, `unlink`, `sigaction`, `rename`,
`getpid`, `memset`, `sigemptyset`, `nanosleep`, `open`, `snprintf`, `write`,
`abort`, `close`, `__libc_start_main`, `__errno_location`, plus the weak
`__gmon_start__`. The only `/proc` string is `/proc/self/stat`; static string
audit found no vehicle-device, socket or stock-launcher access string. This is
static loadability evidence, not physical v2 execution evidence.

Software cannot cryptographically prove the operator physically removed USB.
It can prove same process identity, heartbeat advancement and finite FD
detachment at verification. The physical-removal interval remains operator
provenance.

## Remaining blockers before a v2 review prompt or frozen candidate

The v2 daemon itself records its kernel start ticks once at startup and emits
the seven-key heartbeat `schema`, `process`, `build`, `pid`, `start_ticks`,
`state`, `sequence`. The installer and verifier require a running heartbeat
with PID/start matching the checked live process, and the uninstaller requires
that same exact run before TERM plus its stopped heartbeat before deletion.
The two host suites currently contain 61 integration and 14 synthetic
process/FD cases; overlapping cases must not be counted as 75 distinct
requirements. See `w176-stage4b-v2-matrix-status.md` for the numbered
scenario ledger. The full 88-scenario failure matrix has **not** yet passed: outstanding
coverage includes native FD/process races at exact action boundaries (although
synthetic FD disappearance/replacement and TGID/zombie cases pass), PID
reuse immediately before TERM, some late USB transaction failures,
interruption/replay at every staging/deletion boundary, and privileged real
nested/bind mounts. No target-side sysfs presentation has been checked for
this revision. Accordingly there is still no frozen v2 implementation SHA,
no v2 independent Work prompt, and physical Stage-4B remains **NO-GO**.

No stock file, init, Launcher, NVM `bin`/`lib`, MTD payload, CAN/MCU, network,
or boot-persistence path is intentionally touched. Host tests execute only
native stand-ins, never the target ARM binary.
