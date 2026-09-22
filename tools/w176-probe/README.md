# W176 Stage-1 USB inventory probe

This is the required evidence-gathering step before W176 target support may be
considered established. It is the only USB payload in this repository intended
for the first physical W176 run; it does not launch GeminiTop.

The three shell scripts must be copied together to the root of one FAT/vfat USB
partition. Both the stock `gemn_auto.sh` entrypoint and `stage1_probe.sh`
independently require that directory to be the exact mount point of exactly one
removable `/dev/sd...` partition. Zero candidates, multiple candidates, another
filesystem type, a subdirectory, or a non-removable device causes a fail-closed
exit.

Reviewed scope:

- reads system identity, kernel, `/proc/mtd` metadata, framebuffer attributes,
  input identity, `appinfo.rc`, USB-handler hashes, and application/service names;
- writes its results only beneath `stage1-probe[-N]/` on the same USB device;
- uses a fixed command path, bounded collection commands, bounded output sizes,
  and a maximum of 100 pre-existing output directory names;
- copies or hashes an internal file only when it is a regular non-symlink file;
- does not read raw CAN streams;
- does not read NVM/MTD payload data or write NVM/MTD;
- does not modify the Roadtop filesystem, stock Launcher, networking, SSH, audio,
  MCU, or illumination behavior.

Every created output directory starts as `INCOMPLETE`. `STATUS.txt` records the
state and mandatory failure count, `ERRORS.txt` records mandatory failures, and
`OPTIONAL.txt` records optional skips. Treat a run as successful only when
`STATUS.txt` says `status=COMPLETE` and a regular `COMPLETE` marker exists. The
probe never creates that marker after a mandatory failure.

The output may contain device identifiers or configuration. Review it before
sharing. Keep raw probe and user-data captures outside Git; `.gitignore` blocks
the normal capture paths.

After removing the USB device, compare a result on the host:

```sh
python3 tools/target-identify/identify_target.py /path/to/stage1-probe
```

The tool reports `MATCH`, `DIFFERENT`, or `UNKNOWN` against each profile. A
reference match is similarity evidence and cannot confirm `QD507`.
