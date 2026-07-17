#!/usr/bin/env bash
# Prepare flash-staging/ with images ready for qdl:
#   - Converts sparse system/vendor images to raw
#   - Signs boot/recovery with our PRIVATE AVBv1 key (vendor/lineage-priv/keys-boot,
#     auto-created on first run). NB: that key's digest feeds keymaster's Root of
#     Trust — changing it forces a /data wipe. See boot-signing/scripts/sign-boot.py.
#   - Zeros first 4 MB of userdata (clears FBE headers; forces fresh format on first boot)
#
# Run from anywhere. Then: flash-staging/flash-staging.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LINEAGE_ROOT="/home/kyle/android/lineage-23"
FLASH_DIR="/home/kyle/Personal-Projects/lineage-23/flash-staging"
SIGN_BOOT="$SCRIPT_DIR/boot-signing/scripts/sign-boot.py"
# Passed explicitly: sign-boot.py otherwise locates the keydir by walking up from
# CWD, and this script is meant to run from anywhere.
BOOT_KEYS="$LINEAGE_ROOT/vendor/lineage-priv/keys-boot"
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
[[ -f "$SIGN_BOOT" ]]                || die "sign-boot.py not found at $SIGN_BOOT"

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
    /usr/bin/python3 "$SIGN_BOOT" --keys "$BOOT_KEYS" "$FLASH_DIR/boot_unsigned.img" "$FLASH_DIR/boot.bin" /boot
else
    echo "==> Signing boot image..."
    cp "$PRODUCT_OUT/boot.img" "$FLASH_DIR/boot_unsigned.img"
    /usr/bin/python3 "$SIGN_BOOT" --keys "$BOOT_KEYS" "$FLASH_DIR/boot_unsigned.img" "$FLASH_DIR/boot.bin" /boot
fi

if [[ "$BOOT_ONLY" -eq 0 ]]; then
    echo "==> Signing recovery image..."
    cp "$PRODUCT_OUT/recovery.img" "$FLASH_DIR/recovery_unsigned.img"
    /usr/bin/python3 "$SIGN_BOOT" --keys "$BOOT_KEYS" "$FLASH_DIR/recovery_unsigned.img" "$FLASH_DIR/recovery.bin" /recovery

    #echo "==> Zeroing first 4 MB of userdata (clears FBE headers)..."
    #dd if=/dev/zero of="$FLASH_DIR/userdata.bin" bs=1M count=4 status=none
fi

echo
echo "Flash staging ready:"
ls -lh "$FLASH_DIR"/*.bin "$FLASH_DIR"/*.img 2>/dev/null || true
echo
echo "Next: $FLASH_DIR/flash-staging.sh"
