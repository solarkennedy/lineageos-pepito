#!/usr/bin/env bash
# Clear pstore/ramoops records from an attached adb device.
#
# Intended for recovery/rooted debugging between failed boots, where stale
# console-ramoops and pmsg-ramoops records make serial output noisy and slow.

set -euo pipefail

ADB="${ADB:-adb}"
REBOOT=0
LIST_ONLY=0

usage() {
    cat <<'EOF'
Usage: ./scripts/clear-ramoops.sh [--list-only] [--reboot]

Clears all files under /sys/fs/pstore on the attached adb device.

Options:
  --list-only   Show current pstore records but do not delete them
  --reboot      Reboot the device after clearing records
  -h, --help    Show this help

Set ANDROID_SERIAL=<serial> if more than one adb device is attached.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --list-only) LIST_ONLY=1 ;;
        --reboot) REBOOT=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $arg"
            ;;
    esac
done

command -v "$ADB" >/dev/null 2>&1 || die "adb not found in PATH"

ADB_CMD=("$ADB")
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    ADB_CMD+=("-s" "$ANDROID_SERIAL")
fi

adb_cmd() {
    "${ADB_CMD[@]}" "$@"
}


if [[ "$LIST_ONLY" -eq 1 ]]; then
    adb_cmd shell '
set -u
if ! grep -q " /sys/fs/pstore " /proc/mounts 2>/dev/null; then
    mkdir -p /sys/fs/pstore
    mount -t pstore pstore /sys/fs/pstore 2>/dev/null || mount -t pstore none /sys/fs/pstore 2>/dev/null || true
fi

if [ ! -d /sys/fs/pstore ]; then
    echo "ERROR: /sys/fs/pstore is not available" >&2
    exit 1
fi

found=0
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    found=1
    ls -l "$f"
done
[ "$found" -eq 1 ] || echo "(no pstore records)"
'
    exit 0
fi

echo "[*] Clearing /sys/fs/pstore on device..."
adb_cmd shell '
set -u
if ! grep -q " /sys/fs/pstore " /proc/mounts 2>/dev/null; then
    mkdir -p /sys/fs/pstore
    mount -t pstore pstore /sys/fs/pstore 2>/dev/null || mount -t pstore none /sys/fs/pstore 2>/dev/null || true
fi

if [ ! -d /sys/fs/pstore ]; then
    echo "ERROR: /sys/fs/pstore is not available" >&2
    exit 1
fi

echo "Before:"
found=0
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    found=1
    ls -l "$f"
done
[ "$found" -eq 1 ] || echo "  (no pstore records)"

cleared=0
failed=0
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    if rm -f "$f" 2>/dev/null; then
        cleared=$((cleared + 1))
    elif : > "$f" 2>/dev/null; then
        cleared=$((cleared + 1))
    else
        echo "WARN: failed to clear $f" >&2
        failed=$((failed + 1))
    fi
done

sync
echo
echo "Cleared $cleared pstore record(s)."
echo "After:"
remaining=0
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    remaining=1
    ls -l "$f"
done
[ "$remaining" -eq 1 ] || echo "  (no pstore records)"

[ "$failed" -eq 0 ]
'

if [[ "$REBOOT" -eq 1 ]]; then
    echo "[*] Rebooting device..."
    adb_cmd reboot
fi
