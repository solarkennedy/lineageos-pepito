#!/bin/bash
# Outgoing call left ringing, with the modem's IMS log packets captured (SIP, RTP, RTCP).
# Answers "does the network send ringback audio (early media) while the far end rings?"
# for the no-ringback-on-MO-calls report (Neil, 2026-11-06).
#
#   diag-tools/ringback/capture-mo-ringing.sh <caller-nick> <callee-nick> [ring_s] [--keep-wifi]
#
# Caller must be on USB (Wi-Fi goes off so the call is on LTE). The callee is only dialled:
# mute its ringer first. On A17 units diag goes through the A16 shim kit; on stock 8.1
# (silver) through /vendor/bin/diag_mdlog. One diag session per boot on A17, and stop with -k,
# never kill -9 (memory diag-mdlog-kill9-wedge). Output: diag-tools/ringback/captures/<stamp>-<caller>/
set -euo pipefail
CALLER=$1 CALLEE=$2 RING_S=${3:-20} KEEP_WIFI=${4:-}
TOOLS=~/Projects/pepito-diag-tools
CFG=${CFG:-Diag-ims.cfg}   # Diag-road-ims.cfg = road mask + IMS RTP items (writes files; IMS-only may sit in the buffer)
A="$CALLER-adb"
NUM=$(awk -v n="$CALLEE" '$1==n{print $2}' ~/.config/pepito/unit-numbers)
[ -n "$NUM" ] || { echo "no number for $CALLEE in unit-numbers"; exit 1; }
OUT=$(dirname "$0")/captures/$(date +%Y%m%d-%H%M%S)-$CALLER
mkdir -p "$OUT"
T=/data/local/tmp

$A root >/dev/null 2>&1 || true; sleep 2
$A shell "input keyevent KEYCODE_WAKEUP; svc power stayon usb"   # A17: the diag stream dies at the first AP suspend (-e helps)
if $A shell '[ -x /vendor/bin/diag_mdlog ]'; then
    MDLOG="/vendor/bin/diag_mdlog"                         # stock 8.1
else
    $A shell "mkdir -p $T/diag"
    $A push $TOOLS/diag-a16-shim/{diag_mdlog,libdiag.so,libdiagshim.so} $T/diag/ >/dev/null
    $A shell "chmod 755 $T/diag/diag_mdlog"
    MDLOG="env LD_PRELOAD=$T/diag/libdiagshim.so LD_LIBRARY_PATH=$T/diag:/system/lib64 $T/diag/diag_mdlog"
fi
$A push $TOOLS/$CFG $T/$CFG >/dev/null
$A shell "pidof diag_mdlog" && { echo "$CALLER: diag_mdlog already running; stop it with diag_mdlog -k first"; exit 1; }

cleanup() {
    $A shell "$MDLOG -k" >/dev/null 2>&1 || true
    [ -n "$KEEP_WIFI" ] || $A shell 'svc wifi enable' || true
    $A shell "svc power stayon false" || true
}
trap cleanup EXIT

$A shell "rm -rf $T/ringcap; mkdir -p $T/ringcap; ( setsid $MDLOG -e -f $T/$CFG -o $T/ringcap >$T/ringcap.log 2>&1 & )"
sleep 3
$A shell 'pidof diag_mdlog' >/dev/null || { echo "diag_mdlog did not start:"; $A shell "cat $T/ringcap.log"; exit 1; }
[ -n "$KEEP_WIFI" ] || $A shell 'svc wifi disable'
echo "waiting for IMS on LTE..."
for i in $(seq 1 30); do
    $A shell 'dumpsys telephony.registry 2>/dev/null | grep -m1 -oE "getRilVoiceRadioTechnology=[0-9]+"' | grep -q '=14' && break
    sleep 2
done
sleep 10   # let IMS move off IWLAN
T0=$($A shell "date +%s.%3N")
$A shell "date +%s.%N > $T/ringcap/t-dial; am start -a android.intent.action.CALL -d tel:$NUM >/dev/null"
sleep "$RING_S"
$A shell "date +%s.%N > $T/ringcap/t-hangup; input keyevent KEYCODE_ENDCALL"
sleep 4
$A logcat -d -b main,radio,system -v epoch -T "$T0" > "$OUT/logcat"
$A shell "$MDLOG -k" >/dev/null 2>&1 || true
sleep 3
$A pull $T/ringcap "$OUT/" >/dev/null
echo "capture in $OUT: $(ls "$OUT"/ringcap/*.qmdl 2>/dev/null | wc -l) qmdl"
