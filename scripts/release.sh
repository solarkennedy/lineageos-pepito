#!/usr/bin/env bash
#
# release.sh — cut a lineageos-pepito release from an already-built OTA zip
# (and, unless --skip-edl, an already-staged EDL flash-staging/ directory).
#
# Given the signed zip you built and flash-tested yourself, this:
#   1. sanity-checks it (exists, under GitHub's 2 GiB release-asset limit)
#   2. builds an EDL bundle from flash-staging/ (firehose loader,
#      rawprogram0.xml, raw boot/recovery/system/vendor, README) and
#      compresses the whole thing as one .tar.xz
#   3. creates (or reuses) a GitHub Release and uploads the zip, the EDL
#      tar, and .sha256sum sidecars for both
#   4. regenerates <device>.json (repo root — see note by OTA_JSON_REL below)
#      via gen-ota-json.py (OTA zip only, not the EDL bundle)
#   5. commits and pushes that JSON to the branch lineage_updater_uri points at
#
# Everything except the build itself. Requires `gh` authenticated for the repo.
#
#   ./scripts/release.sh <zip>
#   ./scripts/release.sh <zip> --tag 20260716 --notes "Fixes X, Y"
#   ./scripts/release.sh <zip> --dry-run
#   ./scripts/release.sh <zip> --skip-edl
#
# Device/version/romtype/date are parsed from a standard LineageOS filename
# (lineage-<version>-<YYYYMMDD>-<romtype>-<device>[-signed].zip); override any
# of them with flags if your filename doesn't match.
#
# The EDL bundle is read from --edl-dir (default: flash-staging/ in the
# lineage-23 tree) and expects it already populated by prepare-flash.sh —
# this script does not sign or desparsify images itself.
#
set -euo pipefail

# --- defaults ---------------------------------------------------------------
REPO="solarkennedy/lineageos-pepito"
BRANCH="lineageos23.2"   # must match the branch lineage_updater_uri points at
KEEP=5                   # entries to keep per romtype in the OTA JSON
DEVICE=""
VERSION=""
ROMTYPE=""
TAG=""
NOTES=""
DRY_RUN=false
ASSUME_YES=false
SKIP_EDL=false
EDL_DIR="/home/kyle/android/lineage-23/flash-staging"
# config.bin is a 32 KB zero-fill (written by prepare-flash.sh) that clears a
# stale FRP token so A15+ FRP can auto-deactivate after a wipe. userdata is
# deliberately excluded — a release flash must not wipe /data as a side effect.
EDL_IMAGES=(boot.bin recovery.bin system.bin vendor.bin config.bin)
XZ_LEVEL=6
# --------------------------------------------------------------------------

# --- run-location guard -----------------------------------------------------
# release.sh must run ON the build server: the freshly built zip and
# flash-staging/ already live there, and the EDL bundle's xz pass belongs on
# its CPU, not the netbook's. From the netbook use scripts/release-remotely.sh
# instead — it runs this script over there and only pulls the OTA JSON back.
# Override for a deliberate run elsewhere with RELEASE_ALLOW_ANY_HOST=1.
RELEASE_BUILD_HOST="${RELEASE_BUILD_HOST:-Stellaris16}"
THIS_HOST="$(hostname -s 2>/dev/null || hostname)"
if [[ "${RELEASE_ALLOW_ANY_HOST:-0}" != "1" && "${THIS_HOST,,}" != "${RELEASE_BUILD_HOST,,}" ]]; then
    echo "error: release.sh must run on the build server ($RELEASE_BUILD_HOST), not '$THIS_HOST'." >&2
    echo "       From here, run:  ./scripts/release-remotely.sh   (add --gapps for the gapps build)" >&2
    echo "       To override intentionally: RELEASE_ALLOW_ANY_HOST=1 ./scripts/release.sh ..." >&2
    exit 1
fi
# --------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN_JSON="$SCRIPT_DIR/gen-ota-json.py"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed -n '2,27p' | cut -c3-; exit 1; }

write_edl_readme() {
    # $1 = output path
    cat > "$1" <<EOF
# LineageOS $VERSION for the Palm PVG100 ("pepito") — EDL flash package

$ROMTYPE build \`$TAG\` ($DEVICE). This is the low-level **Qualcomm EDL (9008)**
image set: raw boot / recovery / system / vendor partitions you write with
\`qdl\` when the phone won't boot or you're coming from stock Android 8.1.

**Already running LineageOS and just want to update?** You don't need this — use
the OTA zip instead (\`adb sideload\` in recovery, or the built-in Updater).

- Project & source:  https://github.com/$REPO
- This release:      https://github.com/$REPO/releases/tag/$TAG
- The full story:    https://kyle.cascade.family/posts/porting-android-16-to-a-palm-pvg100-pepito

Not comfortable doing this yourself? I'll flash your PVG100 for you for \$100 —
email kyle@cascade.family.

---

## What's in here

- \`pepito_firehose.elf\` — signed Firehose loader for this SoC (MSM8940)
- \`rawprogram0.xml\` — partition table; only the boot/recovery/system/vendor/
  config entries are used here (the rest are skipped with \`--allow-missing\`)
- \`boot.bin\`, \`recovery.bin\`, \`system.bin\`, \`vendor.bin\` — the raw images
- \`config.bin\` — a 32 KB zero-fill flashed over the \`config\` partition to
  clear any stale factory-reset-protection (FRP) token, so you don't get a
  bogus "factory reset" prompt on every boot. It does **not** touch \`/data\`.

This package does **not** touch modem, bootloader, TrustZone, RPM, or other
firmware partitions — those are stock, device-specific, and already on your
phone. Only boot / recovery / system / vendor are written.

## Before you start

- **Back up first.** With a full backup the PVG100 is effectively unbrickable
  over EDL. See the backup guide:
  https://xdaforums.com/t/guide-using-edl-to-backup-a-palm-pvg-100-pepito-on-linux.4719549/
- **You will lose your data.** Coming from stock (or any mismatched build) the
  first boot reformats \`/data\` for file-based encryption. Save anything you care about.
- **You need:** a Linux machine with \`qdl\` (https://github.com/linux-msm/qdl)
  on your PATH, \`xz-utils\`, and a USB cable.

## Flashing

1. Extract this archive:

       tar xf ${TAG_BUNDLE_NAME}.tar.xz
       cd ${TAG_BUNDLE_NAME}

2. Put the phone into **EDL (9008)** mode:
   - if it still boots or reaches recovery:  \`adb reboot edl\`
   - otherwise use the PVG100 hardware key method (see the project page above).

   The screen stays black in EDL — that's expected. Confirm the phone is in EDL
   with \`lsusb\`: a \`Qualcomm ... 9008\` device should appear.

3. Flash:

       qdl --storage emmc --allow-missing pepito_firehose.elf rawprogram0.xml

   \`--allow-missing\` is required: \`rawprogram0.xml\` lists the full stock
   partition table and only boot/recovery/system/vendor/config are included here.

4. When \`qdl\` finishes, let the phone reboot on its own. **The first boot takes
   a few minutes** while it formats \`/data\`. If it instead reboots into recovery
   asking for a factory reset, that's the encryption mismatch failing safe —
   wipe data and reboot.

## Verify your download

    sha256sum -c ${TAG_BUNDLE_NAME}.tar.xz.sha256sum

## Trouble?

- \`qdl\` not found or "permission denied": build qdl and either run it as root
  or add a udev rule for the 9008 device.
- Black screen after flashing: give the first boot ~5 minutes; if nothing, put
  the phone back into EDL and reflash.
- Bugs and questions: https://github.com/$REPO/issues

Flashing custom firmware voids warranties and is done at your own risk.
EOF
}

ZIP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --romtype) ROMTYPE="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        --edl-dir) EDL_DIR="$2"; shift 2 ;;
        --skip-edl) SKIP_EDL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *) ZIP="$1"; shift ;;
    esac
done

[[ -n "$ZIP" ]] || { echo "Usage: $0 <path-to-signed-ota-zip> [--tag T] [--notes N] [--dry-run] [--skip-edl] ..." >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: $ZIP does not exist" >&2; exit 1; }

FILENAME="$(basename "$ZIP")"

# Parse lineage-<version>-<YYYYMMDD>-<romtype>-<device>[-signed].zip
FN_VERSION="" FN_DATE="" FN_ROMTYPE="" FN_DEVICE=""
if [[ "$FILENAME" =~ ^lineage-([0-9.]+)-([0-9]{8})-([A-Za-z]+)-([A-Za-z0-9_]+)(-signed)?\.zip$ ]]; then
    FN_VERSION="${BASH_REMATCH[1]}"
    FN_DATE="${BASH_REMATCH[2]}"
    FN_ROMTYPE="${BASH_REMATCH[3]}"
    FN_DEVICE="${BASH_REMATCH[4]}"
fi

# Not ${FN_DEVICE:-pepito}: the filename's device component is the AOSP
# codename (Mi8937, == PRODUCT_DEVICE), not our "pepito" release codename that
# device.mk's lineage.updater.uri and this repo's OTA JSON filename use.
DEVICE="${DEVICE:-pepito}"
VERSION="${VERSION:-$FN_VERSION}"
ROMTYPE="${ROMTYPE:-${FN_ROMTYPE:-nightly}}"
TAG="${TAG:-$FN_DATE}"

[[ -n "$VERSION" ]] || { echo "error: couldn't parse a version from '$FILENAME' — pass --version" >&2; exit 1; }
[[ -n "$TAG" ]] || { echo "error: couldn't parse a date/tag from '$FILENAME' — pass --tag" >&2; exit 1; }

# GitHub release assets: 2 GiB per file, hard limit.
SIZE_BYTES=$(stat -c%s "$ZIP")
LIMIT_BYTES=$((2 * 1024 * 1024 * 1024))
if (( SIZE_BYTES >= LIMIT_BYTES )); then
    echo "error: $FILENAME is $(( SIZE_BYTES / 1024 / 1024 )) MB, at/over GitHub's 2 GiB release-asset limit" >&2
    exit 1
fi

command -v gh >/dev/null || { echo "error: gh (GitHub CLI) not found in PATH" >&2; exit 1; }

EDL_BUNDLE="lineage-${VERSION}-${TAG}-${ROMTYPE}-${DEVICE}-EDL"
TAG_BUNDLE_NAME="$EDL_BUNDLE"   # used by write_edl_readme
EDL_TAR_NAME="${EDL_BUNDLE}.tar.xz"
EDL_FIREHOSE="$EDL_DIR/pepito_firehose.elf"
EDL_RAWPROGRAM="$EDL_DIR/rawprogram0.xml"

if ! $SKIP_EDL; then
    MISSING=()
    for f in "$EDL_FIREHOSE" "$EDL_RAWPROGRAM"; do
        [[ -f "$f" ]] || MISSING+=("$f")
    done
    for img in "${EDL_IMAGES[@]}"; do
        [[ -f "$EDL_DIR/$img" ]] || MISSING+=("$EDL_DIR/$img")
    done
    if (( ${#MISSING[@]} > 0 )); then
        echo "error: EDL bundle inputs missing:" >&2
        printf '  %s\n' "${MISSING[@]}" >&2
        echo "Run prepare-flash.sh first, pass --edl-dir, or pass --skip-edl to release the OTA zip only." >&2
        exit 1
    fi
fi

OTA_JSON_REL="${DEVICE}.json"   # repo root, not ota/ — the raw URL must stay under Android's 91-byte sysprop limit
OTA_JSON="$REPO_ROOT/$OTA_JSON_REL"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${OTA_JSON_REL}"
RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${FILENAME}"
EDL_RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${EDL_TAR_NAME}"

echo "== release plan =="
echo "  file:      $FILENAME ($(( SIZE_BYTES / 1024 / 1024 )) MB)"
echo "  device:    $DEVICE"
echo "  version:   $VERSION"
echo "  romtype:   $ROMTYPE"
echo "  repo:      $REPO"
echo "  tag:       $TAG"
echo "  branch:    $BRANCH"
echo "  asset url: $RELEASE_URL"
echo "  ota json:  $OTA_JSON_REL -> $RAW_URL"
if $SKIP_EDL; then
    echo "  edl:       skipped (--skip-edl)"
else
    echo "  edl dir:   $EDL_DIR"
    echo "  edl tar:   $EDL_TAR_NAME -> $EDL_RELEASE_URL"
fi
echo "==================="

if $DRY_RUN; then
    echo "(dry run: stopping before any GitHub or git changes)"
    exit 0
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo "error: gh is not authenticated for github.com (run: gh auth login --hostname github.com)" >&2
    echo "(on a machine with more than one gh host configured, e.g. a work fork of the CLI," >&2
    echo " make sure that login targets github.com specifically, not a default internal host)" >&2
    exit 1
fi

# The landing repo may be a rsync mirror without .git (e.g. the build server —
# build-lineage23-remotely.sh deliberately excludes .git when mirroring it
# there). Detect that now, before creating the release, rather than failing
# on the git commit below after assets are already uploaded.
HAS_GIT=true
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || HAS_GIT=false
if ! $HAS_GIT; then
    echo "note: $REPO_ROOT has no .git (this looks like a synced mirror, not the real clone)."
    echo "      The release will still be created, but ${DEVICE}.json will only be written"
    echo "      locally here — sync it back to the machine with the real clone and commit/push"
    echo "      it from there."
fi

if ! $ASSUME_YES; then
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- sha256sum sidecar for the OTA zip --------------------------------------
SHA_FILE="$WORK/${FILENAME}.sha256sum"
( cd "$(dirname "$ZIP")" && sha256sum "$FILENAME" ) > "$SHA_FILE"

ASSETS=("$ZIP" "$SHA_FILE")

# --- EDL bundle: firehose + rawprogram + raw images + README, --------------
# --- compressed as a single .tar.xz (images themselves stay uncompressed) --
if ! $SKIP_EDL; then
    echo "Building EDL bundle ($EDL_TAR_NAME)..."
    PKG_DIR="$WORK/$EDL_BUNDLE"
    mkdir -p "$PKG_DIR"

    cp "$EDL_FIREHOSE" "$PKG_DIR/"
    cp "$EDL_RAWPROGRAM" "$PKG_DIR/"

    for img in "${EDL_IMAGES[@]}"; do
        cp "$EDL_DIR/$img" "$PKG_DIR/$img"
    done

    write_edl_readme "$PKG_DIR/README.md"

    echo "  compressing archive (xz -$XZ_LEVEL, multithreaded)..."
    EDL_TAR="$WORK/$EDL_TAR_NAME"
    ( cd "$WORK" && tar -cf - "$EDL_BUNDLE" | xz -T0 "-$XZ_LEVEL" -c > "$EDL_TAR_NAME" )

    EDL_SHA_FILE="$WORK/${EDL_TAR_NAME}.sha256sum"
    ( cd "$WORK" && sha256sum "$EDL_TAR_NAME" ) > "$EDL_SHA_FILE"

    ASSETS+=("$EDL_TAR" "$EDL_SHA_FILE")
fi

# --- GitHub release: create, or upload into an existing one ----------------
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "release $TAG already exists on $REPO — uploading assets (--clobber)"
    gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
else
    TITLE="LineageOS $VERSION $ROMTYPE $TAG ($DEVICE)"
    gh release create "$TAG" "${ASSETS[@]}" \
        --repo "$REPO" \
        --title "$TITLE" \
        --notes "${NOTES:-$TITLE}"
fi

# --- regenerate the OTA JSON (OTA zip only) ---------------------------------
DATETIME_ARGS=()
if [[ -n "$FN_DATE" ]]; then
    DATETIME_ARGS=(--datetime "$(date -u -d "$FN_DATE" +%s)")
fi

python3 "$GEN_JSON" "$ZIP" \
    --device "$DEVICE" \
    --version "$VERSION" \
    --romtype "$ROMTYPE" \
    --repo "$REPO" \
    --tag "$TAG" \
    --output "$OTA_JSON" \
    --keep "$KEEP" \
    "${DATETIME_ARGS[@]}"

# --- commit + push (skipped on a .git-less mirror, see the note above) -----
if $HAS_GIT; then
    git -C "$REPO_ROOT" add "$OTA_JSON_REL"
    if git -C "$REPO_ROOT" diff --cached --quiet -- "$OTA_JSON_REL"; then
        echo "no change to $OTA_JSON_REL (already up to date)"
    else
        git -C "$REPO_ROOT" commit -m "ota: add $FILENAME"
        git -C "$REPO_ROOT" push origin "HEAD:$BRANCH"
    fi
else
    echo "skipped commit/push: $OTA_JSON updated locally, no .git here to push from"
fi

echo
echo "Done. OTA feed: $RAW_URL"
if ! $SKIP_EDL; then
    echo "EDL bundle: $EDL_RELEASE_URL"
fi
echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
