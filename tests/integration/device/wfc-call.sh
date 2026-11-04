#!/system/bin/sh
# wfc-call.sh <dir> <number> <hold_s> [wifi_off_at_s]
#
# One scripted MO call (or, with <number> "-", an MT call: see below), run ON the phone (setsid) so it survives adb dropping when
# Wi-Fi goes away. Writes <dir>/samples (1 s: epoch, call state, IMSA voip rat,
# RSRP, the bridge's TH2 state and Wi-Fi-validated flag), <dir>/marks (epoch +
# event) and <dir>/logcat (radio+main from the start of the run). With
# wifi_off_at_s it disables Wi-Fi that many seconds after dialling and always
# re-enables it before exiting. With PRE_WWAN=<s> in the environment it first
# gets IMS voice onto LTE (Wi-Fi off, if voice is not there already) and waits up
# to that long for it, marking on_wwan or no_wwan; no_wwan skips the call. "done"
# in marks means the run is over.
#
# MT (<number> "-"): marks "armed" once the sampler is up, waits up to RING_S
# (default 90) for the phone to ring (no_ring if it never does), answers, and
# holds until the far end hangs up ("ended") or hold_s + 30 s pass ("hangup",
# and we end it).
D=$1; NUM=$2; HOLD=$3; OFF=${4:-}
PRE=${PRE_WWAN:-}; WIFI_DOWN=
IMSA=${IMSA:-/data/local/tmp/imsa-probe}
QMI='LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64'

rm -rf "$D"; mkdir -p "$D"
mark() { echo "$(date +%s) $1" >>"$D/marks"; }

# Call audio at the quietest the phone allows (STREAM_VOICE_CALL minimum is 1,
# not 0), so a test call does not blare out of the earpiece; put the user's
# level back on exit.
vol() { cmd media_session volume --stream 0 "$@" 2>/dev/null; }
VOL=$(vol --get | grep -oE 'volume is [0-9]+' | grep -oE '[0-9]+$')
vol --set 1 >/dev/null
# An MT test call must not ring out loud either: ringer (stream 2) to 0 while it runs.
ring() { cmd media_session volume --stream 2 "$@" 2>/dev/null; }
if [ "$NUM" = - ]; then
    RVOL=$(ring --get | grep -oE 'volume is [0-9]+' | grep -oE '[0-9]+$')
    ring --set 0 >/dev/null
fi

cleanup() {
    [ -n "$VOL" ] && vol --set "$VOL" >/dev/null
    [ -n "${RVOL:-}" ] && ring --set "$RVOL" >/dev/null
    # The in-call proximity sensor can blank the screen and the phone then
    # dozes; screen-off Wi-Fi does not rejoin its network (no PNO), so wake it
    # before giving Wi-Fi back or the run leaves the phone off Wi-Fi.
    input keyevent KEYCODE_WAKEUP
    [ -n "$OFF$WIFI_DOWN" ] && { svc wifi enable; mark wifi_on; sleep 3; }
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

# IMSA voip_service_rat: 0 WLAN, 1 WWAN; voip_service_status 2 = full service.
voip() { env $QMI "$IMSA" 2>/dev/null | grep -oE "voip_service_$1 *= *[0-9]+" | grep -oE '[0-9]+$'; }
if [ -n "$PRE" ]; then
    if [ "$(voip rat)" != 1 ]; then
        WIFI_DOWN=1; mark wifi_off; svc wifi disable
    fi
    i=0
    until [ "$(voip rat)" = 1 ] && [ "$(voip status)" = 2 ]; do
        i=$((i + 2))
        [ "$i" -ge "$PRE" ] && { mark no_wwan; exit 0; }
        sleep 2
    done
    mark on_wwan
fi

callstate() { dumpsys telephony.registry 2>/dev/null | grep -m1 -oE 'mCallState=[0-9]+' | cut -d= -f2; }

sleep 3
if [ "$NUM" = - ]; then
    mark armed
    i=0
    until [ "$(callstate)" = 1 ]; do
        i=$((i + 1))
        [ "$i" -ge "${RING_S:-90}" ] && { mark no_ring; exit 0; }
        sleep 1
    done
    mark ring
    sleep 2
    # Call screening (GApps dialer spam filter) can reject it before we answer.
    [ "$(callstate)" = 1 ] || { mark rejected; sleep 5; exit 0; }
    input keyevent KEYCODE_CALL
    sleep 3
    [ "$(callstate)" = 1 ] && input keyevent KEYCODE_HEADSETHOOK
    mark answer
    i=0
    while [ "$i" -lt $((HOLD + 30)) ]; do
        [ "$(callstate)" = 0 ] && { mark ended; sleep 5; exit 0; }
        i=$((i + 1)); sleep 1
    done
    mark hangup
    input keyevent KEYCODE_ENDCALL
    sleep 5
    exit 0
fi

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
