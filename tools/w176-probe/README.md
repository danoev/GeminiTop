# W176 Stage-1 USB inventory probe

This is the required evidence-gathering step before W176 target support may be
considered established. It is the only USB payload in this repository intended
for the initial physical W176 discovery runs; it does not launch GeminiTop.

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
- uses a fixed command path, bounded collection and USB-handler discovery,
  bounded output sizes, and a maximum of 100 pre-existing output directory
  names;
- uses a `/bin/sh` watchdog built from background jobs, `sleep`, `kill`, and
  `wait`; bounded commands receive `TERM`, a short grace interval, and then
  `KILL`, without requiring the external `timeout` command;
- runs a harmless finite TERM-ignoring self-test before substantive collection
  and fails closed unless the watchdog kills and reaps it and cleans up itself;
- records bounded, read-only shell/`timeout`/BusyBox capability diagnostics in
  the required `CAPABILITIES.txt` output;
- copies or hashes an internal file only when it is a regular non-symlink file;
- does not read raw CAN streams;
- does not read NVM/MTD payload data or write NVM/MTD;
- does not modify the Roadtop filesystem, stock Launcher, networking, SSH, audio,
  MCU, or illumination behavior.

Every created output directory starts as `INCOMPLETE`. `STATUS.txt` records the
state and mandatory failure count, `ERRORS.txt` records mandatory failures, and
`OPTIONAL.txt` records optional skips. Treat a run as successful only when
`STATUS.txt` says `status=COMPLETE` and a regular non-symlink `COMPLETE` marker
exists. Required outputs and manifests are validated and finalised before that
marker is atomically renamed into place. The probe never creates it after a
mandatory or required-write failure.

The deployable scripts contain only the fixed production paths above. Host tests
instrument temporary copies with fixture paths; there is no environment-enabled
test mode or path substitution branch in the USB payload.

## Installed-target evidence from physical attempt 1

The payload from commit `a7a805c8d5298484acbe852062928a429ba9c5d8`
was physically attempted on the installed W176 RoadTop. The stock autorun
mechanism reached `/tmp/sp/mnt/sda1/gemn_auto.sh`, the production mount guard
accepted that removable FAT32 mount, and USB output creation worked. The run
then failed closed with `missing_hard_timeout:TERM_then_KILL` because neither of
the exact tested external `timeout -k` forms was supported. It produced no valid
`COMPLETE` marker and is not a valid Stage-1 capture.

That attempt confirms only the autorun/mount/output facts above. Board identity,
SoC, kernel, partition layout, framebuffer, input, MCU, CAN, audio, and firmware
compatibility remain `UNKNOWN` until a valid probe establishes them.

The output may contain device identifiers or configuration. Review it before
sharing. Keep raw probe and user-data captures outside Git; `.gitignore` blocks
the normal capture paths.

After removing the USB device, compare a result on the host:

```sh
python3 tools/target-identify/identify_target.py /path/to/stage1-probe
```

The tool reports `MATCH`, `DIFFERENT`, or `UNKNOWN` against each profile. A
reference match is similarity evidence and cannot confirm `QD507`.
