#!/usr/bin/env bash
# gen-changelog.sh — assemble a per-release changelog across every pepito repo
# (LineageOS 24.0 / lineageos24.0 branch).
#
# For each repo it lists the commits since that repo's previous pepito-24.0-*
# tag (its own anchor — repos advance independently). Emits one markdown section
# and, unless --stdout, prepends it to CHANGELOG.md in the landing repo and
# writes the same section to a notes file for use as the GitHub release body.
#
# Forks get rebased onto upstream (REBASE.md), which rewrites our commits: the
# previous tag is then no longer an ancestor of HEAD. So the anchor is the
# newest tag by name, our commits are listed with --cherry-pick (a replayed
# patch the tag already had is not new). What a rebase brought in from upstream
# (manifests/upstreams.conf) isn't listed: the release gets a short "Upstream
# LineageOS" note instead (scripts/upstream.py tree-changelog): the Android
# security patch level, the count of Google security fixes LineageOS merged,
# and rebase totals, counting the non-fork projects against the previous
# release's snapshot in manifests/snapshots/. Nothing taken, no note.
#
# The repo set is every project in manifests/pepito.xml on one of our remotes
# (pepito / pepito-ssh), plus this landing repo. There is no 24.0 tree on the
# netbook (git-driven builds, see build-lineage24-remotely.sh), so the tree
# repos are read on the build server, in one ssh session, from its
# ~/android/lineage-24 checkout. That checkout is synced with --no-tags, so the
# pepito-24.0-* tags are fetched from each fork first.
#
# Versions are date codes (YYYYMMDD), matching the GitHub release tag.
#
#   scripts/gen-changelog.sh                    # version = today (UTC), writes files
#   scripts/gen-changelog.sh --version 20260727 # force the date code
#   scripts/gen-changelog.sh --stdout           # print the section only, write nothing
#
set -euo pipefail

TARGET=${TARGET:-10.0.2.43}
REMOTE_TREE=${REMOTE_TREE:-/home/kyle/android/lineage-24}
LANDING=${LANDING:-/home/kyle/Projects/lineageos-pepito-24}
MANIFEST="$LANDING/manifests/pepito.xml"
TAG_PREFIX="pepito-24.0-"

# Tree repos, in manifest order: "<path><TAB><display name><TAB><upstream url><TAB><upstream ref>"
# (upstream "-" when the repo isn't rebased onto one).
mapfile -t TREE_REPOS < <(python3 - "$MANIFEST" "$LANDING/manifests/upstreams.conf" <<'PY'
import sys, xml.etree.ElementTree as ET
OURS = {"pepito", "pepito-ssh"}
UP = {}
for line in open(sys.argv[2]):
    f = line.split("#", 1)[0].split()
    if f and f[1] == "rebase":
        UP[f[0]] = (f[2], f[3])
def display(path):
    special = {
        "kernel/xiaomi/msm8937": "kernel (msm8937)",
        "vendor/xiaomi": "vendor/xiaomi (blobs)",
        "bootable/recovery": "recovery",
    }
    if path in special:
        return special[path]
    if path.startswith("device/xiaomi/"):
        return "device/" + path[len("device/xiaomi/"):]
    if path.startswith("packages/apps/"):
        return path[len("packages/apps/"):]
    return path
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    if p.get("remote") in OURS:
        url, ref = UP.get(p.get("path"), ("-", "-"))
        print(f"{p.get('path')}\t{display(p.get('path'))}\t{url}\t{ref}")
PY
)
[[ ${#TREE_REPOS[@]} -gt 0 ]] || { echo "gen-changelog.sh: no pepito projects found in $MANIFEST" >&2; exit 1; }

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

# Releases are date-coded (UTC), matching the GitHub release tag, which
# release.sh derives from the LineageOS zip filename ($(date -u +%Y%m%d)).
if [[ -z "$VERSION" ]]; then
    VERSION="$(date -u +%Y%m%d)"
fi
[[ "$VERSION" =~ ^[0-9]{8}$ ]] || { echo "gen-changelog.sh: --version must be a YYYYMMDD date code (got '$VERSION')" >&2; exit 1; }

DATE="$(date -u +%Y-%m-%d)"

# --- per-repo logs from the build server, one ssh session --------------------
# Prints, per repo: "@@REPO<TAB><path><TAB><previous tag or empty>", then our
# "- subject" lines since the tag (minus anything that came from upstream).
remote_logs() {
    local args=() entry path rest url ref
    for entry in "${TREE_REPOS[@]}"; do
        IFS=$'\t' read -r path _ url ref <<<"$entry"
        args+=("$path" "$url" "$ref")
    done
    ssh "$TARGET" -- bash -s -- "$REMOTE_TREE" "$TAG_PREFIX" "${args[@]}" <<'REMOTE'
tree=$1; prefix=$2; shift 2
aosp=$(git -C "$tree/.repo/manifests" show HEAD:default.xml \
    | sed -n 's/.*name="aosp".*revision="\([^"]*\)".*/\1/p' | head -n1)
while [ $# -ge 3 ]; do
    p=$1; url=$2; ref=$3; shift 3
    d="$tree/$p"
    if [ ! -e "$d/.git" ]; then
        printf '@@MISSING\t%s\n' "$p"
        continue
    fi
    remote=$(git -C "$d" remote | head -n1)
    [ -n "$remote" ] && git -C "$d" fetch -q "$remote" \
        "+refs/tags/${prefix}*:refs/tags/${prefix}*" 2>/dev/null || true
    # newest by name, not `describe`: after a rebase the tag isn't an ancestor
    prev=$(git -C "$d" tag -l "${prefix}*" | sort -V | tail -n1)
    printf '@@REPO\t%s\t%s\n' "$p" "$prev"
    [ -n "$prev" ] || continue
    up=""
    if [ "$url" != "-" ]; then
        [ "$ref" = "@aosp" ] && ref=$aosp
        git -C "$d" fetch -q --no-tags "$url" "$ref" 2>/dev/null && up=$(git -C "$d" rev-parse FETCH_HEAD)
    fi
    if [ -n "$up" ]; then
        base=$(git -C "$d" merge-base HEAD "$up")   # the upstream commit HEAD sits on
        git -C "$d" log --no-merges --cherry-pick --right-only --pretty='- %s' "$prev...HEAD" "^$base"
    else
        git -C "$d" log --no-merges --pretty='- %s' "$prev..HEAD"
    fi
done </dev/null   # this script arrives on stdin (bash -s); keep git from eating it
exit 0
REMOTE
}

# --- assemble the section ---------------------------------------------------
section() {
    echo "## ${VERSION} (${DATE})"
    echo
    local any=0 logs path prev log name

    logs="$(remote_logs)" || { echo "gen-changelog.sh: could not read repos on $TARGET" >&2; exit 1; }
    if grep -q '^@@MISSING' <<<"$logs"; then
        echo "gen-changelog.sh: missing on $TARGET:$REMOTE_TREE:" >&2
        grep '^@@MISSING' <<<"$logs" | cut -f2 >&2
        exit 1
    fi

    for entry in "${TREE_REPOS[@]}"; do
        IFS=$'\t' read -r path name _ _ <<<"$entry"
        # this repo's block: its @@REPO header line, then lines up to the next header
        local block
        block="$(awk -F'\t' -v p="$path" '
            /^@@REPO\t/ { on = ($2 == p); if (on) print; next }
            on { print }' <<<"$logs")"
        prev="$(head -n1 <<<"$block" | cut -f3)"
        log="$(tail -n +2 <<<"$block")"
        if [[ -z "$prev" ]]; then
            echo "### ${name}"
            echo "- (first tagged in ${VERSION} — no prior anchor)"
            echo
            any=1
            continue
        fi
        [[ -n "$log" ]] || continue
        echo "### ${name} (since ${prev})"
        echo "$log"
        echo
        any=1
    done

    # the upstream note: security patch level, bulletin fixes, rebase totals
    # (only when this release took something from upstream)
    prev="$(git -C "$LANDING" tag -l "${TAG_PREFIX}*" | sort -V | tail -n1)"
    if [[ -n "$prev" ]]; then
        local note
        note="$("$LANDING/scripts/upstream.py" tree-changelog --tag "$prev" \
            "manifests/snapshots/${prev#"$TAG_PREFIX"}.xml")" \
            || { echo "gen-changelog.sh: upstream note failed" >&2; exit 1; }
        if [[ -n "$note" ]]; then
            printf '%s\n\n' "$note"
            any=1
        fi
    fi

    # the landing repo is local
    prev="$(git -C "$LANDING" tag -l "${TAG_PREFIX}*" | sort -V | tail -n1)"
    if [[ -z "$prev" ]]; then
        echo "### landing (docs/scripts)"
        echo "- (first tagged in ${VERSION} — no prior anchor)"
        echo
        any=1
    else
        log="$(git -C "$LANDING" log "$prev..HEAD" --no-merges --pretty='- %s' 2>/dev/null || true)"
        if [[ -n "$log" ]]; then
            echo "### landing (docs/scripts) (since ${prev})"
            echo "$log"
            echo
            any=1
        fi
    fi

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

# CHANGELOG.md — prepend the section under a stable title, newest first.
# Idempotent: if a section for this exact version already exists (a re-run after
# an intermittent failure), drop it first so we replace rather than duplicate.
TITLE="# Changelog — LineageOS 24.0 for pepito (Palm PVG100)"
if [[ -f "$CHANGELOG" ]]; then
    BODY="$(tail -n +2 "$CHANGELOG" | sed '1{/^$/d}')"   # drop old title + one blank
    BODY="$(awk -v ver="$VERSION" '
        $0 ~ ("^## " ver "( |$)") { skip=1; next }   # start of the old same-version block
        skip && /^## / { skip=0 }                    # next section ends the skip
        !skip { print }
    ' <<<"$BODY")"
    BODY="$(sed '/./,$!d' <<<"$BODY")"               # trim any leading blank lines
else
    BODY=""
fi
{
    printf '%s\n\n' "$TITLE"
    printf '%s\n' "$SECTION"
    [[ -n "$BODY" ]] && printf '%s\n' "$BODY"
} > "$CHANGELOG"

echo "gen-changelog: version=$VERSION  notes=$NOTES_FILE  changelog=$CHANGELOG"
