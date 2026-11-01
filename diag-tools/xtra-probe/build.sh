#!/bin/bash
# build.sh — cross-compile xtra-probe for aarch64 Android without a sysroot,
# same recipe as ../nas-probe/build-nosysroot.sh (lineage-23 prebuilt clang +
# bionic headers, QMI headers/stubs from lineage-23's pdc-mbn-loader).
#
# Links against libloc_api_v02.so for loc_qmi_idl_service_object_v02; pull the
# device copy first:  dut1-adb pull /vendor/lib64/libloc_api_v02.so lib/
set -e

TREE=/home/kyle/android/lineage-23
DIR="$(cd "$(dirname "$0")" && pwd)"
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
    "$DIR/xtra-probe.c" \
    "$SDK/crtend_android.o" \
    -L"$SDK" -lc -ldl \
    -L"$PDC" -lqmi_cci \
    -L"$DIR/lib" -l:libloc_api_v02.so \
    -Wl,--allow-shlib-undefined \
    -Wl,-pie \
    -Wl,-dynamic-linker,/system/bin/linker64 \
    -o "$DIR/xtra-probe"

echo "built: $DIR/xtra-probe"
