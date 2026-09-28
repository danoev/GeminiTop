#!/bin/sh
# Host-native, synthetic /proc tests for identity and finite FD scanning.
# This script never opens or executes the committed ARM binary.
set -eu

ROOT=$(mktemp -d /tmp/w176-stage4b-process.XXXXXX)
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT HUP INT TERM
. /src/payload/common.sh
PROCESS_ROOT=$ROOT/proc
DEST_BINARY=$ROOT/geminitop-proofd
USB_ROOT=$ROOT/usb
mkdir -p "$PROCESS_ROOT" "$USB_ROOT" "$ROOT/bin"
cp /bin/sleep "$DEST_BINARY"
COUNT=0
pass() { COUNT=$((COUNT + 1)); printf 'PASS %s\n' "$1"; }

make_process() {
    P=$1; TGID=$2; STATE=$3; FLAGS=$4; TICKS=$5
    mkdir -p "$PROCESS_ROOT/$P/fd"
    printf 'Pid:\t%s\nTgid:\t%s\nState:\t%s (fixture)\n' "$P" "$TGID" "$STATE" > "$PROCESS_ROOT/$P/status"
    printf '%s (synthetic comm) %s' "$P" "$STATE" > "$PROCESS_ROOT/$P/stat"
    FIELD=4
    while [ "$FIELD" -le 21 ]; do
        if [ "$FIELD" -eq 9 ]; then printf ' %s' "$FLAGS" >> "$PROCESS_ROOT/$P/stat"
        else printf ' 0' >> "$PROCESS_ROOT/$P/stat"; fi
        FIELD=$((FIELD + 1))
    done
    printf ' %s\n' "$TICKS" >> "$PROCESS_ROOT/$P/stat"
    ln -s "$DEST_BINARY" "$PROCESS_ROOT/$P/exe"
    ln -s /tmp "$PROCESS_ROOT/$P/cwd"
    ln -s /dev/null "$PROCESS_ROOT/$P/fd/0"
}

make_process 123 123 S 0 42
read_process_identity 123
[ "$PROCESS_START" = 42 ] && [ "$PROCESS_EXE_ONE" = "$DEST_BINARY" ]
scan_unique_proofd 123 42
validate_process_detached_from_usb 123
pass live_leader_start_inode_and_no_usb_fd

printf 'Pid:\t123\nTgid:\t124\nState:\tS (fixture)\n' > "$PROCESS_ROOT/123/status"
if read_process_identity 123; then exit 1; fi
printf 'Pid:\t123\nTgid:\t123\nState:\tS (fixture)\n' > "$PROCESS_ROOT/123/status"
pass wrong_tgid_rejected

printf 'Pid:\t123\nTgid:\t123\nState:\tZ (fixture)\n' > "$PROCESS_ROOT/123/status"
sed -i 's/) S /) Z /' "$PROCESS_ROOT/123/stat"
if read_process_identity 123; then exit 1; fi
scan_no_proofd
sed -i 's/) Z /) S /' "$PROCESS_ROOT/123/stat"
printf 'Pid:\t123\nTgid:\t123\nState:\tS (fixture)\n' > "$PROCESS_ROOT/123/status"
pass zombie_not_live_execution

printf 'Pid:\t123\nTgid:\t123\nState:\tQ (fixture)\n' > "$PROCESS_ROOT/123/status"
if read_process_core 123; then exit 1; fi
printf 'Pid:\t123\nTgid:\t123\nState:\tS (fixture)\n' > "$PROCESS_ROOT/123/status"
pass unknown_state_rejected

sed -i 's/ 42$/ 43/' "$PROCESS_ROOT/123/stat"
if scan_unique_proofd 123 42; then exit 1; fi
sed -i 's/ 43$/ 42/' "$PROCESS_ROOT/123/stat"
pass changed_start_ticks_rejected

make_process 124 124 S 0 99
if scan_unique_proofd 123 42; then exit 1; fi
rm -rf "$PROCESS_ROOT/124"
pass duplicate_same_executable_inode_rejected

make_process 125 125 S 0 99
rm "$PROCESS_ROOT/125/exe"
if scan_unique_proofd 123 42; then exit 1; fi
rm -rf "$PROCESS_ROOT/125"
pass live_uninspectable_process_rejected

rm "$PROCESS_ROOT/123/exe"
ln -s /bin/true "$PROCESS_ROOT/123/exe"
if scan_unique_proofd 123 42; then exit 1; fi
rm "$PROCESS_ROOT/123/exe"
ln -s "$DEST_BINARY" "$PROCESS_ROOT/123/exe"
pass changed_executable_identity_rejected

rm "$PROCESS_ROOT/123/fd/0"
ln -s "$USB_ROOT/file" "$PROCESS_ROOT/123/fd/0"
if validate_process_detached_from_usb 123; then exit 1; fi
rm "$PROCESS_ROOT/123/fd/0"
ln -s /dev/null "$PROCESS_ROOT/123/fd/0"
pass explicit_usb_fd_rejected

ln -s /dev/null "$PROCESS_ROOT/123/fd/128"
if validate_process_detached_from_usb 123; then exit 1; fi
rm "$PROCESS_ROOT/123/fd/128"
pass fd_over_reviewed_bound_rejected

cat > "$ROOT/bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in */fd/0) rm "$1" ;; esac
exec /usr/bin/readlink "$@"
EOF
chmod 755 "$ROOT/bin/readlink"
PATH=$ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin
if validate_process_detached_from_usb 123; then exit 1; fi
rm "$ROOT/bin/readlink"
ln -s /dev/null "$PROCESS_ROOT/123/fd/0"
pass fd_disappears_during_scan_rejected

cat > "$ROOT/bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in */fd/0) exit 7 ;; esac
exec /usr/bin/readlink "$@"
EOF
chmod 755 "$ROOT/bin/readlink"
if validate_process_detached_from_usb 123; then exit 1; fi
rm "$ROOT/bin/readlink"
pass fd_readlink_failure_rejected

export USB_ROOT PROCESS_ROOT
cat > "$ROOT/bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in
    */fd/0)
        if [ ! -e "$PROCESS_ROOT/switched" ]; then
            OLD=$(/usr/bin/readlink "$1") || exit 1
            /bin/rm "$1"
            /bin/ln -s "$USB_ROOT/file" "$1"
            : > "$PROCESS_ROOT/switched"
            printf '%s\n' "$OLD"
            exit 0
        fi
        ;;
esac
exec /usr/bin/readlink "$@"
EOF
chmod 755 "$ROOT/bin/readlink"
if validate_process_detached_from_usb 123; then exit 1; fi
rm "$ROOT/bin/readlink" "$PROCESS_ROOT/switched" "$PROCESS_ROOT/123/fd/0"
ln -s /dev/null "$PROCESS_ROOT/123/fd/0"
pass fd_target_replaced_during_scan_rejected

cat > "$ROOT/bin/readlink" <<'EOF'
#!/bin/sh
case "$1" in
    */fd/0)
        if [ ! -e "$PROCESS_ROOT/switched" ]; then
            /bin/sed -i 's/ 42$/ 43/' "$PROCESS_ROOT/123/stat"
            : > "$PROCESS_ROOT/switched"
        fi
        ;;
esac
exec /usr/bin/readlink "$@"
EOF
chmod 755 "$ROOT/bin/readlink"
if validate_process_detached_from_usb 123; then exit 1; fi
pass process_changes_during_fd_bracket_rejected

printf 'schema=1\nresult=PASS_PARTIAL_MATRIX\ntests=%s\n' "$COUNT"
