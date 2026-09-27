#!/bin/sh
# Run only inside a disposable privileged Linux container with dosfstools.
set -eu

IMAGE=/tmp/w176-fat.img
MOUNTPOINT=/mnt/w176-fat
READY=/run/w176-writer-ready
GO=/run/w176-writer-go
WRITER_STATUS=/run/w176-writer-status
WRITER_ERROR=/run/w176-writer-error
LOOP=
MOUNTED=0

cleanup() {
    cd /
    if [ "$MOUNTED" -eq 1 ]; then
        mount -o remount,rw "$LOOP" "$MOUNTPOINT" >/dev/null 2>&1 || true
        umount "$MOUNTPOINT" >/dev/null 2>&1 || true
    fi
    [ -z "$LOOP" ] || losetup -d "$LOOP" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

truncate -s 256M "$IMAGE"
mkfs.fat -F 32 "$IMAGE" >/dev/null
mkdir -p "$MOUNTPOINT"
LOOP=$(losetup --find --show "$IMAGE")
mount -t vfat -o rw,dirsync,nosuid,nodev,noatime,nodiratime "$LOOP" "$MOUNTPOINT"
MOUNTED=1

printf '#!/bin/sh\nexit 0\n' > "$MOUNTPOINT/candidate"
printf '#!/bin/sh\nexit 7\n' > "$MOUNTPOINT/replacement"
chmod 755 "$MOUNTPOINT/candidate" "$MOUNTPOINT/replacement"
printf 'rw-before\n' > "$MOUNTPOINT/write-before"
printf 'armed\n' > "$MOUNTPOINT/ARM_STAGE3_ARM_EXECUTION_PROBE"
rm "$MOUNTPOINT/ARM_STAGE3_ARM_EXECUTION_PROBE"
[ ! -e "$MOUNTPOINT/ARM_STAGE3_ARM_EXECUTION_PROBE" ]
HASH_BEFORE=$(sha256sum "$MOUNTPOINT/candidate" | awk '{print $1}')
cd "$MOUNTPOINT"

mount -o remount,ro "$LOOP" "$MOUNTPOINT"
OPTIONS=$(awk -v d="$LOOP" -v m="$MOUNTPOINT" '$1 == d && $2 == m && $3 == "vfat" {print $4}' /proc/mounts)
case ",$OPTIONS," in *,ro,*) ;; *) echo "ro verification failed" >&2; exit 1 ;; esac
case ",$OPTIONS," in *,rw,*) echo "rw remained set" >&2; exit 1 ;; esac

if mv "$MOUNTPOINT/replacement" "$MOUNTPOINT/candidate" 2>/dev/null; then
    echo "rename-over unexpectedly succeeded" >&2
    exit 1
fi
if sh -c ': > "$1"' sh "$MOUNTPOINT/candidate" 2>/dev/null; then
    echo "truncate unexpectedly succeeded" >&2
    exit 1
fi
if sh -c 'printf x >> "$1"' sh "$MOUNTPOINT/candidate" 2>/dev/null; then
    echo "in-place append unexpectedly succeeded" >&2
    exit 1
fi
HASH_RO=$(sha256sum "$MOUNTPOINT/candidate" | awk '{print $1}')
[ "$HASH_RO" = "$HASH_BEFORE" ]
if mv "$MOUNTPOINT/replacement" "$MOUNTPOINT/candidate" 2>/dev/null; then
    echo "post-hash rename-over unexpectedly succeeded" >&2
    exit 1
fi
if sh -c 'printf late >> "$1"' sh "$MOUNTPOINT/candidate" 2>/dev/null; then
    echo "post-hash write unexpectedly succeeded" >&2
    exit 1
fi
[ "$(sha256sum "$MOUNTPOINT/candidate" | awk '{print $1}')" = "$HASH_RO" ]
"$MOUNTPOINT/candidate"

mount -o remount,rw "$LOOP" "$MOUNTPOINT"
OPTIONS=$(awk -v d="$LOOP" -v m="$MOUNTPOINT" '$1 == d && $2 == m && $3 == "vfat" {print $4}' /proc/mounts)
case ",$OPTIONS," in *,rw,*) ;; *) echo "rw verification failed" >&2; exit 1 ;; esac
case ",$OPTIONS," in *,ro,*) echo "ro remained set" >&2; exit 1 ;; esac
printf 'rw-after\n' > "$MOUNTPOINT/write-after"

rm -f "$READY" "$GO" "$WRITER_STATUS" "$WRITER_ERROR"
(
    exec 9>> "$MOUNTPOINT/candidate"
    : > "$READY"
    while [ ! -e "$GO" ]; do sleep 0.05; done
    if printf retained >&9 2> "$WRITER_ERROR"; then
        printf '0\n' > "$WRITER_STATUS"
    else
        printf '%s\n' "$?" > "$WRITER_STATUS"
    fi
) &
WRITER_PID=$!
while [ ! -e "$READY" ]; do sleep 0.05; done

if mount -o remount,ro "$LOOP" "$MOUNTPOINT" 2>/run/w176-retained-remount-error; then
    RETAINED_REMOUNT=SUCCEEDED
    RETAINED_REMOUNT_ERROR=none
    OPTIONS=$(awk -v d="$LOOP" -v m="$MOUNTPOINT" '$1 == d && $2 == m && $3 == "vfat" {print $4}' /proc/mounts)
    case ",$OPTIONS," in *,ro,*) ;; *) echo "retained-handle remount falsely succeeded" >&2; exit 1 ;; esac
else
    RETAINED_REMOUNT=BLOCKED
    RETAINED_REMOUNT_ERROR=$(tr '\n' ' ' < /run/w176-retained-remount-error | sed 's/[[:space:]][[:space:]]*/ /g')
    OPTIONS=$(awk -v d="$LOOP" -v m="$MOUNTPOINT" '$1 == d && $2 == m && $3 == "vfat" {print $4}' /proc/mounts)
    case ",$OPTIONS," in *,rw,*) ;; *) echo "failed retained-handle remount left unknown state" >&2; exit 1 ;; esac
fi
: > "$GO"
wait "$WRITER_PID"
RETAINED_WRITE_STATUS=$(cat "$WRITER_STATUS")

if [ "$RETAINED_REMOUNT" = SUCCEEDED ]; then
    [ "$RETAINED_WRITE_STATUS" -ne 0 ] || {
        echo "retained writer mutated RO filesystem" >&2
        exit 1
    }
    mount -o remount,rw "$LOOP" "$MOUNTPOINT"
else
    [ "$RETAINED_WRITE_STATUS" -eq 0 ] || {
        echo "writer failed despite remount remaining RW" >&2
        exit 1
    }
fi

printf 'schema=1\nresult=PASS\n' > "$MOUNTPOINT/execution.txt"
printf 'complete=1\n' > "$MOUNTPOINT/COMPLETE"

printf '%s\n' \
    "fat.filesystem=vfat" \
    "rw.write.before=PASS" \
    "anchored.cwd=PASS" \
    "arming_marker.consumed=PASS" \
    "ro.state.verified=PASS" \
    "ro.rename_over.blocked=PASS" \
    "ro.truncate.blocked=PASS" \
    "ro.in_place_write.blocked=PASS" \
    "ro.hash.stable=PASS" \
    "ro.post_hash_rename_over.blocked=PASS" \
    "ro.post_hash_write.blocked=PASS" \
    "ro.host_stub.execution=PASS" \
    "rw.restore.verified=PASS" \
    "rw.write.after=PASS" \
    "retained_handle.remount=$RETAINED_REMOUNT" \
    "retained_handle.remount_error=$RETAINED_REMOUNT_ERROR" \
    "retained_handle.write_status=$RETAINED_WRITE_STATUS" \
    "transaction.after_rw=PASS"
