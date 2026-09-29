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
| Exact stat/readlink for /media, NVM path, /dev/mtdblock12, /sys/class/mtd/mtd12, derived /sys/dev/block major:minor, /proc/self/fd | Per-line bounded metadata, no device open | Symlink, type, device, inode, mode, major/minor and association presentation | Raw MTD contents or executable support |
| Exact /sys/class/mtd/mtd12 name/type/size/erasesize/dev | 4 KiB each, optional | MTD sysfs text | Device contents |
| /lib/libc.so.6 and /lib/ld-linux-armhf.so.3 link metadata; exact /lib/libc-2.30.so and /lib/ld-2.30.so copies | 1 MiB and 128 KiB, optional | Installed size/hash and offline ELF32 ARM dynamic-symbol exports | Missing wrapper implies missing kernel syscall; sealed memfd execution |

No glob or recursive source search is used. /boot and /lib copies require
the effective root mount to be read-only SquashFS, with no covering nested
mount and matching filesystem device identity. Unsafe provenance means no
copy. Exact regular-file sources are checked before and after a retained,
bounded descriptor read. Proc/sysfs pseudo-files use finite read counts
because their reported size can be zero; producer exit status and actual
output size are checked separately. The /proc/self/mounts read provides the
/proc/mounts view without following its usual symlink.

This capture can reduce the separate mountinfo/sysfs presentation UNKNOWN,
and may establish installed libc exports statically. Config plus positive
symbol metadata can support compiled presence only. Absent, unreadable,
truncated, contradictory or malformed evidence remains UNKNOWN.

## Transaction and analyser

The payload and limits are documented in the candidate README. The result
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
    NVM_MOUNT_PRESENTATION=CONFIRMED|UNKNOWN
    SEALED_RUNTIME_EXECUTION=NOT_TESTED
    EXECUTION_HIGH=OPEN

NOT_OBSERVED requires a complete, structurally valid ELF32 ARM dynamic
symbol table from the exact copied libc. Missing/unparseable libc is
UNKNOWN. SUPPORTED_BY_METADATA requires coherent config and positive
relevant symbol names where applicable. Neither category permits
SEALED_RUNTIME_EXECUTION=CONFIRMED.

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

Fourteen disposable native-Linux fixture cases passed: complete and missing
optional evidence, conflicting configs, oversized sources, unsafe symlinks,
producer nonzero with plausible output, guarded RO-root/nested-RW/special
source cases, malformed/duplicate metadata, checksum/inventory corruption,
false COMPLETE, and USB-guard failure. The unchanged historical Stage-4A
transaction suite passed 83 tests. These are host results, not RoadTop
observations.

No stock file, internal NVM, MTD, service, CAN/MCU/UART, or network state was
changed. No physical test is approved by this report.
