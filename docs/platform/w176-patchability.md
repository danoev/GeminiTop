# W176 patchability decision record

Status: evidence and planning only. No runtime injection, persistent target
write, modified image, update attempt, or recovery action is authorised.

## Engineering goal

The platform workstream exists to identify the safest mechanism for deploying
our own fixes and features to the installed W176 RoadTop. Version comparison is
useful only insofar as it reduces the risk of that decision.

## Current route assessment

| Route | Current evidence | State | Present decision |
|---|---|---|---|
| 1. USB runtime patch/injection | Stage-1 and Stage-2 prove that the stock root-run mdev action executes removable-root `gemn_auto.sh`. Installed ELF evidence proves ARM EABI5 hard-float with `/lib/ld-linux-armhf.so.3` and glibc 2.30. On 2026-09-27 the exact independently reviewed Stage-3 ELF executed natively from USB and returned zero through the serialized RO window. | Shell autorun, installed ABI, reproducible/static gate, atomic-lock/RO host regressions, disposable Linux FAT semantics, and exact physical native execution CONFIRMED | **Preferred early patchability route and physically proven at the inert-probe boundary.** Broader binaries and persistent installation still require separate design and review. |
| 2. Writable-storage/overlay patch | `/etc` and `/root` are tmpfs. The `/etc` overlay upper/work layers are volatile. NVM and userdata are persistent YAFFS2 mounts; installed init places `/media/flash/nvm/bin` and `/media/flash/nvm/lib` first in PATH and library search order. A non-shadowing Stage-4B candidate now targets only `/media/flash/nvm/geminitop/w176`. | Persistent mount/path facts CONFIRMED; candidate build/static/host-fixture gates CONFIRMED; physical residency UNKNOWN | Architecturally plausible. The prepared candidate deliberately avoids `nvm/bin`, `nvm/lib`, userdata, stock files, and boot startup. It still requires independent review and a separate physical decision. |
| 3. Modified application SquashFS | Installed `mtd11` is named `spapp.` and `/dev/blockrom11` is mounted read-only at `/tmp/sp/application`; Launcher is `/application/bin/Launcher`. The reference `spapp.` contains the application layer. | Installed facts CONFIRMED; mapping to the same reference image format is INFERENCE | Potentially narrower than a full image, but still a flash operation and currently blocked. It requires exact installed layout/update verification and proven recovery first. |
| 4. Full firmware fork | Reference BINs can be statically unpacked. Existing legacy tooling can rebuild reference-style SquashFS regions and refresh uImage CRC/MD5 fields, but uses fixed historical layouts and has not been validated for the installed target. | REFERENCE ONLY / UNKNOWN | Highest-risk and last choice. Do not create or flash an installed-target image in this phase. |

## Startup and application ownership

CONFIRMED on the installed target:

- PID 1 is `/init`;
- Launcher runs as root from `/application/bin/Launcher` with
  `--dfb:no-layers-clear`;
- platform services run as root from `/usr/local/bin`;
- root, SDK, and application filesystems are read-only SquashFS mounts;
- the USB autorun process is root-owned and invokes the Stage-1 shell payload.

CONFIRMED installed v2.0.61 init files mount `spsdk.` at `/usr/local`, `spapp.`
at `/application`, and declare Launcher and platform services. The observed
Launcher command line selects the installed `ncLauncher` definition with
`--dfb:no-layers-clear`. See `w176-stage2-evidence.md` for the exact sanitised
startup result.

## Userspace ABI and own-code viability

CONFIRMED: installed Launcher is ELF32 little-endian ARM EABI5 hard-float,
dynamically linked through `/lib/ld-linux-armhf.so.3` to the installed
`ld-2.30.so`. Its recorded version needs are `GLIBC_2.4` and `GCC_3.5`; it has
no RPATH/RUNPATH. Installed libc, libstdc++, BusyBox, the loader, Launcher, and
two platform libraries differ from v2.0.65, while five selected services match.
No byte difference alone proves ABI incompatibility.

CONFIRMED: the exact reviewed project ARM ELF loads and exits cleanly on the
installed target. The host prerequisite was resolved with the official AArch64-Linux-hosted Arm GNU A-profile
9.2-2019.12 toolchain and a digest-pinned Linux/arm64 container. Two clean
builds of the 15-line inert C probe are identical, and static inspection shows
only the installed-compatible loader, `libc.so.6`, and `GLIBC_2.4` boundary.
The one-shot physical run subsequently completed with exit status zero. This
proves only the reviewed inert binary and its established ABI boundary.

The first Stage-3 wrapper revision was rejected after a confirmed HIGH
hash-to-exec pathname race produced false COMPLETE in a host reproduction. The
remediation removes the mutable snapshot and permits final hashing/execution
only after the same validated USB device/mount is independently confirmed RO.
Real disposable FAT tests support this normal-writer threat model, including
fail-closed rejection when a writable descriptor prevents RO remount. Target
BusyBox remount capability remains UNKNOWN and must fail closed.

A later independent review CONFIRMED that the first RO-window wrapper was still
HIGH/NO-GO under overlap: both invocations could pass the marker and one could
restore RW during the other's integrity window. The current host-only design
uses atomic `mkdir .stage3-arm-probe.lock` after USB anchoring and before marker
handling. Only its winner can enter the complete marker/RO/hash/execute/RW/
COMPLETE sequence, and the target never removes the lock. Reuse therefore
requires deliberate off-target preparation and another exact-payload review.

## Firmware format and integrity

REFERENCE ONLY static analysis establishes:

- `GEMINI_PACK.BIN` has a component table covering `spapp.`, `spsdk.`,
  `rootfs.`, kernel, uboot2, and ECOS with embedded MD5 values;
- the update scripts are CRC-valid uImages and verify written chunks with MD5;
- the v2.0.65 main update script contains 205 `md5sum` references; each full
  NAND/eMMC ISP script contains 306;
- direct static term checks of those three script bodies found no `rsa`,
  `signature`, `signed`, `sha1`, `sha256`, or `public key` token;
- the reference scripts erase/write partitions and verify them afterwards.

This does **not** prove unsigned modified images are accepted. A bootloader or
pre-script loader may enforce authentication outside the visible scripts. The
installed v2.0.61 updater path and keys/checks remain UNKNOWN. Existing legacy
repack code demonstrates how reference CRC/MD5 metadata could be regenerated;
it is not evidence that an installed-target image is safe or accepted.

## Recovery and fallback

The installed MTD names include `uboot1`, `uboot2`, `env`, `env_redund`, and
`vd_restore`. These names are not proof of a working rollback path. REFERENCE
ONLY update scripts expose `isp_update_cancel`/`isp_all_or_update_done`, save
environment state, and perform in-place partition erase/write followed by MD5
verification. No verified A/B application slot, automatic rollback, recovery
button sequence, rescue image, or external programming procedure is currently
known. Therefore any SquashFS or firmware route remains blocked.

## Decision after Stage-2

1. Installed startup, overlay, USB-action, loader, and library evidence is now
   confirmed and recorded offline.
2. The pinned Linux ARMHF build/static gate and exact one-shot physical
   loadability proof are complete. Treat later native payloads as new review
   subjects rather than inheriting blanket compatibility.
3. Prefer a removable, non-persistent USB runtime mechanism for early fixes.
4. Consider a writable overlay only if installed startup explicitly supports a
   reversible hook and its storage boundary is proven safe.
5. Do not consider `spapp.` replacement until updater acceptance and a real
   recovery path are proven independently.
6. Treat a full firmware fork as the final route, not the default.

Current recommendation: route 1 remains the safest early mechanism and exact
native USB execution is physically confirmed. Route 2 may now proceed only to
a separately reviewed minimal residency proof. A host-only install/verify/
uninstall candidate exists, but no NVM write is authorised; routes 3–4 remain
blocked.
