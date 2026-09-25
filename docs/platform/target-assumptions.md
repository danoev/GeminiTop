# Target-assumption audit

This audit covers the complete initial repository at commit `4cd54a4`, including
runtime code, applications, build scripts, firmware tools, assets, and the
legacy Audi reconnaissance capture subsequently removed from Git.
Classification describes the assumption itself, not whether the code currently
exposes a configuration switch.

| Area | Assumption and locations | Classification | Platform treatment |
|---|---|---|---|
| Firmware offsets | `firmware_tools/scripts/common.py` defines a `0x400` Gemini header, table at `0xc80`, six `0x80` records, three ISP filesystem offsets/sizes, and two script slots. Extract, validate, and repack consume them. | AUDI-SPECIFIC | Kept as legacy layout knowledge only. New `inspect_firmware.py` discovers and validates magic, uImage CRCs, SquashFS bounds, and component records without selecting these constants. |
| QD513/QD515 | The README names `QD513-QD515-AUDI-incell...` as the firmware for which the legacy offsets were written. | AUDI-SPECIFIC | Documented as the original reference; not a generic Gemini or W176 identity. |
| QD507 | Not present in original source. The supplied Benz archive filename contains it. | UNKNOWN | Stored only as a non-authoritative REFERENCE ONLY label. No comparison may confirm it. |
| Audi branding | README describes the original Audi unit; `logos/CarPlayLogo.icon` embeds `audi-logo.png`. | AUDI-SPECIFIC | Retained for the Audi reference. It is not used as a Mercedes/W176 default. |
| Partition layout and sizes | Legacy firmware tools expect named `rootfs.`, `spsdk.`, and `spapp.` slots and exact allocations. The legacy Audi capture showed a 28-entry MTD map. | TARGET-CONFIGURABLE | CONFIRMED metadata only for installed W176: Stage-1 recorded its 28 names/order/sizes and signature. No partition payload was read, and matching reference component names do not prove byte or flash compatibility. |
| NVM size | The legacy Audi capture reported an 8 MiB `nvm` MTD partition and `/media/flash/nvm`. Runtime search paths include its `bin`/`lib`. | TARGET-CONFIGURABLE | CONFIRMED for installed W176: `/proc/mtd` reports 8 MiB. Stage-1 read metadata only; NVM content and semantics remain UNKNOWN. |
| Touch controller | Legacy Audi evidence identifies `fts_ts`/FocalTech. RetroArch comments call the touchscreen `event3`. | RUNTIME-DETECTABLE | CONFIRMED for this installed boot: `fts_ts`, I2C bus 1/address 0x38, input3/event3. Runtime code must still bind by identity rather than assuming stable enumeration. |
| Input event numbers | `event3` appears in legacy Audi evidence and RetroArch comments; code generally enumerates event nodes dynamically. | RUNTIME-DETECTABLE | Do not configure W176 by event number alone because enumeration can change. Probe captures handler/name relationships. |
| Framebuffer device | `libgemini` and RetroArch open `/dev/fb0`. | TARGET-CONFIGURABLE | W176 device is UNKNOWN. Existing runtime remains unchanged and is not approved for W176. |
| Framebuffer geometry discovery | `libgemini` reads variable framebuffer geometry using fbdev ioctls. | RUNTIME-DETECTABLE | CONFIRMED installed metadata: visible 1920x720, virtual 1920x1440, 32 bpp, stride 7680, `FB-O2-1920x720`. This does not itself approve rendering. |
| Hard-coded display geometry | README, NetSurf, Quake assets/code, and RetroArch comments assume 1920×720; reference evidence reports virtual 1920×1440 and 32 bpp. | AUDI-SPECIFIC | App constants must be removed or selected by an established target before W176 runtime support. |
| Framebuffer format | Draw/video code assumes 32-bit pixels with alpha forced to `0xff`; RetroArch describes BGRA. | TARGET-CONFIGURABLE | W176 format/channel layout is UNKNOWN. Width/bpp alone is insufficient to approve rendering. |
| Device paths | `/dev/fb0`, `/dev/input`, `/application`, `/usr/local`, `/system`, `/apps`, and `/media/flash/nvm` are embedded throughout runtime/orchestrator code. | TARGET-CONFIGURABLE | Reference-only until verified. Profiles are not wired into runtime in this phase. |
| Filesystem locations | Orchestrator constructs `PATH`/`LD_LIBRARY_PATH` from Sunplus/Roadtop directories; launcher and app code assume stock `Launcher` and application paths. | TARGET-CONFIGURABLE | Stage-1 inventories names and selected metadata. No W176 launcher action is enabled. |
| USB mount points | Launcher searches `/tmp/sp/mnt/sda1`, `sdb1`, and `sdc1`; the stock entry script also infers `/dev/sd*`. | RUNTIME-DETECTABLE | W176 probe resolves its own USB root from the invoked script path and writes only beneath it. |
| Kernel | Legacy Audi evidence reports Linux 4.9.217. Kernel module and ABI expectations are implicit in evdev/fbdev behavior. | TARGET-CONFIGURABLE | CONFIRMED installed release 4.9.217, ARMv7, build date 2025-09-11. Kernel equality does not establish userspace ABI or module compatibility. |
| Image-format primitives | uImage headers/CRCs, SquashFS superblocks, cryptographic hashes, and bounded ZIP handling are standard format mechanisms. | GENERIC | Read-only inspector validates each discovered structure and bounds. |
| Legacy firmware workflow | The old tools assume GEMINI_PACK/ISPBOOOT pairing, ASCII MD5 fields, uImage scripts, named SquashFS regions, and a fixed update-script order. | AUDI-SPECIFIC | Retained as historical Audi tooling; it does not define the W176 workflow. |
| Architecture | Docker/toolchain/build scripts assume ARMv7-A hard-float with NEON/VFPv4 and `arm-*-linux-gnueabihf`; htop also considers musl. | TARGET-CONFIGURABLE | W176 ARMv7 is CONFIRMED, but hard-float ABI, loader/runtime identity, and toolchain compatibility remain UNKNOWN. Stage-2 copies the small loader and hashes libc/libstdc++/BusyBox; it executes none of them. |
| Launcher replacement | `scripts/gemn_auto.sh`, orchestrator, `libgemini_system.c`, and apps freeze/override/resume a process named `Launcher`. | AUDI-SPECIFIC | Existing Audi behavior is preserved but not staged by the W176 probe. Active W176 launcher/runtime work is blocked. |
| Audio | `libgemini` and RetroArch load `libaudio.so(.2)`, resolve specific C++ symbols, and create `QtOutput`/`alternative`; apps assume 16-bit PCM and commonly 48 kHz. | AUDI-SPECIFIC | Reference path only. CarPlay endpoint, Use Car BT, focus, physical output, and DAB/MOST remain separate W176 investigations. |
| Networking | `launcher/gemini_wifi.sh` assumes `wlan0`, Sunplus `nw_control`, stock wpa tools/config paths, DHCP behavior, and may kill/restart network processes. | AUDI-SPECIFIC | Not invoked by Stage-1. W176 networking support is UNKNOWN and blocked. |
| SSH | Build/orchestrator packages patched Dropbear, creates keys under `/tmp`, and can listen on port 2222; README documents passwordless root access. | AUDI-SPECIFIC | Not enabled or probed on W176. Security behavior must be redesigned before any W176 activation. |
| App/display constants | NetSurf fixes 1920×720×32 and Quake fixes height 720. | AUDI-SPECIFIC | Must be target-aware before a W176 launcher is possible. |
| App use of libgemini | Most other apps obtain dimensions and input through the shared library. | GENERIC | Reusable only after the underlying target-specific backend is established. |
| Branding/assets | Audi logo assets are present; generic launcher colors/text are otherwise not vehicle-specific. | AUDI-SPECIFIC | Preserve under the Audi reference; do not reuse as W176 evidence. |

## Generic versus target material

Generic S7-QA/Gemini concepts include validated uImage/SquashFS parsing,
cryptographic hashing, evdev enumeration, framebuffer ioctl discovery, app
catalog parsing, and host-side comparison/reporting. Hardware paths, ABI,
partition map, display pixel layout, stock process/service names, audio symbols,
network commands, and vehicle branding are target evidence.

The legacy `recon.txt` raw capture was removed because it included environmental
details. Its reviewed conclusions remain historical reference evidence only and
must not be treated as a probe of the owner's installed W176 unit. New raw probe
outputs are ignored by Git and must be reviewed/redacted before any metadata is
committed.
