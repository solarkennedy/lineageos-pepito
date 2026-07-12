#!/usr/bin/env bash
# Flash boot + system + vendor from flash-staging/ via EDL (Qualcomm 9008).
#
# Must be run from the project root (where flash-staging/ lives).
# Requires: qdl, adb (optional — used to trigger EDL automatically).
#
# Usage:
#   scripts/flash-staging.sh          # auto-detect ADB, trigger EDL if present
#   scripts/flash-staging.sh --no-adb # skip ADB trigger, wait for manual EDL entry

set -euo pipefail

FLASH_DIR="flash-staging"
FIREHOSE="$FLASH_DIR/pepito_firehose.elf"
RAWPROGRAM="$FLASH_DIR/rawprogram0.xml"
BOOT_IMG="$FLASH_DIR/boot.bin"
EDL_USB_ID="05c6:9008"
NO_ADB=0

for arg in "$@"; do
    [[ "$arg" == "--no-adb" ]] && NO_ADB=1
done

die() { echo "ERROR: $*" >&2; exit 1; }

# Sanity checks
[[ -f "$BOOT_IMG" ]]    || die "$BOOT_IMG not found — run scripts/build-sysimage.sh first"
[[ -f "$FIREHOSE" ]]    || die "$FIREHOSE not found"
[[ -f "$RAWPROGRAM" ]]  || die "$RAWPROGRAM not found"
command -v qdl &>/dev/null || die "'qdl' not found in PATH"

echo "Boot image: $BOOT_IMG ($(du -h "$BOOT_IMG" | cut -f1))"
echo

# Try to trigger EDL via ADB if a device is connected
if [[ "$NO_ADB" -eq 0 ]] && command -v adb &>/dev/null; then

    DEVICE=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')
    if [[ -n "$DEVICE" ]]; then
        echo "ADB device found: $DEVICE — triggering EDL reboot..."
        adb reboot edl
        echo "Waiting for device to drop off USB..."
        sleep 3
    else
        echo "No ADB device detected."
    fi
fi

# Wait for EDL device to appear (USB 05c6:9008)
echo "Waiting for EDL device ($EDL_USB_ID) — enter EDL mode now if not already done:"
echo "  Power off → hold Vol↑ → plug USB"
echo
for i in $(seq 1 30); do
    if lsusb 2>/dev/null | grep -q "$EDL_USB_ID"; then
        echo "EDL device detected."
        break
    fi
    if [[ $i -eq 30 ]]; then
        die "Timed out waiting for EDL device after 30 seconds"
    fi
    printf "\r  [%2ds] waiting..." "$i"
    sleep 1
done
echo

echo "Flashing boot partition..."
# Run from FLASH_DIR so qdl resolves filenames in rawprogram0.xml relative to it
(cd "$FLASH_DIR" && qdl --storage emmc pepito_firehose.elf rawprogram0.xml)

echo
echo "Done. Waiting 120s for device to boot..."
sleep 120
echo "Device should be up. Watch for the yellow AVB warning — that is expected."
