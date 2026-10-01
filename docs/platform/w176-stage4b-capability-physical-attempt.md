# W176 Stage-4B capability preflight: incomplete physical attempt

One separately authorised metadata-only attempt used the collector frozen at
`465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed`. The values below are
**operator-returned physical evidence**. This repository update did not
inspect the original USB filesystem or raw returned target files.

The arming marker was consumed; `.stage4b-capability.lock` was retained; and
the result directory was created. The returned `STATUS.txt` reported
`status=INCOMPLETE`, `mandatory_failures=1`, `optional_unknowns=3`. The exact
mandatory error was `failure.1=proc_version:absent_or_unsafe`. `COMPLETE`,
`INVENTORY.txt`, and `checksums.sha256` were absent. This is **not** a
checksum-valid capability capture. No target capability classification is
promoted from its partial files.

The partial uname, kernel-symbol and object-metadata lines are only
**PRELIMINARY / UNVALIDATED physical debug observations**. In particular,
the reported `/proc/kallsyms` description was `regular empty file` with
metadata size zero, while the bounded read returned symbol-name text. The
returned `SUMMARY.txt` stated `feature_syscalls.invoked=0`, `nvm.writes=0`,
`device_streams.opened=0`, and `sealed_runtime_execution=NOT_TESTED`. These
are operator-supplied statements from the incomplete transaction, not an
independent reconstruction of its original USB objects.

The frozen collector required the human-readable `stat -c '%F'` output to be
exactly `regular file` before reading virtual sources. On native Linux,
`/proc/version` is a readable regular procfs object even when GNU/BusyBox
`stat` describes it as `regular empty file` and reports size zero. A regression
using actual Linux `/proc/version` reproduces the frozen collector's exact
`proc_version:absent_or_unsafe` failure. The remediation removes this prose
comparison, retains non-symlink regular-file admission and bounded reads,
and verifies the opened descriptor against the exact source identity.

The revised collector requires a fresh independent review and a separately
authorised, newly prepared one-shot USB attempt. The used USB's retained
lock and consumed marker must not be treated as a reusable armed payload.
Stage-4B residency remains NO-GO; sealed runtime execution remains NOT TESTED.
