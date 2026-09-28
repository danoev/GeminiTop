# W176 Stage-4B NVM source — recovered physical evidence

The successful Stage-1 physical backup at
`~/Desktop/W176-Stage1-Success-2026-09-25/stage1-probe/` was inspected
**read-only** on 2026-09-28. Its `STATUS.txt` says `schema=1`,
`status=COMPLETE`, and `mandatory_failures=0`; `COMPLETE` is a regular file
containing `complete=1`, and `ERRORS.txt` is empty. The backup's
`mounts.txt:9` is a runtime mount snapshot from the installed W176:

```text
/dev/mtdblock12 /tmp/sp/media/flash/nvm yaffs2 rw,noatime 0 0
```

The same capture's `mtd.txt:14` reports:

```text
mtd12: 00800000 00020000 "nvm"
```

These are **CONFIRMED physical runtime observations**, subject to the
operator-returned backup provenance and the Stage-1 capture's limitations.
They are not reference-firmware deductions. The successful Stage-2 backup at
`~/Desktop/W176-Stage2-Success-2026-09-26/stage2-platform/` has a separate
regular `COMPLETE`, `status=COMPLETE`, zero mandatory failures, and empty
`ERRORS.txt`. Its captured `symlinks.txt:3` reports
`media_link|/media|/tmp/sp/media/`. Its installed `init.platform.rc:5`
declares `mount yaffs2 mtd@nvm /media/flash/nvm wait noatime`; that is
**startup configuration**, not the runtime `/proc/mounts` source token.

Thus the intended **logical** installation pathname is
`/media/flash/nvm/geminitop/w176`, while its observed canonical physical
mountpoint is `/tmp/sp/media/flash/nvm` and observed runtime source is
`/dev/mtdblock12`. A validator demanding the literal `/media/flash/nvm` as
the canonical `/proc/mounts` mountpoint would reject the actual installed
system. Stage-4B must verify this exact logical-to-canonical symlink
relationship, source token, YAFFS2 RW mount, and independent `mtd12` metadata
as one bound identity before any persistent write. It must also recheck the
deepest effective mount for every proposed child path.

No raw physical capture or proprietary file was committed. This recovered
source is evidence for a **future safety gate**, not approval for an NVM write.
