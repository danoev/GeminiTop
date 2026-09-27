# Stage-4A second NO-GO remediation — host evidence

Date: 2026-09-27. Branch: `feature/w176-stage4`.
Starting SHA: `82b7d36fce4428ed91eabe4013c95917ce4662d2`.
Previous frozen NO-GO: `11376fc13f61cf0f05a3bfd45ab287e5f42982d0`.
No physical action, target access, ARM execution/emulation, device-stream access
or NVM write occurred. Stage-4B is frozen byte-for-byte against the starting SHA.

## Reproduction before remediation

`tools/w176-stage4-topology/reproduce_round2.py` reads the exact frozen
collector, analyser, and fixture implementation through `git show`. All 13
requested disposable-fixture reproductions were **REPRODUCED**:

| Finding | Frozen result |
| --- | --- |
| STATUS hash nonzero/empty | False COMPLETE |
| STATUS valid-looking hash then nonzero | False COMPLETE |
| STATUS malformed digest | False COMPLETE |
| Writable nested application/lib mount | Accepted |
| Nested mutable mount + pathname/FIFO swap | Open sentinel tripped |
| Normal proc/mounts symlink | Rejected |
| Normal class/net/can0 symlink | Type 280 lost |
| processes_inspected=999999 | Accepted |
| OPTIONAL count mismatch | Accepted |
| 17 dynamic owner groups | Accepted |
| Aggregate maps above 524288 bytes | Accepted |
| Conflicting owner start times | Accepted |
| Output size property | Post-collection, not admission |

This models defects, not the installed target's topology.

## Final transaction

`final_transaction` makes every late mandatory step immediately fail closed.
STATUS is written COMPLETE, hashed with separately checked command exit status
and strict digest/path parsing, and followed by a clean failure-count gate.
The exact 11-byte `complete=1\n` temporary object is validated and hashed under
logical path `COMPLETE`. Checksum temporaries are removed and the manifest
committed. Required objects, empty ERRORS, STATUS reparse, final output size,
and temporary cleanup must all succeed. A final `FAILURES==0` gate immediately
precedes renaming that exact hashed temp to COMPLETE. The rename is the last
required operation; only exit zero follows. Any failure leaves no COMPLETE.

The permanent matrix individually substitutes failure for STATUS write/hash,
COMPLETE temp write/size/content/hash, checksum cleanup/manifest commit,
required-file validation, ERRORS check, STATUS reparse, final size measurement/
parse/read/limit/cleanup, final temp validation, destination absence, and
COMPLETE rename. A separately injected late recorded failure tests the final
gate. STATUS hashing additionally tests nonzero empty, nonzero valid-looking,
malformed, truncated, and extra-path output.

## Effective mount and trusted kernel topology

Production source: **/proc/self/mounts**. The helper reads at most 131073 bytes
using one-byte bounded reads (no short-read truncation assumption); a sentinel
preserves trailing newlines when testing the 131072-byte table bound. Parsing
allows at most 1024 records and 4096 bytes per line, six mount fields, absolute
mountpoints, and rejects escaped mountpoints conservatively. Even unrelated
escaped mountpoints stop capture; this is a compatibility limitation, not
loose escape decoding.

For each library, safe directory canonicalisation produces the exact path.
The deepest mount ancestor is selected using equality or `mountpoint + "/"`,
not lexical prefix alone. Its mountpoint must equal canonical application
root; the unique application record must be SquashFS, ro and not rw. Every
covering nested mount is rejected, including read-only and same-device bind
mounts. Source and application `st_dev` must match. The same helper runs in
the child immediately before PREOPEN metadata and the single data open, which
uses the canonical pathname. The normal, non-hostile stock-system assumption
still excludes privileged mount/path tampering between validation and open:
this is not a Linux openat/O_NOFOLLOW atomic defence against hostile root.

The proc symlink belongs to trusted kernel topology, not returned capture
evidence. No capture-tree symlink prohibition is relaxed. Sysfs class links
are resolved through metadata-only directory operations, and must land within
canonical `/sys/devices/`. Only the six bounded ordinary attributes are read;
missing ones become OPTIONAL. Out-of-root class links fail closed.

## Independent analyser consistency

After canonical checksum validation and before classification, enforce all
summary ceilings (32 interfaces, 18 devices, 256 processes, 4096 FD links,
16 owners, 720896 library bytes). Interface/device/group counts and actual
library bytes must match SUMMARY. Scan counts cannot be smaller than retained
owner evidence. OPTIONAL rows have sequential indices and bounded nonempty
details, and STATUS's count must match them. One PID has one start time; one
PID/FD has one identity. Inventory declares exactly four owner files per PID,
and groups must match owners.txt. Per-owner and aggregate maps limits are
independently enforced. Device allowlist/duplicates, interface duplicates,
library limits, exact capability schema/values, and unexpected evidence files
remain fail-closed. The analyser also rejects logical final bytes above 2 MiB;
copied captures do not preserve FAT allocation, so that is not a reconstruction
of target du allocation.

CASE A still means only ARPHRD_CAN/type 280; vehicle connectivity, traffic,
bitrate and semantics remain UNKNOWN. MCU translation remains INFERENCE.

## Writer audit — Option B

CAPABILITIES schema 3 exposes:

```text
output.final_capture.kib.max=2048
output.write_ceiling=NOT_CLAIMED
all_writers.individually_bounded=1
```

The collector retains the final 2048-KiB du acceptance check (including late
control records). It does **not** claim aggregate write admission or cumulative
write-volume control. Bounded appends admit a complete record only if the
destination remains within its individual byte cap.

| Writer / final object | Byte cap |
| --- | ---: |
| proc-net-dev | 65536 |
| interfaces | 262144 |
| devices | 65536 |
| owners.txt | 131072 |
| owner comm | 4096 each ×16 =65536 |
| owner cmdline | 16384 each ×16 =262144 |
| owner exe | 4097 each ×16 =65552 |
| owner maps | 65536 each; aggregate 524288 |
| framework library | 393216 |
| MCU library | 327680 |
| inventory | 131072 |
| OPTIONAL | 65536 |
| ERRORS | 65536; zero bytes for successful COMPLETE |
| SUMMARY | 4096 conservative cap; fixed bounded counters |
| CAPABILITIES | 16384 conservative cap; fixed constants/counters |
| STATUS | 4096 conservative cap; fixed bounded counters |
| checksums | 65536 |
| COMPLETE | exactly 11 bytes; conservative analyser cap 64 |

Summing the conservative final object caps with zero ERRORS and the 64-byte
COMPLETE allowance yields **2,449,488 logical bytes** before aggregate final
acceptance. These maxima cannot all survive the separate 2-MiB final check.
Directory/FAT allocation overhead is not included in this logical sum.

All collection reads specify counts/lengths. Interface names are ≤15 bytes;
device paths are exactly 18; PID/FD scans are finite; start times are ≤20 digits;
diagnostic details are ≤256 bytes. Inventory/checksum/control appends are capped.
No output loop has an unbounded iteration range.

Temporary writers: bounded text staging uses LIMIT+1 (≤65537); interface raw/
normal uses ≤4097; readlink/value ≤4097; proc stat ≤8193; library staging is
bounded by its library limit before copy; owner staging by the individual
owner limits+1; mount-table memory ≤131073; checksum parse output normally
≤512/65; checksum path-state ≤65536; candidate-state ≤65536; owner-state
≤4096; COMPLETE temp exactly 11. Fixed parsing/control/du intermediates read
bounded input or finite kernel/tool metadata. In addition, the collector sets
`ulimit -f 1024` before USB output, providing a conservative **≤1 MiB per
regular output file** emergency ceiling across 512/1024-byte shell units,
including unexpectedly verbose diagnostic commands. Failure of this setup
stops capture. This is not a global cap.

There is only one library and one owner staging group active at a time.
Race-discard cleanup includes owner link-value staging; failure becomes
mandatory and ends scanning. Temporary names have finite fixed sets plus the
bounded numeric owner group. No wildcard cleanup is added. Failed transactions
may retain bounded staging for diagnosis, and total USB write volume is not
claimed. A caller can deliberately rerun host tests; this is not a malicious
USB/host resource-exhaustion protection claim.

## Validation and remaining limits

Regression results:

| Suite | Result |
| --- | --- |
| Frozen second-review reproductions | 13/13 reproduced |
| Stage-1 | 56 PASS |
| Stage-2 | 43 PASS |
| Stage-3 | 24 PASS |
| Target identification | 10 PASS |
| Firmware inspection | 10 PASS |
| Stage-4A native Linux | 53 PASS, no skips |
| Stage-4A macOS | 53 run, 51 PASS, socket/character skipped by sandbox |
| Real Linux topology/mount script | 8 PASS assertions |
| Stage-4B static | 8 PASS |
| Stage-4B Linux integration | 15 PASS |
| Stage-3 static ELF/ABI/interpreter/NEEDED/version/import/string gate | PASS |
| Stage-3 real FAT RO/RW suite | PASS |
| Stage-3 real FAT concurrency | 50 pairs PASS; paused-RO contender rejected |
| sh -n / dash -n (all five stages' shell scripts) | PASS |
| Python compileall (tools + firmware_tools) | PASS |
| git diff --check | PASS |
| Stage-4B diff against starting SHA | EMPTY |
| Live arming marker / raw firmware or probe data added | NONE |

The late-finalisation matrix contains 21 individually injected operation
failures plus the final failure-count gate; all prevent COMPLETE. Five
STATUS-hash variants also prevent COMPLETE. Earlier development test failures
were corrected (mount-table trailing newline preservation, macOS canonical
/private/tmp fixture paths, and a stale static assertion); the results above
refer to passing reruns. Native Linux covers socket/character cases skipped
on macOS. Exact commands:

```sh
python3 tools/w176-stage4-topology/reproduce_round2.py
python3 tools/w176-probe/test_stage1_probe.py
python3 tools/w176-stage2/test_stage2_platform_capture.py
python3 tools/w176-stage3-arm-probe/test_stage3_arm_probe.py
python3 -m unittest discover -s tools/target-identify -v
python3 -m unittest discover -s firmware_tools/tests -v
python3 -m unittest discover -s tools/w176-stage4-topology -v
python3 tools/w176-stage4-residency/test_stage4_residency.py
sh tools/w176-stage3-arm-probe/verify.sh
docker run --rm --privileged --platform linux/arm64 geminitop-w176-fat-ro-test:bookworm
sh tools/w176-stage4-residency/test_linux.sh
docker build --platform linux/arm64 -f tools/w176-stage4-topology/Test.Dockerfile -t geminitop-w176-topology-test:round2 tools/w176-stage4-topology
docker run --rm --privileged --platform linux/arm64 --mount type=bind,src=/Users/daniel/Documents/GeminiTop,dst=/repo,readonly geminitop-w176-topology-test:round2
rg --files tools/w176-probe tools/w176-stage2 tools/w176-stage3-arm-probe tools/w176-stage4-topology tools/w176-stage4-residency -g '*.sh' -0 | xargs -0 -n 1 sh -n
rg --files tools/w176-probe tools/w176-stage2 tools/w176-stage3-arm-probe tools/w176-stage4-topology tools/w176-stage4-residency -g '*.sh' -0 | xargs -0 -n 1 dash -n
PYTHONPYCACHEPREFIX=/tmp/geminitop-pycache python3 -m compileall -q tools firmware_tools
git diff --check
```

Final immutable review SHA is recorded with the fresh review prompt.
Native Linux uses pinned Debian
digest `3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251`,
Python `3.11.2-1+b1`, SquashFS tools `1:4.5.1-1`.
The pinned base and explicitly pinned top-level packages do not freeze all
transitive apt dependencies.

Real Linux fixtures verify SquashFS and normal proc metadata, writable and
read-only nested tmpfs, unrelated lib2 mount, same-device nested bind mount,
restored topology, and real sysfs class-link layout. Synthetic fixtures include
ext4-ro, device mismatch, topology change before child, realistic type-280
class-link metadata and a mutable-mount swap/FIFO sentinel that remains
untouched after rejection. Direct FIFO, FIFO links (including MCU), socket,
directory, disappearing source and character-device fixtures are host-only.
No target ARM code is executed.

Remaining LOW/INFO: finite scan ranges may omit higher IDs; unavailable sysfs
attributes are optional; checksums are consistency not authentication; owner
brackets reduce but cannot eliminate kernel object races; proc escaping policy
may conservatively reject valid unrelated mounts; filesystem allocation can
make du reject a logically smaller capture; hostile-root mount mutation is
outside the threat model. Physical BusyBox/installed topology still requires
independent review and a separate operator decision.
