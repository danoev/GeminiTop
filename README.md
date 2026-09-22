# GeminiTop — Mercedes-Benz RoadTop Fork

> A Mercedes-Benz-focused fork of [martexas/GeminiTop](https://github.com/martexas/GeminiTop) for understanding and extending RoadTop Linux display units in Mercedes-Benz vehicles.

## Project status

**Early development / reverse-engineering phase.**

This repository is not currently a plug-and-play Mercedes GeminiTop release.

The immediate goal is to understand the installed RoadTop hardware and software safely, establish its exact characteristics, and develop a Mercedes-Benz compatibility layer based on target evidence. Support for other Mercedes-Benz vehicles, NTG generations, screens, boards, MCUs, or firmware is not assumed.

The initial reference implementation and current primary development target is a RoadTop S7-QA Linux display installed in a Mercedes-Benz W176 A45 AMG using the factory NTG5*1 system. Other Mercedes-Benz targets may be considered only after their compatibility is established independently.

Installed RoadTop software currently reports:

```text
System Software:
2025.09.11-S7-qa-v2.0.61

MCU:
Z-2.01-250521
```

A newer Mercedes/Benz S7-QA v2.0.65 firmware package is also being studied as **static reference material only**.

It is not currently considered safe or appropriate to flash that firmware onto the development unit.

---

## Why this fork exists

GeminiTop demonstrated that these RoadTop Linux displays can run software from USB through the stock `gemn_auto.sh` mechanism without permanently replacing the original firmware.

The original project was developed against an Audi-oriented RoadTop target.

That legacy Audi-targeted material is retained as reference-only for the
Mercedes work. It must not be treated as compatible with, or deployed to, the
W176 target without independent target identification and review.

This fork is intended to take that work in a different direction:

- identify and document Mercedes RoadTop hardware accurately;
- separate generic Gemini/S7-QA behaviour from vehicle-specific assumptions;
- create Mercedes-specific target profiles;
- develop safe inspection and diagnostic tools;
- investigate RoadTop audio routing and CarPlay behaviour;
- investigate Mercedes CAN/MCU integration;
- improve day/night and illumination behaviour;
- ultimately provide a Mercedes-focused GeminiTop runtime once the hardware is properly understood.

The project currently prioritises **evidence and compatibility detection before runtime modification**.

---

## Primary target

Current development vehicle:

```text
Vehicle:
Mercedes-Benz W176 A45 AMG

OEM infotainment:
NTG5*1

RoadTop:
12.3-inch Linux display for Mercedes A-Class / CLA / GLA NTG5 generation

RoadTop software:
2025.09.11-S7-qa-v2.0.61

RoadTop MCU:
Z-2.01-250521
```

The repository should not assume that every Mercedes RoadTop screen shares the same:

- SoC or board revision;
- flash partition layout;
- touchscreen controller;
- display timing;
- framebuffer format;
- MCU firmware;
- CAN decoder;
- audio hardware;
- software build;
- or update compatibility.

Those characteristics are treated as target evidence rather than universal constants.

---

## Current engineering workstreams

### 1. RoadTop platform identification

Before enabling the GeminiTop runtime on the Mercedes target, the installed unit is being characterised using a minimal USB Stage-1 probe.

The probe is intended to establish things such as:

- CPU / platform identity;
- Linux kernel;
- flash partition metadata;
- NVM partition size;
- touchscreen hardware;
- framebuffer configuration;
- stock USB autorun behaviour;
- running services and application structure.

The first probe is deliberately observation-only.

It does **not**:

- flash firmware;
- write NVM;
- write raw MTD storage;
- transmit CAN;
- issue MCU commands;
- replace the stock Launcher;
- start SSH;
- alter networking;
- or persist anything onto the RoadTop unit.

Probe output is written to USB.

Both the autorun entry point and the probe independently require the script
directory to be the exact mount point of the single mounted removable
`/dev/sd...` partition and require an approved FAT/vfat filesystem. The probe
fails closed on missing, ambiguous, or invalid media. Each run writes explicit
status, error, and optional-operation manifests; a `COMPLETE` marker is created
only after every mandatory collection and write succeeds.

See:

```text
tools/w176-probe/
```

---

### 2. Mercedes firmware analysis

A Mercedes S7-QA firmware archive is being analysed offline:

```text
QD507-Benz-QA-2026.02.05-v2.0.65
```

This firmware is treated as **REFERENCE ONLY**.

The repository contains tooling capable of inspecting firmware structure without relying on the fixed offsets used by the original Audi-specific tooling.

The read-only inspector can identify and record:

- archive and component hashes;
- Gemini container information;
- uImage structures;
- SquashFS filesystems;
- filesystem inventories;
- ELF path / size / hash metadata;
- partition-layout evidence.

It does not execute or emulate target ARM binaries and does not create flashable firmware.

See:

```text
firmware_tools/scripts/inspect_firmware.py
docs/platform/benz-reference.md
reports/firmware/
```

Proprietary firmware archives and extracted firmware files are intentionally excluded from Git.

---

### 3. Audio / CarPlay / MOST

One major goal of the project is improving the audio path between RoadTop CarPlay and the factory Mercedes audio system.

The development vehicle retains:

- NTG5*1;
- the factory external MOST audio architecture;
- factory amplifier;
- factory speakers and vehicle controls.

Current investigation includes:

- RoadTop CarPlay audio routing;
- `Use Car's BT Channel`;
- media / navigation / Siri / telephone audio;
- RoadTop audio-focus behaviour;
- identifying the RoadTop's local low-latency audio endpoint;
- integration with the factory Mercedes MOST audio path.

A longer-term experimental route is the investigation of the factory DAB audio source boundary as a possible reversible RoadTop-to-OEM digital audio injection point.

This work is still exploratory.

See:

```text
docs/workstreams/
```

---

### 4. Mercedes illumination / day-night behaviour

The RoadTop currently switches between its saved Day and Night brightness levels according to a translated vehicle illumination state.

Static analysis of the Mercedes reference firmware has identified the RoadTop-side mechanism:

```text
HcCar type 8

0x17 -> illumination true / night
0x18 -> illumination false / day
```

This Boolean ultimately controls:

- RoadTop Day/Night state;
- the saved Day and Night dimmer levels;
- CarPlay night mode;
- Android Auto night mode where supported.

The current investigation is focused on identifying the Mercedes-side state that should drive this behaviour.

The desired behaviour is for RoadTop to follow the same effective **day/night decision used by the OEM Mercedes displays**, rather than simply changing to night mode whenever sidelights or dipped headlights are active.

No Mercedes CAN arbitration ID has yet been established for that state.

---

## Target profiles

This fork introduces target profiles so that reference information does not silently become hardware fact.

Current structure:

```text
targets/
├── audi-reference/
├── mercedes-reference/
└── w176-ntg5/
```

The distinction is intentional.

### Audi reference

Documents assumptions and behaviour inherited from the original GeminiTop development target.

### Mercedes reference

Contains information established from static analysis of the available Mercedes firmware.

### W176 NTG5 target

Represents the actual development vehicle.

Unknown characteristics remain explicitly **UNKNOWN** until confirmed from the installed unit.

A partial match against a reference profile does not mean:

```text
QD507 confirmed
firmware compatible
safe to flash
```

Target comparison uses conservative results such as:

```text
MATCH
DIFFERENT
UNKNOWN
```

---

## Evidence states

Project documentation should distinguish between:

### CONFIRMED

Observed directly on the development unit or established directly from the relevant code/data.

### REFERENCE ONLY

Established from another known firmware or hardware target but not yet confirmed on the development unit.

### INFERENCE

A conclusion supported by available evidence but not directly demonstrated.

### UNKNOWN

Not yet established.

This distinction is important because RoadTop appears to reuse similar software across multiple vehicle and hardware variants.

---

## Safety principles

Until the Mercedes target is sufficiently characterised, this project follows several rules:

- do not flash reference firmware merely because version numbers look compatible;
- do not assume Audi firmware offsets apply to Mercedes;
- do not treat marketing identifiers such as `QD507` as hardware proof;
- do not execute extracted target firmware during analysis;
- do not transmit vehicle CAN or MCU commands during discovery;
- do not replace the stock RoadTop launcher on an unverified target;
- do not enable network services or SSH merely for convenience;
- prefer passive and reversible investigation techniques.

The currently analysed Benz v2.0.65 firmware is **not an approved update for the installed development unit**.

---

## Repository layout

Some of the most relevant areas are:

```text
targets/
    Target/reference profiles

tools/w176-probe/
    Minimal read-only Stage-1 hardware probe

tools/target-identify/
    Host-side probe/profile comparison

firmware_tools/
    Firmware inspection and legacy firmware utilities

docs/platform/
    RoadTop platform and target research

docs/workstreams/
    Mercedes-Benz platform workstreams, beginning with W176

reports/firmware/
    Commit-safe firmware metadata reports

libgemini/
    Original GeminiTop hardware compatibility layer

launcher/
orchestrator/
apps/
    Original GeminiTop runtime and applications
```

The original launcher/runtime remains part of the repository, but active Mercedes runtime support is not yet considered established.

---

## Development

The original GeminiTop project already provides an ARM build environment and application framework.

Docker remains available for reproducible builds:

```bash
./docker_build.sh
```

The native build system can also be used:

```bash
./build.sh
```

Before building or deploying applications to a Mercedes target, confirm that the relevant target profile has been established.

Firmware-analysis tooling is host-side Python and can be used independently of the ARM runtime.

For example:

```bash
python3 firmware_tools/scripts/inspect_firmware.py \
    /path/to/reference-firmware.zip \
    --output reports/firmware/reference.json
```

For complete SquashFS filesystem inventories, `unsquashfs` from `squashfs-tools` is used in read-only mode.

On macOS with Homebrew:

```bash
brew install squashfs
```

---

## Current roadmap

The immediate development sequence is:

```text
Mercedes firmware reference
            +
       Stage-1 probe
            |
            v
   identify real W176 target
            |
            v
       Stage-2 capture
            |
      +-----+-----+
      |           |
      v           v
   AUDIO      ILLUMINATION
      |           |
      +-----+-----+
            |
            v
Mercedes compatibility layer
            |
            v
 future GeminiTop deployment
```

The first major milestone is therefore not a new launcher.

It is a trustworthy description of the actual Mercedes RoadTop hardware.

---

## Upstream GeminiTop

This repository is a fork of:

**GeminiTop by martexas**

https://github.com/martexas/GeminiTop

The original project demonstrated the USB runtime approach, developed `libgemini`, the launcher/orchestrator architecture and multiple applications against an Audi-oriented RoadTop unit.

This fork retains that work while developing a different vehicle target and a more explicit target-detection architecture.

Please refer to the upstream project for its original documentation, history and releases.

---

## Disclaimer

This is an experimental reverse-engineering and development project.

RoadTop units differ between vehicle families and hardware revisions, and incorrect firmware or low-level changes may render a unit unusable.

Do not assume that firmware, offsets, binaries, MCU software or configuration from one RoadTop unit are compatible with another.

Until a target is explicitly documented as supported, treat all deployment work as experimental.

---

## Licence

This fork retains the licence and attribution of the upstream GeminiTop project.

See:

```text
LICENSE
```
