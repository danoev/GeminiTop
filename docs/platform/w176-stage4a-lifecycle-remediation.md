# Stage-4A leader lifecycle and ownership-coverage remediation

The exact frozen TGID-aware v4 candidate
`d0f5d7ad651953f607414de956f24bff2d8889f9` received an independent
NO-GO for false clean ownership coverage after a process leader exits while
workers remain alive. The review record is `w176-stage4a-v4-no-go.md`. This
revision preserves TGID leader-only enumeration, the 1..4096 numeric scan,
FDs 0..127 and the 16-unique-owner bound. No vehicle action or target ARM
execution was part of this remediation.

## Bounded task-state model

Each accessible `/proc/<id>/status` is copied with at most three 4,096-byte
read records; no more than 8,192 bytes are admitted. One parse of that bounded
snapshot requires exactly one numeric `Tgid:` and exactly one well-formed
one-letter `State:` record with a parenthesized description. Missing,
duplicate, malformed or oversized status is an OPTIONAL coverage gap. Only
`R`, `S`, `D`, `T`, `t` and `I` are admitted as inspectable live states for a
leader. `Z`, `X`, `x` and any unknown code are uninspectable, not clean zero-FD
observations. This is deliberately conservative for the installed Linux 4.9
family. A non-leader (`id != Tgid`) is still skipped without FD inspection.
An in-range TID with out-of-range TGID is not followed and leaves coverage
PARTIAL; IDs above 4096 remain NOT_INSPECTED.

For a leader, the collector reads live state and start time before considering
its FD directory, requires that directory to be real/readable/searchable, and
then scans the unchanged finite FD range. It stages candidate FD rows and one
bounded comm/cmdline/exe/maps group without publishing them. Each matched FD
retains its before/after TGID/live-state/start-time, symlink-target and safe
FD-stat checks. After the entire FD range, status and start time are reread.
Only the same live leader with an available FD directory can increment
`processes_inspected`, enter the checksum-covered leader roster, contribute
`fd_links_inspected`, and commit its staged owner group. If any lifecycle or
FD race makes the process scan incomplete, all staged owner evidence for that
leader is discarded; another stable process's positive evidence is unaffected.
A stable live process with no candidate FD still counts as inspected.
At most one leader staging group is active: FD rows have a 16,384-byte temp
cap, while the existing per-owner metadata caps, aggregate maps bound, final
2,048-KiB acceptance check and per-file emergency ceiling remain. As before,
the collector does not claim a bound on cumulative USB write volume.

The shell transaction is race-reducing, not an atomic kernel snapshot. A
process can change just after the post-scan check, and an FD table not shared
with the leader is outside this leader-only observation model. The result is
therefore bounded metadata evidence, never a global proof of ownership
absence.

## Coverage and analyser contract

SUMMARY schema 4 adds checksum-covered
`process_fd_coverage=COMPLETE|PARTIAL`. A bounded OPTIONAL record for an
unusable status, leader state/FD directory, PID/TGID/start-time change, or FD
race forces PARTIAL. The analyser cross-checks this field against the
coverage-relevant OPTIONAL records, requires the leader roster count to equal
`processes_inspected`, and retains the existing owner/inventory/checksum
constraints. Its result exposes `process_fd_owner_coverage`. For PARTIAL it
returns `ownership_absence_claim=NOT_AVAILABLE` while preserving positive
owner paths from other fully validated leaders. For COMPLETE it still says
`NOT_ESTABLISHED_BEYOND_REVIEWED_SCAN`, because IDs >4096, FDs >127 and
thread-specific unshared descriptor tables are not covered. A checksum-valid
coverage-field contradiction is rejected before CASE classification.

## Independent LOW findings

The effective library mount guard now counts only nonempty real mount records,
so exactly 1,024 valid records pass with or without a final newline. The hard
1,024-record, 4,096-byte-line and 131,072-byte table bounds remain; 1,025
records, overlong lines and malformed records fail. `bounded_readlink` now
removes both its temp file and `.value` companion on success or failure, and
the final explicit cleanup includes each fixed readlink pair. No wildcard
deletion was introduced.

## Host evidence and unresolved target question

The native Linux regression starts a host-native multithreaded helper: its
worker holds a harmless fixture FD while the main thread exits. The host
kernel reports leader `State: Z`; `/proc/<leader>/fd` exists but lists no
entries, while `/proc/<worker-tid>/fd` still exposes the fixture FD. The full
collector uses that native container `/proc` and produces a checksum-valid
COMPLETE qualified as PARTIAL; the exited leader is absent from the inspected
roster and owner records, and the analyser makes no negative ownership claim.
Synthetic injection covers pre-scan terminal states, transitions before and
during FD enumeration, post-scan exit/disappearance/reuse/TGID changes,
staged-owner discard, stable zero-match and positive-owner controls, 16/17
owner bounds, malformed State, and the two LOW cases. These are host tests,
not installed-RoadTop validation. The actual installed process lifecycle and
time to finish a revised capture remain UNKNOWN until separately reviewed and
authorised physical observation.

USB activity LED silence is not proof of completion. The off-target acceptance
gate remains returned STATUS, exact checksums, COMPLETE last, and analyser
PASS with the coverage qualification read explicitly.
