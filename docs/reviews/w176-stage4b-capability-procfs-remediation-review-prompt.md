# Ready-to-paste independent Work review: W176 capability procfs remediation

Perform a FRESH, READ-ONLY, INDEPENDENT safety review of the GeminiTop W176
Stage-4B **metadata-only capability preflight remediation**. Do not implement
changes, prepare or arm USB, interact with the RoadTop, execute target ARM
code, call feature syscalls on the target, write NVM, or grant physical GO.

Repository: https://github.com/danoev/GeminiTop

Branch: `codex/w176-stage4b-capability-preflight`

Last physically run frozen implementation: `465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed`

New **candidate implementation freeze**: `f02c89e91eb2d5f962ce485669bba91e89eab37b`
Production branch `feature/w176-stage4b`: untouched; known HEAD `a5034afef4a258813c202e72904cce2f70abee2e`.

The owner returned one operator-supplied physical result from the old
collector: marker consumed, lock retained, `status=INCOMPLETE`,
`mandatory_failures=1`, `failure.1=proc_version:absent_or_unsafe`, and no
COMPLETE/inventory/checksums. Its partial uname/symbol/metadata lines are
PRELIMINARY / UNVALIDATED. This review must not treat them as a valid
capability capture or claim access to the original FAT objects. The sanitised
record is `docs/platform/w176-stage4b-capability-physical-attempt.md`.

The old `capture_virtual()` required literal `stat -c '%F'` output
`regular file`; real Linux `/proc/version` reports `regular empty file`
despite `test -f` and a successful bounded read. The candidate removes prose
admission from both `capture()` and `capture_virtual()`, retains non-symlink
structural regular-file checks, and adds an opened-descriptor device/inode/mode
comparison to virtual reads. `/proc/self/mounts` and mountinfo are tied to the
collector shell PID for external-stat comparisons. Review that aliasing and
the exact source allowlist carefully.

The four target payload Git blobs at the candidate freeze are:

| USB root file | Bytes | SHA-256 |
|---|---:|---|
| gemn_auto.sh | 602 | `3cbe48aed6188606d701c774b19251e659ae31dae8942359496cdb78f1235c44` |
| mount_guard.sh | 5,536 | `7401bc34c9e85b0091f5d994169949e5af915cec87034c0bd97e236f83e4ad5c` |
| root_mount_guard.sh | 1,632 | `acfebdbf0dbdbe5135d453a3e41b8829c49fa8510117b35c960bebd9fe154d06` |
| capability_probe.sh | 17,806 | `ed8c94eba43dcfe3d8248ac9b9df1738615329fc14cb846a29ed85bede530b5a` |

The analyser is not a target payload. Its frozen blob remains 28,530 bytes,
SHA-256 `4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566`.
`docs/platform/w176-stage4b-capability-physical-handoff.md` must use the new
freeze and target hashes in every operative step; it is not physical approval.

Review the exact diff from the previous branch HEAD
`07f20e98d665d33423a7cc38b075351c56e34e62` through the candidate
implementation, then the documentation-only follow-up. Specifically:

1. Reproduce with **actual native Linux procfs** that the old collector
   rejects `/proc/version` as `absent_or_unsafe` while the new collector
   captures bounded content and completes a disposable fixture transaction.
   A mocked `%F` response alone is insufficient.
2. Audit all virtual sources: `/proc/version`, osrelease, filesystems,
   `/proc/self/mounts`, mountinfo, `/proc/mtd`, optional config.gz and kallsyms,
   and the five exact mtd12 sysfs attributes. Confirm none still require
   English `stat` prose or treat st_size zero as empty content.
3. Verify both read paths retain symlink rejection, regular-file semantics,
   exact allowlisting, descriptor/path identity where applicable, bounded
   reads, LIMIT+1 complete-view handling for mount/MTD association sources,
   producer-status checks, oversize rejection and false-COMPLETE prevention.
   Pay special attention to `/proc/self`'s process-relative inode semantics.
4. Re-run every preflight test, real FAT/stacked-mount regression, and all
   relevant Stage-4A regressions. Author-reported results are 69 preflight
   tests PASS, three real FAT/stacked-mount checks PASS, and 83 Stage-4A tests
   PASS plus eight Stage-4A native mount checks. Independently verify them.
5. Check the physical handoff's Git extraction, four exact root payloads,
   sizes/hashes, marker/lock semantics, return preservation and frozen host
   analyser. Confirm no old operative SHA or stale target hash remains.
6. Confirm the added sealed-runtime document is **design only**: no new
   target executable, feature syscall invocation, NVM write, or physical-run
   authorisation. `SEALED_RUNTIME_EXECUTION=NOT_TESTED` and
   `EXECUTION_HIGH=OPEN` must remain explicit.
7. Inspect the branch for proprietary raw target files, live arming markers,
   returned firmware/NVM material, unrelated Stage-4B remediation, and
   unexpected target-side changes. Do not rely on `.gitignore` alone.

Return findings with CRITICAL/HIGH/MEDIUM/LOW/INFO severity, exact file/line
evidence, reproducible failure conditions and the smallest safe remedy.
State whether the candidate is **READY FOR TARGETED PHYSICAL-HANDOFF REVIEW**
or **NO-GO**, but do not yourself grant physical GO. Stage-4B persistent
residency remains separately NO-GO.
