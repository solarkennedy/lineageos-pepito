#!/usr/bin/env bash
# Cross-compile ota2raw for every OS the EDL kit supports.
#
#   tools/ota2raw/build.sh <out-dir> [version]
#
# Writes ota2raw-<os>-<arch>[.exe] into <out-dir>. Pure Go (CGO off), so one
# Linux host builds all of them; the binaries are static and need nothing
# installed. release.sh runs this on the build server, which has no Go of its
# own, so the toolchain is looked up as: $GO, PATH, then the AOSP tree's
# prebuilt (prebuilts/go/linux-x86). The one dependency (a brotli decoder) is
# vendored under vendor/, so the build needs no network: the build server's
# GOPROXY points at an internal host it cannot reach from home.
set -euo pipefail

OUT="${1:?usage: build.sh <out-dir> [version]}"
VERSION="${2:-dev}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOSP_GO="${LINEAGE_ROOT:-/home/kyle/android/lineage-24}/prebuilts/go/linux-x86/bin/go"

if [[ -z "${GO:-}" ]]; then
    GO="$(command -v go || true)"
    [[ -n "$GO" ]] || GO="$AOSP_GO"
fi
[[ -x "$GO" ]] || { echo "error: no Go toolchain (set GO=, or install go; looked at $AOSP_GO)" >&2; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# GOOS GOARCH name-suffix. The names use the words users know their machine by.
TARGETS=(
    "linux   amd64 linux-x86_64"
    "linux   arm64 linux-arm64"
    "darwin  arm64 macos-arm64"
    "darwin  amd64 macos-x86_64"
    "windows amd64 windows-x86_64.exe"
)

export CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=vendor GOPROXY=off
export GOCACHE="${GOCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ota2raw/build}"

cd "$SRC"
for t in "${TARGETS[@]}"; do
    read -r goos goarch suffix <<<"$t"
    GOOS=$goos GOARCH=$goarch "$GO" build -trimpath \
        -ldflags "-s -w -buildid= -X main.version=$VERSION" \
        -o "$OUT/ota2raw-$suffix" .
    echo "  built ota2raw-$suffix"
done
