# W176 Stage 4B capability metadata physical handoff procedure

This is an operator and independent-review handoff for one possible future
metadata-only capture on the installed W176 RoadTop. It is **not physical GO**.
No USB was prepared or armed, and no vehicle action was performed while writing
this document. Use it only after a separate physical-handoff safety review
returns GO and the owner separately authorises one controlled attempt.
Stage-4B persistent residency remains NO-GO.

The independently host-reviewed implementation is frozen at
465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed. Every future extraction below
uses Git objects at that SHA, never the current checkout. The source of the
installed stock autorun chain is recorded in
[Stage-2 physical evidence](w176-stage2-evidence.md); the operator's prior
Stage-4A experience, including an interrupted attempt and the warning that
USB activity is not a completion indicator, is in
[Stage-4A physical attempts](w176-stage4a-physical-attempts.md).

## Exact USB root inventory

Only these four frozen files belong at the FAT volume root. Sizes and SHA-256
values were calculated from the Git blobs at the frozen implementation SHA.
All four have Git mode 100755. Preserve 0755 and verify effective readability
and executability on the prepared volume. The stock autorun invokes the
root-level gemn_auto.sh; the three other scripts are invoked through /bin/sh,
so their executable bit is not needed by those calls, but the reviewed Git
mode is still 100755. FAT mount policy may determine effective permissions.

| Repository path under tools/w176-stage4b-capability-probe/payload | USB root name | Bytes | SHA-256 | Executable requirement |
| --- | --- | ---: | --- | --- |
| gemn_auto.sh | gemn_auto.sh | 602 | 3cbe48aed6188606d701c774b19251e659ae31dae8942359496cdb78f1235c44 | Yes for stock autorun invocation; preserve 0755 |
| mount_guard.sh | mount_guard.sh | 5,536 | 7401bc34c9e85b0091f5d994169949e5af915cec87034c0bd97e236f83e4ad5c | Invoked by /bin/sh; preserve reviewed 0755 |
| root_mount_guard.sh | root_mount_guard.sh | 1,632 | acfebdbf0dbdbe5135d453a3e41b8829c49fa8510117b35c960bebd9fe154d06 | Invoked by /bin/sh; preserve reviewed 0755 |
| capability_probe.sh | capability_probe.sh | 16,907 | 5281d55b407c33ccb712fd83c358fee6386f4dfc235fdd4ea091dfe782bc8de6 | Invoked by /bin/sh; preserve reviewed 0755 |

The tracked inert example is
tools/w176-stage4b-capability-probe/payload/ARM_STAGE4B_CAPABILITY_PREFLIGHT.example
(77 bytes; SHA-256
58c2df4500e8e630358d0db150ec6ecd4b178d697756253eb37321b41199ed5a).
It is **not** copied to USB. No live marker named
ARM_STAGE4B_CAPABILITY_PREFLIGHT is tracked. The frozen collector expects that
exact live name at the USB root, consumes it after creating the one-shot lock,
and retains the .stage4b-capability.lock directory. An unarmed insertion is
not harmless: after USB validation it can still create the lock before
reporting “not armed”. Never insert a merely prepared USB into the RoadTop.

The host analyser, tests, documentation, review briefs, inert example marker
and any ARM executable are **not** part of the USB payload.

## Target action order and mutation boundary

The stock USB action invokes gemn_auto.sh. That entrypoint canonicalises its
own directory, checks the guard and collector are regular non-symlinks, and
runs mount_guard.sh. It invokes capability_probe.sh only if the guard proves
the effective removable FAT mount equals the script directory. The collector
checks its root, both guard files and the effective USB mount again. It sets a
process file-size limit, then performs the first filesystem mutation:
mkdir .stage4b-capability.lock **on that USB**. It requires a regular,
non-symlink live marker, removes it, creates one fresh result directory,
publishes INCOMPLETE first, performs bounded metadata reads, registers output,
hashes the transaction, checks the final size, and publishes COMPLETE last.

The target-side mutations are confined by the reviewed code to that validated
USB root: lock directory creation; marker removal; result-directory and
subdirectory creation; result, status, inventory, checksum and bounded
temporary-file writes; temporary-file removals and renames; and final COMPLETE
publication. No NVM, MTD, stock file, process, device stream or network write
is intended. The review must still assess guard assumptions and any
validation-to-write race; this document is not physical approval.

## Mac USB identification before any preparation

Prefer a dedicated, freshly prepared FAT USB containing no previous capture.
Do not erase or format a device as part of this handoff. Start a future Mac
`/bin/bash` session and run the preparation blocks in order in that same
shell, after entering the *observed* volume
path, label and disk identifier. The placeholders deliberately fail if not
replaced. If diskutil reports a different removable/writable/FAT identity,
stop; do not relax the checks by guessing. This block reads device metadata
and writes only a temporary plist on the Mac.

~~~bash
set -euo pipefail
REPO='/Users/daniel/Documents/GeminiTop'
FROZEN='465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed'
USB_VOLUME='/Volumes/REPLACE_WITH_USB_LABEL'
EXPECTED_LABEL='REPLACE_WITH_USB_LABEL'
EXPECTED_DEVICE='diskXsY'
case "$USB_VOLUME" in /Volumes/*) ;; *) echo 'STOP: not a volume path' >&2; exit 1 ;; esac
test -d "$USB_VOLUME" && test ! -L "$USB_VOLUME"
test "$(cd -P "$USB_VOLUME" && pwd -P)" = "$USB_VOLUME"
test "$(git -C "$REPO" rev-parse --verify "$FROZEN^{commit}")" = "$FROZEN"
DISK_INFO=$(mktemp -t gt-preflight-disk-info)
diskutil info -plist "$USB_VOLUME" > "$DISK_INFO"
plist_value() { plutil -extract "$1" raw -o - "$DISK_INFO"; }
test "$(plist_value MountPoint)" = "$USB_VOLUME"
test "$(plist_value VolumeName)" = "$EXPECTED_LABEL"
test "$(plist_value DeviceIdentifier)" = "$EXPECTED_DEVICE"
test "$(plist_value Internal)" = false
test "$(plist_value RemovableMedia)" = true
test "$(plist_value BusProtocol)" = USB
test "$(plist_value FilesystemType)" = msdos
test "$(plist_value WritableVolume)" = true
test "$(plist_value WritableMedia)" = true
diskutil info "$USB_VOLUME"
find "$USB_VOLUME" -mindepth 1 -maxdepth 1 -print
rm "$DISK_INFO"
~~~

Stop if the displayed root inventory contains anything unexplained. macOS
housekeeping entries may appear; identify them explicitly rather than
deleting them. A USB that reports itself as fixed/nonremovable on macOS is not
an acceptable substitute merely because it has a FAT label. Recheck identity
immediately before every later USB-writing block.

## Previous result preservation and exact-name cleanup

The preferred path is a different clean USB. If reusing a volume with a
previous result, first preserve it to a private local host location outside
the repository and cloud sync. Do not use this reuse block if there is a live
marker, a numbered result directory, a symlink, an unexplained top-level
object, or an ambiguous previous attempt; choose a new USB and leave the old
one untouched for manual review. The code below backs up the *entire* old USB
root and checks the copy before it offers any deletion. Set BACKUP_PARENT to
an existing private local directory. The operator must inspect the displayed
inventory and type the exact acknowledgement; otherwise nothing is removed.

~~~bash
BACKUP_PARENT='/Users/daniel/REPLACE_WITH_PRIVATE_LOCAL_BACKUP_DIRECTORY'
test -d "$USB_VOLUME" && test ! -L "$USB_VOLUME"
test -d "$BACKUP_PARENT" && test ! -L "$BACKUP_PARENT"
case "$BACKUP_PARENT" in /Volumes/*|"$REPO"|"$REPO"/*) echo 'STOP: unsafe backup location' >&2; exit 1 ;; esac
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract DeviceIdentifier raw -o - -)" = "$EXPECTED_DEVICE"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract VolumeName raw -o - -)" = "$EXPECTED_LABEL"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract MountPoint raw -o - -)" = "$USB_VOLUME"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract Internal raw -o - -)" = false
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract RemovableMedia raw -o - -)" = true
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract BusProtocol raw -o - -)" = USB
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract FilesystemType raw -o - -)" = msdos
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract WritableVolume raw -o - -)" = true
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract WritableMedia raw -o - -)" = true
test ! -e "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
test ! -L "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
NUMBERED=$(find "$USB_VOLUME" -mindepth 1 -maxdepth 1 \
  -name 'stage4b-capability-*' -print)
test -z "$NUMBERED"
if test -e "$USB_VOLUME/stage4b-capability" || test -L "$USB_VOLUME/stage4b-capability"; then
  test -d "$USB_VOLUME/stage4b-capability"
  test ! -L "$USB_VOLUME/stage4b-capability"
  NESTED_LINKS=$(find "$USB_VOLUME/stage4b-capability" -type l -print)
  NESTED_SPECIALS=$(find "$USB_VOLUME/stage4b-capability" ! -type f ! -type d -print)
  test -z "$NESTED_LINKS" && test -z "$NESTED_SPECIALS"
fi
if test -e "$USB_VOLUME/.stage4b-capability.lock" || test -L "$USB_VOLUME/.stage4b-capability.lock"; then
  test -d "$USB_VOLUME/.stage4b-capability.lock"
  test ! -L "$USB_VOLUME/.stage4b-capability.lock"
  LOCK_CONTENT=$(find "$USB_VOLUME/.stage4b-capability.lock" -mindepth 1 -maxdepth 1 -print)
  test -z "$LOCK_CONTENT"
fi
for name in gemn_auto.sh mount_guard.sh root_mount_guard.sh capability_probe.sh; do
  if test -e "$USB_VOLUME/$name" || test -L "$USB_VOLUME/$name"; then
    test -f "$USB_VOLUME/$name" && test ! -L "$USB_VOLUME/$name"
    git -C "$REPO" show "$FROZEN:tools/w176-stage4b-capability-probe/payload/$name" |
      cmp - "$USB_VOLUME/$name"
  fi
done
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OLD_BACKUP="$BACKUP_PARENT/preflight-usb-before-clean-$STAMP"
umask 077
mkdir "$OLD_BACKUP"
rsync -a "$USB_VOLUME/" "$OLD_BACKUP/usb-root/"
diff -rq "$USB_VOLUME/" "$OLD_BACKUP/usb-root/"
find "$USB_VOLUME" -print
printf 'Backup: %s\n' "$OLD_BACKUP"
read -r -p 'After inspecting the listing and backup, type CLEAN_KNOWN_PREFLIGHT: ' ACK
test "$ACK" = CLEAN_KNOWN_PREFLIGHT
if test -d "$USB_VOLUME/stage4b-capability"; then
  rm -R "$USB_VOLUME/stage4b-capability"
fi
if test -d "$USB_VOLUME/.stage4b-capability.lock"; then
  rmdir "$USB_VOLUME/.stage4b-capability.lock"
fi
for name in gemn_auto.sh mount_guard.sh root_mount_guard.sh capability_probe.sh; do
  if test -f "$USB_VOLUME/$name"; then rm "$USB_VOLUME/$name"; fi
done
~~~

The recursive removal above has one exact result-directory target and runs
only after full-root backup, a recursive inventory checked for unexplained
contents, and human acknowledgement. It never uses a
wildcard delete. If the backup, comparison, inventory or any check fails,
stop and preserve the old USB. An unexpected live marker is an abort
condition, not something this cleanup quietly removes.

## Extract and verify the unarmed payload

Run only after the identity block succeeds and the selected USB is clean.
This block extracts each file from the frozen Git object with noclobber,
checks byte-for-byte equality against that object, and checks exact size and
SHA-256. A failed or interrupted extraction leaves an untrusted partial USB;
do not rerun it blindly. Use a new clean USB or return to the reviewed cleanup
path. It deliberately does not copy or create either marker.

~~~bash
test -d "$USB_VOLUME" && test ! -L "$USB_VOLUME"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract DeviceIdentifier raw -o - -)" = "$EXPECTED_DEVICE"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract VolumeName raw -o - -)" = "$EXPECTED_LABEL"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract MountPoint raw -o - -)" = "$USB_VOLUME"
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract Internal raw -o - -)" = false
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract RemovableMedia raw -o - -)" = true
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract BusProtocol raw -o - -)" = USB
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract FilesystemType raw -o - -)" = msdos
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract WritableVolume raw -o - -)" = true
test "$(diskutil info -plist "$USB_VOLUME" |
  plutil -extract WritableMedia raw -o - -)" = true
test ! -e "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
test ! -L "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
test ! -e "$USB_VOLUME/.stage4b-capability.lock"
test ! -L "$USB_VOLUME/.stage4b-capability.lock"
OLD_RESULTS=$(find "$USB_VOLUME" -mindepth 1 -maxdepth 1 \
  -name 'stage4b-capability*' -print)
test -z "$OLD_RESULTS"
find "$USB_VOLUME" -mindepth 1 -maxdepth 1 -print
read -r -p 'After checking all root entries, type ROOT_CLEAN: ' ROOT_ACK
test "$ROOT_ACK" = ROOT_CLEAN
set -C
for name in gemn_auto.sh mount_guard.sh root_mount_guard.sh capability_probe.sh; do
  rel="tools/w176-stage4b-capability-probe/payload/$name"
  dest="$USB_VOLUME/$name"
  test ! -e "$dest" && test ! -L "$dest"
  case "$name" in
    gemn_auto.sh) expected_bytes=602; expected_sha=3cbe48aed6188606d701c774b19251e659ae31dae8942359496cdb78f1235c44 ;;
    mount_guard.sh) expected_bytes=5536; expected_sha=7401bc34c9e85b0091f5d994169949e5af915cec87034c0bd97e236f83e4ad5c ;;
    root_mount_guard.sh) expected_bytes=1632; expected_sha=acfebdbf0dbdbe5135d453a3e41b8829c49fa8510117b35c960bebd9fe154d06 ;;
    capability_probe.sh) expected_bytes=16907; expected_sha=5281d55b407c33ccb712fd83c358fee6386f4dfc235fdd4ea091dfe782bc8de6 ;;
  esac
  git -C "$REPO" show "$FROZEN:$rel" > "$dest"
  chmod 755 "$dest"
  git -C "$REPO" show "$FROZEN:$rel" | cmp - "$dest"
  test "$(stat -f %z "$dest")" = "$expected_bytes"
  test "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$expected_sha"
  test -r "$dest" && test -x "$dest"
done
set +C
test ! -e "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
test ! -L "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"
test ! -e "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT.example"
test ! -e "$USB_VOLUME/.stage4b-capability.lock"
test ! -L "$USB_VOLUME/.stage4b-capability.lock"
FINAL_RESULTS=$(find "$USB_VOLUME" -mindepth 1 -maxdepth 1 \
  -name 'stage4b-capability*' -print)
test -z "$FINAL_RESULTS"
ls -la "$USB_VOLUME"
shasum -a 256 "$USB_VOLUME/gemn_auto.sh" "$USB_VOLUME/mount_guard.sh" \
  "$USB_VOLUME/root_mount_guard.sh" "$USB_VOLUME/capability_probe.sh"
printf '%s\n' 'PREPARED BUT UNARMED — DO NOT INSERT INTO ROADTOP'
~~~

Review the final root listing. No old result, retained lock, live marker or
inert example marker is acceptable on this prepared USB. Mac housekeeping
files must be identified; any other unexplained content is an abort. Safely
eject the USB after inspection. There is no arming action in preparation.

## Future arming and one-attempt operator procedure

**DO NOT RUN UNTIL SEPARATELY AUTHORISED.** The following is the future
one-line arming action, not an instruction to execute now. Before it, repeat
the USB identity and four-file hash/byte checks above, confirm no result or
lock, and obtain an independent physical-handoff GO plus explicit owner
approval. A pre-existing marker is an abort, never a reason to overwrite it.

~~~bash
# DO NOT RUN UNTIL SEPARATELY AUTHORISED
( set -C; printf 'one reviewed metadata capture\n' > "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT" )
~~~

For an approved attempt, park the vehicle safely and let the known RoadTop
finish booting. The engine is **not established as required** for this Linux
metadata read; what matters is stable RoadTop power throughout the attempt.
If stable power cannot be assured without an unsafe idle or battery risk,
defer the test. Do not run in an enclosed space merely to keep the engine on.
Insert the armed USB once. Do not interact with the RoadTop, unplug/reinsert
the USB, or trigger a second attempt while it collects.

Allow **at least 20 minutes** with stable power before considering removal.
This is a conservative operator wait, not a measured completion time:
the bounded collector has no proven physical deadline, and a previous
Stage-4A attempt was observed for about ten minutes. A USB activity LED
going quiet is **not** completion evidence. If power, timing or progress is
uncertain, do not retry; safely retrieve the USB when possible and classify
the result off target. Do not infer success until the returned transaction
passes the host checks below.

## Immediate read-only check after return to Mac

Do this before copying or analysing. The commands below only read the
returned USB and print obvious state; they do not write into its capture.
Use the same explicitly identified USB volume. If the volume identity is
uncertain, stop and preserve it for manual review.

~~~bash
USB_VOLUME='/Volumes/REPLACE_WITH_USB_LABEL'
test -d "$USB_VOLUME" && test ! -L "$USB_VOLUME"
diskutil info "$USB_VOLUME"
for object in ARM_STAGE4B_CAPABILITY_PREFLIGHT .stage4b-capability.lock; do
  if test -e "$USB_VOLUME/$object" || test -L "$USB_VOLUME/$object"; then
    ls -ld "$USB_VOLUME/$object"
  else
    printf '%s: ABSENT\n' "$object"
  fi
done
find "$USB_VOLUME" -mindepth 1 -maxdepth 1 -name 'stage4b-capability*' -print
RESULT="$USB_VOLUME/stage4b-capability"
if test -d "$RESULT" && test ! -L "$RESULT"; then
  for name in STATUS.txt COMPLETE ERRORS.txt OPTIONAL.txt; do
    if test -f "$RESULT/$name" && test ! -L "$RESULT/$name"; then
      ls -l "$RESULT/$name"
      printf '%s:\n' "$name"
      head -n 40 "$RESULT/$name"
    elif test -e "$RESULT/$name" || test -L "$RESULT/$name"; then
      printf '%s: UNEXPECTED OBJECT TYPE\n' "$name"
    else
      printf '%s: ABSENT\n' "$name"
    fi
  done
else
  printf '%s\n' 'Base result directory absent or not a real directory'
fi
~~~

This inspection is not validation. In particular, a displayed COMPLETE,
an empty ERRORS file or a quiet USB LED does not establish a valid transaction.
Do not run the analyser on the original USB. Do not create or remove a marker,
lock or result while inspecting returned evidence.

## Preserve pristine returned evidence on the host

Copy the whole returned USB root, including the exact result, lock and payload,
into a timestamped private local directory outside the repository and cloud
sync. This also preserves multiple or unexpected result directories for manual
review. The source USB is only read by these commands. Keep the original
unchanged and available; macOS itself may create housekeeping metadata, so
record any such observation rather than claiming filesystem inode identity.
Set EVIDENCE_PARENT to an existing private local directory and record the
operator's truthful one-insertion/one-attempt statement.

~~~bash
set -euo pipefail
USB_VOLUME='/Volumes/REPLACE_WITH_USB_LABEL'
EVIDENCE_PARENT='/Users/daniel/REPLACE_WITH_PRIVATE_LOCAL_EVIDENCE_DIRECTORY'
FROZEN='465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed'
test -d "$USB_VOLUME" && test ! -L "$USB_VOLUME"
test -d "$EVIDENCE_PARENT" && test ! -L "$EVIDENCE_PARENT"
case "$EVIDENCE_PARENT" in /Volumes/*|/Users/daniel/Documents/GeminiTop|/Users/daniel/Documents/GeminiTop/*)
  echo 'STOP: evidence destination must be private local host storage' >&2; exit 1 ;;
esac
umask 077
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR="$EVIDENCE_PARENT/stage4b-capability-$STAMP"
mkdir "$EVIDENCE_DIR"
rsync -a "$USB_VOLUME/" "$EVIDENCE_DIR/usb-root/"
if diff -rq "$USB_VOLUME/" "$EVIDENCE_DIR/usb-root/" \
  > "$EVIDENCE_DIR/copy-comparison.txt" 2>&1; then
  COPY_MATCH=YES
else
  COPY_MATCH=NO
fi
RESULT_NAME='stage4b-capability'
if test -d "$EVIDENCE_DIR/usb-root/$RESULT_NAME" &&
   test ! -L "$EVIDENCE_DIR/usb-root/$RESULT_NAME"; then
  ( cd "$EVIDENCE_DIR/usb-root/$RESULT_NAME" &&
    find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort ) \
    > "$EVIDENCE_DIR/copied-transaction.sha256"
  if test -d "$USB_VOLUME/$RESULT_NAME" &&
     test ! -L "$USB_VOLUME/$RESULT_NAME"; then
    ( cd "$USB_VOLUME/$RESULT_NAME" &&
      find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort ) \
      > "$EVIDENCE_DIR/source-transaction.sha256"
    cmp "$EVIDENCE_DIR/source-transaction.sha256" \
        "$EVIDENCE_DIR/copied-transaction.sha256"
  fi
fi
if test -e "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT" ||
   test -L "$USB_VOLUME/ARM_STAGE4B_CAPABILITY_PREFLIGHT"; then
  MARKER_STATE=PRESENT
else
  MARKER_STATE=ABSENT
fi
if test -d "$USB_VOLUME/.stage4b-capability.lock" &&
   test ! -L "$USB_VOLUME/.stage4b-capability.lock"; then
  LOCK_STATE=RETAINED_DIRECTORY
else
  LOCK_STATE=ABSENT_OR_AMBIGUOUS
fi
read -r -p 'Was this exactly one insertion and one attempt? Type YES, NO or UNKNOWN: ' ATTEMPT_STATEMENT
case "$ATTEMPT_STATEMENT" in YES|NO|UNKNOWN) ;; *) ATTEMPT_STATEMENT=UNKNOWN ;; esac
{
  printf 'frozen_implementation=%s\n' "$FROZEN"
  printf 'preserved_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'usb_mount=%s\n' "$USB_VOLUME"
  printf 'usb_label=%s\n' "$(diskutil info -plist "$USB_VOLUME" |
    plutil -extract VolumeName raw -o - -)"
  printf 'marker_state=%s\n' "$MARKER_STATE"
  printf 'lock_state=%s\n' "$LOCK_STATE"
  printf 'operator_one_insertion_one_attempt=%s\n' "$ATTEMPT_STATEMENT"
  printf 'whole_root_copy_comparison=%s\n' "$COPY_MATCH"
} > "$EVIDENCE_DIR/provenance.txt"
printf 'Preserved host directory: %s\n' "$EVIDENCE_DIR"
test "$COPY_MATCH" = YES
~~~

If comparison or copying fails, keep both the source and partial host copy;
classify MANUAL REVIEW REQUIRED. Do not clean or retry the USB. Hashes are
host-side evidence of the copied regular-file contents, not proof of the
original FAT inode types. The frozen analyser below checks the copied
transaction's own checksums, inventory and object types.

## Run only the frozen analyser on the host copy

Do this **after** preservation and copy comparison, never on the original
USB. The exact frozen analyser is 28,530 bytes with SHA-256
4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566.
Extract it to a temporary host directory from Git, verify its bytes, and
write stdout, stderr, exit status and the optional JSON outside the pristine
copied transaction. Replace EVIDENCE_DIR with the path printed by the
preservation block if running in a new shell.

~~~bash
set -euo pipefail
REPO='/Users/daniel/Documents/GeminiTop'
FROZEN='465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed'
EVIDENCE_DIR='/Users/daniel/REPLACE_WITH_PRESERVED_EVIDENCE_DIRECTORY'
test -d "$EVIDENCE_DIR/usb-root/stage4b-capability"
test ! -L "$EVIDENCE_DIR/usb-root/stage4b-capability"
grep -Fqx 'whole_root_copy_comparison=YES' "$EVIDENCE_DIR/provenance.txt"
ANALYSER_TMP=$(mktemp -d /private/tmp/gt-stage4b-analyser.XXXXXX)
ANALYSER_REL='tools/w176-stage4b-capability-probe/analyze.py'
git -C "$REPO" show "$FROZEN:$ANALYSER_REL" > "$ANALYSER_TMP/analyze.py"
git -C "$REPO" show "$FROZEN:$ANALYSER_REL" |
  cmp - "$ANALYSER_TMP/analyze.py"
test "$(stat -f %z "$ANALYSER_TMP/analyze.py")" = 28530
test "$(shasum -a 256 "$ANALYSER_TMP/analyze.py" | awk '{print $1}')" = \
  4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566
shasum -a 256 "$ANALYSER_TMP/analyze.py" > "$EVIDENCE_DIR/analyser.sha256"
if python3 -B "$ANALYSER_TMP/analyze.py" \
  "$EVIDENCE_DIR/usb-root/stage4b-capability" \
  --json "$EVIDENCE_DIR/analysis.json" \
  > "$EVIDENCE_DIR/analysis.stdout" 2> "$EVIDENCE_DIR/analysis.stderr"; then
  ANALYSER_EXIT=0
else
  ANALYSER_EXIT=$?
fi
printf '%s\n' "$ANALYSER_EXIT" > "$EVIDENCE_DIR/analysis.exit_status"
printf 'Analyser exit status: %s\n' "$ANALYSER_EXIT"
~~~

The analyser writes JSON only if it accepts the capture. A nonzero exit,
missing JSON or discrepancy is not a reason to edit the pristine copy or
rerun the physical attempt. Keep the extracted analyser and all output
outside the copied transaction. Its result must continue to say
SEALED_RUNTIME_EXECUTION=NOT_TESTED and EXECUTION_HIGH=OPEN.

## Classify the returned physical transaction

Apply this precedence after preservation. **MANUAL REVIEW REQUIRED** comes
first for uncertain USB identity, unexpected objects, symlinks, ambiguous
marker/lock state, multiple result directories, copy mismatch, analyser
discrepancy, or anything not explicitly covered below. Preserve all material
and do not retry.

Otherwise **INCOMPLETE** includes absent COMPLETE, STATUS not complete,
mandatory_failures other than zero, nonempty ERRORS, interrupted output, or
an analyser rejection of structure/checksums. A valid capture must never be
inferred from elapsed time, LED activity, or a visible COMPLETE alone.

Only **VALID COMPLETE CAPTURE** requires all of the following: exactly one
result directory from the one-attempt procedure; consumed marker absent;
retained real one-shot lock directory; STATUS.txt states status=COMPLETE and
mandatory_failures=0; COMPLETE is a regular, non-symlink file; ERRORS.txt is
empty; the copied transaction matches the returned source; and the
frozen host analyser exits zero with CAPTURE=COMPLETE and valid checksums and
inventory. This is metadata evidence only, not Stage-4B residency approval.

A valid physical metadata capture may establish kernel identity, installed
mountinfo and MTD/sysfs presentation, libc/loader provenance, static wrapper
exports, and feature-support metadata. It cannot establish successful memfd
creation, sealing, mutation rejection or descriptor execution. The required
evidence boundary remains SEALED_RUNTIME_EXECUTION=NOT_TESTED and
EXECUTION_HIGH=OPEN.

## Stop conditions

Do not arm or run if the frozen SHA or any payload hash/size disagrees, the
USB identity/FAT/removable/writable check fails, permissions are uncertain,
unexpected files or a live marker exist, an old result/lock is not fully
understood, a previous backup is unverified, the current target no longer
appears to be the owner-confirmed RoadTop, or the reviewed implementation
differs from the extracted Git objects. Stop on branch/commit confusion,
insufficient stable power, unexpected RoadTop behavior, or any failed command.
Do not substitute the moving branch tip, broaden the capture, alter target
state or automatically retry after an uncertain attempt.
