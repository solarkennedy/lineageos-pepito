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
#      run's changelog anchors here;
#   5. (best-effort) shell out to `claude` to turn the raw commit changelog into a
#      friendly end-user BBCode bullet list (with a link to the releases page) for
#      the XDA update post — printed at the end, saved to .release-xda-post.txt,
#      followed by the XDA thread URL to paste it into. Skipped if claude is
#      absent; never fails the release.
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
  "$TREE/frameworks/native	solarkennedy"
  "$TREE/lineage-sdk	solarkennedy"
  "$TREE/packages/apps/LineageParts	solarkennedy"
  "$TREE/hardware/interfaces	solarkennedy"
  "$TREE/hardware/qcom-caf/bt	solarkennedy"
  "$TREE/system/core	solarkennedy"
  "$TREE/system/bpfprogs	solarkennedy"
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

# --- 0. date is chosen ONCE, here ------------------------------------------
# release-all owns the release date: a single value stamped identically on both
# variants' zips, the changelog, every source tag, and the GitHub release. It is
# threaded into the remote builds (LINEAGE_BUILD_DATE, exported below) so a build
# that straddles UTC midnight can't desync vanilla vs gapps — the bug that split
# 20260803/20260804. Default to the LOCAL calendar date (the day you built on),
# not UTC, so an evening build west of UTC stays "today"; override with --version.
[[ -n "$VERSION" ]] || VERSION="$(date +%Y%m%d)"
[[ "$VERSION" =~ ^[0-9]{8}$ ]] || { echo "error: --version must be YYYYMMDD (got '$VERSION')" >&2; exit 1; }
export LINEAGE_BUILD_DATE="$VERSION"   # picked up by build-lineage23-remotely.sh → the build

# --- 1. changelog -----------------------------------------------------------
say "Generating changelog"

# Preview via --stdout first: writes nothing. Pinned to our chosen $VERSION so
# the changelog heading matches the zips and tags exactly.
SECTION="$("$SCRIPT_DIR/gen-changelog.sh" --stdout --version "$VERSION")"
[[ -n "$SECTION" ]] || { echo "error: gen-changelog produced no output for $VERSION" >&2; exit 1; }
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

# --- 5. XDA forum post (best-effort; the release is already done) ------------
# Turn the raw per-repo commit changelog into a friendly, end-user BBCode bullet
# list to paste into the XDA update thread. Never fatal: if claude is missing or
# errors, we just skip it — the release itself has already succeeded.
XDA_POST="$LANDING_ROOT/.release-xda-post.txt"
RELEASES_URL="https://github.com/solarkennedy/lineageos-pepito/releases"
XDA_THREAD_URL="https://xdaforums.com/t/rom-unofficial-a16-lineageos-23-2-for-the-palm-pvg100.4795985/#"
if command -v claude >/dev/null 2>&1; then
    say "Generating XDA changelog post (Claude)"
    read -r -d '' XDA_PROMPT <<PROMPT || true
You are writing a short "release update" post for the XDA-Developers thread for
LineageOS 23.2 (Android 16) on the Palm PVG100 ("pepito"), an obscure tiny phone.
The reader is an end user, not a developer.

Below (on stdin) is the raw changelog for release $VERSION — git commit subjects
grouped by source repo. Rewrite it as a friendly, plain-language summary that a
normal person can understand.

Output ONLY XDA BBCode, nothing else (no preamble, no code fences):
- A one-line bold heading with the version, e.g. [B]Update $VERSION[/B]
- Then a [LIST] ... [/LIST] of [*] bullets.
- Then a final line linking to the releases page (NOT a specific file or release
  — there are vanilla and gapps variants), exactly:
  [URL=$RELEASES_URL]Download the latest build[/URL]
Rules:
- Translate technical commits into the user-facing benefit ("fixes intermittent
  silent calls", "step counter now works", "sunlight-readable screen mode").
- Merge related commits into one bullet; group by theme, not by repo.
- OMIT pure-internal noise: build/release scripts, refactors, plan docs,
  changelog/CI, revert-of-experiment commits. If nothing user-facing remains in
  a group, drop it.
- Keep it concise — aim for 4-10 bullets. Friendly, not marketing-y.
PROMPT
    if printf '%s\n' "$SECTION" | claude -p "$XDA_PROMPT" > "$XDA_POST" 2>/dev/null && [[ -s "$XDA_POST" ]]; then
        echo
        echo "===== XDA post (BBCode) — also saved to $XDA_POST ====="
        cat "$XDA_POST"
        echo "======================================================="
        echo "Paste it into the XDA thread:"
        echo "  $XDA_THREAD_URL"
    else
        echo "note: Claude did not produce an XDA post — skipping (release is unaffected)." >&2
        rm -f "$XDA_POST"
    fi
else
    echo "note: 'claude' not on PATH — skipping XDA post generation." >&2
fi

say "Done: $VERSION released (vanilla + gapps). Releases: https://github.com/solarkennedy/lineageos-pepito/releases"
