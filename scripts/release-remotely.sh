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

# The build server's own `gh` is logged into an internal host (git.netflix.net)
# and can't create a github.com release, so we forward a local token instead of
# relying on the server's gh auth. gh reads GH_TOKEN for github.com directly,
# which also satisfies release.sh's `gh auth status --hostname github.com` gate.
# Name the var holding it via GH_TOKEN_VAR (default: GITHUB_TOKEN_PEPITO).
GH_TOKEN_VAR=${GH_TOKEN_VAR:-GITHUB_TOKEN_PEPITO}
REMOTE_GH_TOKEN=${!GH_TOKEN_VAR:-}
if [[ -z "$REMOTE_GH_TOKEN" ]]; then
    echo "error: \$$GH_TOKEN_VAR is not set in this shell — the remote gh has no" >&2
    echo "usable github.com auth, so release.sh would fail there. Export a token" >&2
    echo "with repo scope (or set GH_TOKEN_VAR to the var that holds one)." >&2
    exit 1
fi
# Both variants build as UNOFFICIAL now; they're told apart by the LINEAGE_BUILD
# suffix in the filename (Mi8937 vs Mi8937_gapps), not the releasetype — see the
# zip-selection filter below.
BUILDTYPE_TAG=UNOFFICIAL

RSYNC_COMMON=(-aP --human-readable)

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
ALL_ZIPS=$(ssh "$TARGET" -- "ls '$REMOTE_ROOT/$PRODUCT_OUT'"/lineage-*-"$DATE_TAG"-"$BUILDTYPE_TAG"-*.zip 2>/dev/null || true)

# Both variants are UNOFFICIAL, so filter on the _gapps suffix: gapps zips end
# in -Mi8937_gapps.zip, vanilla in -Mi8937.zip. grep -v drops the gapps ones for
# a vanilla release and vice versa.
if $GAPPS; then
    VARIANT_DESC="gapps (_gapps)"
    MATCHES=$(grep '_gapps\.zip$' <<< "$ALL_ZIPS" || true)
else
    VARIANT_DESC="vanilla (non-_gapps)"
    MATCHES=$(grep -v '_gapps\.zip$' <<< "$ALL_ZIPS" | grep . || true)
fi
NUM_MATCHES=$(grep -c . <<< "$MATCHES" || true)

if [[ "$NUM_MATCHES" -eq 0 ]]; then
    echo "error: no $BUILDTYPE_TAG $VARIANT_DESC zip matching today's date ($DATE_TAG) in $REMOTE_ROOT/$PRODUCT_OUT on $TARGET" >&2
    exit 1
elif [[ "$NUM_MATCHES" -gt 1 ]]; then
    echo "error: multiple $BUILDTYPE_TAG $VARIANT_DESC zips matching today's date ($DATE_TAG) in $REMOTE_ROOT/$PRODUCT_OUT on $TARGET:" >&2
    echo "$MATCHES" >&2
    exit 1
fi
ZIP="$MATCHES"
echo "Using remote zip: $ZIP"

# -tt: release.sh prompts for confirmation, which needs a real tty over ssh.
#
# Two env vars are forwarded to the remote gh:
#   GH_TOKEN — auth for github.com (see the GH_TOKEN_VAR note above).
#   GH_HOST=github.com — the build server's gh is a Netflix fork that DEFAULTS
#     to git.netflix.net. release.sh's `gh release create --repo owner/name`
#     passes no --hostname, so without this it resolves owner/name against the
#     internal host and times out. GH_HOST forces github.com as the default.
# Both go to the remote command's environment (not typed, so not in the server's
# shell history); the token is briefly visible in the process list on both ends
# — acceptable for a single-user LAN build server. `export` (not a var prefix)
# so they cover the whole `cd && release.sh` chain; %q-quote the token for
# safe transport.
# --edl-only: r1 publishes the EDL bundle only — no OTA zip asset and no OTA
# JSON, so there's nothing to fetch back or commit afterward.
ssh -tt "$TARGET" -- \
    "export GH_HOST=github.com GH_TOKEN=$(printf '%q' "$REMOTE_GH_TOKEN"); cd '$REMOTE_ROOT' && ./scripts/release.sh --edl-only $(printf '%q' "$ZIP")"
