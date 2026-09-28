#!/bin/sh
# Disposable Linux integration tests. The target ARM ELF is always replaced by
# a host-native fixture before any installer path is invoked.
set -eu

SOURCE=/src
TEST_ROOT=/tmp/geminitop-stage4b-tests.$$
CURRENT=
CURRENT_PID=
PASS_COUNT=0

cleanup_current() {
    if [ -n "$CURRENT_PID" ]; then kill -TERM "$CURRENT_PID" 2>/dev/null || true; fi
    sleep 0.1 2>/dev/null || true
    rm -f /tmp/geminitop-proofd.status /tmp/.geminitop-proofd.status.tmp
    [ -z "$CURRENT" ] || rm -rf "$CURRENT"
    CURRENT=
    CURRENT_PID=
}
cleanup_all() { cleanup_current; rm -rf "$TEST_ROOT"; }
trap cleanup_all EXIT HUP INT TERM
mkdir -p "$TEST_ROOT"

replace_once() {
    FILE=$1; OLD=$2; NEW=$3
    [ "$(grep -F -c "$OLD" "$FILE")" -eq 1 ] || { echo "replacement count failed: $OLD" >&2; exit 1; }
    ESCAPED_OLD=$(printf '%s' "$OLD" | sed 's/[|&]/\\&/g')
    ESCAPED_NEW=$(printf '%s' "$NEW" | sed 's/[|&]/\\&/g')
    sed -i "s|$ESCAPED_OLD|$ESCAPED_NEW|" "$FILE"
}

new_fixture() {
    NAME=$1
    cleanup_current
    CURRENT="$TEST_ROOT/$NAME"
    USB="$CURRENT/usb"
    BIN="$CURRENT/bin"
    NVM="$CURRENT/nvm"
    TARGET="$CURRENT/target"
    PROC_FIXTURE="$CURRENT/proc-fixture"
    SYS="$CURRENT/sys"
    DEV="$CURRENT/dev"
    mkdir -p "$USB" "$BIN" "$NVM" "$TARGET/application/bin" "$SYS/block/sda" "$DEV" "$PROC_FIXTURE"
    NVM_SOURCE="$CURRENT/mtdblock12"
    : > "$NVM_SOURCE"
    ln -s "$NVM" "$CURRENT/media-link"
    cp -a "$SOURCE/payload/." "$USB/"

    # Host-native stand-in; the committed ARM ELF is never executed.
    cp /bin/sleep "$USB/geminitop-proofd"
    chmod 755 "$USB/geminitop-proofd"
    BINARY_HASH=$(sha256sum "$USB/geminitop-proofd" | awk '{print $1}')
    BINARY_SIZE=$(stat -c '%s' "$USB/geminitop-proofd")
    printf 'fixture launcher\n' > "$TARGET/application/bin/Launcher"
    LAUNCHER_HASH=$(sha256sum "$TARGET/application/bin/Launcher" | awk '{print $1}')
    LAUNCHER_SIZE=$(stat -c '%s' "$TARGET/application/bin/Launcher")
    printf 'gemini_8368_XU_evb_def_config\n' > "$TARGET/application/appinfo.rc"
    printf '4.9.217\n' > "$PROC_FIXTURE/osrelease"
    printf 'dev: size erasesize name\nmtd12: 00800000 00020000 "nvm"\n' > "$PROC_FIXTURE/mtd"
    printf '1\n' > "$SYS/block/sda/removable"
    : > "$DEV/sda1"
    printf '/dev/sda1 %s vfat rw,dirsync 0 0\n%s %s yaffs2 rw,relatime 0 0\n' "$USB" "$NVM_SOURCE" "$NVM" > "$PROC_FIXTURE/mounts"
    printf '31 20 0:31 / %s rw,relatime - vfat /dev/sda1 rw\n32 20 0:32 / %s rw,relatime - yaffs2 %s rw\n' "$USB" "$NVM" "$NVM_SOURCE" > "$PROC_FIXTURE/mountinfo"
    printf '100000|%s\n' "$NVM" > "$CURRENT/df-spec"
    export DF_SPEC="$CURRENT/df-spec"
    export NVM_SOURCE

    for COMMAND in awk chmod dd dirname grep mkdir mv pwd readlink rm rmdir sed sha256sum sleep stat wc; do
        ln -s "$(command -v "$COMMAND")" "$BIN/$COMMAND"
    done
    cat > "$BIN/df" <<'EOF'
#!/bin/sh
IFS='|' read -r FREE MOUNTPOINT < "$DF_SPEC" || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '%s 200000 100000 %s 50%% %s\n' "$NVM_SOURCE" "$FREE" "$MOUNTPOINT"
EOF
    chmod 755 "$BIN/df"
    cat > "$BIN/heartbeat_writer" <<'EOF'
#!/bin/sh
PID=$1
HASH=$2
SEQUENCE=0
while [ -e "/proc/$PID/exe" ]; do
    printf '%s\n' schema=1 process=geminitop-proofd version=w176-stage4b-proofd-v1 \
        "pid=$PID" started=1 state=running "heartbeat_sequence=$SEQUENCE" \
        "binary_sha256=$HASH" > /tmp/.geminitop-proofd.status.tmp || exit 1
    /bin/mv /tmp/.geminitop-proofd.status.tmp /tmp/geminitop-proofd.status || exit 1
    SEQUENCE=$((SEQUENCE + 1))
    sleep 1
done
printf '%s\n' schema=1 process=geminitop-proofd version=w176-stage4b-proofd-v1 \
    "pid=$PID" started=1 state=stopped "heartbeat_sequence=$SEQUENCE" \
    "binary_sha256=$HASH" > /tmp/.geminitop-proofd.status.tmp || exit 1
/bin/mv /tmp/.geminitop-proofd.status.tmp /tmp/geminitop-proofd.status
EOF
    chmod 755 "$BIN/heartbeat_writer"

    for FILE in gemn_auto.sh mount_guard.sh common.sh; do
        replace_once "$USB/$FILE" 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' "PATH=$BIN"
    done
    replace_once "$USB/mount_guard.sh" 'MOUNTS_FILE=/proc/mounts' "MOUNTS_FILE=$PROC_FIXTURE/mounts"
    replace_once "$USB/mount_guard.sh" 'SYS_BLOCK_ROOT=/sys/block' "SYS_BLOCK_ROOT=$SYS/block"
    replace_once "$USB/mount_guard.sh" 'DEV_ROOT=/dev' "DEV_ROOT=$DEV"
    replace_once "$USB/mount_guard.sh" 'DEVICE_TEST=-b' 'DEVICE_TEST=-e'
    replace_once "$USB/common.sh" 'MOUNTS_FILE=/proc/mounts' "MOUNTS_FILE=$PROC_FIXTURE/mounts"
    replace_once "$USB/common.sh" 'MOUNTINFO_FILE=/proc/self/mountinfo' "MOUNTINFO_FILE=$PROC_FIXTURE/mountinfo"
    replace_once "$USB/common.sh" 'MTD_FILE=/proc/mtd' "MTD_FILE=$PROC_FIXTURE/mtd"
    replace_once "$USB/common.sh" 'KERNEL_RELEASE_FILE=/proc/sys/kernel/osrelease' "KERNEL_RELEASE_FILE=$PROC_FIXTURE/osrelease"
    replace_once "$USB/common.sh" 'NVM_ROOT=/media/flash/nvm' "NVM_ROOT=$NVM"
    replace_once "$USB/common.sh" 'MEDIA_LINK_PATH=/media' "MEDIA_LINK_PATH=$CURRENT/media-link"
    replace_once "$USB/common.sh" 'EXPECTED_MEDIA_LINK=/tmp/sp/media/' "EXPECTED_MEDIA_LINK=$NVM"
    replace_once "$USB/common.sh" 'EXPECTED_NVM_CANONICAL=/tmp/sp/media/flash/nvm' "EXPECTED_NVM_CANONICAL=$NVM"
    replace_once "$USB/common.sh" 'EXPECTED_NVM_SOURCE=/dev/mtdblock12' "EXPECTED_NVM_SOURCE=$NVM_SOURCE"
    replace_once "$USB/common.sh" 'NVM_SOURCE_TEST=-b' 'NVM_SOURCE_TEST=-e'
    replace_once "$USB/common.sh" 'LAUNCHER_PATH=/application/bin/Launcher' "LAUNCHER_PATH=$TARGET/application/bin/Launcher"
    replace_once "$USB/common.sh" 'APPINFO_PATH=/application/appinfo.rc' "APPINFO_PATH=$TARGET/application/appinfo.rc"
    replace_once "$USB/common.sh" 'EXPECTED_LAUNCHER_SHA256=5ff83ac9cf9fb2ccb21c90c9b2edb2952581153ec5d5ab4a299787243e1e0c56' "EXPECTED_LAUNCHER_SHA256=$LAUNCHER_HASH"
    replace_once "$USB/common.sh" 'EXPECTED_LAUNCHER_SIZE=92416' "EXPECTED_LAUNCHER_SIZE=$LAUNCHER_SIZE"
    replace_once "$USB/common.sh" 'EXPECTED_BINARY_SHA256=57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6' "EXPECTED_BINARY_SHA256=$BINARY_HASH"
    replace_once "$USB/common.sh" 'EXPECTED_BINARY_SIZE=5556' "EXPECTED_BINARY_SIZE=$BINARY_SIZE"
    replace_once "$USB/install.sh" 'exec "$DEST_BINARY" "$EXPECTED_BINARY_SHA256"' 'exec "$DEST_BINARY" 300'
    replace_once "$USB/install.sh" 'PROCESS_PID=$!' 'PROCESS_PID=$!\nheartbeat_writer "$PROCESS_PID" "$EXPECTED_BINARY_SHA256" &'
    STOCK_LAUNCHER_BEFORE=$(sha256sum "$TARGET/application/bin/Launcher" | awk '{print $1}')
    STOCK_APPINFO_BEFORE=$(sha256sum "$TARGET/application/appinfo.rc" | awk '{print $1}')
}

arm_install() { printf 'stage4b_install=1\n' > "$USB/ARM_STAGE4B_INSTALL"; }
arm_verify() { printf 'usb_removed_and_reinserted=1\n' > "$USB/ARM_STAGE4B_VERIFY_AFTER_REMOVAL"; }
arm_uninstall() { printf 'stage4b_uninstall=1\n' > "$USB/ARM_STAGE4B_UNINSTALL"; }
run_payload() { (cd "$USB" && /bin/sh ./gemn_auto.sh); }
assert_no_complete() { [ ! -e "$USB/$1/COMPLETE" ]; }
record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS %s\n' "$1"; }

install_clean() {
    arm_install
    if ! run_payload >/dev/null; then
        [ ! -f "$USB/stage4b-install/ERRORS.txt" ] || sed -n '1,12p' "$USB/stage4b-install/ERRORS.txt" >&2
        exit 1
    fi
    grep -q '^status=COMPLETE$' "$USB/stage4b-install/STATUS.txt"
    CURRENT_PID=$(awk -F= '$1=="pid" {print $2}' "$USB/stage4b-install/PROCESS.txt")
    kill -0 "$CURRENT_PID"
}

new_fixture clean
install_clean
mv "$USB" "$CURRENT/usb-detached"
USB="$CURRENT/usb-detached"
sleep 3
kill -0 "$CURRENT_PID"
mv "$USB" "$CURRENT/usb"
USB="$CURRENT/usb"
arm_verify
run_payload >/dev/null
grep -q '^result=PASS$' "$USB/stage4b-verify-after-removal/RESULT.txt"
arm_uninstall
run_payload >/dev/null
grep -q '^result=PASS$' "$USB/stage4b-uninstall/RESULT.txt"
[ -d "$NVM/geminitop" ] && [ ! -e "$NVM/geminitop/w176" ]
[ -f /tmp/geminitop-proofd.status ]
[ "$(sha256sum "$TARGET/application/bin/Launcher" | awk '{print $1}')" = "$STOCK_LAUNCHER_BEFORE" ]
[ "$(sha256sum "$TARGET/application/appinfo.rc" | awk '{print $1}')" = "$STOCK_APPINFO_BEFORE" ]
[ ! -e "$NVM/bin" ] && [ ! -e "$NVM/lib" ]
CURRENT_PID=
record_pass clean_install_remove_verify_term_uninstall

new_fixture wrong-target
printf '4.9.999\n' > "$PROC_FIXTURE/osrelease"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass wrong_target

new_fixture wrong-nvm
sed -i 's/ yaffs2 / ext4 /' "$PROC_FIXTURE/mounts"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass wrong_nvm_mount

new_fixture wrong-nvm-source
sed -i "s|$NVM_SOURCE $NVM yaffs2|$CURRENT/unrelated $NVM yaffs2|" "$PROC_FIXTURE/mounts"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass wrong_nvm_source

new_fixture nested-mount
printf '%s %s/geminitop yaffs2 rw,relatime 0 0\n' "$NVM_SOURCE" "$NVM" >> "$PROC_FIXTURE/mounts"
printf '33 32 0:33 / %s/geminitop rw,relatime - yaffs2 %s rw\n' "$NVM" "$NVM_SOURCE" >> "$PROC_FIXTURE/mountinfo"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass nested_covering_mount

new_fixture same-device-bind
sed -i "s|32 20 0:32 / $NVM|32 20 0:32 /other-subtree $NVM|" "$PROC_FIXTURE/mountinfo"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass same_device_bind

new_fixture hash-producer-error
rm "$BIN/sha256sum"
cat > "$BIN/sha256sum" <<'EOF'
#!/bin/sh
/usr/bin/sha256sum "$@"
exit 7
EOF
chmod 755 "$BIN/sha256sum"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass hash_valid_output_nonzero_exit

new_fixture kernel-producer-error
rm "$BIN/dd"
cat > "$BIN/dd" <<'EOF'
#!/bin/sh
case "$*" in *osrelease*) printf '4.9.217\n'; exit 7 ;; *) exec /bin/dd "$@" ;; esac
EOF
chmod 755 "$BIN/dd"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass kernel_valid_output_nonzero_exit

new_fixture df-producer-error
cat > "$BIN/df" <<'EOF'
#!/bin/sh
IFS='|' read -r FREE MOUNTPOINT < "$DF_SPEC" || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '%s 200000 100000 %s 50%% %s\n' "$NVM_SOURCE" "$FREE" "$MOUNTPOINT"
exit 7
EOF
chmod 755 "$BIN/df"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass df_valid_output_nonzero_exit

new_fixture readonly-nvm
sed -i 's/ yaffs2 rw,/ yaffs2 ro,/' "$PROC_FIXTURE/mounts"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass readonly_nvm

new_fixture low-space
printf '8|%s\n' "$NVM" > "$CURRENT/df-spec"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass insufficient_space

new_fixture existing-directory
mkdir "$NVM/geminitop"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -d "$NVM/geminitop" ]
record_pass existing_directory_collision

new_fixture existing-file
printf conflict > "$NVM/geminitop"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ "$(cat "$NVM/geminitop")" = conflict ]
record_pass existing_file_collision

new_fixture source-hash
printf x >> "$USB/geminitop-proofd"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ ! -e "$NVM/geminitop" ]
record_pass source_hash_mismatch

new_fixture destination-hash
rm "$BIN/sha256sum"
cat > "$BIN/sha256sum" <<'EOF'
#!/bin/sh
case "$1" in */.w176-stage4b-installing/geminitop-proofd.tmp) printf '%064d  %s\n' 0 "$1" ;; *) exec /usr/bin/sha256sum "$@" ;; esac
EOF
chmod 755 "$BIN/sha256sum"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -d "$NVM/geminitop/.w176-stage4b-installing" ]
record_pass destination_hash_mismatch

new_fixture copy-interruption
rm "$BIN/dd"
cat > "$BIN/dd" <<'EOF'
#!/bin/sh
case "$*" in bs=4096*) exit 1 ;; *) exec /bin/dd "$@" ;; esac
EOF
chmod 755 "$BIN/dd"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -d "$NVM/geminitop/.w176-stage4b-installing" ]
record_pass copy_interruption

new_fixture launch-failure
replace_once "$USB/install.sh" 'exec "$DEST_BINARY" 300' 'exec /bin/false'
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
record_pass launch_failure

new_fixture heartbeat-failure
printf '#!/bin/sh\nexit 0\n' > "$BIN/heartbeat_writer"
chmod 755 "$BIN/heartbeat_writer"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
record_pass heartbeat_failure

new_fixture late-result-hash-failure
rm "$BIN/sha256sum"
cat > "$BIN/sha256sum" <<'EOF'
#!/bin/sh
case "$1" in TARGET.txt) /usr/bin/sha256sum "$@"; exit 7 ;; *) exec /usr/bin/sha256sum "$@" ;; esac
EOF
chmod 755 "$BIN/sha256sum"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-install
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
CURRENT_PID=$(awk -F= '$1=="pid" {print $2}' "$USB/stage4b-install/PROCESS.txt")
kill -0 "$CURRENT_PID"
record_pass late_usb_result_hash_failure_preserves_nvm_and_run

new_fixture pid-identity
install_clean
sed -i 's/^start_time=.*/start_time=1/' "$USB/stage4b-install/PROCESS.txt"
sleep 2
arm_verify
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-verify-after-removal
record_pass pid_identity_change

new_fixture tampered-install-transaction
install_clean
sed -i 's/^start_time=.*/start_time=1/' "$USB/stage4b-install/PROCESS.txt"
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
kill -0 "$CURRENT_PID"
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
record_pass tampered_install_transaction_blocks_uninstall

new_fixture mismatched-heartbeat-pid
install_clean
sed -i 's/^pid=.*/pid=999999/' /tmp/geminitop-proofd.status
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
kill -0 "$CURRENT_PID"
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
record_pass heartbeat_pid_mismatch_blocks_term

new_fixture malformed-heartbeat
install_clean
printf 'foreign\n' > /tmp/geminitop-proofd.status
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
kill -0 "$CURRENT_PID"
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
record_pass malformed_heartbeat_blocks_term

new_fixture missing-original-process
install_clean
kill -TERM "$CURRENT_PID"
sleep 2
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
CURRENT_PID=
record_pass absent_original_process_requires_manual_review

new_fixture symlink-in-install
install_clean
rm "$NVM/geminitop/w176/manifest.txt"
ln -s "$TARGET/application/appinfo.rc" "$NVM/geminitop/w176/manifest.txt"
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
kill -0 "$CURRENT_PID"
[ -L "$NVM/geminitop/w176/manifest.txt" ]
record_pass symlink_in_install_blocks_uninstall

new_fixture unexpected-extra
install_clean
printf unexpected > "$NVM/geminitop/w176/foreign.file"
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
[ "$(cat "$NVM/geminitop/w176/foreign.file")" = unexpected ]
kill -0 "$CURRENT_PID"
record_pass unexpected_extra_blocks_uninstall

new_fixture partial-delete
install_clean
rm "$BIN/rm"
cat > "$BIN/rm" <<'EOF'
#!/bin/sh
case "$1" in */w176/geminitop-proofd) exit 7 ;; *) exec /bin/rm "$@" ;; esac
EOF
chmod 755 "$BIN/rm"
arm_uninstall
if run_payload >/dev/null 2>&1; then exit 1; fi
assert_no_complete stage4b-uninstall
[ ! -e "$NVM/geminitop/w176/manifest.txt" ]
[ -f "$NVM/geminitop/w176/geminitop-proofd" ]
[ -d "$NVM/geminitop/w176" ]
record_pass partial_delete_stops_without_directory_cleanup

new_fixture wrong-usb
OTHER="$CURRENT/other"
mkdir "$OTHER"
sed -i "s|/dev/sda1 $USB |/dev/sda1 $OTHER |" "$PROC_FIXTURE/mounts"
arm_install
if run_payload >/dev/null 2>&1; then exit 1; fi
[ ! -e "$USB/stage4b-install" ]
record_pass usb_failure

printf 'schema=1\nresult=PASS\ntests=%s\n' "$PASS_COUNT"
