# Installed W176 v2.0.61 MCU library — offline static trace

## Input and method

The input is `files/libappmcucommunication.so.1.0.0` from the successful
Stage-4A v5 physical capture, not the Benz v2.0.65 reference image. The
mounted capture passed the exact frozen `4161bc3...` analyser with 22 verified
checksums. The library is 213,496 bytes, SHA-256
`a45b1b92e8e5fcc224758dac1f6c57b2ab82a468db5bc15dcd53103a382f55b4`.
Analysis used host `file`, `strings` with offsets, and LLVM ELF header,
dynamic-symbol, and Thumb disassembly inspection. The ARM library was never
executed, loaded, debugged, or emulated. No live UART/CAN/MCU access occurred.
The source capture is proprietary and is not committed.

## ELF identity

**CONFIRMED:** ELF32 little-endian ARM shared object, EABI5, stripped of local
symbols but with dynamic symbols. `e_flags=0x05000400` declares EABI5 and
hard-float. SONAME is `libappmcucommunication.so.1`. NEEDED entries are
`libresourcemanager_client.so`, `libsppfc.so`, Qt5 Widgets/Gui/Core,
`libpthread.so.0`, `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, and
`libc.so.6`. Version needs include `GLIBC_2.4`, `GLIBC_2.7`, and `GCC_3.5`.
The exact v2.0.65 reference library bytes were not available in this session;
whole-file MATCH/DIFFERENT is **UNKNOWN**, not inferred from strings.

## Device and reader boundary

**CONFIRMED:** installed strings include `/dev/ttyS1` (file offset
`0x2d373`), `/dev/canbox_protocol_dev` (`0x2bfdf`), and `/dev/hc_mcu_dev`
(`0x2ca95`). This library did not establish literal `/dev/ttyS2` or
`/dev/ttyS4` references in the selected string search. The validated physical
FD snapshot separately shows Launcher owning `/dev/ttyS1` and `/dev/ttyS4`,
and gocsdk owning `/dev/ttyS2`; ownership alone does not prove which stream
carries HcCar.

**CONFIRMED static call relationship:** `hc_init` at `0x426a6d68` starts a
pthread, calls `open` with mode `2` for the literal `/dev/ttyS1`, and calls
`set_speed`/`set_parity` on the returned descriptor. The relevant PC-relative
literal is at `0x426a6dfc`; the adjacent string is at `0x426ad373`.
`hc_mcu_read` at `0x426a6ea0` checks that stored descriptor, calls libc
`read(fd, ..., 1)` at `0x426a6ed2`, and enters a small bytewise state machine.
It compares a candidate first byte with `0x2e` at `0x426a6ef0`, retains bytes
and state, and has a bounded-looking `0x32` comparison at `0x426a6f68`.
This proves a bytewise parser exists; the complete frame length, checksum,
escaping, resynchronisation, and message semantics remain **UNKNOWN**. This
function also contains `write`, `sem_post`, and `usleep` calls, so it must not
be treated as a passive-only routine.

`hc_protocol_initialize` at `0x4269bd28` stores callback pointers and may
create a worker thread. It separately opens the literal
`/dev/canbox_protocol_dev` with mode `2`, reads 16 bytes, and closes the
descriptor (`0x4269bdc2`–`0x4269be2a`). The meaning of those bytes and its
relation to `/dev/ttyS1` are **UNKNOWN**. `/dev/hc_mcu_dev` appears in multiple
named car-data handlers; its exact role in the installed W176 configuration is
**UNKNOWN**. Neither `ttyS2` nor `ttyS4` can be assigned to HcCar from this
library and the FD metadata alone.

## Callback, HcProtocol, HcCar, and illumination

**CONFIRMED:** `notify_car_event` (`0x4269bae8`) and
`notify_canbox_event` (`0x4269bb12`) construct callback-notification arguments
and call imported `callback_notify`. Multiple installed handlers call these
entry points. The precise on-wire to callback field transformation is not yet
fully reconstructed, so whether Linux constructs HcCar from lower-level
fields, receives it already semantic, or uses both remains **UNKNOWN**.
`HcProtocolWrapper` conversion and `SettingPrivate::onHcProtocol` are defined
in this same installed library; a path from HcProtocol to `HcCar*` handler is
statically present, but a complete device-to-event causal chain is not proven.

Crucially, **CONFIRMED in installed v2.0.61 bytes**:
`SettingPrivate::onHcCarHandler(HcCar*)` is defined at `0x426977dc`.
Its outer switch reads the first HcCar word (`0x426977ee`), subtracts two,
and dispatches type 8 to `0x426979ac`. That branch compares the second word
at offset `+4` against literal `0x17` and `0x18`
(`0x426979ee`–`0x426979f6`). `0x18` calls
`Setting::iLLLightStatus(false)` (`0x426979f8`–`0x426979fc`). `0x17`
conditionally calls `Setting::iLLLightStatus(true)` when the stored headlamp
status at `+0x6d` is set (`0x42697a06`–`0x42697a10`). Thus the installed
branch has a headlamp-status gate; a simple unconditional `0x17 -> true`
description is incomplete. `Setting::iLLLightStatus(bool)` is also defined in
the captured installed library at `0x426a79c0` and emits a Qt signal. The
handler is not merely an uncaptured Settings-binary assumption.

Other recoverable handler observations are deliberately limited:

| HcCar outer type | subvalue | installed branch | state |
| --- | --- | --- | --- |
| 8 | `0x17` | conditional illumination true, gated by stored headlamp state | CONFIRMED |
| 8 | `0x18` | illumination false | CONFIRMED |
| 9 | `0x19`/`0x1a` | calls `Setting::carBrakeStatus(bool)` | CONFIRMED call; vehicle meaning UNKNOWN |
| 12 | `0x1f`..`0x24` | bounded nested dispatch including MCU-update progress and `setHcProtocol` paths | CONFIRMED branch family; complete meanings UNKNOWN |
| other 2..12 | not resolved | most entries return/default or need deeper table analysis | UNKNOWN EVENT |

These internal codes are **not Mercedes CAN arbitration IDs**. There is no
installed proof that a W176 physical lamp, dimmer, ambient sensor, or OEM
day/night event generated any particular HcCar value. Installed symbols include
`Setting::setHeadlampStatus(bool)`, `sendIllstatus`, and
`dayNightModeSwitch`; their causal relation to Mercedes OEM display brightness
is **UNKNOWN**.

## Existing observation hooks and next boundary

**CONFIRMED:** `onHcCarHandler` contains Qt `QMessageLogger::debug` /
`QDebug` calls immediately before type-8 and other branches. The library also
imports `printf` and has bounded static diagnostic strings near CAN and MCU
handlers. Whether stock logging is enabled, retained, or accessible without
altering runtime behaviour is **UNKNOWN**. No hook was enabled here.

The best-supported architecture is **INFERENCE**:
`/dev/ttyS1` -> `hc_init`/byte reader -> protocol/callback machinery ->
`HcProtocol`/`HcCar` -> `SettingPrivate::onHcCarHandler` -> Qt illumination
signal. The endpoints and installed type-8 handler are statically confirmed;
the entire dynamic chain and vehicle source are not. A later bounded live
correlation can now be *designed* around pre-existing, passively readable
semantic logs or exported state, if first verified accessible without enabling
logging, opening a second UART reader, attaching a tracer, or changing stock
processes. Otherwise the observation boundary remains **UNKNOWN**, and the
smallest safe next step is further offline call-graph analysis and a separate
independent review of any proposed passive capture.

## Designated handoff to 02 — Illumination & CAN

Installed library SHA-256:
`a45b1b92e8e5fcc224758dac1f6c57b2ab82a468db5bc15dcd53103a382f55b4`
(213,496 bytes), from the checksum-validated Stage-4A v5 capture. Confirmed:
`hc_init` opens `/dev/ttyS1`; `hc_mcu_read` reads one byte at a time;
`onHcCarHandler` in this installed library handles outer type 8, compares
`0x17`/`0x18`, and calls `iLLLightStatus(true/false)` with a headlamp gate on
the true path. Existing Qt debug calls occur at the semantic handler.
Unknown: complete UART framing/checksum, exact callback construction, physical
Mercedes event mapping, whether logging is enabled, and safe access to its
output. MCU translation is an inference, formal topology CASE D. A bounded
live-correlation experiment is conceptually designable only after confirming
an already-active passive log/export boundary; do not read device streams or
enable hooks. No live experiment is performed or authorised here.
