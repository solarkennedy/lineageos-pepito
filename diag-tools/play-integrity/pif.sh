#!/bin/bash
# pif.sh — drive the framework Play Integrity spoof hooks (frameworks/base
# android.security.pif, inert unless configured) on a bench phone.
#
#   pif.sh <unit> apply <config.json>   push a config to Settings.Secure, restart
#                                       DroidGuard + Play Store, show what flipped
#   pif.sh <unit> clear                 remove it (back to the honest identity)
#   pif.sh <unit> status                current config + recent PIF log lines
#   pif.sh <unit> cell <config.json>    apply, then run check-integrity.py
#   pif.sh <unit> sweep [config...]     run `cell` for each config (default:
#                                       configs/*.json), then clear
#
# Config keys: any Build / Build.VERSION field name (FINGERPRINT, MODEL,
# SECURITY_PATCH, SDK_INT, DEVICE_INITIAL_SDK_INT, ...) plus the knobs
# spoofBuild, spoofProvider (hide HW attestation from DroidGuard),
# spoofSignature, spoofVendingFinger, spoofVendingSdk, verboseLogs.
# Keys starting with "_" are comments. No reboot needed, except that
# spoofSignature is applied once per DroidGuard process start.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
KEY=spoof_pif_config

[ $# -ge 2 ] || { sed -n 2,19p "$0"; exit 1; }
UNIT=$1; shift
ADB=${ADB:-$UNIT-adb}
CMD=$1; shift

restart_targets() {
    $ADB shell 'am force-stop com.android.vending; for p in com.google.android.gms.unstable; do pid=$(pidof $p 2>/dev/null) && kill $pid; done; true' >/dev/null
}

apply() {
    local f=$1
    [ -f "$f" ] || { echo "no such config: $f" >&2; exit 1; }
    $ADB shell "settings put secure $KEY '$(tr -d '\n' < "$f" | sed "s/'/'\\\\''/g")'"
    restart_targets
    echo "applied $(basename "$f"): $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("_comment",""))' "$f")"
}

# Not `logcat -s`: the PIF/Java:DG tag's colon reads as a priority separator there.
log() { $ADB shell 'logcat -d -v time' | grep -E '[VDIWE]/(PIF|PIF/Java:(DG|PS)) *\(' | tail -${1:-30}; }

cell() {
    local f=$1
    # Clear before apply: DroidGuard can start during the Play Store navigation,
    # before the check's own tap, and its PIF lines must survive.
    $ADB shell 'logcat -b all -c'
    apply "$f"
    "$HERE/check-integrity.py" --keep-log "$UNIT" | grep -E '^(verdict|labels|saved)=?' | sed 's/^saved: /saved=/' || true
    echo "--- DroidGuard PIF log for this run:"
    log 40 | grep -E 'loaded|Applied|Java:DG|attestation|Signature|Failed' || echo "(no PIF lines: hook did not fire?)"
}

case $CMD in
    apply) apply "$1"; sleep 1; log 10;;
    clear) $ADB shell settings delete secure $KEY >/dev/null; restart_targets; echo "cleared";;
    status)
        echo "## Settings.Secure.$KEY:"; $ADB shell settings get secure $KEY
        echo "## recent PIF log:"; log 30;;
    cell) cell "$1";;
    sweep)
        [ $# -gt 0 ] || set -- "$HERE"/configs/*.json
        for f in "$@"; do echo "=================== $(basename "$f")"; cell "$f"; done
        $ADB shell settings delete secure $KEY >/dev/null; restart_targets
        echo "=================== sweep done, config cleared";;
    *) sed -n 2,19p "$0"; exit 1;;
esac
