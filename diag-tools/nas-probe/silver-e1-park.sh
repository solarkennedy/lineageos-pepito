#!/bin/bash
# silver-e1-park.sh arm|status|stop|pull <label>|decode <dir>
#
# PLAN-oos-time E1 re-run on silver (stock A8, rooted via /su, SIM in): capture
# modem F3 while IMS is forced down (Settings > Mobile network > Enhanced 4G LTE
# Mode OFF) to see which PLMN the stock modem parks on when its own home PLMN is
# voice-forbidden. Native diag_mdlog, Diag-road.cfg mask (18 SSIDs + RRC/NAS OTA),
# 100 MB x 40 rotation (~0.45 MB/s on this mask => ~4 min/file, ~2.5 h), plus the
# 30 s framework sampler. diag_mdlog runs as the shell user: stock lets shell
# open /dev/diag, and /su on silver is uid 0 with only CAP_SETUID/SETGID, so a
# /su-started logger can neither be killed by /su nor by -k. /su is used only
# to read dmesg.
#
#   arm            start diag + sampler (refuses if no SIM / diag mux unhealthy)
#   status         last sampler lines + registry state + diag file sizes
#   stop           stop diag (-k, never kill -9) and the sampler
#   pull <label>   stop + pull everything to $CAPDIR/silver-e1-<label>-<date>/
#   decode <dir>   decode the pulled qmdls with silver's stock QDB -> timeline.txt
set -u
S=4373dd0f
ADB="silver-adb"
CFG=/data/local/tmp/Diag-road.cfg
SCAP=/data/local/tmp/scap-e1
CAPDIR=${CAPDIR:-$HOME/android/lineage-23/diag-tools/captures}
QDB=$HOME/android/lineage-23/diag-tools/captures/stock-diff-l1/silver-qdb.dec
DECODE=$HOME/android/lineage-23/diag-tools/decode_f3.py
HERE=$(cd "$(dirname "$0")" && pwd)

A(){ $ADB shell "$@" 2>/dev/null | tr -d '\r'; }
R(){ echo "$*" | $ADB shell /su 2>/dev/null | tr -d '\r'; }   # run as root (stdin mode)
need_serial(){ [ "$(A getprop ro.serialno)" = "$S" ] || { echo "not silver ($S)"; exit 1; }; }

case "${1:-}" in
arm)
  need_serial
  sim=$(A getprop gsm.sim.state); op=$(A getprop gsm.operator.numeric)
  echo "sim=$sim operator=$op"
  [ "$sim" = "LOADED" ] || { echo "REFUSE: SIM not loaded (move the SIM from new2 first)"; exit 1; }
  if R "dmesg" | grep -q -E "diag.*-107"; then echo "REFUSE: diag mux already shows -107 (reboot silver first)"; exit 1; fi
  A "/vendor/bin/diag_mdlog -k" >/dev/null; sleep 1
  A "rm -rf $SCAP; mkdir -p $SCAP"
  A "setsid nohup /vendor/bin/diag_mdlog -f $CFG -o $SCAP -s 100 -n 40 </dev/null >/dev/null 2>&1 &"
  sleep 4
  A "pkill -f silver-sampler.sh" >/dev/null
  A "setsid nohup sh /data/local/tmp/silver-sampler.sh >/dev/null 2>&1 &"
  echo "diag pid: $(A pidof diag_mdlog)  sampler: $(A 'pgrep -f silver-sampler.sh' | head -1)"
  A "log -t E1 'armed'"
  echo
  echo "NOW (by hand, on silver): Settings > Network & Internet > Mobile network > Enhanced 4G LTE Mode -> OFF."
  echo "Then: $0 status   every few minutes. Expect the park within ~15 s to a few minutes."
  echo "Let it sit >= 10 min parked, then toggle Enhanced 4G back ON, wait for voice, then: $0 pull <label>"
  ;;
status)
  need_serial
  echo "diag pid: $(A pidof diag_mdlog)   files:"; A "ls -l $SCAP" | grep -E "qmdl|qdb" | awk '{print "   ", $5, $NF}'
  echo "--- sampler tail"; A "tail -4 /data/local/tmp/silver-sample.log" | cut -c1-200
  echo "--- registry"; A "dumpsys telephony.registry" | grep -m1 -oE 'mVoiceRegState=[0-9]|mDataRegState=[0-9]|mVoiceOperatorNumeric=[0-9]*|mIsEmergencyOnly=[a-z]+' | tr '\n' ' '; echo
  echo "--- IMS (framework)"; A "dumpsys telephony.registry" | grep -m1 -oE 'mImsRegistered=[a-z]+|ImsRegistrationState[^,]{0,40}' | head -2
  ;;
stop)
  need_serial
  A "log -t E1 'stop'"
  A "/vendor/bin/diag_mdlog -k" >/dev/null; sleep 3
  p=$(A pidof diag_mdlog); [ -n "$p" ] && { A "kill -HUP $p"; sleep 3; }
  A "pkill -f silver-sampler.sh" >/dev/null
  echo "diag still running: $(A pidof diag_mdlog || echo none)   dmesg -107: $(R dmesg | grep -c -E 'diag.*-107')"
  ;;
pull)
  need_serial
  label=${2:?label}; out="$CAPDIR/silver-e1-$label-$(date +%Y%m%d-%H%M)"
  "$0" stop
  mkdir -p "$out"
  $ADB pull $SCAP "$out/" >/dev/null 2>&1
  $ADB pull /data/local/tmp/silver-sample.log "$out/" >/dev/null 2>&1
  A "logcat -b radio,main -d -v threadtime" > "$out/logcat.txt"
  echo "pulled to $out:"; ls -la "$out"/scap-e1 2>/dev/null | awk '{print "   ", $5, $NF}' | grep -E "qmdl|qdb"
  echo "next: $0 decode $out"
  ;;
decode)
  d=${2:?dir}
  for q in "$d"/scap-e1/*.qmdl; do
    [ -e "$q" ] || continue
    b=$(basename "$q" .qmdl)
    python3 -I "$DECODE" "$QDB" "$q" > "$d/$b.f3.txt" 2>"$d/$b.f3.err"
    python3 -I "$HERE/f3_timeline.py" "$d/$b.f3.txt" > "$d/$b.timeline.txt"
    echo "$b: $(wc -l < "$d/$b.f3.txt") F3 lines -> $b.timeline.txt"
  done
  echo "read: grep -E 'reg_sim|Forbidden|forbidden|emc_|LIMITED|PLMN|srv_status|camped' $d/*.timeline.txt | less"
  ;;
*) sed -n 2,16p "$0"; exit 2;;
esac
