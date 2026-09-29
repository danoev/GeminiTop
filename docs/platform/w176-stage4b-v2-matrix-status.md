# W176 Stage-4B v2 host safety matrix — 2026-09-29

This is host-only evidence for the candidate implementation, **not physical GO**.
The 88 required scenario rows are defined individually in
`tools/w176-stage4-residency/matrix.psv`; the 20 interrupted-state decisions
are in `tools/w176-stage4-residency/recovery_states.psv`. Both are checked by
`tools/w176-stage4-residency/run_matrix.sh` against actual PASS lines from
disposable Linux fixtures. A missing, repeated, skipped, or partial required
marker fails the run. Shared markers represent one test that directly checks
multiple stated requirements; they are not presented as 88 independent tests.
Two verifier mutation tests confirm that missing, duplicate, FAIL, SKIP,
PARTIAL, XFAIL, and NOT RUN markers are rejected for both ledgers.

The complete 2026-09-29 run reported:

```text
residency integration cases: 120 PASS
process / FD helper cases: 18 PASS
privileged real mount cases: 10 PASS
privileged block-node / sysfs metadata cases: 7 PASS
REQUIRED_MATRIX=88 PASS=88 FAIL=0 SKIP=0 PARTIAL=0
RECOVERY_STATES=20 PASS=20 FAIL=0 SKIP=0 PARTIAL=0
```

The matrix records each row's evidence class: `REAL-LINUX`,
`DISPOSABLE-MOUNT`, or `SYNTHETIC-DETERMINISTIC`. The mount suite uses real
Linux `/proc/self/mountinfo`, nested tmpfs/ext4, external and same-device bind
mounts. Its test-only copy changes the required base-filesystem literal from
YAFFS2 to tmpfs; production validation remains unchanged. The block-binding
suite uses a real block-special node and disposable sysfs metadata, but never
opens that node. Neither suite establishes the installed vendor kernel's exact
sysfs presentation; a mismatch on target must fail before the first write.

The 20-state recovery table specifies six decisions for every boundary:
fresh install, verify, uninstall, one-shot replay, automatic deletion, and
manual review. The tests exercise the real action selectors on interrupted
fixtures and a clean second-USB fixture against the same retained NVM state.
States I and J are adjacent descriptions of the same launched-but-not-proven
boundary and intentionally share one test marker. State M alone permits a
*new, separately armed uninstall* after an interrupted verify; it never
replays verify. All other interrupted states fail closed and retain NVM for
manual review. No fixture grants automatic persistent deletion.

The three separate USB-result transaction suites each inject nine failures:
initial STATUS, final STATUS, evidence hash, manifest hash, checksum commit,
required-file validation, COMPLETE temp creation, COMPLETE hash, and COMPLETE
rename. All 27 fault cases reject false COMPLETE. A later USB-output failure
after process launch retains the committed NVM files and running process.

The reviewed FD envelope is numeric descriptors `0..127`. A descriptor above
127 is `NOT_INSPECTED`, so detachment is UNKNOWN and install/verify cannot
COMPLETE; it is not treated as proof of no USB reference. This conservative
bound avoids unbounded proc enumeration on the installed unit. FD disappearance,
appearance, failed `readlink`, changed target, and unavailable FD directory
also fail closed. The bound is a Stage-4B safety limitation, not evidence that
the RoadTop process can never allocate a higher descriptor.

The exact ARMHF daemon remains 5,556 bytes, SHA-256
`684afd86a067a6e175ed6b7d6c2a0281f1d44c67f62d86431589d1d7bd8c41b8`.
Two clean Linux/arm64 toolchain-container builds were byte-identical to this
committed binary, and the static ELF/interpreter/NEEDED/version/import audit
passed. The target ARMHF binary was **not executed or emulated**. Physical
Stage-4B action still requires a fresh independent safety review and explicit
operator authorization for the exact frozen implementation.
