#!/system/bin/sh
# sampler v11 (OBSERVER, PLAN-oos-time E0): one line / 15 s, MODEM-SOURCED signal.
#   MODEM  reg/plmn/LTE srv_status/is_forbidden/usage      (nas-probe status, NAS 0x24/0x34/0x4D)
#   SIG    serving-cell rsrp/rsrq/snr/rssi                 (nas-probe sig, NAS 0x4F)  <- replaces v10's framework RSRP
#   CELL   earfcn/pci/srxlev + neighbour list w/ srxlev    (nas-probe sig, NAS 0x43)  <- S-criterion as the modem sees it
#   FW     mVoiceRegState/mDataRegState/channel/emergency  (framework, for the "what the user saw" column only)
#   IMS    imsa-probe every 4th sample (60 s)
# No intervention of any kind. Same timeout rules as v9/v10 (never `export LD_PRELOAD; timeout`).
# Start:  setsid nohup sh /data/local/tmp/rec/sampler-v11.sh >/dev/null 2>&1 & echo $! > /data/local/tmp/rec/sampler-v11.pid
# Stop:   kill $(cat /data/local/tmp/rec/sampler-v11.pid)        Dies on reboot (restart after `adb root`).
R=/data/local/tmp/rec; mkdir -p $R
ENV="LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64"
NP=/data/local/tmp/nas-probe
n=0
while true; do
  t=$(date +%m-%d\ %H:%M:%S); t0=$(cut -d. -f1 /proc/uptime)
  mdm=$(timeout 12 env $ENV $NP status 2>/dev/null | grep -E "registration_state|current PLMN|LTE +srv_status|is_forbidden|usage_preference" | sed -E 's/registration_state += ([0-9]).*/reg=\1/; s/current PLMN += mcc ([0-9]+) mnc ([0-9]+).*/plmn=\1\2/; s/LTE +srv_status = ([0-9]).*/lte=\1/; s/.*is_forbidden += ([0-9]).*/forb=\1/; s/.*usage_preference += ([0-9]).*/usage=\1/' | tr '\n' ' ')
  [ -z "$mdm" ] && mdm="TIMEOUT"
  sigout=$(timeout 12 env $ENV $NP sig 2>/dev/null)
  sig=$(echo "$sigout" | grep -m1 "^SIG lte" | sed 's/^SIG lte //')
  [ -z "$sig" ] && sig="$(echo "$sigout" | grep -m1 '^SIG' | cut -c5-)"
  [ -z "$sig" ] && sig="nosig"
  cell=$(echo "$sigout" | grep -m1 "^CELL lte" | sed -E 's/^CELL lte //; s/ gci=[0-9]+//; s/ prio=[0-9]+//')
  [ -z "$cell" ] && cell="nocell"
  ims=""
  if [ $((n % 4)) -eq 0 ]; then
    ims=$(timeout 10 env $ENV /data/local/tmp/imsa-probe 2>/dev/null | grep -E "ims_registered|voip_service_status|voip_service_rat" | sed -E "s/ +=+ +/=/; s/ +\(.*//" | tr "\n" " ")
  fi
  reg=$(timeout 8 dumpsys telephony.registry 2>/dev/null)
  ss=$(echo "$reg" | grep -m1 -E "mVoiceRegState" | grep -oE 'mVoiceRegState=[0-9]|mDataRegState=[0-9]|mChannelNumber=-?[0-9]+|mIsEmergencyOnly=[a-z]+' | sed -E 's/mVoiceRegState/v/; s/mDataRegState/d/; s/mChannelNumber/ch/; s/mIsEmergencyOnly/emg/' | tr '\n' ' ')
  wifi=$(ip -4 -o addr show wlan0 2>/dev/null | grep -c " inet ")
  op=$(getprop gsm.operator.numeric); sim=$(getprop gsm.sim.state); la=$(cut -d' ' -f1 /proc/loadavg)
  t1=$(cut -d. -f1 /proc/uptime)
  echo "$t | MODEM $mdm| SIG $sig | CELL $cell | FW $ss| IMS $ims| op=$op sim=$sim wifi=$wifi load=$la took=$((t1-t0))s" >> $R/sample-v11.log
  n=$((n + 1))
  d=$((15 - (t1 - t0))); [ $d -lt 3 ] && d=3; sleep $d
done
