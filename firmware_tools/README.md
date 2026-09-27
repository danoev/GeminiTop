# Firmware tools

The supported platform-analysis entrypoint is
`scripts/inspect_firmware.py`. It is read-only, target-neutral, and accepts a
ZIP archive or individual BIN file. It writes JSON metadata only.

```sh
python3 firmware_tools/scripts/inspect_firmware.py firmware.zip \
  --output reports/firmware/inspection.json
```

Discovery uses container magic, validated record bounds and hashes, uImage
header/data CRCs, and structurally validated SquashFS superblocks. Component
tables with any MD5 mismatch are rejected. If `unsquashfs` is available, the
inspector uses time- and output-bounded list/cat modes to add a path inventory
and hashes for ELF files without extracting a filesystem tree. Unavailable or
boundedly skipped data is marked `UNAVAILABLE` or `PARTIAL` instead of guessed.
An `--output` path may not alias the input by pathname, symlink, or hardlink.

The pre-existing `extract_firmware.py`, `validate_firmware.py`,
`repack_firmware.py`, and GUI are legacy Audi-reference tools with fixed layout
assumptions. They are deliberately excluded from the Mercedes-Benz platform
workflow.
They must not be used to create vehicle firmware for this project phase.
