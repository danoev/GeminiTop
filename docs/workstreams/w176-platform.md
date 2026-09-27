# Mercedes-Benz platform workstreams — W176 development target

These workstreams begin with the installed W176 + NTG5*1 unit. Findings from
that target do not establish compatibility with other Mercedes-Benz RoadTop
installations.

Every item uses one of: CONFIRMED, REFERENCE ONLY, INFERENCE, or UNKNOWN.

## A. Common Roadtop platform

The end goal is a defensible, recoverable mechanism for deploying our own fixes
and features. Characterisation and reference comparison are gates toward that
patchability decision, not ends in themselves. The current route assessment is
maintained in `docs/platform/w176-patchability.md`.

- CONFIRMED: the installed UI reports system `2025.09.11-S7-qa-v2.0.61` and MCU
  `Z-2.01-250521`.
- CONFIRMED: Stage-1 attempt 2, using immutable payload commit
  `5f85cafd0416b0511cc4570b6e280613112d6243`, completed with
  `status=COMPLETE`, zero mandatory failures, an empty `ERRORS.txt`, and a
  regular completion marker. Its sanitised fingerprint is recorded in
  `targets/w176-ntg5/profile.json` and `docs/platform/w176-stage1-evidence.md`.
- CONFIRMED: the installed runtime is ARMv7/GEMINI with Linux 4.9.217, the
  recorded 28-entry MTD metadata map, read-only SquashFS platform/application
  roots, 8 MiB NVM, a 1920x720/32-bpp framebuffer, and `fts_ts` on `event3`.
- CONFIRMED: the successful physical Stage-2 capture from payload commit
  `059db6e6aabdd0599967e413bd28c429ab0f0458` establishes installed `8368_XU`
  build configuration, exact init/USB startup topology, NVM PATH/library
  precedence, and ELF32 ARM EABI5 hard-float through glibc 2.30's
  `/lib/ld-linux-armhf.so.3` interpreter.
- CONFIRMED: the later host-only Stage-3 build uses a pinned official Arm GNU
  A-profile 9.2-2019.12 AArch64-Linux-hosted toolchain and pinned Linux/arm64
  container; two clean builds of the inert custom ELF are byte-identical and
  the static ABI/import/source gate passes.
- CONFIRMED: the first Stage-3 mutable-snapshot wrapper was HIGH/NO-GO after a
  host race produced false COMPLETE. Its read-only-window replacement passes
  disposable Linux FAT semantics and host-stub adversarial tests. Installed
  BusyBox remount behavior was then exercised by the final reviewed physical
  transaction; the earlier wrapper remains historical NO-GO.
- CONFIRMED: the first read-only-window wrapper was also HIGH/NO-GO because
  overlapping invocations could both execute and could break one another's RO
  interval. The final revision atomically acquires a persistent FAT
  directory lock before marker handling and serializes the entire RO/hash/
  execute/RW/COMPLETE sequence. Host overlap, paused-RO, reinvocation, malformed
  lock, and 50-pair real FAT concurrency tests passed before physical use.
- CONFIRMED: on 2026-09-27 the operator returned a successful Stage-3 physical
  transaction from reviewed commit `ee6ea0f7d0ef028c406c324e9f43f078d5f8de3f`.
  The exact 5,556-byte ARMHF ELF with SHA-256
  `662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789`
  executed once and returned zero; RO/RW window verification passed and the
  one-shot lock remained. Original FAT files were not inspected by the session
  recording this operator-supplied evidence.
- REFERENCE ONLY: the Benz v2.0.65 archive contains a Gemini container, a
  validated Linux 4.9.217 uImage, and SquashFS images. Separately, the original
  Audi reconnaissance capture showed a Gemini/ARMv7 runtime and stock
  `Launcher`; the raw capture has been removed from Git.
- INFERENCE: the installed v2.0.61 and reference v2.0.65 share a substantial
  S7-QA/Gemini platform topology. Matching names, sizes, and kernel release do
  not establish byte identity or update compatibility.
- UNKNOWN: commercial board identity, compatibility of arbitrary ARM ELFs, complete
  userspace compatibility beyond the captured boundary, update compatibility,
  framebuffer pixel semantics beyond the captured channel metadata, and
  unobserved feature flags.

## B. Audio / MOST

- REFERENCE ONLY: GeminiTop's current audio backend uses `libaudio` and a
  `QtOutput`/`alternative` track on the original unit.
- UNKNOWN: which CarPlay audio endpoint the W176 unit uses.
- UNKNOWN: the exact effect of `Use Car BT` on routing and call/media behavior.
- UNKNOWN: audio-focus ownership and transitions among OEM, CarPlay, Bluetooth,
  and auxiliary sources.
- UNKNOWN: the physical Roadtop output feeding the vehicle.
- UNKNOWN: the relationship among DAB, MOST, the head unit, and Roadtop audio.

No audio-routing patch or MCU command belongs in the common-platform phase.

## C. Illumination

- REFERENCE ONLY: the investigation vocabulary includes HcCar type 8,
  `0x17`/`0x18` internal illumination Boolean candidates, and `DayNightMode`.
- INFERENCE: UI day/night state may have both an internal Roadtop source and an
  OEM Mercedes source; their relationship must be measured.
- UNKNOWN: message direction, semantics, timing, transport, and whether the
  installed W176/NTG5 unit exposes the same path.

No CAN transmission, MCU command, illumination patch, or forced day/night value
is authorized in this phase.

## Still blocked after physical Stage-3 completion

- treating the narrow Stage-3 success as approval for arbitrary native code,
  persistent installation, boot persistence, or stock-process modification;
- approving rendering solely from dimensions and 32-bpp metadata;
- treating a matching partition name/size as firmware byte compatibility;
- identifying the unit as QD507 (or any other marketing board identifier);
- staging or enabling the Gemini launcher/orchestrator on the W176 unit;
- enabling SSH/network services;
- beginning audio, MOST, illumination, CAN, or MCU changes that depend on target
  identity.

Stages 1, 2, and 3 are frozen historical evidence points. Stage-3 native USB
execution is physically confirmed for the exact reviewed binary; it does not
approve later payloads. See `docs/platform/w176-stage3-arm-probe.md` and
`docs/platform/w176-stage3-physical-evidence.md`.
