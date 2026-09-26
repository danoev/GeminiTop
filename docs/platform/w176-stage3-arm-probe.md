# W176 Stage-3 ARM loadability probe review state

Status: the reproducible host build, static ABI gate, inert payload, and host
adversarial tests are complete. **No physical GO is declared.** Custom ARM ELF
loadability on the installed RoadTop remains UNKNOWN until an independent Work
safety review approves the exact frozen commit, exact binary, and one-shot
payload.

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

The remediated wrapper retains the reviewed Stage-2 removable FAT anchor and
bounded direct-child architecture, but removes the snapshot. It consumes the
one-shot marker, remounts only the exact validated USB device/mount read-only,
independently confirms that same identity and `ro` state from `/proc/mounts`,
then performs the final size/hash check and one pathname execution entirely
inside that RO window. It captures only shell exit state. After a known child
termination it remounts the same pair RW, independently verifies `rw`, and only
then writes results. `COMPLETE` remains last.

Disposable Linux/arm64 FAT32 tests confirm that RO blocks pathname replacement,
truncation, and ordinary in-place writes while allowing a harmless host stub to
execute. A writable descriptor retained before remount causes the RO remount
to fail busy; the wrapper therefore cannot proceed to hash or execution. The
installed BusyBox remount command/syntax remains physically UNKNOWN and is a
fail-closed capability check, not an assumption.

If the execution child becomes uncertain/stuck or RW restoration cannot be
proven, the initial INCOMPLETE state remains, the marker remains consumed, and
physical USB removal is the documented recovery. No physical GO is declared.

## Evidence state

- **CONFIRMED:** stock USB root shell execution and the installed ABI facts
  recorded by Stages 1 and 2.
- **CONFIRMED:** the committed host build is reproducible and passes its static
  ABI/import/source gates.
- **CONFIRMED:** host-stub adversarial tests pass without running the ARM ELF.
- **CONFIRMED:** real disposable Linux FAT remount tests establish the stated
  normal-writer immutability and retained-writable-handle fail-closed behavior.
- **UNKNOWN:** whether the installed kernel, loader, and libc will load and
  return from this custom ELF.
- **UNKNOWN:** whether installed BusyBox v1.29.3 accepts the exact narrow
  remount syntax and reports the expected `/proc/mounts` transitions.
- **NOT AUTHORISED:** physical use until a new independent safety review returns
  GO for only the exact frozen commit, binary hash, payload, and one attempt.

This work does not prove RoadTop patching, ABI suitability for a feature
binary, library shadowing, persistence, application replacement, or firmware
compatibility.

## Threat model

The safety objective is exact-file execution on a normal, non-hostile stock
system, protecting against wrapper races, pathname replacement, retained
ordinary writers, and accidental mutation. It does not claim protection from
a malicious privileged root process deliberately remounting the USB RW during
the execution window.
