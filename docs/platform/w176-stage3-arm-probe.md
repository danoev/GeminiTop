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

The wrapper retains the reviewed Stage-2 removable FAT anchor and bounded
direct-child architecture. It validates and snapshots the already-open binary
descriptor, hashes the snapshot against the frozen value, performs at most one
execution attempt, accepts only exact stdout plus empty stderr and exit zero,
and creates `COMPLETE` last. Every failure path is INCOMPLETE.

## Evidence state

- **CONFIRMED:** stock USB root shell execution and the installed ABI facts
  recorded by Stages 1 and 2.
- **CONFIRMED:** the committed host build is reproducible and passes its static
  ABI/import/source gates.
- **CONFIRMED:** host-stub adversarial tests pass without running the ARM ELF.
- **UNKNOWN:** whether the installed kernel, loader, and libc will load and
  return from this custom ELF.
- **NOT AUTHORISED:** physical use until a new independent safety review returns
  GO for only the exact frozen commit, binary hash, payload, and one attempt.

This work does not prove RoadTop patching, ABI suitability for a feature
binary, library shadowing, persistence, application replacement, or firmware
compatibility.
