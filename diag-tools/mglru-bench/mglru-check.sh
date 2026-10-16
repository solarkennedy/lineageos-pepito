#!/bin/bash
# mglru-bench/mglru-check.sh — post-flash checks for the MGLRU kernel (PLAN-mglru Phase 1).
#
#   mglru-check.sh status        kernel, lru_gen state/caps, generation dump, kill-switch sanity
#   mglru-check.sh health        BUG/WARN/Bad page in dmesg + pstore (run any time during the soak)
#   mglru-check.sh flip [N]      toggle /sys/kernel/mm/lru_gen/enabled N times (default 20) under
#                                an app-cycle load, with a health check after each flip
#   mglru-check.sh walk SECS     force MM_WALK on (0x0003) for SECS, then back to the default
#
# Unit: ${PEPITO_ADB:-dut1-adb}, needs root. Never reboots or flashes.
. "$(dirname "$0")/lib.sh"

LG=/sys/kernel/mm/lru_gen
mount_dbg() { sh 'mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug' 2>/dev/null; }

health() {
    local bad
    # Known-benign on this kernel: the boot gic_irq_domain_alloc WARN (irq-gic.c:1008) and, with
    # DEBUG_VM, lru_gen_use_mm's VM_WARN_ON(list_empty) racing lru_gen_migrate_mm (mm_types.h:591,
    # documented "not a bug" in the v10 series; upstream later removed the check).
    bad=$(sh 'dmesg | grep -E "BUG:|WARNING:|Bad page|list_del corruption|kernel BUG at|VM_BUG_ON|page dumped" | grep -v -c -E "irq-gic.c:1008|mm_types.h:591"')
    echo "dmesg BUG/WARN/Bad-page lines (excl. known-benign): $bad   benign: gic=$(sh 'dmesg | grep -c irq-gic.c:1008') use_mm=$(sh 'dmesg | grep -c mm_types.h:591')"
    [ "$bad" != "0" ] && sh 'dmesg | grep -E -A3 "BUG:|WARNING:|Bad page|list_del corruption|kernel BUG at|page dumped" | grep -v -E "irq-gic.c:1008|mm_types.h:591" | head -40'
    echo "pstore: $(sh 'ls /sys/fs/pstore 2>/dev/null | tr "\n" " "')"
    sh 'grep -l "BUG\|panic" /sys/fs/pstore/* 2>/dev/null' | sed 's/^/   HIT: /'
    [ "$bad" = "0" ]
}

case "${1:-status}" in
status)
    $ADB root >/dev/null 2>&1; sleep 1
    echo "serial $(sh getprop ro.serialno) kernel $(sh uname -r) uptime $(sh cut -d. -f1 /proc/uptime)s"
    echo "LRU_GEN in config: $(sh 'zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_(LRU_GEN|LRU_GEN_ENABLED|LRU_GEN_STATS|DEBUG_VM|PAGE_OWNER)=" | tr "\n" " "')"
    echo "lru_gen/enabled: $(sh "cat $LG/enabled 2>&1")   min_ttl_ms: $(sh "cat $LG/min_ttl_ms 2>&1")"
    echo "persist.gotweak.mglru: $(sh getprop persist.gotweak.mglru)"
    mount_dbg
    echo "debugfs lru_gen (first 12 lines):"; sh 'head -12 /sys/kernel/debug/lru_gen 2>&1' | sed 's/^/   /'
    echo "hw_af (CPU Features): $(sh 'grep -m1 Features /proc/cpuinfo' | grep -o hwaf || echo none)"
    echo "vmstat: $(sh 'grep -E "^(workingset_refault|pgsteal_kswapd|pgsteal_direct|oom_kill) " /proc/vmstat' | tr '\n' ' ')"
    health;;
health)
    $ADB root >/dev/null 2>&1; sleep 1; health;;
flip)
    n=${2:-20}
    $ADB root >/dev/null 2>&1; sleep 1
    orig=$(sh "cat $LG/enabled")
    echo "flipping $n times (orig $orig) under app-cycle load"
    "$HERE/app-cycle.sh" -r 50 -d 1 -t flipload >/dev/null 2>&1 &
    LOADPID=$!
    sleep 10
    for i in $(seq 1 "$n"); do
        v=n; [ $((i % 2)) -eq 0 ] && v=y
        sh "echo $v > $LG/enabled"; sleep 6
        echo "flip $i -> $(sh "cat $LG/enabled")"
        health >/dev/null || { echo "!! health failed after flip $i"; health; break; }
    done
    kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null
    sh "echo $orig > $LG/enabled"; echo "restored $(sh "cat $LG/enabled")"; health;;
walk)
    # A53 has no hardware Accessed flag, so kswapd aging never walks page tables
    # (try_to_inc_max_seq: !full_scan && !arch_has_hw_pte_young() -> rmap only).
    # A forced full scan from debugfs ("+ memcg node max_gen can_swap full_scan=1")
    # bypasses that gate and runs walk_mm(); this is the only way to exercise the
    # page-table-walk code on this SoC.
    secs=${2:?secs}
    $ADB root >/dev/null 2>&1; sleep 1; mount_dbg
    end=$(( $(date +%s) + secs )); n=0
    "$HERE/app-cycle.sh" -r 50 -d 1 -t walkload >/dev/null 2>&1 &
    LOADPID=$!
    echo "forcing full-scan aging on every memcg for ${secs}s under app-cycle load"
    while [ "$(date +%s)" -lt "$end" ]; do
        # Field-based parse: this kernel prints "memcg <id> <path>", " node <n>" and generation
        # rows as "<gen> <age_ms> <anon> <file>" with variable indentation (a whitespace-anchored
        # version on 10-15 matched nothing and the first "walk" run issued zero scans).
        # The last gen row of node 0 is max_seq; "+ memcg 0 max_seq 1 1" ages it by one with
        # full_scan=1. Every accepted write bumps max_seq, so root's gen should climb ~1/iteration.
        sh 'awk "\$1==\"memcg\" {m=\$2} \$1==\"node\" {nd=\$2} \$1 ~ /^[0-9]+\$/ && NF==4 {if (nd==0) mx[m]=\$1} END {for (m in mx) print \"+ \" m \" 0 \" mx[m] \" 1 1\"}" /sys/kernel/debug/lru_gen | while read -r l; do echo "$l" > /sys/kernel/debug/lru_gen; done'
        n=$((n + 1)); sleep 3
        [ "$n" = 2 ] && echo "root max gen after 2 iterations: $(sh 'awk "\$1==\"memcg\" {m=\$2} \$1==\"node\" {nd=\$2} \$1 ~ /^[0-9]+\$/ && NF==4 && m==1 && nd==0 {mx=\$1} END {print mx}" /sys/kernel/debug/lru_gen')"
        if [ $((n % 20)) -eq 0 ]; then echo "$n scans, $(( end - $(date +%s) ))s left"; health >/dev/null || { echo "!! health failed after scan $n"; health; break; }; fi
    done
    kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null
    echo "$n forced scans"; sh 'head -8 /sys/kernel/debug/lru_gen' | sed 's/^/   /'; health;;
*) sed -n '2,10p' "$0"; exit 2;;
esac
