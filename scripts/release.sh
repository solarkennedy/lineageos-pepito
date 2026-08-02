#!/usr/bin/env bash
#
# release.sh — cut a lineageos-pepito release from an already-built OTA zip
# (and, unless --skip-edl, an already-staged EDL flash-staging/ directory).
#
# Given the signed zip you built and flash-tested yourself, this:
#   1. sanity-checks it (exists, under GitHub's 2 GiB release-asset limit)
#   2. builds an EDL bundle from flash-staging/ (per-variant firehose loaders
#      + rawprogram XMLs for both PVG100 and PVG100E, raw
#      boot/recovery/system/vendor, README) and
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
#   ./scripts/release.sh <zip> --skip-edl    # OTA zip + JSON only, no EDL bundle
#   ./scripts/release.sh <zip> --edl-only    # EDL bundle only, no OTA zip or JSON
#   ./scripts/release.sh <zip> --notes-file CHANGELOG_SECTION.md  # release body
#     (note: the body is only set when the release is CREATED, not on re-upload)
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
EDL_ONLY=false           # publish only the EDL bundle: no OTA zip asset, no OTA JSON
EDL_DIR="/home/kyle/android/lineage-23/flash-staging"
# config.bin is a 32 KB zero-fill (written by prepare-flash.sh) that clears a
# stale FRP token so A15+ FRP can auto-deactivate after a wipe. userdata is
# deliberately excluded — a release flash must not wipe /data as a side effect.
EDL_IMAGES=(boot.bin recovery.bin system.bin vendor.bin config.bin)
# qdl flasher bundled into the EDL package so users don't have to build one that
# works with this device. Prebuilt x86-64 Linux binary from the pepito branch of
# https://github.com/xerootg/qdl. Override the path with QDL_BIN if needed.
QDL_BIN="${QDL_BIN:-/usr/local/bin/qdl}"
QDL_SRC_URL="https://github.com/xerootg/qdl/tree/pepito"
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
# NOT $SCRIPT_DIR/..: scripts/ is symlinked into the AOSP tree, so when release.sh
# is invoked through that symlink (release-remotely.sh does `cd $REMOTE_ROOT &&
# ./scripts/release.sh`) $SCRIPT_DIR/.. resolves to the AOSP tree root — not a git
# repo — and pepito.json gets written there and never committed. Hardcode the
# landing repo (env-overridable), matching release-all.sh / release-remotely.sh.
REPO_ROOT="${REPO_ROOT:-/home/kyle/Projects/lineageos-pepito}"
GEN_JSON="$SCRIPT_DIR/gen-ota-json.py"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed -n '2,29p' | cut -c3-; exit 1; }

write_edl_readme() {
    # $1 = output path

    # Update path differs by release mode: EDL-only builds ship no OTA zip and
    # no in-app Updater feed, so the only way to move to a newer build is to
    # reflash this package.
    local update_note
    if $EDL_ONLY; then
        update_note="**Already running LineageOS and just want to update?** This release ships
as an EDL package only (no OTA zip, no in-app Updater yet), so updating means
reflashing a newer EDL package the same way — it keeps \`/data\` intact when
you're going LineageOS-to-LineageOS."
    else
        update_note="**Already running LineageOS and just want to update?** You don't need this — use
the OTA zip instead (\`adb sideload\` in recovery, or the built-in Updater)."
    fi

    cat > "$1" <<EOF
# LineageOS $VERSION for the Palm PVG100 / PVG100E ("pepito") — EDL flash package

$ROMTYPE build \`$TAG\` ($DEVICE). This is the low-level **Qualcomm EDL (9008)**
image set: raw boot / recovery / system / vendor partitions you write with the
bundled \`qdl\` when the phone won't boot or you're coming from stock Android 8.1.

Supports both hardware variants — the US **PVG100** and the international
**PVG100E**. The OS images are identical; what differs is the Firehose loader
and the partition-table XML you pass to \`qdl\`. See "Which variant do I
have?" below — **using the wrong XML writes over the wrong partitions**,
including stock firmware this package otherwise never touches (recoverable
only from a full EDL backup).

$update_note

- Project & source:  https://github.com/$REPO
- This release:      https://github.com/$REPO/releases/tag/$TAG
- The full story:    https://kyle.cascade.family/posts/porting-android-16-to-a-palm-pvg100-pepito

---

## What's in here

- \`pvg100_firehose.elf\` — signed Firehose loader for the **PVG100**
- \`pvg100e_firehose.elf\` — signed Firehose loader for the **PVG100E**
  (each variant has its own signing cert — use the one matching your phone)
- \`rawprogram0.pvg100.xml\` — **PVG100** partition table
- \`rawprogram0.pvg100e.xml\` — **PVG100E** partition table (same disk, but the
  partitions live at different offsets — the two are NOT interchangeable)
- In either XML only the boot/recovery/system/vendor/config entries are used
  here; the rest are skipped with \`--allow-missing\`.
- \`boot.bin\`, \`recovery.bin\`, \`system.bin\`, \`vendor.bin\` — the raw images
- \`config.bin\` — a 32 KB zero-fill flashed over the \`config\` partition to
  clear any stale factory-reset-protection (FRP) token, so you don't get a
  bogus "factory reset" prompt on every boot. It does **not** touch \`/data\`.
- \`qdl\` — the flasher itself, a prebuilt x86-64 Linux binary from the
  \`pepito\` branch of $QDL_SRC_URL (stock upstream qdl does not handle this
  device). Needs common shared libs (libxml2, libudev, libicu, liblzma) — on
  any modern desktop distro it just runs. If it won't, build it from that
  branch and use your own \`qdl\` instead.

This package does **not** touch modem, bootloader, TrustZone, RPM, or other
firmware partitions — those are stock, device-specific, and already on your
phone. Only boot / recovery / system / vendor are written.

## Which variant do I have?

Check the model number — it's printed on the regulatory label on the back of
the phone, on the box, and shown in stock Android under Settings → System →
About phone → Model:

- **PVG100** — the US / Verizon model
  → \`pvg100_firehose.elf\` + \`rawprogram0.pvg100.xml\`
- **PVG100E** — the international (Vodafone) model
  → \`pvg100e_firehose.elf\` + \`rawprogram0.pvg100e.xml\`

⚠️ **This matters.** The two variants place their partitions at completely
different offsets on the same-size eMMC. Flashing with the other variant's
XML writes these images over the wrong partitions — including the stock
bootloader chain and firmware regions this package otherwise never touches —
leaving the phone unbootable at best, and restorable only from a full EDL
backup. If you're not 100% sure, check the label.

## Before you start

- **Back up first.** With a full backup the PVG100 is effectively unbrickable
  over EDL. See the backup guide:
  https://xdaforums.com/t/guide-using-edl-to-backup-a-palm-pvg-100-pepito-on-linux.4719549/
- **You will lose your data.** Coming from stock (or any mismatched build) the
  first boot reformats \`/data\` for file-based encryption. Save anything you care about.
- **You need:** an x86-64 Linux machine, \`xz-utils\`, and a USB cable. \`qdl\`
  is bundled — no separate install. (Source: $QDL_SRC_URL.)

## Flashing

1. Extract this archive:

       tar xf ${TAG_BUNDLE_NAME}.tar.xz
       cd ${TAG_BUNDLE_NAME}

2. Put the phone into **EDL (9008)** mode:
   - if it still boots or reaches recovery:  \`adb reboot edl\`
   - otherwise use the PVG100 hardware key method (see the project page above).

   The screen stays black in EDL — that's expected. Confirm the phone is in EDL
   with \`lsusb\`: a \`Qualcomm ... 9008\` device should appear.

3. Flash (the bundled \`./qdl\` — root or a 9008 udev rule is needed for USB).
   **Use the loader and XML that match your variant** (see above):

   PVG100:

       sudo ./qdl --storage emmc --allow-missing pvg100_firehose.elf rawprogram0.pvg100.xml

   PVG100E:

       sudo ./qdl --storage emmc --allow-missing pvg100e_firehose.elf rawprogram0.pvg100e.xml

   \`--allow-missing\` is required: each XML lists the full stock partition
   table and only boot/recovery/system/vendor/config are included here.

4. When \`qdl\` finishes, let the phone reboot on its own. **The first boot takes
   a few minutes** while it formats \`/data\`. If it instead reboots into recovery
   asking for a factory reset, that's the encryption mismatch failing safe —
   wipe data and reboot.

## Verify your download

    sha256sum -c ${TAG_BUNDLE_NAME}.tar.xz.sha256sum

## Trouble?

- \`./qdl\` "permission denied" or no device: run it with \`sudo\`, or add a udev
  rule for the 9008 device. If the bundled binary won't run at all (missing
  libs / non-x86-64 host), build qdl from $QDL_SRC_URL.
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
        --notes-file) NOTES="$(cat "$2")"; shift 2 ;;
        --keep) KEEP="$2"; shift 2 ;;
        --edl-dir) EDL_DIR="$2"; shift 2 ;;
        --skip-edl) SKIP_EDL=true; shift ;;
        --edl-only) EDL_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *) ZIP="$1"; shift ;;
    esac
done

[[ -n "$ZIP" ]] || { echo "Usage: $0 <path-to-signed-ota-zip> [--tag T] [--notes N] [--dry-run] [--skip-edl|--edl-only] ..." >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: $ZIP does not exist" >&2; exit 1; }
if $EDL_ONLY && $SKIP_EDL; then
    echo "error: --edl-only and --skip-edl are mutually exclusive (nothing would be released)" >&2
    exit 1
fi

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

# Variant suffix for asset names. Both the vanilla and gapps builds share
# DEVICE=pepito and (now) ROMTYPE=UNOFFICIAL, so without this the two EDL
# bundles would get the same filename and clobber each other on the release.
# The gapps zip's LINEAGE_BUILD (FN_DEVICE) ends in _gapps; carry that through.
VARIANT_SUFFIX=""
if [[ "$FN_DEVICE" == *_gapps ]]; then
    VARIANT_SUFFIX="-gapps"
fi

[[ -n "$VERSION" ]] || { echo "error: couldn't parse a version from '$FILENAME' — pass --version" >&2; exit 1; }
[[ -n "$TAG" ]] || { echo "error: couldn't parse a date/tag from '$FILENAME' — pass --tag" >&2; exit 1; }

# GitHub release assets: 2 GiB per file, hard limit.
SIZE_BYTES=$(stat -c%s "$ZIP")
LIMIT_BYTES=$((2 * 1024 * 1024 * 1024))
if (( SIZE_BYTES >= LIMIT_BYTES )); then
    echo "error: $FILENAME is $(( SIZE_BYTES / 1024 / 1024 )) MB, at/over GitHub's 2 GiB release-asset limit" >&2
    exit 1
fi

# Full path, not the bare name: the other `gh` on this box is a GitHub Enterprise
# fork that defaults to the internal host. gh.com is the real github.com CLI, but
# ~/.bin isn't on PATH under a non-interactive ssh session, so hardcode it.
# (release-remotely.sh also forwards GH_HOST=github.com — the server's gh config
# defaults even this binary to the enterprise host otherwise.)
GH="${GH:-/home/kyle/.bin/gh.com}"
EDL_BUNDLE="lineage-${VERSION}-${TAG}-${ROMTYPE}-${DEVICE}${VARIANT_SUFFIX}-EDL"
TAG_BUNDLE_NAME="$EDL_BUNDLE"   # used by write_edl_readme
EDL_TAR_NAME="${EDL_BUNDLE}.tar.xz"
# Every loader/XML carries its model number explicitly so a user can never
# grab a "default" that happens to be the wrong variant — they must pick.
# PVG100E (international/Vodafone variant): same eMMC + same images, but a
# completely reshuffled GPT (its own rawprogram is mandatory — wrong XML
# writes over the wrong partitions) AND its own variant-signed loader
# ("PepitoVDF Attestation Cert1" vs the PVG100's "Pepito Attestation Cert1";
# sourced from programmer-collection/alcatel Pepito_VDF_NPRG.bin). All four
# are required inputs; E-flash confirmed working by a community E-unit
# 2026-08-02.
EDL_FIREHOSE="$EDL_DIR/pvg100_firehose.elf"
EDL_RAWPROGRAM="$EDL_DIR/rawprogram0.pvg100.xml"
EDL_FIREHOSE_E="$EDL_DIR/pvg100e_firehose.elf"
EDL_RAWPROGRAM_E="$EDL_DIR/rawprogram0.pvg100e.xml"

if ! $SKIP_EDL; then
    MISSING=()
    for f in "$EDL_FIREHOSE" "$EDL_FIREHOSE_E" "$EDL_RAWPROGRAM" "$EDL_RAWPROGRAM_E"; do
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
if $EDL_ONLY; then
    echo "  mode:      EDL-only (no OTA zip asset, no OTA JSON)"
else
    echo "  asset url: $RELEASE_URL"
    echo "  ota json:  $OTA_JSON_REL -> $RAW_URL"
fi
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

if ! $GH auth status --hostname github.com >/dev/null 2>&1; then
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

# --- OTA zip asset + sha256 sidecar (skipped in --edl-only) -----------------
if $EDL_ONLY; then
    ASSETS=()
else
    SHA_FILE="$WORK/${FILENAME}.sha256sum"
    ( cd "$(dirname "$ZIP")" && sha256sum "$FILENAME" ) > "$SHA_FILE"
    ASSETS=("$ZIP" "$SHA_FILE")
fi

# --- EDL bundle: firehose + rawprogram + raw images + README, --------------
# --- compressed as a single .tar.xz (images themselves stay uncompressed) --
if ! $SKIP_EDL; then
    echo "Building EDL bundle ($EDL_TAR_NAME)..."
    PKG_DIR="$WORK/$EDL_BUNDLE"
    mkdir -p "$PKG_DIR"

    cp "$EDL_FIREHOSE" "$PKG_DIR/"
    cp "$EDL_FIREHOSE_E" "$PKG_DIR/"
    cp "$EDL_RAWPROGRAM" "$PKG_DIR/"
    cp "$EDL_RAWPROGRAM_E" "$PKG_DIR/"

    for img in "${EDL_IMAGES[@]}"; do
        cp "$EDL_DIR/$img" "$PKG_DIR/$img"
    done

    # Bundle the qdl flasher (pepito branch of xerootg/qdl).
    [[ -f "$QDL_BIN" ]] || { echo "error: qdl binary not found at $QDL_BIN (set QDL_BIN)" >&2; exit 1; }
    cp "$QDL_BIN" "$PKG_DIR/qdl"
    chmod +x "$PKG_DIR/qdl"

    write_edl_readme "$PKG_DIR/README.md"

    echo "  compressing archive (xz -$XZ_LEVEL, multithreaded)..."
    EDL_TAR="$WORK/$EDL_TAR_NAME"
    ( cd "$WORK" && tar -cf - "$EDL_BUNDLE" | xz -T0 "-$XZ_LEVEL" -c > "$EDL_TAR_NAME" )

    EDL_SHA_FILE="$WORK/${EDL_TAR_NAME}.sha256sum"
    ( cd "$WORK" && sha256sum "$EDL_TAR_NAME" ) > "$EDL_SHA_FILE"

    ASSETS+=("$EDL_TAR" "$EDL_SHA_FILE")
fi

# --- GitHub release: create, then upload each asset with retry -------------
# The assets are large (~1 GB EDL/OTA) and the build server's network path
# intermittently corrupts a TLS record mid-transfer ("tls: bad record MAC"),
# which gh does not retry. Create the release first (empty), then upload each
# asset on its own with a retry loop; --clobber makes each upload idempotent, so
# a retry re-sends only the failed asset rather than restarting the whole set.
retry() {
    local n=0 max="${RETRY_MAX:-5}" delay="${RETRY_DELAY:-15}"
    until "$@"; do
        n=$((n + 1))
        if (( n >= max )); then
            echo "  retry: giving up after $max attempts: $*" >&2
            return 1
        fi
        echo "  retry $n/$max in ${delay}s (last attempt failed): $*" >&2
        sleep "$delay"
    done
}

if ! $GH release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    TITLE="LineageOS $VERSION $ROMTYPE $TAG ($DEVICE)"
    retry $GH release create "$TAG" --repo "$REPO" --title "$TITLE" --notes "${NOTES:-$TITLE}"
else
    echo "release $TAG already exists on $REPO — uploading assets (--clobber)"
fi
for asset in "${ASSETS[@]}"; do
    echo "uploading $(basename "$asset") ..."
    retry $GH release upload "$TAG" "$asset" --repo "$REPO" --clobber
done

# --- regenerate the OTA JSON (OTA zip only; skipped in --edl-only) ----------
if ! $EDL_ONLY; then
    # Feed datetime = the build's real timestamp (ro.build.date.utc), taken from
    # the OTA metadata's post-timestamp — NOT midnight of the date code. The
    # Updater skips any candidate whose datetime <= the installed
    # ro.build.date.utc, so a midnight stamp makes a same-day rebuild invisible
    # to a phone already on an earlier same-day build (exactly the graft-fix
    # re-release case). post-timestamp is what the device actually compares to.
    POST_TS="$(unzip -p "$ZIP" META-INF/com/android/metadata 2>/dev/null | sed -n 's/^post-timestamp=//p' | head -1)"
    [[ -n "$POST_TS" ]] || POST_TS="$(stat -c %Y "$ZIP")"   # fallback: zip mtime
    DATETIME_ARGS=(--datetime "$POST_TS")

    python3 "$GEN_JSON" "$ZIP" \
        --device "$DEVICE" \
        --version "$VERSION" \
        --romtype "$ROMTYPE" \
        --repo "$REPO" \
        --tag "$TAG" \
        --output "$OTA_JSON" \
        --keep "$KEEP" \
        "${DATETIME_ARGS[@]}"

    # --- commit + push (skipped on a .git-less mirror, see the note above) --
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
fi

echo
if $EDL_ONLY; then
    echo "Done (EDL-only: no OTA zip or JSON published)."
else
    echo "Done. OTA feed: $RAW_URL"
fi
if ! $SKIP_EDL; then
    echo "EDL bundle: $EDL_RELEASE_URL"
fi
echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
