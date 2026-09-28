# W176 Stage-4B persistent-residency candidate

Status: **historical host-only baseline, NOT READY for physical review or
execution** after the fresh 2026-09-28 audit. Never physically run. See
`w176-stage4b-fresh-safety-audit.md` for the historical HIGH findings and
`w176-stage4b-remediation-status.md` for later partial hardening and remaining
blockers. The claims below describe the old intended design, not a currently
approved safety gate.

## Evidence boundary

CONFIRMED installed evidence from Stages 1–2 identifies `mtd12` as an 8 MiB
`nvm` partition and `/media/flash/nvm` as its YAFFS2 read-write mount. Installed
init places that mount's `bin` and `lib` directories before stock search paths.
Those precedence paths are explicitly excluded from this milestone.

The proposed dedicated location is:

```text
/media/flash/nvm/geminitop/w176
```

Writing or executing from that new directory remains UNKNOWN until a later,
independently reviewed physical test. Userdata is not an alternative or
fallback.

## Candidate and gates

The candidate requires all of the following before its first persistent write:

- exact validated removable FAT USB root and one-shot install marker/lock;
- kernel `4.9.217`;
- installed Launcher size 92,416 and SHA-256
  `5ff83ac9cf9fb2ccb21c90c9b2edb2952581153ec5d5ab4a299787243e1e0c56`;
- installed `8368_XU` app-info evidence;
- unique `/media/flash/nvm` mount record, YAFFS2, RW and not RO;
- unique `nvm` MTD record of `0x00800000` bytes;
- at least 128 KiB reported free; and
- exact source proof binary size/hash.

It creates a private staging directory only beneath the new GeminiTop parent,
performs a single-open descriptor-verified bounded copy, verifies the
destination hash, commits an exact manifest and directory, then executes the
destination copy. No wildcard overwrite or fallback is present.

The process starts with `/tmp` as its working directory and standard streams on
`/dev/null`. The installer verifies the exact `/proc/<pid>/exe`, kernel PID
start time, `/tmp` cwd, no file descriptor resolving into the USB root, and an
advancing volatile heartbeat. The later verification action binds those values
to the original install evidence after an operator-marked USB removal and
reinsertion.

## Exact ARM boundary

The 5,556-byte `geminitop-proofd` SHA-256 is:

```text
57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6
```

Two clean builds in the digest-pinned Linux/arm64 environment match. Static
inspection confirms the physically proven Stage-3 architecture/interpreter
boundary and only `libc.so.6` / `GLIBC_2.4`. No ARM execution or emulation was
performed in preparing this candidate.

## Recovery boundary

The separately armed uninstaller checks the target, exact parent/directory
allowlist, manifest, binary hash, process executable and PID start time. It uses
TERM only, verifies termination, revalidates the owned files, and removes only
the heartbeat, binary, manifest, and now-empty dedicated directories. Any
unexpected object stops removal. There is no recursive delete.

## Explicit exclusions

- Stock files touched: **NONE in the design and host fixtures**.
- PATH/library shadowing: **NONE**.
- Boot persistence enabled: **NO**.
- CAN/MCU access: **NO**.
- Network access: **NO**.
- Settings UI modification: **NO**.
- Physical approval: **NOT GRANTED by this document**.

Reference inventory names do not establish an installed Settings plugin API or
safe startup extension. Therefore:

```text
STOCK SETTINGS EXTENSION: NOT YET SAFE / REQUIRES FURTHER RESEARCH
```
