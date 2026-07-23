#!/bin/bash
set -euo pipefail
# pipefail matters here: several rsync calls below are piped through `tail`
# to keep their output volume down (rsync -P's per-file progress redraws can
# produce enormous output on a tree this size, which was getting the whole
# background build task killed outright -- not a real network/rsync failure,
# just too much text). Without pipefail, `rsync ... | tail` would hide a
# real rsync failure behind tail's always-zero exit status.

TARGET=${TARGET:-10.0.2.43}
LOCAL_ROOT=${LOCAL_ROOT:-/home/kyle/android/lineage-23}
REMOTE_ROOT=${REMOTE_ROOT:-/home/kyle/android/lineage-23}
PRODUCT_OUT=out/target/product/Mi8937
DEVICE_LABEL=${DEVICE_LABEL:-Mi8937/pepito}

# Push a phone notification. Never fatal: this script runs under `set -e`, and
# a build that succeeded must not be reported as failed just because ntfy.sh is
# unreachable.
notify() {
    /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" || true
}

RSYNC_COMMON=(-aP --human-readable)
SOURCE_DELETE=()
if [[ ${DELETE_REMOTE_STALE:-0} == 1 ]]; then
    SOURCE_DELETE=(--delete)
fi

SOURCE_EXCLUDES=(
    --exclude='/.repo/'
    --exclude='**/.git/'
    --exclude='**/.git'
    --exclude='/out/'
    --exclude='/.claude/'
    --exclude='/.crush/'
    --exclude='/flash-recovery/'
    --exclude='/flash-stock/'
    --exclude='/flash-staging/'
    --exclude='/pstore/'
    --exclude='/tombstones/'
    --exclude='/lineage-23.2-*.zip'
    --exclude='/*.log'
    --exclude='/boot.*.log'
    --exclude='/logcat*.txt'
    --exclude='/serial*.log'
    --exclude='/working-clock*.log'
    # In-tree kernel build artifacts. If a plain `make` (no O=) is ever run in a
    # kernel source dir, it leaves .config/include/config/include/generated etc.
    # in-tree. Syncing those to the builder makes kbuild's prepare3 guard abort
    # the O= build ("<srctree> is not clean, please run 'make mrproper'"), and
    # the stale generated headers cause spurious "asm/types.h not found" errors.
    # Never sync them; the builder generates its own under out/.../KERNEL_OBJ.
    --exclude='/kernel/**/.config'
    --exclude='/kernel/**/.config.old'
    --exclude='/kernel/**/include/config/'
    --exclude='/kernel/**/include/generated/'
    --exclude='/kernel/**/include/generated'
    --exclude='/kernel/**/arch/*/include/generated/'
    --exclude='/kernel/**/.tmp_versions/'
    --exclude='/kernel/**/*.o'
    --exclude='/kernel/**/*.o.d'
    --exclude='/kernel/**/*.cmd'
    --exclude='/kernel/**/.*.cmd'
)

# The four images prepare-flash.sh produces per build (desparsified system/
# vendor, signed boot/recovery). pepito_firehose.elf and rawprogram0.xml are
# device-constant, already present locally, and not re-fetched.
STAGE_FILTERS=(
    --include='boot.bin'
    --include='recovery.bin'
    --include='system.bin'
    --include='vendor.bin'
    --exclude='*'
)

REMOTE_BUILD_ARGS=()
for arg in "$@"; do
    REMOTE_BUILD_ARGS+=("$(printf '%q' "$arg")")
done
REMOTE_BUILD_ARGS_STR="${REMOTE_BUILD_ARGS[*]:-}"

ssh "$TARGET" -- "mkdir -p '$REMOTE_ROOT'"

# Hold a sleep inhibitor on the server for the whole sync+build+fetch run;
# Stellaris16 idle-suspends (suspend-then-hibernate) and ssh/rsync traffic
# does not count as user activity. -tt ties the remote inhibitor's lifetime
# to this ssh process, which the EXIT trap kills.
ssh -tt "$TARGET" -- systemd-inhibit --what=sleep:idle --who=build-lineage23-remotely \
    --why='remote lineage build in progress' sleep 21600 >/dev/null 2>&1 &
INHIBIT_SSH_PID=$!
trap 'kill "$INHIBIT_SSH_PID" 2>/dev/null || true' EXIT

# scripts/ and PLAN*.md at the tree root are symlinks into the landing repo
# (~/Projects/lineageos-pepito). The server mirrors the same /home/kyle
# layout, so mirror the (small) landing repo first and the symlinks resolve
# there exactly as they do locally. Do NOT be tempted by --copy-unsafe-links
# on the tree sync instead: the tree holds other absolute symlinks it would
# materialize into the transfer, incl. a 32 GB stock-backup link.
git -C ~/android/lineage-23/packages/apps/PepitoLauncher2 pull
LANDING_ROOT=/home/kyle/Projects/lineageos-pepito
ssh "$TARGET" -- "mkdir -p '$LANDING_ROOT'"
rsync "${RSYNC_COMMON[@]}" --exclude='/.git/' \
    "$LANDING_ROOT"/ "$TARGET:$LANDING_ROOT"/ | tail -20

echo "==> Syncing main tree..."
rsync "${RSYNC_COMMON[@]}" "${SOURCE_DELETE[@]}" "${SOURCE_EXCLUDES[@]}" \
    "$LOCAL_ROOT"/ "$TARGET:$REMOTE_ROOT"/ | tail -20

# NOTE: do NOT wipe KERNEL_OBJ here. A cold (freshly-wiped) out-of-tree kernel
# build intermittently loses a kbuild parallel-ordering race under -j: the
# generic-y wrapper arch/arm64/include/generated/uapi/asm/types.h isn't produced
# by the asm-generic step before scripts/mod compiles, giving a hard
# "fatal error: 'asm/types.h' file not found" on scripts/mod/devicetable-offsets.
# Keeping KERNEL_OBJ warm across builds means the generated headers persist, so
# the race can't recur. kbuild tracks source deps, so incremental kernel builds
# still pick up changes correctly. If you ever need a truly clean kernel, wipe
# KERNEL_OBJ manually (one cold build may re-roll the race).
#
# Run detached (setsid + nohup, all three std streams redirected) instead of
# one long blocking `ssh -tt` session: a single ssh session held open for a
# full build (an hour-plus) was repeatedly getting this whole script killed
# partway through (observed losing a 94%-complete build) with no error of its
# own -- whatever the trigger, many short poll connections every 30s survive
# it, and the remote build now keeps running even if one of those polls (or
# this whole wrapper) gets killed.
BUILD_LOG="/tmp/pepito-build-$$.log"
BUILD_EXITCODE="/tmp/pepito-build-$$.exitcode"
BUILD_START=$SECONDS
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && rm -f '$BUILD_LOG' '$BUILD_EXITCODE' && setsid nohup bash -c 'TARGET_PEPITO_KEYMASTER_DHSECAPP_DIAGNOSTIC=true TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true ./scripts/build-lineage23.sh $REMOTE_BUILD_ARGS_STR; echo \$? > $BUILD_EXITCODE' > '$BUILD_LOG' 2>&1 < /dev/null &"

echo "==> Build launched detached on $TARGET (remote log: $BUILD_LOG). Polling..."
while ! ssh "$TARGET" -- "test -f '$BUILD_EXITCODE'" 2>/dev/null; do
    sleep 30
    ssh "$TARGET" -- "tail -n 3 '$BUILD_LOG' 2>/dev/null" || true
done

BUILD_EXIT=$(ssh "$TARGET" -- "cat '$BUILD_EXITCODE'")
BUILD_MINS=$(( (SECONDS - BUILD_START) / 60 ))
if [[ "$BUILD_EXIT" != "0" ]]; then
    # Error lines for the phone; the full 150-line tail still goes to the terminal.
    ERR_LINES=$(ssh "$TARGET" -- "grep -iE 'error|fatal|FAILED' '$BUILD_LOG' | tail -n 6" 2>/dev/null || true)
    notify "Build FAILED — $DEVICE_LABEL" \
"exit $BUILD_EXIT after ${BUILD_MINS}m
log: $TARGET:$BUILD_LOG

${ERR_LINES:-(no error lines matched; see log)}"
    echo "==> Remote build FAILED (exit $BUILD_EXIT). Last 150 lines of $BUILD_LOG:" >&2
    ssh "$TARGET" -- "tail -n 150 '$BUILD_LOG'" >&2
    exit 1
fi
BUILD_ZIP=$(ssh "$TARGET" -- "ls -1t '$REMOTE_ROOT/$PRODUCT_OUT'/lineage-23.2-*.zip 2>/dev/null | head -n 1" 2>/dev/null || true)
notify "Build SUCCESS — $DEVICE_LABEL" \
"built in ${BUILD_MINS}m on $TARGET
${BUILD_ZIP:+artifact: $(basename "$BUILD_ZIP")
}fetching product-out next"
echo "==> Remote build succeeded."

echo "==> Staging flash images remotely (prepare-flash.sh)..."
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && ./scripts/prepare-flash.sh"

echo "==> Fetching staged flash images..."
mkdir -p "$LOCAL_ROOT/flash-staging"
rsync "${RSYNC_COMMON[@]}" "${STAGE_FILTERS[@]}" \
    "$TARGET:$REMOTE_ROOT/flash-staging"/ "$LOCAL_ROOT/flash-staging"/ | tail -20

#ssh 10.0.2.43 -- systemctl suspend
