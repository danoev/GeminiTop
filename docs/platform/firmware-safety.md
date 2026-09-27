# Proprietary firmware safety

Firmware archives and extracted content are local inputs, never repository
assets. Normal Git workflow ignores ZIP/BIN images, filesystem images,
extraction trees, copied Roadtop ELFs, NVM captures, user-data captures, and raw
Stage-1 probe output.

Commit-safe artifacts are limited to source code, documentation, profiles,
hashes, and metadata reports that do not contain extracted proprietary payloads.

Use the read-only inspector:

```sh
python3 firmware_tools/scripts/inspect_firmware.py \
  /path/to/reference-firmware.zip \
  --output reports/firmware/reference.json
```

It validates ZIP paths/sizes, hashes archive members, discovers structures by
magic, validates uImage CRC and SquashFS bounds, and derives a partition-layout
signature. It does not execute or emulate payloads, create an updater, modify an
image, or produce flashable firmware. The older extract/validate/repack scripts
remain historical Audi-reference tooling and are not part of the Mercedes-Benz
platform workflow.
