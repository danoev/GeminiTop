# W176 Stage-3 inert ARMHF loadability probe

Status: host build and static review material only. This directory does not
authorise a physical run. The installed RoadTop has not executed this binary,
and custom ARM executable loadability remains UNKNOWN pending a fresh
independent safety review and a separately authorised one-shot test.

## Question and safety boundary

The probe answers one question only: can the installed kernel, ARMHF loader,
and libc load a small custom ELF from removable USB and return normally?

`probe.c` performs one libc `write` to standard output and returns zero only
when every byte was written. It does not open a file, inspect the target,
access a device, use RoadTop libraries, create another process, use networking,
change privileges, signal another process, mount anything, or persist. The
reviewed shell wrapper owns stdout/stderr capture and writes only beneath the
validated removable filesystem.

The exact expected stdout is:

```text
schema=1
probe=w176-arm-loadability
started=1
result=PASS
```

## Pinned build provenance

| Item | Pinned value |
|---|---|
| Vendor / release | Arm GNU Toolchain for the A-profile Architecture 9.2-2019.12 |
| Host build | AArch64 GNU/Linux |
| Target triple | `arm-none-linux-gnueabihf` |
| Archive | `gcc-arm-9.2-2019.12-aarch64-arm-none-linux-gnueabihf.tar.xz` |
| Authoritative URL | `https://developer.arm.com/-/media/Files/downloads/gnu-a/9.2-2019.12/binrel/gcc-arm-9.2-2019.12-aarch64-arm-none-linux-gnueabihf.tar.xz` |
| Archive size | 259,613,720 bytes |
| Independently computed SHA-256 | `9f333ede9ba09d1bd266e110c1a0b69aa0fd4543696b5132ff238c20124b0dcb` |
| Arm checksum sidecar | same URL with `.asc`; MD5 `571432175db6e28442e4610da92fe5cc` |
| Container platform | `linux/arm64` |
| Base image | `debian@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251` |
| Compiler | `arm-none-linux-gnueabihf-gcc` 9.2.1 20191025, Arm 9.2-2019.12 |
| Linker | GNU ld 2.33.1.20191209 |
| Sysroot | `${TOOLCHAIN_ROOT}/arm-none-linux-gnueabihf/libc` |

The bundled sysroot loader is `/lib/ld-linux-armhf.so.3`. Static inspection of
its libc shows ELF32 ARM EABI5 hard-float and version definitions through
`GLIBC_2.30`. Compatibility is not inferred from that ceiling: the produced
probe requires only `GLIBC_2.4`, already established on the installed target
by Stage-2 evidence.

`build.sh` fetches the exact archive and its Arm-hosted checksum sidecar,
verifies both the independently pinned SHA-256 and published MD5, extracts it
into a temporary build context, and builds the digest-pinned Linux/arm64 image.
It then performs two separate clean container runs. No undocumented toolchain
file is required. Downloads and extracted proprietary-free build inputs remain
outside Git.

## Compile and reproducibility result

The exact compile/link options are defined in `container-build.sh`:

```text
-std=c11 -O2 -Wall -Wextra -Werror
-fno-ident -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-pie
-march=armv7-a -mfpu=neon -mfloat-abi=hard -mthumb -no-pie
-Wl,--build-id=none -Wl,--as-needed -Wl,--hash-style=both
-Wl,-z,relro -Wl,-z,now
```

The architecture flags reproduce, without exceeding, the installed Launcher's
Stage-2 static attributes: ARMv7-A application profile, ARM ISA, Thumb-2,
VFPv3, NEONv1, and VFP-register argument passing.

Both clean builds produced an identical 5,556-byte stripped binary:

```text
662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789
```

The committed `payload/arm_probe.sha256` records the same value.

## Complete static ABI result

`verify.sh` uses `file`, the target toolchain's `readelf`, `objdump`, and
`strings`; it never runs the binary. The frozen binary has:

- ELF32, little-endian, ARM, EABI5, hard-float flags `0x5000400`;
- ARMv7-A application profile, ARM ISA, Thumb-2, VFPv3, NEONv1, VFP args;
- interpreter exactly `/lib/ld-linux-armhf.so.3`;
- one `NEEDED` entry: `libc.so.6`;
- no RPATH or RUNPATH;
- one version requirement: `GLIBC_2.4` from `libc.so.6`;
- no C++ or RoadTop-specific library dependency.

The complete unique undefined/imported-symbol set is:

| Import | Classification |
|---|---|
| `write@GLIBC_2.4` | Deliberate libc call used for the fixed stdout marker |
| `__libc_start_main@GLIBC_2.4` | Normal GNU C runtime startup |
| `abort@GLIBC_2.4` | Normal GNU startup-object failure path; not called by probe source |
| weak `__gmon_start__` | Optional GNU startup hook; unresolved weak import |

The entire source is 15 lines. Its prohibited-API/string audit passes. It has
no third-party or generated source.

## Physical payload and arming

The payload directory contains:

```text
ARM_STAGE3_ARM_EXECUTION_PROBE.example
arm_probe
arm_probe.sha256
gemn_auto.sh
mount_guard.sh
stage3_arm_probe.sh
```

The real marker `ARM_STAGE3_ARM_EXECUTION_PROBE` is deliberately absent and
must never be tracked. Both the entrypoint and the stage script require it to
be a real regular non-symlink. Creating it is a separate post-review physical
action and is not authorised by this repository state.

The mount guard requires exactly one removable `/dev/sdN` partition, an
approved FAT filesystem, and the payload directory to be the exact anchored
mount root. Results use a fresh relative `stage3-arm-probe[-N]` directory. The
wrapper never falls back to internal storage and does not resolve later output
writes through the original mount pathname.

Before the execution attempt, the wrapper opens the reviewed binary once,
checks its regular-file/path identity and exact size, copies that open
descriptor into a private USB result-directory snapshot, and verifies the
snapshot's exact SHA-256. Only that verified snapshot can become the one direct
child. Original and snapshot metadata are checked again afterward.

The parent `/proc` state machine has a five-second normal deadline, one-second
TERM phase, and one-second KILL phase, plus a destructive-timeout self-test
before the probe. UNKNOWN state, PID reuse/identity change, signal failure,
timeout, nonzero/signal exit, loader stderr, unexpected stdout, hash mismatch,
or output failure leaves the result INCOMPLETE without `COMPLETE`. As with the
reviewed Stage-2 runner, a child stuck in uninterruptible kernel `D` state
cannot be synchronously removed by KILL; that condition is fatal and cannot
produce success.

`STATUS.txt` starts INCOMPLETE. Success requires exact stdout, empty stderr,
exit zero, the frozen hash, zero mandatory failures, all required regular
outputs, and a COMPLETE status. The regular non-symlink `COMPLETE` marker is
committed last.

## Host-only commands

After the pinned image has been built, `verify.sh` performs the complete static
gate. `test_stage3_arm_probe.py` substitutes host shell stubs for execution
tests; it never transforms or runs `payload/arm_probe`.

No QEMU, binfmt, Rosetta, target execution, or other emulation is used anywhere
in this workflow.
