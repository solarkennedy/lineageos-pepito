#!/system/bin/sh
# flash-report.sh -- PHONE-SIDE flash tracer for reporters.  Runs entirely on the phone (Android
# toybox shell), so the computer only needs adb: Windows, macOS and Linux use the same commands.
# Analyse the bundle it produces with flash-analyze.py (on our side).
#
# While it runs it records: the kernel flash ioctls (INIT/LOW/OFF/HIGH) and the PMIC strobe
# current, the "Flash power" cap, the PMIC VPH-droop latch (0xd318), battery state at every
# photo, camera HAL frame timing (logcat), and a copy of every photo taken.  Once started the
# phone may be UNPLUGGED -- the trace keeps going and the bundle lands in Download/.
#
# ---------------------------------------------------------------- for the reporter ----------
#  Needs: a computer with Android platform-tools (adb).  Windows: download "SDK Platform-Tools
#  for Windows" from developer.android.com/tools/releases/platform-tools, unzip it, put this
#  file in that folder, open a terminal there (PowerShell: type .\adb instead of adb).
#
#  On the phone: Settings > System > Developer options: "USB debugging" ON and
#  "Rooted debugging" ON.  Plug in, accept the prompt.  Set PVG100 System Tweaks > Camera >
#  Flash power to the setting that still fails for you.  Best: reboot the phone first and
#  start straight after unlocking (the first shots after a boot fail most often).
#
#    adb root
#    adb push flash-report.sh /data/local/tmp/
#    adb shell "tr -d '\r' < /data/local/tmp/flash-report.sh > /data/local/tmp/fr && sh /data/local/tmp/fr start 5"
#
#  Then: open the camera, flash ON, darkish room, point at a wall, take 5 photos, waiting about
#  5 seconds between them.  Plugged in or not -- whichever way it fails for you (say which).
#  When the 5th photo is saved, the trace stops by itself (or after 20 minutes).  Then:
#
#    adb pull /sdcard/Download/flash-report.tar.gz
#
#  (or send Download/flash-report-*.tar.gz from the phone's Files app).  Say which photos
#  looked wrong.  Progress:  adb shell sh /data/local/tmp/fr status
#  Stop early:               adb shell sh /data/local/tmp/fr stop
# ---------------------------------------------------------------------------------------------
D=/data/local/tmp/flash-report
W=$D/w
MODE=${1:-start}
N=${2:-5}
TIMEOUT=${3:-1200}
LATCH_NODE=/sys/kernel/debug/regmap/spmi0-03

alive() { [ -f $D/pid ] && kill -0 "$(cat $D/pid)" 2>/dev/null; }
uptime_s() { cut -d' ' -f1 /proc/uptime; }
latch() { (cd $LATCH_NODE 2>/dev/null && echo 0xd318 > address && echo 1 > count && cat data) | sed -E 's/.*: *//'; }
bat() { cd /sys/class/power_supply/battery && echo "status=$(cat status) soc=$(cat capacity) uV=$(cat voltage_now) uA=$(cat current_now) temp=$(cat temp)"; cd /; }
mark() { log -t FLASHTRACE "shot $1"; echo "FLASHTRACE shot $1" > /dev/kmsg; }
photos() { find /sdcard/DCIM /sdcard/Pictures -type f -newer $W/start.stamp \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' \) 2>/dev/null | grep -v '/\.' | sort; }

case "$MODE" in
start)
	[ "$(id -u)" = 0 ] || { echo "Not root. Turn on Developer options > Rooted debugging, run 'adb root', then try again."; exit 1; }
	alive && { echo "Already running:"; cat $D/state; exit 0; }
	rm -rf $D; mkdir -p $W
	cp "$0" $D/self.sh
	setsid sh $D/self.sh run "$N" "$TIMEOUT" > $D/run.log 2>&1 < /dev/null &
	sleep 3
	cat $D/run.log
	echo
	echo ">>> Tracing.  If your camera app is open, close it (swipe it away) and reopen it."
	echo ">>> Take $N photos with flash ON, ~5 s apart.  You can unplug the phone now if you want."
	echo ">>> The trace stops after the ${N}th photo; then: adb pull /sdcard/Download/flash-report.tar.gz"
	;;
status)
	cat $D/state 2>/dev/null || echo "not started"
	alive && echo "(running)" || echo "(not running)"
	;;
stop)
	touch $D/stop; echo "stopping; the bundle is written to /sdcard/Download in a few seconds"
	;;
run)
	echo $$ > $D/pid
	SER=$(getprop ro.serialno)
	NAME=flash-report-$SER-$(date +%Y%m%d-%H%M%S)
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
	{
	echo "# flash-report $(date)  serial=$SER  shots=$N"
	echo "build:       $(getprop ro.lineage.version) / android $(getprop ro.build.version.release)"
	echo "variant:     hwversion=$(getprop ro.boot.hwversion) hwc=$(getprop ro.boot.hwc) product=$(getprop ro.product.device)"
	echo "kernel:      $(uname -v)"
	echo "uptime:      $(uptime_s) s at start"
	echo "flash power: persist.gotweak.flash_ma='$(getprop persist.gotweak.flash_ma)' kernel flash_cap_ma=$(cat /sys/module/msm_flash/parameters/flash_cap_ma 2>/dev/null || echo MISSING)"
	echo "battery:     $(bat) health=$(cat /sys/class/power_supply/battery/health)"
	echo "usb:         online=$(cat /sys/class/power_supply/usb/online 2>/dev/null) type=$(cat /sys/class/power_supply/usb/real_type 2>/dev/null || cat /sys/class/power_supply/usb/type 2>/dev/null)"
	echo "bms:         resistance=$(cat /sys/class/power_supply/bms/resistance) charge_full=$(cat /sys/class/power_supply/bms/charge_full) cycle_count=$(cat /sys/class/power_supply/bms/cycle_count)"
	echo "latch:       0xd318=$(latch) at start"
	echo "reg_dump:    $(cat /sys/class/leds/led:switch/reg_dump | tr '\n' ' ')"
	echo "camera pkgs: $(pm list packages 2>/dev/null | grep -iE 'camera|aperture|gcam' | tr '\n' ' ')"
	} > $W/info.txt
	dmesg > $W/dmesg-before.txt
	echo "file msm_flash.c +p" > /sys/kernel/debug/dynamic_debug/control
	echo "file leds-qpnp-flash.c +p" > /sys/kernel/debug/dynamic_debug/control
	echo 1 > /sys/kernel/debug/flashLED/enable_debug
	setprop persist.vendor.camera.hal.debug 4
	# the HAL reads its log level when the camera opens
	am force-stop org.lineageos.aperture
	touch $W/start.stamp
	dmesg -w > $W/kmsg.txt 2>&1 &
	KP=$!
	logcat -c
	logcat -v monotonic > $W/logcat.txt 2>&1 &
	LP=$!
	sleep 1
	mark 0
	echo "collecting: 0/$N photos" > $D/state
	cat $D/state
	T0=$(date +%s); SHOTS=0; LAST=$(latch); SEEN=""
	echo "$(uptime_s) latch $LAST (start)" > $W/latch.txt
	while [ "$SHOTS" -lt "$N" ] && [ ! -f $D/stop ] && [ $(( $(date +%s) - T0 )) -lt "$TIMEOUT" ]; do
		sleep 0.5
		L=$(latch)
		[ "$L" != "$LAST" ] && { echo "$(uptime_s) latch $L" >> $W/latch.txt; LAST=$L; }
		for p in $(photos); do
			case " $SEEN " in *" $p "*) continue ;; esac
			SEEN="$SEEN $p"
			sleep 1.5
			SHOTS=$((SHOTS + 1))
			mark $SHOTS
			echo "shot=$SHOTS up=$(uptime_s) latch=$(latch) cap=$(cat /sys/module/msm_flash/parameters/flash_cap_ma 2>/dev/null) $(bat) photo=$p" >> $W/shots.txt
			cp "$p" $W/shot$SHOTS.${p##*.}
			echo "collecting: $SHOTS/$N photos" > $D/state
		done
	done
	sleep 2
	kill $KP $LP 2>/dev/null
	echo "file msm_flash.c -p" > /sys/kernel/debug/dynamic_debug/control
	echo "file leds-qpnp-flash.c -p" > /sys/kernel/debug/dynamic_debug/control
	echo 0 > /sys/kernel/debug/flashLED/enable_debug
	setprop persist.vendor.camera.hal.debug ""
	echo "end: $(date) uptime=$(uptime_s) shots=$SHOTS $( [ -f $D/stop ] && echo '(stopped)')" >> $W/info.txt
	cd $D && mv w $NAME
	if tar czf $D/out.tar.gz $NAME 2>/dev/null; then :; else tar cf $D/out.tar.gz $NAME; fi
	cp $D/out.tar.gz /sdcard/Download/$NAME.tar.gz
	cp $D/out.tar.gz /sdcard/Download/flash-report.tar.gz
	rm -rf $D/$NAME
	echo "DONE: $SHOTS photos -> /sdcard/Download/$NAME.tar.gz (also Download/flash-report.tar.gz)" > $D/state
	cat $D/state
	cmd notification post -t "Flash report ready" flashreport "Download/$NAME.tar.gz" > /dev/null 2>&1
	rm -f $D/pid
	;;
*)
	echo "usage: sh fr start [SHOTS] [TIMEOUT_S] | status | stop"; exit 2 ;;
esac
