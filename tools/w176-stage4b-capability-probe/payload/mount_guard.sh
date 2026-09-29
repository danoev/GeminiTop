#!/bin/sh
# Stage-4B USB guard: prove the effective mounted filesystem before any write.
CDPATH=
export CDPATH
IFS=$(printf '\040\011\012x'); IFS=${IFS%x}
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
MOUNTS_FILE=/proc/mounts
MOUNTINFO_FILE=/proc/self/mountinfo
SYS_BLOCK_ROOT=/sys/block
DEV_ROOT=/dev
DEVICE_TEST=-b
fail() { printf '%s\n' "w176-stage4b: USB validation failed: $1" >&2; exit 1; }

[ "$#" -eq 1 ] || fail argument_count
[ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] || fail unsafe_root
for CMD in awk dd pwd sed stat; do command -v "$CMD" >/dev/null 2>&1 || fail "missing_$CMD"; done
CANONICAL_ROOT=$(cd -P "$1" 2>/dev/null && pwd -P) || fail canonical_root
[ "$1" -ef "$CANONICAL_ROOT" ] 2>/dev/null || fail root_changed
[ -r "$MOUNTS_FILE" ] && [ -r "$MOUNTINFO_FILE" ] || fail mount_views_missing
case "$CANONICAL_ROOT" in /|*\\*|*[!A-Za-z0-9_./-]*) fail unsafe_mount_path ;; esac

# Command substitution is in memory, not a target write. The terminal x
# preserves trailing newlines; dd's exit status is checked separately. Read
# one byte per counted input block: count must not mean "17 short reads".
# LIMIT+1 bytes proves either EOF within the bound or an oversize view.
MOUNTS=$(dd if="$MOUNTS_FILE" bs=1 count=65537 2>/dev/null && printf x) || fail mounts_read
case "$MOUNTS" in *x) MOUNTS=${MOUNTS%x} ;; *) fail mounts_read ;; esac
[ "${#MOUNTS}" -le 65536 ] || fail mounts_oversize
INFO=$(dd if="$MOUNTINFO_FILE" bs=1 count=131073 2>/dev/null && printf x) || fail mountinfo_read
case "$INFO" in *x) INFO=${INFO%x} ;; *) fail mountinfo_read ;; esac
[ "${#INFO}" -le 131072 ] || fail mountinfo_oversize
NEWLINE_X=$(printf '\nx')
case "${MOUNTS}x" in *"$NEWLINE_X") ;; *) fail mounts_unterminated ;; esac
case "${INFO}x" in *"$NEWLINE_X") ;; *) fail mountinfo_unterminated ;; esac

# Reject ambiguity and nested covering mounts. Both tables must be globally
# well formed and bounded before the first mutation occurs.
MOUNT_RECORD=$(printf '%s' "$MOUNTS" | awk -v root="$CANONICAL_ROOT" '
  BEGIN { good=1; count=0; sdcount=0; n=0 }
  { n++; if (n>256 || length($0)>2048 || NF!=6) good=0;
    if ($1 ~ /^\/dev\/sd[a-z]+[0-9]+$/) sdcount++;
    if ($2==root) { count++; rec=$1 "|" $2 "|" $3 "|" $4 }
    if (index($2,root "/")==1) good=0 }
  END { if (!good || count!=1 || sdcount!=1) exit 1; print rec }
') || fail mounts_malformed_or_ambiguous
INFO_RECORD=$(printf '%s' "$INFO" | awk -v root="$CANONICAL_ROOT" '
  BEGIN { good=1; count=0; n=0 }
  { n++; if (n>256 || length($0)>2048 || NF<10 || $1 !~ /^[0-9]+$/ ||
               $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+:[0-9]+$/ ||
               substr($4,1,1)!="/" || substr($5,1,1)!="/") good=0;
    sep=0; for (i=7;i<=NF;i++) if ($i=="-") { if (sep) good=0; sep=i }
    if (!sep || NF!=sep+3) good=0;
    if ($5==root) { count++; rec=$3 "|" $4 "|" $5 "|" $6 "|" $(sep+1) "|" $(sep+2) "|" $(sep+3) }
    if (index($5,root "/")==1) good=0 }
  END { if (!good || count!=1) exit 1; print rec }
') || fail mountinfo_malformed_or_ambiguous

DEVICE=${MOUNT_RECORD%%|*}; REST=${MOUNT_RECORD#*|}
MOUNT=${REST%%|*}; REST=${REST#*|}; FSTYPE=${REST%%|*}; MOUNT_OPTS=${REST#*|}
case "$DEVICE" in /dev/sd*[0-9]) ;; *) fail wrong_source ;; esac
case "$FSTYPE" in vfat|msdos|fat) ;; *) fail wrong_fs ;; esac
NAME=${DEVICE#/dev/}; DISK=$(printf '%s\n' "$NAME" | sed 's/[0-9][0-9]*$//')
case "$DISK" in sd[a-z]*) ;; *) fail wrong_disk ;; esac
case "$DISK" in *[!a-z]*) fail wrong_disk ;; esac
PART=${NAME#"$DISK"}
case "$PART" in ''|*[!0-9]*) fail wrong_partition ;; esac
[ -r "$SYS_BLOCK_ROOT/$DISK/removable" ] || fail removable_missing
REMOVABLE=$(dd if="$SYS_BLOCK_ROOT/$DISK/removable" bs=4 count=1 2>/dev/null) || fail removable_read
[ "$REMOVABLE" = 1 ] || fail not_removable
if [ "$DEVICE_TEST" = -b ]; then [ -b "$DEV_ROOT/$NAME" ] && [ ! -L "$DEV_ROOT/$NAME" ] || fail device_node
else [ -e "$DEV_ROOT/$NAME" ] && [ ! -L "$DEV_ROOT/$NAME" ] || fail fixture_device; fi

INFO_MM=${INFO_RECORD%%|*}; REST=${INFO_RECORD#*|}
INFO_FSROOT=${REST%%|*}; REST=${REST#*|}; INFO_MOUNT=${REST%%|*}
REST=${REST#*|}; INFO_OPTS=${REST%%|*}; REST=${REST#*|}
INFO_FS=${REST%%|*}; REST=${REST#*|}; INFO_SOURCE=${REST%%|*}; INFO_SUPER_OPTS=${REST#*|}
[ "$MOUNT" = "$CANONICAL_ROOT" ] && [ "$INFO_MOUNT" = "$CANONICAL_ROOT" ] || fail wrong_mountpoint
[ "$INFO_FSROOT" = / ] && [ "$INFO_FS" = "$FSTYPE" ] &&
    [ "$INFO_SOURCE" = "$DEVICE" ] || fail inconsistent_mount_views
for OPTS in "$MOUNT_OPTS" "$INFO_OPTS" "$INFO_SUPER_OPTS"; do
    case ",$OPTS," in *,rw,*) ;; *) fail mount_not_rw ;; esac
    case ",$OPTS," in *,ro,*) fail contradictory_ro ;; esac
done

# Linux st_dev encodes the major:minor reported for this mount by mountinfo.
DEC=$(stat -c '%d' "$CANONICAL_ROOT" 2>/dev/null) || fail root_stat
case "$DEC" in ''|*[!0-9]*) fail root_stat ;; esac
ROOT_MAJOR=$(( (DEC >> 8 & 4095) | (DEC >> 32 & -4096) ))
ROOT_MINOR=$(( (DEC & 255) | (DEC >> 12 & -256) ))
[ "$INFO_MM" = "$ROOT_MAJOR:$ROOT_MINOR" ] || fail effective_device_mismatch
if [ "$DEVICE_TEST" = -b ]; then
    MAJOR_HEX=$(stat -c '%t' "$DEV_ROOT/$NAME" 2>/dev/null) || fail source_stat
    MINOR_HEX=$(stat -c '%T' "$DEV_ROOT/$NAME" 2>/dev/null) || fail source_stat
    SOURCE_MAJOR=$(printf '%d' "0x$MAJOR_HEX" 2>/dev/null) || fail source_stat
    SOURCE_MINOR=$(printf '%d' "0x$MINOR_HEX" 2>/dev/null) || fail source_stat
    [ "$INFO_MM" = "$SOURCE_MAJOR:$SOURCE_MINOR" ] || fail source_device_mismatch
fi
[ . -ef "$CANONICAL_ROOT" ] 2>/dev/null || fail cwd_changed
printf '%s\n' "$CANONICAL_ROOT"
