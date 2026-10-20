#!/bin/bash
# build-imss-nosysroot.sh — cross-compile nas-probe for aarch64 Android on a
# BARE checkout (no out/soong/ndk/sysroot required).
#
# build-imss.sh needs out/soong/ndk/sysroot, which only exists after a full
# build.  This variant combines:
#   * ../efs2-probe/build.sh's sysroot-free recipe (bionic headers from source
#     + prebuilt crt objects and the libc.so stub from
#     prebuilts/runtime/mainline/runtime/sdk/android/arm64/lib), and
#   * the QMI headers/libs from ../pdc-mbn-loader that nas-probe needs.
set -e

TREE=/home/kyle/android/lineage-23
DIR="$TREE/diag-tools/nas-probe"
PDC="$TREE/diag-tools/pdc-mbn-loader"
CLANG="$TREE/prebuilts/clang/host/linux-x86/clang-r563880/bin/clang"
SDK="$TREE/prebuilts/runtime/mainline/runtime/sdk/android/arm64/lib"
B="$TREE/bionic"

"$CLANG" \
    --target=aarch64-linux-android29 \
    -fPIE -O2 -Wall -Wextra -Wno-unused-parameter \
    -nostdinc -nostdlib \
    -isystem "$("$CLANG" -print-resource-dir)/include" \
    -isystem "$B/libc/include" \
    -isystem "$B/libc/kernel/uapi" \
    -isystem "$B/libc/kernel/uapi/asm-arm64" \
    -isystem "$B/libc/kernel/android/uapi" \
    -I"$PDC" -I"$PDC/qmi_inc" \
    "$SDK/crtbegin_dynamic.o" \
    "$DIR/nas-probe.c" \
    "$SDK/crtend_android.o" \
    -L"$SDK" -lc -ldl \
    -L"$PDC" -lqmi_cci -lqmiservices \
    -Wl,--allow-shlib-undefined \
    -Wl,-pie \
    -Wl,-dynamic-linker,/system/bin/linker64 \
    -o "$DIR/nas-probe"

echo "built: $DIR/nas-probe"
