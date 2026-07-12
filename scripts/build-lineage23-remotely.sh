#!/bin/bash
set -eu

TARGET=${TARGET:-10.0.2.43}
LOCAL_ROOT=${LOCAL_ROOT:-/home/kyle/android/lineage-23}
REMOTE_ROOT=${REMOTE_ROOT:-/home/kyle/android/lineage-23}
PRODUCT_OUT=out/target/product/Mi8937

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
    --exclude='/flash-staging/'
    --exclude='/pstore/'
    --exclude='/tombstones/'
    --exclude='/lineage-23.2-*.zip'
    --exclude='/*.log'
    --exclude='/boot.*.log'
    --exclude='/logcat*.txt'
    --exclude='/serial*.log'
    --exclude='/working-clock*.log'
)

OUTPUT_FILTERS=(
    --prune-empty-dirs
    --include='*/'
    --include='*.img'
    --include='*.zip'
    --include='android-info.txt'
    --include='build_fingerprint*.txt'
    --include='build_thumbprint*.txt'
    --include='installed-files*.txt'
    --include='installed-files*.json'
    --include='kernel'
    --exclude='*'
)

REMOTE_BUILD_ARGS=()
for arg in "$@"; do
    REMOTE_BUILD_ARGS+=("$(printf '%q' "$arg")")
done
REMOTE_BUILD_ARGS_STR="${REMOTE_BUILD_ARGS[*]:-}"

/home/kyle/.bin/wakeonlan-stellaris16

ssh "$TARGET" -- "mkdir -p '$REMOTE_ROOT'"

rsync "${RSYNC_COMMON[@]}" "${SOURCE_DELETE[@]}" "${SOURCE_EXCLUDES[@]}" \
    "$LOCAL_ROOT"/ "$TARGET:$REMOTE_ROOT"/

ssh "$TARGET" -- 'rm -rf /home/kyle/android/lineage-23/out/target/product/Mi8937/obj/KERNEL_OBJ'
ssh "$TARGET" -- "cd '$REMOTE_ROOT' &&  TARGET_PEPITO_KEYMASTER_DHSECAPP_DIAGNOSTIC=true TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true ./scripts/build-lineage23.sh $REMOTE_BUILD_ARGS_STR"

mkdir -p "$LOCAL_ROOT/$PRODUCT_OUT"
rsync "${RSYNC_COMMON[@]}" "${OUTPUT_FILTERS[@]}" \
    "$TARGET:$REMOTE_ROOT/$PRODUCT_OUT"/ "$LOCAL_ROOT/$PRODUCT_OUT"/

#ssh 10.0.2.43 -- systemctl suspend
