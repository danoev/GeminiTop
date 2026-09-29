# W176 Stage-4B capability metadata preflight

This is a separately armed, observation-only candidate. It is not the
Stage-4B residency installer, does not implement sealed execution, and does
not authorise a physical run.

Payload:

- payload/gemn_auto.sh: stock USB entry point.
- payload/mount_guard.sh: unchanged Stage-4A removable-FAT guard.
- payload/root_mount_guard.sh: read-only SquashFS source guard for /lib and /boot.
- payload/capability_probe.sh: bounded metadata collector.
- payload/ARM_STAGE4B_CAPABILITY_PREFLIGHT.example: inert example, not a live marker.
- analyze.py: off-target transaction and static ELF analyser.
- test_preflight.py: disposable native-Linux fixtures.

The collector uses a positively identified removable FAT mount, consumes the
exact marker only after retaining a persistent one-shot lock, selects one
atomic fresh output directory, writes INCOMPLETE first, and publishes COMPLETE
last. Optional unavailable evidence is UNKNOWN. The final 3072-KiB
acceptance check is not a pre-write reservation; each producer has a separate
byte ceiling and the shell has a file-size limit.

Host analysis:

    python3 tools/w176-stage4b-capability-probe/analyze.py /path/to/stage4b-capability

Host tests:

    python3 -m unittest discover -s tools/w176-stage4b-capability-probe -v

Do not commit raw returned libc, loader, kernel configuration, mount table,
or other physical capture data without separate sanitisation review.
A valid COMPLETE transaction is not proof that memfd, sealing, and descriptor
execution work together. The analyser always emits
SEALED_RUNTIME_EXECUTION=NOT_TESTED and EXECUTION_HIGH=OPEN.

No NVM write, remount, new ARM code, feature syscall, CAN/MCU/UART stream,
network operation, process signal/attach, or stock-file modification is part
of this probe.
