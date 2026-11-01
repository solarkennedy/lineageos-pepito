#!/bin/bash
# capture-return-to-wlan.sh [unit] — F3 capture of "IMS never returns to WLAN" (PLAN-android17
# "Bench 2026-11-01"). Run on a FRESH boot (one diag session per boot; never stop it with
# kill -9 or -k, see memory diag-mdlog-kill9-wedge). Arms diag_mdlog -e with Diag-wfc.cfg,
# waits for IMS on WLAN, then does two abrupt Wi-Fi losses (loss #2 is the one that sticks),
# watching the modem's per-APN table (DSD 0x24) and the IMS RAT. Leaves diag running; pull
# the qmdl while it runs. Private output (IMSI/MSISDN): ~/android/lineage-24/field-logs/.
set -u
U=${1:-dut1}; A="$U-adb"
D23=~/android/lineage-23/diag-tools
OUT=~/android/lineage-24/field-logs/$U-tmo-wfc-return-$(date +%Y%m%d-%H%M); mkdir -p "$OUT"
$A push $D23/Diag-wfc.cfg /data/local/tmp/Diag-wfc.cfg >/dev/null
$A shell 'pidof diag_mdlog && { echo "diag_mdlog already running: this boot is spent"; exit 1; }
cd /data/local/tmp; rm -rf wret; mkdir wret
( setsid env LD_PRELOAD=/data/local/tmp/diag/libdiagshim.so LD_LIBRARY_PATH=/data/local/tmp/diag:/system/lib64 /data/local/tmp/diag/diag_mdlog -e -f /data/local/tmp/Diag-wfc.cfg -o /data/local/tmp/wret >/data/local/tmp/wret.log 2>&1 & )
input keyevent KEYCODE_WAKEUP; svc power stayon true
until ls wret/*.qmdl >/dev/null 2>&1; do sleep 3; done
Q="LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64"
st() { echo "$(date +%T) $1 $(env $Q ./imsa-probe 2>/dev/null | grep -oE "voip_service_rat *= *[0-9]+" | tr -s " ") ims_apn=$(env $Q ./dsd-probe.full 2>/dev/null | grep "TLV 0x11" | grep -oE "03 69 6d 73 0[0-9]" | tail -c 3) wok=$(getprop vendor.qmux.wfc_wifi_ok) ch=$(dumpsys telephony.registry 2>/dev/null | grep -m1 -oE "mChannelNumber=[0-9]+")" >> wret.marks; }
: > wret.marks; st boot
for i in $(seq 1 36); do sleep 5; st wait-wlan; env $Q ./imsa-probe 2>/dev/null | grep -q "voip_service_rat *= *0" && break; done
for n in 1 2; do
  st "loss$n-wifi_off"; svc wifi disable; for i in 1 2 3 4; do sleep 5; st "loss$n-off"; done
  input keyevent KEYCODE_WAKEUP; st "loss$n-wifi_on"; svc wifi enable
  for i in $(seq 1 30); do sleep 5; st "loss$n-on"; done
done
st end; tail -3 wret.marks; ls -la wret'
$A pull /data/local/tmp/wret "$OUT/" >/dev/null; $A pull /data/local/tmp/wret.marks "$OUT/" >/dev/null
Q=/tmp/claude-1000/wfccap/$U-214411.qdb.dec
[ -f "$Q" ] || { $A pull /firmware/image/qdsp6m.qdb /tmp/$U.qdb >/dev/null && python3 $D23/build_qdb.py /tmp/$U.qdb "$Q"; }
python3 $D23/decode_f3.py "$Q" "$OUT"/wret/*.qmdl '.' > "$OUT/f3-full.txt" 2>&1
echo "capture in $OUT ($(wc -l < "$OUT/f3-full.txt") F3 lines); diag_mdlog still running on $U (leave it)"
echo "first look: grep -nE 'Initiate HO to sys|IsSetPrefSysDuplicate|apn_pref_sys_change|s2b_pdn_throttle|epdg_addr|ikev2|s2b_pdn_sm' $OUT/f3-full.txt"
