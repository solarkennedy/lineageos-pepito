#!/usr/bin/env bash
# Prepare flash-staging/ with images ready for qdl:
#   - Converts sparse system/vendor images to raw
#   - Re-grafts boot/recovery via the fail-open graft
#     (device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py): no key
#     involved, stock cert+sig grafted verbatim + inflated sig length so aboot's
#     verifier exits early and boots GREEN, with a fixed (hardcoded, not per-build)
#     Root-of-Trust. NB: the BUILD now grafts boot.img/recovery.img too (see
#     custom_bootimg.mk) so the OTA is bootable; re-grafting the already-grafted
#     image here is idempotent. Switching an EXISTING key-signed install onto this
#     graft changes the ROT once → one /data wipe.
#   - Writes a ZEROED config.bin (clears a stale FRP token — see below)
#
# We deliberately do NOT touch userdata here: the release must not wipe a user's
# /data as a side effect of flashing. Coming from stock, the first boot formats
# /data on its own (encryption mismatch); an in-place update keeps it intact.
#
# Run from anywhere. Then: flash-staging/flash-staging.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LINEAGE_ROOT="/home/kyle/android/lineage-23"
FLASH_DIR="/home/kyle/Personal-Projects/lineage-23/flash-staging"
# Canonical grafter now lives in the device tree (so the build can reach it too);
# this is the single copy. Re-grafting the build's already-grafted boot.img here
# is idempotent, so EDL staging is unchanged.
SIGN_BOOT="$LINEAGE_ROOT/device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py"
SIMG2IMG="$LINEAGE_ROOT/out/host/linux-x86/bin/simg2img"
PRODUCT_OUT="$LINEAGE_ROOT/out/target/product/Mi8937"

BOOT_ONLY=0
NO_RAMDISK=0
for arg in "$@"; do
    case "$arg" in
        --boot-only|-b) BOOT_ONLY=1 ;;
        --no-ramdisk)   NO_RAMDISK=1; BOOT_ONLY=1 ;;
        -h|--help)
            echo "Usage: $0 [--boot-only|-b] [--no-ramdisk]"
            echo "  --boot-only   Stage only boot.bin (skips system/vendor/recovery/userdata)"
            echo "  --no-ramdisk  Repack boot.bin with an empty ramdisk (diagnostic)."
            echo "                Implies --boot-only. Useful for bypassing initramfs"
            echo "                unpack issues to triage downstream kernel BUGs."
            exit 0
            ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$PRODUCT_OUT/boot.img" ]]     || die "boot.img not found — run build first"
[[ -f "$SIGN_BOOT" ]]                || die "boot signing script not found at $SIGN_BOOT"

if [[ "$BOOT_ONLY" -eq 0 ]]; then
    [[ -f "$PRODUCT_OUT/system.img" ]]   || die "system.img not found — run build first"
    [[ -f "$PRODUCT_OUT/vendor.img" ]]   || die "vendor.img not found — run build first"
    [[ -f "$PRODUCT_OUT/recovery.img" ]] || die "recovery.img not found — run build first"
    [[ -f "$SIMG2IMG" ]]                 || die "simg2img not found at $SIMG2IMG"

    echo "==> Converting system.img (sparse → raw)..."
    "$SIMG2IMG" "$PRODUCT_OUT/system.img" "$FLASH_DIR/system.bin"

    echo "==> Converting vendor.img (sparse → raw)..."
    "$SIMG2IMG" "$PRODUCT_OUT/vendor.img" "$FLASH_DIR/vendor.bin"
fi

if [[ "$NO_RAMDISK" -eq 1 ]]; then
    echo "==> Building no-ramdisk boot image (diagnostic)..."
    UNPACK_BOOTIMG="$LINEAGE_ROOT/out/host/linux-x86/bin/unpack_bootimg"
    MKBOOTIMG="$LINEAGE_ROOT/out/host/linux-x86/bin/mkbootimg"
    [[ -f "$UNPACK_BOOTIMG" ]] || die "unpack_bootimg not found at $UNPACK_BOOTIMG"
    [[ -f "$MKBOOTIMG" ]]      || die "mkbootimg not found at $MKBOOTIMG"

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    "$UNPACK_BOOTIMG" --boot_img "$PRODUCT_OUT/boot.img" --out "$WORK" >/dev/null

    # Reconstruct cmdline from the original boot.img
    CMDLINE="$("$UNPACK_BOOTIMG" --boot_img "$PRODUCT_OUT/boot.img" 2>/dev/null \
        | sed -n 's/^command line args: //p')"

    : > "$WORK/empty.ramdisk"
    "$MKBOOTIMG" \
        --kernel "$WORK/kernel" \
        --ramdisk "$WORK/empty.ramdisk" \
        --cmdline "$CMDLINE" \
        --base 0x80000000 \
        --pagesize 2048 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --header_version 0 \
        --os_version 16.0.0 \
        --os_patch_level 2026-05 \
        --output "$FLASH_DIR/boot_unsigned.img"
    /usr/bin/python3 "$SIGN_BOOT" "$FLASH_DIR/boot_unsigned.img" "$FLASH_DIR/boot.bin" /boot
else
    echo "==> Signing boot image..."
    cp "$PRODUCT_OUT/boot.img" "$FLASH_DIR/boot_unsigned.img"
    /usr/bin/python3 "$SIGN_BOOT" "$FLASH_DIR/boot_unsigned.img" "$FLASH_DIR/boot.bin" /boot
fi

if [[ "$BOOT_ONLY" -eq 0 ]]; then
    echo "==> Signing recovery image..."
    cp "$PRODUCT_OUT/recovery.img" "$FLASH_DIR/recovery_unsigned.img"
    /usr/bin/python3 "$SIGN_BOOT" "$FLASH_DIR/recovery_unsigned.img" "$FLASH_DIR/recovery.bin" /recovery

    # Zero the config partition (64 sectors × 512 B = 32 KB per rawprogram0.xml).
    # The stock/last-owner FRP token lives here. On A15+ a /data wipe deletes
    # /data/system/frp_secret while this token survives, so FRP can never
    # auto-deactivate → FrpWarningActivity ("factory reset" prompt) greets every
    # boot. Shipping config zeroed breaks that desync. Regenerated every run so a
    # stray stock config.bin can never be flashed in its place.
    echo "==> Writing zeroed config.bin (clears stale FRP token)..."
    dd if=/dev/zero of="$FLASH_DIR/config.bin" bs=1K count=32 status=none

    # NB: userdata is intentionally NOT staged here — see header. Leaving
    # userdata.bin absent means qdl --allow-missing skips it and /data is
    # untouched.
fi

echo
echo "Flash staging ready:"
ls -lh "$FLASH_DIR"/*.bin "$FLASH_DIR"/*.img 2>/dev/null || true
echo
echo "Next: $FLASH_DIR/flash-staging.sh"
