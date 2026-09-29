# W176 Stage-4B capability metadata preflight

This is a separately armed, observation-only candidate. It is not the
Stage-4B residency installer, does not implement sealed execution, and does
not authorise a physical run.

Payload:

- payload/gemn_auto.sh: stock USB entry point.
- payload/mount_guard.sh: Stage-4B effective removable-FAT mount guard.
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

The guard checks bounded `/proc/mounts` and `/proc/self/mountinfo` views
before lock creation or marker consumption. It rejects stacked/covering
mounts, ambiguous or malformed records, and filesystem/device identity
disagreement. `test_linux_mounts.sh` additionally exercises actual FAT and
stacked-tmpfs mounts inside a disposable privileged Linux container with a
temporary FAT image; do not run that script on a vehicle or the host.

The host NVM classification is `CONFIRMED`, `PARTIAL`, `CONTRADICTORY`, or
`UNKNOWN`. `CONFIRMED` requires coherent mount, device, MTD and sysfs
evidence; unavailable physical associations remain `PARTIAL`. Libc wrapper
`OBSERVED` requires a defined, externally visible ELF32 ARM function in the
one-hop selected installed libc copy. An import, hidden symbol, out-of-scope
link, or malformed copy cannot prove an exported wrapper.

Final logical schema maximum is 2,287,680 bytes and the final acceptance
ceiling remains 3072 KiB. The largest individual temporary file is
1,052,672 bytes; the two kallsyms working files can together reach that
same amount. A deliberately conservative final-plus-temporaries logical
sum is below 3,355,000 bytes. `output_write_ceiling=NOT_CLAIMED`: FAT block
allocation, metadata and repeated writes prevent a physical peak-write
claim.

Do not commit raw returned libc, loader, kernel configuration, mount table,
or other physical capture data without separate sanitisation review.
A valid COMPLETE transaction is not proof that memfd, sealing, and descriptor
execution work together. The analyser always emits
SEALED_RUNTIME_EXECUTION=NOT_TESTED and EXECUTION_HIGH=OPEN.

No NVM write, remount, new ARM code, feature syscall, CAN/MCU/UART stream,
network operation, process signal/attach, or stock-file modification is part
of this probe.
