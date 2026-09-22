# W176 Stage-1 USB inventory probe

This is the required evidence-gathering step before W176 target support may be
considered established. Copy only the contents of this directory to a FAT32 USB
root. The stock firmware invokes `gemn_auto.sh`; that entrypoint runs
`stage1_probe.sh` and does not launch GeminiTop.

Reviewed scope:

- reads system identity, kernel, `/proc/mtd` metadata, framebuffer attributes,
  input identity, `appinfo.rc`, USB-handler hashes, and application/service names;
- writes its results only beneath `stage1-probe[-N]/` on the same USB device;
- does not read raw CAN streams;
- does not read NVM/MTD payload data or write NVM/MTD;
- does not modify the Roadtop filesystem, stock Launcher, networking, SSH, audio,
  MCU, or illumination behavior.

The output may contain device identifiers or configuration. Review it before
sharing. Keep raw probe and user-data captures outside Git; `.gitignore` blocks
the normal capture paths.

After removing the USB device, compare a result on the host:

```sh
python3 tools/target-identify/identify_target.py /path/to/stage1-probe
```

The tool reports `MATCH`, `DIFFERENT`, or `UNKNOWN` against each profile. A
reference match is similarity evidence and cannot confirm `QD507`.
