# Contributing to GeminiTop — Mercedes-Benz RoadTop Fork

Thank you for considering contributing to this project.

This repository is a Mercedes-Benz-focused engineering fork of [martexas/GeminiTop](https://github.com/martexas/GeminiTop), currently centred on understanding and extending RoadTop Linux display units installed in Mercedes-Benz vehicles.

The primary development target is currently:

```text
Mercedes-Benz W176 A45 AMG
OEM infotainment: NTG5*1
RoadTop system software: 2025.09.11-S7-qa-v2.0.61
RoadTop MCU: Z-2.01-250521
```

The project is still in an active reverse-engineering and target-identification phase.

It is therefore particularly important that contributions distinguish between what has actually been observed and what merely appears likely based on another RoadTop unit, firmware family, vehicle or upstream implementation.

---

## Before contributing

Please read:

```text
README.md
AGENTS.md
docs/platform/
docs/workstreams/
```

before making substantial changes.

In particular, please understand the project evidence model and safety principles described below.

---

# Evidence model

All technical findings should be classified as one of the following.

## CONFIRMED

Directly observed on the specific target being discussed, or proven from the exact code, firmware or hardware under examination.

Examples:

- software version shown by the installed RoadTop;
- output from an approved target probe;
- a value directly present in a firmware binary;
- a function or behaviour established through static analysis;
- a file hash calculated from the actual file.

## REFERENCE ONLY

Known from another target, firmware image, upstream implementation or related RoadTop unit.

Examples:

- a property found in Audi GeminiTop;
- a value found in Mercedes v2.0.65 firmware when the installed unit runs v2.0.61;
- a device path observed on another RoadTop screen.

Reference evidence is valuable, but must not silently become a fact about another target.

## INFERENCE

A conclusion supported by available evidence but not directly demonstrated.

Inference is welcome when clearly labelled.

## UNKNOWN

Not yet established.

Unknown values should remain UNKNOWN until evidence exists.

> Do not replace an unknown with a plausible guess simply to make an implementation appear complete.

---

# Current project priorities

The current engineering priorities are broadly:

```text
Mercedes firmware reference analysis
                +
       physical Stage-1 target probe
                |
                v
        identify real target
                |
                v
          Stage-2 capture
                |
       +--------+--------+
       |                 |
       v                 v
  Audio / MOST      Illumination
       |                 |
       +--------+--------+
                |
                v
      Mercedes runtime layer
                |
                v
   future GeminiTop deployment
```

Contributions which help establish the hardware baseline, improve safe tooling, document findings, or isolate vehicle-specific behaviour are especially useful.

---

# Useful contributions

Examples of welcome contributions include:

- RoadTop hardware observations;
- Mercedes-specific target profiles;
- Stage-1 probe results from additional RoadTop units;
- documentation improvements;
- firmware metadata analysis;
- safe read-only inspection tooling;
- test coverage;
- CarPlay/audio-routing research;
- Mercedes MOST research;
- illumination/day-night behaviour research;
- target-comparison improvements;
- framebuffer/touchscreen investigation;
- reproducible bug reports;
- corrections to assumptions that have been disproven by evidence.

---

# Contributions requiring extra caution

Changes involving the following areas should be treated as safety-sensitive:

- raw flash access;
- firmware flashing;
- NVM;
- CAN transmission;
- MCU communication;
- RoadTop update mechanisms;
- Launcher replacement;
- system services;
- target networking;
- SSH/Telnet/Netcat;
- boot behaviour;
- persistent target modifications.

Do not introduce these behaviours into discovery or probe tooling without an explicit engineering justification and review.

During the current target-identification phase, observation should be preferred over modification wherever possible.

---

# Firmware contributions

Please **do not commit proprietary RoadTop firmware**.

This includes:

```text
*.zip firmware archives
ISPBOOOT.BIN
GEMINI_PACK.BIN
raw SquashFS images
extracted proprietary root filesystems
copied RoadTop firmware executables
NVM dumps
userdata captures
```

Firmware-derived metadata is generally acceptable where it does not reproduce proprietary code.

Examples include:

- SHA-256 hashes;
- filenames;
- sizes;
- filesystem inventories;
- partition metadata;
- ELF hashes;
- structural reports;
- firmware-analysis documentation.

If unsure whether something is appropriate to commit, open an issue or discussion before adding it.

---

# Hardware reports

Reports from additional Mercedes/RoadTop installations are extremely useful.

Please avoid reporting assumptions as hardware facts.

For example:

```text
"QD507 because the update file says QD507"
```

is not equivalent to:

```text
"Board identifier QD507 was directly observed from the installed device"
```

When contributing information from another vehicle, please use the template below.

---

# Hardware report template

```markdown
## Vehicle

Manufacturer:
Mercedes-Benz

Model:
e.g. A45 AMG

Chassis:
e.g. W176

Model year:

Country/market:

---

## OEM infotainment

System:
e.g. NTG5*1

Factory external amplifier:
Yes / No / Unknown

Factory MOST:
Yes / No / Unknown

Other relevant factory equipment:

---

## RoadTop unit

Screen size:

Product listing / model if known:

Physical labels photographed:
Yes / No

Board identifier:
CONFIRMED / REFERENCE ONLY / UNKNOWN

Reported system software:

Reported MCU version:

---

## RoadTop settings

Car model/profile selected:

Headlamp Detection:
On / Off / Unknown

Use Car's BT Channel:
On / Off / Unknown

Other relevant settings:

---

## Observed behaviour

Describe only behaviour directly observed.

Examples:

- when sidelights are switched on...
- when CarPlay starts...
- when the factory radio is selected...
- when the vehicle enters night mode...

---

## Probe data

Stage-1 probe version / commit:

Probe completed:
Yes / No

COMPLETE marker present:
Yes / No

Sanitised probe output attached:
Yes / No

---

## Evidence classification

### CONFIRMED

- ...

### REFERENCE ONLY

- ...

### INFERENCE

- ...

### UNKNOWN

- ...

---

## Photos

Please include useful photos where possible:

- RoadTop About/version screen;
- MCU/version page;
- physical product label;
- vehicle infotainment screen;
- relevant settings pages.

Avoid including:

- VIN;
- home addresses;
- credentials;
- Wi-Fi passwords;
- personally identifying information.
```

---

# Bug reports

When reporting a bug, please include enough context to establish the affected target.

A useful bug report should contain:

```markdown
## Target

Vehicle/chassis:

OEM infotainment:

RoadTop software:

RoadTop MCU:

Target profile:

## Problem

What happened?

## Expected behaviour

What should have happened?

## Reproduction

1.
2.
3.

## Evidence

Logs:
Screenshots:
Probe data:
Commit SHA:

## Safety impact

Does this involve:

- target writes?
- CAN?
- MCU?
- firmware?
- networking?
- boot behaviour?

Yes / No / Unknown
```

---

# Research findings

Reverse-engineering findings are welcome even where they do not immediately result in code.

Please structure research findings around evidence.

A useful format is:

```markdown
## Question

What were you trying to establish?

## Evidence

What files, hardware observations or tests were used?

## Finding

What was directly established?

## Evidence state

CONFIRMED / REFERENCE ONLY / INFERENCE

## Remaining unknowns

What is still not proven?

## Suggested next test

What is the smallest safe experiment that would resolve the next unknown?
```

---

# Pull requests

Please keep pull requests focused.

Prefer:

- one engineering objective per PR;
- clear commit messages;
- tests covering new behaviour;
- documentation updates where assumptions change;
- explicit notes about safety impact.

Avoid combining unrelated refactoring with functional changes unless necessary.

For experimental or safety-sensitive work, draft pull requests are encouraged.

Do not merge a PR merely because tests pass.

Tests establish software behaviour; they do not automatically establish compatibility with physical RoadTop hardware.

---

# Branch naming

Descriptive feature branches are preferred.

Examples:

```text
feature/w176-platform
feature/mercedes-audio-routing
feature/illumination-state
fix/stage1-usb-validation
docs/hardware-reporting
```

---

# Commit messages

Prefer messages which describe the engineering intent.

Good examples:

```text
Harden Stage-1 USB mount validation

Add Mercedes illumination evidence notes

Reject conflicting target-identification evidence

Document W176 RoadTop target baseline
```

Less useful:

```text
Update file

Fix stuff

Changes
```

---

# Tests

Run the relevant tests before submitting a pull request.

Depending on the change, this may include:

```text
firmware inspector tests
target-identification tests
Stage-1 safety tests
Python syntax/compile checks
POSIX shell syntax checks
deterministic output comparison
Git whitespace checks
```

New safety-sensitive behaviour should include tests for failure conditions as well as successful operation.

For example:

```text
no valid USB
multiple USB devices
wrong filesystem
read-only storage
full storage
missing command
timeout
symlink/special file
partial write
conflicting evidence
```

---

# Target profiles

Do not copy reference properties into a physical target profile merely because they appear likely.

For example, the following should not be inherited into `w176-ntg5` without direct evidence:

```text
QD507
8368_XU
Linux 4.9.217
8 MiB or 9 MiB NVM
Goodix touchscreen
FocalTech touchscreen
1920x720 framebuffer
device paths
CAN IDs
MCU commands
audio routes
firmware offsets
```

A target profile should accurately represent what is known, not what is expected.

---

# Compatibility claims

Please avoid claims such as:

```text
works on Mercedes
safe to flash
W176 compatible
same hardware
QD507 confirmed
```

unless the required evidence genuinely exists.

Preferred wording is:

```text
MATCH
DIFFERENT
UNKNOWN
REFERENCE ONLY
CONFIRMED on <specific target>
```

---

# Physical testing

Any test performed on a vehicle or physical RoadTop unit should be designed so that the expected failure mode is safe.

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
retry
force
recover
```

Where possible, define the abort criteria before starting the test.

Physical testing should not proceed while unresolved HIGH or CRITICAL review findings affect the relevant test path.

---

# Privacy

Probe results and diagnostic reports may expose information such as:

- process names;
- mount paths;
- hardware serials;
- network configuration;
- device identifiers.

Review captures before publishing them.

Please remove unnecessary personal or identifying information.

---

# Coding style

There is currently no intention to impose a large stylistic framework on the upstream project.

Prefer:

- readable code;
- explicit failure handling;
- conservative defaults;
- bounded operations;
- clear comments where safety depends on behaviour;
- minimal dependencies;
- compatibility with the target environment.

For shell code, pay particular attention to:

- quoting;
- path validation;
- symlinks;
- special files;
- inherited environment;
- command availability;
- timeouts;
- failure propagation.

---

# AI-assisted contributions

AI-assisted development is welcome.

If using Codex, ChatGPT, Claude or another coding agent, please point it at the repository's:

```text
AGENTS.md
```

before allowing it to make substantial changes.

Contributors remain responsible for reviewing agent-generated code.

An agent's statement that something is "safe" or "compatible" is not evidence by itself.

---

# Documentation

Documentation changes are valuable contributions.

When documenting a finding, please make clear whether it applies to:

```text
the original Audi GeminiTop target
the Mercedes reference firmware
the W176 development unit
another specific vehicle/unit
or RoadTop generally
```

Avoid presenting target-specific observations as universal RoadTop behaviour.

---

# Upstream attribution

This repository is derived from the original GeminiTop project by `martexas`.

Please preserve upstream attribution and licence requirements.

Where a component or behaviour originated upstream, document that appropriately rather than presenting it as newly discovered Mercedes behaviour.

---

# Licence

By contributing, you agree that your contribution may be distributed under the repository's existing licence terms.

See:

```text
LICENSE
```

for the current licence.

---

# Final principle

The project values reliable evidence more highly than apparent completeness.

If something is not yet known:

```text
UNKNOWN
```

is a perfectly valid and useful result.
