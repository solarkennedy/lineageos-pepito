#!/system/bin/sh
# wfc-call.sh <dir> <number> <hold_s> [wifi_off_at_s]
#
# One scripted MO call, run ON the phone (setsid) so it survives adb dropping when
# Wi-Fi goes away. Writes <dir>/samples (1 s: epoch, call state, IMSA voip rat,
# RSRP, the bridge's TH2 state and Wi-Fi-validated flag), <dir>/marks (epoch +
# event) and <dir>/logcat (radio+main from the start of the run). With
# wifi_off_at_s it disables Wi-Fi that many seconds after dialling and always
# re-enables it before exiting. "done" in marks means the run is over.
D=$1; NUM=$2; HOLD=$3; OFF=${4:-}
IMSA=${IMSA:-/data/local/tmp/imsa-probe}
QMI='LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64'

rm -rf "$D"; mkdir -p "$D"
mark() { echo "$(date +%s) $1" >>"$D/marks"; }

cleanup() {
    [ -n "$OFF" ] && { svc wifi enable; mark wifi_on; sleep 3; }
    touch "$D/stop"; sleep 2
    kill "$LOGCAT" 2>/dev/null
    mark done
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

(
    while [ ! -e "$D/stop" ]; do
        t=$(date +%s)
        rat=$(env $QMI "$IMSA" 2>/dev/null | grep -oE 'voip_service_rat *= *[0-9]+' | grep -oE '[0-9]+$')
        reg=$(dumpsys telephony.registry 2>/dev/null)
        cs=$(echo "$reg" | grep -m1 -oE 'mCallState=[0-9]+' | cut -d= -f2)
        rsrp=$(echo "$reg" | grep -m1 -oE 'rsrp=-?[0-9]+' | cut -d= -f2)
        echo "$t cs=$cs rat=$rat rsrp=$rsrp th2=$(getprop vendor.qmux.wfc_th2) wifi_ok=$(getprop vendor.qmux.wfc_wifi_ok)"
        sleep 1
    done >"$D/samples" 2>&1
) &

logcat -b radio -b main -v epoch -T "$(date +%s).000" >"$D/logcat" 2>&1 &
LOGCAT=$!

sleep 3
mark dial
am start -a android.intent.action.CALL -d "tel:$NUM" >/dev/null 2>&1
if [ -n "$OFF" ]; then
    sleep "$OFF"; mark wifi_off; svc wifi disable
    sleep $((HOLD - OFF))
else
    sleep "$HOLD"
fi
mark hangup
input keyevent KEYCODE_ENDCALL
sleep 5
