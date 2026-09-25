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
| 1. USB runtime patch/injection | Stage-1 itself proves that the stock root-run mdev action executes a removable-root shell payload. The exact installed USB action and startup files are not yet captured. No custom ARM executable has been run. | Shell autorun CONFIRMED; ARM ABI/loadability UNKNOWN | **Preferred research route.** It is the most reversible and avoids flash/NVM writes. Stage-2 is read-only and obtains the startup/ABI evidence needed before proposing a later inert executable test. |
| 2. Writable-storage/overlay patch | `/etc` and `/root` are tmpfs. `/tmp/sp/system/etc` is an overlay with read-only `/usr/local/etc` lowerdir and `/tmp/etc_up`/`/tmp/etc_wk` upper/work directories. NVM and userdata are persistent YAFFS2 mounts. | Volatile overlay topology CONFIRMED; persistent startup influence UNKNOWN | Do not write NVM/userdata. Stage-2 reads the small init/mount scripts to determine whether any reviewed, reversible overlay hook exists. A tmpfs upper layer is not persistence. |
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

REFERENCE ONLY v2.0.65 init files mount `spsdk.` at `/usr/local`, `spapp.` at
`/application`, and start Launcher and platform services. Stage-2 copies the
exact installed init/config files needed to determine whether v2.0.61 does the
same and whether a non-persistent USB hook can coexist with stock startup.

## Userspace ABI and own-code viability

CONFIRMED: the installed CPU/kernel are ARMv7/armv7l and stock Launcher exists.
REFERENCE ONLY: the v2.0.65 Launcher is ARM EABI5, requests
`/lib/ld-linux-armhf.so.3`, and links against glibc 2.30-era C/C++ and platform
libraries. UNKNOWN: whether the installed loader, libc, libstdc++, and platform
libraries are byte-identical and whether a binary built with the current
toolchain would load cleanly.

Stage-2 therefore copies the small installed dynamic loader and Launcher for
offline ELF inspection; it hashes installed libc, libstdc++, BusyBox, two
Launcher platform libraries, and selected core services. This does not execute
any ARM code. If the ABI evidence aligns, the next proposal should be a separate
reviewed, inert USB executable that reports only its own startup/ABI status to
USB. It must not replace Launcher or touch services merely to prove loadability.

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

## Decision gate after Stage-2

1. Confirm installed startup, overlay, USB-action, loader, and library evidence
   offline.
2. If ABI evidence is coherent, design a new, separately reviewed inert USB
   loadability probe; do not fold execution into Stage-2.
3. Prefer a removable, non-persistent USB runtime mechanism for early fixes.
4. Consider a writable overlay only if installed startup explicitly supports a
   reversible hook and its storage boundary is proven safe.
5. Do not consider `spapp.` replacement until updater acceptance and a real
   recovery path are proven independently.
6. Treat a full firmware fork as the final route, not the default.

Current recommendation: continue toward route 1 evidence. Routes 2–4 remain
blocked; no physical Stage-2 GO is declared here.
