# AGENTS.md

## Purpose

This repository is a Mercedes-Benz-focused engineering fork of [martexas/GeminiTop](https://github.com/martexas/GeminiTop).

Its current purpose is to reverse-engineer, document, and cautiously extend RoadTop Linux display units used in Mercedes-Benz vehicles, with the primary development target being a RoadTop unit installed in a Mercedes-Benz W176 A45 AMG with factory NTG5*1 infotainment.

This is currently an **engineering and target-identification project**, not a supported Mercedes launcher distribution.

Agents working in this repository must prioritise:

1. safety;
2. evidence quality;
3. reproducibility;
4. minimal assumptions;
5. reversible changes;
6. clear separation between reference data and facts confirmed on the actual target.

---

# Primary development target

Current confirmed target information:

```text
Vehicle:
Mercedes-Benz W176 A45 AMG

OEM infotainment:
NTG5*1

RoadTop system software:
2025.09.11-S7-qa-v2.0.61

RoadTop MCU:
Z-2.01-250521
```

These values are owner-observed and may be treated as **CONFIRMED**.

Do **not** silently infer additional hardware properties from them.

The following are examples of properties which must remain UNKNOWN until directly established on the installed unit:

- RoadTop board identifier;
- SoC / board revision;
- `QD507`, `QD513`, `QD515`, or other marketing/platform identifier;
- Linux kernel version;
- partition map;
- NVM size;
- framebuffer geometry;
- framebuffer format;
- touchscreen controller;
- MCU protocol details;
- CAN arbitration IDs;
- audio hardware;
- RoadTop local audio output path;
- USB-handler hash;
- update compatibility;
- firmware compatibility.

---

# Evidence model

All engineering conclusions should use one of these states.

## CONFIRMED

Observed directly on the actual target, or proven directly from the exact source being discussed.

Examples:

- a value shown on the installed RoadTop's own version screen;
- data captured by the approved Stage-1 probe from the installed unit;
- behaviour directly demonstrated from the relevant firmware/library;
- a hash calculated from an actual file.

## REFERENCE ONLY

Known from another firmware image, hardware target, upstream implementation, or related unit but not yet demonstrated on the installed W176 RoadTop.

Examples:

- properties found in the Benz v2.0.65 reference firmware;
- Audi GeminiTop hardware properties;
- paths or device names found in upstream GeminiTop;
- assumptions learned from a different RoadTop model.

## INFERENCE

A conclusion supported by evidence but not directly demonstrated.

Inference is allowed when useful, but must be labelled as such.

## UNKNOWN

Not yet established.

**Never replace UNKNOWN with a plausible guess merely to complete an implementation.**

**Never silently promote REFERENCE ONLY or INFERENCE to CONFIRMED.**

---

# Core engineering rule

> When evidence is insufficient, preserve UNKNOWN and identify the smallest safe test that would resolve it.

Do not fill gaps with assumptions simply because an upstream implementation, similar firmware, or related RoadTop model behaves a certain way.

---

# Safety invariants

Unless the user has explicitly authorised a later engineering phase, agents must not perform or prepare destructive or persistent target-side actions.

## Do not

- flash firmware;
- create or modify firmware for flashing;
- create a "probably compatible" firmware build;
- execute extracted RoadTop ARM binaries;
- emulate extracted RoadTop ARM binaries;
- write raw MTD, NAND, eMMC, or block devices;
- modify internal NVM;
- copy arbitrary private/user NVM data;
- access `/dev/mem`;
- use `dd` against internal device nodes;
- use `nandwrite`, `flash_erase`, `mtd`, `fw_setenv`, `devmem`, or equivalent tools against the target;
- transmit vehicle CAN frames during discovery;
- send MCU commands during discovery;
- alter the stock Launcher during target identification;
- kill, suspend, freeze, or replace target services during target identification;
- install persistent software on the RoadTop;
- alter target networking;
- start SSH, Dropbear, Telnet, Netcat, or equivalent listeners merely for convenience;
- assume firmware is safe to flash because its version is newer;
- assume firmware is compatible because a marketing identifier appears similar;
- assume a reference firmware represents the installed hardware.

Static firmware analysis is **not** evidence of flash compatibility.

A matching software family is **not** proof of matching hardware.

`QD507` or similar external labels are **not** proof of board identity.

---

# Stage-1 probe rules

The first physical RoadTop interaction must remain a minimal observation-only probe.

The intended flow is:

```text
USB inserted
    ↓
stock RoadTop autorun handler
    ↓
gemn_auto.sh
    ↓
Stage-1 observer
    ↓
read metadata only
    ↓
write report only to removable USB
    ↓
exit
```

It must **not** become:

```text
USB inserted
    ↓
GeminiTop launcher/orchestrator
    ↓
stock processes modified
    ↓
network/SSH/runtime replacement
```

## Stage-1 must not

- flash anything;
- write NVM;
- write raw MTD;
- read raw MTD payloads;
- transmit CAN;
- issue MCU commands;
- open raw CAN/MCU/input-event streams;
- alter Launcher;
- alter services;
- alter networking;
- start persistent listeners;
- install software;
- reboot the unit;
- invoke the firmware updater.

## Stage-1 output safety

Probe output must only be written to a positively identified removable USB filesystem.

Do not infer "USB" merely from:

- the script directory;
- an existing path;
- a directory under `/tmp`;
- a path resembling a mount point.

The probe must fail closed if it cannot prove the output root is the expected mounted removable device.

If zero or multiple valid candidate USB mounts exist, stop rather than guess.

Do not introduce system-wide `sync` or other unnecessary global writeback operations.

A completion marker must only be created after all mandatory collection and output steps succeed.

Failure should result in:

```text
STOP
SKIP
ERROR
```

rather than silently falling back to an internal filesystem or falsely reporting success.

---

# Firmware analysis rules

Firmware work in this repository is primarily static/offline analysis.

## Allowed

- hashing archives and members;
- parsing headers;
- validating bounds;
- identifying uImage structures;
- identifying SquashFS structures;
- read-only `unsquashfs` listing or file streaming;
- filesystem inventories;
- ELF metadata and hashes;
- structural comparison;
- metadata reports;
- documentation.

## Not allowed by default

- executing target firmware;
- emulating target firmware;
- repacking firmware;
- creating flashable images;
- altering reference firmware;
- using fixed Audi offsets on another target without proof;
- committing proprietary firmware payloads.

Firmware inspectors must:

- validate offsets and lengths before reading;
- reject malformed/truncated structures cleanly;
- use safe subprocess argument arrays rather than shell interpolation;
- prevent output files from aliasing or overwriting firmware inputs;
- apply reasonable time/resource bounds;
- clean up temporary data;
- distinguish validated structures from speculative candidates;
- report truncated discovery or incomplete inspection explicitly.

---

# Proprietary and sensitive data

Do not commit:

- firmware ZIP archives;
- `ISPBOOOT.BIN`;
- `GEMINI_PACK.BIN`;
- SquashFS images;
- extracted proprietary filesystem trees;
- copied RoadTop firmware ELF binaries;
- raw NVM dumps;
- userdata;
- credentials;
- raw physical probe captures unless explicitly reviewed and approved;
- sensitive environment/network captures.

Commit-safe outputs may include:

- hashes;
- metadata inventories;
- validated structural reports;
- documentation;
- test fixtures that do not contain proprietary firmware content;
- intentionally sanitised probe summaries.

When adding ignore rules, consider common extraction layouts such as:

```text
squashfs-root/
extracted_*/
rootfs*/
spapp*/
spsdk*/
```

Do not rely on `.gitignore` alone as a security boundary. Always inspect tracked/staged content.

---

# Target profiles

The repository distinguishes between different evidence sources.

Typical structure:

```text
targets/
├── audi-reference/
├── mercedes-reference/
└── w176-ntg5/
```

## Audi reference

Contains inherited upstream assumptions and known properties from the original GeminiTop development target.

Treat as **REFERENCE ONLY** for Mercedes work unless independently confirmed.

## Mercedes reference

Contains properties established from static Mercedes firmware analysis.

Treat as **REFERENCE ONLY** for the installed W176 target unless independently confirmed there.

## W176 NTG5 target

Represents the actual development vehicle.

Unknown fields must remain UNKNOWN until established from the physical unit.

Do not silently inherit reference values into the W176 profile.

Examples of fields that must not be copied into W176 merely because they exist in a reference profile:

- QD identifier;
- kernel version;
- NVM size;
- display geometry;
- framebuffer format;
- touch controller;
- firmware offsets;
- device names;
- audio paths;
- MCU semantics;
- CAN IDs.

Target-comparison output should use conservative states such as:

```text
MATCH
DIFFERENT
UNKNOWN
```

A partial reference match must never be reported as:

```text
QD507 confirmed
firmware compatible
safe to flash
```

---

# Mercedes-specific workstreams

Current engineering work includes several related but distinct workstreams.

## RoadTop platform identification

Goal:

- establish the actual installed hardware/software baseline;
- confirm partition layout;
- confirm kernel;
- confirm touch/framebuffer;
- confirm stock autorun behaviour;
- establish safe runtime assumptions.

## Audio / CarPlay / MOST

Goal:

- identify RoadTop CarPlay audio architecture;
- establish low-latency local RoadTop audio endpoints;
- understand media/call/Siri/navigation focus behaviour;
- investigate integration with factory NTG5*1 and external MOST audio.

Do not assume the RoadTop's physical audio sink until observed.

Do not assume DAB substitution or MOST injection is viable until the relevant hardware/software boundary is confirmed.

## Illumination / day-night

Reference firmware analysis currently indicates a translated Linux-side illumination Boolean:

```text
HcCar type 8

0x17 -> illumination true / night
0x18 -> illumination false / day
```

This is a RoadTop internal translated value, **not a Mercedes CAN arbitration ID**.

The desired engineering target is to follow the effective OEM Mercedes day/night decision rather than merely treating exterior-lamp state as darkness.

Do not invent CAN IDs.

## Firmware compatibility

The Benz v2.0.65 archive is static reference material.

It is not an approved update for the installed v2.0.61 W176 unit.

Do not recommend flashing it unless later hardware evidence and compatibility work explicitly establishes that conclusion.

---

# Repository workflow

## Branching

Use feature branches for engineering changes.

Do not work directly on `main` unless explicitly requested.

For current W176 platform work, preserve the established branch/PR workflow where appropriate.

## Pull requests

During experimental or safety-sensitive development:

- keep PRs in draft state;
- do not merge unless explicitly requested;
- use PR review as a safety gate;
- keep changes reviewable and narrowly scoped.

## Commits

Prefer small, coherent commits.

Commit messages should explain the engineering purpose, not merely the file changed.

Examples:

```text
Harden W176 Stage-1 USB validation
Reject firmware inspector output/input aliasing
Document Mercedes target evidence states
```

## Minimal-change principle

When fixing a safety or correctness issue:

> Make the smallest change that fully closes the finding unless an architectural change is clearly necessary.

Do not turn narrow fixes into broad rewrites simply because refactoring is possible.

---

# Tests

Before committing changes, run the relevant tests.

At minimum, where applicable:

- firmware inspector tests;
- target-identification tests;
- shell syntax checks;
- Python compile/syntax checks;
- deterministic report checks;
- Git diff/whitespace checks.

Safety-sensitive probe changes should include host-side tests for failure conditions where possible.

Examples:

- no valid USB mount;
- multiple USB mounts;
- wrong filesystem type;
- arbitrary/internal output path;
- read-only output;
- full output filesystem;
- existing output directories;
- missing commands;
- special files;
- symlinks;
- timeout conditions;
- false-success prevention.

Passing tests do not by themselves establish physical-target safety.

---

# Working style

This project is evidence-led.

Prefer:

- direct source inspection;
- hashes;
- reproducible tests;
- static analysis;
- target observations;
- explicit uncertainty;
- narrow, reversible experiments;
- documentation of why a conclusion is valid.

Avoid:

- speculative compatibility claims;
- premature hardware assumptions;
- destructive testing when a passive test is available;
- broad architecture changes without need;
- copying reference assumptions into the live target;
- "best guess" values where UNKNOWN is more accurate.

When a conclusion depends on a physical observation not yet available, state that clearly.

---

# Agent behaviour

Agents should inspect existing architecture and documentation before making changes.

Do not redo established work unless:

- the current implementation is demonstrably incorrect;
- a safety finding requires it;
- the user explicitly asks for redesign.

Before changing code, identify:

1. the exact problem;
2. the evidence supporting the change;
3. the smallest safe modification;
4. the tests required to validate it.

If a requested task conflicts with the project's safety invariants, stop and explain the conflict rather than improvising a workaround.

---

# Reporting format

When completing engineering work, report:

## Branch

```text
<branch-name>
```

## Final commit

```text
<full commit SHA>
```

## Files changed

List each meaningful file changed and why.

## Tests run

List the exact tests/checks and results.

## Confirmed findings

Only include facts supported by the work performed.

## Remaining unknowns

Explicitly list important unresolved items.

## Safety impact

State whether the change:

- alters target-side behaviour;
- introduces writes;
- changes USB handling;
- changes networking;
- changes firmware handling;
- affects physical-test approval.

## Physical validation required

State exactly what still requires the actual RoadTop unit.

Do not present host-side success as proof of target-side compatibility.

---

# Review severity

For code and safety review, use:

```text
CRITICAL
HIGH
MEDIUM
LOW
INFO
```

A physical test should not proceed while unresolved HIGH or CRITICAL findings affect that test path.

---

# Current safety posture

Until explicitly updated by later evidence:

```text
Reference firmware flashing:
NO / UNPROVEN

Mercedes runtime replacement:
NOT YET APPROVED

Stage-1 physical probe:
ONLY AFTER THE CURRENT PROBE REVISION PASSES SAFETY REVIEW

Raw CAN/MCU experimentation:
NOT PART OF INITIAL DISCOVERY

GeminiTop SSH/runtime deployment:
NOT PART OF INITIAL DISCOVERY
```

This section should be updated when the engineering state genuinely changes.

---

# Upstream relationship

This repository remains derived from the original GeminiTop project.

Preserve upstream attribution and licence requirements.

When a behaviour comes from upstream GeminiTop, identify it as upstream/reference behaviour rather than silently presenting it as Mercedes-confirmed behaviour.

---

# Final principle

> Preserve the ability to distinguish what we know, what we think, and what we have not yet established.

That distinction is more valuable to this project than making the code appear complete before the target is understood.
