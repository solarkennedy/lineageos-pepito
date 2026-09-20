#!/usr/bin/env bash
#
# release.sh — cut a lineageos-pepito release from an already-built OTA zip
# (and, unless --skip-edl, an already-staged EDL flash-staging/ directory).
#
# Given the signed zip you built and flash-tested yourself, this:
#   1. sanity-checks it (exists, under GitHub's 2 GiB release-asset limit)
#   2. builds an EDL bundle from flash-staging/ (per-variant firehose loaders
#      + rawprogram XMLs for both PVG100 and PVG100E, an optional
#      Magisk-patched boot image, raw
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
#     The notes are also embedded into the pepito.json entry ("changelog" /
#     "changelog_url" keys) for the Updater's "What's new" — on every variant.
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
# Shipped alongside but deliberately NOT referenced by either rawprogram XML:
# an optional, Magisk-pre-patched boot image for users who want root. Built by
# prepare-flash.sh via make-magisk-boot.sh. Users can't roll their own —
# magiskboot fails to parse our fail-open signature block and repacks the image
# unsigned, which aboot refuses (splash hang). The graft is hardcoded, so this
# image carries the same Root of Trust as boot.bin: swapping between the two
# does not re-derive FBE keys and does not wipe /data. Required input, so a
# release can never silently ship without it (build it, or --skip-edl).
EDL_EXTRA_IMAGES=(boot-magisk.bin)
MAGISK_VERSION="v30.7"   # keep in sync with prebuilts/Magisk-*.apk
# qdl flasher bundled into the EDL package so users don't have to build one.
# Prebuilt x86-64 Linux binary of modern upstream linux-msm/qdl (adds read
# support, used by the bundled qdl-dump.sh backup script; the old xerootg
# pepito fork is only still needed for <erase> tags, which nothing here uses).
# rsync'd to the build server at ~/.local/bin/qdl; override with QDL_BIN.
QDL_BIN="${QDL_BIN:-$HOME/.local/bin/qdl}"
QDL_SRC_URL="https://github.com/linux-msm/qdl"
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
- \`boot-magisk.bin\` — **optional**: the same boot image, pre-patched with
  Magisk $MAGISK_VERSION for root. Not used by either XML — see "Root (optional)"
  below. Ignore this file if you don't want root.
- \`config.bin\` — a 32 KB zero-fill flashed over the \`config\` partition to
  clear any stale factory-reset-protection (FRP) token, so you don't get a
  bogus "factory reset" prompt on every boot. It does **not** touch \`/data\`.
- \`qdl\` — the flasher itself, a prebuilt x86-64 Linux binary of upstream
  $QDL_SRC_URL (which also does EDL *reads* — that's what the backup script
  uses). Needs common shared libs (libusb-1.0, libxml2 and their usual
  dependencies) — on any modern desktop distro it just runs. If it won't,
  build it from that repo (\`meson setup build && ninja -C build\`; add
  \`-Dzip-container=disabled\` if you lack libzip) and use your own \`qdl\`.
- \`qdl-dump.sh\` — backup script for **Linux and macOS**: dumps every
  partition to its own \`.bin\` plus generated XML manifests. See step 3.
- \`fh_dump.py\` — the same backup for **Windows**, where \`qdl\` cannot read
  this phone. Read-only; contributed by a PVG100 owner. See step 3.

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

- **Back up first** (step 3). With a full backup the PVG100 is effectively
  unbrickable over EDL, and a backup is the ONLY way back to stock or out of a
  wrong-variant flash. Please don't skip it because it's inconvenient.
- **You will lose your data.** Coming from stock (or any mismatched build) the
  first boot needs \`/data\` reformatted for file-based encryption. Save anything
  you care about.
- **Any of Linux, macOS or Windows works.** What each one uses:

  | | Flashing | Backup |
  |---|---|---|
  | **Linux** (x86-64) | bundled \`./qdl\` | bundled \`./qdl-dump.sh\` (needs \`python3\`) |
  | **Linux** (other CPUs), **macOS** | \`qdl\` from upstream (download or Homebrew-build) | bundled \`./qdl-dump.sh\` with that \`qdl\` (needs \`python3\`) |
  | **Windows** | \`qdl.exe\` from upstream | bundled \`fh_dump.py\` (needs Python + \`pyserial\`) |

  Tested: Linux (every release) and Windows 11 (user-reported, 20260915 build).
  macOS uses the same USB code path as Linux but nobody has reported a run yet —
  if you try it, please tell us how it went: https://github.com/$REPO/issues

Everywhere below, **PVG100E owners substitute** \`pvg100e_firehose.elf\` and
\`rawprogram0.pvg100e.xml\` for the PVG100 file names (see above — this matters).

## Step 1 — Get the tools and extract the package

**Linux**

    sudo apt install xz-utils python3        # or your distro's equivalent
    tar xf ${TAG_BUNDLE_NAME}.tar.xz
    cd ${TAG_BUNDLE_NAME}

The bundled \`./qdl\` is an x86-64 binary. On another CPU (or if it won't
start), download \`qdl-binary-ubuntu-*\` from $QDL_SRC_URL/releases
(v2.8 or newer) or build it (\`meson setup build && ninja -C build\`), and use
that \`qdl\` wherever these steps say \`./qdl\`. USB access needs root (\`sudo\`,
as shown) or a udev rule for \`05c6:9008\`.

**macOS**

    tar xf ${TAG_BUNDLE_NAME}.tar.xz
    cd ${TAG_BUNDLE_NAME}

Download \`qdl-binary-macos-arm64-*.zip\` (Apple Silicon) or
\`qdl-binary-macos-intel-*.zip\` from $QDL_SRC_URL/releases (v2.8 or
newer), unzip it and copy its \`qdl\` **over** the bundled Linux \`./qdl\` in this
folder. macOS quarantines downloaded binaries; clear that once with
\`xattr -dr com.apple.quarantine ./qdl\`. No \`sudo\` and no driver needed.
\`python3\` comes with the Xcode command line tools (\`xcode-select --install\`).
(Prefer to build? \`brew install libxml2 libusb libzip meson ninja\`, then
\`meson setup build && ninja -C build\` in a checkout of that repo.)

**Windows**

1. Extract this archive — 7-Zip opens \`.tar.xz\` (extract twice: \`.xz\`, then
   \`.tar\`).
2. Download \`qdl-binary-windows-x64-*.zip\` from $QDL_SRC_URL/releases
   (v2.8 or newer) and unzip its contents **into the extracted folder**, next
   to the \`.elf\` and \`.bin\` files. The bundled \`qdl\` (no \`.exe\`) is the Linux
   binary — ignore it.
3. For the backup: install Python 3 from https://www.python.org/downloads/ (tick
   "Add python.exe to PATH"), then in a terminal: \`pip install pyserial\`.
4. Driver: with the phone in EDL (step 2) Device Manager must show **Qualcomm
   HS-USB QDLoader 9008 (COMx)** under *Ports*. Windows often has this driver
   already; if the phone shows up as an unknown \`QUSB_BULK\` device instead,
   install the Qualcomm (or Quectel) QDLoader USB driver. **No Zadig / WinUSB
   swap** — qdl talks to the COM port directly. Note the COM number for step 3.

Open a terminal (PowerShell is fine) in the extracted folder for the rest.

## Step 2 — Put the phone into EDL (9008) mode

- If it still boots or reaches recovery:  \`adb reboot edl\`
- Otherwise use the PVG100 hardware key method (see the project page above).

The screen stays black in EDL — that's expected. Confirm it arrived:

- Linux: \`lsusb\` shows a \`Qualcomm ... 9008\` device
- macOS: \`system_profiler SPUSBDataType | grep -i -A3 qualcomm\`, or look for
  \`QUSB_BULK\` in *System Information → USB*
- Windows: Device Manager → *Ports* → *Qualcomm HS-USB QDLoader 9008 (COMx)*

## Step 3 — Back up

Either tool reads the phone's partition table and dumps **every partition** —
including your stock firmware and modem calibration — to per-partition \`.bin\`
files, plus \`gpt-lun0.bin\` and two generated manifests: \`readback.xml\` (what
was read) and \`rawprogram_restore.xml\` (how to write it back). The phone is
left in EDL afterwards, ready for step 4.

A full dump is ~29 GB and slow (an hour or more). Add \`--exclude userdata\` to
skip the data partition — it is encrypted and useless without the exact boot
chain that created it — which shrinks the backup to ~7 GB.

**Linux**

    sudo ./qdl-dump.sh pvg100_firehose.elf backup-\$(date +%F) --exclude userdata

**macOS** (same script, no \`sudo\`)

    ./qdl-dump.sh pvg100_firehose.elf backup-\$(date +%F) --exclude userdata

**Windows** — \`qdl.exe\` can flash this phone but cannot *read* it over the COM
port: the PVG100's loader sends the sector data before its XML reply and never
announces raw mode, so qdl throws the data away (\`failed to read sector data\` /
\`unable to determine sector size for read operation\`). The bundled
\`fh_dump.py\` is a small read-only dumper that copes with that ordering; the
only commands it ever sends the phone are \`<configure>\` and \`<read>\`.

1. It needs the Firehose loader already running on the phone, and uploading it
   is qdl's job. Run one read with qdl — **it is expected to fail** with the
   error above, but the loader stays resident:

       .\qdl.exe --storage emmc --skip-reset pvg100_firehose.elf read 0/0+34 gpt-test.bin

2. Dump, using the COM number from Device Manager:

       python fh_dump.py COM10 backup-today --exclude userdata --rom-xml rawprogram0.pvg100.xml

   \`--rom-xml\` also cross-checks the phone's real partition table against the
   XML you are about to flash with. It must report \`OK - every partition offset
   and size matches\`. **If it reports mismatches, stop** — you have picked the
   wrong variant's XML (or have an unusual unit); do not flash, open an issue.
   It writes \`SHA256SUMS.txt\` next to the images. Expect ~12 MiB/s.

**Restoring a backup** (any OS, phone in EDL, from this folder; Windows:
\`.\qdl.exe\` and no \`sudo\`):

    sudo ./qdl --storage emmc --include backup-DATE pvg100_firehose.elf backup-DATE/rawprogram_restore.xml

Keep the backup somewhere safe — it contains your phone's unique calibration
and IMEI data and cannot be recreated from anyone else's phone.
Alternative manual guide (Linux, \`edl\` tool):
https://xdaforums.com/t/guide-using-edl-to-backup-a-palm-pvg-100-pepito-on-linux.4719549/

## Step 4 — Flash

**Use the loader and XML that match your variant** (see above).

Linux:

    sudo ./qdl --storage emmc --allow-missing pvg100_firehose.elf rawprogram0.pvg100.xml

macOS:

    ./qdl --storage emmc --allow-missing pvg100_firehose.elf rawprogram0.pvg100.xml

Windows:

    .\qdl.exe --storage emmc --allow-missing pvg100_firehose.elf rawprogram0.pvg100.xml

PVG100E, any OS: the same command with \`pvg100e_firehose.elf
rawprogram0.pvg100e.xml\`.

\`--allow-missing\` is required: each XML lists the full stock partition table
and only boot/recovery/system/vendor/config are included here. On Windows one
\`failed to read sector data\` line at the start is harmless (it is the read
problem described in step 3; writes are unaffected). If qdl complains that the
device is already in Firehose mode after a backup, that is fine — it carries on.

## Step 5 — First boot

When \`qdl\` finishes, let the phone reboot on its own. **The first boot takes a
few minutes.** Coming from stock, \`/data\` has to be reformatted:

- If it reboots into recovery asking for a factory reset, that's the encryption
  mismatch failing safe — choose *Factory reset → Format data*, then reboot.
- If it boot-loops without ever reaching recovery, hold **Power** continuously
  through three reboots until "Entering Recovery Mode" appears, then do the
  same *Factory reset → Format data*.

## Root (optional)

\`boot-magisk.bin\` is this build's boot image with Magisk $MAGISK_VERSION already
patched in. **You cannot make your own** by running our \`boot.bin\` through the
Magisk app: this device's bootloader needs a signature block that \`magiskboot\`
can't parse, so it silently repacks the image unsigned and the phone then hangs
at the PALM splash. Use this file instead.

To use it, put it in \`boot.bin\`'s place before step 4 (Flash)
above — neither XML names \`boot-magisk.bin\`, they flash whatever file is called
\`boot.bin\`:

    mv boot.bin boot-stock.bin
    mv boot-magisk.bin boot.bin

then run the same \`qdl\` command as above. To go back to un-rooted later, undo
the rename and reflash. (Already rooted and just swapping boot images? \`dd\` the
file over \`/dev/block/bootdevice/by-name/boot\` instead — no EDL needed.)

Once it boots, install the Magisk app (https://github.com/topjohnwu/Magisk/releases,
version $MAGISK_VERSION) to manage it. Root is not required to use this ROM and is
not supported — you're on your own with it.

The first time you open the app it will ask to do some **"additional setup"** and
then reboot. That is expected and safe: the boot image ships only the minimum
Magisk needs to start, and this step installs the rest into \`/data/adb/magisk\`.
It does **not** touch the boot partition — verified: the partition's checksum is
byte-for-byte unchanged afterwards.

Modules work, including Zygisk ones: enable Zygisk in the app's settings if a
module asks for it. Modules that ship custom SELinux rules work too — the image
is built with a pre-init storage partition configured, which is what lets those
rules reach the kernel policy at boot.

⚠️ **Do not use Magisk's "Direct Install"** to update Magisk later. It re-patches
the live boot partition and strips the signature block, which puts you back at
the splash hang with no way out but EDL. Reflash \`boot.bin\` (or a newer
\`boot-magisk.bin\`) instead.

Both images share the same verified-boot Root of Trust, so switching either
direction keeps \`/data\` and its encryption intact — no wipe, no re-setup.

## Verify your download

    sha256sum -c ${TAG_BUNDLE_NAME}.tar.xz.sha256sum

## Trouble?

- Linux: \`./qdl\` "permission denied" or no device — run it with \`sudo\`, or
  add a udev rule for the 9008 device. If the bundled binary won't run at all
  (missing libs / non-x86-64 host), use an upstream build (step 1).
- macOS: "cannot be opened because the developer cannot be verified" — clear
  the quarantine flag (step 1).
- Windows: qdl finds no device — check Device Manager shows the *QDLoader 9008*
  COM port, not \`QUSB_BULK\`/WinUSB (step 1). \`fh_dump.py\` "timed out waiting
  for XML" — the loader isn't running yet; do the qdl read in step 3 first, and
  make sure nothing else (a serial terminal, another qdl) holds the COM port.
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
    for img in "${EDL_IMAGES[@]}" "${EDL_EXTRA_IMAGES[@]}"; do
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

    for img in "${EDL_IMAGES[@]}" "${EDL_EXTRA_IMAGES[@]}"; do
        cp "$EDL_DIR/$img" "$PKG_DIR/$img"
    done

    # Bundle the qdl flasher (modern linux-msm/qdl — must have read support,
    # the bundled qdl-dump.sh backup script depends on it).
    [[ -f "$QDL_BIN" ]] || { echo "error: qdl binary not found at $QDL_BIN (set QDL_BIN)" >&2; exit 1; }
    "$QDL_BIN" --help 2>&1 | grep -q "read-xml" \
        || { echo "error: $QDL_BIN has no read support (old fork?) — bundle linux-msm qdl" >&2; exit 1; }
    cp "$QDL_BIN" "$PKG_DIR/qdl"
    chmod +x "$PKG_DIR/qdl"

    # Backup script (see the "Back up first" section of the README).
    cp "$SCRIPT_DIR/qdl-dump.sh" "$PKG_DIR/qdl-dump.sh"
    chmod +x "$PKG_DIR/qdl-dump.sh"
    # Windows equivalent: qdl's COM-port backend cannot read this phone.
    cp "$SCRIPT_DIR/fh_dump.py" "$PKG_DIR/fh_dump.py"

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

    # Embed the release notes into this entry as optional "changelog" /
    # "changelog_url" keys (ignored by the stock Updater, shown as "What's new"
    # by ours). Applied to every variant of the day, even when the GitHub
    # release already existed and the body was left alone.
    CHANGELOG_ARGS=()
    NOTES_TMP=""
    if [[ -n "$NOTES" ]]; then
        NOTES_TMP="$(mktemp)"
        printf '%s\n' "$NOTES" > "$NOTES_TMP"
        CHANGELOG_ARGS=(--changelog-file "$NOTES_TMP"
                        --changelog-url "https://github.com/$REPO/releases/tag/$TAG")
    else
        echo "note: no --notes/--notes-file, so no changelog embedded in $OTA_JSON_REL" >&2
    fi

    python3 "$GEN_JSON" "$ZIP" \
        --device "$DEVICE" \
        --version "$VERSION" \
        --romtype "$ROMTYPE" \
        --repo "$REPO" \
        --tag "$TAG" \
        --output "$OTA_JSON" \
        --keep "$KEEP" \
        "${DATETIME_ARGS[@]}" \
        "${CHANGELOG_ARGS[@]}"
    [[ -n "$NOTES_TMP" ]] && rm -f "$NOTES_TMP"

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
