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
| 1. USB runtime patch/injection | Stage-1 and Stage-2 prove that the stock root-run mdev action executes removable-root `gemn_auto.sh`. Installed ELF evidence proves ARM EABI5 hard-float with `/lib/ld-linux-armhf.so.3` and glibc 2.30. No custom ARM executable has run. | Shell autorun and ABI facts CONFIRMED; custom ARM loadability UNKNOWN | **Preferred route.** It is removable and avoids flash/NVM writes. A dynamic inert execution probe is the next physical gate, but no payload is created until a compatible reproducible ARMHF build environment is available and audited. |
| 2. Writable-storage/overlay patch | `/etc` and `/root` are tmpfs. The `/etc` overlay upper/work layers are volatile. NVM and userdata are persistent YAFFS2 mounts; installed init places `/media/flash/nvm/bin` and `/media/flash/nvm/lib` first in PATH and library search order. | Persistent path precedence CONFIRMED; safe override behavior UNKNOWN | Architecturally plausible, but persistent and higher risk. Do not write NVM/userdata or test binary/library shadowing until route 1 and recovery controls are established. |
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

UNKNOWN: whether our own ARM ELF loads and exits cleanly. A trivial dynamic C
probe could answer that without target storage writes, but the present ARM64
macOS host lacks a provenance-pinned Linux ARMHF glibc toolchain/sysroot. No
Stage-3 payload is created until its exact output can be rebuilt and statically
shown to meet the installed ABI boundary.

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
2. Establish a pinned Linux ARMHF toolchain/sysroot compatible with glibc 2.30;
   then build and independently audit one inert dynamic USB loadability probe.
3. Prefer a removable, non-persistent USB runtime mechanism for early fixes.
4. Consider a writable overlay only if installed startup explicitly supports a
   reversible hook and its storage boundary is proven safe.
5. Do not consider `spapp.` replacement until updater acceptance and a real
   recovery path are proven independently.
6. Treat a full firmware fork as the final route, not the default.

Current recommendation: route 1 remains the safest mechanism, but the execution
payload gate is not satisfied. Routes 2–4 remain blocked. Stage-2 itself was
successfully completed; no Stage-3 physical GO is declared here.
