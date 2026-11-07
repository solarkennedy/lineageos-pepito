#!/bin/bash
# build.sh — cross-compile ipcr-mtu-probe for aarch64 Android without a
# sysroot (same recipe as ../nas-probe/build-nosysroot.sh: bionic headers from
# source + prebuilt crt objects and the libc.so stub).
set -e
TREE=/home/kyle/android/pepito-toolchain
DIR="$(cd "$(dirname "$0")" && pwd)"
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
    "$SDK/crtbegin_dynamic.o" \
    "$DIR/ipcr-mtu-probe.c" \
    "$SDK/crtend_android.o" \
    -L"$SDK" -lc \
    -Wl,-pie \
    -Wl,-dynamic-linker,/system/bin/linker64 \
    -o "$DIR/ipcr-mtu-probe"
echo "built: $DIR/ipcr-mtu-probe"
