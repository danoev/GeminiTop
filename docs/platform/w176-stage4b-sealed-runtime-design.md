# W176 volatile sealed-runtime execution: design draft only

Status: **NOT IMPLEMENTED / NOT REVIEWED / NOT TESTED ON TARGET**.
`SEALED_RUNTIME_EXECUTION=NOT_TESTED`; `EXECUTION_HIGH=OPEN`. This is a
candidate for a separate later milestone, not part of the metadata collector,
USB payload, or Stage-4B residency installer. The incomplete physical
preflight's uname/symbol lines are **PRELIMINARY / UNVALIDATED** and do not
establish that any syscall works on the installed RoadTop.

## Question and boundary

Can the installed RoadTop, entirely in volatile memory, create a sealable
anonymous execution object, load exactly reviewed ARMHF bytes, verify and
seal them, demonstrate mutation rejection, and execute that object by file
descriptor? The only durable output would be a bounded transaction report on
a separately validated removable USB. No NVM, stock file, service, init,
Launcher, PATH, library search path, CAN/MCU/UART stream, UI, or network state
would be touched. This would prove a possible immutable runtime step; it
would **not** itself prove persistent residency or boot persistence.

## Reference ABI, not installed-target proof

The [Linux v4.9 ARM UAPI syscall table](https://raw.githubusercontent.com/torvalds/linux/v4.9/arch/arm/include/uapi/asm/unistd.h)
sets the EABI syscall base to zero and assigns `memfd_create` 385,
`execveat` 387, and `fcntl64` 221. These are **REFERENCE ONLY** for the vendor
4.9.217 kernel until a target runtime test succeeds. Prefer the toolchain's
ARM EABI `__NR_*` definitions and a small reviewed `syscall()` adapter or
explicit ARM EABI syscall wrappers; never borrow AArch64 or host numbers.
Record syscall return values and `errno` separately. The installed libc's
exports are not yet validated by a COMPLETE preflight, so the design must not
depend on named `memfd_create` or `execveat` libc wrappers.

The [v4.9 memfd flags](https://raw.githubusercontent.com/torvalds/linux/v4.9/include/uapi/linux/memfd.h)
include `MFD_ALLOW_SEALING`; without it, the initial `F_SEAL_SEAL` prevents
later seals. The [Linux file-sealing API](https://man7.org/linux/man-pages/man2/F_GET_SEALS.2const.html)
provides `F_ADD_SEALS`/`F_GET_SEALS` and the candidate mask
`F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL`.
`F_SEAL_EXEC` is a later-kernel feature and is **not** part of this 4.9
candidate. `F_SEAL_WRITE` can fail while writable shared mappings exist, so
the first design should use ordinary bounded writes without such mappings.
All flags, commands, calling conventions, and returned seal bits require
toolchain-header review against the pinned target ABI before implementation.

`execveat(fd, "", argv, envp, AT_EMPTY_PATH)` is the preferred descriptor
execution path ([interface reference](https://man7.org/linux/man-pages/man2/execveat.2.html)).
The reviewed payload must be a native ELF, not a script. A dynamic ARMHF ELF
still names a stock PT_INTERP loader and may need stock libc at startup; the
prior Stage-3 USB ELF success supports the general ABI but does not establish
sealed memfd execution. The future image needs its own static
interpreter/NEEDED/version/import audit. `MFD_CLOEXEC` and interpreter behavior
must be tested with the exact ELF and loader rather than inferred from man-page
script behavior. Do **not** silently fall back to `/proc/self/fd/<n>` if
`execveat` fails; that would be a different route with separate identity,
mount, loader, and review questions.

## Proposed separately reviewed transaction

1. Positively validate the known W176 target and exact removable USB as in
   the reviewed one-shot methodology; require a fresh marker and lock. Create
   an INCOMPLETE report before feature operations. Use only a single frozen,
   hash-verified tiny ARMHF ELF whose behavior is an inert bounded pipe
   handshake and deterministic exit. No Stage-3 or other binary is reused
   without reviewing its actual behavior.
2. Create one named memfd with `MFD_ALLOW_SEALING` (and an independently
   reviewed close-on-exec choice). Copy exactly the reviewed image bytes from
   the verified USB source using bounded reads/writes; check length, hash,
   descriptor type, and absence of extra bytes. Re-read the anonymous object
   through its descriptor and compare its size and SHA-256 with the reviewed
   image. Do not mmap it writable.
3. Apply the four-seal mask; require exact expected `F_GET_SEALS` bits.
   Attempt a bounded `pwrite` to one byte and both grow/shrink operations,
   requiring rejection without content change. Re-read/hash after rejection.
   Test that an added seal is rejected only after `F_SEAL_SEAL` is present.
   Any different outcome is a capability failure, not permission to proceed.
4. Fork one own child and execute the descriptor using `execveat` with
   `AT_EMPTY_PATH`. The tiny image writes a fixed ready token on a prearranged
   anonymous pipe, then waits for a bounded release token and exits with a
   fixed code. The parent correlates PID and start time, inspects
   `/proc/<child>/exe` while the child is alive, and compares its device/inode
   with the sealed descriptor. A display such as `memfd:<name> (deleted)` is
   expected by reference, not sufficient alone; the installed rendering and
   access policy remain UNKNOWN. Do not inspect or signal stock processes.
5. Release and reap the child with a bounded timeout. A timeout may TERM and
   then forcibly reap **only this proven child**; any identity ambiguity
   becomes failure with manual-review status. Close descriptors and pipes.
   The USB report records per-step return/errno, expected-vs-observed hash,
   seals, child identity, ready token, exit status, and cleanup result. No
   addresses, firmware bytes, NVM material, or private user data are needed.

`COMPLETE` means a valid, checksum-covered transaction was returned; it is
not synonymous with capability PASS. `SEALED_RUNTIME_EXECUTION=CONFIRMED`
would require all byte, seal, rejected-mutation, child-identity, execution,
exit, and cleanup gates to pass on the installed target. A complete report
with any failed gate must say `CAPABILITY=FAIL` or `UNKNOWN`, never PASS.
Missing/ambiguous output remains INCOMPLETE. Report creation and analysis
must be independently reviewed for false-COMPLETE behavior.

## Gates and next path

1. Corrected metadata capture returns checksum-valid COMPLETE.
2. Host analyser validates it and classifies kernel/config/symbol/libc/NVM
   presentation without promoting metadata into runtime proof.
3. If evidence supports the primitives, freeze and independently review a
   **new** volatile capability payload and its recovery procedure.
4. Only a separately authorised physical run may resolve this question.
5. If it passes, reconsider Stage-4B as a validated persistent NVM artifact
   feeding an immutable sealed volatile execution object, followed by a
   separate Stage-4B installer/uninstaller review and physical proof.
6. Actual GeminiTop service/integration work comes only after those gates.

Until then, `SEALED_RUNTIME_EXECUTION=NOT_TESTED` and `EXECUTION_HIGH=OPEN`.
