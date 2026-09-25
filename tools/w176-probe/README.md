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
- uses one parent-controlled `/bin/sh` state machine which polls the direct
  child's `/proc/PID/stat` identity and state without reaping it; bounded
  commands receive `TERM`, a short grace interval, and then `KILL`, with all
  signal paths ending before the single `wait`/reap and without requiring the
  external `timeout` command;
- rejects a changed `/proc/PID/stat` parent-PID/start-time identity before any
  signal, rather than treating a reused numeric PID as the owned child;
- runs a harmless finite TERM-ignoring self-test before substantive collection
  and fails closed unless the runner records that the owned child was live at
  the KILL decision, KILL succeeded, the child ceased being live, and the child
  was reaped with a signal-derived status;
- records bounded, read-only shell/`timeout`/BusyBox capability diagnostics in
  the required `CAPABILITIES.txt` output, and never starts a diagnostic or
  collector when its file-size limit cannot first be established;
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

The bounded runner owns only the one direct process it launches. The Stage-1
commands are simple utilities, but the runner cannot guarantee control of
arbitrary unexpected descendants created by a target utility.

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
