#!/bin/bash
# ap-release-census.sh <unit> [out-dir]
#
# Read-only census of every AP -> modem request class that can make the modem
# drop, re-select or re-attach a cell ("let go of the tower"), pulled from a
# bench unit's radio log over adb.  Companion to PLAN-emergency-only.md
# "2026-10-20 AP-side let-go audit".  Touches nothing on the phone.
#
#   ./ap-release-census.sh new2            # summary on stdout, raw logs in /tmp
#   ./ap-release-census.sh dut1 ./census    # keep raw logs in ./census
#
# Three buckets:
#   COMMAND  requests that change modem system-selection / attach state
#            (a non-zero count in a fault window is a lead)
#   STATE    requests that change persistent modem policy (fine at boot,
#            suspicious at runtime)
#   READ     polling that cannot release a cell (load only)
set -euo pipefail

unit=${1:?usage: ap-release-census.sh <unit nick: new2|dut1|silver|gold> [out-dir]}
out=${2:-/tmp/ap-release-census-$unit-$(date +%Y%m%d-%H%M%S)}
adb="${unit}-adb"
mkdir -p "$out"

serial=$($adb shell getprop ro.serialno | tr -d '\r')
echo "unit=$unit serialno=$serial out=$out"

$adb shell 'logcat -b radio -d -v threadtime' | tr -d '\r' > "$out/radio.log"
$adb shell 'logcat -b main,system -d -v threadtime -s wfc_wlan_bridge:* ims_enabler:* modem_b12:* EmergencyWatchdog:* DSRM-0:* DSRM-1:*' \
    | tr -d '\r' > "$out/daemons.log"
$adb shell 'cat /proc/uptime; for p in qcrild imsqmidaemon imsdatadaemon wfc_wlan_bridge netmgrd; do pid=$(pidof $p 2>/dev/null | cut -d" " -f1); if [ -n "$pid" ]; then echo "$p pid=$pid start_jiffies=$(cut -d" " -f22 /proc/$pid/stat)"; else echo "$p NOT-RUNNING"; fi; done' \
    | tr -d '\r' > "$out/daemons.txt"

R="$out/radio.log"
first=$(grep -m1 -E '^[0-9]{2}-[0-9]{2} ' "$R" | cut -c1-18 || true)
last=$(grep -E '^[0-9]{2}-[0-9]{2} ' "$R" | tail -1 | cut -c1-18 || true)
echo "radio log window: ${first:-?} .. ${last:-?}  ($(wc -l < "$R") lines)"
echo

count_req() {  # count_req NAME  -> RILJ "> NAME" requests
    grep -c -E "RILJ.*\]> $1( |\$)" "$R" || true
}

COMMAND=(RADIO_POWER SET_ALLOWED_NETWORK_TYPES_BITMAP SET_PREFERRED_NETWORK_TYPE
         SET_NETWORK_SELECTION_AUTOMATIC SET_NETWORK_SELECTION_MANUAL
         SET_INITIAL_ATTACH_APN SET_DATA_PROFILE DEACTIVATE_DATA_CALL
         NV_RESET_CONFIG ENABLE_MODEM SHUTDOWN START_NETWORK_SCAN STOP_NETWORK_SCAN
         SET_SYSTEM_SELECTION_CHANNELS SET_BAND_MODE SET_RADIO_CAPABILITY
         SET_SIM_CARD_POWER SET_UICC_SUBSCRIPTION EXIT_EMERGENCY_CALLBACK_MODE
         SET_USAGE_SETTING)
STATE=(SET_SIGNAL_STRENGTH_REPORTING_CRITERIA SET_LINK_CAPACITY_REPORTING_CRITERIA
       SET_UNSOLICITED_RESPONSE_FILTER SET_LOCATION_UPDATES SET_CELL_INFO_LIST_RATE
       ALLOW_DATA SET_PREFERRED_DATA_MODEM SET_CDMA_ROAMING_PREFERENCE
       SET_CDMA_SUBSCRIPTION_SOURCE SETUP_DATA_CALL SET_CARRIER_INFO_IMSI_ENCRYPTION)

echo "== COMMAND class (can release / re-select / re-attach)"
for r in "${COMMAND[@]}"; do n=$(count_req "$r"); [ "$n" != 0 ] && printf '  %6d  %s\n' "$n" "$r"; done
echo "  (anything not listed = 0)"
echo
echo "== STATE class (policy writes; expected at boot only)"
for r in "${STATE[@]}"; do n=$(count_req "$r"); [ "$n" != 0 ] && printf '  %6d  %s\n' "$n" "$r"; done
echo
echo "== READ class, top 12 (load only)"
grep -E 'RILJ.*\]> ' "$R" | sed -E 's/.*\]> ([A-Za-z_0-9]+).*/\1/' | sort | uniq -c | sort -rn | head -12 | sed 's/^/  /'
echo
echo "== unsolicited, top 10"
grep -E 'RILJ.*\[UNSL\]< ' "$R" | sed -E 's/.*\[UNSL\]< ([A-Za-z_0-9]+).*/\1/' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
echo
echo "== framework recovery / RIL lifecycle"
printf '  %6d  DSRM lines (DataStallRecoveryManager)\n' "$(grep -c -E 'DSRM|DataStallRecovery' "$R" || true)"
printf '  %6d  DSRM actions actually taken\n' "$(grep -c -E 'DSRM.*(doRecovery|RECOVERY_ACTION_(CLEANUP|RADIO_RESTART|RESET_MODEM).*(start|perform|execut))' "$R" || true)"
printf '  %6d  DSRM skipped (poor signal)\n' "$(grep -c 'skip data stall recovery as in poor signal' "$R" || true)"
printf '  %6d  RIL_CONNECTED / RADIO_STATE_CHANGED / RADIO_UNAVAILABLE\n' "$(grep -c -E 'RIL_CONNECTED|RADIO_STATE_CHANGED|RADIO_UNAVAILABLE|RADIO_NOT_AVAILABLE' "$R" || true)"
printf '  %6d  ServiceState transitions to NOT_REG / OUT_OF_SERVICE / EMERGENCY_ONLY\n' "$(grep -c -E 'Poll ServiceState done.*(mVoiceRegState=[123]|EMERGENCY_ONLY|mIsEmergencyOnly=true)' "$R" || true)"
echo
echo "== our daemons (main/system log)"
D="$out/daemons.log"
printf '  %6d  wfc_wlan_bridge WLAN_AVAILABLE sends\n'      "$(grep -c -E 'wfc_wlan_bridge.*(WLAN_AVAILABLE|sent available|assoc)' "$D" || true)"
printf '  %6d  wfc_wlan_bridge WLAN_NOT_AVAILABLE sends\n'  "$(grep -c -E 'wfc_wlan_bridge.*NOT_AVAILABLE' "$D" || true)"
printf '  %6d  EmergencyWatchdog nudges\n'                  "$(grep -c -E 'EmergencyWatchdog.*(nudge|setNetworkSelectionModeAutomatic|setRadioPower)' "$D" || true)"
printf '  %6d  EmergencyWatchdog state lines\n'             "$(grep -c 'EmergencyWatchdog' "$D" || true)"
printf '  %6d  ims_enabler / modem_b12 NV writes\n'         "$(grep -c -E '(ims_enabler|modem_b12).*(wrote|set |SET|write)' "$D" || true)"
echo
echo "== daemon lifetimes (start_jiffies/100 = seconds after boot; uptime first field)"
sed 's/^/  /' "$out/daemons.txt"
echo
echo "Raw logs kept in $out"
