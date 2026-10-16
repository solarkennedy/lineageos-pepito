#!/bin/bash
# mglru-bench/vmstat-delta.sh — reclaim counters over a window.
#
#   vmstat-delta.sh snap <file>          write a snapshot (see lib.sh snapshot)
#   vmstat-delta.sh diff <before> <after>  print deltas and derived ratios
#   vmstat-delta.sh watch <tag> <secs>    snap, sleep, snap, diff (idle-window check)
#
# Unit: ${PEPITO_ADB:-dut1-adb}.
. "$(dirname "$0")/lib.sh"

diff_snaps() {
    awk '
    FNR==NR { a[$1]=$2; next }
    { b[$1]=$2 }
    END {
        dt = b["uptime_s"] - a["uptime_s"]; if (dt <= 0) dt = 1
        printf "window_s %d\n", dt
        n = split("pgscan_kswapd pgscan_direct pgsteal_kswapd pgsteal_direct allocstall_normal allocstall_movable workingset_refault workingset_activate workingset_restore pswpin pswpout pgmajfault pgfault oom_kill compact_stall kswapd_low_wmark_hit_quickly kswapd_high_wmark_hit_quickly lmk_kills", k, " ")
        for (i = 1; i <= n; i++) { d[k[i]] = b[k[i]] - a[k[i]]; printf "%-32s %12d\n", k[i], d[k[i]] }
        printf "%-32s %12.2f s\n", "psi_some_stall", (b["psi_some_us"] - a["psi_some_us"]) / 1e6
        printf "%-32s %12.2f s\n", "psi_full_stall", (b["psi_full_us"] - a["psi_full_us"]) / 1e6
        printf "%-32s %12.2f s\n", "kswapd_cpu", (b["kswapd_run_ns"] - a["kswapd_run_ns"]) / 1e9
        scan = d["pgscan_kswapd"] + d["pgscan_direct"]
        steal = d["pgsteal_kswapd"] + d["pgsteal_direct"]
        printf "%-32s %12.1f MB\n", "scanned", scan * 4 / 1024
        printf "%-32s %12.1f MB\n", "reclaimed", steal * 4 / 1024
        if (scan > 0) printf "%-32s %12.3f\n", "steal_per_scan", steal / scan
        if (steal > 0) printf "%-32s %12.3f\n", "refault_per_steal", d["workingset_refault"] / steal
        if (steal > 0) printf "%-32s %12.3f\n", "direct_share", d["pgsteal_direct"] / steal
        printf "%-32s %12.1f MB\n", "swapped_out", d["pswpout"] * 4 / 1024
        printf "%-32s %12.1f MB\n", "swapped_in", d["pswpin"] * 4 / 1024
        printf "%-32s %s -> %s\n", "lru_gen", a["lru_gen"], b["lru_gen"]
        printf "%-32s %s -> %s kB\n", "MemAvailable", a["MemAvailable"], b["MemAvailable"]
        printf "%-32s %s -> %s kB\n", "SwapFree", a["SwapFree"], b["SwapFree"]
    }' "$1" "$2"
}

case "${1:-}" in
snap)  snapshot > "${2:?file}";;
diff)  diff_snaps "${2:?before}" "${3:?after}";;
watch)
    tag=${2:?tag}; secs=${3:?secs}
    bench_init "watch-$tag" >/dev/null
    snapshot > "$RUN/before.snap"; sleep "$secs"; snapshot > "$RUN/after.snap"
    diff_snaps "$RUN/before.snap" "$RUN/after.snap" | tee "$RUN/delta.txt"
    echo "results: $RUN";;
*) sed -n '2,8p' "$0"; exit 2;;
esac
