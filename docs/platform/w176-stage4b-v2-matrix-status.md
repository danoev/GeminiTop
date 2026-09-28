# W176 Stage-4B v2 host matrix — incomplete, 2026-09-28

This is a coverage ledger, **not** an independent review or physical approval.
The 61 integration cases and 14 synthetic process/FD cases pass in disposable
Linux fixtures. Several test cases overlap. `PASS` below means the stated
host scenario was exercised; it is not evidence that vendor-kernel behavior
has been observed on the RoadTop. `PARTIAL` and `OPEN` block a frozen candidate.

| Requested scenarios | Host status | Evidence or missing part |
| --- | --- | --- |
| 1–8 exact/wrong NVM, node, sysfs, MTD | PASS | Clean cycle; wrong source, regular node, wrong major/minor, sysfs target, MTD number/name/size. Block-special positive case is still fixture-only, not a real MTD device. |
| 9–12 nested tmpfs/RO/YAFFS2/bind | PARTIAL | Synthetic mount and mountinfo rejects pass. Existing Stage-4A real tmpfs/bind regression passes, but Stage-4B has no privileged real nested/bind harness. |
| 13–18 producer status/format | PASS | Correct-output/nonzero and empty SHA, kernel, df, malformed/ambiguous df. |
| 19–27 source/copy/commit | PASS | Symlink, FIFO, hash, source mutation, short copy, staged/destination hash, manifest-write and final-rename faults. |
| 28–32 live/TGID/zombie/state/PID reuse | PARTIAL | Native live process plus synthetic TGID, zombie, invalid state and changed start ticks. Actual reuse around signal boundary remains untested. |
| 33 process exits inside identity bracket | OPEN | No controlled exit during the precise `/proc` bracket. |
| 34–37 duplicate/uninspectable/exe/start change | PASS | Native duplicate execution and synthetic unreadable exe, changed exe inode and changed start ticks. |
| 38–44 USB FD coverage | PARTIAL | Native clean FD and synthetic explicit USB FD, disappeared FD, failed/changed readlink, changed process, FD 128 rejection. No post-reinsertion native USB-FD regression yet. |
| 45–53 heartbeat ownership/schema | PARTIAL | Exact running heartbeat, wrong PID/start/build, stale sequence, malformed, duplicate/extra keys pass. Different-run collision is simulated by wrong start; schema mismatch and real collision race remain open. |
| 54 USB output write failure after launch | PARTIAL | Late hash/result failure leaves NVM and process intact; direct write failure still open. |
| 55–58 hash/STATUS/COMPLETE/uncertain launch | PASS | Injected hash, COMPLETE and STATUS commit failures; launch uncertainty retains NVM; one-shot replay refused. |
| 59–64 verify same run/restart/sequence/duplicate/no relaunch | PARTIAL | Clean survive/advance, stale sequence, duplicate and dead-process no-relaunch pass. A real replacement/reuse at verify boundary remains open. |
| 65 USB FD present after reinsertion | OPEN | No native verify-path injection for this boundary. |
| 66–67 normal and ignored TERM | PASS | Both native host processes exercised; ignored TERM leaves installation intact. |
| 68–70 PID reuse, zombie, identity change immediately before TERM | OPEN | Earlier start/record mismatch and synthetic zombie checks do not inject the precise pre-TERM races. |
| 71 duplicate before TERM | PASS | Native second execution causes uninstall to stop without signaling or deleting. |
| 72 live uninspectable process before TERM | PARTIAL | Synthetic full-scan rejection passes; exact uninstall boundary not injected. |
| 73–80 inventory/collision/partial delete | PARTIAL | Unexpected file/dir/symlink, manifest/binary tamper, wrong heartbeat, first-delete partial failure and final-directory removal failure pass. A post-TERM heartbeat collision race remains open. |
| 81–82 parent creation/copy interruption | PASS | Both interrupted stages fail incomplete and preserve NVM; parent case replay refused. |
| 83 interrupted after staged hash | OPEN | Hash mismatch is tested, but not interruption after a valid staged hash. |
| 84 interrupted after manifest | PARTIAL | Final rename failure preserves staged manifest; signal interruption/replay at this exact boundary remains open. |
| 85 interrupted after final commit before launch | PARTIAL | Launch failure preserves committed files; signal interruption at this exact boundary remains open. |
| 86 interrupted after launch before USB result | PARTIAL | Late result hash, STATUS and COMPLETE failures preserve the running process; direct signal/output-write interruption not covered. |
| 87 interrupted after TERM | OPEN | Ignored TERM and failed post-TERM validation are not a controlled interruption at this boundary. |
| 88 interrupted after first uninstall delete | PARTIAL | First-delete success/second-delete failure stops with partial NVM tree; signal interruption/replay at the boundary is not covered. |

The 88 entries are not 88 passing tests. This ledger intentionally avoids
turning related fixture tests into invented one-to-one proof. A new frozen
implementation SHA and review prompt remain prohibited until every `PARTIAL`
and `OPEN` item relevant to the physical path is closed and independently
audited. No target ARM code was run or emulated.
