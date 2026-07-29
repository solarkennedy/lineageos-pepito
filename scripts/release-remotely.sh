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
#   ./scripts/release-remotely.sh                # full: OTA zip + JSON + EDL bundle
#   ./scripts/release-remotely.sh --gapps        # the gapps variant
#   ./scripts/release-remotely.sh --edl-only     # EDL bundle only (no OTA)
#   ./scripts/release-remotely.sh --notes-file ~/Projects/lineageos-pepito/.release-notes.md
#
# --notes-file FILE sets the GitHub release body (must live under the landing
# repo so it's rsynced to the server). Usually driven by release-all.sh.
#
set -euo pipefail
# pipefail matters: the rsync calls below pipe through `tail` to keep output
# volume down (see build-lineage23-remotely.sh for why); without pipefail a
# real rsync failure would hide behind tail's always-zero exit status.

GAPPS=false
NOTES_FILE=""
TAG_OVERRIDE=""
EDL_ONLY=false          # default: full release (OTA zip + JSON feed + EDL bundle)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gapps) GAPPS=true; shift ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --tag) TAG_OVERRIDE="$2"; shift 2 ;;
        --edl-only) EDL_ONLY=true; shift ;;
        *) echo "error: release-remotely.sh: unknown arg '$1' (accepts --gapps, --notes-file FILE, --tag TAG, --edl-only)" >&2; exit 1 ;;
    esac
done

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
# Vanilla is UNOFFICIAL, gapps is SNAPSHOT (the OTA channel separator — see
# build-lineage23.sh). The releasetype is in the zip filename, so it already
# isolates the variant's zip; the _gapps filter below is belt-and-suspenders.
BUILDTYPE_TAG=UNOFFICIAL
if $GAPPS; then
    BUILDTYPE_TAG=SNAPSHOT
fi

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

# UTC, not local: LineageOS stamps the zip with $(date -u +%Y%m%d)
# (vendor/lineage/config/version.mk). Matching on local time silently fails to
# find a just-built zip whenever local and UTC dates differ — i.e. every evening
# west of UTC.
DATE_TAG=$(date -u +%Y%m%d)
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

# --yes: this is unattended automation (usually driven by release-all.sh), so
# skip release.sh's interactive confirmation. No prompt means no tty is needed,
# so we drop the old `ssh -tt` too (plain ssh still streams remote output back).
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
# Mode: by default this is a FULL release — release.sh publishes the OTA zip,
# the pepito.json OTA feed, and the EDL bundle. --edl-only drops the OTA zip and
# JSON (EDL bundle only). In full mode release.sh writes pepito.json on the
# server (which has no .git), so we fetch it back and commit it here afterward.
#
# --notes-file: optional path to the release-body markdown. It must live under
# LANDING_ROOT so the rsync above already copied it to the server at the same
# absolute path (LANDING_ROOT is identical on both ends). release.sh only
# applies the body when it CREATES a release, so on a same-day second variant
# (uploaded into the existing release) it's a harmless no-op.
NOTES_ARG=""
if [[ -n "$NOTES_FILE" ]]; then
    case "$NOTES_FILE" in
        "$LANDING_ROOT"/*) : ;;
        *) echo "error: --notes-file must be under $LANDING_ROOT (so it syncs to the server); got '$NOTES_FILE'" >&2; exit 1 ;;
    esac
    [[ -f "$NOTES_FILE" ]] || { echo "error: notes file not found: $NOTES_FILE" >&2; exit 1; }
    NOTES_ARG="--notes-file $(printf '%q' "$NOTES_FILE")"
fi

# --tag forces the GitHub release tag (default: release.sh derives it from the
# zip's own UTC date). release-all.sh passes it so the release tag, the
# changelog date, and the source-repo tags are all the same code even if the
# build straddles UTC midnight.
TAG_ARG=""
[[ -n "$TAG_OVERRIDE" ]] && TAG_ARG="--tag $(printf '%q' "$TAG_OVERRIDE")"

EDL_ONLY_ARG=""
$EDL_ONLY && EDL_ONLY_ARG="--edl-only"

ssh "$TARGET" -- \
    "export GH_HOST=github.com GH_TOKEN=$(printf '%q' "$REMOTE_GH_TOKEN"); cd '$REMOTE_ROOT' && ./scripts/release.sh $EDL_ONLY_ARG --yes $NOTES_ARG $TAG_ARG $(printf '%q' "$ZIP")"

# In full mode release.sh regenerated pepito.json on the server, where the
# landing mirror has no .git. Fetch it back and commit it from here, where the
# real clone lives, so the Updater feed the device polls is actually updated.
if ! $EDL_ONLY; then
    echo "==> Fetching regenerated OTA JSON from the server..."
    rsync "${RSYNC_COMMON[@]}" --include='*.json' --exclude='*' \
        "$TARGET:$LANDING_ROOT"/ "$LANDING_ROOT"/ | tail -20

    if [[ -n "$(git -C "$LANDING_ROOT" status --porcelain -- '*.json')" ]]; then
        git -C "$LANDING_ROOT" add -- '*.json'
        git -C "$LANDING_ROOT" commit -m "ota: ${TAG_OVERRIDE:-release} $($GAPPS && echo gapps || echo vanilla)"
        git -C "$LANDING_ROOT" push origin HEAD
    else
        echo "no OTA JSON change to commit"
    fi
fi
