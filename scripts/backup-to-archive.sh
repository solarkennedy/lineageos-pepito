#!/usr/bin/env bash
#
# backup-to-archive.sh — snapshot this LineageOS tree to the NFS archive server.
#
# Drops a timestamped .tgz onto the Synology archive share (see DEST below).
# Takes NO arguments. Backs up whichever tree it lives in (resolves its own
# path), so it works unchanged on the build server even if the checkout path
# differs. Run it from the build server for speed (fast local disk + LAN to NAS).
#
#   ./scripts/backup-to-archive.sh
#
set -euo pipefail

# --- config ---------------------------------------------------------------
# NFS archive location (from /etc/fstab: 10.0.2.2:/volume1/archive).
DEST="/mnt/synology1/archive"

# Paths excluded from the tarball, relative to the tree root. out/ and ccache
# are regenerable build output (the bulk of the ~188 GB); everything else,
# including .repo/, is kept so the archive is a working tree.
EXCLUDES=(
  out
  .ccache
  ccache
)

# zstd compression level (only used when zstd is the chosen compressor).
# 12 is a strong speed/ratio balance for a big source tree; raise toward 19
# for a smaller file if CPU is plentiful, lower for max throughput.
ZSTD_LEVEL=12
# --------------------------------------------------------------------------

# Resolve the tree root as the parent of this script's dir. LOGICAL path
# (pwd, not pwd -P): the tree's scripts/ is a symlink into the landing repo
# (~/Projects/lineageos-pepito), and physical resolution would follow it and
# "back up" the 1 MB landing repo instead of the tree it was invoked from.
# Override with TREE_ROOT=... when invoking from outside a tree.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TREE_ROOT="${TREE_ROOT:-"$(cd -- "$SCRIPT_DIR/.." && pwd)"}"
TREE_NAME="$(basename -- "$TREE_ROOT")"
TREE_PARENT="$(dirname -- "$TREE_ROOT")"

if [[ ! -e "$TREE_ROOT/.repo" ]]; then
  echo "ERROR: '$TREE_ROOT' does not look like a repo tree (no .repo/)." >&2
  echo "       Invoke via the tree's scripts/ symlink (e.g." >&2
  echo "       ~/android/lineage-23/scripts/backup-to-archive.sh) or set TREE_ROOT=." >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"

# --- preflight ------------------------------------------------------------
if ! mountpoint -q "$DEST" 2>/dev/null; then
  echo "ERROR: '$DEST' is not a mounted filesystem." >&2
  echo "       Mount the NFS archive share first (see /etc/fstab)." >&2
  exit 1
fi
if [[ ! -w "$DEST" ]]; then
  echo "ERROR: '$DEST' is not writable." >&2
  exit 1
fi

# Pick the best available compressor: zstd (best wall-clock when network-bound)
# > pigz (parallel gzip) > gzip. The extension follows the choice.
if command -v zstd >/dev/null 2>&1; then
  COMPRESSOR="zstd -T0 --long=27 -${ZSTD_LEVEL}"   # -T0 = all cores
  EXT="tar.zst"
elif command -v pigz >/dev/null 2>&1; then
  COMPRESSOR="pigz"
  EXT="tgz"
else
  COMPRESSOR="gzip"
  EXT="tgz"
  echo "note: neither zstd nor pigz found, falling back to single-threaded gzip." >&2
fi

ARCHIVE="${TREE_NAME}-${STAMP}.${EXT}"
DEST_FINAL="${DEST%/}/${ARCHIVE}"
DEST_PARTIAL="${DEST_FINAL}.partial"

# Build tar --exclude args (paths relative to the tarball root, TREE_NAME/...).
EXCLUDE_ARGS=()
for e in "${EXCLUDES[@]}"; do
  EXCLUDE_ARGS+=( "--exclude=${TREE_NAME}/${e}" )
done

echo "Backing up : $TREE_ROOT"
echo "Excluding  : ${EXCLUDES[*]}"
echo "Compressor : $COMPRESSOR"
echo "Destination: $DEST_FINAL"
df -h "$DEST" | awk 'NR==1 || NR==2 {print "  " $0}'
echo

# --- archive --------------------------------------------------------------
# Write to a .partial name and rename only on success, so an interrupted run
# never leaves a truncated archive that looks complete.
START=$(date +%s)
trap 'rm -f "$DEST_PARTIAL"' ERR INT TERM

tar --use-compress-program="$COMPRESSOR" \
    "${EXCLUDE_ARGS[@]}" \
    -cf "$DEST_PARTIAL" \
    -C "$TREE_PARENT" \
    "$TREE_NAME"

mv -f "$DEST_PARTIAL" "$DEST_FINAL"
trap - ERR INT TERM

END=$(date +%s)
SIZE="$(du -h "$DEST_FINAL" | cut -f1)"
echo
echo "Done: $DEST_FINAL"
echo "Size: $SIZE   Elapsed: $(( END - START ))s"
