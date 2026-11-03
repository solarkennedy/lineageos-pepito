#!/usr/bin/env bash
# release-all.sh — cut a full pepito LineageOS 24.0 release from the netbook
# (lineageos24.0 branch), in two phases, so what is published is exactly what
# was tested:
#
#   --stage    changelog, then build + package (release.sh --package-only) each
#              flavor; the finished zips wait in release-dist/ on the builder and
#              each flavor's flash images are kept in
#              flash-staging/release-<version>-<flavor>/. Nothing is published.
#   (bench)    flash each staged flavor and run tests/integration on it.
#   --publish  for each flavor: a green test-plan run on THAT build (the phone's
#              ro.build.date.utc = the zip's post-timestamp) and an unchanged
#              builder tree, then publish the staged zip as is (no rebuild, no
#              repackaging), then tag.
#
# Why: 20261101 gapps was rebuilt after its source passed the gate; the rebuild
# came out of an R8 race with NetworkStatsService methods stripped and never
# booted (PLAN-android17.md, "Bug 2026-11-02"). Gating a source does not gate
# the bits a rebuild produces.
#
# The steps below are the old single-pass order; --stage runs 1-3 (packaging
# instead of releasing), --publish runs the releases of 2-3, then 4-5.
#
#   1. generate the changelog across every pepito repo (scripts/gen-changelog.sh,
#      which reads the tree repos on the build server), commit + push
#      CHANGELOG.md to the landing repo, and stage it as the release body
#      (.release-notes.md) — or use a hand-written body via --notes-file;
#   2. build the VANILLA variant remotely (git-driven: build-lineage24-remotely.sh
#      syncs what is pushed), then release it with that changelog as the
#      release body: ONE zip (the OTA, with our README and the EDL flashing kit
#      packed in and re-signed — see release.sh) + the pepito.json v2 Updater feed;
#   3. GAPPS variant the same way — only with --gapps, until 24.0 has a gapps
#      build (vendor/pepito-gapps is not in the 24.0 manifest yet);
#      (vanilla is UNOFFICIAL, gapps is SNAPSHOT — the two OTA channels in the
#       shared pepito.json; the Updater offers each phone only its own channel)
#   4. tag every pepito repo pepito-24.0-<version> and push the tags, so the next
#      run's changelog anchors here. The tree repos are tagged ON THE BUILD
#      SERVER, at exactly the commits that were built; the landing repo here,
#      after committing manifests/snapshots/<version>.xml (`repo manifest -r` of
#      the built tree), which the next changelog's upstream section diffs against;
#   0. (--publish) refuse unless tests/integration has a green run of the
#      release's test plan on each staged build (scripts/test-gate.py
#      --build-utc; tests/integration/README.md);
#   5. (best-effort) shell out to `claude` to turn the raw commit changelog into a
#      friendly end-user BBCode bullet list for the XDA update post.
#
# The release notes are also embedded into each pepito.json entry ("changelog" /
# "changelog_url" keys) for our Updater's "What's new" (plans/PLAN-ota-changelog.md).
#
# Vanilla is built+packaged BEFORE gapps is built, on purpose: the two variants
# share out/target/product/Mi8937/ and each build's installclean wipes the
# other's zip, so packaging must happen while its zip still exists. The packaged
# zip in release-dist/ is independent of out/ from then on.
#
# IDEMPOTENT — safe to just re-run after an intermittent failure (see the 23.2
# notes: changelog sections are replaced, released variants are skipped, uploads
# use --clobber, existing tags are skipped). Pass the original --version when
# resuming on a later day.
#
#   ./scripts/release-all.sh --stage --gapps      # build + package both flavors, publish nothing
#   ./scripts/release-all.sh --publish --version 20261101 --gapps
#                                                 # gate + publish what --stage left
#   ./scripts/release-all.sh --stage --version 20261101   # force the date code
#   ./scripts/release-all.sh --dry-run            # changelog only; no build/release/tag
#   ./scripts/release-all.sh --publish --no-tag   # skip the repo-tagging step
#   ./scripts/release-all.sh --stage --notes-file FILE    # hand-written release body (e.g.
#                                                 # the first 24.0 release, which has no anchor)
#   ./scripts/release-all.sh --publish --skip-test-gate   # publish without a green run
#
# --publish takes the same --version and --gapps as the --stage it follows
# (--version defaults to today's date, so pass it on a later day).
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
TEST_GATE=true
PHASE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-tag)  DO_TAG=false; shift ;;
        --gapps)   DO_GAPPS=true; shift ;;
        --notes-file) CUSTOM_NOTES="$2"; shift 2 ;;
        --skip-test-gate) TEST_GATE=false; shift ;;
        --stage)   PHASE=stage; shift ;;
        --publish) PHASE=publish; shift ;;
        -h|--help) sed -n '2,75p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
        *) echo "release-all.sh: unknown arg '$1'" >&2; exit 1 ;;
    esac
done
if [[ -z "$PHASE" ]] && ! $DRY_RUN; then
    echo "error: say --stage (build + package, publish nothing) or --publish (gate + publish what" >&2
    echo "       --stage left). A release is published only after its own zips were tested." >&2
    exit 1
fi
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
    grep -qE -e "$1" <<<"$names"   # -e: the patterns start with "-"
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
# Upstream moves only on rebase day (REBASE.md), never inside a release: the
# changelog written in step 1 and the snapshot in step 4 describe the tree as it
# stands, so the builds must not re-sync it under them.
unset SYNC_ALL

# --- 0b. staged flavors ----------------------------------------------------
# --stage keeps each flavor's flash images (hard links, so a later build's
# rsync into flash-staging/ cannot change them) and its build stamp here;
# --publish reads them back. The zips themselves wait in release-dist/ on the
# builder, where release.sh --package-only put them.
LOCAL_FLASH_DIR=${LOCAL_FLASH_DIR:-/home/kyle/android/lineage-24/flash-staging}
STAMP=$LOCAL_FLASH_DIR/build-stamp.json
FLAVORS=(vanilla)
$DO_GAPPS && FLAVORS+=(gapps)
stage_dir()   { echo "$LOCAL_FLASH_DIR/release-$VERSION-$1"; }
flavor_args() { [[ "$1" == gapps ]] && echo --gapps || true; }
sidecar_re()  { [[ "$1" == gapps ]] && echo '-Mi8937_gapps\.zip\.sha256sum$' || echo '-Mi8937\.zip\.sha256sum$'; }
dist_zip_glob() {
    [[ "$1" == gapps ]] && echo "$REMOTE_TREE/release-dist/lineage-*-$VERSION-SNAPSHOT-Mi8937_gapps.zip" \
                        || echo "$REMOTE_TREE/release-dist/lineage-*-$VERSION-UNOFFICIAL-Mi8937.zip"
}
stamp_get() {   # stamp_get FILE source_id|date_utc
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print(d["source_id"] if sys.argv[2] == "source_id" else d["build"]["date_utc"])' "$1" "$2"
}

# --- 0c. publish gate: every check before anything is published --------------
if [[ "$PHASE" == publish ]]; then
    say "Publish gate: each flavor's staged zip, its build, and a green run on that build"
    STAGED_ID=""
    for f in "${FLAVORS[@]}"; do
        dir=$(stage_dir "$f")
        [[ -f "$dir/build-stamp.json" ]] \
            || { echo "error: $f: nothing staged in $dir (run --stage --version $VERSION first)" >&2; exit 1; }
        sid=$(stamp_get "$dir/build-stamp.json" source_id)
        utc=$(stamp_get "$dir/build-stamp.json" date_utc)
        [[ -z "$STAGED_ID" || "$STAGED_ID" == "$sid" ]] \
            || { echo "error: the staged flavors are different sources ($STAGED_ID, $sid)" >&2; exit 1; }
        STAGED_ID=$sid
        zip=$(ssh "$TARGET" -- "ls $(dist_zip_glob "$f") 2>/dev/null" || true)
        [[ $(grep -c . <<<"$zip") -eq 1 ]] \
            || { echo "error: $f: expected one staged zip $(dist_zip_glob "$f") on $TARGET, found: ${zip:-none}" >&2; exit 1; }
        ts=$(ssh "$TARGET" -- "unzip -p $(printf '%q' "$zip") META-INF/com/android/metadata" | sed -n 's/^post-timestamp=//p')
        [[ "$ts" == "$utc" ]] \
            || { echo "error: $f: $zip is build $ts, but the staged images are build $utc" >&2; exit 1; }
        echo "$f: $(basename "$zip"), build $utc, source $sid"
        if $TEST_GATE; then
            "$SCRIPT_DIR/test-gate.py" --source-id "$sid" --build-utc "$utc" || {
                echo "error: $f: no green test-plan run on build $utc (the staged zip itself)." >&2
                echo "       FLASH_DIR=$dir $LOCAL_FLASH_DIR/flash-staging.sh <unit>, run tests/integration," >&2
                echo "       then publish again (or --skip-test-gate)." >&2
                exit 1; }
        fi
    done
    $TEST_GATE || say "Integration-test gate SKIPPED (--skip-test-gate)"
    # Tags go on the builder's HEADs and the snapshot is `repo manifest -r` of
    # the tree, so the tree must still be what was staged.
    if $DO_TAG; then
        TREE_ID=$(cd "$SCRIPT_DIR" && python3 -c 'import test_plan; print(test_plan.on_builder("stamp")["source_id"])')
        [[ "$TREE_ID" == "$STAGED_ID" ]] || {
            echo "error: the builder tree is now source $TREE_ID, not the staged $STAGED_ID, so the tags" >&2
            echo "       would not name what was built. Put the tree back, or publish with --no-tag and tag by hand." >&2
            exit 1; }
    fi
    [[ -s "$NOTES_FILE" ]] || { echo "error: $NOTES_FILE (written by --stage) is missing" >&2; exit 1; }
    SECTION="$(cat "$NOTES_FILE")"
    TAG="${TAG_PREFIX}${VERSION}"
    if $DRY_RUN; then
        say "Dry run — the publish gate passed; nothing published or tagged."
        exit 0
    fi
fi

if [[ "$PHASE" != publish ]]; then
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
fi

# --- 2-3. stage: build + package each flavor; publish: release the staged zips -
# "Released" = the zip's .sha256sum sidecar is on the release: release.sh uploads
# it after the zip, so its presence means the variant's upload completed.
for f in "${FLAVORS[@]}"; do
    if variant_released "$(sidecar_re "$f")"; then
        say "${f^} zip already on release $VERSION — skipping"
        continue
    fi
    if [[ "$PHASE" == publish ]]; then
        say "Publishing ${f^^} (the staged zip, as is)"
        "$SCRIPT_DIR/release-remotely.sh" $(flavor_args "$f") --packaged --notes-file "$NOTES_FILE" --tag "$VERSION"
        continue
    fi
    dir=$(stage_dir "$f")
    if [[ -f "$dir/build-stamp.json" ]] && ssh "$TARGET" -- "ls $(dist_zip_glob "$f")" >/dev/null 2>&1; then
        say "${f^} already staged in $dir — skipping build"
        continue
    fi
    say "Building ${f^^} remotely"
    rm -f "$STAMP"
    "$SCRIPT_DIR/build-lineage24-remotely.sh" $(flavor_args "$f")
    [[ -f "$STAMP" ]] || { echo "error: the $f build has no stamp ($STAMP), so no test run could be tied to it" >&2; exit 1; }
    say "Packaging ${f^^} (release.sh --package-only)"
    "$SCRIPT_DIR/release-remotely.sh" $(flavor_args "$f") --package-only --notes-file "$NOTES_FILE" --tag "$VERSION"
    # Stage the images the PACKAGED zip yields, converted by its own ota2raw
    # (which checks each against the zip's manifest), not flash-staging/: the
    # build's out/ images differ from the zip's (target-files adds
    # vendor/bin/install-recovery.sh, vendor/etc/recovery.img, ...), so they
    # would not be the bits users install.
    zip=$(ssh "$TARGET" -- "ls $(dist_zip_glob "$f")")
    conv="$REMOTE_TREE/release-dist/$(basename "$zip" .zip)-edl"
    ssh "$TARGET" -- "set -eo pipefail; rm -rf '$conv'; mkdir -p '$conv'; cd '$conv'
        unzip -oq '$zip' edl/ota2raw-linux-x86_64; chmod +x edl/ota2raw-linux-x86_64
        ./edl/ota2raw-linux-x86_64 -o images '$zip' | grep -E 'verified|MISMATCH'"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$STAMP" "$dir/build-stamp.json"
    rsync -az --partial-dir=.rsync-partial --progress \
        $(for i in boot.bin boot-magisk.bin recovery.bin system.bin vendor.bin config.bin splash.bin \
                   pvg100_firehose.elf pvg100e_firehose.elf rawprogram0.pvg100.xml rawprogram0.pvg100e.xml; do
              printf '%s:%s/images/%s ' "$TARGET" "$conv" "$i"; done) "$dir"/ | tail -3
    ssh "$TARGET" -- "rm -rf '$conv'"
    echo "Staged $f: $dir (build $(stamp_get "$dir/build-stamp.json" date_utc), images from $(basename "$zip"))"
done

if [[ "$PHASE" == stage ]]; then
    say "Staged $VERSION. Nothing is published yet. For each flavor:"
    for f in "${FLAVORS[@]}"; do
        echo "  FLASH_DIR=$(stage_dir "$f") $LOCAL_FLASH_DIR/flash-staging.sh <unit>   # $f"
    done
    echo "  then on that unit: cd tests/integration && python3 -m pytest --unit <unit> ..."
    echo "  (scripts/test-gate.py --source-id $(stamp_get "$(stage_dir "${FLAVORS[0]}")/build-stamp.json" source_id) --build-utc <date_utc> shows what is left)"
    echo "Then: ./scripts/release-all.sh --publish --version $VERSION$($DO_GAPPS && echo " --gapps")"
    exit 0
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
    # ssh joins its arguments with spaces and the remote shell parses the result
    # again, so each one is %q-quoted: the message has spaces and parentheses.
    REMOTE_ARGS="$(printf '%q ' "$REMOTE_TREE" "$TAG" "$MSG" "$TAGGER_NAME" "$TAGGER_EMAIL" "${TREE_TAG_PATHS[@]}")"
    ssh "$TARGET" -- "bash -s -- $REMOTE_ARGS" <<'REMOTE'
set -e
tree=$1; tag=$2; msg=$3; name=$4; email=$5; shift 5
for p in "$@"; do
    d="$tree/$p"
    # Our fork remote, not just the first one: a repo can also carry an
    # upstream remote (FaceUnlock's crdroid-gitlab sorts before pepito).
    remote=$(git -C "$d" remote | grep -xE 'pepito-ssh|pepito' | sort -r | head -n1)
    remote=${remote:-$(git -C "$d" remote | head -n1)}
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
    SNAP="manifests/snapshots/$VERSION.xml"
    SNAP_TMP=$(mktemp)
    "$SCRIPT_DIR/upstream.py" snapshot > "$SNAP_TMP"
    mv "$SNAP_TMP" "$LANDING_ROOT/$SNAP"
    if [[ -n "$(git -C "$LANDING_ROOT" status --porcelain -- "$SNAP")" ]]; then
        git -C "$LANDING_ROOT" add "$SNAP"
        git -C "$LANDING_ROOT" commit -m "snapshot: $VERSION tree"
        git -C "$LANDING_ROOT" push origin HEAD
    fi
    echo "  snapshot: $SNAP"
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
XDA_THREAD_URL="https://xdaforums.com/t/rom-unofficial-a17-lineageos-24-0-for-the-palm-pvg100-pvg100e-pepito.4804726/"
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

# Always shown, even when no post was generated: the thread is updated by hand.
say "REMINDER: post the $VERSION update to the XDA thread (and bump 'Latest build' in its first post):"
echo "  $XDA_THREAD_URL"

say "Done: $VERSION released ($($DO_GAPPS && echo "vanilla + gapps" || echo vanilla)). Releases: https://github.com/solarkennedy/lineageos-pepito/releases"
