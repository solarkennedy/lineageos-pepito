#!/usr/bin/env bash
# Flash partitions from flash-staging/ via EDL (Qualcomm 9008).
#
# Requires: qdl, android16-adb (optional — used to trigger EDL automatically).
# Staging images come from scripts/prepare-flash.sh.
#
# Usage:
#   ./flash-staging.sh          # trigger EDL via ADB if a device is present
#   ./flash-staging.sh --no-adb # skip ADB trigger, wait for manual EDL entry
#
# Canonically lives here; flash-staging/flash-staging.sh is a symlink to it.

set -euo pipefail

FLASH_DIR="/home/kyle/android/lineage-23/flash-staging"
BOOT_IMG="$FLASH_DIR/boot.bin"
EDL_USB_ID="05c6:9008"
NO_ADB=0

for arg in "$@"; do
    [[ "$arg" == "--no-adb" ]] && NO_ADB=1
done

die() { echo "ERROR: $*" >&2; exit 1; }

# Never fatal: a finished flash must not report failure because ntfy is down.
notify() {
    /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" || true
}

# Wipe pstore so the next boot's ramoops is from this flash, not the last one.
clear_ramoops() {
    local cmd="if [ -d /sys/fs/pstore ]; then rm -f /sys/fs/pstore/*ramoops* /sys/fs/pstore/pmsg-*; sync; fi"
    echo "Clearing ramoops via ADB..."
    android16-adb shell "$cmd" >/dev/null 2>&1 && return 0
    android16-adb shell su 0 sh -c "$cmd" >/dev/null 2>&1 && return 0
    echo "WARNING: Could not clear ramoops; continuing with EDL reboot." >&2
}

# PVG100 names hardcoded: the bench DUTs are all US-variant hardware. The
# PVG100E (pvg100e_firehose.elf + rawprogram0.pvg100e.xml) ships in the
# release bundle only — see release.sh.
for f in "$BOOT_IMG" "$FLASH_DIR/pvg100_firehose.elf" "$FLASH_DIR/rawprogram0.pvg100.xml"; do
    [[ -f "$f" ]] || die "$f not found — run scripts/prepare-flash.sh first"
done
command -v qdl >/dev/null || die "'qdl' not found in PATH"

echo "Boot image: $BOOT_IMG ($(du -h "$BOOT_IMG" | cut -f1))"

if [[ "$NO_ADB" -eq 0 ]] && command -v android16-adb >/dev/null; then
    clear_ramoops
    echo "Triggering EDL reboot..."
    android16-adb reboot edl
    sleep 3
fi

echo "Waiting for EDL device ($EDL_USB_ID) — if not already there: power off → hold Vol↑ → plug USB"
for i in $(seq 1 30); do
    lsusb 2>/dev/null | grep -q "$EDL_USB_ID" && break
    [[ $i -eq 30 ]] && die "Timed out waiting for EDL device after 30s"
    printf "\r  [%2ds] waiting..." "$i"
    sleep 1
done
echo -e "\nEDL device detected."

# Run from FLASH_DIR so qdl resolves the rawprogram XML's filenames relative to it.
FLASH_START=$SECONDS
(cd "$FLASH_DIR" && systemd-inhibit qdl --storage emmc pvg100_firehose.elf rawprogram0.pvg100.xml)

notify "Flash complete — pepito" \
"qdl finished in $(( (SECONDS - FLASH_START) / 60 ))m
boot.bin $(du -h "$BOOT_IMG" | cut -f1)
now waiting for adb to come back up"

echo
echo "Flash done. Waiting for adb to come back up..."
android16-adb wait-for-device && android16-adb root
