# Installed W176 Stage-3 physical ARM execution evidence

Status: operator-supplied physical-target evidence recorded on 2026-09-27.

## Provenance and limitation

The operator reported the returned Stage-3 transaction from the installed
Mercedes-Benz W176 RoadTop. This repository update did not inspect the original
FAT filesystem or the original raw result files. In particular, a copied or
uploaded `COMPLETE` file cannot independently reconstruct the original FAT
object's inode/type metadata.

The physical payload was reported to correspond exactly to reviewed commit
`ee6ea0f7d0ef028c406c324e9f43f078d5f8de3f` and its committed inert ARMHF
binary:

```text
path=tools/w176-stage3-arm-probe/payload/arm_probe
size=5556
sha256=662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789
```

## Operator-returned result

```text
STATUS.txt:
status=COMPLETE
mandatory_failures=0

execution.txt:
executed=1
exit_status=0
result=PASS

binary.sha256:
662a2457a818624c63428c9bab0a62ff3c90f9941c3b92761c4f646ee0477789

CAPABILITIES.txt / runtime evidence:
usb.device=/dev/sda1
usb.filesystem=vfat
usb.readonly_window.verified=PASS
usb.readwrite_restore.verified=PASS
one_shot.lock=retained
arming_marker.consumed=PASS
```

The operator additionally reported a valid `COMPLETE` transaction and an empty
`ERRORS.txt`; the empty file was not retained in the chat upload. The reviewed
wrapper only creates `COMPLETE` after verifying its required outputs as regular
non-symlinks, final `status=COMPLETE`, and zero mandatory failures. That wrapper
property supports the returned result but does not substitute for this
session's absent original-media inspection.

## Confirmed platform conclusion

**CONFIRMED on the installed target:** a custom ARMHF ELF built by this project
can be loaded and executed natively from removable USB by the installed
RoadTop kernel, loader, and libc, and can return normally with exit status zero.

This proves Route 1 native USB execution at this narrow ABI boundary. It does
not prove compatibility for arbitrary binaries, RoadTop private libraries,
persistent installation, boot persistence, Launcher replacement, CAN/MCU
access, networking, firmware modification, or other targets.
