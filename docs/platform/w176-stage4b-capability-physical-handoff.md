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

## Mac-only effective-storage guard

The physical attempt requires a dedicated clean USB. No old result, lock,
live marker, old payload, or unexplained top-level object may be present. If
the candidate is dirty: STOP — USE ANOTHER USB. This handoff does not erase,
format, back up, clean, or reuse removable media.

The following function is host-only; paste it into a future Mac /bin/bash
session before preparation, and again on return if using a new shell. It makes
no writes. It resolves the complete existing host-parent path, including
symlinked ancestors. macOS diskutil info does not reliably accept an arbitrary
directory, and APFS System/Data firmlinks can report the same st_dev. The
function instead obtains the path's effective filesystem from df -P and
cross-checks its device and mount against diskutil info -plist. Ambiguous
output fails closed. The parent must resolve to internal, nonremovable,
writable storage on a different filesystem from USB, outside the repository
and common cloud-sync
locations. The operator must separately confirm that the chosen private
directory is not cloud-synchronised; no path test proves the absence of every
sync client.

~~~bash
host_storage_guard() {
python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import pathlib
import plistlib
import subprocess
import sys

def stop(reason):
    raise SystemExit("STOP: " + reason)

def plist(*args):
    data = subprocess.check_output(("diskutil", *args),
                                   stderr=subprocess.DEVNULL)
    result = plistlib.loads(data)
    if result.get("Error"):
        stop("diskutil error")
    return result

def backing_volume(path):
    lines = subprocess.check_output(("df", "-P", str(path)),
                                    text=True, stderr=subprocess.DEVNULL).splitlines()
    if len(lines) != 2:
        stop("ambiguous effective-filesystem report")
    fields = lines[1].split(None, 5)
    if len(fields) != 6 or not fields[0].startswith("/dev/"):
        stop("effective filesystem has no local block device")
    identifier = os.path.basename(fields[0])
    mount = fields[5]
    info = plist("info", "-plist", identifier)
    if info.get("DeviceIdentifier") != identifier or \
       os.path.realpath(info.get("MountPoint", "")) != os.path.realpath(mount):
        stop("backing-volume information changed")
    device = os.stat(path).st_dev
    if os.stat(mount).st_dev != device:
        stop("backing-volume device changed")
    return info, device

def check_host_destination(parent, usb, repo, host_info, host_dev, usb_dev,
                           usb_identifier):
    if os.path.commonpath((str(parent), str(usb))) == str(usb) or \
       os.path.commonpath((str(parent), str(repo))) == str(repo):
        stop("host parent resolves onto USB or into repository")
    parts = set(parent.parts)
    if parts & {"CloudStorage", "Mobile Documents", "Dropbox", "OneDrive",
                "Google Drive"}:
        stop("known cloud-sync path")
    home = pathlib.Path.home()
    if any(os.path.commonpath((str(parent), str(home / name))) ==
           str(home / name) for name in ("Documents", "Desktop")):
        stop("potentially cloud-synchronised home folder")
    if host_dev == usb_dev or \
       host_info.get("DeviceIdentifier") == usb_identifier or \
       host_info.get("Internal") is not True or \
       host_info.get("RemovableMedia") is not False or \
       host_info.get("WritableVolume") is not True:
        stop("host parent is not separate internal writable storage")

usb_arg, parent_arg, repo_arg = sys.argv[1:]
usb = pathlib.Path(usb_arg).resolve(strict=True)
parent = pathlib.Path(parent_arg).resolve(strict=True)
repo = pathlib.Path(repo_arg).resolve(strict=True)
if not usb.is_dir() or not parent.is_dir() or not repo.is_dir():
    stop("required directory absent")
if os.path.realpath(os.path.abspath(usb_arg)) != os.path.abspath(usb_arg):
    stop("USB path has a symlinked component")
if os.path.commonpath((str(usb), "/Volumes")) != "/Volumes" or \
   str(usb) == "/Volumes" or not os.path.ismount(usb):
    stop("USB path is not a volume root")
usb_info, usb_dev = backing_volume(usb)
if os.path.realpath(usb_info.get("MountPoint", "")) != str(usb):
    stop("USB effective mount mismatch")
if usb_info.get("Internal") is not False or \
   usb_info.get("RemovableMedia") is not True or \
   usb_info.get("BusProtocol") != "USB" or \
   usb_info.get("FilesystemType") != "msdos" or \
   usb_info.get("WritableVolume") is not True or \
   usb_info.get("WritableMedia") is not True:
    stop("USB is not writable removable USB/FAT")
uuid = usb_info.get("VolumeUUID")
size = usb_info.get("Size")
label = usb_info.get("VolumeName")
if not isinstance(uuid, str) or not uuid.strip() or \
   not isinstance(size, int) or isinstance(size, bool) or size <= 0 or \
   not isinstance(label, str) or not label.strip():
    stop("USB lacks required persistent identity fields")
host_info, host_dev = backing_volume(parent)
check_host_destination(parent, usb, repo, host_info, host_dev, usb_dev,
                       usb_info["DeviceIdentifier"])
print(json.dumps({
    "host": {"canonical_parent": str(parent), "st_dev": host_dev,
             "backing_mount": host_info["MountPoint"],
             "backing_device_session": host_info["DeviceIdentifier"]},
    "usb": {"stable": {"VolumeUUID": uuid.upper(), "VolumeName": label,
                       "FilesystemType": "msdos", "Size": size,
                       "BusProtocol": "USB", "Internal": False,
                       "RemovableMedia": True},
            "session": {"DeviceIdentifier": usb_info["DeviceIdentifier"],
                        "DeviceNode": usb_info.get("DeviceNode"),
                        "MountPoint": str(usb), "st_dev": usb_dev}}
}, sort_keys=True))
PY
}
~~~

VolumeUUID is the required persistent volume identifier when macOS provides
one; if absent, stop rather than invent a fallback. Compare it on return
alongside label, filesystem, capacity, USB bus, and removable flags. This
corroborates volume identity but does not cryptographically authenticate a
physical stick. DeviceIdentifier, DeviceNode, MountPoint and st_dev are
session-local: record them, but do not require equality across eject/reinsert.
Within one mounted preparation session, the full guard result must remain
equal before any USB write. [Apple documents a volume UUID as persistent when
available](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeuuidstring);
the requirement here to compare it with the other fields is a conservative
procedure choice, not proof of physical-device authenticity.

## Dedicated clean USB and pre-arm host record

Start /bin/bash and run the guard definition above. Set the observed USB
mount and a pre-existing private host parent. Do not create the host parent
on USB, in this repository, or in a cloud-synchronised location. Do not erase
or format a USB in this procedure. The following block reads the USB and
creates only a timestamped host record directory after validating its backing
storage. The accepted housekeeping names and types are exact; any other
object, including old preflight state or a symlink, causes STOP. Do not delete
anything. Record the printed PREARM_DIR for the return phase.

~~~bash
set -euo pipefail
REPO='/Users/daniel/Documents/GeminiTop'
FROZEN='465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed'
USB_VOLUME='/Volumes/REPLACE_WITH_OBSERVED_USB_LABEL'
EVIDENCE_PARENT='/Users/daniel/REPLACE_WITH_PRIVATE_LOCAL_PARENT'
test "$(git -C "$REPO" rev-parse --verify "$FROZEN^{commit}")" = "$FROZEN"
PREP_GUARD=$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")
printf '%s\n' "$PREP_GUARD"
read -r -p 'Confirm this host parent is private and NOT cloud synced; type LOCAL_NOT_SYNCED: ' LOCAL_ACK
test "$LOCAL_ACK" = LOCAL_NOT_SYNCED
CLEAN_ROOT=$(python3 - "$USB_VOLUME" <<'PY'
import json, os, stat, sys
root = sys.argv[1]
allowed = {".DS_Store": "file", ".metadata_never_index": "file",
           ".Spotlight-V100": "directory", ".Trashes": "directory",
           ".fseventsd": "directory"}
found = {}
for entry in os.scandir(root):
    mode = entry.stat(follow_symlinks=False).st_mode
    kind = ("file" if stat.S_ISREG(mode) else
            "directory" if stat.S_ISDIR(mode) else "unexpected")
    if entry.name not in allowed or kind != allowed[entry.name]:
        raise SystemExit("STOP: dirty USB; use another clean USB: " + entry.name)
    found[entry.name] = kind
print(json.dumps(found, sort_keys=True))
PY
)
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$PREP_GUARD"
SAFE_PARENT=$(printf '%s' "$PREP_GUARD" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["host"]["canonical_parent"])')
umask 077
PREARM_DIR=$(mktemp -d "$SAFE_PARENT/stage4b-prearm.XXXXXX")
python3 - "$PREARM_DIR" "$SAFE_PARENT" <<'PY'
import os, pathlib, sys
child = pathlib.Path(sys.argv[1]).resolve(strict=True)
parent = pathlib.Path(sys.argv[2]).resolve(strict=True)
if child.parent != parent or child.stat().st_dev != parent.stat().st_dev:
    raise SystemExit("STOP: pre-arm host directory escaped validated parent")
PY
printf '%s\n' "$CLEAN_ROOT" > "$PREARM_DIR/initial-clean-root.json"
printf '%s\n' "$PREP_GUARD" > "$PREARM_DIR/preparation-guard.json"
printf 'PREARM_DIR=%s\n' "$PREARM_DIR"
~~~

## Extract and verify the unarmed payload

Run this only after the clean-volume gate above succeeds, in the same shell.
It extracts directly from frozen Git blobs with noclobber. A failed or
interrupted extraction leaves a dirty USB: STOP — USE ANOTHER USB. There is no
cleanup or retry path. The final pre-arm manifest is written only to the
validated internal host directory, never to USB. No marker is copied or
created.

~~~bash
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$PREP_GUARD"
python3 - "$USB_VOLUME" "$CLEAN_ROOT" <<'PY'
import json, os, stat, sys
expected = json.loads(sys.argv[2])
actual = {}
for entry in os.scandir(sys.argv[1]):
    mode = entry.stat(follow_symlinks=False).st_mode
    actual[entry.name] = ("file" if stat.S_ISREG(mode) else
                          "directory" if stat.S_ISDIR(mode) else "unexpected")
if actual != expected:
    raise SystemExit("STOP: USB root changed before extraction")
PY
set -C
for name in gemn_auto.sh mount_guard.sh root_mount_guard.sh capability_probe.sh; do
  rel="tools/w176-stage4b-capability-probe/payload/$name"
  dest="$USB_VOLUME/$name"
  test ! -e "$dest" && test ! -L "$dest"
  git -C "$REPO" show "$FROZEN:$rel" > "$dest"
  chmod 755 "$dest"
  git -C "$REPO" show "$FROZEN:$rel" | cmp - "$dest"
  test -r "$dest" && test -x "$dest"
done
set +C
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$PREP_GUARD"
python3 - "$REPO" "$FROZEN" "$USB_VOLUME" "$PREARM_DIR" \
  "$CLEAN_ROOT" "$PREP_GUARD" <<'PY'
import datetime, hashlib, json, os, pathlib, stat, subprocess, sys
repo, frozen, root, record_dir, clean_json, guard_json = sys.argv[1:]
names = ("gemn_auto.sh", "mount_guard.sh", "root_mount_guard.sh",
         "capability_probe.sh")
initial = json.loads(clean_json)
guard = json.loads(guard_json)
parent = pathlib.Path(guard["host"]["canonical_parent"])
record = pathlib.Path(record_dir).resolve(strict=True)
if record.parent != parent or record.stat().st_dev != parent.stat().st_dev:
    raise SystemExit("STOP: pre-arm record is not on validated host storage")
actual_root = {}
for entry in os.scandir(root):
    mode = entry.stat(follow_symlinks=False).st_mode
    actual_root[entry.name] = ("file" if stat.S_ISREG(mode) else
                               "directory" if stat.S_ISDIR(mode) else "unexpected")
expected_root = dict(initial)
expected_root.update({name: "file" for name in names})
if actual_root != expected_root:
    raise SystemExit("STOP: unexpected USB root object after extraction")
payload = {}
for name in names:
    rel = "tools/w176-stage4b-capability-probe/payload/" + name
    frozen_bytes = subprocess.check_output(
        ("git", "-C", repo, "show", frozen + ":" + rel))
    path = os.path.join(root, name)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise SystemExit("STOP: returned payload is not regular: " + name)
        actual = stream.read()
    if actual != frozen_bytes:
        raise SystemExit("STOP: payload differs from frozen Git blob: " + name)
    payload[name] = {"bytes": len(frozen_bytes),
                     "sha256": hashlib.sha256(frozen_bytes).hexdigest()}
manifest = {
    "schema": 1, "frozen_implementation": frozen,
    "prepared_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "clean_usb_initial_root": initial, "usb": guard["usb"],
    "payload": payload, "arming_marker_created": False
}
with open(record / "prearm.json", "x", encoding="utf-8") as output:
    json.dump(manifest, output, sort_keys=True, indent=2)
    output.write("\n")
print(json.dumps(payload, sort_keys=True, indent=2))
print("PREPARED BUT UNARMED — DO NOT INSERT INTO ROADTOP")
PY
~~~

Review the displayed inventory and safely eject the USB. The pre-arm record
contains the USB stable and session-local identity, frozen SHA, exact
filenames, size/hash values computed from Git, preparation UTC time, and
initial clean-root state. Keep PREARM_DIR on validated internal host storage
and record its path for return. The inert example marker, host analyser,
tests and review documents are not on USB.

## Reusable pre-arm identity and frozen-payload gate

Paste this host-only function into the same shell as the storage guard; paste
both definitions again if the shell is restarted. It makes no writes. It
compares only the documented stable USB fields across eject/reinsert, then
requires every payload to be a regular non-symlink file whose size, SHA-256,
and bytes match both the pre-arm manifest and the exact frozen Git blob. A
failure is MANUAL REVIEW REQUIRED on return, not permission to repair the USB.

~~~bash
frozen_provenance_gate() {
python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib, json, os, pathlib, stat, subprocess, sys
prearm_path, guard_text, repo, frozen, root = sys.argv[1:]
guard = json.loads(guard_text)
host = pathlib.Path(guard["host"]["canonical_parent"])
record = pathlib.Path(prearm_path).resolve(strict=True)
if record.name != "prearm.json" or record.parent.parent != host or \
   record.stat().st_dev != host.stat().st_dev or \
   not stat.S_ISREG(os.lstat(prearm_path).st_mode):
    raise SystemExit("MANUAL REVIEW: pre-arm record is not on validated host storage")
with open(prearm_path, "r", encoding="utf-8") as stream:
    prearm = json.load(stream)
if prearm.get("schema") != 1 or prearm.get("frozen_implementation") != frozen:
    raise SystemExit("MANUAL REVIEW: wrong pre-arm record or frozen SHA")
if prearm.get("usb", {}).get("stable") != guard["usb"]["stable"]:
    raise SystemExit("MANUAL REVIEW: returned stable USB identity differs")
names = ("gemn_auto.sh", "mount_guard.sh", "root_mount_guard.sh",
         "capability_probe.sh")
if set(prearm.get("payload", {})) != set(names):
    raise SystemExit("MANUAL REVIEW: pre-arm payload inventory differs")
observed = {}
for name in names:
    rel = "tools/w176-stage4b-capability-probe/payload/" + name
    frozen_bytes = subprocess.check_output(
        ("git", "-C", repo, "show", frozen + ":" + rel))
    path = os.path.join(root, name)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if not stat.S_ISREG(meta.st_mode) or meta.st_size != len(frozen_bytes):
            raise SystemExit("MANUAL REVIEW: payload type/size mismatch: " + name)
        data = stream.read(len(frozen_bytes) + 1)
    item = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    expected = {"bytes": len(frozen_bytes),
                "sha256": hashlib.sha256(frozen_bytes).hexdigest()}
    if data != frozen_bytes or item != expected or item != prearm["payload"][name]:
        raise SystemExit("MANUAL REVIEW: frozen payload mismatch: " + name)
    observed[name] = item
print(json.dumps({"stable_identity": guard["usb"]["stable"],
                  "payload": observed}, sort_keys=True))
PY
}
~~~

## Future arming and one-attempt operator procedure

**DO NOT RUN UNTIL SEPARATELY AUTHORISED.** The following is the future
arming gate and final one-line arming action, not an instruction to execute
now. Before the final command, run
host_storage_guard and frozen_provenance_gate against the preserved pre-arm
record, confirm no result or lock, and obtain an independent physical-handoff
GO plus explicit owner approval. A pre-existing marker is an abort, never a
reason to overwrite it. A changed session-local device identifier alone does
not negate an otherwise matching stable identity after reinsertion.

~~~bash
# DO NOT RUN UNTIL SEPARATELY AUTHORISED
CURRENT_GUARD=$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")
frozen_provenance_gate "$PREARM_DIR/prearm.json" "$CURRENT_GUARD" \
  "$REPO" "$FROZEN" "$USB_VOLUME"
python3 - "$USB_VOLUME" <<'PY'
import os, sys
names = set(os.listdir(sys.argv[1]))
for forbidden in ("ARM_STAGE4B_CAPABILITY_PREFLIGHT",
                  ".stage4b-capability.lock", "stage4b-capability"):
    if forbidden in names:
        raise SystemExit("STOP: marker, lock or result already exists")
if any(name.startswith("stage4b-capability-") for name in names):
    raise SystemExit("STOP: numbered old result exists")
PY
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

## Preserve pristine returned evidence on proven internal host storage

After the read-only inspection, paste both host-only function definitions again if
the shell was restarted. Enter the returned USB mount, the same validated host
parent and the PREARM_DIR printed at preparation. Before copying, the block
below compares the returned stable USB identity with pre-arm identity. The
session-local BSD disk identifier may change and is not compared. If the
stable identifier is missing or differs: MANUAL REVIEW REQUIRED; stop and
leave the original USB untouched. The operator answers the one-attempt
question truthfully. NO or UNKNOWN may still be preserved, but can never be
VALID COMPLETE.

The host parent is canonicalised and proven internal/nonremovable and on a
different effective filesystem from USB before the new evidence directory is
created, then checked again immediately before copy. The only source of the
rsync is USB; it is not a destination. -x refuses traversal into a different
filesystem beneath the USB; the complete-root verifier below detects any
omission instead of silently accepting an incomplete copy.

~~~bash
set -euo pipefail
REPO='/Users/daniel/Documents/GeminiTop'
FROZEN='465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed'
USB_VOLUME='/Volumes/REPLACE_WITH_RETURNED_USB_LABEL'
EVIDENCE_PARENT='/Users/daniel/REPLACE_WITH_PRIVATE_LOCAL_PARENT'
PREARM_DIR='/Users/daniel/REPLACE_WITH_RECORDED_PREARM_DIR'
RETURN_GUARD=$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")
python3 - "$PREARM_DIR/prearm.json" "$RETURN_GUARD" "$FROZEN" <<'PY'
import json, os, pathlib, stat, sys
path, guard_text, frozen = sys.argv[1:]
guard = json.loads(guard_text)
host = pathlib.Path(guard["host"]["canonical_parent"])
record = pathlib.Path(path).resolve(strict=True)
if record.name != "prearm.json" or record.parent.parent != host or \
   record.stat().st_dev != host.stat().st_dev or \
   not stat.S_ISREG(os.lstat(path).st_mode):
    raise SystemExit("MANUAL REVIEW: pre-arm record not on validated host")
with open(path, encoding="utf-8") as stream:
    prearm = json.load(stream)
if prearm.get("schema") != 1 or prearm.get("frozen_implementation") != frozen or \
   prearm.get("usb", {}).get("stable") != guard["usb"]["stable"]:
    raise SystemExit("MANUAL REVIEW: returned USB stable identity mismatch")
print("PRE-ARM / RETURN STABLE USB IDENTITY: MATCH")
PY
read -r -p 'Was this exactly one insertion and one physical probe attempt? YES, NO or UNKNOWN: ' ATTEMPT_STATEMENT
case "$ATTEMPT_STATEMENT" in YES|NO|UNKNOWN) ;; *) ATTEMPT_STATEMENT=UNKNOWN ;; esac
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$RETURN_GUARD"
SAFE_PARENT=$(printf '%s' "$RETURN_GUARD" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["host"]["canonical_parent"])')
umask 077
EVIDENCE_DIR=$(mktemp -d "$SAFE_PARENT/stage4b-return.XXXXXX")
python3 - "$EVIDENCE_DIR" "$SAFE_PARENT" <<'PY'
import pathlib, sys
child = pathlib.Path(sys.argv[1]).resolve(strict=True)
parent = pathlib.Path(sys.argv[2]).resolve(strict=True)
if child.parent != parent or child.stat().st_dev != parent.stat().st_dev:
    raise SystemExit("MANUAL REVIEW: evidence directory escaped validated parent")
PY
printf '%s\n' "$RETURN_GUARD" > "$EVIDENCE_DIR/return-guard.json"
cp "$PREARM_DIR/prearm.json" "$EVIDENCE_DIR/prearm.json"
printf 'operator_one_insertion_one_attempt=%s\n' "$ATTEMPT_STATEMENT" \
  > "$EVIDENCE_DIR/operator-provenance.txt"
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$RETURN_GUARD"
python3 - "$EVIDENCE_DIR" "$SAFE_PARENT" "$USB_VOLUME" <<'PY'
import pathlib, sys
child = pathlib.Path(sys.argv[1]).resolve(strict=True)
parent = pathlib.Path(sys.argv[2]).resolve(strict=True)
usb = pathlib.Path(sys.argv[3]).resolve(strict=True)
if child.parent != parent or child.stat().st_dev != parent.stat().st_dev or \
   child.stat().st_dev == usb.stat().st_dev:
    raise SystemExit("MANUAL REVIEW: destination identity changed before copy")
PY
rsync -a -x "$USB_VOLUME/" "$EVIDENCE_DIR/usb-root/"
printf 'Preserved host directory: %s\n' "$EVIDENCE_DIR"
~~~

If any validation or copy fails, keep the original USB and any partial host
copy untouched. Classify MANUAL REVIEW REQUIRED. Do not clean, reinsert, or
retry the physical probe. macOS itself may create housekeeping metadata;
record that observation rather than claiming original FAT inode identity.

## Verify the complete copy and frozen returned payload

The next block only reads the returned USB and copied root; all reports are
written outside the pristine copied transaction. It rejects symlinks, special
files, nested mounts, unexpected root objects, overlarge or changing files,
and byte-level copy mismatch. The limits below are conservative host-analysis
limits; exceeding them means MANUAL REVIEW, not that the probe failed. It
also rehashes all four returned scripts against exact frozen Git blobs using
the reusable provenance gate. A mismatch is MANUAL REVIEW REQUIRED.

~~~bash
set -euo pipefail
test "$(host_storage_guard "$USB_VOLUME" "$EVIDENCE_PARENT" "$REPO")" = "$RETURN_GUARD"
if frozen_provenance_gate "$PREARM_DIR/prearm.json" "$RETURN_GUARD" \
   "$REPO" "$FROZEN" "$USB_VOLUME" \
   > "$EVIDENCE_DIR/returned-payload.json" \
   2> "$EVIDENCE_DIR/returned-payload.error"; then
  PAYLOAD_GATE=YES
else
  PAYLOAD_GATE=NO
fi
if frozen_provenance_gate "$PREARM_DIR/prearm.json" "$RETURN_GUARD" \
   "$REPO" "$FROZEN" "$EVIDENCE_DIR/usb-root" \
   > "$EVIDENCE_DIR/copied-payload.json" \
   2> "$EVIDENCE_DIR/copied-payload.error"; then
  COPIED_PAYLOAD_GATE=YES
else
  COPIED_PAYLOAD_GATE=NO
fi
printf 'returned_payload_match=%s\ncopied_payload_match=%s\n' \
  "$PAYLOAD_GATE" "$COPIED_PAYLOAD_GATE" > "$EVIDENCE_DIR/payload-gates.txt"
python3 - "$USB_VOLUME" "$EVIDENCE_DIR/usb-root" \
  "$EVIDENCE_DIR" "$PREARM_DIR/prearm.json" <<'PY'
import hashlib, json, os, stat, sys
source, copied, evidence, prearm_path = sys.argv[1:]
with open(prearm_path, encoding="utf-8") as stream:
    prearm = json.load(stream)
allowed = set(prearm["clean_usb_initial_root"]) | set(prearm["payload"]) | {
    "ARM_STAGE4B_CAPABILITY_PREFLIGHT", ".stage4b-capability.lock",
    "stage4b-capability"}
report = {"status": "MANUAL_REVIEW_REQUIRED"}
def snapshot(root):
    device = os.stat(root).st_dev
    stack = [(root, "")]
    objects = {}
    total = 0
    while stack:
        directory, prefix = stack.pop()
        for entry in os.scandir(directory):
            name = prefix + entry.name
            meta = entry.stat(follow_symlinks=False)
            if meta.st_dev != device or stat.S_ISLNK(meta.st_mode):
                raise ValueError("nested mount or symlink: " + name)
            if len(objects) >= 10000:
                raise ValueError("too many objects for bounded host comparison")
            if stat.S_ISDIR(meta.st_mode):
                objects[name] = {"type": "directory"}
                stack.append((entry.path, name + "/"))
            elif stat.S_ISREG(meta.st_mode):
                total += meta.st_size
                if total > 64 * 1024 * 1024:
                    raise ValueError("too many bytes for bounded host comparison")
                fd = os.open(entry.path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as stream:
                    before = os.fstat(stream.fileno())
                    if not stat.S_ISREG(before.st_mode) or \
                       before.st_dev != device or before.st_ino != meta.st_ino:
                        raise ValueError("changed source file: " + name)
                    data = stream.read(meta.st_size + 1)
                    after = os.fstat(stream.fileno())
                if len(data) != meta.st_size or before.st_size != after.st_size or \
                   before.st_mtime_ns != after.st_mtime_ns or \
                   before.st_ctime_ns != after.st_ctime_ns:
                    raise ValueError("growing or truncated file: " + name)
                objects[name] = {"type": "file", "bytes": len(data),
                                 "sha256": hashlib.sha256(data).hexdigest()}
            else:
                raise ValueError("special object: " + name)
    return objects
try:
    if os.stat(source).st_dev == os.stat(copied).st_dev:
        raise ValueError("source and host copy share a filesystem")
    source_root = set(os.listdir(source))
    if not source_root <= allowed:
        raise ValueError("unexpected returned USB root object")
    src = snapshot(source)
    dst = snapshot(copied)
    if src != dst:
        raise ValueError("whole-root copy differs from source")
    report = {"status": "MATCH", "objects": len(src),
              "transaction_files": sorted(
                  name for name in dst
                  if name.startswith("stage4b-capability/") and
                     dst[name]["type"] == "file")}
    with open(os.path.join(evidence, "copied-transaction.sha256"), "x") as out:
        for name in report["transaction_files"]:
            out.write(dst[name]["sha256"] + "  " + name + "\n")
except (OSError, ValueError) as exc:
    report["error"] = str(exc)
with open(os.path.join(evidence, "copy-comparison.json"), "x") as out:
    json.dump(report, out, sort_keys=True, indent=2)
    out.write("\n")
if report["status"] != "MATCH":
    raise SystemExit("MANUAL REVIEW: whole-root comparison did not match")
PY
grep -Fqx 'returned_payload_match=YES' "$EVIDENCE_DIR/payload-gates.txt"
grep -Fqx 'copied_payload_match=YES' "$EVIDENCE_DIR/payload-gates.txt"
~~~

The returned-payload and copied-payload JSON reports include exact stable
identity and the recomputed size and hash of each script. The host comparer
does not interpret the probe transaction; the frozen analyser below does.

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
python3 - "$EVIDENCE_DIR" <<'PY'
import json, pathlib, sys
base = pathlib.Path(sys.argv[1])
with open(base / "copy-comparison.json", encoding="utf-8") as stream:
    comparison = json.load(stream)
if comparison.get("status") != "MATCH":
    raise SystemExit("MANUAL REVIEW: whole-root copy not verified")
if (base / "payload-gates.txt").read_text().splitlines() != [
    "returned_payload_match=YES", "copied_payload_match=YES"]:
    raise SystemExit("MANUAL REVIEW: frozen payload mismatch")
PY
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

Apply this precedence after preservation. MANUAL REVIEW REQUIRED comes first
for missing/ambiguous pre-arm identity, return mismatch, unsafe host backing,
source/copy device equality, missing/changed/symlinked payload, operator
statement other than exact YES, unexpected objects, multiple results,
ambiguous marker/lock, copy mismatch, analyser discrepancy, or any
unclassified condition. Preserve everything and do not retry.

Only if provenance is sound, INCOMPLETE describes a known incomplete probe
transaction: absent COMPLETE, incomplete STATUS, nonzero mandatory failures,
nonempty ERRORS, interruption, or a structural/checksum rejection by the
frozen analyser. An analyser exit 2 with INVALID CAPTURE is not evidence of a
valid capture.

VALID COMPLETE CAPTURE requires **all** provenance gates above, exactly one
base result directory, absent consumed marker, real retained lock, STATUS
status=COMPLETE with mandatory_failures=0, regular non-symlink COMPLETE,
empty ERRORS, matching whole-root copy, frozen analyser exit zero with valid
inventory/checksums and CAPTURE=COMPLETE, plus its unchanged evidence boundary.
A visible COMPLETE or quiet LED alone is never sufficient.

The following host-only final gate records the category outside the copied
transaction. Run it after the analyser when a candidate result exists; if
the transaction is obviously incomplete, it may still record INCOMPLETE
without analyser output. Any missing provenance input results in MANUAL
REVIEW REQUIRED. It never writes to the USB.

~~~bash
python3 - "$EVIDENCE_DIR" "$FROZEN" <<'PY'
import json, os, pathlib, stat, sys
base = pathlib.Path(sys.argv[1])
frozen = sys.argv[2]
category = "MANUAL REVIEW REQUIRED"
reason = "unclassified or unavailable provenance"
try:
    prearm = json.loads((base / "prearm.json").read_text())
    returned = json.loads((base / "return-guard.json").read_text())
    comparison = json.loads((base / "copy-comparison.json").read_text())
    attempts = (base / "operator-provenance.txt").read_text().splitlines()
    payload_gates = (base / "payload-gates.txt").read_text().splitlines()
    root = base / "usb-root"
    if prearm.get("schema") != 1 or \
       prearm.get("frozen_implementation") != frozen or \
       prearm.get("usb", {}).get("stable") != returned["usb"]["stable"]:
        raise ValueError("pre-arm/return identity mismatch")
    if attempts != ["operator_one_insertion_one_attempt=YES"]:
        raise ValueError("operator did not attest exactly one insertion/attempt")
    if payload_gates != ["returned_payload_match=YES",
                         "copied_payload_match=YES"]:
        raise ValueError("returned or copied frozen payload mismatch")
    for name in ("returned-payload.json", "copied-payload.json"):
        report = json.loads((base / name).read_text())
        if report.get("stable_identity") != prearm["usb"]["stable"] or \
           report.get("payload") != prearm["payload"]:
            raise ValueError("frozen payload report discrepancy")
    if comparison.get("status") != "MATCH":
        raise ValueError("whole-root copy mismatch")
    names = set(os.listdir(root))
    allowed = set(prearm["clean_usb_initial_root"]) | set(prearm["payload"]) | {
        ".stage4b-capability.lock", "stage4b-capability"}
    if not names <= allowed or "ARM_STAGE4B_CAPABILITY_PREFLIGHT" in names:
        raise ValueError("unexpected object or unconsumed marker")
    lock = root / ".stage4b-capability.lock"
    if not stat.S_ISDIR(os.lstat(lock).st_mode) or any(lock.iterdir()):
        raise ValueError("one-shot lock absent or ambiguous")
    results = sorted(name for name in names if name.startswith("stage4b-capability"))
    if len(results) > 1 or (results and results[0] != "stage4b-capability"):
        raise ValueError("multiple or unexpected result directories")
    if not results:
        category, reason = "INCOMPLETE", "result directory absent"
    else:
        result = root / "stage4b-capability"
        if not stat.S_ISDIR(os.lstat(result).st_mode):
            raise ValueError("result directory wrong type")
        status_path = result / "STATUS.txt"
        complete_path = result / "COMPLETE"
        errors_path = result / "ERRORS.txt"
        if any(os.path.lexists(path) and
               not stat.S_ISREG(os.lstat(path).st_mode) for path in
               (status_path, complete_path, errors_path)):
            raise ValueError("transaction object wrong type")
        if not all(os.path.lexists(path) for path in
                   (status_path, complete_path, errors_path)):
            category, reason = "INCOMPLETE", "transaction file absent"
        else:
            lines = status_path.read_text().splitlines()
            fields = dict(line.split("=", 1) for line in lines if "=" in line)
            if len(fields) != len(lines) or len(fields) != 5 or \
               fields.get("schema") != "1" or \
               fields.get("scope") != "w176-stage4b-capability-metadata":
                raise ValueError("malformed STATUS")
            failures = fields.get("mandatory_failures", "")
            if not failures.isascii() or not failures.isdecimal():
                raise ValueError("malformed mandatory failure count")
            if fields.get("status") != "COMPLETE" or int(failures) != 0 or \
               errors_path.stat().st_size != 0:
                category, reason = "INCOMPLETE", "reported probe failure"
            else:
                exit_code = (base / "analysis.exit_status").read_text().strip()
                if exit_code == "2" and (base / "analysis.stderr").read_text().startswith(
                        "INVALID CAPTURE:"):
                    category, reason = "INCOMPLETE", "frozen analyser rejected transaction"
                elif exit_code != "0":
                    raise ValueError("analyser discrepancy")
                else:
                    analysed = json.loads((base / "analysis.json").read_text())
                    if analysed.get("CAPTURE") != "COMPLETE" or \
                       analysed.get("SEALED_RUNTIME_EXECUTION") != "NOT_TESTED" or \
                       analysed.get("EXECUTION_HIGH") != "OPEN":
                        raise ValueError("analyser result outside evidence boundary")
                    category, reason = "VALID COMPLETE CAPTURE", "all gates passed"
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
    category, reason = "MANUAL REVIEW REQUIRED", str(exc)
report = {"category": category, "reason": reason}
with open(base / "classification.json", "x", encoding="utf-8") as output:
    json.dump(report, output, sort_keys=True, indent=2)
    output.write("\n")
print(json.dumps(report, sort_keys=True))
PY
~~~

A valid physical metadata capture may establish kernel identity, installed
mountinfo and MTD/sysfs presentation, libc/loader provenance, static wrapper
exports, and feature-support metadata. It cannot establish successful memfd
creation, sealing, mutation rejection, or descriptor execution. The required
evidence boundary remains SEALED_RUNTIME_EXECUTION=NOT_TESTED and
EXECUTION_HIGH=OPEN. Stage-4B residency remains NO-GO.

## Disposable host procedure checks

The remediation was checked without a real USB or target interaction. A
temporary-directory harness extracted the Python blocks above, used a
symlinked-ancestor fixture, mocked the frozen Git blob reads with fixture
bytes, and exercised the clean-root, provenance, and final-classification
gates. It confirmed: ancestor resolving onto USB STOP; external host STOP;
same-device host STOP; separate internal host PASS; prior result and nested
old-result content STOP without deletion; clean empty root PASS; matching
stable identity and frozen payload PASS; changed identity, changed payload,
and symlinked payload STOP; operator YES eligible for VALID COMPLETE while NO
and UNKNOWN require MANUAL REVIEW; missing COMPLETE yields INCOMPLETE. A
read-only check against this Mac also confirmed that the df/diskutil lookup
selects the writable APFS Data volume for an ordinary home directory. The
old documentation's recursive cleanup was inspected as a nested-mount risk;
no nested filesystem was mounted or deleted during testing. These fixtures
do not prove behaviour on a future USB or the RoadTop.

## Stop conditions

Do not prepare, arm, or run if the frozen SHA, payload bytes/size/hash,
pre-arm record, USB identity/FAT/removable/writable check, separate internal
host storage, clean-volume gate, or effective permissions fail. Stop for a
dirty USB: no cleanup or reuse. Stop for a live marker, old lock/result,
unexpected content, cloud-synchronised host parent, branch/commit confusion,
or a target that no longer appears to be the owner-confirmed RoadTop. Stop
for unstable RoadTop power, unexpected behaviour, or any failed command.
Do not substitute the moving branch tip, broaden the capture, modify target
state, or automatically retry after an uncertain attempt.
