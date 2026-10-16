#!/bin/bash
# mglru-bench/mglru-ab.sh — PLAN-mglru Phase 2: MGLRU on vs off, same boot, interleaved.
#
#   mglru-ab.sh run TAG [BLOCKS]     BLOCKS (default 5) pairs of cells; the arm order alternates
#                                    per block (on,off / off,on / ...) to cancel drift. Each cell:
#                                    write /sys/kernel/mm/lru_gen/enabled, settle 120 s, then
#                                    hog-resume.sh -n 3 and app-cycle.sh -r 3 -d 2.
#   mglru-ab.sh report TAG           aggregate every results/*-TAG-<arm><n> dir per arm.
#
# Measures (per arm): lmkd kills per hog, resumed-app survival, resume TotalTime, memory PSI full
# stall, app-cycle cold rate and mean launch time, refaults per steal, direct-reclaim share.
# hog iteration 1 of each cell follows the 120 s idle settle and is the known post-idle outlier
# (README); `report` drops it. Unit: ${PEPITO_ADB:-dut1-adb}, needs root. Same boot throughout:
# the kill switch is a sysfs write, nothing is rebooted or flashed. Holds results/.lock-<nick>.
. "$(dirname "$0")/lib.sh"

LG=/sys/kernel/mm/lru_gen/enabled
set_arm() { sh "echo $1 > $LG"; sh "cat $LG"; }

case "${1:-}" in
run)
    tag=${2:?tag}; blocks=${3:-5}
    exec 9> "$RESULTS/.lock-$NICK"
    flock -n 9 || { echo "another bench is running on $NICK" >&2; exit 1; }
    $ADB root >/dev/null 2>&1; sleep 1
    orig=$(sh "cat $LG")
    echo "=== $tag: $blocks blocks, orig enabled=$orig, kernel $(sh uname -r)"
    sh 'getprop | grep -E "ro\.lmk\."' | tr -d '\r' | sed 's/^/    /'
    n=0
    for b in $(seq 1 "$blocks"); do
        order="on off"; [ $((b % 2)) -eq 0 ] && order="off on"
        for arm in $order; do
            n=$((n + 1)); v=y; [ "$arm" = off ] && v=n
            echo "=== cell $n block $b arm $arm ($(date +%H:%M)) enabled -> $(set_arm $v)"
            sleep 120
            "$HERE/hog-resume.sh" -n 3 -t "$tag-$arm$n" | grep -E "^[0-9]+,|lmk_kills|psi_full|== summary|survived"
            "$HERE/app-cycle.sh" -r 3 -d 2 -t "$tag-$arm$n" | grep -E "^round|cold rate|lmk_kills|psi_full|== summary"
        done
    done
    set_arm "$orig" >/dev/null; echo "=== restored enabled=$(sh "cat $LG")"
    "$0" report "$tag";;
report)
    tag=${2:?tag}
    for arm in on off; do
        dirs=$(ls -d "$RESULTS"/*-"$tag-$arm"[0-9]* 2>/dev/null)
        [ -z "$dirs" ] && { echo "== $arm: no runs"; continue; }
        echo "== arm $arm: $(echo "$dirs" | wc -l) cell dirs"
        # hog-resume: iterations 2+ only
        cat $(for d in $dirs; do [ -f "$d/resume.csv" ] && echo "$d/resume.csv"; done) 2>/dev/null \
            | awk -F, '$1 ~ /^[0-9]+$/ && $1 >= 2 { n[$2]++; s[$2]+=$3; if ($4=="COLD") c[$2]++; t[$2]+=$5; N++; S+=$3; T+=$5 }
                       END { for (a in n) printf "   %-45s survived %2d/%-2d cold %2d mean %5d ms\n", a, s[a], n[a], c[a]+0, t[a]/n[a];
                             if (N) printf "   ALL APPS: survived %d/%d (%.0f%%), mean resume %d ms\n", S, N, 100*S/N, T/N }'
        for k in lmk_kills psi_full_stall swapped_out refault_per_steal direct_share; do
            cat $(for d in $dirs; do ls "$d"/iter[2-9].delta.txt 2>/dev/null; done) 2>/dev/null \
                | awk -v k="$k" '$1==k { n++; s+=$2 } END { if (n) printf "   hog %-18s mean %8.2f over %d hogs\n", k, s/n, n }'
        done
        # app-cycle: rounds 2+
        cat $(for d in $dirs; do [ -f "$d/cycle.csv" ] && echo "$d/cycle.csv"; done) 2>/dev/null \
            | awk -F, '$1 ~ /^[0-9]+$/ && $1 >= 2 { n++; if ($4=="COLD") c++; t+=$5 } END { if (n) printf "   app-cycle: cold %d/%d (%.1f%%), mean launch %d ms\n", c, n, 100*c/n, t/n }'
        for k in lmk_kills psi_full_stall kswapd_cpu refault_per_steal direct_share; do
            cat $(for d in $dirs; do [ -f "$d/delta.txt" ] && echo "$d/delta.txt"; done) 2>/dev/null \
                | awk -v k="$k" '$1==k { n++; s+=$2 } END { if (n) printf "   cycle %-16s mean %8.2f over %d runs\n", k, s/n, n }'
        done
    done;;
*) sed -n '2,15p' "$0"; exit 2;;
esac
