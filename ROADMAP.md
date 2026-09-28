# GeminiTop Mercedes-Benz RoadTop Fork — Roadmap

This roadmap describes the current engineering direction of the Mercedes-Benz-focused GeminiTop fork.

The W176 + NTG5*1 unit is the initial reference implementation and primary
development target. Future Mercedes-Benz targets require separate evidence of
hardware and software compatibility.

The project is intentionally evidence-led. Milestones should only move forward when the preceding target assumptions have been established well enough to make the next step safe and useful.

## Status key

- **COMPLETE** — milestone completed and documented
- **IN PROGRESS** — active work
- **BLOCKED** — waiting for evidence, physical testing, or another dependency
- **PLANNED** — agreed future work
- **EXPLORATORY** — useful research direction, not yet an implementation commitment

---

# Current development target

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

The project must not assume that other Mercedes RoadTop installations share the same hardware, firmware layout, touchscreen, display, MCU, CAN behaviour, or audio architecture.

---

# High-level roadmap

```text
Phase 0 — Reference research
            COMPLETE
               |
               v
Phase 1 — Safe Stage-1 target probe
            COMPLETE
               |
               v
Phase 2 — Installed v2.0.61 target capture
            COMPLETE
               |
               v
Phase 3 — Native ARMHF USB execution
            COMPLETE
               |
        +------+------+
        |             |
        v             v
Phase 4A          Phase 4B
CAN/MCU topology  Residency proof
  IN PROGRESS       IN PROGRESS
        |             |
        +------+------+
               |
               v
Phase 5 — Mercedes compatibility layer
            PLANNED
               |
               v
Phase 6 — Safe GeminiTop runtime
            PLANNED
               |
               v
Phase 7 — Additional Mercedes targets
            EXPLORATORY
```

---

# Phase 0 — Reference research

**Status: COMPLETE**

Goals:

- establish the upstream GeminiTop architecture;
- separate Audi-specific assumptions from generic Gemini/S7-QA behaviour;
- perform static analysis of the available Mercedes reference firmware;
- create conservative target profiles;
- create read-only firmware inspection tooling;
- establish evidence terminology;
- create the first W176 discovery tooling.

Completed work includes:

- Audi reference target profile;
- Mercedes reference target profile;
- W176/NTG5 target profile with unknowns preserved;
- static Benz v2.0.65 firmware inspection;
- SquashFS inventories and ELF metadata;
- host-side target comparison tooling;
- initial Stage-1 USB probe;
- firmware/probe safety documentation;
- hardened repository ignore rules;
- Mercedes-Benz-focused project documentation grounded in the W176 development target.

The Mercedes v2.0.65 firmware remains **REFERENCE ONLY** and does not prove compatibility with the installed v2.0.61 unit.

---

# Phase 1 — Safe Stage-1 target probe

**Status: COMPLETE**

Goal:

Obtain a minimal, read-only description of the actual installed RoadTop unit without modifying the target.

The Stage-1 probe is intended to establish:

- kernel identity;
- CPU/platform information;
- MTD partition metadata;
- NVM partition size;
- framebuffer geometry and properties;
- touchscreen/input devices;
- relevant application paths;
- stock USB autorun behaviour;
- mounted storage behaviour;
- availability of required userspace tools.

Safety requirements:

- output only to a positively validated removable USB filesystem;
- no firmware flashing;
- no NVM writes;
- no raw MTD writes;
- no CAN transmission;
- no MCU commands;
- no Launcher replacement;
- no SSH/network changes;
- no persistent installation;
- fail closed when assumptions are not satisfied.

Exit criterion:

A physical Stage-1 run must complete with a valid `COMPLETE` marker and produce a reviewable capture from the installed unit.

The successful physical capture and sanitised derived evidence are recorded in
`docs/platform/w176-stage1-evidence.md`.

---

# Phase 2 — Installed v2.0.61 target capture

**Status: COMPLETE**

Goal:

Collect only the additional files required to compare the installed v2.0.61 software against the Mercedes v2.0.65 reference.

This phase should remain selective and allowlisted.

Likely areas of interest include:

- Launcher and setup modules;
- MCU communication libraries;
- CarPlay-related libraries;
- audio-service components;
- illumination/day-night handling;
- system configuration relevant to target identity.

This phase must not become a general filesystem dump.

Expected output:

- exact hashes;
- metadata;
- selected static files required for offline comparison;
- no arbitrary userdata or private NVM collection.

The selected physical capture completed successfully and is recorded in
`docs/platform/w176-stage2-evidence.md`.

---

# Phase 3 — Native ARMHF USB execution

**Status: COMPLETE**

Goal:

Prove that the installed kernel, loader, and libc can load one exact,
independently reviewed project-built ARMHF ELF from removable USB and return
normally.

On 2026-09-27 the exact 5,556-byte Stage-3 probe from reviewed commit
`ee6ea0f7d0ef028c406c324e9f43f078d5f8de3f`, SHA-256
`662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789`,
executed once and returned zero. This proves the narrow native-execution
boundary, not arbitrary compatibility or persistence.

See `docs/platform/w176-stage3-physical-evidence.md`.

---

# Parallel workstream — Audio / CarPlay / MOST

**Status: EXPLORATORY**

Goal:

Create a low-latency RoadTop-to-OEM audio path while retaining:

- NTG5*1;
- factory MOST architecture;
- factory amplifier;
- factory speakers and wiring;
- OEM settings and vehicle integration.

Current research areas:

- RoadTop CarPlay audio-service architecture;
- media/call/Siri/navigation focus handling;
- `Use Car's BT Channel`;
- RoadTop local audio output path;
- microphone routing;
- OEM MOST source behaviour.

Current primary hypothesis:

A reversible digital substitution at the factory DAB audio boundary may allow RoadTop programme audio to enter the existing OEM-managed MOST path.

This remains **EXPLORATORY** until the installed hardware and DAB signal boundary are confirmed.

No donor hardware purchase or irreversible modification should be based on this hypothesis alone.

---

# Parallel workstream — Mercedes illumination / day-night behaviour

**Status: EXPLORATORY**

Goal:

Make RoadTop day/night behaviour follow the effective OEM Mercedes display day/night decision rather than simply exterior-light state.

Reference firmware currently shows the RoadTop-side translated state:

```text
HcCar type 8

0x17 -> illumination true / night
0x18 -> illumination false / day
```

These are internal RoadTop identifiers, **not Mercedes CAN arbitration IDs**.

Research goals:

- identify the real Mercedes-side source of the OEM day/night decision;
- determine whether it is available through the existing RoadTop MCU/CAN path;
- avoid using the driver brightness preference as the day/night trigger;
- preserve the existing RoadTop downstream dimmer and projection behaviour.

---

# Phase 4A — CAN / MCU topology discovery

**Status: COMPLETE — physical v5 capture validated; architecture remains CASE D / UNKNOWN**

Goal:

Understand the boundary between:

```text
Mercedes vehicle CAN
        ↓
RoadTop CAN decoder / MCU
        ↓
Linux device/protocol
        ↓
Launcher / application behaviour
```

Initial work should remain observational.

Do not transmit CAN or send MCU commands merely to discover the protocol.

The separately armed candidate under `tools/w176-stage4-topology/` collects
only bounded network/sysfs/device metadata, existing process-FD ownership, and
two installed libraries for off-target static analysis. It never opens a
candidate device stream. Earlier attempts and the v4 NO-GO are retained as
historical safety evidence. The independently reviewed v5 candidate
`4161bc3b92d61e19751358fb2e210ebfa9c4e8b2` completed physically on
2026-09-28; its frozen analyser passed with 22 checksums. No Linux type-280
interface was observed in that snapshot, positive UART owners were observed,
and process-FD coverage was PARTIAL. The formal result is CASE D — UNKNOWN;
MCU translation is an INFERENCE. See
`docs/platform/w176-stage4a-physical-evidence.md`. The next 01 analysis is an
offline static trace of the validated installed v2.0.61 MCU library.

---

# Phase 4B — First resident GeminiTop process

**Status: IN PROGRESS — host-only review candidate prepared**

Goal:

Prove that one narrowly scoped GeminiTop-owned ARMHF executable can be stored
under a dedicated, non-shadowing NVM directory, executed from that location,
and continue running while the installer USB is absent.

The candidate under `tools/w176-stage4-residency/` targets only
`/media/flash/nvm/geminitop/w176`, includes separately armed install,
post-removal verification, and exact-allowlist uninstall actions, and leaves
its heartbeat in `/tmp`. Boot persistence, stock-file modification,
`nvm/bin`/`nvm/lib` shadowing, networking, CAN, and MCU access are excluded.

The proof ELF has passed clean reproducible builds and static ABI/import
inspection. Disposable Linux tests use a host-native stand-in and do not
execute the ARM ELF. No Stage-4B target write or physical run has occurred.

Stage 4A and 4B retain separate payload/review boundaries. Stage-4A physical
success does not grant Stage-4B GO.

---

# Phase 5 — Mercedes compatibility layer

**Status: PLANNED**

Goal:

Separate truly generic Gemini/S7-QA functionality from Mercedes-specific behaviour so the runtime can make target-aware decisions.

The W176 + NTG5*1 unit is the initial reference implementation; this phase does
not establish support for other Mercedes-Benz installations.

Expected areas:

- display;
- input;
- audio;
- MCU communication;
- vehicle events;
- lifecycle;
- target capabilities;
- safe feature gating.

The compatibility layer should prefer explicit capability detection over assumptions derived from product names.

---

# Phase 6 — Safe GeminiTop runtime

**Status: PLANNED**

Goal:

Enable a Mercedes-targeted GeminiTop runtime only after the relevant physical target has been identified and validated.

Requirements before runtime deployment:

- known display configuration;
- known touchscreen/input behaviour;
- understood stock Launcher lifecycle;
- safe USB behaviour;
- explicit target profile;
- no unresolved HIGH or CRITICAL safety findings affecting deployment.

Initial Mercedes runtime work should remain reversible and USB-based wherever practical.

Persistent installation is not an initial goal.

---

# Phase 7 — Additional Mercedes targets

**Status: EXPLORATORY**

Potential future targets may include related Mercedes installations such as:

- other W176 variants;
- W117 CLA;
- X156 GLA;
- W205 and related NTG-generation RoadTop units.

Support must be evidence-driven.

A visually similar RoadTop screen or similar firmware filename does not establish hardware compatibility.

Each target should have its own evidence profile.

---

# Cross-cutting project goals

## Evidence quality

Continue using:

```text
CONFIRMED
REFERENCE ONLY
INFERENCE
UNKNOWN
```

Unknowns should remain unknown until evidence exists.

## Safety

Prefer:

```text
observe
record
compare
exit
```

over:

```text
modify
force
recover
```

## Testing

Continue expanding host-side tests for:

- malformed firmware;
- target-profile conflicts;
- probe failure modes;
- path validation;
- timeout behaviour;
- false-success prevention.

## Documentation

Keep:

- `README.md` focused on what the project is;
- `AGENTS.md` focused on agent behaviour;
- `CONTRIBUTING.md` focused on human contributors;
- workstream documentation focused on engineering evidence;
- target profiles focused on what is actually known.

---

# Immediate next milestone

The next meaningful milestone is:

> **Trace the validated installed v2.0.61 MCU library offline, then refresh
> Stage-4B as a separately reviewed residency candidate.**

Stage-4A physical capture is complete but does not resolve end-to-end topology
or authorise Stage-4B physical installation. Persistent-storage safety and
compatibility assumptions remain conservative until that payload passes its
own independent review and physical evidence gate.

---

# Guiding principle

The project does not need to appear complete before the hardware is understood.

A reliable `UNKNOWN` is more useful than an unsupported assumption.
