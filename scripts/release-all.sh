#!/usr/bin/env bash
# release-all.sh — one command to cut a full pepito release from the netbook.
#
#   1. generate the changelog across every pepito repo (scripts/gen-changelog.sh),
#      commit + push CHANGELOG.md to the landing repo, and stage it as the
#      release body (.release-notes.md);
#   2. build the VANILLA variant remotely, then release it (OTA zip + pepito.json
#      Updater feed + EDL bundle) with that changelog as the release body;
#   3. build the GAPPS variant remotely, then release it the same way;
#      (vanilla is UNOFFICIAL, gapps is SNAPSHOT — the two OTA channels in the
#       shared pepito.json; the Updater offers each phone only its own channel)
#   4. tag every pepito repo pepito-23.2-<version> and push the tags, so the next
#      run's changelog anchors here.
#
# Vanilla is built+released BEFORE gapps is built, on purpose: the two variants
# share out/target/product/Mi8937/ and each build's installclean wipes the
# other's zip, so the release must happen while its zip still exists.
#
# IDEMPOTENT — safe to just re-run after an intermittent failure. Each step is
# either a no-op or skipped when already done: the changelog replaces (not
# duplicates) its dated section; a variant whose EDL bundle is already on the
# GitHub release is skipped (build + upload); release upload uses --clobber; and
# tagging skips tags that already exist. Runs unattended — no confirmation
# prompt (release.sh is invoked with --yes).
#
#   ./scripts/release-all.sh                    # version = today's UTC date code
#   ./scripts/release-all.sh --version 20260727 # force the date code
#   ./scripts/release-all.sh --dry-run          # changelog only; no build/release/tag
#   ./scripts/release-all.sh --no-tag           # skip the repo-tagging step
#
# The date code (UTC YYYYMMDD) is the single release identity: the GitHub
# release tag (forced via --tag), the CHANGELOG heading, and the source-repo
# tags pepito-23.2-<date> all use it.
#
# Runs on the netbook (it drives the build server over ssh via the remote
# helpers). Needs $GITHUB_TOKEN_PEPITO (or $GH_TOKEN_VAR) set — same as
# release-remotely.sh — for the GitHub release.
set -euo pipefail

# Hardcoded (env-overridable), matching release-remotely.sh and gen-changelog.sh.
# NOT derived from BASH_SOURCE: scripts/ is symlinked into the AOSP tree, so
# invoking via that symlink (~/android/lineage-23/scripts/...) would resolve
# LANDING_ROOT up to the tree root — which isn't a git repo — and misdirect the
# notes file. Fixed paths make the script work from any cwd or symlink.
LANDING_ROOT=${LANDING_ROOT:-/home/kyle/Projects/lineageos-pepito}
SCRIPT_DIR="$LANDING_ROOT/scripts"
TREE=${TREE:-/home/kyle/android/lineage-23}
LAUNCHER=${LAUNCHER:-/home/kyle/Projects/PepitoLauncher2}
TAG_PREFIX="pepito-23.2-"
NOTES_FILE="$LANDING_ROOT/.release-notes.md"

VERSION=""
DRY_RUN=false
DO_TAG=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-tag)  DO_TAG=false; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
        *) echo "release-all.sh: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

# repos to tag at the end (path<TAB>preferred-remote). Changelog repo set lives
# in gen-changelog.sh; this list is only for tagging/pushing.
TAG_REPOS=(
  "$TREE/kernel/xiaomi/msm8937	solarkennedy"
  "$TREE/device/xiaomi/Mi8937	solarkennedy"
  "$TREE/device/xiaomi/mithorium-common	solarkennedy"
  "$TREE/vendor/xiaomi	origin"
  "$TREE/bootable/recovery	solarkennedy"
  "$TREE/frameworks/base	solarkennedy"
  "$TREE/lineage-sdk	solarkennedy"
  "$TREE/packages/apps/LineageParts	solarkennedy"
  "$TREE/hardware/interfaces	solarkennedy"
  "$TREE/hardware/qcom-caf/bt	solarkennedy"
  "$TREE/system/core	solarkennedy"
  "$TREE/vendor/lineage	solarkennedy"
  "$LAUNCHER	origin"
  "$LANDING_ROOT	origin"
)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# --- preflight --------------------------------------------------------------
GH_TOKEN_VAR=${GH_TOKEN_VAR:-GITHUB_TOKEN_PEPITO}
if [[ -z "${!GH_TOKEN_VAR:-}" ]]; then
    echo "error: \$$GH_TOKEN_VAR is not set — release-remotely.sh needs it for the GitHub release." >&2
    exit 1
fi
TOKEN="${!GH_TOKEN_VAR}"
TARGET=${TARGET:-10.0.2.43}                       # build server (queried for skip checks)
REPO=${REPO:-solarkennedy/lineageos-pepito}
GH_REMOTE_BIN=${GH_REMOTE_BIN:-/home/kyle/.bin/gh.com}

# variant_released REGEX — 0 if the release tagged $VERSION already carries an
# asset whose name matches REGEX. Queried on the build server (that's where the
# github.com-capable gh + token live). FAIL-OPEN: any ssh/gh error returns 1, so
# we fall through and (re)build — release.sh's `gh --clobber` makes a redundant
# re-release harmless. This is the idempotency shortcut: on a re-run after an
# intermittent failure, an already-published variant is skipped instead of
# rebuilt+reuploaded.
variant_released() {
    local names
    names="$(ssh "$TARGET" -- \
        "export GH_HOST=github.com GH_TOKEN=$(printf '%q' "$TOKEN"); \
         $GH_REMOTE_BIN release view $(printf '%q' "$VERSION") --repo $(printf '%q' "$REPO") \
         --json assets --jq '.assets[].name' 2>/dev/null" 2>/dev/null)" || return 1
    grep -qE "$1" <<<"$names"
}

# --- 1. changelog -----------------------------------------------------------
say "Generating changelog"
VER_ARG=(); [[ -n "$VERSION" ]] && VER_ARG=(--version "$VERSION")

# Preview via --stdout first: writes nothing, and lets us pin the version so the
# write pass below can't derive a different one.
SECTION="$("$SCRIPT_DIR/gen-changelog.sh" --stdout "${VER_ARG[@]}")"
VERSION="$(sed -n 's/^## \([0-9]\{8\}\) .*/\1/p' <<<"$SECTION" | head -1)"
[[ -n "$VERSION" ]] || { echo "error: could not determine version from changelog output" >&2; exit 1; }
TAG="${TAG_PREFIX}${VERSION}"
say "Release version: $VERSION  (tag: $TAG)"
echo "----- release body -----"
printf '%s\n' "$SECTION"
echo "------------------------"

if $DRY_RUN; then
    say "Dry run — no files written, no build/release/tag. Re-run without --dry-run to proceed."
    exit 0
fi

# Real run: write CHANGELOG.md + the notes file (release body), pinned to $VERSION.
"$SCRIPT_DIR/gen-changelog.sh" --version "$VERSION" --notes-file "$NOTES_FILE"

# commit the changelog before building so the remote build/rsync carries it
if ! git -C "$LANDING_ROOT" diff --quiet -- CHANGELOG.md 2>/dev/null || \
   [[ -n "$(git -C "$LANDING_ROOT" status --porcelain -- CHANGELOG.md)" ]]; then
    git -C "$LANDING_ROOT" add CHANGELOG.md
    git -C "$LANDING_ROOT" commit -m "changelog: $VERSION"
    git -C "$LANDING_ROOT" push origin HEAD
else
    echo "CHANGELOG.md unchanged — nothing to commit"
fi

# --- 2. vanilla: build then release -----------------------------------------
if variant_released 'pepito-EDL\.tar\.xz$'; then
    say "Vanilla EDL already on release $VERSION — skipping build + release"
else
    say "Building VANILLA remotely"
    "$SCRIPT_DIR/build-lineage23-remotely.sh"
    say "Releasing VANILLA"
    "$SCRIPT_DIR/release-remotely.sh" --notes-file "$NOTES_FILE" --tag "$VERSION"
fi

# --- 3. gapps: build then release -------------------------------------------
if variant_released 'pepito-gapps-EDL\.tar\.xz$'; then
    say "GApps EDL already on release $VERSION — skipping build + release"
else
    say "Building GAPPS remotely"
    "$SCRIPT_DIR/build-lineage23-remotely.sh" --gapps
    say "Releasing GAPPS"
    "$SCRIPT_DIR/release-remotely.sh" --gapps --notes-file "$NOTES_FILE" --tag "$VERSION"
fi

# --- 4. tag every repo + push ----------------------------------------------
if $DO_TAG; then
    say "Tagging all repos $TAG"
    for entry in "${TAG_REPOS[@]}"; do
        path="${entry%%$'\t'*}"; remote="${entry##*$'\t'}"
        [[ -d "$path/.git" ]] || { echo "  skip (not a repo): $path"; continue; }
        # prefer the named remote; fall back to whatever single remote exists
        if ! git -C "$path" remote | grep -qx "$remote"; then
            remote="$(git -C "$path" remote | head -1)"
        fi
        if git -C "$path" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
            echo "  $path: tag $TAG already exists, skipping create"
        else
            git -C "$path" tag -a "$TAG" -m "LineageOS 23.2 for pepito (Palm PVG100) — $VERSION"
        fi
        git -C "$path" push "$remote" "$TAG"
        echo "  tagged + pushed: $path -> $remote"
    done
fi

say "Done: $VERSION released (vanilla + gapps). Releases: https://github.com/solarkennedy/lineageos-pepito/releases"
