#!/bin/bash
# release-remotely.sh — run scripts/release.sh on the build server instead of
# locally: the zip and flash-staging/ are already there after a remote build
# (build-lineage23-remotely.sh fetches them down too, but release.sh's own
# xz compression of the EDL bundle is the slow part — better to run it on
# the build server's CPU than the laptop's).
#
# The remote landing-repo mirror has no .git (build-lineage23-remotely.sh
# excludes it), so release.sh degrades gracefully there: it still cuts the
# GitHub release, but only writes <device>.json locally on the server. This
# script fetches that file back and does the commit/push from here, where
# the real clone lives.
#
# Takes one optional flag, --gapps, and otherwise no arguments: assumes you're
# releasing the same day you built, so it looks for a zip matching today's
# date in the remote out/target/product/Mi8937/ rather than guessing "newest"
# — and fails loudly if that's not exactly one file. Then runs release.sh with
# no extra flags (its interactive confirmation prompt still applies, over an
# allocated tty).
#
# --gapps selects the lineage_Mi8937_gapps build instead of the vanilla one.
# Both variants share out/target/product/Mi8937/ (same PRODUCT_DEVICE) and can
# coexist there on the same day since build-lineage23.sh tags them with
# different RELEASE_TYPE values (embedded in the filename) specifically so
# they don't collide — --gapps just picks which one to release when both are
# present.
#
#   ./scripts/release-remotely.sh
#   ./scripts/release-remotely.sh --gapps
#
set -euo pipefail
# pipefail matters: the rsync calls below pipe through `tail` to keep output
# volume down (see build-lineage23-remotely.sh for why); without pipefail a
# real rsync failure would hide behind tail's always-zero exit status.

GAPPS=false
if [[ "${1:-}" == "--gapps" ]]; then
    GAPPS=true
    shift
fi
if [[ $# -gt 0 ]]; then
    echo "error: release-remotely.sh takes no arguments other than --gapps" >&2
    exit 1
fi

TARGET=${TARGET:-10.0.2.43}
REMOTE_ROOT=${REMOTE_ROOT:-/home/kyle/android/lineage-23}
LANDING_ROOT=/home/kyle/Projects/lineageos-pepito
PRODUCT_OUT=out/target/product/Mi8937
# Must match build-lineage23.sh's RELEASE_TYPE choices exactly.
BUILDTYPE_TAG=UNOFFICIAL
if $GAPPS; then
    BUILDTYPE_TAG=SNAPSHOT
fi

RSYNC_COMMON=(-aP --human-readable)

/home/kyle/.bin/wakeonlan-stellaris16

# Same sleep-inhibit pattern as build-lineage23-remotely.sh: the xz pass over
# the EDL bundle alone can run several minutes, and Stellaris16 idle-suspends
# regardless of ssh/rsync traffic.
ssh -tt "$TARGET" -- systemd-inhibit --what=sleep:idle --who=release-remotely \
    --why='remote release in progress' sleep 3600 >/dev/null 2>&1 &
INHIBIT_SSH_PID=$!
trap 'kill "$INHIBIT_SSH_PID" 2>/dev/null || true' EXIT

# release.sh may have changed locally since the last remote build; make sure
# the server has the current copy (still excluding .git — see header note).
ssh "$TARGET" -- "mkdir -p '$LANDING_ROOT'"
rsync "${RSYNC_COMMON[@]}" --exclude='/.git/' \
    "$LANDING_ROOT"/ "$TARGET:$LANDING_ROOT"/ | tail -20

DATE_TAG=$(date +%Y%m%d)
MATCHES=$(ssh "$TARGET" -- "ls '$REMOTE_ROOT/$PRODUCT_OUT'"/lineage-*-"$DATE_TAG"-"$BUILDTYPE_TAG"-*.zip 2>/dev/null || true)
NUM_MATCHES=$(grep -c . <<< "$MATCHES" || true)

if [[ "$NUM_MATCHES" -eq 0 ]]; then
    echo "error: no $BUILDTYPE_TAG zip matching today's date ($DATE_TAG) in $REMOTE_ROOT/$PRODUCT_OUT on $TARGET" >&2
    exit 1
elif [[ "$NUM_MATCHES" -gt 1 ]]; then
    echo "error: multiple $BUILDTYPE_TAG zips matching today's date ($DATE_TAG) in $REMOTE_ROOT/$PRODUCT_OUT on $TARGET:" >&2
    echo "$MATCHES" >&2
    exit 1
fi
ZIP="$MATCHES"
echo "Using remote zip: $ZIP"

# -tt: release.sh prompts for confirmation, which needs a real tty over ssh.
ssh -tt "$TARGET" -- "cd '$REMOTE_ROOT' && ./scripts/release.sh $(printf '%q' "$ZIP")"

echo "==> Fetching regenerated OTA JSON from the server..."
rsync "${RSYNC_COMMON[@]}" --include='*.json' --exclude='*' \
    "$TARGET:$LANDING_ROOT"/ "$LANDING_ROOT"/ | tail -20

CHANGED=()
while IFS= read -r -d '' f; do
    CHANGED+=("$f")
done < <(git -C "$LANDING_ROOT" status --porcelain -z -- '*.json')

if [[ ${#CHANGED[@]} -eq 0 ]]; then
    echo "no OTA JSON changes to commit"
else
    git -C "$LANDING_ROOT" add -- '*.json'
    git -C "$LANDING_ROOT" commit -m "ota: update from remote release ($TARGET)"
    git -C "$LANDING_ROOT" push origin HEAD
fi
