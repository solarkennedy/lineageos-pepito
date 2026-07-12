#!/usr/bin/env bash
set -eo pipefail

LINEAGE_ROOT=/home/kyle/android/lineage
LOG=/tmp/lineage_boot_build.log

exec > >(tee "$LOG") 2>&1

echo "=== build-bootimage.sh ==="
echo "Log: $LOG"
echo ""

cd "$LINEAGE_ROOT"
source build/envsetup.sh
lunch lineage_pepito-userdebug

echo "Cleaning kernel source tree (mrproper) ..."
make -C "$LINEAGE_ROOT/kernel/palm/pepito" mrproper

echo "Starting build at $(date '+%T') ..."
make bootimage -j"$(nproc)"
