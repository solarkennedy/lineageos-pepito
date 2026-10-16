#!/bin/bash
# mglru-bench/hog-resume.sh — the zram lane's anon hog, then resume a few apps.
#
#   hog-resume.sh [-n ITER] [-m HOG_MB] [-t TAG] [app/activity ...]
#
# Per iteration: warm the apps (launch each, go home), settle, snapshot, run
# `head -c (HOG+100)m /dev/zero | tail -c HOGm` on the device (tail's ring buffer is
# real anon memory; lmkd/kswapd/swap do their thing), then launch each app again and
# record whether its process survived, the LaunchState (HOT/WARM/COLD) and TotalTime.
# Default HOG_MB=1200 is what the 2026-08-22 zram A/B used.
#
# Output: results/<stamp>-<tag>/{meta.txt,resume.csv,iter<N>.{before,after}.snap,
# iter<N>.delta.txt,killlog.*}. resume.csv: iter,app,survived,state,total_ms,hog_s.
#
# Unit: ${PEPITO_ADB:-dut1-adb}. Do not run while another session captures on the unit.
. "$(dirname "$0")/lib.sh"

ITER=3; HOG=1200; TAG=hog
while getopts n:m:t: o; do case $o in n) ITER=$OPTARG;; m) HOG=$OPTARG;; t) TAG=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND - 1))
APPS=("$@"); [ ${#APPS[@]} -gt 0 ] || APPS=(
    com.android.settings/.Settings
    com.google.android.apps.messaging/.ui.ConversationListActivity
    org.lineageos.jelly/.MainActivity
    org.lineageos.aperture/.CameraLauncher
)

bench_init "$TAG" -n "$ITER" -m "$HOG" "${APPS[@]}"
bench_awake
CSV=$RUN/resume.csv
echo "iter,app,survived,state,total_ms,hog_s" > "$CSV"

for it in $(seq 1 "$ITER"); do
    echo "== iter $it: warming ${#APPS[@]} apps"
    for a in "${APPS[@]}"; do launch "$a" >/dev/null; sleep 3; sh input keyevent KEYCODE_HOME; sleep 1; done
    sleep 15
    declare -A PID=()
    for a in "${APPS[@]}"; do PID[$a]=$(pid_of "$(pkg_of "$a")"); done
    snapshot > "$RUN/iter$it.before.snap"
    killlog_start "iter$it"

    echo "== iter $it: hog ${HOG} MB"
    t0=$(date +%s)
    sh "head -c $((HOG + 100))m /dev/zero | tail -c ${HOG}m > /dev/null"
    hog_s=$(( $(date +%s) - t0 ))
    # lmkd's "swap is low" sweep keeps killing for ~10 s after the hog exits;
    # launching into that reads as LaunchState UNKNOWN.
    sleep 20

    for a in "${APPS[@]}"; do
        p=$(pid_of "$(pkg_of "$a")")
        surv=0; [ -n "$p" ] && [ "$p" = "${PID[$a]}" ] && surv=1
        read -r state total <<<"$(launch "$a")"
        echo "$it,$a,$surv,$state,$total,$hog_s" | tee -a "$CSV"
        sleep 3; sh input keyevent KEYCODE_HOME; sleep 1
    done

    killlog_stop "iter$it"
    snapshot > "$RUN/iter$it.after.snap"
    "$HERE/vmstat-delta.sh" diff "$RUN/iter$it.before.snap" "$RUN/iter$it.after.snap" > "$RUN/iter$it.delta.txt"
    grep -E "lmk_kills|psi_full|swapped_out|refault_per|direct_share" "$RUN/iter$it.delta.txt"
    sleep 20
done
bench_done

echo "== summary ($RUN)"
awk -F, 'NR>1 { n[$2]++; s[$2]+=$3; t[$2]+=$5; if ($4=="COLD") c[$2]++ }
    END { for (a in n) printf "%-70s survived %d/%d  cold %d  mean %d ms\n", a, s[a], n[a], c[a]+0, t[a]/n[a] }' "$CSV"
