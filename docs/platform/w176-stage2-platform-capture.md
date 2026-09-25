# W176 Stage-2 selective platform capture

Status: implemented for independent review; **not approved for physical use**.

## Question and necessity

Stage-1 established the installed topology but cannot yet support a safe
patching mechanism. The next decision is whether reversible USB-loaded code can
run against the installed ABI, whether the volatile/writable overlays can
influence startup, and which read-only image owns the application layer. The
v2.0.61 versus v2.0.65 comparison is evidence toward that decision, not the end
goal. The smallest useful follow-up copies only the Launcher, dynamic loader,
and small startup/configuration text files needed for offline inspection, and
hashes larger binaries when equality alone answers the question.

## Fixed whitelist

| Path | Action | Maximum bytes | Requirement | Question answered |
|---|---:|---:|---|---|
| `/application/bin/Launcher` | COPY | 262,144 | mandatory | Exact installed ELF/linkage/build and why its size differs from reference. |
| `/application/appinfo.rc` | COPY | 4,096 | mandatory | Installed build/platform feature metadata and `8368_XU` relationship. |
| `/init.rc` | COPY | 32,768 | mandatory | Installed service/application startup graph. |
| `/init.platform.rc` | COPY | 4,096 | mandatory | Installed platform mount wiring. |
| `/init.gui.rc` | COPY | 8,192 | mandatory | DirectFB/touch/Launcher GUI wiring. |
| `/init.environ.rc` | COPY | 8,192 | mandatory | Display and runtime environment. |
| `/etc/inittab` | COPY | 4,096 | mandatory | Init entry path. |
| `/etc/init.d/rcS` | COPY | 16,384 | mandatory | Early userspace startup. |
| `/etc/fstab` | COPY | 4,096 | mandatory | Declared filesystem layout. |
| `/etc/mdev.conf` | COPY | 4,096 | mandatory | Installed block-device autorun dispatch. |
| `/etc/usb_action_8368-U` | COPY | 16,384 | mandatory | Exact installed USB action behavior. |
| `/lib/ld-2.30.so` | COPY | 262,144 | mandatory | Installed ELF loader ABI and whether a future USB executable can target it. |
| `/application/lib/libappframework.so.1.0.0` | HASH | 1,048,576 | mandatory | Exact equality with reference framework library. |
| `/application/lib/libappmcucommunication.so.1.0.0` | HASH | 1,048,576 | mandatory | Exact equality of the generic platform MCU boundary library; no MCU interaction. |
| `/usr/local/bin/servicemanager` | HASH | 65,536 | mandatory | Core service binary equality. |
| `/usr/local/bin/resourcemanager` | HASH | 524,288 | mandatory | Core service binary equality. |
| `/usr/local/bin/networkmanager` | HASH | 524,288 | mandatory | Core service binary equality; no networking action. |
| `/usr/local/bin/device_server` | HASH | 524,288 | mandatory | Core device-service binary equality. |
| `/usr/local/bin/pfc_server` | HASH | 65,536 | mandatory | Core service binary equality. |
| `/lib/libc-2.30.so` | HASH | 2,097,152 | mandatory | Installed C runtime equality with the reference toolchain baseline. |
| `/lib/libstdc++.so.6.0.28` | HASH | 2,097,152 | mandatory | Installed C++ runtime equality for Launcher-compatible code. |
| `/bin/busybox` | HASH | 1,048,576 | mandatory | Exact root userspace/tooling build relationship. |
| `/application`, `/usr/local`, `/media`, `/init`, `/bin/sh`, `/lib/ld-linux-armhf.so.3`, `/lib/libc.so.6`, `/lib/libstdc++.so.6` | symlink metadata | 1,024 each | optional | Exact runtime and ABI link targets without following or copying them. |

No wildcard, recursive walk, user data, NVM, raw MTD, logs, CAN, MCU device,
network command, or service-control operation is present. Reference hashes used
later for host comparison remain reference evidence, not capture inputs.

## Limits and transaction model

- Maximum bytes processed across whitelisted copied/hashed source files:
  8,388,608.
- Maximum copied payload bytes: 524,288.
- Maximum complete output byte size, including manifests: 1,048,576.
- Each source is checked as a regular non-symlink, measured through a bounded
  child, checked against its own limit, then opened by a separately bounded
  hash/copy child. Copies are re-measured and must match the measured source.
- Missing, symlink, directory, oversized, changed-size, timed-out, or failed
  mandatory inputs leave `status=INCOMPLETE` and no completion marker.
- Every output is created under one positively identified removable FAT mount.
  There is no internal fallback. Existing output directories are never reused.
- `STATUS.txt` starts incomplete. `ERRORS.txt`, `OPTIONAL.txt`, capabilities,
  summary, checksums, inventory, copied files, and README must be regular
  non-symlinks. `COMPLETE` is committed last only after status re-validation.

## Deliberate arming

The payload is isolated in `tools/w176-stage2/`. Its `gemn_auto.sh` name is
required by the verified stock autorun mechanism, but it refuses to run unless
the already validated USB root also contains a regular non-symlink file named
`ARM_STAGE2_PLATFORM_CAPTURE`. The repository supplies only a differently
named `.example` file containing the human-readable scope line
`scope=w176-stage2-platform-v1`; the target entrypoint deliberately does not
open the marker, avoiding an unbounded marker-file race. Merely copying the
reviewed directory to USB therefore does not arm it.

Creating the real marker is a later physical action and requires a separate,
explicit independent-review GO. This implementation and its tests do not
perform that action.

## Reference comparison anchors

Known v2.0.65 REFERENCE ONLY values include Launcher 92,544 bytes/SHA-256
`e23be22d0c1988b6ec7f272cbc770ec24fdab4b74c2b2fb4a59cf902050b7008`,
`libappframework.so.1.0.0`
`ca32e77e88f76f332929b46ea563a89d6ef2a3715fabe9e1ebd868eb9b7246d8`,
and `libappmcucommunication.so.1.0.0`
`cc29f92689aea4ab0cbccad5b27aed664afe379c553ef16dc0f483d9a928cde9`.
The reference dynamic loader, libc, libstdc++, and BusyBox hashes are
`fc56665106425528a918986fe880b5ef8bc034fa121060135f38afc68dc61be8`,
`c145a9a28b628bda6b3bead3a4880d025de9d92695405d8bc2af75e417dbe79b`,
`b67b997d454d94d7eafc086ecaeb0c59b37320ff9abf2dcbaa9772d9935c44bd`,
and `a495bbc5b21da2d369c5e0cc145ea61f34f1f2745abcbe69f4ae5d652c9060e8`
respectively.
No installed binary hash is known until a reviewed Stage-2 run occurs.
