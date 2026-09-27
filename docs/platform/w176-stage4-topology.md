# W176 Stage-4A CAN / MCU topology candidate

Status: prepared and host-tested; no physical run or physical GO.

## Exact scope

The separately armed candidate classifies the installed Linux vehicle boundary
as raw CAN, MCU/proprietary translated events, hybrid, or insufficient evidence.
It captures only:

- bounded `/proc/net/dev` and `/sys/class/net` metadata;
- `stat`/`lstat`, symlink, major/minor, permission, and sysfs associations for
  `/dev/canbox_protocol_dev`, `/dev/hc_mcu_dev`, `/dev/ttyS1`, and narrowly
  named CAN/MCU/UART candidates;
- bounded `/proc/<pid>/fd` symlink correlation, with double-read FD and PID
  start-time identity checks;
- bounded `comm`, `cmdline`, `exe` symlink, and `maps` only for matched
  production owners; and
- descriptor-verified bounded copies of installed
  `libappframework.so.1.0.0` and
  `libappmcucommunication.so.1.0.0` for off-target static analysis.

No candidate device is opened. No CAN frame is received or transmitted. No
MCU command, UART read, ioctl, interface change, logging change, process
attachment, library execution, or target-storage write is present.

## Bounds

The candidate limits inspection to 256 processes, 128 FDs per process, 4,096
FD links total, 16 matched owners, 64 KiB maps per owner and 512 KiB maps total,
32 interfaces, 64 device candidates, 32 configuration-name candidates, 384
KiB for `libappframework`, 320 KiB for `libappmcucommunication`, 704 KiB of
library bytes total, and 2 MiB of USB output.

The installed library sizes confirmed by Stage 2 (287,536 and 213,496 bytes)
fit those individual limits.

## Host validation

Disposable fixtures cover a blocking FIFO device candidate, symlink candidates,
PID and FD disappearance, FD/process/maps bounds, library size bounds, missing
mandatory libraries, false-completion prevention, checksum tampering, and USB
identity failure. The FIFO test completes within its timeout, supporting the
source-level guarantee that enumeration uses metadata and symlink operations
without opening the device stream.

The arming marker is absent. A physical result remains UNKNOWN until a separate
review and operator decision.
