#!/bin/sh
# Run only inside a disposable privileged Linux container with dosfstools.
set -eu

IMAGE=/tmp/w176-fat-lock.img
MOUNTPOINT=/mnt/w176-fat-lock
LOCK_NAME=.stage3-arm-probe.lock
MARKER_NAME=ARM_STAGE3_ARM_EXECUTION_PROBE
REPETITIONS=50
LOG_ROOT=/run/w176-fat-lock-events
PAUSE_READY=/run/w176-fat-lock-pause-ready
PAUSE_RELEASE=/run/w176-fat-lock-pause-release
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
mkdir -p "$MOUNTPOINT" "$LOG_ROOT"
LOOP=$(losetup --find --show "$IMAGE")
mount -t vfat -o rw,dirsync,nosuid,nodev,noatime,nodiratime "$LOOP" "$MOUNTPOINT"
MOUNTED=1

printf '#!/bin/sh\nexit 0\n' > "$MOUNTPOINT/host-stub"
chmod 755 "$MOUNTPOINT/host-stub"
EXPECTED_HASH=$(sha256sum "$MOUNTPOINT/host-stub" | awk '{print $1}')

mount_options() {
    awk -v d="$LOOP" -v m="$MOUNTPOINT" \
        '$1 == d && $2 == m && $3 == "vfat" { count++; options=$4 } END { if (count == 1) print options; else exit 1 }' \
        /proc/mounts
}

verify_state() {
    EXPECTED=$1
    OPTIONS=$(mount_options)
    case "$EXPECTED:$OPTIONS" in
        ro:*) case ",$OPTIONS," in *,ro,*) ;; *) return 1 ;; esac
              case ",$OPTIONS," in *,rw,*) return 1 ;; esac ;;
        rw:*) case ",$OPTIONS," in *,rw,*) ;; *) return 1 ;; esac
              case ",$OPTIONS," in *,ro,*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
}

contender() (
    REPETITION=$1
    CONTENDER_ID=$2
    cd "$MOUNTPOINT"
    LOCK_OWNED=0
    : > "$LOG_ROOT/ready.$REPETITION.$CONTENDER_ID"
    while [ ! -e "$LOG_ROOT/ready.$REPETITION.a" ] || [ ! -e "$LOG_ROOT/ready.$REPETITION.b" ]; do
        sleep 0.01
    done
    if mkdir "./$LOCK_NAME" 2>/dev/null; then
        LOCK_OWNED=1
    else
        : > "$LOG_ROOT/loser.$REPETITION.$CONTENDER_ID"
        exit 1
    fi
    owns_lock() {
        [ "$LOCK_OWNED" -eq 1 ] && [ -d "$MOUNTPOINT/$LOCK_NAME" ] && [ ! -L "$MOUNTPOINT/$LOCK_NAME" ]
    }
    owns_lock || exit 2
    : > "$LOG_ROOT/winner.$REPETITION.$CONTENDER_ID"
    [ -f "./$MARKER_NAME" ] && [ ! -L "./$MARKER_NAME" ] || exit 3
    rm "./$MARKER_NAME"
    [ ! -e "./$MARKER_NAME" ] && [ ! -L "./$MARKER_NAME" ] || exit 4
    : > "$LOG_ROOT/marker.$REPETITION.$CONTENDER_ID"
    OUT="result-$REPETITION-$CONTENDER_ID"
    mkdir "$OUT"
    printf 'status=INCOMPLETE\n' > "$OUT/STATUS.txt"
    owns_lock || exit 5
    : > "$LOG_ROOT/ro-request.$REPETITION.$CONTENDER_ID"
    mount -o remount,ro "$LOOP" "$MOUNTPOINT"
    verify_state ro
    owns_lock || exit 6
    ACTUAL_HASH=$(sha256sum "$MOUNTPOINT/host-stub" | awk '{print $1}')
    [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ]
    : > "$LOG_ROOT/hash.$REPETITION.$CONTENDER_ID"
    owns_lock || exit 7
    "$MOUNTPOINT/host-stub"
    : > "$LOG_ROOT/exec.$REPETITION.$CONTENDER_ID"
    owns_lock || exit 8
    : > "$LOG_ROOT/rw-request.$REPETITION.$CONTENDER_ID"
    mount -o remount,rw "$LOOP" "$MOUNTPOINT"
    verify_state rw
    printf 'status=COMPLETE\n' > "$OUT/STATUS.txt"
    printf 'complete=1\n' > "$OUT/COMPLETE"
    : > "$LOG_ROOT/complete.$REPETITION.$CONTENDER_ID"
)

count_pair_events() {
    PREFIX=$1
    REPETITION=$2
    COUNT=0
    for CONTENDER_ID in a b; do
        [ ! -e "$LOG_ROOT/$PREFIX.$REPETITION.$CONTENDER_ID" ] || COUNT=$((COUNT + 1))
    done
    printf '%s\n' "$COUNT"
}

TOTAL_EXECUTIONS=0
TOTAL_RO_REQUESTS=0
TOTAL_RW_REQUESTS=0
for REPETITION in $(seq 1 "$REPETITIONS"); do
    verify_state rw
    if [ -e "$MOUNTPOINT/$LOCK_NAME" ] || [ -L "$MOUNTPOINT/$LOCK_NAME" ]; then
        rmdir "$MOUNTPOINT/$LOCK_NAME"
    fi
    printf 'armed\n' > "$MOUNTPOINT/$MARKER_NAME"

    contender "$REPETITION" a &
    FIRST_PID=$!
    contender "$REPETITION" b &
    SECOND_PID=$!
    FIRST_STATUS=0
    SECOND_STATUS=0
    wait "$FIRST_PID" || FIRST_STATUS=$?
    wait "$SECOND_PID" || SECOND_STATUS=$?

    [ "$(count_pair_events winner "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events loser "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events marker "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events hash "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events exec "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events ro-request "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events rw-request "$REPETITION")" -eq 1 ]
    [ "$(count_pair_events complete "$REPETITION")" -eq 1 ]
    [ "$FIRST_STATUS" -eq 0 ] || [ "$SECOND_STATUS" -eq 0 ]
    [ "$FIRST_STATUS" -ne 0 ] || [ "$SECOND_STATUS" -ne 0 ]
    [ -d "$MOUNTPOINT/$LOCK_NAME" ] && [ ! -L "$MOUNTPOINT/$LOCK_NAME" ]
    [ ! -e "$MOUNTPOINT/$MARKER_NAME" ]
    verify_state rw
    TOTAL_EXECUTIONS=$((TOTAL_EXECUTIONS + 1))
    TOTAL_RO_REQUESTS=$((TOTAL_RO_REQUESTS + 1))
    TOTAL_RW_REQUESTS=$((TOTAL_RW_REQUESTS + 1))
done

# The test harness deliberately performs the off-target-equivalent reset here.
rmdir "$MOUNTPOINT/$LOCK_NAME"
printf 'armed\n' > "$MOUNTPOINT/$MARKER_NAME"
rm -f "$PAUSE_READY" "$PAUSE_RELEASE"

(
    cd "$MOUNTPOINT"
    LOCK_OWNED=0
    mkdir "./$LOCK_NAME"
    LOCK_OWNED=1
    owns_pause_lock() {
        [ "$LOCK_OWNED" -eq 1 ] && [ -d "$MOUNTPOINT/$LOCK_NAME" ] && [ ! -L "$MOUNTPOINT/$LOCK_NAME" ]
    }
    owns_pause_lock
    rm "./$MARKER_NAME"
    mkdir pause-result-owner
    printf 'status=INCOMPLETE\n' > pause-result-owner/STATUS.txt
    owns_pause_lock
    : > "$LOG_ROOT/pause.owner.ro-request"
    mount -o remount,ro "$LOOP" "$MOUNTPOINT"
    verify_state ro
    : > "$PAUSE_READY"
    while [ ! -e "$PAUSE_RELEASE" ]; do sleep 0.01; done
    owns_pause_lock
    [ "$(sha256sum "$MOUNTPOINT/host-stub" | awk '{print $1}')" = "$EXPECTED_HASH" ]
    "$MOUNTPOINT/host-stub"
    : > "$LOG_ROOT/pause.owner.exec"
    owns_pause_lock
    : > "$LOG_ROOT/pause.owner.rw-request"
    mount -o remount,rw "$LOOP" "$MOUNTPOINT"
    verify_state rw
    printf 'status=COMPLETE\n' > pause-result-owner/STATUS.txt
    printf 'complete=1\n' > pause-result-owner/COMPLETE
    : > "$LOG_ROOT/pause.owner.complete"
) &
OWNER_PID=$!
while [ ! -e "$PAUSE_READY" ]; do sleep 0.01; done
verify_state ro

(
    cd "$MOUNTPOINT"
    if mkdir "./$LOCK_NAME" 2>/dev/null; then
        : > "$LOG_ROOT/pause.loser.unexpected-lock"
        exit 0
    fi
    : > "$LOG_ROOT/pause.loser.lock-rejected"
    exit 1
) &
LOSER_PID=$!
LOSER_STATUS=0
wait "$LOSER_PID" || LOSER_STATUS=$?
[ "$LOSER_STATUS" -ne 0 ]
[ -e "$LOG_ROOT/pause.loser.lock-rejected" ]
[ ! -e "$LOG_ROOT/pause.loser.unexpected-lock" ]
[ ! -e "$LOG_ROOT/pause.owner.rw-request" ]
verify_state ro
: > "$PAUSE_RELEASE"
wait "$OWNER_PID"
verify_state rw
[ -e "$LOG_ROOT/pause.owner.exec" ]
[ -e "$LOG_ROOT/pause.owner.rw-request" ]
[ -e "$LOG_ROOT/pause.owner.complete" ]
[ -d "$MOUNTPOINT/$LOCK_NAME" ] && [ ! -L "$MOUNTPOINT/$LOCK_NAME" ]

printf '%s\n' \
    "fat.lock.filesystem=vfat" \
    "fat.lock.concurrent_repetitions=$REPETITIONS" \
    "fat.lock.concurrent_winners=$REPETITIONS" \
    "fat.lock.concurrent_losers=$REPETITIONS" \
    "fat.lock.concurrent_executions=$TOTAL_EXECUTIONS" \
    "fat.lock.concurrent_ro_requests=$TOTAL_RO_REQUESTS" \
    "fat.lock.concurrent_rw_requests=$TOTAL_RW_REQUESTS" \
    "fat.lock.concurrent_completes=$REPETITIONS" \
    "fat.lock.pause_second_rejected=PASS" \
    "fat.lock.pause_usb_remained_ro=PASS" \
    "fat.lock.pause_owner_execution=1" \
    "fat.lock.pause_owner_ro_requests=1" \
    "fat.lock.pause_owner_rw_requests=1" \
    "fat.lock.persistent_after_success=PASS"
