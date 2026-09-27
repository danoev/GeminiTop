# W176 Stage-4A CAN / MCU topology candidate

This directory prepares the separately armed, observation-only Stage-4A
candidate. It does **not** authorise a physical run.

The payload answers one narrow question: does the installed RoadTop expose raw
CAN to Linux, translated MCU/proprietary interfaces, both, or insufficient
evidence? It writes only to a positively identified removable FAT filesystem.
It never opens a candidate CAN, MCU, UART, or other device stream.

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

- a bounded `/proc/net/dev` snapshot and bounded `/sys/class/net` attributes;
- `lstat`-style device metadata, symlink targets, major/minor numbers, and
  `/sys/dev/char` associations for narrowly named candidates;
- bounded correlation of existing `/proc/<pid>/fd` symlink destinations, with
  PID start-time and double-read FD identity checks;
- bounded `comm`, `cmdline`, `exe`, and `maps` data only for matched owners;
- single-open, descriptor-verified copies of the installed
  `libappframework.so.1.0.0` and `libappmcucommunication.so.1.0.0` for later
  off-target static analysis; and
- names and metadata (not contents) for narrowly named application
  configuration candidates.

It does not run `candump`, receive or transmit frames, open device streams,
issue MCU commands or ioctls, attach to processes, change interfaces or
logging, or execute/emulate copied ARM libraries.

The hard limits are recorded in `CAPABILITIES.txt`. A valid result requires a
regular non-symlink `COMPLETE`, `STATUS.txt` with `status=COMPLETE` and
`mandatory_failures=0`, empty `ERRORS.txt`, both bounded libraries, and the
manifest/checksum files.

## Offline interpretation

```sh
python3 tools/w176-stage4-topology/analyze_topology.py \
  /path/to/stage4-topology --json /path/to/topology-analysis.json
```

The analyser verifies the returned transaction and checksums before assigning
CASE A, B, C, or D. Copied target libraries are treated as data only.

## Host tests

```sh
python3 tools/w176-stage4-topology/test_stage4_topology.py
```

The tests use disposable fixtures and host-native stand-ins. They never run a
RoadTop ARM binary or copied RoadTop library.
