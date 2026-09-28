# W176 Stage-4B persistent-residency candidate

Status: historical host-only candidate, **NOT READY** after the 2026-09-28
fresh safety audit in `docs/platform/w176-stage4b-fresh-safety-audit.md`.
The earlier review prompt is superseded. Do not arm or physically run these
scripts. No physical run or NVM write is authorised by this directory.
The branch's subsequent v2 host-only hardening and unresolved gates are tracked in
`docs/platform/w176-stage4b-remediation-status.md`; the older design summary
below is not a claim of current approval.

## Confirmed storage boundary

Installed Stage-1/2 evidence confirms:

- `mtd12` is the 8 MiB `nvm` partition;
- `/media/flash/nvm` is a persistent YAFFS2 read-write mount; and
- stock init prepends `/media/flash/nvm/bin` and
  `/media/flash/nvm/lib` to search paths.

This candidate deliberately avoids both shadowing locations. Its only proposed
persistent target is:

```text
/media/flash/nvm/geminitop/w176/
├── geminitop-proofd
└── manifest.txt
```

The installer requires the exact mount point, YAFFS2 type, RW state, unique
8 MiB `nvm` MTD record, installed kernel release, `8368_XU` app-info clue, and
the exact confirmed installed Launcher hash/size. It refuses userdata and all
fallback paths.

## Proof executable

`geminitop-proofd` is an intentionally idle ARMHF process. It:

- publishes an atomic heartbeat under `/tmp` every two seconds;
- reports its PID, kernel process start ticks, fixed build identifier, and
  heartbeat sequence (its binary hash is verified independently);
- handles TERM/INT and publishes a final stopped state; and
- accesses no CAN, MCU, serial, framebuffer, input, audio, Bluetooth, stock
  process, private RoadTop library, or network interface.

The current **unfrozen host-only v2 build** is 5,556 bytes with SHA-256:

```text
684afd86a067a6e175ed6b7d6c2a0281f1d44c67f62d86431589d1d7bd8c41b8
```

The historical v1 build was also 5,556 bytes, SHA-256
`57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6`.

It is built twice with the same pinned official Arm GNU A-profile
9.2-2019.12 AArch64-Linux-hosted toolchain used for the physically proven
Stage-3 ABI. Both clean outputs are byte-identical. Static inspection confirms
ELF32 little-endian ARMv7 EABI5 hard-float,
`/lib/ld-linux-armhf.so.3`, only `libc.so.6`, only `GLIBC_2.4`, and no
RPATH/RUNPATH. The ARM binary is never run on the development host.

## Separately armed actions

The payload ships without any live arming marker. Exactly one marker may exist:

1. `ARM_STAGE4B_INSTALL` — creates the dedicated tree transactionally, checks
   the copied hash, launches the destination copy from `/tmp` as its working
   directory, and verifies `/proc/<pid>/exe`, PID start time, heartbeat, and
   absence of USB-backed file descriptors and exactly one matching live
   execution of the installed binary.
2. `ARM_STAGE4B_VERIFY_AFTER_REMOVAL` — created off-target only after the
   operator removes and reinserts the USB. It compares the original PID/start
   identity and proves the volatile heartbeat continued to advance.
3. `ARM_STAGE4B_UNINSTALL` — validates the manifest, binary, directory
   allowlist, running PID/start/executable identity, and heartbeat; sends TERM;
   verifies termination; then removes only the two owned NVM files, their empty
   final directory. It leaves the empty parent and stopped volatile heartbeat
   in place to avoid unnecessary or ambiguously owned cleanup.

Each action consumes its marker and retains a distinct one-shot lock. The
`.example` files show exact marker content. An uploaded result can record the
operator's removal/reinsertion action but cannot independently reconstruct that
physical fact.

No action modifies stock files, `PATH`, `LD_LIBRARY_PATH`, init, Launcher,
SquashFS, MTD, CAN/MCU state, or networking. Boot persistence is not enabled;
a reboot may stop the proof process.

## Build and verification

```sh
tools/w176-stage4-residency/build.sh
tools/w176-stage4-residency/verify.sh
tools/w176-stage4-residency/test_linux.sh
```

The Linux suite replaces the ARM ELF with a host-native stand-in before any
execution. It exercises wrong-target/mount/storage cases, collisions, source
and destination hash failures, interrupted copies, launch/heartbeat/PID
failures, simulated USB removal, continued execution from the persistent path,
clean TERM, exact uninstall, unexpected-file refusal, stock-file invariance,
and absence of `nvm/bin` or `nvm/lib` shadowing.

## UI and boot-persistence findings

Installed startup evidence proves only the risky search-path precedence and
stock init service declarations. Reference inventories contain ordinary Qt
plugin directories and unrelated feature plugins, but no evidence establishes
an intended data-driven extension point for the installed Launcher Settings UI
or a low-risk persistent startup registration mechanism.

```text
STOCK SETTINGS EXTENSION: NOT YET SAFE / REQUIRES FURTHER RESEARCH
BOOT PERSISTENCE: NOT ENABLED
```
