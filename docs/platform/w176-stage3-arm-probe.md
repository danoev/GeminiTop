# W176 Stage-3 ARM loadability probe review state

Status: COMPLETE. Following independent review of the frozen payload, the
operator ran the one-shot probe on 2026-09-27. The exact reviewed ARMHF ELF
executed natively on the installed RoadTop and returned zero. See
`w176-stage3-physical-evidence.md` for the returned transaction and provenance
limitation.

## Host result

- Official Arm GNU A-profile 9.2-2019.12 AArch64-Linux-hosted toolchain,
  archive SHA-256
  `9f333ede9ba09d1bd266e110c1a0b69aa0fd4543696b5132ff238c20124b0dcb`.
- Digest-pinned Debian Linux/arm64 build image.
- Two clean builds are byte-identical.
- Frozen binary: 5,556 bytes, SHA-256
  `662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789`.
- Static result: ELF32 little-endian ARM EABI5 hard-float, installed-compatible
  ARMv7-A/VFPv3/NEON attributes, exact `/lib/ld-linux-armhf.so.3`
  interpreter, only `libc.so.6`, only `GLIBC_2.4`, no RPATH/RUNPATH, and no
  RoadTop-specific dependency.
- The 15-line C source performs only one libc `write` of a fixed marker and
  returns according to that write's result.
- The target binary has not been executed or emulated.

The preceding bullet describes the host build/static-review phase. It is kept
as historical context. The later physical milestone is recorded below.

## Physical result — 2026-09-27

Operator-supplied physical evidence ties the successful run to commit
`ee6ea0f7d0ef028c406c324e9f43f078d5f8de3f` and the exact 5,556-byte binary
SHA-256
`662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789`.
The returned transaction reported COMPLETE, zero mandatory failures, executed
once, exit status zero, PASS, verified RO execution window, verified RW
restoration, consumed marker, and retained one-shot lock.

This session did not inspect the original FAT media or raw result files. The
reviewed wrapper's regular non-symlink checks support the operator-returned
valid transaction, but copied files cannot independently reproduce original
FAT object metadata.

Full provenance, flags, import classification, payload design, and limitations
are documented in `tools/w176-stage3-arm-probe/README.md`.

## Payload state

The isolated payload exists only to support a fresh independent review. It is
unarmed: Git contains `ARM_STAGE3_ARM_EXECUTION_PROBE.example`, not the real
`ARM_STAGE3_ARM_EXECUTION_PROBE` marker.

The payload at commit `207e4c49c955befbfaa06dd6df976e2d23a23b39`
is CONFIRMED **HIGH / NO-GO**. Its hash-then-execute-by-path snapshot could be
replaced during a mutable interval, allowing different harmless host code to
execute and false COMPLETE.

The subsequent read-only-window payload at commit
`e16c2e43777a8b0fd5885af3621d4f25bf7e5f4a` is also CONFIRMED **HIGH /
NO-GO** because its marker was not an atomic concurrency primitive. Two
overlapping host wrappers could both execute and both create COMPLETE, while
one could restore RW during the other's RO integrity window.

The remediated wrapper retains the reviewed Stage-2 removable FAT anchor,
bounded direct-child architecture, and RO execution window. After anchoring it
atomically creates the fixed `.stage3-arm-probe.lock` directory. Only the
successful `mkdir` owner may inspect/consume the marker, create initial
INCOMPLETE, remount, hash, execute, restore RW, or finalise results. It remounts
only the exact validated USB device/mount read-only,
independently confirms that same identity and `ro` state from `/proc/mounts`,
then performs the final size/hash check and one pathname execution entirely
inside that RO window. It captures only shell exit state. After a known child
termination it remounts the same pair RW, independently verifies `rw`, and only
then writes results. `COMPLETE` remains last.

The target never removes or stale-checks the lock, on success or failure. A new
reviewed attempt requires deliberate off-target Mac preparation: inspect the
prior result, manually remove the old lock, create a fresh real marker, and
reverify the exact payload. Reinvocation with no marker, or with a mistakenly
recreated marker, fails at the older lock before any remount or execution.

Disposable Linux/arm64 FAT32 tests confirm that RO blocks pathname replacement,
truncation, and ordinary in-place writes while allowing a harmless host stub to
execute. A writable descriptor retained before remount causes the RO remount
to fail busy; the wrapper therefore cannot proceed to hash or execution. The
installed BusyBox remount command/syntax remains physically UNKNOWN and is a
fail-closed capability check, not an assumption.

Host regression tests run 25 two-process overlap repetitions with exactly one
execution and one COMPLETE per pair. A separate real FAT test runs 50 pairs
with exactly one lock winner, marker consumer, RO request, host-stub execution,
RW request, and COMPLETE per pair. A paused-RO-owner test confirms that a
second invocation loses the lock and cannot remount RW; RO remains in force
until the owner restores it.

If the execution child becomes uncertain/stuck or RW restoration cannot be
proven, the initial INCOMPLETE state remains, the marker remains consumed, and
physical USB removal is the documented recovery. No physical GO is declared.

## Evidence state

- **CONFIRMED:** stock USB root shell execution and the installed ABI facts
  recorded by Stages 1 and 2.
- **CONFIRMED:** the committed host build is reproducible and passes its static
  ABI/import/source gates.
- **CONFIRMED:** host-stub adversarial tests pass without running the ARM ELF.
- **CONFIRMED:** the concurrency finding at `e16c2e4` is reproduced and the
  atomic persistent-directory-lock regression tests serialize the full window.
- **CONFIRMED:** real disposable Linux FAT remount tests establish the stated
  normal-writer immutability and retained-writable-handle fail-closed behavior.
- **CONFIRMED:** the installed kernel, loader, and libc loaded the exact reviewed
  custom ELF from removable USB and it returned exit status zero.
- **CONFIRMED:** for this physical transaction, the wrapper reported that the
  installed remount path established RO, then restored and verified RW.
- **COMPLETE:** the reviewed one-shot Stage-3 physical milestone. This does not
  authorise broader runtime, persistence, CAN/MCU, or firmware actions.

This work does not prove RoadTop patching, ABI suitability for a feature
binary, library shadowing, persistence, application replacement, or firmware
compatibility.

## Threat model

The safety objective is exact-file execution on a normal, non-hostile stock
system, protecting against wrapper races, pathname replacement, retained
ordinary writers, and accidental mutation. It does not claim protection from
a malicious privileged root process deliberately remounting the USB RW during
the execution window.
