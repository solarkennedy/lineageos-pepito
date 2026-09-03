#!/usr/bin/env bash
# Build a Magisk-patched pepito boot image that still boots GREEN.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Users cannot patch our boot.img with the Magisk app and flash the result:
# magiskboot fails to parse the fail-open AVBv1 signature block that
# sign-boot-graft.py appends (the outer SEQUENCE declares 0xFFFF, so magiskboot
# reports "trailing data at end of DER message" and never sets its
# "AVB1-signed" flag). It therefore repacks the image UNSIGNED, and aboot hangs
# at the PALM splash on an unsigned boot image -- the bootloop users report.
#
# Fix: patch with magiskboot ourselves, then re-run the grafter over the result.
# The graft is hardcoded and deterministic, so the patched image carries a
# byte-identical Root of Trust to the stock boot.bin -- same verifiedBootKey,
# same FBE key derivation, so switching between boot.bin and boot-magisk.bin
# does NOT wipe /data.
#
# Usage:
#   ./scripts/make-magisk-boot.sh [--in boot.img] [--out boot-magisk.bin] [--apk Magisk.apk]
#
# Defaults: in = flash-staging/boot.bin, out = flash-staging/boot-magisk.bin.
# The input may be either an unsigned build boot.img or an already-grafted
# boot.bin (padded or not) -- magiskboot ignores the trailing signature/padding
# and the re-graft is idempotent.
#
# The x86-64 magiskboot/magiskinit/magisk binaries are extracted from the Magisk
# APK at run time; nothing is vendored. Magisk is GPLv3 -- the release README
# must name the exact version shipped and link upstream.
#
# Wired into prepare-flash.sh (runs on every build), rsynced back by
# build-lineage23-remotely.sh, and shipped in the EDL bundle by release.sh.

set -euo pipefail

LINEAGE_ROOT="${LINEAGE_ROOT:-/home/kyle/android/lineage-23}"
FLASH_DIR="${FLASH_DIR:-/home/kyle/Personal-Projects/lineage-23/flash-staging}"
SIGN_BOOT="$LINEAGE_ROOT/device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py"

IN="$FLASH_DIR/boot.bin"
OUT="$FLASH_DIR/boot-magisk.bin"
# Partition holding Magisk's preinit dir, where modules' sepolicy.rule files are
# staged for magiskinit to apply at boot. Without it magiskinit never creates
# .magisk/preinit, module installs print "Unable to find preinit dir", and NO
# module's custom SELinux rules are ever applied -- which under Enforcing breaks
# modules subtly rather than loudly.
#
# ⚠️ Must be a partition LABEL, never the device node the phone reports.
# `magisk --preinit-device` returns "mmcblk0p35" on a PVG100, but that index is
# variant-specific: comparing our two rawprogram XMLs, the `oem` label is entry
# 35 on the PVG100 and 50 on the PVG100E (persist: 30 vs 7, cache: 29 vs 49), so
# a baked node number would make magiskinit mount and write into an unrelated
# partition on every E unit. magiskinit resolves this string as a PARTNAME, and
# our fstab mounts by-name/oem at /metadata on both variants, so the label is
# portable where the node is not. Flash-validated 2026-09-03: resolves to
# /metadata/watchdog/magisk, and Shamiko's rules reach the live kernel policy.
PREINIT_DEVICE="${MAGISK_PREINIT_DEVICE:-oem}"
# Magisk APK is pinned in the landing repo's prebuilts/ so the build server (an
# rsync mirror of that repo) has it without fetching anything. MAGISK_APK, then
# an explicit --apk, override the search.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${MAGISK_APK:-}"
if [[ -z "$APK" ]]; then
    # Exactly one APK may sit in prebuilts/, so the shipped Magisk version is
    # never ambiguous — a leftover older APK silently building the wrong
    # version is precisely how you ship a boot image that bootloops.
    shopt -s nullglob
    FOUND=("$SCRIPT_DIR"/../prebuilts/Magisk-*.apk)
    (( ${#FOUND[@]} > 1 )) && die "multiple APKs in prebuilts/: ${FOUND[*]##*/} — keep exactly one"
    (( ${#FOUND[@]} == 1 )) && APK="${FOUND[0]}"
    [[ -z "$APK" && -f /home/kyle/Projects/apks/Magisk.apk ]] && APK=/home/kyle/Projects/apks/Magisk.apk
    shopt -u nullglob
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in)  IN="$2";  shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --apk) APK="$2"; shift 2 ;;
        --preinit-device) PREINIT_DEVICE="$2"; shift 2 ;;   # label, not a node
        --no-preinit)     PREINIT_DEVICE=""; shift ;;
        -h|--help) grep '^#' "$0" | sed -n '2,30p' | cut -c3-; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$IN"  ]] || die "input boot image not found: $IN"
[[ -n "$APK" && -f "$APK" ]] || die "Magisk APK not found (looked in <landing-repo>/prebuilts/ and ~/Projects/apks/; override with --apk or MAGISK_APK)"
[[ -f "$SIGN_BOOT" ]] || die "grafter not found: $SIGN_BOOT"

# Version string for the release README / provenance line.
MAGISK_VER="$(basename "$APK" .apk)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Extracting Magisk payload ($MAGISK_VER)"
# TWO architectures, deliberately, and mixing them up is the trap here:
#   magiskboot  runs on THIS machine (x86-64 build server) -> lib/x86_64
#   magiskinit  is embedded in the ramdisk as /init and runs on the PHONE
#   magisk, init-ld  likewise ship to the phone            -> lib/arm64-v8a
# boot_patch.sh is an on-device script, so it assumes one arch for all of them.
# Taking x86_64 for the lot builds and flashes perfectly happily, then the
# kernel dies at "Failed to execute /init (error -8)" (ENOEXEC) and panics with
# "No working init found" -- a bootloop with nothing in it that says "Magisk".
# The e_machine assertion at the end of this script exists to catch a
# regression here loudly instead of costing a flash.
unzip -o -j -q "$APK" 'lib/x86_64/libmagiskboot.so' -d "$WORK/host"
unzip -o -j -q "$APK" 'lib/arm64-v8a/*'             -d "$WORK/target"
unzip -o -j -q "$APK" 'assets/*'                    -d "$WORK"
cp "$WORK/host/libmagiskboot.so"   "$WORK/magiskboot"   # host arch
cp "$WORK/target/libmagiskinit.so" "$WORK/magiskinit"   # device arch
cp "$WORK/target/libmagisk.so"     "$WORK/magisk"       # device arch
cp "$WORK/target/libinit-ld.so"    "$WORK/init-ld"      # device arch
chmod 755 "$WORK"/magiskboot "$WORK"/magiskinit "$WORK"/magisk "$WORK"/init-ld

# boot_patch.sh is an on-device script; SOURCEDMODE=1 makes it skip the
# util_functions.sh/device-probe preamble, so we supply the few helpers it uses.
cat > "$WORK/host_patch.sh" <<'EOF'
set -e
ui_print() { echo "  $*"; }
abort() { echo "ERROR: $*" >&2; exit 1; }
grep_prop() { sed -n "s/^$1=//p" "${2:-/dev/null}" | head -1; }
export SOURCEDMODE=1 BOOTMODE=false
# Defaults match the Magisk app's own "Patch a File" flow. LEGACYSAR=false is
# correct here: our boot ramdisk carries a real first-stage init (magiskboot
# `cpio test` == 0, ramdisk has /init + /system), so the kernel is never asked
# to skip_initramfs.
export KEEPVERITY=false KEEPFORCEENCRYPT=false PATCHVBMETAFLAG=false \
       RECOVERYMODE=false LEGACYSAR=false
# Normally resolved on-device (BOOTMODE=true); we must supply it by label.
export PREINITDEVICE="$PREINIT_DEVICE"
. ./boot_patch.sh "$1"
EOF

cp "$IN" "$WORK/stock.img"
echo "==> Patching with magiskboot"
# host_patch.sh runs as a child process, so this must be exported, not just set.
export PREINIT_DEVICE
( cd "$WORK" && sh ./host_patch.sh stock.img )
[[ -f "$WORK/new-boot.img" ]] || die "boot_patch.sh produced no new-boot.img"

echo "==> Re-grafting fail-open signature"
/usr/bin/python3 "$SIGN_BOOT" "$WORK/new-boot.img" "$OUT" /boot

echo "==> Verifying"
mkdir -p "$WORK/verify"
cp "$WORK/magiskboot" "$WORK/verify/"
( cd "$WORK/verify" && cp "$OUT" verify.bin && ./magiskboot unpack verify.bin >/dev/null 2>&1
  set +e; ./magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = 1 ] || { echo "ERROR: output ramdisk is not Magisk-patched (cpio test=$rc)" >&2; exit 1; }
  echo "  ramdisk: Magisk-patched (cpio test=1)"

  # The ramdisk's /init (magiskinit) must be an AArch64 ELF, or the kernel
  # refuses it with ENOEXEC and panics -- see the extraction note above.
  ./magiskboot cpio ramdisk.cpio "extract init init.elf" >/dev/null 2>&1
  MACHINE=$(od -An -tx1 -j18 -N2 init.elf | tr -d ' ')   # ELF e_machine, LE
  [ "$MACHINE" = "b700" ] || {
      echo "ERROR: ramdisk /init is not AArch64 (e_machine=0x$MACHINE, want 0xb7)" >&2
      echo "       The device-arch binaries were taken from the wrong lib/ dir." >&2
      exit 1; }
  echo "  ramdisk /init: AArch64 ELF (e_machine=0xb7)"

  # And that the preinit device made it into the baked config, or module
  # sepolicy rules will silently never be applied.
  ./magiskboot cpio ramdisk.cpio "extract .backup/.magisk cfg" >/dev/null 2>&1
  chmod 644 cfg 2>/dev/null || true
  if [ -n "$PREINIT_DEVICE" ]; then
      grep -q "^PREINITDEVICE=$PREINIT_DEVICE\$" cfg || {
          echo "ERROR: PREINITDEVICE=$PREINIT_DEVICE missing from baked config" >&2; exit 1; }
      echo "  preinit device: $PREINIT_DEVICE (module sepolicy rules will apply)"
  else
      echo "  preinit device: NONE — module sepolicy.rule files will NOT be applied"
  fi )

echo
echo "Done: $OUT ($(stat -c %s "$OUT") bytes, $MAGISK_VER)"
echo "Flash over the boot partition only; boot.bin in the same dir is the un-rooted image."
