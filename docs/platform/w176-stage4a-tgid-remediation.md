# Stage-4A process/TGID ownership remediation

The approved historical physical candidate
`17557e6481d68799712779ca605b87e2da866e47` failed closed at
`owner_limit` on its second operator-reported attempt. See
`w176-stage4a-physical-attempts.md`. Its partial serial/network material is not
validated topology evidence.

## Root cause and provenance

The frozen collector probed `/proc/1` through `/proc/4096` and counted every
accessible numeric path with a candidate FD as a separate owner. It did not
read kernel TGID. [proc_pid_task(5)](https://man7.org/linux/man-pages/man5/proc_pid_task.5.html)
establishes that `/proc/<tid>` for non-leaders is directly addressable even
though it is absent from directory iteration.
[proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html)
defines `Tgid` as process/thread-group ID and `Pid` as thread ID.

The durable `reproduce_tgid_owner_limit.py` runs exactly that frozen shell from
Git against disposable host fixtures. One leader TGID 700 with 20 non-leader
TIDs produced `matched_owners=17`, included TID 701 as an owner, and failed
closed at `owner_limit`. This **CONFIRMS the implementation defect**. It does
not prove the TGID of every numeric identity in the incomplete physical return;
those raw TGID records were not provided. Its contribution to that particular
physical failure remains a strong **INFERENCE** pending a valid capture.

## New process model

The candidate preserves the exact numeric scan 1..4096. For each accessible
numeric proc directory, it makes at most three 4096-byte read records from
`/proc/<id>/status` (12288 attempted bytes), admits at most 8192, and parses
exactly one numeric `Tgid:` line. Multiple bounded records accommodate short
proc reads without one-byte-at-a-time writes to removable FAT storage.
Malformed, missing, duplicate, oversized, vanished, or invalid status is a
bounded OPTIONAL skip; it cannot produce owner evidence. An in-range TID with
TGID above 4096 is OPTIONAL `pid_tgid_outside_scan`; it never follows that
out-of-range path. A valid ID with `id != Tgid` is a non-leader and does not
consume process count, scan FDs, use an owner slot, or capture metadata.

Only `id == Tgid`, with a safely read start time and an available leader FD
directory, enters FD inspection. `processes_inspected` counts those inspected
process leaders, not every addressable TID or unavailable leader.
`MAX_PROCESSES=256`, `MAX_OWNERS=16`, FD numbers 0..127, global FD link
limit 4096, and PID scan 1..4096 remain unchanged. Each leader gets one bounded
checksum-covered `processes/leaders.txt` row `PID|TGID|start`. Before a matched
FD, ownership is tied to leader TGID/start, FD number, symlink target, and
safe FD-stat metadata. After bounded comm/cmdline/exe/maps collection, TGID,
start time, FD target, and FD-stat are reread. Changed/disappeared identity is
discarded and recorded OPTIONAL with no unbounded retry.

`processes/owners.txt` now records
`PID|TGID|start|FD|candidate_path`. The same PID may have multiple FD rows,
but only one metadata group and one owner slot. Same comm or executable paths
never deduplicate separate leaders. SUMMARY and STATUS are schema 3;
CAPABILITIES is schema 4 with `owner.identity=PID_EQUALS_TGID`.
The prior round-2 writer table describes its frozen candidate: this revision
adds a 16,384-byte final leader-roster cap and bounded status/TGID staging
(at most 12,288 bytes written and 8,192 admitted for status, then 21 bytes
for the parsed TGID). The 2,048-KiB final acceptance
check and per-file emergency ceiling remain; total USB write volume is still
not claimed as bounded.

The offline analyser requires exactly one checksum-covered leader row per
`processes_inspected` leader, PID==TGID, unique bounded PIDs, consistent start
time across roster and owner records, each retained owner present in the roster,
at most 16 owner groups, exact four metadata files per owner, and no duplicate
PID/FD identity. It rejects checksum-valid inflated counts or non-leader owner
rows before producing a CASE. Checksums still provide consistency, not
authentication of a deliberately rewritten capture.

## Coverage and runtime implications

Ordinary pthreads sharing a descriptor table expose the same FDs through the
leader's `/proc/<TGID>/fd`. The native Linux host fixture verifies a live
non-leader `/proc/<tid>/status` reports the common TGID and its FD symlink
agrees with the leader's. Thus a leader with 20 ordinary threads needs one
128-FD-number scan instead of up to 21. The physical runtime improvement is
an **INFERENCE**, not a target measurement.

This policy is intentionally not a claim of exhaustive thread-specific FD
coverage. [clone(2)](https://man7.org/linux/man-pages/man2/clone.2.html)
explains descriptor-table sharing is controlled by `CLONE_FILES`, and
[proc_pid_fd(5)](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html)
notes that `/proc/<pid>/fd` may be unavailable after the main thread exits.
A leader FD directory that is absent/non-directory is recorded OPTIONAL
`leader_fd_unavailable`. Neither an unavailable leader nor a process using
unshared thread-specific FDs proves absence of candidate ownership. The
collector does **not** fall back to thread-by-thread scanning, which would
reintroduce inflation and expand the reviewed scope. IDs above 4096 remain
NOT_INSPECTED; processes lacking usable TGID remain not observed.

No target timestamp was added: a reliable, already reviewed stock monotonic
clock command has not been established. USB activity LED silence is not a done
signal. Only returned STATUS, checksums, COMPLETE and successful host analyser
validation establish a complete transaction.

## Host validation

The permanent matrix models one leader/20 threads, two leaders/many threads,
one owner with two candidate FDs, 16 genuine owners, 17 genuine owners,
malformed/missing/duplicate/nonnumeric/oversized status, TGID change, TID
disappearance, leader absence, leader PID reuse, out-of-range TGID, two
distinct leaders with the same exe/comm, and checksum-valid inconsistent
leader/owner evidence. A physical-like Launcher/gocsdk fixture with worker
TIDs and ttyS candidate links must reach both library snapshots, inventory,
checksum manifest, clean STATUS and final COMPLETE, then pass the analyser.

All previous Stage-4A safety remediations remain required: exact device
allowlist, bounded sysfs/proc metadata, no candidate device stream open,
effective read-only library mount proof, special-file rejection, canonical
checksums, and fail-closed COMPLETE-last transaction. The new code neither
receives/transmits CAN nor reads MCU/UART streams, touches NVM, runs ARM code,
or modifies Stage-4B.
