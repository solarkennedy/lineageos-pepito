#!/bin/bash
# mglru-bench/lmk-props.sh — flip lmkd tunables at runtime (PLAN-mglru §2).
#
#   lmk-props.sh show                       current overrides + the effective defaults
#   lmk-props.sh set name=value [...]       e.g. set lowmem_min_oom_score=1001 swap_free_low_percentage=5
#   lmk-props.sh clear                      back to the ro.lmk / built-in defaults
#   lmk-props.sh ab TAG CELLS ITER          interleaved hog-resume cells, e.g. `ab lmk "A B A B" 3`
#                                           cells are named in CELL_<name> variables below
#
# lmkd reads persist.device_config.lmkd_native.<name> over ro.lmk.<name> (GET_LMK_PROPERTY),
# and `setprop lmkd.reinit 1` makes it re-read (lmkd.rc runs `lmkd --reinit`). Nothing
# here survives a factory reset, but the persist props DO survive a reboot: run `clear`
# when done. Unit: ${PEPITO_ADB:-dut1-adb}, needs root.
. "$(dirname "$0")/lib.sh"

P=persist.device_config.lmkd_native
KNOBS="lowmem_min_oom_score swap_compression_ratio swap_compression_ratio_div relaxed_available_memory swap_free_low_percentage thrashing_limit thrashing_limit_critical thrashing_limit_decay psi_partial_stall_ms psi_complete_stall_ms swap_util_max filecache_min_kb direct_reclaim_threshold_ms kill_heaviest_task use_minfree_levels"

# A17 lmkd.cpp defaults (non-low-ram): lowmem_min_oom_score 701, swap_free_low_percentage 10,
# thrashing_limit 100, thrashing_limit_critical 300, thrashing_limit_decay 10,
# psi_partial_stall_ms 70, psi_complete_stall_ms 700, swap_util_max 100, filecache_min_kb 0.
CELL_A=""                                    # AOSP defaults
CELL_B="lowmem_min_oom_score=1001"           # no cached-app kills on a bare watermark breach
CELL_C="lowmem_min_oom_score=1001 swap_free_low_percentage=5"
CELL_D="swap_free_low_percentage=5"
CELL_E="swap_compression_ratio=3"               # lz4 measures 3.2:1 here; default 1 makes "free swap" = free RAM
CELL_F="swap_compression_ratio=3 lowmem_min_oom_score=1001"
CELL_G="swap_compression_ratio=3 lowmem_min_oom_score=1001 relaxed_available_memory=true"

reinit() {
    sh setprop lmkd.reinit 1; sleep 2
    sh logcat -d -s lowmemorykiller:* | tail -50 | grep -q "updated properties successfully" || echo "WARN: no reinit ack in logcat" >&2
}
clear_all() { for k in $KNOBS; do sh setprop $P.$k '""'; done; }
set_kv()    { for kv in "$@"; do sh setprop $P.${kv%%=*} "${kv#*=}"; done; }

case "${1:-}" in
show)
    $ADB root >/dev/null 2>&1; sleep 1
    sh getprop | grep -E "lmkd_native|ro\.lmk\." || echo "(no overrides, no ro.lmk props)";;
set)   shift; $ADB root >/dev/null 2>&1; sleep 1; set_kv "$@"; reinit; sh getprop | grep lmkd_native;;
clear) $ADB root >/dev/null 2>&1; sleep 1; clear_all; reinit; echo cleared;;
ab)
    tag=${2:?tag}; cells=${3:?cells}; iter=${4:-3}
    # One bench per unit: two concurrent runs (10-15) doubled the hog and raced the props.
    exec 9> "$RESULTS/.lock-$NICK"
    flock -n 9 || { echo "another bench is running on $NICK (lock $RESULTS/.lock-$NICK)" >&2; exit 1; }
    $ADB root >/dev/null 2>&1; sleep 1
    n=0
    for c in $cells; do
        n=$((n + 1)); v="CELL_$c"
        echo "=== cell $c #$n: ${!v:-defaults}"
        clear_all; [ -n "${!v}" ] && set_kv ${!v}; reinit
        sleep 60
        "$HERE/hog-resume.sh" -n "$iter" -t "$tag-$c$n" | grep -E "^[0-9]+,|lmk_kills|== summary|survived"
    done
    clear_all; reinit; echo "=== overrides cleared";;
*) sed -n '2,9p' "$0"; exit 2;;
esac
