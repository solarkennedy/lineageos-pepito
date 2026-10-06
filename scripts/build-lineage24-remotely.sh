#!/bin/bash
set -euo pipefail
# pipefail matters here: several rsync calls below are piped through `tail`
# to keep their output volume down (rsync -P's per-file progress redraws can
# produce enormous output on a tree this size, which was getting the whole
# background build task killed outright -- not a real network/rsync failure,
# just too much text). Without pipefail, `rsync ... | tail` would hide a
# real rsync failure behind tail's always-zero exit status.
#
# LineageOS 24.0 (Android 17) build on the build server, GIT-DRIVEN.
#
# Unlike 23.2 (build-lineage23-remotely.sh rsyncs netbook4's working tree to
# the server), there is no 24.0 tree on netbook4. The server's
# ~/android/lineage-24 is a plain repo checkout, and the source of truth is
# what is PUSHED to the forks. So a change must be committed + pushed before it
# builds. This script:
#   1. mirrors this landing-repo checkout (lineageos24.0 branch) to the server,
#      installs manifests/pepito.xml as the tree's local manifest, and links the
#      tree's scripts/ to it;
#   2. `repo sync`s the projects from that manifest (all projects with
#      SYNC_ALL=1, none with SKIP_SYNC=1);
#   3. runs scripts/build-lineage24.sh there, detached, and polls it;
#   4. stages flash images remotely (prepare-flash.sh) and fetches them to
#      LOCAL_FLASH_DIR for flashing from netbook4.

TARGET=${TARGET:-10.0.2.43}
REMOTE_ROOT=${REMOTE_ROOT:-/home/kyle/android/lineage-24}
LANDING_ROOT=/home/kyle/Projects/lineageos-pepito-24
# netbook4 has no 24.0 tree; this directory only holds flashable images plus the
# device-constant firehose loaders / rawprogram XMLs (seeded from 23.2 below).
LOCAL_FLASH_DIR=${LOCAL_FLASH_DIR:-/home/kyle/android/lineage-24/flash-staging}
PRODUCT_OUT=out/target/product/Mi8937
DEVICE_LABEL=${DEVICE_LABEL:-Mi8937/pepito A17}

# Push a phone notification. Never fatal: this script runs under `set -e`, and
# a build that succeeded must not be reported as failed just because ntfy.sh is
# unreachable.
notify() {
    /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" || true
}

RSYNC_COMMON=(-aP --human-readable)

# The images prepare-flash.sh produces per build (desparsified system/vendor,
# signed boot/recovery, and the Magisk-patched boot variant). The firehose
# loaders and rawprogram XMLs (pvg100_/pvg100e_-prefixed) are device-constant
# and seeded once into LOCAL_FLASH_DIR, not re-fetched.
STAGE_FILTERS=(
    --include='boot.bin'
    --include='boot-magisk.bin'
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

ssh "$TARGET" -- "test -d '$REMOTE_ROOT/.repo'" || {
    echo "!! $TARGET:$REMOTE_ROOT is not a repo checkout. Create it first:" >&2
    echo "   repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs \\" >&2
    echo "     --reference=/home/kyle/android/lineage-23 && repo sync" >&2
    exit 1
}

# Memory preflight. Soong's analysis pass alone peaks at ~31 GB RSS, and
# Stellaris16 has no headroom once something else bloats: on 2026-09-24 an
# Xorg leak (30 GB after 18 h up) left soong_build OOM-killed with the only
# clue a bare "Killed" in out/error.log. Check MemAvailable + free swap before
# syncing. PEPITO_BUILD_MIN_GB=0 bypasses the check.
MIN_GB="${PEPITO_BUILD_MIN_GB:-40}"
read -r AVAIL_GB SWAP_GB HOG <<<"$(ssh "$TARGET" -- '
    awk "/MemAvailable/{a=\$2} /SwapFree/{s=\$2} END{printf \"%d %d \", a/1048576, s/1048576}" /proc/meminfo
    ps -eo rss,comm --sort=-rss | awk "NR==2{printf \"%s(%dGB)\", \$2, \$1/1048576}"')"
if (( AVAIL_GB + SWAP_GB < MIN_GB )); then
    echo "!! $TARGET has ${AVAIL_GB} GB available + ${SWAP_GB} GB free swap (< ${MIN_GB} GB)." >&2
    echo "   Largest process: $HOG. Soong needs ~31 GB; the build would be OOM-killed." >&2
    echo "   Free memory first (a leaking Xorg = restart the GNOME session), or" >&2
    echo "   PEPITO_BUILD_MIN_GB=0 to override." >&2
    exit 1
fi
echo "==> $TARGET memory: ${AVAIL_GB} GB available + ${SWAP_GB} GB swap (largest: $HOG)"

# Hold a sleep inhibitor on the server for the whole sync+build+fetch run;
# Stellaris16 idle-suspends (suspend-then-hibernate) and ssh/rsync traffic
# does not count as user activity. -tt ties the remote inhibitor's lifetime
# to this ssh process, which the EXIT trap kills.
ssh -tt "$TARGET" -- systemd-inhibit --what=sleep:idle --who=build-lineage24-remotely \
    --why='remote lineage build in progress' sleep 21600 >/dev/null 2>&1 &
INHIBIT_SSH_PID=$!
trap 'kill "$INHIBIT_SSH_PID" 2>/dev/null || true' EXIT

# The pinned Magisk APK is gitignored (prebuilts/*.apk), so a fresh checkout of
# this branch lacks it and prepare-flash.sh silently skips boot-magisk.bin.
# Seed it from the 23.2 landing checkout before mirroring.
if ! compgen -G "$LANDING_ROOT/prebuilts/Magisk-*.apk" >/dev/null; then
    for apk in /home/kyle/Projects/lineageos-pepito/prebuilts/Magisk-*.apk; do
        [[ -f "$apk" ]] && cp -p "$apk" "$LANDING_ROOT/prebuilts/" && echo "==> Seeded $(basename "$apk") into $LANDING_ROOT/prebuilts/"
    done
fi

# 1. Landing repo: mirror this checkout (scripts, plans, manifest), then make it
#    the tree's local manifest and its scripts/. A worktree's .git is a FILE,
#    hence both excludes.
echo "==> Mirroring landing repo ($LANDING_ROOT, branch $(git -C "$LANDING_ROOT" branch --show-current))..."
ssh "$TARGET" -- "mkdir -p '$LANDING_ROOT'"
rsync "${RSYNC_COMMON[@]}" --delete --exclude='/.git/' --exclude='/.git' \
    "$LANDING_ROOT"/ "$TARGET:$LANDING_ROOT"/ | tail -5
ssh "$TARGET" -- "set -e
    mkdir -p '$REMOTE_ROOT/.repo/local_manifests'
    cp '$LANDING_ROOT/manifests/pepito.xml' '$REMOTE_ROOT/.repo/local_manifests/roomservice.xml'
    ln -sfn '$LANDING_ROOT/scripts' '$REMOTE_ROOT/scripts'"

# 2. Source: repo sync. Default = only the projects our manifest names (forks,
#    blobs, FaceUnlock, launcher), so upstream lineage-24.0 does not move under
#    a test build; upstream 01e1033 broke the build on 2026-10-05 that way.
#    SYNC_ALL=1 also pulls upstream. --force-sync lets a project switch remotes
#    when the manifest moves it to/from a fork.
if [[ ${SKIP_SYNC:-0} == 1 ]]; then
    echo "==> SKIP_SYNC=1: building the server tree as it is."
else
    if [[ ${SYNC_ALL:-0} == 1 ]]; then
        SYNC_PROJECTS=""
        echo "==> repo sync (ALL projects, incl. upstream lineage-24.0)..."
    else
        SYNC_PROJECTS=$(python3 - "$LANDING_ROOT/manifests/pepito.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
print(" ".join(p.get("path") for p in ET.parse(sys.argv[1]).getroot().iter("project")))
EOF
)
        echo "==> repo sync (manifest projects only; SYNC_ALL=1 for upstream too)..."
    fi
    ssh "$TARGET" -- "set -o pipefail; cd '$REMOTE_ROOT' && ~/bin/repo sync -j6 --no-tags --force-sync --retry-fetches=5 $SYNC_PROJECTS 2>&1 \
        | grep -v 'new version of repo\|upgrade soon\|cp .*/repo/repo\|hooks is different' | tail -5"
fi
echo "==> Building these heads:"
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && for p in $(python3 -c "
import xml.etree.ElementTree as ET
print(' '.join(p.get('path') for p in ET.parse('$LANDING_ROOT/manifests/pepito.xml').getroot().iter('project')))"); do
        printf '    %-32s %s\n' \"\$p\" \"\$(git -C \"\$p\" log -1 --format='%h %s' | cut -c1-60)\"; done"

# Untracked inputs no repo carries. Fail fast here instead of 10 minutes into
# soong analysis (2026-10-05: missing launcher cert stopped the build).
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && test -f vendor/lineage-priv/keys/keys.mk \
    && test -f device/xiaomi/Mi8937/security/pepitolauncher2/pepitolauncher2.pk8" || {
    echo "!! Signing keys missing in $TARGET:$REMOTE_ROOT. Copy them from the 23.2 tree there:" >&2
    echo "   rsync -a ~/android/lineage-23/vendor/lineage-priv/ ~/android/lineage-24/vendor/lineage-priv/" >&2
    echo "   cp -p ~/android/lineage-23/device/xiaomi/Mi8937/security/pepitolauncher2/pepitolauncher2.{pk8,x509.pem} \\" >&2
    echo "         ~/android/lineage-24/device/xiaomi/Mi8937/security/pepitolauncher2/" >&2
    exit 1
}

# 3. Build. NOTE: do NOT wipe KERNEL_OBJ here. A cold (freshly-wiped)
# out-of-tree kernel build intermittently loses a kbuild parallel-ordering race
# under -j: the generic-y wrapper arch/arm64/include/generated/uapi/asm/types.h
# isn't produced by the asm-generic step before scripts/mod compiles, giving a
# hard "fatal error: 'asm/types.h' file not found" on
# scripts/mod/devicetable-offsets. Keeping KERNEL_OBJ warm across builds means
# the generated headers persist, so the race can't recur.
#
# Run detached (setsid + nohup, all three std streams redirected) instead of
# one long blocking `ssh -tt` session: a single ssh session held open for a
# full build (an hour-plus) was repeatedly getting the 23.2 script killed
# partway through (observed losing a 94%-complete build) with no error of its
# own. Many short poll connections every 30s survive it, and the remote build
# keeps running even if this wrapper gets killed.
BUILD_LOG="/tmp/pepito24-build-$$.log"
BUILD_EXITCODE="/tmp/pepito24-build-$$.exitcode"
BUILD_START=$SECONDS
# Forward PEPITO_SERIAL_CONSOLE to the remote build when set locally, so
#   PEPITO_SERIAL_CONSOLE=true ./scripts/build-lineage24-remotely.sh
# bakes console=ttyMSM0 + SysRq into boot.img (BoardConfigCommon.mk) for a
# serial-console debug build. Empty/unset by default = normal quiet release.
REMOTE_ENV="TARGET_PEPITO_KEYMASTER_DHSECAPP_DIAGNOSTIC=true TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true"
[[ -n "${PEPITO_SERIAL_CONSOLE:-}" ]] && REMOTE_ENV="$REMOTE_ENV PEPITO_SERIAL_CONSOLE=$(printf '%q' "$PEPITO_SERIAL_CONSOLE")"
[[ -n "${LINEAGE_BUILD_DATE:-}" ]] && REMOTE_ENV="$REMOTE_ENV LINEAGE_BUILD_DATE=$(printf '%q' "$LINEAGE_BUILD_DATE")"
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && rm -f '$BUILD_LOG' '$BUILD_EXITCODE' && setsid nohup bash -c '$REMOTE_ENV ./scripts/build-lineage24.sh $REMOTE_BUILD_ARGS_STR; echo \$? > $BUILD_EXITCODE' > '$BUILD_LOG' 2>&1 < /dev/null &"

echo "==> Build launched detached on $TARGET (remote log: $BUILD_LOG). Polling..."
while ! ssh "$TARGET" -- "test -f '$BUILD_EXITCODE'" 2>/dev/null; do
    sleep 30
    ssh "$TARGET" -- "tail -n 3 '$BUILD_LOG' 2>/dev/null" || true
done

BUILD_EXIT=$(ssh "$TARGET" -- "cat '$BUILD_EXITCODE'")
BUILD_MINS=$(( (SECONDS - BUILD_START) / 60 ))
if [[ "$BUILD_EXIT" != "0" ]]; then
    # out/error.log holds the real FAILED: entries; the console tail is mostly
    # D8 duplicate-class warnings.
    ERR_LINES=$(ssh "$TARGET" -- "grep -E '^FAILED:|error:' '$REMOTE_ROOT/out/error.log' | sed 's/\x1b\[[0-9;]*m//g' | head -n 6" 2>/dev/null || true)
    notify "Build FAILED — $DEVICE_LABEL" \
"exit $BUILD_EXIT after ${BUILD_MINS}m
log: $TARGET:$BUILD_LOG

${ERR_LINES:-(no error lines matched; see log)}"
    echo "==> Remote build FAILED (exit $BUILD_EXIT). FAILED entries from out/error.log:" >&2
    ssh "$TARGET" -- "grep -A12 '^FAILED:' '$REMOTE_ROOT/out/error.log' | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^Command:\|^Outputs:' | head -n 80" >&2 || true
    echo "==> Last 40 lines of $BUILD_LOG:" >&2
    ssh "$TARGET" -- "tail -n 40 '$BUILD_LOG'" >&2
    exit 1
fi
BUILD_ZIP=$(ssh "$TARGET" -- "ls -1t '$REMOTE_ROOT/$PRODUCT_OUT'/lineage-24.0-*.zip 2>/dev/null | head -n 1" 2>/dev/null || true)
notify "Build SUCCESS — $DEVICE_LABEL" \
"built in ${BUILD_MINS}m on $TARGET
${BUILD_ZIP:+artifact: $(basename "$BUILD_ZIP")
}fetching product-out next"
echo "==> Remote build succeeded."

# 4. Flash images.
echo "==> Staging flash images remotely (prepare-flash.sh)..."
ssh "$TARGET" -- "cd '$REMOTE_ROOT' && ./scripts/prepare-flash.sh"

echo "==> Fetching staged flash images to $LOCAL_FLASH_DIR..."
mkdir -p "$LOCAL_FLASH_DIR"
# Seed the device-constant flash inputs once, from the 23.2 staging dir (they
# are hardware-specific, not Android-version-specific).
for f in pvg100_firehose.elf pvg100e_firehose.elf rawprogram0.pvg100.xml rawprogram0.pvg100e.xml; do
    [[ -e "$LOCAL_FLASH_DIR/$f" ]] || cp -p "/home/kyle/android/lineage-23/flash-staging/$f" "$LOCAL_FLASH_DIR/$f"
done
ln -sfn "$LANDING_ROOT/scripts/flash-staging.sh" "$LOCAL_FLASH_DIR/flash-staging.sh"
rsync "${RSYNC_COMMON[@]}" "${STAGE_FILTERS[@]}" \
    "$TARGET:$REMOTE_ROOT/flash-staging"/ "$LOCAL_FLASH_DIR"/ | tail -20
echo "==> Ready to flash: $LOCAL_FLASH_DIR/flash-staging.sh"
