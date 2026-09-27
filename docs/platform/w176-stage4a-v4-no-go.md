# Stage-4A v4 independent NO-GO — exited leader coverage

The independently reviewed frozen v4 candidate was
`d0f5d7ad651953f607414de956f24bff2d8889f9`. The user returned the
independent verdict **PHYSICAL STAGE-4A TOPOLOGY CAPTURE: NO-GO**. No vehicle
action occurred during that review. This is a separate review finding from the
earlier operator-returned physical `owner_limit` failure, recorded in
`w176-stage4a-physical-attempts.md`. No valid installed-unit topology capture
exists.

## HIGH — exited leader can look like a clean zero-FD inspection

The v4 collector correctly selected kernel TGID leaders instead of counting
each addressable thread. It nevertheless incremented `processes_inspected`
before finishing the leader FD scan and checked only whether
`/proc/<leader>/fd` was a directory. A multithreaded process whose main thread
has exited can still have a live worker with an open FD while the leader status
is `Z` and its existing FD directory has no available entries. The old code
could therefore count the leader, retain zero owners, and produce a clean
COMPLETE. The independent review reproduced `processes_inspected=1`,
`fd_links_inspected=0`, `matched_owners=0` for this case. This is a false
process-ownership absence implication, not evidence that no worker owns an FD.

Linux documents that the leader FD directory contents are unavailable after
the main thread exits: [proc_pid_fd(5)](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html).
The status fields `State` and `Tgid` are documented by
[proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html).
The independent native-Linux reproduction is **CONFIRMED review evidence** as
reported by the user. The subsequent implementing-session native fixture is
kept separately in `test_00_native_lifecycle.py`; it is host evidence, not
physical RoadTop evidence.

## LOW — two fail-safe compatibility/cleanup defects

The prior mount guard counted a heredoc-added empty line as a 1,025th record
when exactly 1,024 valid records already ended in a newline. It rejected that
mount table safely but unnecessarily. The guard should count real nonempty
records without loosening the 1,024-record, 4,096-byte-line, or total-input
bounds.

A malformed FD readlink could leave `.fd-link-before.tmp.value`. The analyser
rejected this undeclared scratch file, so it was fail-safe, but could waste an
otherwise qualified capture. Explicit cleanup of each bounded-readlink temp
pair is required on success, failure and finalisation.

## Evidence posture

V4's bounded TGID parsing, leader-only policy, 16-owner limit, finite 0..127
FD scan, validated library snapshots, final transaction, checksum/schema
checks, and conservative CASE policy remain valuable and must not be undone.
The remedy is bounded leader state/lifecycle bracketing plus explicit PARTIAL
ownership coverage, not per-thread FD enumeration or a raised owner limit.
An `INCOMPLETE` physical transaction or a later host-only PASS cannot establish
vehicle CAN/MCU topology.
