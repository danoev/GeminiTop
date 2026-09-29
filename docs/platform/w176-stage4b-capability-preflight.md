# W176 Stage-4B capability metadata preflight

Date: 2026-09-29. Separate branch: codex/w176-stage4b-capability-preflight,
based on a5034afef4a258813c202e72904cce2f70abee2e. The original
feature/w176-stage4b checkout retains its uncommitted NO-GO remediation and
architecture research. The last independently reviewed production candidate
remains 052332973c1e28566395483b52ba11eda72db772.

Stage-4B remains NO-GO. This candidate invokes no memfd, sealing, or exec
feature syscall, executes no new ARM code, and has not run on the vehicle.

## Exact sources and evidential limits

| Source | Target read ceiling | Can support | Cannot prove |
|---|---:|---|---|
| uname -a; /proc/version; /proc/sys/kernel/osrelease | 4, 8, 1 KiB | Running kernel/architecture identity when consistent | Vendor kernel equals upstream 4.9 or enables a syscall |
| /proc/filesystems | 16 KiB | Registered tmpfs/proc filesystem names | Memfd or sealing enabled |
| /proc/config.gz; exact /boot/config-4.9.217 | 256, 512 KiB, optional | CONFIG_TMPFS, CONFIG_PROC_FS and other build options; conflicting configs mean UNKNOWN | Actual syscall dispatch, security policy, seal or exec success |
| /proc/kallsyms | First 512 KiB only, optional; output is symbol names only | Positive memfd/shmem-seal/execveat symbol presence | Absence, because prefix truncation, visibility, filtering, vendor naming and permissions can hide symbols |
| /proc/self/mounts; /proc/self/mountinfo; /proc/mtd | 64, 128, 16 KiB | Exact NVM mount source, root, mountpoint, YAFFS2/RW, and MTD map | NVM write safety or stable future mount state |
| Exact stat/readlink for /media, NVM path, /dev/mtdblock12, /sys/class/mtd/mtd12, /sys/class/block/mtdblock12, derived /sys/dev/block major:minor, /proc/self/fd | Per-line bounded metadata, no device open | Symlink, type, device, inode, mode, major/minor and association presentation | Raw MTD contents or executable support |
| Exact /sys/class/mtd/mtd12 name/type/size/erasesize/dev | 4 KiB each, optional | MTD sysfs text | Device contents |
| /lib/libc.so.6 and /lib/ld-linux-armhf.so.3 link metadata; exact /lib/libc-2.30.so and /lib/ld-2.30.so copies | 1 MiB and 128 KiB, optional | Installed size/hash and offline ELF32 ARM dynamic-symbol exports | Missing wrapper implies missing kernel syscall; sealed memfd execution |

No glob or recursive source search is used. /boot and /lib copies require
the effective root mount to be read-only SquashFS, with no covering nested
mount and matching filesystem device identity. Unsafe provenance means no
copy. Exact regular-file sources are checked before and after a retained,
bounded descriptor read. Proc/sysfs pseudo-files use finite read counts
because their reported size can be zero. The captured mount/MTD association
views and mtd12 attributes use byte-granularity LIMIT+1 reads, so their
bounded copy is complete or marked oversized rather than accepting a
short-read prefix. Other pseudo-files retain their separately bounded reads;
producer exit status and actual output size are checked separately. The /proc/self/mounts read provides the
/proc/mounts view without following its usual symlink.

This capture can reduce the separate mountinfo/sysfs presentation UNKNOWN,
and may establish installed libc exports statically. Config plus positive
symbol metadata can support compiled presence only. Absent, unreadable,
truncated, contradictory or malformed evidence remains UNKNOWN.

## Transaction and analyser

The payload and limits are documented in the candidate README. The USB guard
reads at most 65,537 bytes from `/proc/mounts` and 131,073 bytes from
`/proc/self/mountinfo`, rejecting snapshots above 65,536 and 131,072 bytes
respectively, before any mutation. `dd bs=1 count=LIMIT+1` means the count
cannot expire after short positive 4-KiB reads: each counted input block is
one byte. At <=LIMIT bytes, successful `dd` must have reached EOF; at LIMIT+1,
the guard fails oversized. Nonzero producer status fails separately. This uses
basic BusyBox 1.29.3 `dd` semantics without assuming `iflag=fullblock`.
The [BusyBox 1.29 stable `dd` source](https://github.com/mirror/busybox/blob/1_29_stable/coreutils/dd.c)
counts full or partial input blocks and uses `bs`/`count` independently of
the optional `iflag` feature; a one-byte block therefore cannot be a short
positive read.
It permits at most 256 records and 2,048
bytes per line in each view. It rejects duplicate or nested covering mounts
and cross-checks the FAT source, removable block node, mountinfo major:minor
and the output root's `st_dev`. This proves complete bounded mount views and
effective filesystem identity **at validation time**. It does not establish
resistance to a privileged actor deliberately changing mounts between that
check and the first USB write; no such adversary is assumed in this passive
physical-test boundary. The result
is fresh, USB-only, checksum-covered and exact-inventory. INCOMPLETE is
written first; COMPLETE is last. The host analyser rejects symlinked or
unexpected evidence, unsafe paths, oversize files, wrong schema/status,
duplicate or malformed records, inventory/checksum mismatches and false
COMPLETE. It never executes copied target files.

Classification vocabulary:

    KERNEL_IDENTITY=CONFIRMED|UNKNOWN
    UPSTREAM_4_9_MEMFD_COMPATIBILITY=REFERENCE_ONLY
    TARGET_MEMFD_SUPPORT=SUPPORTED_BY_METADATA|UNKNOWN
    TARGET_SEALING_SUPPORT=SUPPORTED_BY_METADATA|UNKNOWN
    TARGET_EXECVEAT_SUPPORT=SUPPORTED_BY_METADATA|UNKNOWN
    TARGET_LIBC_WRAPPER_MEMFD_CREATE=OBSERVED|NOT_OBSERVED|UNKNOWN
    TARGET_LIBC_WRAPPER_EXECVEAT=OBSERVED|NOT_OBSERVED|UNKNOWN
    TARGET_LIBC_WRAPPER_FEXECVE=OBSERVED|NOT_OBSERVED|UNKNOWN
    NVM_MOUNT_PRESENTATION=CONFIRMED|PARTIAL|CONTRADICTORY|UNKNOWN
    SEALED_RUNTIME_EXECUTION=NOT_TESTED
    EXECUTION_HIGH=OPEN

OBSERVED requires a defined, globally/weakly bound, externally visible
function in an ELF32 ARM ET_DYN loadable shared object, plus an exact one-hop
`/lib/libc.so.6` resolution to the copied `libc-2.30.so` object. Program
headers must be bounded, PT_LOAD must contain PT_DYNAMIC and the dynamic
symbol/string tables, required dynamic tags must match those tables, and
SONAME must be `libc.so.6`. ELF identification must state the current version;
PT_LOAD ranges must be in-file, non-overlapping, aligned and non-wrapping.
For each requested visible defined function, `st_value` with the ARM Thumb
indicator bit stripped must locate its entry in file-backed executable
PT_LOAD bytes. Nonzero `st_size` must fit in that same file-backed range;
zero-size symbols still require one entry byte. This follows the
[Arm AAELF32 Thumb symbol convention](https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst)
and [ELF PT_LOAD/PF_X semantics](https://refspecs.linuxfoundation.org/elf/gabi4%2B/ch5.pheader.html)
as reference rules, not an observed installed-target ABI extension.
ET_REL/ET_EXEC, malformed structure or unresolved
provenance gives UNKNOWN. An undefined import or hidden symbol in a validated
image is NOT_OBSERVED, not proof of kernel syscall absence. NVM CONFIRMED
requires coherent mount source/type/RW in all three exact option fields:
`/proc/mounts` options, mountinfo per-mount options and mountinfo superblock
options. Each must contain exactly one `rw` token and no `ro` token; empty,
duplicate or conflicting semantic tokens are CONTRADICTORY. Before those
semantics, the analyser validates the **raw captured** `/proc/mounts` and
mountinfo text: strict UTF-8, LF record boundaries, literal ASCII-space field
separators, no literal controls/DEL/non-printable characters, and complete
record grammar. It never collapses tabs or other whitespace into separators.
Every `/proc/mounts` record has exactly six nonempty fields: textual source,
mountpoint and filesystem, validated options, and ASCII-decimal dump and pass
fields. Every mountinfo record has ASCII-decimal mount and parent IDs,
ASCII-decimal `major:minor`, textual root and mountpoint, validated per-mount
options, zero or more structurally valid `tag[:value]` optional fields, one
separator in its required position, and textual filesystem/source plus
validated superblock options. Zero IDs are accepted as decimal syntax, not
claimed as installed values. Unknown but valid optional tags are accepted.
Textual fields are preserved verbatim, not decoded: a backslash must start a
complete three-octal-digit escape; visible non-whitespace text otherwise
remains admissible. Structural failure in either captured view is
CONTRADICTORY before NVM-specific source/type/RW or MTD/sysfs comparison.
Each option field is nonempty and comma-delimited; every token is visible,
non-whitespace and nonempty, duplicates are rejected, and `key=value` requires
nonempty key and value. Printable paths, `foo=bar`, additional `=` within a
value, and visible backslash escape text remain accepted. A malformed required
view is CONTRADICTORY, not PARTIAL. This fail-closed grammar follows the
space-delimited, escaped-path presentation in the
[Linux 4.9 `/proc` mount formatter](https://github.com/torvalds/linux/blob/v4.9/fs/proc_namespace.c)
and the [kernel mountinfo field description](https://www.kernel.org/doc/html/latest/filesystems/proc.html)
as REFERENCE ONLY; it does not assert a vendor extension or installed value.
It also requires
mountinfo major:minor, logical `/media` link, block node, matching dev/block
and class/block sysfs targets, `/proc/mtd` mtd12 identity and sysfs name,
size, dev, erase-size and type attributes. For the reported YAFFS2/MTD
association, upstream Linux MTD type text `nand` or `mlc-nand` permits
CONFIRMED; a different recognized type is PARTIAL and malformed type is
CONTRADICTORY. This does not assert the installed unit's type before capture.
The finite recognized strings come from the
[Linux 4.9 MTD sysfs type implementation](https://github.com/torvalds/linux/blob/v4.9/drivers/mtd/mtdcore.c).
A missing association is PARTIAL, while conflicting evidence is CONTRADICTORY.
SUPPORTED_BY_METADATA requires coherent config and positive
relevant symbol names where applicable. Neither category permits
SEALED_RUNTIME_EXECUTION=CONFIRMED.

The NVM association audit evaluates each captured field: both mount views
must agree on source `/dev/mtdblock12`, YAFFS2, RW, exact path and
major:minor; the NVM directory's `st_dev` and block node's `rdev` must match
that pair; the `/media` link must resolve to the expected logical mount path;
`/sys/dev/block` and `/sys/class/block` links must resolve to the same
`mtdblock12` object; `/proc/mtd` must identify mtd12 as `nvm` with the
reviewed size and erase size; and sysfs mtd12 name, size, dev, erase size
and type must be present and coherent. Missing optional associations reduce
to PARTIAL. This is metadata presentation only, not a permission to write NVM.

## Hard limit

No: a stock-shell metadata-only probe cannot close the remaining HIGH.
It can suggest compiled features and identify userspace exports. It cannot
prove that the installed RoadTop permits memfd creation with sealing,
accepts all required seals, rejects later writes, and executes the protected
ARMHF dynamic ELF by descriptor. The smallest remaining runtime capability
question is whether that complete seal-verify-execute sequence succeeds on
the installed kernel/loader. A separately reviewed and explicitly authorised
minimal native experiment would be needed later; none is built here.

## Host verification

The frozen `0f65de8` implementation was reproduced failing all five
first-review findings. The later `d5a608a` implementation was reproduced
failing the second review's short-read HIGH and MTD-type/ET_REL MEDIUM findings
before that remediation. The frozen `d7fc83a` implementation was reproduced
falsely confirming three checksum-valid contradictory RW/RO captures and
falsely observing both an EI_VERSION=0 and an unmapped function value before
that analyser-only remediation. The later frozen `bf8b87d` analyser was
reproduced falsely confirming six checksum-valid captures containing
`rw,ro\x00` or `rw,\x00` in each of the three required option fields.
The later frozen `3da1e48` analyser was reproduced falsely confirming four
checksum-valid captures with `bad` mountinfo mount/parent IDs or `bad`
`/proc/mounts` dump/pass fields. This round validates complete raw records,
adds 58 malformed structural cases, 264 textual-control injections and
positive unknown-tag/escaped-path cases without changing the payload.
Fixtures cover real-guard collector
integration, FAT identity, stacked/deeper mounts, byte/record/line ceilings,
native FIFO short reads, NVM contradiction/partial/coherent cases,
defined/undefined/hidden ET_DYN ELF
symbols, out-of-scope libc links and truncated kallsyms records. Separate
container testing mounts a disposable FAT image and then stacks tmpfs over
the exact root and a child path. The complete test totals and new frozen
commit are recorded in the follow-up independent-review brief. These are
host results, not RoadTop observations.

No payload writer or mount guard changes in this round. The sum of allowed
final logical file sizes remains 2,287,680 bytes. The largest
single temporary file is 1,052,672 bytes; both kallsyms working files can
coexist at that total. A deliberately conservative final-plus-temporaries
logical sum is 3,354,752 bytes: 2,287,680 final + 1,052,672 concurrent
kallsyms temporaries + 14,400 other temporary allowances. The 3072-KiB final acceptance check
is not a peak-write bound, and FAT write amplification is not claimed.

No stock file, internal NVM, MTD, service, CAN/MCU/UART, or network state was
changed. No physical test is approved by this report.
