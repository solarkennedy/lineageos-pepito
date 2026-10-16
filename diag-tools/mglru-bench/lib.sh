#!/bin/bash
# mglru-bench/lib.sh — shared host-side helpers. Sourced by the three bench scripts.
#
# Unit: ${PEPITO_ADB:-dut1-adb}. Nothing here reboots, flashes or toggles a radio.
# The scripts keep the screen on for the run (svc power stayon) and restore it after.

set -u
ADB=${PEPITO_ADB:-dut1-adb}
NICK=${ADB%-adb}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESULTS=${MGLRU_RESULTS:-$HERE/results}
DEV_TMP=/data/local/tmp/mglru-bench

sh() { $ADB shell "$@" | tr -d '\r'; }

# Default app set for app-cycle / hog-resume: launcher activities present on the
# gapps bench build (checked on dut1 2026-10-15). Override with APPS="a b c" or args.
DEFAULT_APPS=(
    com.android.settings/.Settings
    com.google.android.apps.messaging/.ui.ConversationListActivity
    com.google.android.contacts/com.android.contacts.activities.PeopleActivity
    com.google.android.dialer/.extensions.GoogleDialtactsActivity
    org.lineageos.jelly/.MainActivity
    org.lineageos.aperture/.CameraLauncher
    org.lineageos.glimpse/.MainActivity
    org.lineageos.twelve/.MainActivity
    org.lineageos.etar/com.android.calendar.AllInOneActivity
    com.android.deskclock/.DeskClock
    com.android.calculator2/.Calculator
    com.android.documentsui/.LauncherActivity
    org.lineageos.recorder/.RecorderActivity
    com.android.vending/.AssetBrowserActivity
    com.google.android.googlequicksearchbox/.SearchActivity
)

pkg_of() { echo "${1%%/*}"; }

# Verify the unit, root it (pstore/dmesg later), make the results dir.
bench_init() {
    local tag=$1
    local serial
    serial=$(sh getprop ro.serialno)
    [ -n "$serial" ] || { echo "no device on $ADB" >&2; exit 1; }
    $ADB root >/dev/null 2>&1; sleep 2
    RUN=$RESULTS/$(date +%Y%m%d-%H%M%S)-$tag
    mkdir -p "$RUN"
    {
        echo "adb $ADB serial $serial"
        echo "build $(sh getprop ro.build.version.incremental) kernel $(sh uname -r)"
        echo "uptime_s $(sh cut -d. -f1 /proc/uptime)"
        echo "lru_gen $(sh 'cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo absent')"
        echo "zram $(sh 'cat /sys/block/zram0/comp_algorithm') disksize $(sh cat /sys/block/zram0/disksize)"
        echo "swappiness $(sh cat /proc/sys/vm/swappiness) wsf $(sh cat /proc/sys/vm/watermark_scale_factor) extra_free_kbytes $(sh 'cat /proc/sys/vm/extra_free_kbytes 2>/dev/null')"
        echo "lmk_props $(sh 'getprop | grep ro.lmk' | tr '\n' ' ')"
        echo "args $*"
    } | tee "$RUN/meta.txt"
    sh "mkdir -p $DEV_TMP"
}

# Screen on + unlocked, and kept on for the run. bench_done undoes the stayon.
bench_awake() {
    sh svc power stayon true >/dev/null
    sh input keyevent KEYCODE_WAKEUP
    if sh dumpsys window | grep -q 'isKeyguardShowing=true'; then
        # On a swipe-only keyguard the unlocker's swipe dismisses it, then it exits 1
        # for want of a pattern grid; trust the keyguard state, not the exit code.
        android-unlock-"$NICK" 2>/dev/null
        sleep 1
        sh dumpsys window | grep -q 'isKeyguardShowing=true' && { echo "could not unlock $NICK" >&2; exit 1; }
    fi
    sh input keyevent KEYCODE_HOME
    sleep 1
}

bench_done() {
    sh input keyevent KEYCODE_HOME
    sh svc power stayon false >/dev/null
}

# Counter snapshot, one "key value" per line. Everything in it is cumulative
# since boot except the Mem*/Swap*/zram_* gauges. Single adb round trip.
snapshot() {
    sh '
      echo uptime_s $(cut -d. -f1 /proc/uptime)
      grep -E "^(pgscan_kswapd|pgscan_direct|pgsteal_kswapd|pgsteal_direct|allocstall_normal|allocstall_movable|workingset_refault|workingset_activate|workingset_restore|pswpin|pswpout|pgmajfault|pgfault|oom_kill|kswapd_low_wmark_hit_quickly|kswapd_high_wmark_hit_quickly|compact_stall) " /proc/vmstat
      awk "/^some/ {sub(\"total=\",\"\",\$5); print \"psi_some_us\", \$5} /^full/ {sub(\"total=\",\"\",\$5); print \"psi_full_us\", \$5}" /proc/pressure/memory
      for p in /proc/[0-9]*; do
        case "$(cat $p/comm 2>/dev/null)" in kswapd0*) echo kswapd_run_ns $(cut -d" " -f1 $p/schedstat);; esac
      done
      echo lmk_kills $(dumpsys activity lmk | awk "/Total number of kills/ {print \$5}")
      awk "/^(MemFree|MemAvailable|SwapFree|Mapped|AnonPages):/ {print \$1, \$2}" /proc/meminfo | tr -d :
      set -- $(cat /sys/block/zram0/mm_stat); echo zram_orig_b $1; echo zram_compr_b $2
      echo lru_gen $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo absent)
    '
}

# Start/stop an on-device logcat of the kill reporters for a window.
killlog_start() { sh "nohup logcat -T 1 -s lowmemorykiller:* ActivityManager:I -v time > $DEV_TMP/killlog.$1 2>&1 & echo \$! > $DEV_TMP/killlog.pid"; }
killlog_stop()  {
    sh "kill \$(cat $DEV_TMP/killlog.pid) 2>/dev/null; sleep 0.5"
    $ADB pull "$DEV_TMP/killlog.$1" "$RUN/killlog.$1.txt" >/dev/null 2>&1
    sh "logcat -b events -d | grep am_kill" > "$RUN/am_kill.$1.txt"
}

# am start -W, parsed to "STATE total_ms". STATE is COLD/WARM/HOT, or UNKNOWN when
# the screen was off / the activity was already on top.
launch() {
    local out
    out=$(sh am start -W -n "$1" 2>&1)
    local state total
    state=$(echo "$out" | sed -n 's/^LaunchState: \([A-Z]*\).*/\1/p' | head -1)
    total=$(echo "$out" | sed -n 's/^TotalTime: \([0-9]*\).*/\1/p' | head -1)
    [ -z "$total" ] && total=$(echo "$out" | sed -n 's/^WaitTime: \([0-9]*\).*/\1/p' | head -1)
    echo "${state:-ERR} ${total:--1}"
}

# Exact process-name match: pidof would also return the app's :sub processes.
pid_of() { sh ps -A -o PID,NAME | awk -v n="$1" '$2==n {print $1; exit}'; }
