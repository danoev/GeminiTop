# Installed W176 Stage-1 evidence

Status: physical-target evidence. This document contains sanitised derived facts
only; the raw USB capture is intentionally outside Git.

## Capture validity and provenance

- Payload commit: `5f85cafd0416b0511cc4570b6e280613112d6243`
- Physical attempt: Stage-1 attempt 2
- `STATUS.txt`: schema 1, `COMPLETE`, zero mandatory failures
- `COMPLETE`: regular non-symlink marker with `complete=1`
- `ERRORS.txt`: empty
- Hard timeout backend/self-test: `parent_proc_state_machine` / `PASS`
- Output root: the positively validated removable VFAT mount `/dev/sda1` at
  `/tmp/sp/mnt/sda1`

The raw directory was inspected read-only. It was not copied into this
repository. The capture reports no CAN, MCU, raw MTD/NVM payload, network, or
target-filesystem write.

Several output files contain a shell diagnostic stating that a short-lived
`/proc/<pid>/stat` disappeared. This is a benign observation race from the
portable process monitor: the run still met the complete transaction contract
and its timeout self-test passed. Stage-1 is not being changed or rerun merely
to remove this noise.

## CONFIRMED installed facts

- UI software `2025.09.11-S7-qa-v2.0.61`; MCU `Z-2.01-250521`.
- `Hardware: GEMINI`; ARMv7 processor implementer `0x41`, part `0xc07`, revision
  5; Linux 4.9.217 (`armv7l`), build dated 2025-09-11; boot memory argument
  `mem=256M`.
- Root is `/dev/blockrom8`, SquashFS and read-only. `/dev/blockrom10` is mounted
  read-only at `/tmp/sp/usr/local`; `/dev/blockrom11` is mounted read-only at
  `/tmp/sp/application`. NVM (`mtd12`, 8 MiB) and userdata (`mtd27`, 6 MiB) are
  YAFFS2 read-write mounts. Stage-1 did not read either payload.
- `/proc/mtd` contains the following 28-entry metadata map. Stage-1 read no
  partition payload:

  ```text
  mtd0  nand_header  0x00020000    mtd14 logo          0x00600000
  mtd1  xboot1       0x00020000    mtd15 tcon          0x00020000
  mtd2  uboot1       0x000e0000    mtd16 iop_car       0x00040000
  mtd3  uboot2       0x001e0000    mtd17 iop_sby       0x00040000
  mtd4  env          0x00080000    mtd18 runtime_cfg   0x00100000
  mtd5  env_redund   0x00080000    mtd19 vi            0x00020000
  mtd6  ecos         0x00400000    mtd20 isp_logo      0x00780000
  mtd7  kernel       0x00480000    mtd21 vendordata    0x00040000
  mtd8  rootfs.      0x00500000    mtd22 pat_logo      0x00300000
  mtd9  opt.         0x00060000    mtd23 version_info  0x00040000
  mtd10 spsdk.       0x03000000    mtd24 vd_restore    0x00040000
  mtd11 spapp.       0x01b00000    mtd25 anm_logo      0x00020000
  mtd12 nvm          0x00800000    mtd26 pic           0x001e0000
  mtd13 pq           0x00020000    mtd27 userdata      0x00600000
  ```

  Its canonical metadata signature is
  `eb8d657cd8f7538896b0f51b0621aaaf04a110303e6732f9d9922e3073791ed7`.
- Framebuffer: 1920x720 visible, 1920x1440 virtual, 32 bpp, stride 7680,
  `FB-O2-1920x720`, approximately 59.94 Hz, channel metadata
  `rgba 8/16,8/8,8/0,8/24`.
- Touch: `fts_ts`, I2C bus 1/address 0x38, input3/event3. Other input devices
  include `SPHE_IR`, `sp_virt_kb`, and `sp_virt_mouse`.
- Stock application path `/application/bin/Launcher`; observed size 92,416
  bytes. Observed `/usr/local/bin` processes include `servicemanager`,
  `resourcemanager`, `networkmanager`, `bluetooth_server`, `gocsdk`, `hostapd`,
  `pfc_server`, `log_server`, `as_server`, `videoin_server`, `device_server`,
  `mdnsd`, `apple_iap_server`, `vs_server`, `apple_carplay_server`, and
  `ps_server`.
- The observed autorun chain is `/sbin/mdev block` ->
  `/etc/usb_action_8368-U` -> removable-root `gemn_auto.sh` -> Stage-1.
- BusyBox 1.29.3, built 2025-09-11. Its timeout command has the older
  `timeout [-t SECS] [-s SIG] PROG ARGS` interface and no verified `-k` support.
- Selected installed USB-related hashes are
  `9ed1057f86c0388442d2db796d6dc3dec33f460aabd084dfa90d7024d309d1f6`
  (`Usbnet_ncm.sh`),
  `efc846c45a5e50433d9eeece6ec1df916625086f07eef494524f61c55d224cf4`
  (`usb_control`),
  `31f76531dd2cef6f14969be35cc41345dff5f1224c44f424f767645afd07493f`
  (`usb_uphy`), and
  `0ad5c35f22e8e4092ffffebd77616187a7fe7a77b9304f36e27293dd57946e39`
  (`usbmuxd`).

## Installed v2.0.61 versus reference v2.0.65

| Area | Installed physical target | Mercedes v2.0.65 reference | Result | Evidence state | Implication |
|---|---|---|---|---|---|
| Architecture | ARMv7; Stage-2 later confirmed ELF32 ARM EABI5 hard-float | ARM 32-bit EABI5 ELF files | MATCH | CONFIRMED vs REFERENCE ONLY | Installed loader/ABI is now recorded in `w176-stage2-evidence.md`; custom-code loadability remains unproven. |
| Kernel | 4.9.217 | validated `Linux-4.9.217` uImage | MATCH | CONFIRMED vs REFERENCE ONLY | Kernel release aligns, not proof of identical config/modules. |
| Platform identity | `GEMINI`; Stage-2 later captured installed `8368_XU` configuration strings | `GEMINI`, `8368-XU` strings | MATCH | CONFIRMED vs REFERENCE ONLY | Same platform/configuration family; no commercial board identity. |
| Boot command line | root blockrom8, SquashFS, 256 MiB | no authoritative installed-style command line recovered | UNKNOWN | CONFIRMED vs UNKNOWN | Reference cannot validate installed boot arguments. |
| MTD names/order | 28-entry map; rootfs./spsdk./spapp. at 8/10/11 | container records include rootfs./spsdk./spapp.; no full live MTD table | UNKNOWN/PARTIAL | CONFIRMED vs REFERENCE ONLY | Component names align; full order equivalence is unproven. |
| Partition sizes | rootfs 5 MiB, SDK 48 MiB, app 27 MiB, NVM 8 MiB, userdata 6 MiB | payload sizes: rootfs 3,883,008; SDK 46,325,760; app 21,319,680 bytes | UNKNOWN | CONFIRMED allocations vs REFERENCE ONLY payloads | Payload length is not partition allocation; do not equate them. |
| Read-only roots | root, `/usr/local`, `/application` are SquashFS RO | rootfs plus SDK/app SquashFS; rootfs symlinks to `/tmp/sp/...` | MATCH/PARTIAL | CONFIRMED vs REFERENCE ONLY | Topology aligns; exact files/content await selective comparison. |
| Writable data | NVM/userdata YAFFS2 RW | init scripts mount NVM/userdata YAFFS2 | MATCH | CONFIRMED vs REFERENCE ONLY | Arrangement aligns; contents/semantics were not read. |
| Application roots | `/application`, `/usr/local` | `/application` and `/usr/local` through `/tmp/sp` | MATCH | CONFIRMED vs REFERENCE ONLY | Common path model is supported. |
| Launcher | `/application/bin/Launcher`, 92,416 bytes | same path, 92,544 bytes | DIFFERENT | CONFIRMED vs REFERENCE ONLY | Stage-2 SHA-256 proves non-identity and establishes the installed ELF boundary. |
| USB autorun | mdev -> `usb_action_8368-U` -> `gemn_auto.sh` | `mdev.conf` dispatches sd* to the same action script, which calls root `gemn_auto.sh` | MATCH | CONFIRMED installed content vs REFERENCE ONLY | Installed dispatch and action contents were captured by Stage-2. |
| Framebuffer/display | 1920x720, virtual 1920x1440, 32 bpp, stride 7680 | init environment/config contains DirectFB/fb0 and reference assets assume 1920x720 | MATCH/PARTIAL | CONFIRMED vs REFERENCE ONLY | Strong topology alignment; exact pixel semantics/runtime support remain unapproved. |
| Touch | `fts_ts`, event3 | init GUI/environment names event3; driver configuration is reference-only | MATCH/PARTIAL | CONFIRMED vs REFERENCE ONLY | Same observed event placement; do not hard-code enumeration. |
| Major services | servicemanager, resourcemanager, networkmanager, pfc_server, device_server and others observed | same paths/names | MATCH for five selected binaries | CONFIRMED vs REFERENCE ONLY | Stage-2 SHA-256 values match the five named reference service binaries. |
| Generic platform libraries | Stage-2 hashes `libappframework` and `libappmcucommunication` | same paths in reference | DIFFERENT | CONFIRMED vs REFERENCE ONLY | Both selected installed library hashes differ; byte difference alone is not ABI incompatibility. |

## Resulting evidence state

Promoted to CONFIRMED only for the installed target: kernel/architecture,
GEMINI runtime identity, MTD metadata map, mounts, NVM allocation size,
framebuffer metadata, touch identity/event, application/service paths, USB mount,
and observed autorun chain. Reference kernel/path/topology similarities support
an INFERENCE of a common S7-QA/Gemini platform lineage.

Stage-2 later promoted only the installed init/config contents, `8368_XU`
configuration, ELF linkage/ABI, and selected installed hashes to CONFIRMED; see
`w176-stage2-evidence.md`. v2.0.65 contents remain REFERENCE ONLY. Still
UNKNOWN: QD507 or any commercial identity, custom-code loadability, update/flash
compatibility, raw partition content, deep MCU/CAN semantics, and deep audio
routing.

## Patchability implication

Stage-1 proves the least invasive entry boundary: stock root-run autorun can
execute a reviewed shell payload from positively identified removable USB.
It also proves that the application and SDK are read-only SquashFS mounts and
that the observed writable `/etc` overlay uses a volatile tmpfs upper/work
layer. Stage-2 confirms the installed ARM hard-float loader boundary and
persistent NVM path precedence, but it still does not prove that our own ARM
executable will load, that NVM shadowing is safe, that modified firmware is
accepted, or that a recovery path exists. See `w176-patchability.md` for the
route decision.
