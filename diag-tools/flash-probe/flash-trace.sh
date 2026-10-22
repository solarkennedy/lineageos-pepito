#!/bin/bash
# flash-trace.sh -- did the camera flash STROBE for one photo?  (kernel-level ground truth)
#
# Traces the flash subdev ioctls (INIT/RELEASE/OFF/LOW/HIGH) through the kernel's dynamic
# debug while you take ONE flash photo, then classifies the result and dumps the
# flash-block registers, battery state and unit identity next to it.  Works on any
# LineageOS pepito build (needs `adb root`) and is what to ask a reporter to run.
#
#   flash-trace.sh [-s SERIAL] [--auto SECS] [-o report.txt]
#     -s SERIAL     adb serial (default: the only device, or $ANDROID_SERIAL)
#     --auto SECS   start Aperture, wait SECS, press the camera key for you
#                   (set the flash mode to ON in Aperture FIRST; it is remembered)
#     -o FILE       write the report there (default: flash-trace-<serial>-<date>.txt)
#
# Classification (from `dmesg`):
#   LOW .. OFF .. HIGH .. OFF   = normal: preflash, then the main strobe was commanded
#   LOW .. OFF, no HIGH         = the camera daemon never asked for the strobe
#   HIGH with "Invalid state"   = the driver dropped the strobe (state machine desync)
#   HIGH present but photo dark = the PMIC cut the pulse in hardware (droop/thermal/fault)
#
# Reference runs (2026-10-22, 24.0 20261017, new2/dut1/gold): LOW ~0.45 s before the snapshot
# frame, OFF ~0.25 s before, HIGH 30-115 ms before, OFF 0-70 ms after; photo EXIF "FIRED",
# meanY 120-150 in a dark room.  See PLAN-misc.md §9 addenda 3-5.
#
# For a reporter (Linux/macOS host with adb; Windows: use WSL or Git Bash):
#   1. enable USB debugging, plug in, accept the prompt;  `adb devices` must list the phone
#   2. bash flash-trace.sh            (it runs `adb root` itself -- the ROM allows it)
#   3. when asked, open Camera, set flash ON, take ONE photo, press Enter
#   4. send back the flash-trace-*.txt, .dmesg, .logcat and .jpg files
set -u
SER=""; AUTO=""; OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		-s) SER="$2"; shift 2 ;;
		--auto) AUTO="$2"; shift 2 ;;
		-o) OUT="$2"; shift 2 ;;
		*) echo "unknown arg $1" >&2; exit 2 ;;
	esac
done
A=(adb); [ -n "$SER" ] && A=(adb -s "$SER")
SERIAL=$("${A[@]}" shell getprop ro.serialno 2>/dev/null | tr -d '\r')
[ -z "$SERIAL" ] && { echo "no device (use -s SERIAL)"; exit 1; }
[ -z "$OUT" ] && OUT="flash-trace-${SERIAL}-$(date +%Y%m%d-%H%M%S).txt"

sh() { "${A[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }

"${A[@]}" root >/dev/null 2>&1; sleep 2
[ "$(sh id -u)" = "0" ] || { echo "need a root adb shell (adb root failed)"; exit 1; }

{
echo "# flash-trace $(date -Is)  serial=$SERIAL"
echo "build:    $(sh getprop ro.lineage.version) / android $(sh getprop ro.build.version.release)"
echo "variant:  hwversion=$(sh getprop ro.boot.hwversion) hwc=$(sh getprop ro.boot.hwc) product=$(sh getprop ro.product.device)"
echo "battery:  $(sh 'cd /sys/class/power_supply/battery && echo status=$(cat status) capacity=$(cat capacity) voltage_now=$(cat voltage_now) current_now=$(cat current_now) temp=$(cat temp) health=$(cat health) flash_active=$(cat flash_active 2>/dev/null)')"
echo "bms:      resistance=$(sh cat /sys/class/power_supply/bms/resistance) charge_full=$(sh cat /sys/class/power_supply/bms/charge_full) cycle_count=$(sh cat /sys/class/power_supply/bms/cycle_count)"
echo "leds:     $(sh 'ls /sys/class/leds | tr "\n" " "')"
echo "reg_dump before: $(sh 'cat /sys/class/leds/led:switch/reg_dump | tr "\n" " "')"
} | tee "$OUT"

# the HAL reads its log level when the camera is opened -- close the app first so it reopens
sh 'am force-stop org.lineageos.aperture; mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug; echo "file msm_flash.c +p" > /sys/kernel/debug/dynamic_debug/control; setprop persist.vendor.camera.hal.debug 4; dmesg -c > /dev/null; logcat -c'
"${A[@]}" logcat -v monotonic > "$OUT.logcat" 2>/dev/null &
LCPID=$!
# clock offset: kernel printk time vs logcat monotonic time
sh 'log -t FLASHTRACE mark; echo FLASHTRACE > /dev/kmsg'
echo "trace armed." | tee -a "$OUT"

BEFORE=$(sh 'ls -t /sdcard/DCIM/Camera 2>/dev/null | head -1')
if [ -n "$AUTO" ]; then
	sh 'am start -n org.lineageos.aperture/.CameraActivity' >/dev/null
	echo "Aperture started; pressing the camera key in $AUTO s (flash mode must already be ON)" | tee -a "$OUT"
	sleep "$AUTO"
	T0=$(sh 'cut -d" " -f1 /proc/uptime')
	sh 'input keyevent KEYCODE_CAMERA'
	sleep 6
else
	echo
	echo ">>> Now open the camera app, set the flash to ON, take ONE photo, then press Enter here."
	read -r _
fi

NEWEST=$(sh 'ls -t /sdcard/DCIM/Camera 2>/dev/null | head -1')
[ "$NEWEST" = "$BEFORE" ] && { echo "NO NEW PHOTO was saved -- the shot did not happen; rerun." | tee -a "$OUT"; NEWEST=""; }
"${A[@]}" shell dmesg > "$OUT.dmesg" 2>/dev/null
sleep 1; kill $LCPID 2>/dev/null
sh 'echo "file msm_flash.c -p" > /sys/kernel/debug/dynamic_debug/control; setprop persist.vendor.camera.hal.debug ""'

{
echo "reg_dump after:  $(sh 'cat /sys/class/leds/led:switch/reg_dump | tr "\n" " "')"
echo "battery after:   voltage_now=$(sh cat /sys/class/power_supply/battery/voltage_now) status=$(sh cat /sys/class/power_supply/battery/status)"
echo "newest photo:    $NEWEST"
echo "--- flash ioctl trace (kernel time) ---"
grep -E 'msm_flash_config:[0-9]+ Enter|Invalid state|flash_current|Enable/Disable Regulator|open_fault|qpnp-flash' "$OUT.dmesg" \
	| sed -E 's/msm_flash_config:[0-9]+ Enter msm_flash_config type 0/INIT/; s/type 1$/RELEASE/; s/type 2$/OFF/; s/type 3$/LOW/; s/type 4$/HIGH/' \
	| sed -E 's/msm_flash_config:[0-9]+ Enter msm_flash_config //'
echo "--- strobe vs snapshot frame (logcat clock) ---"
KM=$(grep -m1 'FLASHTRACE' "$OUT.dmesg" | sed -E 's/^\[ *([0-9.]+)\].*/\1/')
LM=$(grep -m1 'FLASHTRACE' "$OUT.logcat" | awk '{print $1}')
BLOB=$(grep 'stream format = 33' "$OUT.logcat" | tail -1 | sed -E 's/.*frame = ([0-9]+),.*/\1/')
SOF=$(grep "valid frame_number = $BLOB," "$OUT.logcat" | head -1 | sed -E 's/.*capture_time = ([0-9-]+).*/\1/')
if [ -n "$KM" ] && [ -n "$LM" ] && [ -n "$BLOB" ] && [ -n "$SOF" ]; then
	OFFS=$(python3 -c "print($LM-$KM)")
	echo "clock offset logcat-kernel = $OFFS s; snapshot request = frame $BLOB, SOF = $(python3 -c "print($SOF/1e9)")"
	grep -E 'msm_flash_config:[0-9]+ Enter' "$OUT.dmesg" | sed -E 's/^\[ *([0-9.]+)\].*type ([0-9]).*/\1 \2/' | while read -r kt ty; do
		case $ty in 0) n=INIT;; 1) n=RELEASE;; 2) n=OFF;; 3) n=LOW;; 4) n=HIGH;; *) n=$ty;; esac
		python3 -c "d=($kt+$OFFS)-$SOF/1e9; print(f'  {\"$n\":8s} at SOF {d*1000:+8.0f} ms')"
	done
	echo "  (frame exposes from SOF -exposure_time to SOF +readout ~40 ms; HIGH should start before SOF and OFF after SOF+60 ms)"
else
	echo "  (could not align: KM=$KM LM=$LM BLOB=$BLOB SOF=$SOF)"
fi
if [ -n "$NEWEST" ] && python3 -c "import PIL" 2>/dev/null; then
	"${A[@]}" pull "/sdcard/DCIM/Camera/$NEWEST" "$OUT.jpg" >/dev/null 2>&1 && python3 -I -c "
from PIL import Image; im=Image.open('$OUT.jpg'); ex=im.getexif().get_ifd(0x8769); g=im.convert('L').resize((30,40)); px=list(g.getdata())
f=ex.get(0x9209); print('photo: exif_flash=%s (%s) expo=%s iso=%s meanY=%d' % (f, 'FIRED' if f is not None and f&1 else 'not fired', ex.get(0x829A), ex.get(0x8827), sum(px)/len(px)))"
fi
echo "--- verdict ---"
T=$(grep -E 'msm_flash_config:[0-9]+ Enter' "$OUT.dmesg" | grep -o 'type [0-9]' | tr -d 'type ' | tr -d '\n')
case "$T" in
	*3*2*4*2*) echo "NORMAL: preflash (LOW/OFF) then the main strobe (HIGH/OFF) was commanded. If the photo is still dark the PMIC cut the pulse in hardware." ;;
	*3*2*)     echo "NO STROBE REQUESTED: preflash ran but the daemon never sent HIGH." ;;
	*4*)       echo "HIGH without a preflash sequence -- unusual, read the trace." ;;
	"")        echo "NO FLASH IOCTLS AT ALL: no photo taken, or the camera did not open the flash subdev." ;;
	*)         echo "sequence '$T' -- read the trace." ;;
esac
grep -q 'Invalid state' "$OUT.dmesg" && echo "DRIVER DROPPED A REQUEST (Invalid state) -- state-machine desync, see flash-torch-state-machine notes."
} | tee -a "$OUT"
echo "report: $OUT  (also send: $OUT.dmesg $OUT.logcat $OUT.jpg)"
