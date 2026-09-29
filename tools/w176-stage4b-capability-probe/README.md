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

The guard reads each mount view byte-by-byte with `dd bs=1 count=LIMIT+1`;
success with at most LIMIT bytes means an actual EOF was reached, while
LIMIT+1 fails oversized. Unlike `bs=4096 count=17/33`, a short positive read
cannot exhaust the count early: one counted input block is one byte. This uses
the basic `bs`/`count` behaviour available in BusyBox 1.29.3, not a GNU-only
`iflag=fullblock`. Producer nonzero remains a read failure. It rejects stacked/covering
mounts, ambiguous or malformed records, and filesystem/device identity
disagreement. `test_linux_mounts.sh` additionally exercises actual FAT and
stacked-tmpfs mounts inside a disposable privileged Linux container with a
temporary FAT image; short-read FIFO fixtures exercise the real guard in Linux.
Do not run the mount script on a vehicle or the host. These checks establish
complete bounded views and effective identity at validation time, not immunity
to a privileged actor remounting between validation and first USB write.

The host NVM classification is `CONFIRMED`, `PARTIAL`, `CONTRADICTORY`, or
`UNKNOWN`. `CONFIRMED` requires coherent mount, device, MTD and sysfs
evidence; unavailable physical associations remain `PARTIAL`. Captured MTD
name, size, dev, erase size and type are all classified; `nand` or `mlc-nand`
supports the YAFFS2 association, an unfamiliar/malformed type contradicts it,
and another recognized family leaves it `PARTIAL`. Each of the `/proc/mounts`
options, mountinfo per-mount options and mountinfo superblock options must
contain exactly one `rw` token and no `ro` token; malformed or conflicting
options are `CONTRADICTORY`. The analyser reads the raw captured view as
UTF-8 lines separated only by LF and preserves literal spaces instead of
normalising whitespace. Literal controls, DEL, non-printable text, malformed
record fields, empty comma tokens, duplicate tokens and key/value tokens with
an empty side are contradictory. Printable non-whitespace options such as
`foo=bar`, visible paths and backslash escape text remain admissible. This is
a conservative evidence grammar, not a claim that every vendor option was
observed on the installed unit. Complete raw-record validation precedes NVM
semantics: `/proc/mounts` requires six fields including decimal dump/pass;
mountinfo requires decimal mount/parent IDs and major:minor, textual
root/point/source/type, parsed options, any structurally valid unknown
`tag[:value]` optional fields, and its separator at the required position.
Zero IDs are accepted as syntax only. Text is not unescaped: each literal
backslash must introduce exactly three octal digits, while ordinary visible
text remains permitted. Any malformed captured record makes the required
view `CONTRADICTORY`, before a positive NVM association can be inferred.
Libc wrapper `OBSERVED`
requires a defined, externally visible ELF32 ARM function in a provenance-bound
ET_DYN loadable shared image with bounded PT_LOAD/PT_DYNAMIC, matching dynamic
string/symbol tables and `libc.so.6` SONAME. The symbol entry (and its stated
nonzero size) must map to file-backed bytes of an executable PT_LOAD; the
Thumb low bit is stripped for the address check. Bad ELF identification,
out-of-range/overlapping segments, ET_REL, ET_EXEC, an import, hidden
symbol, out-of-scope link, or malformed copy cannot prove an exported wrapper.

Final logical schema maximum is 2,287,680 bytes and the final acceptance
ceiling remains 3072 KiB. The largest individual temporary file is
1,052,672 bytes; the two kallsyms working files can together reach that
same amount. A deliberately conservative final-plus-temporaries logical
sum is 3,354,752 bytes. This analyser-only remediation changes no payload
writer or bound. `output_write_ceiling=NOT_CLAIMED`: FAT block
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
