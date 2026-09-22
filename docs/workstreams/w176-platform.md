# W176 project workstreams

Every item uses one of: CONFIRMED, REFERENCE ONLY, INFERENCE, or UNKNOWN.

## A. Common Roadtop platform

- CONFIRMED: the installed UI reports system `2025.09.11-S7-qa-v2.0.61` and MCU
  `Z-2.01-250521`.
- REFERENCE ONLY: the Benz v2.0.65 archive contains a Gemini container, a
  validated Linux 4.9.217 uImage, and SquashFS images. Separately, the original
  Audi `recon.txt` shows a Gemini/ARMv7 runtime and stock `Launcher`.
- INFERENCE: validated image-format and host-analysis code can be shared across
  S7-QA variants.
- UNKNOWN: installed board identity, partition map, ABI, framebuffer, touch,
  paths, service set, USB handler, and compatibility with reference firmware.

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

## Blocked until the real Stage-1 probe

- promoting any Mercedes reference fact into the W176 profile;
- selecting a runtime toolchain/ABI for W176;
- approving framebuffer or touch support;
- using a partition size, firmware offset, filesystem path, or USB mount rule;
- identifying the unit as QD507 (or any other marketing board identifier);
- staging or enabling the Gemini launcher/orchestrator on the W176 unit;
- enabling SSH/network services;
- beginning audio, MOST, illumination, CAN, or MCU changes that depend on target
  identity.
