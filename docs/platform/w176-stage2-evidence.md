# Installed W176 Stage-2 platform evidence

Status: physical-target evidence. This document records sanitised derived facts
only. The raw USB capture and copied proprietary binaries remain outside Git.

## Capture validity and provenance

- Payload commit: `059db6e6aabdd0599967e413bd28c429ab0f0458`
- Physical review decision before use: `PHYSICAL STAGE-2 PLATFORM CAPTURE: GO`
- `STATUS.txt`: schema 1, scope `w176-stage2-platform`, `COMPLETE`, zero
  mandatory failures
- `COMPLETE`: regular marker containing `complete=1`
- `ERRORS.txt` and `OPTIONAL.txt`: empty
- Hard-timeout backend/self-test: `parent_proc_state_machine` / `PASS`
- Source acquisition: `single_open_verified_fd_snapshot`
- Reported target writes, raw-MTD reads, NVM/userdata reads, and CAN/MCU
  operations: all zero

The raw return was inspected read-only at its removable-volume location. All 12
mandatory COPY entries, 10 mandatory HASH entries, and 8 symlink metadata
entries reported `OK`. The retained copied payload was 216,551 bytes; total
source bytes processed were 4,249,551. No raw capture content is tracked.

## CONFIRMED installed platform and startup facts

The captured `/application/appinfo.rc` contains these exact configuration
values:

```text
4RlsCode_8368_XU_demov1.0_openall_cfg
gemini_8368_XU_evb_def_config
sunplus/gemini_disc
gemini_8368_XU_defconfig
gemini_servo_cfg
sunplus/sunplus_XU_demo_openallfunc
```

This confirms `8368_XU` as installed platform/build configuration evidence. It
does not identify a QD507/QD513/QD515 or other retail PCB.

The installed startup files establish:

- `/init` resolves to `bin/init`; `/etc/inittab` runs `/etc/init.d/rcS` as
  `sysinit`;
- `/init.rc` imports `/init.gui.rc`, `/init.environ.rc`, and
  `/init.platform.rc`;
- `rom@spsdk.` is mounted read-only at `/usr/local`, `rom@spapp.` is mounted
  read-only at `/application`, and NVM/userdata are mounted as YAFFS2 at
  `/media/flash/nvm` and `/media/flash/userdata`;
- `LD_LIBRARY_PATH` starts with `/media/flash/nvm/lib` and `PATH` starts with
  `/media/flash/nvm/bin` before the stock locations;
- `ncLauncher` starts `/application/bin/Launcher --dfb:no-layers-clear`, while
  the alternate `Launcher` service omits that option. The Stage-1 process
  observation included the option, supporting the `ncLauncher` path for that
  boot;
- services are declared under the root init context. Selected normal/step-1
  services include service/resource/device managers, `as_server`, video-in,
  Bluetooth, and network services. Optional CarPlay and Android Auto services
  are property-triggered and disabled initially.

The persistent NVM path precedence is an important future patchability clue,
not authorisation to write NVM or shadow a binary/library. Whether a safe
persistent override works remains UNKNOWN.

The installed `rcS` contains entirely commented historical development blocks
which refer to USB `sprtlib.sqfs`, `spsdk.sqfs`, and `app.sqfs`, loop mounting,
and replacing runtime/application paths. Their presence is CONFIRMED; an
active, safe, or supported USB-SquashFS mechanism is UNKNOWN. They must not be
reactivated during discovery.

## CONFIRMED USB autorun

`/etc/mdev.conf` dispatches `sd.*` events to `/etc/usb_action_8368-U`. That
script sets `SP_GEMINI_AUTO_FILENAME="gemn_auto.sh"`, waits for an `sd.*` mount
reported by `df`, and invokes the file at the selected mount root. Combined
with the successful root-owned Stage-1 and Stage-2 runs, removable-root shell
execution is physically proven.

The stock script itself does not provide the fail-closed mount guarantees used
by the reviewed probes; every future USB payload must retain its own positive
mount and output-boundary validation.

## CONFIRMED installed ELF/ABI facts

Host-side static inspection only was used. Neither captured ARM file was
executed or emulated.

| Property | Installed Launcher result |
|---|---|
| SHA-256 / size | `5ff83ac9cf9fb2ccb21c90c9b2edb2952581153ec5d5ab4a299787243e1e0c56` / 92,416 bytes |
| Class / data | ELF32 / little-endian |
| Machine / ABI | ARM, EABI5 |
| ARM ELF flags | `0x05000400`: EABI5 plus hard-float ABI flag |
| File kind | dynamically linked executable, stripped |
| Kernel ABI note | GNU/Linux 3.2.0 |
| Interpreter | `/lib/ld-linux-armhf.so.3` |
| RPATH / RUNPATH | absent |
| Version needs | `GLIBC_2.4`, `GCC_3.5` |
| Compiler string | GNU A-profile 9.2-2019.12, GCC 9.2.1 20191025 |

The interpreter symlink resolves to `ld-2.30.so`. The captured loader is
106,956 bytes, has SHA-256
`ecbb0438ae125f89f190cbd0a86345d3c212a8ddc1448e25008dc91921b831c9`,
uses the same `0x05000400` ARM flags, has SONAME `ld-linux-armhf.so.3`, and
defines `GLIBC_2.4` plus `GLIBC_PRIVATE`. `/lib/libc.so.6` resolves to
`libc-2.30.so`; the installed libc hash is
`ff2c3745c8c41e41b8f770f306250334d8b1b2cd5da4801f066342164024ee04`.

A future trivial C loadability probe should therefore be ELF32 little-endian
ARM EABI5 hard-float, request exactly `/lib/ld-linux-armhf.so.3`, avoid C++ and
all RoadTop libraries, contain no RPATH/RUNPATH, and require no symbol version
newer than one independently established in the installed runtime. Launcher
demonstrates the `GLIBC_2.4`/`GCC_3.5` floor for its own imports, but it is not a
complete inventory of libc 2.30 exports.

## Installed v2.0.61 versus v2.0.65 reference

| Binary | Installed size | Installed SHA-256 | Reference result |
|---|---:|---|---|
| Launcher | 92,416 | `5ff83ac9cf9fb2ccb21c90c9b2edb2952581153ec5d5ab4a299787243e1e0c56` | DIFFERENT |
| `libappframework.so.1.0.0` | 287,536 | `f79bb7e63fe4c5fb4b667ffd98e4f09ae57c6526b2cff856379ee8f12b4fc248` | DIFFERENT |
| `libappmcucommunication.so.1.0.0` | 213,496 | `a45b1b92e8e5fcc224758dac1f6c57b2ab82a468db5bc15dcd53103a382f55b4` | DIFFERENT |
| `ld-2.30.so` | 106,956 | `ecbb0438ae125f89f190cbd0a86345d3c212a8ddc1448e25008dc91921b831c9` | DIFFERENT |
| `libc-2.30.so` | 934,972 | `ff2c3745c8c41e41b8f770f306250334d8b1b2cd5da4801f066342164024ee04` | DIFFERENT |
| `libstdc++.so.6.0.28` | 1,416,644 | `a102d9b05e6c691c3e460fb0bb3ed2476fedeeae6e88e41f910954cfa3db56c0` | DIFFERENT |
| BusyBox | 758,996 | `96cbb1cd5ab51587367bec3795ba280a8000866a9d7197a1051249e7ec4c0b32` | DIFFERENT |
| `servicemanager` | 9,816 | `3253243fba26d3e39aae7ea542d2d60a89e28fb72a6b445e06579df3f056c0de` | MATCH |
| `resourcemanager` | 133,852 | `6985dce7a3cb7930dd2d74a807c28d9d7f368db1224b29d8c2e3028976c8dc6b` | MATCH |
| `networkmanager` | 121,444 | `1f2ce2140622123ae69609ecf80f51c0c154cd5615b118d7ece2ce15f40fa75d` | MATCH |
| `device_server` | 146,472 | `b0fe3c527823bc67760925c3c07461df2ccdb7e6750b56d9bb2e27d7d117894f` | MATCH |
| `pfc_server` | 9,772 | `4c9ac4a2d44b1ed5b1e51572d768759942b531468cf2c7eb98ac6a2b43c39f85` | MATCH |

Each result is a SHA-256 comparison between CONFIRMED installed bytes and a
REFERENCE ONLY v2.0.65 anchor. The reference is not byte-identical and must not
be treated as a drop-in update. Matching core services, common paths, matching
runtime filenames/sizes, and the shared Gemini/8368_XU configuration make it
structurally useful for static investigation; they do not establish update or
flash compatibility.

## ARM execution decision after resolving the host build gate

The Stage-2 evidence above remains unchanged. A later host-only Stage-3 task
resolved its one identified prerequisite using the official Arm GNU A-profile
9.2-2019.12 AArch64-Linux-hosted ARMHF toolchain in a digest-pinned Linux/arm64
container. Two clean builds are byte-identical, and the resulting inert ELF
passes the complete static interpreter, NEEDED, symbol-version, import, source,
and architecture gate.

An isolated, deliberately unarmed Stage-3 review payload now exists at
`tools/w176-stage3-arm-probe/`. This changes the state from “build prerequisite
missing” to “ready for fresh independent code-safety review”; it does not add
physical evidence. The binary has never been executed or emulated, no vehicle
action has occurred, and custom ARM loadability remains UNKNOWN. See
`w176-stage3-arm-probe.md`.
