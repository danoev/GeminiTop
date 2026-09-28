# W176 Stage-4A CAN / MCU topology candidate

Status: the independently approved v5 candidate
`4161bc3b92d61e19751358fb2e210ebfa9c4e8b2` completed physically on
2026-09-28. The exact analyser passed with 22 checksums and returned CASE D —
UNKNOWN, with PARTIAL process-FD coverage. See
`w176-stage4a-physical-evidence.md`. Earlier failed and NO-GO candidates
remain historical in `w176-stage4a-physical-attempts.md` and
`w176-stage4a-v4-no-go.md`.

## Exact scope

The separately armed candidate observes the installed Linux vehicle boundary.
It captures only:

- bounded `/proc/net/dev` and `/sys/class/net` metadata;
- `stat`/`lstat`, symlink, major/minor, permission, and sysfs associations for
  `/dev/canbox_protocol_dev`, `/dev/hc_mcu_dev`, `/dev/can0`..`can7`, and
  `/dev/ttyS0`..`ttyS7`;
- bounded `/proc/<pid>/fd` symlink correlation over IDs 1..4096 and FD numbers
  0..127 **only for kernel-reported TGID leaders** whose status is live before
  and after the complete FD scan; TGID, PID start-time, FD-target, and safe
  FD-stat checks bracket positive owner metadata;
- process-level staging of owner FD rows and comm/cmdline/exe/maps: none are
  retained unless the whole leader scan passes post-scan lifecycle validation;
- a bounded checksum-covered process-leader roster so the analyser can verify
  `processes_inspected` exactly and require every owner to be a retained leader;
- explicit checksum-covered COMPLETE/PARTIAL process-FD coverage, with no
  negative ownership claim when any leader is uninspectable or races;
- bounded `comm`, `cmdline`, `exe` symlink, and `maps` only for matched
  production owners; and
- regular/non-symlink metadata preflight inside the physically confirmed
  read-only application SquashFS, then descriptor-verified bounded copies of
  installed
  `libappframework.so.1.0.0` and
  `libappmcucommunication.so.1.0.0` for off-target static analysis.

No candidate device is opened. No CAN frame is received or transmitted. No
MCU command, UART read, ioctl, interface change, logging change, process
attachment, library execution, or target-storage write is present.

## Independent NO-GO reproduction and disposition

All ten requested findings were reproduced against frozen candidate
`ff5eab20c8959863ff805a331775807c4ce80322` using disposable host fixtures:

1. an approved library FIFO blocked;
2. an approved library symlink to a FIFO blocked;
3. failed `sha256sum` with no output could false-COMPLETE;
4. failed `sha256sum` after valid-looking output could false-COMPLETE;
5. unchecked interface evidence could change classification and still PASS;
6. occupying all output names reused the base directory;
7. a parent-directory symlink escape passed analysis;
8. weak named-device/string evidence produced CASE B;
9. PID replacement after prevalidation retained replacement metadata under the
   original owner record; and
10. a broad `hc*` device name was enumerated.

The remediated library path rejects symlink, FIFO, socket, block/character
device, and directory types using metadata before any source descriptor open.
It computes the deepest path-component mount ancestor of each exact canonical
library path from bounded `/proc/self/mounts`, requires that mount to equal the
established application SquashFS (`ro`, never `rw`), rejects covering nested
mounts, and compares source/application `st_dev`. It repeats the effective
mount check inside the copy child and opens the canonical path only afterwards.
Under the stated normal/non-hostile stock-system
threat model, the read-only mount prevents pathname replacement between
preflight and open; descriptor/path identity and mutation checks remain after
open.

Every checksum command now runs separately from parsing, and nonzero, empty,
malformed, truncated, multi-field, and unexpected-path output fails closed.
The analyser derives dynamic owner evidence from the bounded inventory
and requires exactly one checksum for the complete canonical evidence set,
including the inventory, status, errors, optional findings, and final COMPLETE
contents. The checksum manifest cannot recursively checksum itself; its exact
path set and syntax are instead validated. This is consistency protection, not
authentication.

## Bounds

The candidate scans only numeric proc IDs 1..4096, accepts at most 256
confirmed process leaders for FD inspection, checks only FD numbers 0..127,
permits 4,096 existing FD links total
and 16 matched owners, and bounds maps to 64 KiB per owner and 512 KiB total.
It permits 32 interfaces from a 64-KiB `/proc/net/dev` snapshot, exactly 18
device path candidates, 4,096-byte symlink results, 384 KiB for
`libappframework`, 320 KiB for `libappmcucommunication`, 704 KiB of library
bytes total, and a 2-MiB **final capture acceptance** measurement, not an
aggregate write-admission ceiling. Every writer is individually bounded; the
complete audit and theoretical pre-acceptance byte bound are in the round-2
record. PIDs above 4096 and FD numbers above 127
are explicitly `NOT_INSPECTED`, not evidence of absence.

The frozen TGID-aware v4 candidate and its host fixture evidence are described
in `w176-stage4a-tgid-remediation.md`; the lifecycle follow-up is in
`w176-stage4a-lifecycle-remediation.md`. The installed library sizes confirmed by
Stage 2 (287,536 and 213,496 bytes)
fit those individual limits.

## Host validation

Disposable fixtures cover direct and symlinked library FIFOs with blocked-writer
sentinels, a directory source, source disappearance, invalid application mounts,
all checksum failure forms, incomplete manifests, output exhaustion, leaf and
parent symlinks, conservative classification, PID reuse/disappearance, FD
replacement/disappearance, metadata failure, stable owners, fixed enumeration,
numeric resource bounds, malformed schemas, and false-completion paths. The
macOS sandbox cannot create a character node or bind a Unix socket; both
fixtures run in the disposable privileged native Linux test environment.

## Evidence and handoff policy

- `interface.type=280` is **CONFIRMED** Linux ARPHRD_CAN metadata. It does not
  prove physical Mercedes CAN connectivity; bus, traffic, bitrate, and message
  semantics remain **UNKNOWN**. A virtual CAN interface is possible.
- an installed-library string is **CONFIRMED** only as a string in that exact
  returned library copy. Device names, production FD ownership, and strings may
  support `MCU_TRANSLATION_PATH: INFERENCE`; they do not prove live semantics.
- `CASE A` requires verified type 280. `CASE B` is not established by this
  capture. `CASE C` requires both constituents at their evidence threshold. If
  no type-280 interface exists, classification is `CASE D — UNKNOWN` with any
  secondary MCU inference kept separate.
- readlink equality and FD stat metadata reduce races but do not identify an
  immutable kernel open-file object. A changed bracket is discarded rather
  than attributed.
- `process_fd_coverage=PARTIAL` means one or more leaders/tasks could not be
  safely covered; retained owner paths are positive observations only. Even
  COMPLETE is limited to IDs 1..4096 and FDs 0..127, not global absence proof.

The real arming marker is absent. The v5 capture was COMPLETE and validated;
end-to-end installed CAN/MCU topology nevertheless remains UNKNOWN. No further
physical action is authorised by this result.
