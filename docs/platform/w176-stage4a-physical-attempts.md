# W176 Stage-4A physical attempts — operator-returned evidence

Recorded 2026-09-27 from the operator's report. This repository session did not
inspect the original removable FAT filesystem or original raw result objects.
The exact independently approved and physically used Stage-4A candidate was
`17557e6481d68799712779ca605b87e2da866e47`; its Git history is preserved.

## Attempt 1 — operator interrupted

The operator removed the USB before the transaction finished. Returned status
was `INCOMPLETE`, `mandatory_failures=0`, `optional_findings=0`. Temporary
owner-capture files around PID/TID 791 were observed. This establishes neither
completion nor a topology classification and is retained only as historical
operator-interruption evidence.

## Attempt 2 — deliberate fail-closed completion

The operator left the capture running for approximately ten minutes; USB
activity later stopped. Returned values:

```text
status=INCOMPLETE
mandatory_failures=3
error.1=owner_limit
error.2=required_output_invalid:files/libappframework.so.1.0.0
error.3=required_output_invalid:files/libappmcucommunication.so.1.0.0
processes_inspected=130
fd_links_inspected=567
matched_owners=17
library_bytes=0
owners.max=16
```

`owner_limit` is the primary reported failure. Library copies were not reached
because the mandatory failure had already occurred; their required-output
errors are downstream. No valid `COMPLETE` was returned. This is a **failed
Stage-4A transaction**, not a successful topology capture. The fail-closed
response is consistent with the reviewed collector logic; it does not validate
any partial classification.

## Preliminary material — not validated Stage-4A topology

The incomplete capture showed separate numeric identities with Launcher and
gocsdk-related names, including 717, 762, 765, 766, 767, 782, 785, 790 and
781, 783, 784, 786, 787, 788, 789, 791 respectively. Executable symlinks
appeared to resolve to installed Launcher and gocsdk. Preliminary candidate
FD destinations included `/dev/ttyS4`, `/dev/ttyS1`, and `/dev/ttyS2`. A
partial network view mentioned `apple_usb0`, `sit0`, `lo`, and `wlan0`, without
an observed type-280 CAN interface.

All of this is **PRELIMINARY / FROM AN INCOMPLETE TRANSACTION**. Equal
executable paths or similar thread names do not establish a common TGID.
Neither CAN absence nor MCU routing is confirmed. None of these values belongs
in the physical target profile or the illumination/CAN workstream as validated
topology evidence.

## Engineering implication

The approved collector probes numeric `/proc/<id>` paths without distinguishing
process leaders from non-leader threads. Linux permits direct lookup of
`/proc/<tid>` for non-leaders, and `/proc/<id>/status` reports `Tgid`. Thus the
old design can count threads as separate owners; a host reproduction is required
to demonstrate this mechanism against the frozen source. Whether each reported
physical identity was a non-leader remains **UNKNOWN** without its returned
TGID. The association of that mechanism with this specific physical failure is
an **INFERENCE**, not a validated topology fact.

Primary Linux references: [proc_pid_task(5)](https://man7.org/linux/man-pages/man5/proc_pid_task.5.html)
documents usable `/proc/tid` paths that do not appear in directory listings;
[proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html)
defines `Tgid` as thread-group/process ID and `Pid` as thread ID.

## Operator completion rule

A stopped USB activity LED is **not** proof of completion: much of the scan
reads `/proc` and `/sys` without writing continuously to USB. After USB removal,
success requires off-target inspection of `STATUS.txt`, `checksums.sha256`,
and `COMPLETE`, followed by successful host-analyser validation. Never infer
success from elapsed time, LED state, partial files, or an `INCOMPLETE` status.
