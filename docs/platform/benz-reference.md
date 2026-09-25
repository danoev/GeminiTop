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

A follow-up read-only inspection with `unsquashfs` 4.7.5 completed all six
filesystem inventories. Each main BIN contains 2,215 listed filesystem entries
and 651 ELF path/size/SHA-256 records; the corresponding inventories in
`ISPBOOOT.BIN` and `GEMINI_PACK.BIN` are identical after accounting for their
different embedded offsets. Within either BIN, the 651 ELF records contain 623
distinct content hashes because some files have identical content.

`unsquashfs` was used only to list paths and stream individual regular files to
the inspector for ELF-magic detection and hashing. No filesystem tree was
retained and no ARM binary was executed or emulated. These inventories remain
REFERENCE ONLY and do not establish the installed W176 unit's filesystem,
binary set, ABI, or hardware identity.

The successful installed-target Stage-1 capture now confirms several matching
topology characteristics, documented in `w176-stage1-evidence.md`. They do not
promote this image to a compatible update. In particular, the installed
Launcher is 92,416 bytes while this reference Launcher is 92,544 bytes, proving
that those two files differ. The separately reviewed Stage-2 design captures
only the installed Launcher and small startup/config files, and hashes selected
larger platform binaries, to resolve the remaining static-comparison questions.

For patchability planning, direct static inspection of the extracted reference
update-script bodies found uImage CRC plus component/chunk MD5 integrity logic.
The main script contains 205 `md5sum` references and each full NAND/eMMC ISP
script contains 306. No `rsa`, `signature`, `signed`, `sha1`, `sha256`, or
`public key` token was found in those three script bodies. This is not proof
that modified images are accepted: authentication may occur in a bootloader or
pre-script loader. Installed v2.0.61 update acceptance remains UNKNOWN, and no
modified image is authorised.
