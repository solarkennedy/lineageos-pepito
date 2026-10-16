#!/usr/bin/env bash
#
# release.sh — cut a lineageos-pepito release from an already-built OTA zip.
#
# ONE zip per flavor is published. It is the OTA zip the build produced, with
# our README and the EDL flashing kit added and the whole file re-signed, so
# the same download serves both uses:
#   - an update: the Updater or `adb sideload` installs it like any OTA (the
#     extra files are ignored by the installer);
#   - a first install over EDL: the user extracts it and runs the bundled
#     ota2raw converter, which rebuilds the raw boot/recovery/system/vendor
#     images qdl needs from the OTA payload. The images are not shipped twice.
#
# Given the signed zip you built, this:
#   1. sanity-checks it (exists, signed with our release key)
#   2. stages the kit: README.md at the top of the zip, and under edl/ the
#      per-variant firehose loaders + rawprogram XMLs (PVG100 and PVG100E),
#      the Magisk-patched boot image, qdl, the backup scripts, ota2raw for
#      Linux/macOS/Windows (tools/ota2raw, cross-compiled here), and
#      manifest.json (what ota2raw builds, with the SHA-256 each image must
#      have, taken from independent references: see OTA_BLOCK_IMAGES below)
#   3. appends the kit to a copy of the zip and re-signs it with the release
#      key (signapk -w, the same whole-file signature the build applied)
#   4. verifies the result: signature, OTA metadata offsets, and a full
#      ota2raw conversion that must reproduce those references byte for byte
#   5. creates (or reuses) a GitHub Release and uploads the zip + .sha256sum
#   6. regenerates <device>.json (repo root — see note by OTA_JSON_REL below)
#      via gen-ota-json.py
#   7. commits and pushes that JSON to the branch lineage_updater_uri points at
#
# Everything except the build itself. Requires `gh` authenticated for the repo.
#
#   ./scripts/release.sh <zip>
#   ./scripts/release.sh <zip> --tag 20260716 --notes "Fixes X, Y"
#   ./scripts/release.sh <zip> --dry-run       # print the plan, do nothing
#   ./scripts/release.sh <zip> --package-only  # build + verify the release zip
#                                              # in --dist-dir, publish nothing
#   ./scripts/release.sh <zip> --skip-edl      # publish the zip as built, no kit
#   ./scripts/release.sh <zip> --no-feed       # publish the zip, but leave the
#                                              # Updater feed (JSON) alone
#   ./scripts/release.sh <zip> --notes-file CHANGELOG_SECTION.md  # release body
#     (note: the body is only set when the release is CREATED, not on re-upload)
#     The notes are also embedded into the pepito.json entry ("changelog" /
#     "changelog_url" keys) for the Updater's "What's new" — on every variant.
#
# Device/version/romtype/date are parsed from a standard LineageOS filename
# (lineage-<version>-<YYYYMMDD>-<romtype>-<device>[-signed].zip); override any
# of them with flags if your filename doesn't match.
#
# The kit inputs are read from --edl-dir (default: flash-staging/ in the
# lineage-24 tree), already populated by prepare-flash.sh FOR THE SAME BUILD as
# the zip, and from that build's target-files IMAGES/ (still in out/ right after
# the build). Step 4 fails if either disagrees with the zip's payload.
#
set -euo pipefail

# --- defaults ---------------------------------------------------------------
REPO="solarkennedy/lineageos-pepito"
BRANCH="lineageos24.0"   # must match the branch lineage.updater.uri points at
KEEP=5                   # entries to keep per romtype in the OTA JSON
DEVICE=""
VERSION=""
ROMTYPE=""
TAG=""
NOTES=""
DRY_RUN=false
ASSUME_YES=false
SKIP_EDL=false           # publish the zip exactly as built: no README, no EDL kit
NO_FEED=false            # publish the zip but do not touch the Updater feed (JSON)
PACKAGE_ONLY=false       # build + verify the release zip, then stop
TREE="${LINEAGE_ROOT:-/home/kyle/android/lineage-24}"
EDL_DIR="$TREE/flash-staging"
# Where the repackaged zip is written (and kept, so it can be test-flashed).
DIST_DIR="${DIST_DIR:-$TREE/release-dist}"
# The images ota2raw rebuilds from the OTA payload. None of them is shipped as
# a file; a reference copy's SHA-256 goes into edl/manifest.json and is what
# ota2raw's output must match.
#
# boot/recovery/config/splash: the reference is the copy prepare-flash.sh
# staged (boot.img/recovery.img zero-padded to the partition size, a 32 KB
# zero-fill that clears a stale FRP token so A15+ FRP can auto-deactivate after
# a wipe, and the boot logo: the build's splash.img, which the OTA carries as
# firmware-update/splash.img and writes itself). userdata is deliberately
# excluded — a release flash must not wipe /data as a side effect.
EDL_IMAGES=(boot.bin recovery.bin config.bin splash.bin)
# system/vendor: the reference is the target-files image the OTA payload was
# generated from (IMAGES/<part>.img, desparsified with simg2img), NOT the
# system.bin/vendor.bin in flash-staging/. Those come from out/<part>.img, a
# separate image build: same files, but real timestamps instead of the OTA's
# fixed ones, and its vendor lacks the three files target-files packaging adds
# (bin/install-recovery.sh, etc/recovery.img, lib/modules/modules.load). So an
# EDL install from this zip is byte-identical to a phone updated by OTA, which
# the old out/-based EDL bundle never was.
OTA_BLOCK_IMAGES=(system vendor)
SIMG2IMG="$TREE/out/host/linux-x86/bin/simg2img"
# <out>/obj/PACKAGING/target_files_intermediates/<product>-target_files/IMAGES;
# derived from the zip unless set (--target-images-dir).
TARGET_IMAGES_DIR="${TARGET_IMAGES_DIR:-}"
# Shipped in edl/ as a file (it cannot be derived from the OTA payload) but
# deliberately NOT referenced by either rawprogram XML: an optional,
# Magisk-pre-patched boot image for users who want root. Built by
# prepare-flash.sh via make-magisk-boot.sh. Users can't roll their own —
# magiskboot fails to parse our fail-open signature block and repacks the image
# unsigned, which aboot refuses (splash hang). The graft is hardcoded, so this
# image carries the same Root of Trust as boot.bin: swapping between the two
# does not re-derive FBE keys and does not wipe /data. Required input, so a
# release can never silently ship without it (build it, or --skip-edl).
EDL_EXTRA_IMAGES=(boot-magisk.bin)
MAGISK_VERSION="v30.7"   # keep in sync with prebuilts/Magisk-*.apk
# qdl flasher bundled into the kit so users don't have to build one.
# Prebuilt x86-64 Linux binary of modern upstream linux-msm/qdl (adds read
# support, used by the bundled qdl-dump.sh backup script; the old xerootg
# pepito fork is only still needed for <erase> tags, which nothing here uses).
# rsync'd to the build server at ~/.local/bin/qdl; override with QDL_BIN.
QDL_BIN="${QDL_BIN:-$HOME/.local/bin/qdl}"
QDL_SRC_URL="https://github.com/linux-msm/qdl"
# The web flasher (docs/flasher, served by GitHub Pages from this branch). The
# bundled README sends first-time installers there; qdl is the fallback.
FLASHER_URL="https://solarkennedy.github.io/lineageos-pepito/flasher/"
# Release key the build signed the OTA with (PRODUCT_OTA_PUBLIC_KEYS in
# vendor/lineage-priv/keys/keys.mk); the repackaged zip is re-signed with it.
# Path without the .pk8 / .x509.pem suffix.
OTA_KEY="${OTA_KEY:-$TREE/vendor/lineage-priv/keys/releasekey}"
# Host tools from the build (out/host) used to re-sign and to check the result.
SIGNAPK_JAR="$TREE/out/host/linux-x86/framework/signapk.jar"
SIGNAPK_LIBS="$TREE/out/host/linux-x86/lib64"
JAVA="${JAVA:-$TREE/prebuilts/jdk/jdk21/linux-x86/bin/java}"
CHECK_OTA_SIG="$TREE/out/host/linux-x86/bin/check_ota_package_signature"
# --------------------------------------------------------------------------

# --- run-location guard -----------------------------------------------------
# release.sh must run ON the build server: the freshly built zip, flash-staging/,
# the release key and the build's host tools (signapk) all live there. From the netbook use scripts/release-remotely.sh
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
REPO_ROOT="${REPO_ROOT:-/home/kyle/Projects/lineageos-pepito-24}"
GEN_JSON="$SCRIPT_DIR/gen-ota-json.py"
OTA2RAW_SRC="$REPO_ROOT/tools/ota2raw"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed -n '2,54p' | cut -c3-; exit 1; }

write_readme() {
    # $1 = output path. Lands at the top level of the release zip.
    cat > "$1" <<EOF
# LineageOS $VERSION for the Palm PVG100 / PVG100E ("pepito")

$ROMTYPE build \`$TAG\` ($DEVICE), file \`$FILENAME\`. This one zip is two things:

1. **An update package.** If your phone already runs this LineageOS, install
   the zip as it is: the built-in Updater offers it, or use \`adb sideload\` in
   recovery. You do not need anything below.
2. **A first-install kit** for a phone that is still on stock Android 8.1, or
   that won't boot: this README plus the \`edl/\` folder. It writes the boot,
   recovery, system and vendor partitions over **Qualcomm EDL (9008)**.

**The easy way to do a first install is the web flasher:**

> **$FLASHER_URL**

Open it in Chrome or Edge. It walks you through everything on this page —
converting the images, EDL mode, the backup and the flash — with no tools to
install, and it reads the phone's own partition table instead of trusting an
XML file, so the wrong-variant mistake described below cannot happen. Use it
unless you have a reason not to. The rest of this README is the command-line
route with \`qdl\`, for when you can't use a Chromium browser or want to script
the install.

The partition images are not in the zip twice. For a first install you run the
included converter, \`ota2raw\`, once: it rebuilds the raw images \`qdl\` needs
from the update payload and checks each one against a known checksum.

Supports both hardware variants — the US **PVG100** and the international
**PVG100E**. The OS images are identical; what differs is the Firehose loader
and the partition-table XML you pass to \`qdl\`. See "Which variant do I
have?" below — **using the wrong XML writes over the wrong partitions**,
including stock firmware this kit otherwise never touches (recoverable
only from a full EDL backup).

- Project & source:  https://github.com/$REPO
- This release:      https://github.com/$REPO/releases/tag/$TAG
- The full story:    https://kyle.cascade.family/posts/porting-android-16-to-a-palm-pvg100-pepito

---

## What's in here

At the top level, next to this README, is the update payload
(\`system.new.dat.br\`, \`vendor.new.dat.br\`, \`boot.img\`, \`recovery.img\`,
\`firmware-update/splash.img\`, \`META-INF/\` and friends). Leave those files where they are; \`ota2raw\` reads
them.

In \`edl/\`:

- \`ota2raw-<os>-<cpu>\` — the converter, one build per system:
  \`linux-x86_64\`, \`linux-arm64\`, \`macos-arm64\` (Apple Silicon),
  \`macos-x86_64\` (Intel) and \`windows-x86_64.exe\`. Standalone programs,
  nothing to install. Source: https://github.com/$REPO/tree/$BRANCH/tools/ota2raw
- \`manifest.json\` — what \`ota2raw\` builds and the checksum of each image
- \`pvg100_firehose.elf\` — signed Firehose loader for the **PVG100**
- \`pvg100e_firehose.elf\` — signed Firehose loader for the **PVG100E**
  (each variant has its own signing cert — use the one matching your phone)
- \`rawprogram0.pvg100.xml\` — **PVG100** partition table
- \`rawprogram0.pvg100e.xml\` — **PVG100E** partition table (same disk, but the
  partitions live at different offsets — the two are NOT interchangeable)
- In either XML only the boot/recovery/system/vendor/config/splash entries are
  used here; the rest are skipped with \`--allow-missing\`.
- \`boot-magisk.bin\` — **optional**: the boot image pre-patched with
  Magisk $MAGISK_VERSION for root. Not used by either XML — see "Root (optional)"
  below. Ignore this file if you don't want root.
- \`qdl\` — the flasher itself, a prebuilt x86-64 Linux binary of upstream
  $QDL_SRC_URL (which also does EDL *reads* — that's what the backup script
  uses). Needs common shared libs (libusb-1.0, libxml2 and their usual
  dependencies) — on any modern desktop distro it just runs. If it won't,
  build it from that repo (\`meson setup build && ninja -C build\`; add
  \`-Dzip-container=disabled\` if you lack libzip) and use your own \`qdl\`.
- \`qdl-dump.sh\` — backup script for **Linux and macOS**: dumps every
  partition to its own \`.bin\` plus generated XML manifests. See step 3.
- \`fh_dump.py\` — the same backup for **Windows**, where \`qdl\` cannot read
  this phone. Read-only. See step 3.

\`ota2raw\` adds these to \`edl/\` (step 1):

- \`boot.bin\`, \`recovery.bin\`, \`system.bin\`, \`vendor.bin\` — the raw images
- \`config.bin\` — a 32 KB zero-fill flashed over the \`config\` partition to
  clear any stale factory-reset-protection (FRP) token, so you don't get a
  bogus "factory reset" prompt on every boot. It does **not** touch \`/data\`.
- \`splash.bin\` — the boot logo (PALM, which the boot animation then fades
  out). It is the first 128 KB of the \`splash\` partition; the rest of that
  partition is left as it is. Every OTA update writes it too.

This kit does **not** touch modem, bootloader, TrustZone, RPM, or other
firmware partitions — those are stock, device-specific, and already on your
phone. Only boot / recovery / system / vendor / config, and the boot-logo part
of splash, are written.

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
bootloader chain and firmware regions this kit otherwise never touches —
leaving the phone unbootable at best, and restorable only from a full EDL
backup. If you're not 100% sure, check the label.

## Before you start

- **Back up first** (step 3). With a full backup the PVG100 is effectively
  unbrickable over EDL, and a backup is the ONLY way back to stock or out of a
  wrong-variant flash. Please don't skip it because it's inconvenient.
- **You will lose your data.** Coming from stock (or any mismatched build) the
  first boot needs \`/data\` reformatted for file-based encryption. Save anything
  you care about.
- **Disk space:** about 7 GB free for the zip, its extracted copy and the
  converted images, and another 8 GB for the backup.
- **Any of Linux, macOS or Windows works.** What each one uses:

  | | Converting | Flashing | Backup |
  |---|---|---|---|
  | **Linux** (x86-64) | bundled \`ota2raw\` | bundled \`./qdl\` | bundled \`./qdl-dump.sh\` (needs \`python3\`) |
  | **Linux** (arm64), **macOS** | bundled \`ota2raw\` | \`qdl\` from upstream (download or Homebrew-build) | bundled \`./qdl-dump.sh\` with that \`qdl\` (needs \`python3\`) |
  | **Windows** | bundled \`ota2raw\` | \`qdl.exe\` from upstream | bundled \`fh_dump.py\` (needs Python + \`pyserial\`) |

  Tested: Linux (every release) and Windows 11 flashing (user-reported,
  20260915 build). macOS uses the same USB code path as Linux but nobody has
  reported a run yet, and the macOS and Windows builds of \`ota2raw\` are new —
  if you try them, please tell us how it went: https://github.com/$REPO/issues

Everywhere below, **PVG100E owners substitute** \`pvg100e_firehose.elf\` and
\`rawprogram0.pvg100e.xml\` for the PVG100 file names (see above — this matters).

## Step 1 — Extract the zip and convert the images

This step is the same for the web flasher and for the command line. After it,
web flasher users go back to the page and point it at the \`edl\` folder;
everything from step 2 on is the command-line route.

Every command from here on is run **inside the \`edl\` folder**.

**Linux**

    unzip $FILENAME -d lineage-pepito
    cd lineage-pepito/edl
    chmod +x ota2raw-linux-x86_64
    ./ota2raw-linux-x86_64

(\`ota2raw-linux-arm64\` on an ARM machine.) It takes a minute or two, prints
\`verified\` for each image, and makes \`qdl\` and \`qdl-dump.sh\` executable.

The bundled \`./qdl\` is an x86-64 binary. On another CPU (or if it won't
start), download \`qdl-binary-ubuntu-*\` from $QDL_SRC_URL/releases
(v2.8 or newer) or build it (\`meson setup build && ninja -C build\`), and use
that \`qdl\` wherever these steps say \`./qdl\`. USB access needs root (\`sudo\`,
as shown) or a udev rule for \`05c6:9008\`. The backup script needs \`python3\`.

**macOS**

    unzip $FILENAME -d lineage-pepito
    cd lineage-pepito/edl
    xattr -dr com.apple.quarantine .
    chmod +x ota2raw-macos-arm64
    ./ota2raw-macos-arm64

(\`ota2raw-macos-x86_64\` on an Intel Mac.) The \`xattr\` line clears the
quarantine flag macOS puts on downloaded programs.

Then download \`qdl-binary-macos-arm64-*.zip\` (Apple Silicon) or
\`qdl-binary-macos-intel-*.zip\` from $QDL_SRC_URL/releases (v2.8 or
newer), unzip it and copy its \`qdl\` **over** the bundled Linux \`./qdl\` in this
folder, and clear its quarantine flag too (\`xattr -dr com.apple.quarantine ./qdl\`).
No \`sudo\` and no driver needed. \`python3\` comes with the Xcode command line
tools (\`xcode-select --install\`).
(Prefer to build? \`brew install libxml2 libusb libzip meson ninja\`, then
\`meson setup build && ninja -C build\` in a checkout of that repo.)

**Windows**

1. Right-click the zip → *Extract All*, then open the extracted \`edl\` folder.
2. Double-click \`ota2raw-windows-x86_64.exe\`. Windows may warn that it is an
   unrecognised app (it is not code-signed): *More info* → *Run anyway*. A
   console window shows the progress; wait for \`Done\`.
3. Download \`qdl-binary-windows-x64-*.zip\` from $QDL_SRC_URL/releases
   (v2.8 or newer) and unzip its contents **into the \`edl\` folder**, next
   to the \`.elf\` and \`.bin\` files. The bundled \`qdl\` (no \`.exe\`) is the Linux
   binary — ignore it.
4. For the backup: install Python 3 from https://www.python.org/downloads/ (tick
   "Add python.exe to PATH"), then in a terminal: \`pip install pyserial\`.
5. Driver: with the phone in EDL (step 2) Device Manager must show **Qualcomm
   HS-USB QDLoader 9008 (COMx)** under *Ports*. Windows often has this driver
   already; if the phone shows up as an unknown \`QUSB_BULK\` device instead,
   install the Qualcomm (or Quectel) QDLoader USB driver. **No Zadig / WinUSB
   swap** for this command-line route — qdl talks to the COM port directly.
   (The web flasher is the opposite: it needs WinUSB. Its page explains; don't
   mix the two setups.) Note the COM number for step 3.

Open a terminal (PowerShell is fine) in the \`edl\` folder for the rest.

**Short on disk space?** \`ota2raw\` can read the zip directly, so only the
\`edl\` folder needs extracting: \`unzip $FILENAME 'edl/*'\`, then
\`cd edl\` and \`./ota2raw-linux-x86_64 -o . ../$FILENAME\`.

## Step 2 — Put the phone into EDL (9008) mode

- With adb: \`adb reboot edl\`, from Android (turn on USB debugging in
  Developer options first) or from recovery.
- From the recovery menu: hold the power button down through three restarts
  until "Entering Recovery Mode" appears, then choose *Advanced → Reboot to
  EDL* (LineageOS recovery) or *Emergency Download Mode* (stock recovery; a
  short press moves down, a long press selects).
- With an EDL cable, for a phone that will not start: with the phone off, hold
  the cable's button, plug it in, and let go after a few seconds.

The web flasher page above has videos of the last two.

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
chain that created it — which shrinks the backup to about 8 GB (about 6 GB on a PVG100E).

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

**Restoring a backup** (any OS, phone in EDL, from the \`edl\` folder; Windows:
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
and only boot/recovery/system/vendor/config are provided here. On Windows one
\`failed to read sector data\` line at the start is harmless (it is the read
problem described in step 3; writes are unaffected). If qdl complains that the
device is already in Firehose mode after a backup, that is fine — it carries on.

If qdl finishes almost instantly and wrote nothing, the \`.bin\` images are
missing: run \`ota2raw\` first (step 1).

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

To use it, put it in \`boot.bin\`'s place after step 1 and before step 4 (Flash)
above — neither XML names \`boot-magisk.bin\`, they flash whatever file is called
\`boot.bin\`:

    mv boot.bin boot-stock.bin
    mv boot-magisk.bin boot.bin

then run the same \`qdl\` command as above. To go back to un-rooted later, undo
the rename and reflash. (Already rooted and just swapping boot images? \`dd\` the
file over \`/dev/block/bootdevice/by-name/boot\` instead — no EDL needed.)

Installing a later update through the Updater or \`adb sideload\` writes the
plain boot image again, so root is gone until you flash that release's
\`boot-magisk.bin\`.

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

    sha256sum -c ${FILENAME}.sha256sum

\`ota2raw\` also checks every image it writes against the checksum recorded in
\`edl/manifest.json\` at release time, and refuses to finish on a mismatch.

## Trouble?

- \`ota2raw\` says \`CHECKSUM MISMATCH\` or \`truncated or corrupt\` — the download
  is damaged. Fetch the zip again and verify it (above). Do not flash.
- Linux/macOS: \`ota2raw\` "permission denied" — \`chmod +x\` it (step 1); zip
  files don't carry the executable flag here.
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
        --dist-dir) DIST_DIR="$2"; shift 2 ;;
        --target-images-dir) TARGET_IMAGES_DIR="$2"; shift 2 ;;
        --skip-edl) SKIP_EDL=true; shift ;;
        --no-feed) NO_FEED=true; shift ;;
        --package-only) PACKAGE_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *) ZIP="$1"; shift ;;
    esac
done

[[ -n "$ZIP" ]] || { echo "Usage: $0 <path-to-signed-ota-zip> [--tag T] [--notes N] [--dry-run] [--package-only] [--skip-edl] [--no-feed] ..." >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: $ZIP does not exist" >&2; exit 1; }
if $PACKAGE_ONLY && $SKIP_EDL; then
    echo "error: --package-only and --skip-edl are mutually exclusive (there would be nothing to package)" >&2
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

[[ -n "$VERSION" ]] || { echo "error: couldn't parse a version from '$FILENAME' — pass --version" >&2; exit 1; }
[[ -n "$TAG" ]] || { echo "error: couldn't parse a date/tag from '$FILENAME' — pass --tag" >&2; exit 1; }

# GitHub release assets: 2 GiB per file, hard limit. Checked again on the
# repackaged zip, which is a little larger.
LIMIT_BYTES=$((2 * 1024 * 1024 * 1024))
check_size() {
    local size
    size=$(stat -c%s "$1")
    if (( size >= LIMIT_BYTES )); then
        echo "error: $(basename "$1") is $(( size / 1024 / 1024 )) MB, at/over GitHub's 2 GiB release-asset limit" >&2
        exit 1
    fi
}
check_size "$ZIP"
SIZE_BYTES=$(stat -c%s "$ZIP")

# Full path, not the bare name: the other `gh` on this box is a GitHub Enterprise
# fork that defaults to the internal host. gh.com is the real github.com CLI, but
# ~/.bin isn't on PATH under a non-interactive ssh session, so hardcode it.
# (release-remotely.sh also forwards GH_HOST=github.com — the server's gh config
# defaults even this binary to the enterprise host otherwise.)
GH="${GH:-/home/kyle/.bin/gh.com}"
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
    for f in "$EDL_FIREHOSE" "$EDL_FIREHOSE_E" "$EDL_RAWPROGRAM" "$EDL_RAWPROGRAM_E" \
             "$QDL_BIN" "$SCRIPT_DIR/qdl-dump.sh" "$SCRIPT_DIR/fh_dump.py" "$OTA2RAW_SRC/build.sh" \
             "$OTA_KEY.pk8" "$OTA_KEY.x509.pem" "$SIGNAPK_JAR" "$JAVA" "$CHECK_OTA_SIG" "$SIMG2IMG"; do
        [[ -f "$f" ]] || MISSING+=("$f")
    done
    # The product name is the second field of the build fingerprint recorded in
    # the zip (Palm/lineage_Mi8937_gapps/Mi8937:...); the target-files tree the
    # OTA was generated from sits beside the zip, under that name.
    if [[ -z "$TARGET_IMAGES_DIR" ]]; then
        OTA_PRODUCT="$(unzip -p "$ZIP" META-INF/com/android/metadata 2>/dev/null \
            | sed -n 's|^post-build=[^/]*/\([^/]*\)/.*|\1|p' | head -1)"
        TARGET_IMAGES_DIR="$(dirname "$ZIP")/obj/PACKAGING/target_files_intermediates/${OTA_PRODUCT}-target_files/IMAGES"
    fi
    for part in "${OTA_BLOCK_IMAGES[@]}"; do
        [[ -f "$TARGET_IMAGES_DIR/$part.img" ]] || MISSING+=("$TARGET_IMAGES_DIR/$part.img")
    done
    for img in "${EDL_IMAGES[@]}" "${EDL_EXTRA_IMAGES[@]}"; do
        [[ -f "$EDL_DIR/$img" ]] || MISSING+=("$EDL_DIR/$img")
    done
    if (( ${#MISSING[@]} > 0 )); then
        echo "error: inputs for the EDL kit are missing:" >&2
        printf '  %s\n' "${MISSING[@]}" >&2
        echo "Run prepare-flash.sh first (and release before the next build replaces out/), pass" >&2
        echo "--edl-dir / --target-images-dir, or pass --skip-edl to release the zip as built." >&2
        exit 1
    fi
    # Re-signing with any other key would produce a zip that no installed
    # build accepts as an update. Refuse unless OTA_KEY is the key the build
    # used, as recorded in the zip itself.
    if ! unzip -p "$ZIP" META-INF/com/android/otacert 2>/dev/null | cmp -s - "$OTA_KEY.x509.pem"; then
        echo "error: $FILENAME was not signed with $OTA_KEY.x509.pem" >&2
        echo "       (its META-INF/com/android/otacert differs). Set OTA_KEY to the key the build used." >&2
        exit 1
    fi
fi

OTA_JSON_REL="${DEVICE}.json"   # repo root, not ota/ — the raw URL must stay under Android's 91-byte sysprop limit
OTA_JSON="$REPO_ROOT/$OTA_JSON_REL"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${OTA_JSON_REL}"
RELEASE_URL="https://github.com/${REPO}/releases/download/${TAG}/${FILENAME}"
# The published zip keeps the build's filename: the Updater feed and the
# installed build's own records both go by it.
RELEASE_ZIP="$ZIP"
$SKIP_EDL || RELEASE_ZIP="$DIST_DIR/$FILENAME"

echo "== release plan =="
echo "  file:      $FILENAME ($(( SIZE_BYTES / 1024 / 1024 )) MB as built)"
echo "  device:    $DEVICE"
echo "  version:   $VERSION"
echo "  romtype:   $ROMTYPE"
echo "  repo:      $REPO"
echo "  tag:       $TAG"
echo "  branch:    $BRANCH"
if $SKIP_EDL; then
    echo "  edl kit:   none (--skip-edl): the zip is published exactly as built"
else
    echo "  edl kit:   from $EDL_DIR, re-signed with $(basename "$OTA_KEY")"
    echo "  reference: $TARGET_IMAGES_DIR"
    echo "  packaged:  $RELEASE_ZIP"
fi
if $PACKAGE_ONLY; then
    echo "  mode:      package only (nothing is uploaded or committed)"
else
    echo "  asset url: $RELEASE_URL"
    if $NO_FEED; then
        echo "  ota json:  left alone (--no-feed)"
    else
        echo "  ota json:  $OTA_JSON_REL -> $RAW_URL"
    fi
fi
echo "==================="

if $DRY_RUN; then
    echo "(dry run: stopping before any packaging, GitHub or git changes)"
    exit 0
fi

HAS_GIT=true
if ! $PACKAGE_ONLY; then
    if ! $GH auth status --hostname github.com >/dev/null 2>&1; then
        echo "error: gh is not authenticated for github.com (run: gh auth login --hostname github.com)" >&2
        echo "(on a machine with more than one gh host configured, e.g. a work fork of the CLI," >&2
        echo " make sure that login targets github.com specifically, not a default internal host)" >&2
        exit 1
    fi

    # The landing repo may be a rsync mirror without .git (e.g. the build server —
    # build-lineage24-remotely.sh deliberately excludes .git when mirroring it
    # there). Detect that now, before creating the release, rather than failing
    # on the git commit below after assets are already uploaded.
    git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || HAS_GIT=false
    if ! $HAS_GIT && ! $NO_FEED; then
        echo "note: $REPO_ROOT has no .git (this looks like a synced mirror, not the real clone)."
        echo "      The release will still be created, but ${DEVICE}.json will only be written"
        echo "      locally here — sync it back to the machine with the real clone and commit/push"
        echo "      it from there."
    fi

    if ! $ASSUME_YES; then
        read -r -p "Proceed? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
    fi
fi

# --- package: OTA zip + README + EDL kit, re-signed --------------------------
# Work on disk under DIST_DIR, not /tmp: the verification pass writes ~4 GB of
# raw images and /tmp on the build server is RAM-backed.
WORK=""
trap '[[ -n "$WORK" ]] && rm -rf "$WORK"' EXIT

stage_kit() {
    # $1 = directory whose contents are added at the top level of the zip.
    local top="$1" kit="$1/edl" img
    mkdir -p "$kit"

    cp "$EDL_FIREHOSE" "$EDL_FIREHOSE_E" "$EDL_RAWPROGRAM" "$EDL_RAWPROGRAM_E" "$kit/"
    for img in "${EDL_EXTRA_IMAGES[@]}"; do
        cp "$EDL_DIR/$img" "$kit/$img"
    done

    # Bundle the qdl flasher (modern linux-msm/qdl — must have read support,
    # the bundled qdl-dump.sh backup script depends on it).
    "$QDL_BIN" --help 2>&1 | grep -q "read-xml" \
        || { echo "error: $QDL_BIN has no read support (old fork?) — bundle linux-msm qdl" >&2; exit 1; }
    cp "$QDL_BIN" "$kit/qdl"
    # Backup script (see the "Back up" section of the README).
    cp "$SCRIPT_DIR/qdl-dump.sh" "$kit/qdl-dump.sh"
    # Windows equivalent: qdl's COM-port backend cannot read this phone.
    cp "$SCRIPT_DIR/fh_dump.py" "$kit/fh_dump.py"

    echo "  building ota2raw (linux, macOS, windows)..."
    LINEAGE_ROOT="$TREE" "$OTA2RAW_SRC/build.sh" "$kit" "$TAG"

    # Reference system/vendor images: the target-files images the OTA payload
    # was generated from, desparsified by the build's own simg2img. ota2raw
    # reaches the same bytes by a different route (brotli stream + transfer
    # list), which is what makes the comparison in the verify step meaningful.
    echo "  desparsifying the reference ${OTA_BLOCK_IMAGES[*]} images..."
    mkdir -p "$WORK/ref"
    for img in "${OTA_BLOCK_IMAGES[@]}"; do
        "$SIMG2IMG" "$TARGET_IMAGES_DIR/$img.img" "$WORK/ref/$img.bin"
    done

    # manifest.json: what ota2raw rebuilds from the OTA payload, and the
    # SHA-256 each result must have (see EDL_IMAGES / OTA_BLOCK_IMAGES above
    # for where each reference comes from).
    python3 - "$EDL_DIR" "$WORK/ref" "${FILENAME%.zip}" "$kit/manifest.json" <<'PY'
import hashlib, json, os, sys

edl_dir, ref_dir, build, out = sys.argv[1:5]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(4 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# name, type, source. "file": a zip entry, zero-padded to the staged size.
# "blocks": <source>.new.dat.br written out per <source>.transfer.list.
# "zero": zero-fill of the staged size.
SPEC = [
    ("boot.bin", "file", "boot.img"),
    ("recovery.bin", "file", "recovery.img"),
    ("system.bin", "blocks", "system"),
    ("vendor.bin", "blocks", "vendor"),
    ("config.bin", "zero", ""),
    ("splash.bin", "file", "firmware-update/splash.img"),
]
images = []
for name, kind, source in SPEC:
    path = os.path.join(ref_dir if kind == "blocks" else edl_dir, name)
    entry = {"name": name, "type": kind}
    if source:
        entry["source"] = source
    if kind != "blocks":
        entry["size"] = os.path.getsize(path)
    entry["sha256"] = sha256(path)
    images.append(entry)
with open(out, "w") as f:
    json.dump({"version": 1, "build": build, "images": images}, f, indent=2)
    f.write("\n")
PY

    rm -rf "$WORK/ref"
    write_readme "$top/README.md"
}

if ! $SKIP_EDL; then
    echo "Packaging $FILENAME with the README and EDL kit..."
    mkdir -p "$DIST_DIR"
    # Old packaged zips are only kept for test-flashing; don't let them pile up.
    find "$DIST_DIR" -maxdepth 1 -name 'lineage-*.zip' -mtime +14 -delete
    WORK="$(mktemp -d -p "$DIST_DIR" .work.XXXXXX)"

    stage_kit "$WORK/top"

    # Append the kit to a copy of the zip. The copy's old signature (stored in
    # the zip comment) is dropped here; signapk writes a new one below.
    echo "  adding the kit to the zip..."
    cp "$ZIP" "$WORK/unsigned.zip"
    python3 - "$WORK/unsigned.zip" "$WORK/top" <<'PY'
import os, sys, zipfile

zip_path, top = sys.argv[1:3]
with zipfile.ZipFile(zip_path, "a", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    existing = set(z.namelist())
    for root, _, files in sorted(os.walk(top)):
        for name in sorted(files):
            path = os.path.join(root, name)
            arc = os.path.relpath(path, top).replace(os.sep, "/")
            if arc in existing:
                sys.exit(f"error: {arc} is already in the OTA zip")
            z.write(path, arc)
    z.comment = b""
PY

    # Whole-file signature, exactly as ota_from_target_files applies it
    # (releasetools common.SignFile with whole_file=True).
    echo "  re-signing (signapk -w, $(basename "$OTA_KEY"))..."
    "$JAVA" -XX:+UseCompressedOops -Xmx4096m "-Djava.library.path=$SIGNAPK_LIBS" \
        -jar "$SIGNAPK_JAR" -w "$OTA_KEY.x509.pem" "$OTA_KEY.pk8" \
        "$WORK/unsigned.zip" "$WORK/signed.zip"
    rm -f "$WORK/unsigned.zip"

    # --- verify before anything is published --------------------------------
    echo "  verifying the signature..."
    "$CHECK_OTA_SIG" "$OTA_KEY.x509.pem" "$WORK/signed.zip" 2>&1 \
        | grep -q "Whole package signature VERIFIED" \
        || { echo "error: the repackaged zip failed whole-file signature verification" >&2; exit 1; }

    # The payload must be untouched and the OTA metadata still accurate:
    # every original entry byte-identical (CRC), and the offsets recorded in
    # ota-property-files still pointing at the metadata entries (signapk
    # rewrites the zip, so check rather than assume).
    python3 - "$ZIP" "$WORK/signed.zip" <<'PY'
import struct, sys, zipfile

orig, new = (zipfile.ZipFile(p) for p in sys.argv[1:3])
new_infos = {i.filename: i for i in new.infolist()}
for info in orig.infolist():
    got = new_infos.get(info.filename)
    if got is None or (got.CRC, got.file_size) != (info.CRC, info.file_size):
        sys.exit(f"error: {info.filename} changed or went missing in the repackaged zip")
    if got.compress_type != info.compress_type:
        sys.exit(f"error: {info.filename} changed compression method in the repackaged zip")

META = "META-INF/com/android/"
props = [l for l in new.read(META + "metadata").decode().splitlines()
         if l.startswith("ota-property-files=")]
with open(sys.argv[2], "rb") as f:
    for token in (props[0].split("=", 1)[1].split(",") if props else []):
        name, offset, size = token.strip().split(":")
        info = new_infos[META + name]
        f.seek(info.header_offset + 26)
        name_len, extra_len = struct.unpack("<HH", f.read(4))
        data_offset = info.header_offset + 30 + name_len + extra_len
        if (data_offset, info.file_size) != (int(offset), int(size)):
            sys.exit(f"error: ota-property-files says {name} is at {offset}:{size}, "
                     f"but it is at {data_offset}:{info.file_size} in the repackaged zip")
print(f"  payload intact: {len(orig.infolist())} original entries unchanged, "
      f"{len(new_infos) - len(orig.infolist())} added")
PY

    # End-to-end: convert the finished zip the way a user will. ota2raw checks
    # each image against manifest.json, whose hashes are the references', so
    # this also proves flash-staging/ and the target-files images belong to
    # this zip's build.
    echo "  converting it back to raw images with ota2raw (must match the references)..."
    "$WORK/top/edl/ota2raw-linux-x86_64" -o "$WORK/verify" "$WORK/signed.zip" \
        || { echo "error: ota2raw could not reproduce the reference images from the repackaged zip." >&2
             echo "       Are $EDL_DIR and $TARGET_IMAGES_DIR" >&2
             echo "       from the same build as $FILENAME? (re-run prepare-flash.sh; release before the next build)" >&2
             exit 1; }
    for f in "${EDL_EXTRA_IMAGES[@]}" pvg100_firehose.elf pvg100e_firehose.elf \
             rawprogram0.pvg100.xml rawprogram0.pvg100e.xml qdl qdl-dump.sh fh_dump.py README.md; do
        [[ -s "$WORK/verify/$f" ]] || { echo "error: $f missing from the converted kit" >&2; exit 1; }
    done
    cmp "$EDL_DIR/boot-magisk.bin" "$WORK/verify/boot-magisk.bin"
    rm -rf "$WORK/verify"

    check_size "$WORK/signed.zip"
    mv -f "$WORK/signed.zip" "$RELEASE_ZIP"
    echo "  packaged: $RELEASE_ZIP ($(( $(stat -c%s "$RELEASE_ZIP") / 1024 / 1024 )) MB)"
fi

if $PACKAGE_ONLY; then
    echo
    echo "Done (package only: nothing uploaded). Test it like any OTA, e.g.:"
    echo "  adb sideload $RELEASE_ZIP"
    exit 0
fi

# --- assets: the zip, then its sha256 sidecar --------------------------------
# Order matters: release-all.sh treats the sidecar's presence on the release as
# "this variant is fully uploaded", so it must go up last.
[[ -n "$WORK" ]] || WORK="$(mktemp -d)"
SHA_FILE="$WORK/${FILENAME}.sha256sum"
( cd "$(dirname "$RELEASE_ZIP")" && sha256sum "$FILENAME" ) > "$SHA_FILE"
ASSETS=("$RELEASE_ZIP" "$SHA_FILE")

# --- GitHub release: create, then upload each asset with retry -------------
# The assets are large (~1.5 GB) and the build server's network path
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

# --- regenerate the OTA JSON (skipped with --no-feed) ------------------------
if ! $NO_FEED; then
    # Feed datetime = the build's real timestamp (ro.build.date.utc), taken from
    # the OTA metadata's post-timestamp — NOT midnight of the date code. The
    # Updater skips any candidate whose datetime <= the installed
    # ro.build.date.utc, so a midnight stamp makes a same-day rebuild invisible
    # to a phone already on an earlier same-day build (exactly the graft-fix
    # re-release case). post-timestamp is what the device actually compares to.
    POST_TS="$(unzip -p "$RELEASE_ZIP" META-INF/com/android/metadata 2>/dev/null | sed -n 's/^post-timestamp=//p' | head -1)"
    [[ -n "$POST_TS" ]] || POST_TS="$(stat -c %Y "$ZIP")"   # fallback: zip mtime
    DATETIME_ARGS=(--datetime "$POST_TS")

    # Embed the release notes into this entry as optional "changelog" /
    # "changelog_url" keys, shown as "What's new" by our Updater fork. The feed
    # is LineageOS API-v2 (gen-ota-json.py's default), the shape the 24.0
    # Updater reads; it ignores unknown keys, so a stock Updater is unaffected. Applied to every variant of the day, even when the GitHub
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

    # Size and sha256 in the feed are those of the zip as PUBLISHED (the
    # repackaged one), which is what the Updater downloads and checks.
    python3 "$GEN_JSON" "$RELEASE_ZIP" \
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
if $NO_FEED; then
    echo "Done (--no-feed: the Updater feed was not changed)."
else
    echo "Done. OTA feed: $RAW_URL"
fi
echo "Download: $RELEASE_URL"
echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
