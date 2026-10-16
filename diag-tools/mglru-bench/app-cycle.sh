#!/bin/bash
# mglru-bench/app-cycle.sh — round-robin app launches; count cold vs warm starts.
#
#   app-cycle.sh [-r ROUNDS] [-d DWELL_S] [-t TAG] [app/activity ...]
#
# Launches each app in turn (default: the 15 in lib.sh DEFAULT_APPS), dwells, goes
# home, for ROUNDS rounds. Round 1 primes the set and is reported separately; the
# claim under test is how many of rounds 2..N come back COLD (process was killed)
# vs WARM/HOT. Snapshots before/after give the reclaim counters for the whole run.
#
# Output: results/<stamp>-<tag>/{meta.txt,cycle.csv,before.snap,after.snap,delta.txt,
# killlog.*}. cycle.csv: round,idx,app,state,total_ms.
#
# Unit: ${PEPITO_ADB:-dut1-adb}. Do not run while another session captures on the unit.
. "$(dirname "$0")/lib.sh"

ROUNDS=4; DWELL=3; TAG=cycle
while getopts r:d:t: o; do case $o in r) ROUNDS=$OPTARG;; d) DWELL=$OPTARG;; t) TAG=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND - 1))
APPS=("$@"); [ ${#APPS[@]} -gt 0 ] || APPS=("${DEFAULT_APPS[@]}")

bench_init "$TAG" -r "$ROUNDS" -d "$DWELL" "${APPS[@]}"
bench_awake
CSV=$RUN/cycle.csv
echo "round,idx,app,state,total_ms" > "$CSV"
snapshot > "$RUN/before.snap"
killlog_start cycle

for r in $(seq 1 "$ROUNDS"); do
    i=0
    for a in "${APPS[@]}"; do
        i=$((i + 1))
        read -r state total <<<"$(launch "$a")"
        echo "$r,$i,$a,$state,$total" >> "$CSV"
        sleep "$DWELL"; sh input keyevent KEYCODE_HOME; sleep 1
    done
    awk -F, -v r="$r" '$1==r { n++; if ($4=="COLD") c++; t+=$5 } END { printf "round %d: %d launches, %d cold, mean %d ms\n", r, n, c, t/n }' "$CSV"
done

killlog_stop cycle
snapshot > "$RUN/after.snap"
bench_done
"$HERE/vmstat-delta.sh" diff "$RUN/before.snap" "$RUN/after.snap" > "$RUN/delta.txt"

echo "== summary ($RUN)"
awk -F, 'NR>1 && $1>1 { n++; st[$4]++; t[$4]+=$5 }
    END { for (s in st) printf "%-8s %3d  mean %5d ms\n", s, st[s], t[s]/st[s]; printf "cold rate (rounds 2+): %d/%d\n", st["COLD"]+0, n }' "$CSV"
grep -E "lmk_kills|psi_full|kswapd_cpu|refault_per|direct_share|swapped_out" "$RUN/delta.txt"
