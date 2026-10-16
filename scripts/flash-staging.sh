#!/usr/bin/env bash
# Flash partitions from flash-staging/ via EDL (Qualcomm 9008).
#
# Requires: qdl, adb (optional — used to trigger EDL automatically).
# Staging images come from scripts/prepare-flash.sh.
#
# Usage:
#   ./flash-staging.sh                # flash dut1: adb reboot edl, flash, wait for adb
#   ./flash-staging.sh new2           # same, for another unit (nick, serial or IMEI)
#   ./flash-staging.sh -s 9c2e6b00    # explicit serial (also --serial)
#   ./flash-staging.sh --no-adb       # skip ADB trigger, wait for manual EDL entry
#   ./flash-staging.sh new2 --wipe    # flash, then boot straight into recovery and wipe /data
#   ./flash-staging.sh --no-unlock    # leave the lockscreen up after the post-flash boot
#
# --wipe stages a 4 KiB misc.bin holding a bootloader control block
# (command "boot-recovery", args "--wipe_data"): aboot sees it and boots
# recovery, recovery formats /data + /metadata, clears the block and reboots
# into the fresh system. Only the BCB is written — misc keeps vendor data past
# 0x8000 — and misc.bin is deleted again afterwards so a later flash can't
# re-wipe. config.bin (zeroed FRP) is always flashed, so FRP stays in lockstep.
#
# The unit is resolved through the fleet roster (~/.config/pepito/units.conf,
# $PEPITO_UNITS overrides); a serial not in the roster is used as-is. Every adb
# call is pinned to that serial (USB, plain `adb -s` — no pepito-adb probing,
# the unit may be mid-boot), and qdl is pinned to it too when the EDL device's
# _SN: matches, so other phones on the bench are never touched.
# After the post-flash boot the script roots adbd and, when the roster has a
# `PATTERN <nick> <dots>` line for the unit, unlocks the pattern lockscreen
# with pepito-unlock (best effort: a failed unlock never fails the flash).
# Env: PEPITO_ADB_WAIT=<sec> how long to wait for adb after the flash (default 600).
#
# Canonically lives here; flash-staging/flash-staging.sh is a symlink to it.

set -euo pipefail

FLASH_DIR="${FLASH_DIR:-/home/kyle/android/lineage-24/flash-staging}"
BOOT_IMG="$FLASH_DIR/boot.bin"
EDL_USB_ID="05c6:9008"
NO_ADB=0
WIPE=0
UNLOCK=1
UNIT=dut1   # flashed most often

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-adb)      NO_ADB=1 ;;
        -s|--serial)   [[ -n "${2:-}" ]] || die "$1 needs a value"; UNIT=$2; shift ;;
        --serial=*)    UNIT=${1#--serial=} ;;
        --wipe)        WIPE=1 ;;
        --no-unlock)   UNLOCK=0 ;;
        -h|--help)     sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)            die "unknown option $1 (try --help)" ;;
        *)             UNIT=$1 ;;
    esac
    shift
done

# Resolve nick/serial/IMEI → nick + serial via the roster.
UNITS_CONF=${PEPITO_UNITS:-$HOME/.config/pepito/units.conf}
ROW=""
[[ -f "$UNITS_CONF" ]] && ROW=$(awk -v w="$UNIT" '!/^#/ && NF>=6 && !/^DAILY=/ && ($1==w || $2==w || $3==w){print; exit}' "$UNITS_CONF")
if [[ -n "$ROW" ]]; then
    NICK=$(awk '{print $1}' <<<"$ROW")
    SERIAL=$(awk '{print $2}' <<<"$ROW")
    [[ "$SERIAL" != "-" ]] || die "$NICK has no serial in $UNITS_CONF"
else
    [[ "$UNIT" =~ ^[0-9A-Za-z]{6,}$ ]] || die "'$UNIT' is not in $UNITS_CONF and doesn't look like a serial"
    NICK=$UNIT
    SERIAL=$UNIT
fi
echo "Target: $NICK ($SERIAL)"

dadb() { adb -s "$SERIAL" "$@"; }

# EDL serials of every 9008 device qdl can see, one per line ("qdl list" prints
# "... (PID 0x9008, serial: XXXX)"). Empty when qdl has no `list` subcommand.
edl_serials() {
    "$QDL" list 2>/dev/null | sed -n 's/.*serial: *\([^)]*\)).*/\1/p'
}
edl_count() { lsusb 2>/dev/null | grep -c "$EDL_USB_ID" || true; }

# Never fatal: a finished flash must not report failure because ntfy is down.
notify() {
    /home/kyle/.bin/ntfy-main "$1" "$2" "${3:-default}" || true
}

# Wipe pstore so the next boot's ramoops is from this flash, not the last one.
clear_ramoops() {
    local cmd="if [ -d /sys/fs/pstore ]; then rm -f /sys/fs/pstore/*ramoops* /sys/fs/pstore/pmsg-*; sync; fi"
    echo "Clearing ramoops via ADB..."
    dadb shell "$cmd" >/dev/null 2>&1 && return 0
    dadb shell su 0 sh -c "$cmd" >/dev/null 2>&1 && return 0
    echo "WARNING: Could not clear ramoops; continuing with EDL reboot." >&2
}

# PVG100 names hardcoded: the bench DUTs are all US-variant hardware. The
# PVG100E (pvg100e_firehose.elf + rawprogram0.pvg100e.xml) ships in the
# release bundle only — see release.sh.
for f in "$BOOT_IMG" "$FLASH_DIR/pvg100_firehose.elf" "$FLASH_DIR/rawprogram0.pvg100.xml"; do
    [[ -f "$f" ]] || die "$f not found — run scripts/prepare-flash.sh first"
done

# Refuse a half-copied staging dir. qdl --allow-missing silently skips absent
# images and happily writes a truncated one — flashing mid-rsync left new2 with
# 87% of system.bin, no vendor.bin, and a system_server crash loop (10-14).
ls "$FLASH_DIR"/.*.bin.* >/dev/null 2>&1 \
    && die "rsync temp files in $FLASH_DIR ($(cd "$FLASH_DIR" && ls .*.bin.* | tr '\n' ' ')) — a copy is still running or died; re-run it"
[[ -n "$(ls -A "$FLASH_DIR/.rsync-partial" 2>/dev/null)" ]] \
    && die "unfinished rsync partials in $FLASH_DIR/.rsync-partial ($(ls -A "$FLASH_DIR/.rsync-partial" | tr '\n' ' ')) — re-run the fetch"
# misc.bin only ever exists while a --wipe flash runs; one left behind (an
# aborted --wipe) would silently factory-reset the next unit flashed.
[[ -e "$FLASH_DIR/misc.bin" ]] \
    && die "stale $FLASH_DIR/misc.bin (wipe BCB from an aborted --wipe?) — delete it and re-run"
if [[ -f "$FLASH_DIR/system.bin" || -f "$FLASH_DIR/vendor.bin" ]]; then
    for img in system.bin vendor.bin; do
        [[ -f "$FLASH_DIR/$img" ]] || die "$img missing but its partner is staged — incomplete copy?"
    done
fi
# A raw ext4 image must be exactly its superblock's block count × block size.
ext4_expected_bytes() {
    local f=$1 magic blocks log
    magic=$(od -An -tx2 -j 1080 -N 2 "$f" | tr -d ' ')
    [[ "$magic" == "ef53" ]] || return 1
    blocks=$(od -An -tu4 -j 1028 -N 4 "$f" | tr -d ' ')
    log=$(od -An -tu4 -j 1048 -N 4 "$f" | tr -d ' ')
    echo $(( blocks * (1024 << log) ))
}
for img in system.bin vendor.bin; do
    f="$FLASH_DIR/$img"
    [[ -f "$f" ]] || continue
    want=$(ext4_expected_bytes "$f") || die "$img has no ext4 superblock — corrupt or wrong file"
    have=$(stat -c %s "$f")
    [[ "$have" -eq "$want" ]] \
        || die "$img is $have bytes but its superblock says $want — truncated copy, re-sync it"
done
# qdl binary: $QDL override > modern linux-msm build > PATH (old pepito fork).
if [[ -z "${QDL:-}" ]]; then
    for cand in "$HOME/.local/bin/qdl" "$HOME/Projects/qdl-upstream/build/qdl" "$(command -v qdl || true)"; do
        [[ -n "$cand" && -x "$cand" ]] && QDL=$cand && break
    done
fi
[[ -n "${QDL:-}" ]] || die "no qdl binary found (set QDL=...)"
echo "Using qdl: $QDL ($("$QDL" --version 2>/dev/null || echo 'pepito fork, no --version'))"
# Modern qdl needs --allow-missing for rawprogram entries whose images aren't
# staged (userdata, gpt_*); the old fork skipped those silently and ignores
# the flag's long form, so only pass it when supported.
ALLOW_MISSING=()
"$QDL" --help 2>&1 | grep -q "allow-missing" && ALLOW_MISSING=(--allow-missing)

echo "Boot image: $BOOT_IMG ($(du -h "$BOOT_IMG" | cut -f1))"

# Anything already sitting in EDL before we reboot ours is some OTHER phone.
EDL_BEFORE=$(edl_count)
# With --no-adb the user put the phone in EDL by hand, so a device already there is ours.
[[ "$NO_ADB" -eq 1 ]] && EDL_BEFORE=0

if [[ "$NO_ADB" -eq 0 ]] && command -v adb >/dev/null; then
    [[ "$(dadb get-state 2>/dev/null)" == "device" ]] \
        || die "$NICK ($SERIAL) is not on adb — plug it in, or use --no-adb and enter EDL by hand"
    clear_ramoops
    echo "Triggering EDL reboot of $NICK..."
    dadb reboot edl
    sleep 3
fi

echo "Waiting for EDL device ($EDL_USB_ID) — if not already there: power off → hold Vol↑ → plug USB"
QDL_SERIAL=()
for i in $(seq 1 30); do
    # Prefer an exact _SN: match (case-insensitive: PBL may report it upper-case).
    match=$(edl_serials | awk -v s="$SERIAL" 'tolower($0)==tolower(s){print; exit}')
    if [[ -n "$match" ]]; then
        QDL_SERIAL=(--serial "$match")
        break
    fi
    # No serial match: accept only a lone EDL device that appeared after our reboot.
    # Give the match a few seconds first — the USB string can lag enumeration.
    if [[ $i -ge 5 && "$EDL_BEFORE" -eq 0 && "$(edl_count)" -eq 1 ]]; then
        echo -e "\nWARNING: the EDL device's serial doesn't match $SERIAL ($(edl_serials | tr '\n' ' ')); it is the only one, flashing it." >&2
        break
    fi
    [[ $i -eq 30 ]] && die "Timed out waiting for $NICK in EDL after 30s (EDL serials seen: $(edl_serials | tr '\n' ' '))"
    printf "\r  [%2ds] waiting..." "$i"
    sleep 1
done
echo -e "\nEDL device detected${QDL_SERIAL[1]:+ (serial ${QDL_SERIAL[1]})}."

# Run from FLASH_DIR so qdl resolves the rawprogram XML's filenames relative to it.
if [[ "$WIPE" -eq 1 ]]; then
    # struct bootloader_message: command[32] @0, status[32] @32, recovery[768] @64.
    trap 'rm -f "$FLASH_DIR/misc.bin"' EXIT
    head -c 4096 /dev/zero > "$FLASH_DIR/misc.bin"
    printf 'boot-recovery' | dd of="$FLASH_DIR/misc.bin" conv=notrunc status=none
    printf 'recovery\n--wipe_data\n' | dd of="$FLASH_DIR/misc.bin" bs=1 seek=64 conv=notrunc status=none
    echo "WIPE: staged misc.bin — $NICK will boot recovery and wipe /data after the flash."
fi

FLASH_START=$SECONDS
(cd "$FLASH_DIR" && systemd-inhibit "$QDL" --storage emmc "${ALLOW_MISSING[@]}" "${QDL_SERIAL[@]}" pvg100_firehose.elf rawprogram0.pvg100.xml)

notify "Flash complete — $NICK" \
"qdl finished in $(( (SECONDS - FLASH_START) / 60 ))m
boot.bin $(du -h "$BOOT_IMG" | cut -f1)
now waiting for adb to come back up"

echo
ADB_WAIT=${PEPITO_ADB_WAIT:-600}
echo "Flash done. Waiting up to ${ADB_WAIT}s for $NICK ($SERIAL) on adb..."
if [[ "$WIPE" -eq 1 ]]; then
    # The wipe takes the adb authorization (and the USB-debugging toggle) with
    # it, so adb staying away is the expected outcome — not a failure.
    if timeout "$ADB_WAIT" adb -s "$SERIAL" wait-for-device; then
        echo "$NICK is up after the wipe: $(dadb shell getprop ro.lineage.version 2>/dev/null | tr -d '\r')"
    else
        echo "$NICK wiped; adb didn't come back (expected — re-enable USB debugging in setup)."
    fi
    notify "Flash + wipe done — $NICK" "finish first-boot setup on the phone"
    exit 0
fi
if ! timeout "$ADB_WAIT" adb -s "$SERIAL" wait-for-device; then
    notify "Flash: $NICK never came back on adb" "waited ${ADB_WAIT}s after qdl — check the phone" high
    die "$NICK ($SERIAL) did not come back on adb within ${ADB_WAIT}s"
fi
dadb root
timeout 60 adb -s "$SERIAL" wait-for-device || true   # adbd restarts as root
echo "$NICK is up: $(dadb shell getprop ro.lineage.version 2>/dev/null | tr -d '\r')"

# Unlock the lockscreen, like the root step above. One attempt only: each
# failed pepito-unlock run counts as a wrong pattern (5 = 30 s lockout).
PATTERN=""
[[ -f "$UNITS_CONF" ]] && PATTERN=$(awk -v n="$NICK" '$1=="PATTERN" && $2==n {print $3; exit}' "$UNITS_CONF")
if [[ "$UNLOCK" -eq 1 && -n "$PATTERN" ]] && command -v pepito-unlock >/dev/null; then
    echo "Waiting for boot_completed to unlock $NICK..."
    if timeout 300 adb -s "$SERIAL" wait-for-device shell \
            'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'; then
        sleep 5   # keyguard comes up just after boot_completed
        pepito-unlock "adb -s $SERIAL" "$PATTERN" \
            || echo "WARNING: could not unlock $NICK — unlock it by hand" >&2
    else
        echo "WARNING: $NICK never reported boot_completed; not unlocking" >&2
    fi
fi
