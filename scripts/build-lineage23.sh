#!/bin/bash
# Build script for Lineage 23.2 Mi8937 pepito variant
# Uses the exact kernel config from official nightly build

set -e

LINEAGE_ROOT="/home/kyle/android/lineage-23"
TARGET_PRODUCT="lineage_Mi8937"
TARGET_RELEASE="bp4a"
TARGET_VARIANT="userdebug"

BOOT_ONLY=0
RECOVERY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --boot-only|-b) BOOT_ONLY=1 ;;
        --recovery-only|-r) RECOVERY_ONLY=1 ;;
        --gapps)
            TARGET_PRODUCT="lineage_Mi8937_gapps"
            # BoardConfig.mk only relaxes the system partition's reserved-size
            # margin (800MB -> 40MB) when WITH_GMS=true; the baked-in GApps
            # payload (~600MB) doesn't fit under the vanilla 800MB margin.
            export WITH_GMS=true
            # SNAPSHOT releasetype: this is the OTA channel separator. The
            # LineageOS Updater only offers a build whose romtype exactly equals
            # the device's ro.lineage.releasetype (Updater Utils.isCompatible),
            # and both variants share one pepito.json OTA feed — so tagging gapps
            # SNAPSHOT (vanilla stays UNOFFICIAL) is what stops a vanilla phone
            # being offered the gapps build and vice versa. It also lands in the
            # zip filename (LINEAGE_BUILDTYPE), which release-remotely.sh ignores
            # (it selects the variant on the _gapps suffix). The date stays the
            # version identity; releasetype is just the channel.
            export RELEASE_TYPE=SNAPSHOT
            ;;
        -h|--help)
            echo "Usage: $0 [--boot-only|-b] [--recovery-only|-r] [--gapps]"
            echo "  --boot-only      Build only bootimage (skips system/vendor/recovery)"
            echo "  --recovery-only  Build only recoveryimage (skips system/vendor/boot)"
            echo "  --gapps          Build the lineage_Mi8937_gapps target instead (bakes in GApps)"
            exit 0
            ;;
    esac
done

# One date drives BOTH the fingerprint incremental (BUILD_NUMBER) and the zip
# name / ro.lineage.version (LINEAGE_BUILD_DATE, via vendor/lineage version.mk).
# Deriving them separately from date(1) desyncs a build that straddles UTC
# midnight — vanilla stamps one day, gapps the next. So pick ONE value here:
#   injected LINEAGE_BUILD_DATE  >  injected BUILD_NUMBER  >  today (UTC).
# release-all.sh injects LINEAGE_BUILD_DATE so both variants + the release share
# a single date it chose up front. Exported before envsetup/lunch/mka so the
# build system picks them up.
#
# (Why stamp at all: with BUILD_NUMBER unset AOSP falls back to eng.$USER, which
# lands verbatim in ro.build.version.incremental / the fingerprint — an eng-build
# smell we don't want in a release image.)
PEPITO_BUILD_DATE="${LINEAGE_BUILD_DATE:-${BUILD_NUMBER:-$(date -u +%Y%m%d)}}"
export BUILD_NUMBER="$PEPITO_BUILD_DATE"
export LINEAGE_BUILD_DATE="$PEPITO_BUILD_DATE"

if [[ "$BOOT_ONLY" -eq 1 ]]; then
    BUILD_TARGETS="bootimage"
elif [[ "$RECOVERY_ONLY" -eq 1 ]]; then
    BUILD_TARGETS="recoveryimage"
else
    # bacon (vendor/lineage/build/tasks/bacon.mk) is the standard LineageOS
    # OTA-zip target: lineage-$(LINEAGE_VERSION).zip + .sha256sum in
    # $(PRODUCT_OUT), which is what release.sh actually needs as input. It
    # already depends on systemimage/vendorimage/bootimage/recoveryimage (via
    # the default full build), so the old explicit target list here was a
    # strict subset that never actually produced a releasable zip.
    BUILD_TARGETS="bacon"
fi

echo "================================"
echo "Lineage 23.2 Mi8937 Build Script"
echo "================================"
echo "Product:  $TARGET_PRODUCT"
echo "Release:  $TARGET_RELEASE"
echo "Variant:  $TARGET_VARIANT"
echo "Build #:  $BUILD_NUMBER (-> fingerprint incremental)"
echo ""

# Change to Lineage root
cd "$LINEAGE_ROOT"

# Source the build environment
echo "[*] Sourcing build environment..."
source build/envsetup.sh > /dev/null 2>&1

# Set up lunch (three-part format required by Lineage 23.2)
echo "[*] Setting up lunch: $TARGET_PRODUCT $TARGET_RELEASE $TARGET_VARIANT"
lunch "$TARGET_PRODUCT" "$TARGET_RELEASE" "$TARGET_VARIANT" > /dev/null 2>&1 || {
    echo "ERROR: lunch failed"
    echo "Try: lunch $TARGET_PRODUCT $TARGET_RELEASE $TARGET_VARIANT"
    exit 1
}

# Show what we're building
echo "[*] Build configuration:"
echo "    TARGET_PRODUCT=$TARGET_PRODUCT"
echo "    TARGET_RELEASE=$TARGET_RELEASE"
echo "    TARGET_BUILD_VARIANT=$TARGET_VARIANT"
echo ""

# pepito: /persist must be a REAL directory in the system-image root, not the
# common /mnt/vendor/persist symlink — Palm's stock sensor registry daemon
# (sensors.qti) rejects the symlinked path at file init ("sns_fsa_la: invalid
# directory path"), the DSP-side SMGR then gets registry-read errors at ADSP
# boot and never starts -> no SNS services -> no prox/ALS (2026-07-10 root
# cause). BOARD_ROOT_EXTRA_SYMLINKS has no consumer in the A16 build system,
# so the $OUT/root staging artifacts are load-bearing state: swap the stale
# symlink for a real dir here. init.target.rc bind-mounts the persist
# partition onto it at boot (pepito-gated). See PLAN-sensors.md.
ROOT_STAGING="$LINEAGE_ROOT/out/target/product/Mi8937/root"
mkdir -p "$ROOT_STAGING"
if [ -L "$ROOT_STAGING/persist" ] || [ ! -d "$ROOT_STAGING/persist" ]; then
    rm -f "$ROOT_STAGING/persist"
    mkdir "$ROOT_STAGING/persist"
fi

# Regenerate the metalava api/lint baselines before the main build.
#
# After a clean tree (rm out), the first build caches the api-stubs-docs
# outputs; a later framework source edit only partially invalidates them, so
# the incremental metalava run hits an inconsistent state and fails the whole
# build with `ErrorWhenNew` lint on a pile of stock files (BroadcastReceiver,
# Intent, TelephonyManager...) plus this tree's custom continuity/clipboard
# APIs. `update-api` regenerates the api path consistently and clears it.
# It's an out/-local fix (touches no source/api/baseline files), so it must be
# re-run after every clean build -- hence doing it here unconditionally. On an
# already-consistent tree it's a cheap near-no-op metalava rerun.
# (Skipped for boot/recovery-only builds, which don't touch the framework.)
if [[ "$BOOT_ONLY" -eq 0 && "$RECOVERY_ONLY" -eq 0 ]]; then
    echo "[*] Regenerating api/lint baselines (update-api)..."
    mka update-api
    echo ""
fi

# Build
echo "[*] Starting build..."
echo "    Building: $BUILD_TARGETS"
echo ""

mka $BUILD_TARGETS

echo ""
echo "================================"
echo "Build Complete!"
echo "================================"
echo ""
echo "Output location:"
echo "  $LINEAGE_ROOT/out/target/product/Mi8937/"
echo ""
echo "Key files:"
echo "  system.img:    system image"
echo "  vendor.img:    vendor image"
echo "  boot.img:      kernel + normal-boot ramdisk"
echo "  recovery.img:  kernel + recovery ramdisk (separate partition!)"
