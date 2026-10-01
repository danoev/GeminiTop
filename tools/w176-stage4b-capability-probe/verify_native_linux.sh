#!/usr/bin/env bash
# Host-only verification harness. Never run on a RoadTop or vehicle system.
set -u
set -o pipefail
export LC_ALL=C

CANDIDATE=f02c89e91eb2d5f962ce485669bba91e89eab37b
OLD=465e7bd3809b3165bbe4df2d46c53f6cc25ea8ed
ART=${1:?provide an artifact directory outside the candidate worktree}
WORKFLOW_REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 1
RUN_TEMP=${RUNNER_TEMP:-/tmp}
mkdir -p "$ART" || exit 1
ART=$(cd -P "$ART" && pwd -P) || exit 1
FAILED=0

finish() {
    local prior=$?
    trap - EXIT
    [ "$prior" -eq 0 ] || FAILED=1
    printf 'candidate=%s\nworkflow_revision=%s\nresult=%s\n' \
        "$CANDIDATE" "$(git -C "$WORKFLOW_REPO" rev-parse HEAD 2>/dev/null || printf UNKNOWN)" \
        "$([ "$FAILED" -eq 0 ] && printf PASS || printf NO-GO)" >> "$ART/summary.txt"
    (cd "$ART" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 sha256sum) > "$ART/SHA256SUMS" || FAILED=1
    exit "$FAILED"
}
trap finish EXIT

run_logged() {
    local name=$1 command rc
    shift
    printf -v command '%q ' "$@"
    printf '%s\n' "$command" > "$ART/$name.command"
    "$@" > "$ART/$name.stdout" 2> "$ART/$name.stderr"
    rc=$?
    printf '%s\n' "$rc" > "$ART/$name.exit"
    {
        printf 'COMMAND: %s\nSTDOUT:\n' "$command"
        sed -n '1,$p' "$ART/$name.stdout"
        printf 'STDERR:\n'
        sed -n '1,$p' "$ART/$name.stderr"
        printf 'EXIT_STATUS=%s\n' "$rc"
    } > "$ART/$name.log"
    [ "$rc" -eq 0 ] || FAILED=1
}

blocked() {
    local name=$1 reason=$2
    printf '%s\n' "NOT RUN: $reason" > "$ART/$name.command"
    : > "$ART/$name.stdout"
    printf '%s\n' "$reason" > "$ART/$name.stderr"
    printf '125\n' > "$ART/$name.exit"
    printf 'NOT RUN: %s\nEXIT_STATUS=125\n' "$reason" > "$ART/$name.log"
    FAILED=1
}

check_unittest() {
    local name=$1 expected=$2 log run pass fail error skip
    log="$ART/$name.log"
    run=$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$log" | tail -1)
    pass=$(grep -Ec '\.\.\. ok$' "$log" || true)
    fail=$(grep -Ec '\.\.\. FAIL$' "$log" || true)
    error=$(grep -Ec '\.\.\. ERROR$' "$log" || true)
    skip=$(grep -Ec '\.\.\. skipped ' "$log" || true)
    printf '%s RUN=%s PASS=%s FAIL=%s ERROR=%s SKIP=%s\n' \
        "$name" "${run:-UNKNOWN}" "$pass" "$fail" "$error" "$skip" >> "$ART/summary.txt"
    [ "$(cat "$ART/$name.exit")" = 0 ] &&
        [ "$run" = "$expected" ] && [ "$pass" = "$expected" ] &&
        [ "$fail" = 0 ] && [ "$error" = 0 ] && [ "$skip" = 0 ] &&
        grep -Fxq OK "$log" || FAILED=1
}

check_lines() {
    local name=$1 prefix=$2 expected_count=$3
    shift 3
    local observed expected
    observed=$(grep -c "^$prefix" "$ART/$name.log" || true)
    [ "$observed" = "$expected_count" ] || FAILED=1
    for expected in "$@"; do
        [ "$(grep -Fxc "$expected" "$ART/$name.log" || true)" = 1 ] || FAILED=1
    done
    printf '%s semantic_lines=%s expected=%s\n' \
        "$name" "$observed" "$expected_count" >> "$ART/summary.txt"
}

run_logged environment bash -c '
    set -e
    uname -a
    cat /etc/os-release
    python3 --version
    docker version
    git --version
    printf "GITHUB_RUN_ID=%s\\nGITHUB_REPOSITORY=%s\\n" \
        "${GITHUB_RUN_ID:-NOT_GITHUB_ACTIONS}" "${GITHUB_REPOSITORY:-NOT_GITHUB_ACTIONS}"
'
cp "$ART/environment.log" "$ART/environment.txt"
[ "$(uname -s)" = Linux ] || { printf 'Linux required\n' >> "$ART/summary.txt"; exit 1; }

CANDIDATE_PARENT=$(mktemp -d "$RUN_TEMP/geminitop-f02c.XXXXXX") || exit 1
CANDIDATE_DIR=$CANDIDATE_PARENT/candidate
run_logged exact-candidate bash -c '
    repo=$1; candidate=$2; destination=$3
    git -C "$repo" cat-file -e "$candidate^{commit}" || exit 1
    git -C "$repo" worktree add --detach "$destination" "$candidate" || exit 1
    actual=$(git -C "$destination" rev-parse HEAD) || exit 1
    printf "workflow_revision=%s\ncandidate_required=%s\ncandidate_actual=%s\n" \
        "$(git -C "$repo" rev-parse HEAD)" "$candidate" "$actual"
    [ "$actual" = "$candidate" ]
' sh "$WORKFLOW_REPO" "$CANDIDATE" "$CANDIDATE_DIR"
cp "$ART/exact-candidate.log" "$ART/exact-candidate.txt"
[ "$(cat "$ART/exact-candidate.exit")" = 0 ] || exit 1
cd "$CANDIDATE_DIR" || exit 1
export PYTHONPYCACHEPREFIX=$CANDIDATE_PARENT/pycache

run_logged proc-version-observation bash -c '
    stat -c "%F|%s|%f" /proc/version || exit 1
    test -f /proc/version || exit 1
    printf "test -f: PASS\n"
    bytes=$(wc -c < /proc/version) || exit 1
    printf "wc -c: %s\n" "$bytes"
    cat /proc/version || exit 1
    [ "$(stat -c "%F" /proc/version)" = "regular empty file" ] || exit 1
    [ "$(stat -c "%s" /proc/version)" = 0 ] || exit 1
    [ "$bytes" -gt 0 ]
'
cp "$ART/proc-version-observation.log" "$ART/proc-version-observation.txt"

run_logged proc-version-regression python3 -m unittest discover \
    -s tools/w176-stage4b-capability-probe -p test_preflight.py \
    -k real_proc_version_frozen_rejection_and_current_acceptance -v
check_unittest proc-version-regression 1
run_logged proc-self-regression python3 -m unittest discover \
    -s tools/w176-stage4b-capability-probe -p test_preflight.py \
    -k real_proc_self_mount_views_keep_descriptor_identity -v
check_unittest proc-self-regression 1
run_logged preflight-full python3 -m unittest discover \
    -s tools/w176-stage4b-capability-probe -v
check_unittest preflight-full 69

run_logged capability-image-build docker build --pull=false \
    -f "$WORKFLOW_REPO/tools/w176-stage4b-capability-probe/Test.Dockerfile" \
    -t geminitop-w176-capability-native:f02c89e "$CANDIDATE_DIR"
if [ "$(cat "$ART/capability-image-build.exit")" = 0 ]; then
    run_logged capability-image-identity docker image inspect \
        --format '{{.Id}} {{json .RepoDigests}}' geminitop-w176-capability-native:f02c89e
    run_logged capability-native-mount docker run --rm --privileged --network none \
        -v "$CANDIDATE_DIR:/src:ro" geminitop-w176-capability-native:f02c89e \
        sh -c 'dd if=/dev/zero of=/tmp/capability-fat.img bs=1M count=32 status=none &&
               mkfs.vfat -F 16 /tmp/capability-fat.img >/dev/null &&
               /bin/sh /src/tools/w176-stage4b-capability-probe/test_linux_mounts.sh \
                   < /tmp/capability-fat.img'
    check_lines capability-native-mount native 3 \
        'native FAT effective mount: PASS' \
        'native exact stacked tmpfs: REJECT' \
        'native deeper covering tmpfs: REJECT'
else
    blocked capability-image-identity 'capability test image build failed'
    blocked capability-native-mount 'capability test image build failed'
fi

run_logged stage4a-image-build docker build --pull=false \
    -f "$CANDIDATE_DIR/tools/w176-stage4-topology/Test.Dockerfile" \
    -t geminitop-w176-stage4a-native:f02c89e "$CANDIDATE_DIR"
if [ "$(cat "$ART/stage4a-image-build.exit")" = 0 ]; then
    run_logged stage4a-image-identity docker image inspect \
        --format '{{.Id}} {{json .RepoDigests}}' geminitop-w176-stage4a-native:f02c89e
    run_logged stage4a-native docker run --rm --privileged --network none \
        -v "$CANDIDATE_DIR:/repo:ro" geminitop-w176-stage4a-native:f02c89e
    check_unittest stage4a-native 83
    check_lines stage4a-native PASS 8 \
        'PASS real_proc_self_mounts_and_squashfs' \
        'PASS normal_proc_mounts_symlink' \
        'PASS unrelated_component_boundary_nested_mount' \
        'PASS real_nested_tmpfs_rejected' \
        'PASS real_nested_readonly_mount_rejected' \
        'PASS nested_same_device_bind_mount_rejected' \
        'PASS restored_mount_topology' \
        'PASS real_sysfs_class_link_layout'
else
    blocked stage4a-image-identity 'Stage-4A test image build failed'
    blocked stage4a-native 'Stage-4A test image build failed'
fi

run_logged static-gates bash -c '
    candidate=$1
    [ "$(git rev-parse HEAD)" = "$candidate" ] || exit 1
    for script in tools/w176-stage4b-capability-probe/payload/*.sh; do
        sh -n "$script" && dash -n "$script" || exit 1
    done
    python3 -m py_compile tools/w176-stage4b-capability-probe/analyze.py \
        tools/w176-stage4b-capability-probe/test_preflight.py || exit 1
    git diff --check HEAD^ HEAD && git diff --check || exit 1
    [ -z "$(git status --porcelain=v1)" ] || exit 1
    changed=$(git diff-tree --no-commit-id --name-only -r HEAD | sort)
    expected=$(printf "%s\\n" \
        docs/platform/w176-stage4b-capability-physical-attempt.md \
        tools/w176-stage4b-capability-probe/payload/capability_probe.sh \
        tools/w176-stage4b-capability-probe/test_preflight.py | sort)
    [ "$changed" = "$expected" ] || exit 1
    ! git ls-tree -r --name-only HEAD | grep -Fx \
        tools/w176-stage4b-capability-probe/payload/ARM_STAGE4B_CAPABILITY_PREFLIGHT || exit 1
    printf "candidate implementation files:\\n%s\\n" "$changed"
    printf "live marker: ABSENT; raw target files/executable in candidate diff: NONE\\n"
' sh "$CANDIDATE"

run_logged payload-hashes bash -c '
    check() {
        path=$1; expected_size=$2; expected_hash=$3
        size=$(stat -c "%s" "$path") || return 1
        hash=$(sha256sum "$path" | cut -d " " -f 1) || return 1
        printf "%s|%s|%s\\n" "$path" "$size" "$hash"
        [ "$size" = "$expected_size" ] && [ "$hash" = "$expected_hash" ]
    }
    base=tools/w176-stage4b-capability-probe/payload
    check "$base/gemn_auto.sh" 602 3cbe48aed6188606d701c774b19251e659ae31dae8942359496cdb78f1235c44 || exit 1
    check "$base/mount_guard.sh" 5536 7401bc34c9e85b0091f5d994169949e5af915cec87034c0bd97e236f83e4ad5c || exit 1
    check "$base/root_mount_guard.sh" 1632 acfebdbf0dbdbe5135d453a3e41b8829c49fa8510117b35c960bebd9fe154d06 || exit 1
    check "$base/capability_probe.sh" 17806 ed8c94eba43dcfe3d8248ac9b9df1738615329fc14cb846a29ed85bede530b5a || exit 1
    check tools/w176-stage4b-capability-probe/analyze.py 28530 4f8a0b939445636630e707d3fe97f51a0570d5bda317cef41d7c3bf800890566
'
cp "$ART/payload-hashes.log" "$ART/payload-hashes.txt"

printf 'old_frozen_collector=%s\nsealed_runtime_execution=NOT_TESTED\nexecution_high=OPEN\n' \
    "$OLD" >> "$ART/summary.txt"
exit "$FAILED"
