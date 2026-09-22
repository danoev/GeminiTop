# Benz v2.0.65 static reference inspection

Status: REFERENCE ONLY. This does not describe or identify the installed W176
unit.

The read-only inspection of the supplied local archive produced
`reports/firmware/benz-qa-2026.02.05-v2.0.65.json`. The archive itself and its
BIN members remain outside Git.

- Archive SHA-256:
  `7c565eb53039c937e0a280955f1ed8b22151dd07ccebf70094cd7105833602d5`
- `GEMINI_PACK.BIN` SHA-256:
  `8d449d4c9887ae6b573495b8798929edfe7543fcddd2d6380ac247959994587f`
- `ISPBOOOT.BIN` SHA-256:
  `6f14a55a2cf2ed1e41d341facaf73484e0b385e6c81ae8fbfb2117c0fc3e5070`
- Gemini container fields: variant `QA`, version `12.0.1.0.0.0.0.0`, validated
  payload bounds, and six component records whose MD5 values match.
- Validated embedded uImages include `Linux-4.9.217`, ECOS, and update scripts.
- Three bounded SquashFS superblocks were found in each main BIN.
- The ISP SquashFS candidates are at `0x937800`, `0xceb800`, and `0x3919800`.
  This demonstrates why the old fixed Audi `spapp.` offset must not be reused.
- Embedded string clues include `GEMINI` and `8368-XU`; neither is an
  authoritative retail board mapping.

The inspection host did not have `unsquashfs`, so filesystem-path and ELF-hash
inventories are explicitly `UNAVAILABLE` in this report. The inspector supports
that read-only inventory when the tool is installed; it never executes an ELF.
