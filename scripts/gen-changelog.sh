#!/usr/bin/env bash
# gen-changelog.sh — assemble a per-release changelog across every pepito repo.
#
# For each repo it lists the commits since that repo's previous pepito-23.2-r*
# tag (its own anchor — repos advance independently). Emits one markdown section
# and, unless --stdout, prepends it to CHANGELOG.md in the landing repo and
# writes the same section to a notes file for use as the GitHub release body.
#
#   scripts/gen-changelog.sh                 # auto version (last rN + 1), writes files
#   scripts/gen-changelog.sh --version r2    # force the version label
#   scripts/gen-changelog.sh --stdout        # print the section only, write nothing
#
set -euo pipefail

TREE=${TREE:-/home/kyle/android/lineage-23}
LANDING=${LANDING:-/home/kyle/Projects/lineageos-pepito}
LAUNCHER=${LAUNCHER:-/home/kyle/Projects/PepitoLauncher2}
TAG_PREFIX="pepito-23.2-"

# repo table: "<abs path><TAB><display name>". Order = changelog order.
REPOS=(
  "$TREE/kernel/xiaomi/msm8937	kernel (msm8937)"
  "$TREE/device/xiaomi/Mi8937	device/Mi8937"
  "$TREE/device/xiaomi/mithorium-common	device/mithorium-common"
  "$TREE/vendor/xiaomi	vendor/xiaomi (blobs)"
  "$TREE/bootable/recovery	recovery"
  "$TREE/frameworks/base	frameworks/base"
  "$TREE/lineage-sdk	lineage-sdk"
  "$TREE/packages/apps/LineageParts	LineageParts"
  "$TREE/hardware/interfaces	hardware/interfaces"
  "$TREE/hardware/qcom-caf/bt	hardware/qcom-caf/bt"
  "$TREE/system/core	system/core"
  "$TREE/vendor/lineage	vendor/lineage"
  "$LAUNCHER	PepitoLauncher2"
  "$LANDING	landing (docs/scripts)"
)

VERSION=""
MODE="write"   # write | stdout
NOTES_FILE="$LANDING/.release-notes.md"
CHANGELOG="$LANDING/CHANGELOG.md"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --stdout)  MODE="stdout"; shift ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        --changelog)  CHANGELOG="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | cut -c3-; exit 0 ;;
        *) echo "gen-changelog.sh: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

# latest pepito-23.2-rN tag reachable from HEAD in a repo (empty if none)
repo_last_tag() {
    git -C "$1" describe --tags --abbrev=0 --match "${TAG_PREFIX}r*" 2>/dev/null || true
}

# highest N across every repo's latest rN tag (0 if none tagged yet)
max_rn() {
    local max=0 n
    for entry in "${REPOS[@]}"; do
        local path="${entry%%$'\t'*}"
        [[ -d "$path/.git" ]] || continue
        local t; t="$(repo_last_tag "$path")"
        [[ "$t" =~ ^${TAG_PREFIX}r([0-9]+)$ ]] || continue
        n="${BASH_REMATCH[1]}"
        (( n > max )) && max="$n"
    done
    echo "$max"
}

if [[ -z "$VERSION" ]]; then
    VERSION="r$(( $(max_rn) + 1 ))"
fi
[[ "$VERSION" =~ ^r[0-9]+$ ]] || { echo "gen-changelog.sh: --version must look like r2 (got '$VERSION')" >&2; exit 1; }

DATE="$(date -u +%Y-%m-%d)"

# --- assemble the section ---------------------------------------------------
section() {
    echo "## ${VERSION} (${DATE})"
    echo
    local any=0
    for entry in "${REPOS[@]}"; do
        local path="${entry%%$'\t'*}"
        local name="${entry##*$'\t'}"
        [[ -d "$path/.git" ]] || continue

        local prev; prev="$(repo_last_tag "$path")"
        local range subtitle
        if [[ -n "$prev" ]]; then
            range="${prev}..HEAD"
            subtitle="since ${prev}"
        else
            # never tagged (e.g. landing repo) — this release establishes its
            # first anchor; don't dump full history, just note it.
            subtitle="(first tagged in ${VERSION} — no prior anchor)"
            echo "### ${name}"
            echo "- ${subtitle}"
            echo
            any=1
            continue
        fi

        local log
        log="$(git -C "$path" log "$range" --no-merges --pretty='- %s' 2>/dev/null || true)"
        [[ -n "$log" ]] || continue   # no changes in this repo → skip
        echo "### ${name} (${subtitle})"
        echo "$log"
        echo
        any=1
    done
    if [[ "$any" -eq 0 ]]; then
        echo "_No changes since the previous release._"
        echo
    fi
}

SECTION="$(section)"

if [[ "$MODE" == "stdout" ]]; then
    printf '%s\n' "$SECTION"
    exit 0
fi

# notes file (release body) — just this section
printf '%s\n' "$SECTION" > "$NOTES_FILE"

# CHANGELOG.md — prepend the section under a stable title, newest first
TITLE="# Changelog — LineageOS 23.2 for pepito (Palm PVG100)"
if [[ -f "$CHANGELOG" ]]; then
    BODY="$(tail -n +2 "$CHANGELOG" | sed '1{/^$/d}')"   # drop old title + one blank
else
    BODY=""
fi
{
    printf '%s\n\n' "$TITLE"
    printf '%s\n' "$SECTION"
    [[ -n "$BODY" ]] && printf '%s\n' "$BODY"
} > "$CHANGELOG"

echo "gen-changelog: version=$VERSION  notes=$NOTES_FILE  changelog=$CHANGELOG"
