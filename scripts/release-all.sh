#!/usr/bin/env bash
# release-all.sh — one command to cut a full pepito LineageOS 24.0 release from
# the netbook (lineageos24.0 branch).
#
#   1. generate the changelog across every pepito repo (scripts/gen-changelog.sh,
#      which reads the tree repos on the build server), commit + push
#      CHANGELOG.md to the landing repo, and stage it as the release body
#      (.release-notes.md) — or use a hand-written body via --notes-file;
#   2. build the VANILLA variant remotely (git-driven: build-lineage24-remotely.sh
#      syncs what is pushed), then release it (OTA zip + pepito.json v2 Updater
#      feed + EDL bundle) with that changelog as the release body;
#   3. GAPPS variant the same way — only with --gapps, until 24.0 has a gapps
#      build (vendor/pepito-gapps is not in the 24.0 manifest yet);
#      (vanilla is UNOFFICIAL, gapps is SNAPSHOT — the two OTA channels in the
#       shared pepito.json; the Updater offers each phone only its own channel)
#   4. tag every pepito repo pepito-24.0-<version> and push the tags, so the next
#      run's changelog anchors here. The tree repos are tagged ON THE BUILD
#      SERVER, at exactly the commits that were built; the landing repo here;
#   5. (best-effort) shell out to `claude` to turn the raw commit changelog into a
#      friendly end-user BBCode bullet list for the XDA update post.
#
# The release notes are also embedded into each pepito.json entry ("changelog" /
# "changelog_url" keys) for our Updater's "What's new" (plans/PLAN-ota-changelog.md).
#
# Vanilla is built+released BEFORE gapps is built, on purpose: the two variants
# share out/target/product/Mi8937/ and each build's installclean wipes the
# other's zip, so the release must happen while its zip still exists.
#
# IDEMPOTENT — safe to just re-run after an intermittent failure (see the 23.2
# notes: changelog sections are replaced, released variants are skipped, uploads
# use --clobber, existing tags are skipped). Pass the original --version when
# resuming on a later day.
#
#   ./scripts/release-all.sh                      # version = today's date code
#   ./scripts/release-all.sh --version 20261101   # force the date code
#   ./scripts/release-all.sh --dry-run            # changelog only; no build/release/tag
#   ./scripts/release-all.sh --no-tag             # skip the repo-tagging step
#   ./scripts/release-all.sh --gapps              # also build + release the gapps variant
#   ./scripts/release-all.sh --notes-file FILE    # hand-written release body (e.g. the
#                                                 # first 24.0 release, which has no anchor)
#
# Needs $GITHUB_TOKEN_PEPITO (or $GH_TOKEN_VAR) set, for the GitHub release.
set -euo pipefail

# Hardcoded (env-overridable), matching release-remotely.sh and gen-changelog.sh.
# NOT derived from BASH_SOURCE: scripts/ is symlinked into the AOSP tree, so
# invoking via that symlink (~/android/lineage-24/scripts/...) would resolve
# LANDING_ROOT up to the tree root — which isn't a git repo — and misdirect the
# notes file. Fixed paths make the script work from any cwd or symlink.
LANDING_ROOT=${LANDING_ROOT:-/home/kyle/Projects/lineageos-pepito-24}
SCRIPT_DIR="$LANDING_ROOT/scripts"
REMOTE_TREE=${REMOTE_TREE:-/home/kyle/android/lineage-24}
TAG_PREFIX="pepito-24.0-"
NOTES_FILE="$LANDING_ROOT/.release-notes.md"

VERSION=""
DRY_RUN=false
DO_TAG=true
DO_GAPPS=false
CUSTOM_NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-tag)  DO_TAG=false; shift ;;
        --gapps)   DO_GAPPS=true; shift ;;
        --notes-file) CUSTOM_NOTES="$2"; shift 2 ;;
        -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
        *) echo "release-all.sh: unknown arg '$1'" >&2; exit 1 ;;
    esac
done
if [[ -n "$CUSTOM_NOTES" && ! -f "$CUSTOM_NOTES" ]]; then
    echo "error: --notes-file not found: $CUSTOM_NOTES" >&2; exit 1
fi

# Tree repos to tag: every manifests/pepito.xml project on one of our remotes
# (same set gen-changelog.sh reads). Tagged on the build server.
mapfile -t TREE_TAG_PATHS < <(python3 - "$LANDING_ROOT/manifests/pepito.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    if p.get("remote") in ("pepito", "pepito-ssh"):
        print(p.get("path"))
PY
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
export LINEAGE_BUILD_DATE="$VERSION"   # picked up by build-lineage24-remotely.sh → the build

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
# A hand-written body replaces the generated one as the release body + feed
# changelog; CHANGELOG.md keeps the generated per-repo section.
if [[ -n "$CUSTOM_NOTES" ]]; then
    cp "$CUSTOM_NOTES" "$NOTES_FILE"
    SECTION="$(cat "$NOTES_FILE")"
    echo "Release body: $CUSTOM_NOTES (hand-written)"
fi

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
    "$SCRIPT_DIR/build-lineage24-remotely.sh"
    say "Releasing VANILLA"
    "$SCRIPT_DIR/release-remotely.sh" --notes-file "$NOTES_FILE" --tag "$VERSION"
fi

# --- 3. gapps: build then release -------------------------------------------
if ! $DO_GAPPS; then
    say "GApps variant skipped (pass --gapps once 24.0 has a gapps build)"
elif variant_released 'pepito-gapps-EDL\.tar\.xz$'; then
    say "GApps EDL already on release $VERSION — skipping build + release"
else
    say "Building GAPPS remotely"
    "$SCRIPT_DIR/build-lineage24-remotely.sh" --gapps
    say "Releasing GAPPS"
    "$SCRIPT_DIR/release-remotely.sh" --gapps --notes-file "$NOTES_FILE" --tag "$VERSION"
fi

# --- 4. tag every repo + push ----------------------------------------------
# Tree repos are tagged on the build server, at the HEADs that were just built,
# and pushed straight to the forks over SSH. The tagger identity is passed
# explicitly: the server's global git identity is a work account, which must
# not end up on these public tags.
if $DO_TAG; then
    say "Tagging all repos $TAG"
    TAGGER_NAME="$(git -C "$LANDING_ROOT" config user.name)"
    TAGGER_EMAIL="$(git -C "$LANDING_ROOT" config user.email)"
    MSG="LineageOS 24.0 for pepito (Palm PVG100) — $VERSION"
    ssh "$TARGET" -- bash -s -- "$REMOTE_TREE" "$TAG" "$MSG" "$TAGGER_NAME" "$TAGGER_EMAIL" \
        "${TREE_TAG_PATHS[@]}" <<'REMOTE'
set -e
tree=$1; tag=$2; msg=$3; name=$4; email=$5; shift 5
for p in "$@"; do
    d="$tree/$p"
    remote=$(git -C "$d" remote | head -n1)
    url=$(git -C "$d" remote get-url "$remote")
    # https://github.com/OWNER/REPO -> git@github.com:OWNER/REPO.git (push over SSH)
    case "$url" in
        https://github.com/*) push_url="git@github.com:${url#https://github.com/}"; push_url="${push_url%.git}.git" ;;
        *) push_url="$url" ;;
    esac
    if git -C "$d" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "  $p: tag $tag already exists, skipping create"
    else
        git -C "$d" -c user.name="$name" -c user.email="$email" tag -a "$tag" -m "$msg"
    fi
    git -C "$d" push -q "$push_url" "refs/tags/$tag"
    echo "  tagged + pushed: $p -> $push_url"
done
REMOTE
    if git -C "$LANDING_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "  landing: tag $TAG already exists, skipping create"
    else
        git -C "$LANDING_ROOT" tag -a "$TAG" -m "LineageOS 24.0 for pepito (Palm PVG100) — $VERSION"
    fi
    git -C "$LANDING_ROOT" push origin "$TAG"
    echo "  tagged + pushed: landing"
fi

# --- 5. XDA forum post (best-effort; the release is already done) ------------
# Turn the raw per-repo commit changelog into a friendly, end-user BBCode bullet
# list to paste into the XDA update thread. Never fatal: if claude is missing or
# errors, we just skip it — the release itself has already succeeded.
XDA_POST="$LANDING_ROOT/.release-xda-post.txt"
RELEASES_URL="https://github.com/solarkennedy/lineageos-pepito/releases"
# Still the 23.2 (A16) thread; swap in a 24.0 thread URL if one is opened.
XDA_THREAD_URL="https://xdaforums.com/t/rom-unofficial-a16-lineageos-23-2-for-the-palm-pvg100.4795985/#"
if command -v claude >/dev/null 2>&1; then
    say "Generating XDA changelog post (Claude)"
    read -r -d '' XDA_PROMPT <<PROMPT || true
You are writing a short "release update" post for the XDA-Developers thread for
LineageOS 24.0 (Android 17) on the Palm PVG100 ("pepito"), an obscure tiny phone.
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

say "Done: $VERSION released ($($DO_GAPPS && echo "vanilla + gapps" || echo vanilla)). Releases: https://github.com/solarkennedy/lineageos-pepito/releases"
