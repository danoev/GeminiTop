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
- CONFIRMED host-only: the original frozen Stage-4A candidate received an
  independent NO-GO; all ten requested findings were then reproduced in
  disposable fixtures. The remediated candidate uses a finite device/PID/FD
  policy, pre-open regular-file checks inside the read-only application mount,
  bracketed owner metadata, and exact canonical checksum coverage. FIFO open
  sentinels remained untouched in host tests. The later frozen candidate was
  independently reviewed and physically attempted; see the separate failed
  attempt record below. This sentence describes the earlier host-only state.
- CONFIRMED host-only: the second frozen Stage-4A candidate
  `11376fc13f61cf0f05a3bfd45ab287e5f42982d0` also received NO-GO.
  All 13 requested reproductions succeeded in disposable fixtures. Round 2
  adds fail-closed late finalisation, exact effective library-mount membership,
  normal proc/sysfs topology handling, independent aggregate/count validation,
  and accurately labelled final output acceptance. This does not authorise a
  physical test or change Stage-4B.
- OPERATOR-RETURNED PHYSICAL EVIDENCE: Stage-4A candidate
  `17557e6481d68799712779ca605b87e2da866e47` received independent GO,
  then two physical attempts. The first was interrupted; the second returned
  `INCOMPLETE`, `owner_limit`, and no valid COMPLETE. The partial serial/network
  observations are not validated topology evidence. See
  `docs/platform/w176-stage4a-physical-attempts.md`. TGID-aware remediation is
  required before another independent review or physical decision.
- CONFIRMED host-only: the exact frozen physical candidate counts addressable
  non-leader TIDs as distinct owners in a synthetic one-TGID/many-TID fixture,
  reproducing `owner_limit`. A new candidate reads bounded kernel TGID and
  selects process leaders only. The physical grouping of partial returned
  identities remains UNKNOWN; see `docs/platform/w176-stage4a-tgid-remediation.md`.
- INDEPENDENT REVIEW RESULT: frozen TGID-aware v4 candidate
  `d0f5d7ad651953f607414de956f24bff2d8889f9` received NO-GO. A live
  worker can retain an FD after its leader exits, while the leader's existing
  FD directory appears empty. V4 could count that as a clean zero-owner scan.
  See `docs/platform/w176-stage4a-v4-no-go.md`. The lifecycle-aware revision
  retains leader-only enumeration, stages owner evidence until post-scan
  validation, and marks incomplete process-FD coverage PARTIAL. This is
  host-only and requires a new independent review; no further vehicle action.
- CONFIRMED physical Stage-4A v5 result: independently approved candidate
  `4161bc3b92d61e19751358fb2e210ebfa9c4e8b2` completed on 2026-09-28.
  The mounted returned capture was re-analysed read-only: validation PASS,
  22 verified checksums, CASE D — UNKNOWN. No Linux type-280 interface was
  observed; Launcher and gocsdk had positive UART FD ownership. Process-FD
  coverage was PARTIAL, so negative ownership claims are unavailable. MCU
  translation remains INFERENCE. See
  `docs/platform/w176-stage4a-physical-evidence.md`. The 02 workstream has
  already received the initial topology handoff and requested an offline trace
  of the installed v2.0.61 MCU library.
- CONFIRMED host-only: the Stage-4B 5,556-byte proof daemon has SHA-256
  `57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6`.
  Two clean pinned-toolchain builds match and the complete static ELF/ABI/
  interpreter/NEEDED/version/import/string gate passes. Disposable Linux
  install/removal/uninstall tests replace it with a host-native stand-in; the
  ARM binary was not executed or emulated.
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
  unobserved feature flags. Persistent execution from the proposed dedicated
  NVM directory remains UNKNOWN until separately reviewed physical evidence.

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
`docs/platform/w176-stage3-physical-evidence.md`. The reviewed Stage-4A v5
capture completed; architecture classification remains CASE D — UNKNOWN.
Stage-4B remains a separate host-only candidate without physical approval.
