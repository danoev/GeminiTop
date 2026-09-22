# GeminiTop

## Super Quick Start

Download the [Latest Release](https://github.com/martexas/GeminiTop/releases) - slap it on a FAT32 formatted USB stick 8GB and below, then plug it in the screen!

## Target status

The original project behavior is preserved as an **Audi reference target**.
Current development separates generic Gemini/S7-QA mechanisms from target
evidence. A Mercedes firmware archive may be inspected as static reference
material, while the installed W176/NTG5 unit remains unprobed and unsupported
for active launcher/runtime replacement.

See:

- `docs/platform/target-assumptions.md`
- `docs/platform/target-architecture.md`
- `docs/platform/firmware-safety.md`
- `docs/platform/benz-reference.md`
- `docs/workstreams/w176-platform.md`
- `tools/w176-probe/README.md`

## Quick Note!

Yes, I know this is all spaghetti code and it's a miracle any of this runs in the first place. The legacy firmware extractor/repacker was written for the Audi `QD513-QD515-AUDI-incell-S7-QA-2026.02.05-v2.0.65.zip` layout. Do not use those fixed-offset scripts for another target. The supported cross-target workflow is the read-only `firmware_tools/scripts/inspect_firmware.py` metadata inspector.

Feel free to fork this and get Codex/Claude to make the adjustments for your changes or a new game/app! This was a fun "can we do it" project and you can see how it was created in my YouTube video: https://www.youtube.com/watch?v=lwifwcN865Y

## Introduction
GeminiTop is a custom launcher and compatibility layer for RoadTop Linux screen units.

It builds a USB payload that auto-runs through `gemn_auto.sh`, hands off to a native launcher/orchestrator, and gives us a cleaner way to run custom apps on the stock firmware without any permanent changes!

The core of that is `libgemini`, which wraps the hardware paths on-device: framebuffer access, touchscreen and input handling, audio, logging, lifecycle helpers and so on.

Current payloads include:

- The Gemini launcher and backend Orchestrator
- DOOM (runs alright, like 40FPS? 100% CPU though)
- RetroArch plus selected libretro cores (100% CPU too)
- DOSBox-X and Windows 3.1 and Windows 95 entries (lol good luck, make some tea)
- `htop` at the USB root for SSH sessions
- Dropbear SSH on port `2222` with no password auth

## Hardware

The public SP7021 specs commonly repeated online do not match this unit very well. This target should be treated as a much lower-end RoadTop Linux screen.

- Kernel: Linux `4.9.217`
- CPU: ARMv7 rev 5 with NEON/VFPv4, 1 Core at around 1Ghz?
- GPU: Gone. Reduced to atoms.
- Memory: 173MB? 192MB? 256MB? Not sure how it's split, some seems to be reserved, you get like a good 100MB to play with
- Display: `/dev/fb0`, `1920x720`, `32bpp`, not very standard
- Input devices: IR, Keyboard/Mouse via USB, and `fts_ts` touchscreen
- Storage: LOL

This potato is limited, so don't expect to run much.

## Quick Start

If you just want to use it, download the latest prebuilt `usb_deploy/` from [Releases](https://github.com/martexas/GeminiTop/releases).

1. Format a USB drive as FAT32.
2. Keep it `8 GB` or smaller.
3. Copy the contents of `usb_deploy/` onto the root of the USB stick.
4. Plug it into the unit.

The firmware entrypoint is `gemn_auto.sh`, which starts the GeminiTop launcher from USB, overriding the original Launcher.

## Development

Docker is still the easiest reproducible path if you do not want to manage the cross toolchain yourself:

```bash
./docker_build.sh
```

Clean the Docker/native output:

```bash
./docker_build.sh clean
./build.sh clean
```

Native builds now work through one interactive script on both macOS and Linux:

```bash
./build.sh
```

When run in a TTY with no arguments, `build.sh` opens an interactive menu that can:

- build all apps
- build a selected app set
- check host dependencies
- attempt to install missing host dependencies on `brew` or `apt`
- clean build artifacts

Non-interactive examples:

```bash
./build.sh --check-deps
./build.sh --apps=doom,retroarch
./build.sh --install-deps
./build.sh clean
```

The main output is:

```text
usb_deploy/
```

`build.sh` discovers launcher apps dynamically from `apps/*/app.cfg`, runs each app's own `build-app.sh` when present, stages files from that app's `stage.lst`, always builds the top-level `htop/` payload into `usb_deploy/htop`, and writes a generated app index at `usb_deploy/apps/catalog.txt`.

## App Layout

Each app lives under `apps/<id>/` and owns its own build + staging metadata:

- `app.cfg`: runtime manifest used by the launcher/orchestrator
- `build-app.sh`: app-specific build step
- `stage.lst`: files/directories copied into `usb_deploy/apps/<id>/`
- `build-tools.lst` (optional): extra host tools that native builds should check for

The launcher and orchestrator both read the same generated `usb_deploy/apps/catalog.txt`, so the packaged app list is now defined in one place instead of each binary discovering apps independently.

`htop` is handled separately under `htop/` because it is intended to be launched from an SSH shell, not shown as a launcher tile. Its binary is staged directly to `usb_deploy/htop`.

Example `app.cfg`:

```text
title=My App
exec=my-app
arg=--example
requires_tty=0
depends=shared-runtime
```

Example `stage.lst`:

```text
mkdir saves
copy app.cfg
copy build/my-app -> my-app
copy assets -> assets
```

To add a new app:

1. Create `apps/<id>/`.
2. Add `app.cfg` with at least `title=` and `exec=`.
3. Add `build-app.sh` if the app needs a build step.
4. Add `stage.lst` describing what should be packaged.
5. Add `build-tools.lst` only if the app needs extra host-side tools beyond the shared defaults.
6. Run `./build.sh` and select the app, or pass `--apps=<id>`.

## Third-Party Downloads

Some third-party sources are fetched during builds and stored inside the repo checkout. That currently includes upstream source and assets for things like DOOM, RetroArch, libretro cores, DOSBox-X, `htop`, `ncurses`, Dropbear, and Buildroot for the desktop path.

## Native Build Requirements

Native builds need:

- `git`
- `make`
- `python3`
- `perl`
- `curl` or `wget`
- an ARM hard-float cross toolchain

`./build.sh --check-deps` will detect what is missing for the selected app set, and `./build.sh --install-deps` will try to install the missing pieces on supported package managers.
