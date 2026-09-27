# W176 Stage-4A CAN / MCU topology candidate

This directory prepares the separately armed, observation-only Stage-4A
candidate. It does **not** authorise a physical run.

The payload answers one narrow question: what metadata exists at the installed
Linux CAN/MCU boundary? It writes only to a positively identified removable
FAT filesystem. It never opens a candidate CAN, MCU, UART, or other device
stream. Metadata alone is not promoted to proof of translated MCU semantics.

## Payload layout

```text
payload/
├── ARM_STAGE4_CAN_MCU_TOPOLOGY.example  # rename only after independent GO
├── gemn_auto.sh                         # stock USB entry point
├── mount_guard.sh                       # exact removable FAT validation
└── stage4_topology.sh                   # bounded metadata/copy collector
```

The arming marker is deliberately absent. After an independent review and an
explicit physical-test decision, the operator would copy the example to the
exact name `ARM_STAGE4_CAN_MCU_TOPOLOGY`. The collector consumes that marker
and retains `.stage4a-topology.lock`; it is one-shot by design.

## Collection boundary

The candidate captures:

- a 64-KiB-bounded `/proc/net/dev` snapshot, at most 32 interface names parsed
  from that snapshot, and bounded `/sys/class/net` attributes;
- `lstat`-style device metadata, symlink targets, major/minor numbers, and
  `/sys/dev/char` associations for the exact finite set
  `/dev/canbox_protocol_dev`, `/dev/hc_mcu_dev`, `/dev/can0` through
  `/dev/can7`, and `/dev/ttyS0` through `/dev/ttyS7`;
- bounded correlation of existing `/proc/<pid>/fd` symlink destinations, with
  an exact PID range of 1..4096 and FD-number range of 0..127;
- bounded `comm`, `cmdline`, `exe`, and `maps` data only for matched owners;
- before/after PID start-time, FD target, and safe FD-stat bracketing around
  owner metadata; a changed bracket is discarded as race/unusable;
- pre-open regular/non-symlink checks and confirmation that `/application` is
  the installed read-only SquashFS boundary, followed by single-open,
  descriptor-verified copies of the installed
  `libappframework.so.1.0.0` and `libappmcucommunication.so.1.0.0` for later
  off-target static analysis.

It does not run `candump`, receive or transmit frames, open device streams,
issue MCU commands or ioctls, attach to processes, change interfaces or
logging, or execute/emulate copied ARM libraries.

The hard limits are recorded in `CAPABILITIES.txt`. Output selection uses only
an atomic fresh-directory creation; all 100 names being occupied fails closed.
A valid result requires a regular non-symlink `COMPLETE` created last,
`STATUS.txt` with `status=COMPLETE` and `mandatory_failures=0`, empty
`ERRORS.txt`, both bounded libraries, a schema-checked inventory, and an exact
checksum entry for every validation or evidence file. `sha256sum` status is
checked before its output is parsed; no pipeline masks it.

## Offline interpretation

```sh
python3 tools/w176-stage4-topology/analyze_topology.py \
  /path/to/stage4-topology --json /path/to/topology-analysis.json
```

The analyser validates every path component, rejects symlink escapes, applies
size limits before reads, validates schemas, requires complete canonical
checksum coverage, and rejects unexpected files before classification.
Checksums establish internal capture consistency, not cryptographic
authentication against deliberate rewriting of both evidence and manifest.

The conservative classification policy is:

- `CASE A` only when verified interface metadata contains Linux ARPHRD_CAN
  type 280. Physical Mercedes CAN connectivity, traffic, bitrate, and message
  semantics remain `UNKNOWN`.
- device names, owner FDs, and installed-library strings may support
  `MCU_TRANSLATION_PATH: INFERENCE`; they do not establish `CASE B`.
- `CASE C` requires independently confirmed raw-CAN and translated-semantic
  evidence; this metadata-only capture cannot establish the latter.
- absent type-280 evidence, the result remains `CASE D — UNKNOWN`, even when
  an MCU translation path is inferred.

Copied target libraries are treated as data only.

## Host tests

```sh
python3 tools/w176-stage4-topology/test_stage4_topology.py
```

The tests use disposable fixtures and host-native stand-ins. They cover the
independently reproduced NO-GO findings, special-source open sentinels,
checksum-command failures, canonical manifest coverage, symlink containment,
owner races, finite enumeration, malformed schemas, and false completion.
They never run a RoadTop ARM binary or copied RoadTop library.
