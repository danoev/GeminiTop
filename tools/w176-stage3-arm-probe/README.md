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
change privileges, signal another process, mount anything, or persist. During
the execution attempt its harmless stdout/stderr are discarded to `/dev/null`;
only its direct-child exit status is retained in shell state.

The source emits this fixed marker, but Stage-3 does not use it as evidence:

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
must never be tracked. The stage script checks it only after winning the atomic
one-shot lock, and requires it to be a real regular non-symlink. Creating it is
a separate post-review physical action and is not authorised by this repository
state.

The mount guard requires exactly one removable `/dev/sdN` partition, an
approved FAT filesystem, and the payload directory to be the exact anchored
mount root. Results use a fresh relative `stage3-arm-probe[-N]` directory. The
wrapper never falls back to internal storage and does not resolve later output
writes through the original mount pathname.

The prior snapshot-by-path design at commit
`207e4c49c955befbfaa06dd6df976e2d23a23b39` is **NO-GO**. A confirmed HIGH
host reproduction replaced its mutable snapshot between hash validation and
the execution identity baseline, executed different harmless code, and
produced false COMPLETE.

Independent review of the first read-only-window revision at commit
`e16c2e43777a8b0fd5885af3621d4f25bf7e5f4a` then CONFIRMED a second HIGH /
NO-GO race: overlapping wrappers could both pass the marker check, both enter
the shared sequence, both execute, and one could restore RW while the other
still required RO integrity.

The replacement design serialises the complete read-only USB execution window:

1. anchor and validate the exact removable FAT USB root;
2. atomically create the fixed relative directory
   `.stage3-arm-probe.lock` and record ownership only after `mkdir` succeeds;
3. verify the acquired path is a real non-symlink directory;
4. only the lock owner checks the real arming marker;
5. consume that marker and verify it is gone;
6. create the fresh result directory and commit initial INCOMPLETE;
7. require the established `rw`, `dirsync`, executable mount state, perform the
   bounded-runner self-test, and complete preliminary binary checks;
8. reverify lock ownership, then invoke the system `mount` command only for
   `mount -o remount,ro <validated-device> <validated-mount>`;
9. independently re-read `/proc/mounts` and require the same device, mount,
   filesystem, anchored directory, `ro`, no `rw`, and no `noexec`;
10. only while that state holds and lock ownership remains valid, revalidate
   type/size, calculate the final exact SHA-256, and execute that exact pathname
   once with no USB output;
11. after a known child termination and another ownership check, remount only
   the same pair RW and
   independently require `rw` with no `ro`;
12. only after RW restoration, commit the hash, capabilities, execution result,
   final status, and finally `COMPLETE`;
13. leave `.stage3-arm-probe.lock` present on every success and failure path.

The lock is never removed, judged stale, or replaced on target. An existing
directory, ordinary file, symlink, failed `mkdir`, or false-successful `mkdir`
fails before marker handling, output creation, remount, hash, execution, or
COMPLETE. A losing concurrent wrapper cannot restore RW because every RO,
hash, execution, and RW transition is reachable only by the invocation whose
atomic `mkdir` succeeded.

There is no execution snapshot and no post-execution metadata identity claim.
A new USB-supplied sealing helper is not used: the already-running reviewed
shell wrapper invokes only stock system `mount`, `awk`, `stat`, and `sha256sum`
and evaluates `/proc/mounts` itself.
A failed or falsely successful RO transition cannot execute the binary. An
unknown/stuck child or unverified RW restoration leaves the already-written
INCOMPLETE state and USB read-only; physical removal is the recovery action.
The real marker is not recreated, so reinsertion cannot automatically retry.
The persistent lock is the stronger one-shot barrier: reinvocation fails before
marker handling even if someone mistakenly recreates the marker.

For any later independently reviewed and separately authorised new attempt,
USB preparation must happen off-target on the Mac: inspect the previous result,
manually remove the old `.stage3-arm-probe.lock` directory, create a fresh real
arming marker, and reverify the exact reviewed payload. The target scripts must
never remove the lock automatically.

The parent `/proc` state machine has a five-second normal deadline, one-second
TERM phase, and one-second KILL phase, plus a destructive-timeout self-test
before the probe. UNKNOWN state, PID reuse/identity change, signal failure,
timeout, nonzero/signal exit, hash mismatch, mount-state mismatch, or output
failure leaves the result INCOMPLETE without `COMPLETE`. As with the
reviewed Stage-2 runner, a child stuck in uninterruptible kernel `D` state
cannot be synchronously removed by KILL; that condition is fatal and cannot
produce success or trigger an RW remount.

`STATUS.txt` starts INCOMPLETE. Success requires a confirmed RO window, final
frozen hash inside that window, known exit zero, confirmed RW restoration,
zero mandatory failures, all required regular outputs, and a COMPLETE status.
The regular non-symlink `COMPLETE` marker is committed last.

## Real Linux FAT semantics

`FatTest.Dockerfile`, `test_fat_ro_window.sh`, and
`test_fat_lock_concurrency.sh` exercise disposable loop devices and FAT32
filesystems inside a privileged, pinned Linux/arm64 container. They never touch
a macOS mount and never execute `payload/arm_probe`.

The observed Linux FAT result is:

- normal RW writes succeed;
- `/proc/mounts` independently confirms RO and later RW;
- rename-over, truncation, and in-place append all fail while RO, including
  fresh rename/write attempts after the final hash and before execution;
- the candidate hash remains stable and a harmless host shell stub executes;
- after confirmed RW restoration, output writes and the transaction resume;
- a writer trying to open/write after RO fails;
- an ordinary writable descriptor retained before remount causes the RO
  remount to fail as busy; the filesystem remains RW and that retained writer
  can still write;
- 50 pairs of simultaneous wrapper equivalents yield exactly 50 winners, 50
  losers, 50 marker consumptions, 50 RO requests, 50 harmless host-stub
  executions, 50 RW requests, and 50 COMPLETE transactions;
- a second process started while the owner is paused on RO loses the lock,
  issues no remount and no execution, and cannot restore RW early;
- the lock remains after success.

The last case is fail-closed by design: the wrapper verifies actual RO state
and does not hash or execute when remount is rejected. Installed BusyBox
v1.29.3 mount syntax for this exact operation is still physically UNKNOWN;
the wrapper treats command absence, unsupported syntax, nonzero status, or a
non-RO `/proc/mounts` result as no-execution failure.

## Threat model

The objective is exact-file execution on a normal, non-hostile embedded
system. The RO window protects against wrapper races, pathname replacement,
rename-over, truncation, retained ordinary writers, and accidental mutation.
It does not attempt to defend against a malicious privileged root process that
deliberately remounts the USB RW during the window. The stock RoadTop system is
trusted for this compatibility experiment.

## Host-only commands

After the pinned image has been built, `verify.sh` performs the complete static
gate. `test_stage3_arm_probe.py` substitutes host shell stubs for execution
tests; it never transforms or runs `payload/arm_probe`.

The real FAT test is run from this directory with:

```text
docker build --platform linux/arm64 -f FatTest.Dockerfile \
  -t geminitop-w176-fat-ro-test:bookworm .
docker run --rm --privileged --platform linux/arm64 \
  geminitop-w176-fat-ro-test:bookworm
```

No QEMU, binfmt, Rosetta, target execution, or other emulation is used anywhere
in this workflow.
