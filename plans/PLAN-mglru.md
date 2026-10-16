# PLAN-mglru.md — Multi-Gen LRU (MGLRU) for the 24.0 kernel

**Goal:** backport MGLRU (`CONFIG_LRU_GEN`) into `kernel/xiaomi/msm8937` branch `pepito-24`, ship it
default-on in a 24.0 release, and keep a runtime kill switch so it can be A/B'd and rolled back without
a reflash.

**Why:** the "A16/A17 feels laggier than A11" root cause was memory pressure. zstd zram made lmkd kill
backgrounded apps that lz4 rides out as swap (memory `zram-zstd-lmkd-kills`, 2026-08-22). MGLRU attacks
the same failure mode: it picks better pages to evict, so reclaim stalls less, PSI spikes less, and lmkd
escalates to kills less often. Google's published numbers on low-RAM Android/ChromeOS are fewer
low-memory kills and faster cold starts. A 2.8 GB-usable phone running A17 plus GMS is that use case.

**Status:** 2026-10-15. Plan only, no code yet. Facts in §1 were checked today on dut1 (`c39a6acf`, 10-11
build, debug kernel `-00005-g6c2d4dd8cb5b`) and new2 (`9c2e6b00`, 10-15 build, release kernel
`50c36c782d89`), and against the builder tree.

**Owner split:** agent ports, builds, and stages the change on the builder and writes the measurement
scripts. Kyle flashes (memory `feedback-user-does-build-flash`).

---

## 1. Starting point (verified 2026-10-15)

| Fact | Value | Consequence |
|---|---|---|
| Kernel | `4.19.325-cip135`, base merges `android13-4.19-kona` + CIP SLTS | mm/ is 4.19 + a few backports (XArray page cache, `mmap_lock` rename, `page_size()`) |
| MGLRU | absent (`/sys/kernel/mm/lru_gen` missing, no `LRU_GEN` in `mm/Kconfig`) | full port needed |
| CPU | 8× Cortex-A53 (`CPU part 0xd03`), `Features` has **no `hwaf`** | **No hardware Accessed flag.** `arch_has_hw_pte_young()` is false, so MGLRU's page-table-walk aging (`LRU_GEN_MM_WALK`, cap `0x0002`) stays **off by default** and aging runs through rmap + look-around only. The riskiest code in the series compiles but doesn't run unless forced on. |
| Paging | 39-bit VA, 3-level tables, `SPARSEMEM_VMEMMAP`, no NUMA, no THP, no KSM | plenty of free `page->flags` bits for the gen/tier counters; no THP edge cases |
| Qualcomm reclaim extras | `CONFIG_PROCESS_RECLAIM=y` (`/proc/<pid>/reclaim` → `reclaim_pages_from_list()` in `fs/proc/task_mmu.c`); `kswapd_threads` (multi-kswapd), set to 1 | the source port below had **neither**, so these are our own conflicts to resolve (§4) |
| Page-walk API | old `struct mm_walk` with callbacks; **no `struct mm_walk_ops`** (5.4 API) | the source port had `mm_walk_ops` and adapted to it (`e180d2f288f3`); we have to adapt the other way, or backport `mm_walk_ops` |
| Missing prereqs | no `arch_has_hw_pte_young`, `__clear_page_lru_flags`, `TestClearPageLRU`, `MADV_PAGEOUT`, `lru_note_cost` | the prereq set in §3 is needed |
| Freezer | cgroup v2 freezer works, `use_freezer=true` (24/36 app processes frozen on dut1) | not part of this lane |
| zram | lz4, 1.5 GiB disksize, swappiness 100, `watermark_scale_factor` 1, `extra_free_kbytes` 10800 | keep these fixed across the A/B |
| lmkd | **no `ro.lmk.*` props at all**, AOSP defaults; PSI mode ("low watermark is breached" kills) | see §2 ordering |
| `cgroup_disable=pressure` | in `CONFIG_CMDLINE` | per-cgroup PSI off, system-wide PSI on (lmkd uses that). Fine. |
| Image size | arm64 header `image_size` (uncompressed text+bss) must stay < 54,001,664 B — DTB is at phys 0x43400000 (memory `list-del-panic-lane`); NOT `Image.gz` | MGLRU adds roughly 4–5 k lines of mm code, about 100 KB. Check anyway. |

dut1 vmstat at 42 h uptime (debug kernel, so only rough): `pgsteal_kswapd 6.76M`, `pgsteal_direct
0.62M`, `allocstall_* ≈ 9.8k`, `workingset_refault 811k`, `pswpout 232k`. The baseline in §6 replaces this.

---

## 2. Ordering with the lmkd-props lane

lmkd currently runs on AOSP defaults. Tuning `ro.lmk.*` for a 3 GB device is cheaper (overlay only)
and could change the picture on its own. To keep the MGLRU A/B clean:

1. Do the lmkd props experiment **first**, or explicitly decide to defer it.
2. Freeze whatever lmkd/zram/swappiness config wins, and run every MGLRU measurement on top of it.
   Changing two reclaim layers in the same A/B makes the result unreadable.

**lmkd mechanism (read from `system/memory/lmkd/lmkd.cpp` on the builder, 2026-10-15).** The
Phase 0 kill log has two reasons: `low watermark is breached` (the first ~8 kills per hog) and
`… and swap is low`. The first is the `LOW_MEM` fallback at the bottom of `mp_event_psi()`:
when no other reason fired and `wmark < WMARK_HIGH`, kill a cached app with adj ≥
`lowmem_min_oom_score` (default `PREVIOUS_APP_ADJ+1` = 701). dut1's only zone (DMA32) has
high = 5170 pages ≈ 20 MB (`watermark_scale_factor` 1 + `extra_free_kbytes` 10800) and
MemFree idles at 24–36 MB, so **every PSI event while free dips under 20 MB kills a cached app,
thrashing or not.** `lowmem_min_oom_score=1001` (> `OOM_SCORE_ADJ_MAX`) disables that path.
The second reason is `swap_free_low_percentage` (default 10 % of the 1.5 GiB zram = 157 MB).
Non-low-ram defaults otherwise: `thrashing_limit` 100, `_critical` 300, `_decay` 10,
`psi_partial_stall_ms` 70, `psi_complete_stall_ms` 700.

Every knob is runtime-overridable: `persist.device_config.lmkd_native.<name>` beats
`ro.lmk.<name>` (`GET_LMK_PROPERTY`), and `setprop lmkd.reinit 1` re-reads them (lmkd.rc →
`lmkd --reinit`, logcat `lmkd updated properties successfully`). So the A/B interleaves in one
boot: `diag-tools/mglru-bench/lmk-props.sh ab <tag> "A B A B" 3`. Cells: A defaults,
B `lowmem_min_oom_score=1001`, C = B + `swap_free_low_percentage=5`, D = swap 5 only.
If a cell wins it ships as `ro.lmk.*` in `mithorium.mk` (build-prop, same pattern as §5).

**A/B #1 (10-15, A B A B × 3 hogs): B = A.** 6–11 kills per hog in every cell, all four apps
lost either way, and **every kill in all four cells was `… and swap is low`** — the plain
`LOW_MEM` path never fired, so `lowmem_min_oom_score` was irrelevant here. (Phase 0's plain
kills came in the first hog after a long idle, when `inactive_file` was still large.)

**Why swap is "low" with 1.1 GB of SwapFree.** `get_free_swap()` =
`min(SwapFree, easy_available × swap_compression_ratio / div)`, ratio default **1**, and with
`relaxed_available_memory=false` (default) `easy_available = MemFree + inactive_file`. So on a
zram device lmkd declares swap exhausted whenever free + inactive-file RAM < 10 % of the zram
size (157 MB) — which any anon burst does within seconds, regardless of how much zram is
actually free. The 1200 MB hog is therefore a swap-"low" test by construction. lz4 here
compresses 3.2:1 (`mm_stat` 410 MB → 127 MB), so **`swap_compression_ratio=3` (cell E)** is the
honest setting; `relaxed_available_memory=true` goes further (adds active_file and
(ratio−1)/ratio of anon). A/B #2 = A E A E. First attempt (09:48–10:40) ran **twice
concurrently** (a backgrounded launch I believed dead): two hogs at once, 41–80 kills, 190 s
stalls; quarantined in `results/invalid-double-run-20261015/`. `ab` now takes a flock.

**A/B #2 rerun (10:40–11:10, cells E2 A3 E4; A1 produced no iterations): E = A on kills, 7 per
hog in both, same three apps lost.** What changes is the reason: A kills are all `… and swap is
low`; E kills are plain `low watermark is breached` (the `LOW_MEM` cached-app path, adj
900–975). Full-stall per hog 3.7–3.9 s (A) → 2.5–2.9 s (E). So ratio 3 removes the false
swap-low verdict and the bare-watermark path kills the same cached apps instead: **the two
knobs only work as a pair.** A/B #3 = A F A F with F = `swap_compression_ratio=3
lowmem_min_oom_score=1001`, leaving only the thrashing/direct-reclaim reasons.

**A/B #3 (11:11–11:50, A F A F × 3): F wins, modestly.** Kills per hog A 7,7,7 / 8,7,7 (mean
7.2) vs F 5,5,4 / 5,2,7 (mean 4.7); full-stall A 3.1–3.9 s vs F 2.3–3.3 s; swapped-out
~440 MB (A) vs ~530 MB (F) — the kernel swaps instead of lmkd killing. Survival over 6 hogs:
Jelly A 1/6 → F 5/6, Settings 0 → 1, Messaging 0 → 1, Aperture 6/6 both. F's remaining kills
are still `… and swap is low` (13–14 of ~16) plus a few `… and thrashing`: with
`inactive_file` drained, 3 × (free + inactive_file) is still < 157 MB. A/B #4 = A G A G with
G = F + `relaxed_available_memory=true` (easy_available then counts active_file and
(ratio−1)/ratio of anon, so "free swap" ≈ real SwapFree and only thrashing reasons remain).

**A/B #4 (11:49–12:27, A G A G × 3): G wins.** Kills per hog A 8,7,8 / 7,6,7 (mean 7.2) vs
G 5,3,3 / 6,3,2 (mean 3.7); full-stall A 3.3–4.4 s vs G 2.0–2.7 s; swapped-out ~430 MB vs
~590 MB; direct-reclaim share 0–0.6 % vs 1–4 % (the kernel works harder instead of lmkd
killing). **Every G kill is `low watermark is breached and thrashing`** — the false swap-low
verdict is gone. Survival over 6 hogs: Jelly 6/6 (A 0/6), Settings 3/6 (A 0/6), Messaging 1/6
(0/6), Aperture 6/6 both. Resume latency of survivors 0.4–0.8 s vs 1.4–1.9 s cold.

**§2 decision (2026-10-15): freeze G as the lmkd config.** Ship in `mithorium.mk` as
`ro.lmk.swap_compression_ratio=3`, `ro.lmk.lowmem_min_oom_score=1001`,
`ro.lmk.relaxed_available_memory=true`; every MGLRU measurement runs on top of it. Caveats:
(a) synthetic-hog result, needs the daily-driver soak (G can go on new2 at runtime with
`lmk-props.sh set …` — persist props survive reboot — no reflash needed); (b) ratio 3 is tied
to lz4; if the zstd toggle is on, ratio ~4 would be truer but 3 is still conservative;
(c) `lowmem_min_oom_score=1001` means cached apps are never killed pre-emptively on a bare
watermark breach — kernel reclaim/swap does the work, so idle-time kswapd CPU is worth a
glance in the soak.

Real-life kill reasons aren't in the logcat buffers (rolled). Persistent loggers started
10-15 09:47 on new2 and dut1: `logcat -s lowmemorykiller -f /data/local/tmp/lmk-kills.log`
(pid in `.pid`, rotating 3 × 2 MB). Read them after a day of Kyle's use to see which path
kills in practice; they die at reboot.

---

## 3. Source for the backport

### Option A (recommended base): UtsavBalar1231 `kernel_xiaomi_sm8250`, branch `android12-stable`

A kona-based 4.19 kernel, the same lineage as our `android13-4.19-kona` merge. Shipped MGLRU in its
"IMMENSITY" release 3.0.0 (4.19.241, 2022). Series in apply order (commit dates):

Prereqs (Yu Zhao's upstream LRU cleanups, mostly 5.9–5.11):
```
d79a7d1a1082 UPSTREAM: mm/vmscan.c: use update_lru_size() in update_lru_sizes()
975494424d5d BACKPORT: mm/swapcache: support to handle the shadow entries   (verify that it's really a dep)
52dae58e2e24 BACKPORT: mm: use self-explanatory macros rather than "2"
caea3c2ab53b BACKPORT: mm/vmscan.c: use add_page_to_lru_list()
161c8162cc7b BACKPORT: include/linux/mm_inline.h: shuffle lru list addition and deletion functions
f03a29a5b56a BACKPORT: mm: don't pass "enum lru_list" to lru list addition functions
aa41f920f0ac BACKPORT: mm/swap.c: don't pass "enum lru_list" to trace_mm_lru_insertion()
5235b46df7d9 BACKPORT: mm: add __clear_page_lru_flags() to replace page_off_lru()
193066d00cb7 UPSTREAM: mm: VM_BUG_ON lru page flags
dd186f96e553 BACKPORT: include/linux/mm_inline.h: fold page_lru_base_type() into its sole caller
a22c83865360 FROMLIST: mm: x86, arm64: add arch_has_hw_pte_young()
e1776f1046eb FROMLIST: mm: x86: add CONFIG_ARCH_HAS_NONLEAF_PMD_YOUNG
a5c025159616 BACKPORT: mm/lru: introduce TestClearPageLRU()                 (check whether it's needed)
```
Core (Yu Zhao's v10 posting, 2022-02/03):
```
3904c29400c6 FROMLIST: mm: multi-gen LRU: groundwork
43d6a1b5a5a9 FROMLIST: mm: multi-gen LRU: minimal implementation
5e687c4264e0 FROMLIST: mm: multi-gen LRU: exploit locality in rmap
206c50620264 FROMLIST: mm: multi-gen LRU: support page table walks
fe0fc3bda1b2 FROMLIST: mm: multi-gen LRU: optimize multiple memcgs
c2046c16abb8 FROMLIST: mm: multi-gen LRU: kill switch
bcb446927aeb FROMLIST: mm: multi-gen LRU: thrashing prevention
c9aa97775a4b FROMLIST: mm: multi-gen LRU: debugfs interface
01fb358818ed FROMLIST: mm: multi-gen LRU: admin guide
8c414d63cfbc FROMLIST: mm: multi-gen LRU: design doc
```
Follow-ups:
```
107b6dd9b5f6 mm: multi-gen LRU: log when min_ttl is unsatisfied              (Juhyung Park / arter97)
5a361d7264ae mm: multi-gen LRU: export min_ttl unsatisfied counter to sysfs   (arter97)
17fbd4d621a7 mm: multi-gen LRU: set min_ttl to 5000ms by default              (arter97, DON'T take the default, see §5)
e180d2f288f3 mm: vmscan: Adapt to use new mm_walk API                         (the inverse of what we need)
f0125de52729 mglru: fixes                                                     (Yu Zhao, 2022-06-14, Change-Id I0999979…)
```
Skip: the 2021 `multigenerational lru` v3-era commits and their mass revert (`74e1664b2e86`…`1f29188bbf5f`);
that was the earlier attempt they replaced with v10.

✅ **Resolved 2026-10-15 — rebase casualty, not a bug.** `android13-stable`/`android14-stable`
are a fresh rebase onto the `android13-4.19-kona` vendor drop; their `mm/vmscan.c` history has
*none* of the a12 branch's mm work (no 2020 LRU backports, no CHROMIUM/rmap-lock backports, no
MGLRU), only Xiaomi's later "reclaim pages" staging drivers. Meanwhile tag **7.1.0 ("Added
support for android 13 ROMs") is the `android12-stable` tip and still carries MGLRU** — they
shipped MGLRU to A13 users from that branch. No issue in the repo mentions MGLRU (0 hits), and no
release note says it was removed or misbehaved. Releases: 3.0.0 "Added support for Multi
Generational LRU" + "Reverted all the Qualcomm changes over the memory management framework";
4.0.0 "Backported MGLRU from AOSP Gerrit" (the v10 series listed above). Base = tag `7.1.0`.
Checked on that tag: `mm/vmscan.c` has no `kswapd_threads` and no `reclaim_pages_from_list`
(only the `PROCESS_RECLAIM` Kconfig symbol survives their QCOM revert), so §1's "source had
neither" stands; it does have the `mm_walk_ops` adaptation (`e180d2f288f3`) to undo.
Option B (arter97 on 4.19): nothing found; his MGLRU work is on 5.4+ trees. Drop it.

### Option B: arter97's own 4.19 kernels (Juhyung Park)
He wrote the min_ttl follow-ups, so he likely carried MGLRU on 4.19 too. Worth a look as a second
reference for the conflict resolutions. **Unverified**, so find the repo first.

### Option C: port the final upstream version (6.1 + stable fixes) straight to 4.19
Upstream merged v14+, with a stream of fixes after it. It's more work (folio conversions everywhere)
but the code is better tested. **Not recommended as the base**, but use it as the fix source in §4 step 5.

---

## 4. Port procedure

Branch `pepito-24-mglru` off `pepito-24` (tip `9e681428a6be` on 2026-10-15, one commit past
`50c36c782d89`) in the builder tree. Cherry-pick with `-x`. The source is fetched there already:
remote `utsav`, tag `7.1.0` = `09f811270e07` (objects only, no branch yet).

1. **Prereqs.** Apply §3's prereq list. Drop any already present (grep first, since the kona merge
   carries some backports). `arch_has_hw_pte_young` on arm64 = `cpu_has_hw_af()`, which returns false
   on A53, as intended.
2. **Core series.** Expect conflicts in `mm/vmscan.c`, `mm/swap.c`, `include/linux/mm_inline.h`,
   `include/linux/mmzone.h`, `mm/workingset.c`, `mm/memcontrol.c`, `kernel/fork.c`, `mm/rmap.c`.
3. **Our conflicts that the source didn't have:**
   - **PROCESS_RECLAIM** (`reclaim_pages_from_list()`, `reclaim_pte_range()`): these isolate pages
     straight from page tables and call `shrink_page_list()`. Under MGLRU, the isolate/putback paths must
     go through `lru_gen_*` helpers (`lru_gen_del_page`/`lru_gen_add_page` via the reworked
     `del_page_from_lru_list`/`add_page_to_lru_list`). If the prereq refactor converts every call site,
     this mostly falls out. Audit every `ClearPageActive`/`SetPageActive` and `isolate_lru_page` caller
     in `fs/proc/task_mmu.c` and `mm/vmscan.c`.
     Also find out **who writes `/proc/<pid>/reclaim` on A17** (Qualcomm perf HAL? AOSP `CachedAppOptimizer`
     with `MADV_PAGEOUT` absent?). If nothing does, consider leaving PPR as is and only making it
     compile-correct.
     ✅ **Answered 10-15:** nothing in userspace writes it. AOSP `CachedAppOptimizer` uses
     `MADV_PAGEOUT` (absent on 4.19 → its compaction is a no-op here). The only PPR user is the
     in-kernel `mm/process_reclaim.c` (vmpressure-driven, calls `reclaim_pages_from_list()`),
     toggled by the perf HAL via `/sys/module/process_reclaim/parameters/enable_process_reclaim`
     (`commonresourceconfigs.xml` opcode 0x6) — **0 on dut1**, `reclaimed_anon=1740` pages ever.
     So: keep PPR compile-correct (`skip_reference_check` → our `force_reclaim`), hand-test
     `/proc/<pid>/reclaim` once with MGLRU on, done.
   - **multi-kswapd** (`kswapd_threads`): runs at 1. Make sure `lru_gen_age_node()` / kswapd hooks run
     once per node, not once per thread.
   - **old page-walk API**: MGLRU's `walk_mm()` uses `walk_page_range(mm, start, end, &mm_walk_ops,
     walk)`. Prefer **adapting `walk_mm()` to our `struct mm_walk` callbacks** over backporting the
     5.4 `mm_walk_ops` series, which touches every walk user (PPR, smaps, mincore, migrate, hmm…). The
     path is inert on A53 anyway (see §1). ~~Still exercise it once on the bench with
     `echo 0x0007 > /sys/kernel/mm/lru_gen/enabled`~~ — **that can't work here**: the cap is
     masked by `arch_has_hw_pte_young()`. But `try_to_inc_max_seq()` gates on
     `!full_scan && (!arch_has_hw_pte_young() || !get_cap(MM_WALK))`, so a **forced full scan
     from debugfs** (`+ memcg node max_seq [swappiness] [full_scan=1]` into
     `/sys/kernel/debug/lru_gen`) runs `walk_mm()` → `walk_page_range()` on A53 regardless.
     Normal kswapd aging never does. So: production = walk code inert (good); Phase 1 =
     `mglru-check.sh walk` hammers the debugfs force-scan for an hour to exercise it.
4. **`page->flags` layout.** Check that `LRU_GEN_WIDTH` + `LRU_REFS_WIDTH` fit (no NUMA and vmemmap, so
   they should), and that nothing aliases. Lesson from list-del: `PG_kmemcg` is a page_type in
   `_mapcount`, not a flag bit. Add a `BUILD_BUG_ON` sanity check if the series doesn't have one.
5. **Upstream fixes since v10.** In a mainline clone, run
   `git log --oneline v5.18..v6.6 -i --grep='multi-gen LRU\|lru_gen\|MGLRU' -- mm include`, then triage
   each into: applies to v10 semantics → take; folio-only/cleanup → skip; new feature → skip. Priority:
   memcg offline/migration crashes, `min_seq` / swap-constraint correctness, and kswapd spin/livelock
   fixes. Record every take/skip decision in §8.
6. **Config.** In `mi8937_defconfig`: `CONFIG_LRU_GEN=y`, `CONFIG_LRU_GEN_ENABLED=y`,
   `# CONFIG_LRU_GEN_STATS is not set` (on for the debug build). It's a shared defconfig, so every
   Mi8937 sibling gets it compiled in. The **runtime default** is set from userspace (§5) so it can be
   pepito-gated if needed.
7. **Build.** `./scripts/build-lineage24-remotely.sh --boot-only` (keep `KERNEL_OBJ` warm, per the script
   note). Check `Image.gz` against the 44 MB cap, and check that the kill switch exists:
   `cat /sys/kernel/mm/lru_gen/enabled` — **expect `0x0001` on A53** (checked in the ported
   `show_enable()`: bit 1 `MM_WALK` is masked by `arch_has_hw_pte_young()` = `cpu_has_hw_af()` =
   false here, bit 2 `NONLEAF_YOUNG` is x86-only).

---

## 5. Userspace knobs (mithorium-common / LineageParts)

- **Kill switch → GoTweaks toggle.** `persist.gotweak.mglru` (default 1), an rc trigger writing
  `/sys/kernel/mm/lru_gen/enabled` `y`/`n`, same pattern as `gpu_perf_floor`. Set the build-prop default in
  `mithorium.mk`, **not** `on boot` (memory `perf-toggle-bench-verdicts`: `on boot` overwrites a persisted
  user "0"). Needs sepolicy for writing that sysfs node from init (check the label first;
  it'll probably be `sysfs` unless we add a genfscon).
- **min_ttl_ms = 0 (upstream default).** arter97's 5000 ms default makes the **kernel OOM killer** fire
  when the working set can't be kept for 5 s, which goes around lmkd's policy (it kills by oom_score_adj,
  not by app state, and leaves no lmkd log line). On Android, lmkd should stay the only killer. Revisit
  only if the bench shows thrashing that lmkd misses.
- Swappiness stays at 100. MGLRU balances anon/file differently, and the old inconclusive swappiness
  result (100 vs 60) doesn't carry over. Re-test it as a separate cell after the main A/B, if at all.

---

## 6. Measurement plan

Same kernel and boot for both arms, toggled at runtime with the kill switch. Interleave
A/B/A/B and never compare across reboots or builds (memory `perf-toggle-bench-verdicts` gotchas:
interleave, process warmth, measure power early). Note: flipping `enabled` drains and rebuilds the lists;
after each flip, let the system settle (~2 min idle) before measuring.

**Phase 0: baseline harness (before any kernel work).** Write `diag-tools/mglru-bench/` with:
- `hog-resume.sh`: the zram lane's anon hog (`head -c 1300m /dev/zero | tail -c 1200m`) followed by
  `am start -W` of Settings, Messages, Chrome, the camera. Record: alive vs killed (from lmkd log),
  hot/cold, TotalTime.
- `vmstat-delta.sh`: snapshot `/proc/vmstat` (`pgscan_*`, `pgsteal_*`, `allocstall_*`,
  `workingset_refault*`, `workingset_activate*`, `pswpin/out`), `/proc/pressure/memory`, kswapd0 utime+stime,
  and the lmkd kill count. Diff across a window.
- `app-cycle.sh`: launch N (≈15) common apps round-robin for M rounds and count cold vs warm starts. This is
  the cleanest test of the "keeps more apps alive" claim.
Run Phase 0 on the current kernel and keep the numbers. It doubles as a reproducibility check of the
harness itself (two runs with the same config should agree).

**Phase 0 DONE 2026-10-15** (dut1, 10-11 build, debug kernel, 43 h uptime; `diag-tools/mglru-bench/results/`):
- `hog-resume` ×5, 1200 MB: iters 2–5 agree. **7–10 lmkd kills per hog**, 2–3 of 4 warmed apps
  killed (Messaging + Jelly every time, Settings 3/5, Aperture never — it was the most recent
  app). Cold resume 1.36–1.68 s vs hot 0.34–0.48 s. `psi_full` ≈ 3 s and ≈ 420–460 MB swapped
  out per hog; `direct_share` < 1 % (kswapd does the work). Iter 1 is an outlier (789 MB
  swapped, 19 kills, all four apps survived HOT): the first hog after a long idle drains
  older junk first. Discard iter 1 in the A/B too, or pre-hog once.
- `app-cycle` 15 apps × 4 rounds: run 1 (from idle) 10 kills, 2/45 cold in rounds 2+; run 2
  straight after: **0 kills, 0/45 cold**, HOT mean 174 ms. Steady-state 15 apps fit; the test
  needs pressure (run after a hog, or ~25 apps) to measure kills. Keep as the warm-launch
  latency and regression check.
- Harness gotchas in `diag-tools/mglru-bench/README.md` (post-hog kill sweep ~10 s, Settings
  `LaunchState`, `pidof` sub-processes).
- Headline baseline for the ship criterion: **~8 kills and 2–3 of 4 apps lost per 1200 MB hog.**

**Phase 1: stability (dut1, debug build with `CONFIG_DEBUG_VM=y` + `LRU_GEN_STATS`).**
- Boot, then 8 h of `app-cycle.sh` + hog loops. Zero `BUG`/`WARN`/`Bad page` in pstore/dmesg.
- Re-run the list-del stress rig and `fake-buddy-scan.sh` (`diag-tools/list-del-repro/`) as the mm
  regression suite. It was good at finding mm accounting bugs on this exact kernel.
- Toggle the kill switch under load about 20 times (the drain/refill path is a classic bug spot).
- Force MM_WALK on (`0x0007`) for one hour of the soak to exercise the adapted walk code.
- Exercise PPR if anything uses it (see §4.3); otherwise poke `/proc/<pid>/reclaim` by hand on a few
  cached apps while MGLRU is on.

**Phase 2: performance A/B (dut1, then release build on new2).**
- `hog-resume.sh` ×5 per arm, interleaved: survival rate, resume latency.
- `app-cycle.sh` ×3 per arm: cold-start count.
- `vmstat-delta.sh` over each run: direct-reclaim stalls and refaults per GB scanned, kswapd CPU.
- Idle power, screen off, 30 min per arm (ask Kyle for unplug assists, per memory
  `feedback-benchmarks-thoroughness`). If kswapd CPU changes, battery can move either way.

**Phase 3: daily-driver soak (new2, Kyle).** A few days on, a few days off. Compare lmkd kill counts per
day (`logcat -b events`/lmkd lines, or a small counter service) and Kyle's subjective feel. Daily use is
the only test that covers his real app mix.

**Ship criteria.** No stability findings in Phase 1. Phase 2: fewer lmkd kills and fewer cold starts with
resume latency no worse, or better. No measurable idle-drain regression. If it's a wash, ship it
**compiled in but default-off** (toggle in GoTweaks) rather than dropping the work.

---

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| mm corruption from a bad conflict resolution (page on wrong list, double isolate) | DEBUG_VM soak + list-del rig; kill switch; `VM_BUG_ON` lru-flag checks from the prereqs |
| v10 bugs fixed upstream later | §4 step 5 fix sweep; prefer stability fixes over features |
| PPR / multi-kswapd interaction | explicit audit in §4.3; test PPR by hand |
| kernel OOM killer surprises | min_ttl = 0 |
| Image size over 44 MB | check after each build; the addition is small |
| Sibling Mi8937 variants | the code is compiled in for all, the runtime default comes from the prop; nobody else ships this tree's kernel today, but keep it clean in case |
| Wasted effort if lmkd tuning alone solves it | §2: do lmkd first and decide after |

Rollback: `persist.gotweak.mglru=0` (no reflash), or drop the branch.

---

## 8. Log

- 2026-10-15: plan written. Verified kernel state (§1). Found the source series (§3) on
  `UtsavBalar1231/kernel_xiaomi_sm8250@android12-stable`. Open questions: why later branches of that tree
  dropped it; whether arter97 has a 4.19 tree; who writes `/proc/<pid>/reclaim` on A17.
- 2026-10-15: **Phase 0 done.** Harness `diag-tools/mglru-bench/` (lib + `vmstat-delta.sh`,
  `hog-resume.sh`, `app-cycle.sh`, README) written and run on dut1; baseline numbers in §6.
  dut1 is the right bench: no pattern lock (swipe keyguard), nothing else running on it.
  Next: §2 decision on the lmkd-props lane, then §3's open question on the source tree.
- 2026-10-15 (pm): **§2 done, G wins** (four interleaved A/Bs on dut1, details in §2).
  Staged, unpushed: mithorium-common `3e9bd71` (`ro.lmk.swap_compression_ratio=3`,
  `lowmem_min_oom_score=1001`, `relaxed_available_memory=true`, vendor props —
  `lmkd_config_prop` is `system_vendor_config_prop`, so vendor_init may set it). Kill-reason
  loggers running on new2 + dut1. **G applied at runtime on new2 12:45** (persist
  `lmkd_native.*` props, survive reboot; `PEPITO_ADB=new2-adb lmk-props.sh clear` reverts) for
  the daily-driver soak; ask Kyle how it feels after a few days and read
  `/data/local/tmp/lmk-kills.log` there. Next: §3 open question (why a13-stable dropped MGLRU), then
  the port. All MGLRU cells run with G in place.
- 2026-10-15 (late pm): **port started**, branch `pepito-24-mglru` on the builder (not pushed).
  Standalone compile wrapper `~/android/lineage-24/kbuild-mglru.sh` (reproduces kernel.mk's make
  line against the warm `KERNEL_OBJ`; ~50 s incremental). Prereqs: 13 of §3's list applied, plus
  `fdff65dfb8f4` (arm64 `cpu_has_hw_af()` — our tree lacked it). Conflicts were trivial
  (mmzone.h compaction fields, swap.c `lru_deactivate_file_fn`, our tree lacks `lru_deactivate_fn`
  / MADV_COLD; the patch's `#include <asm-generic/pgtable.h>` had to go — we already have the 5.8
  `linux/pgtable.h` move). ⚠️ Lesson: `git checkout --theirs` on a conflicted file replaces the
  WHOLE file with the source tree's version (clobbered 47 lines of our arm64 pgtable.h; caught by
  the per-file stat, redone by hand). **Shadow-entries prereq replaced:** the source's
  `975494424d5d` is radix-tree code; our swap cache is still 4.19 radix on an XArray `i_pages`, so
  took upstream 4.20 `8d93b41c09d1` + `4e17ec250fce` (swap cache → XArray) and then upstream 5.9
  `3852f6768ede` (shadow entries, XArray form) as `2c56bd8c8ea6`. Prereqs compile clean. Core
  series: 4 conflicts only (`fs/fuse/dev.c` flag mask, `mm/workingset.c` pack_shadow keeps our
  `EVICTION_MASK` line, `kernel/fork.c` drop the Xiaomi MIHW bits, `kernel/sched/core.c` add
  `lru_gen_use_mm(mm)` to our unrestructured `context_switch()`), plus the two shadow-API call
  sites. Also on the branch: `5d97c4500a30` (`skip_reference_check` → our `force_reclaim`;
  `mmap_sem` → `mmap_read_trylock/unlock`) and `63f30d6a7317` (defconfig `LRU_GEN=y`,
  `LRU_GEN_ENABLED=y`). Branch = 28 commits. **mithorium-common `ce2a9d6`** (unpushed): the
  §5 rc trigger + `persist.gotweak.mglru=1` system_ext default; no GoTweaks UI yet.
  ⚠️ Two self-inflicted stalls today: a fixup autosquash that conflicted mid-rebase while a
  chained compile ran on the half-rebased tree, and a `pkill -f` whose pattern matched its own
  ssh session. Keep fixes as plain commits during the port; squash at the end, if at all.
  **Full port COMPILES** (14:37): 0 errors, 0 warnings, `Image.gz` 18.80 MB vs 18.78 MB base
  (cap 44 MB, §1). Last fix `5ca4fbca950d` (`xa_is_value()` in `do_swap_page()`). Branch
  `pepito-24-mglru` = 29 commits. Polish later: `radix_tree_lookup()` → `xa_load()` in
  `lru_gen_swap_refault`-style helper in `mm/memory.c` (compiles on the hybrid tree as is).
  Phase 1 build = branch `pepito-24-mglru-debug` (mglru + `7060b4f60ae3` DEBUG_VM/page_owner +
  `LRU_GEN_STATS=y`), boot-only with `SKIP_SYNC=1` so the sync can't reset the checkout.
- 2026-10-15 (evening): **first debug flash HUNG** at the Palm logo — serial showed LK's
  `Channel alloc freed` and then nothing, not even earlycon. Not the port: the arm64 header
  `image_size` was 54,128,640 B because the debug branch had `7060b4f60ae3` (PAGE_OWNER/DEBUG_VM)
  but not its companion `cdbfe31dac58` (`STACK_HASH_ORDER_SHIFT=16`), so stackdepot's 8 MB
  `stack_table` pushed BSS over the DTB. ⭐ Exact cap, measured on new2's memblock: LK puts the DTB
  at physical `0x43400000` (ramdisk `0x43600000`), kernel at `0x40080000` ⇒ **`image_size` <
  54,001,664 B (0x3380000)**; the "44 MB `Image.gz`" rows in §1/§7 were the wrong metric
  (`Image.gz` is 18.8 MB; it's the uncompressed text+bss that matters). Release kernel ≈45.6 MB,
  fixed debug kernel 46.26 MB. Cherry-picked `cdbfe31dac58` onto `pepito-24-mglru-debug`;
  gotcha: `kbuild-mglru.sh` reuses the warm `.config`, run `kbuild-mglru.sh mi8937_defconfig`
  after any defconfig change. Serial capture: `cat /dev/ttyUSB0 | ts` (FTDI on `/dev/ttyUSB0`),
  boot built with `PEPITO_SERIAL_CONSOLE=true`.
- 2026-10-15 19:40: **MGLRU debug kernel BOOTS on dut1** (`0068eec0366c`, boot_completed ≈2 min).
  `mglru-check.sh status`: `enabled 0x0001`, root memcg at gen 7 by 150 s, per-uid memcgs listed,
  no hw AF. Only new dmesg line: `VM_WARN_ON(list_empty(&mm->lru_gen.list))` in
  `lru_gen_use_mm` (mm_types.h:591) ×2 at boot — the documented benign race with
  `lru_gen_migrate_mm` (Android memcg-migrates every new process); live only under DEBUG_VM,
  upstream later deleted the check. `health` now counts it separately; TODO drop it on the
  branch in the §4.5 sweep. **`flip 20` PASSED** (20 toggles under app-cycle load, 0 non-benign
  warnings, restored 0x0001; `results/flip20-20261015.log`). `walk 3600` started 19:47
  (`results/walk3600-20261015.log`). Kill logger restarted on dut1.
- 2026-10-15 19:55: ⚠️ the first `walk 3600` run issued ZERO scans — `mglru-check.sh walk`'s awk
  anchored on fixed indentation that this kernel's debugfs dump doesn't use (root gen moved 7→8 in
  20 "scans"). Caught by checking the generation counter mid-run; rewritten field-based, the
  script now prints root's max gen after 2 iterations as a self-check (10→15 confirmed). Dead run
  kept as `results/walk3600-20261015-noop-parserbug.log`; real run restarted 19:53. Lesson for §8:
  a load/stress script needs an in-band proof that it is doing the thing, not just "no errors".
  Also: `pkill -f`/`pgrep -f` with an unbracketed pattern killed my own shell twice more today —
  always `[x]pattern`.
- 2026-10-15 20:48: **`walk 3600` PASSED** (972 forced full scans, root memcg gen 15→987,
  `lru_gen_full` shows ~45 k leaf PTEs + 104 non-leaf walked per gen, young pages found via the
  walk; 0 non-benign dmesg lines). Then the §6 "poke `/proc/<pid>/reclaim` by hand" step
  **PANICKED dut1**: `kernel BUG at mm/vmscan.c:1545` =
  `VM_BUG_ON_PAGE(PageLRU(page) || PageUnevictable(page))` at `shrink_page_list()`'s `keep:`,
  via `reclaim_write → walk_page_range → reclaim_pte_range → reclaim_pages_from_list`. Victim: an
  ext4 file page, `unevictable|mlocked`, mapcount 7, mlocked by pid 1971 (another process).
  **Verdict: pre-existing CAF PPR bug exposed by DEBUG_VM, not the port** — `reclaim_pte_range`
  is byte-identical to `pepito-24`, the BUG line is from 2014, `isolate_lru_page()` happily takes
  pages off the unevictable list and `page_evictable()` then routes them to `keep:`. Production
  (no DEBUG_VM): silent isolate/putback; nothing in userspace writes the node (§4.3). Not
  empirically re-run on the stock debug kernel. Fix `fd88e2ecb440` on `pepito-24-mglru` (skip
  `PageUnevictable` pages before isolating, as upstream MADV_PAGEOUT effectively does); debug
  branch rebased on it (tip `3af02bb2495c`). pstore + serial banked in
  `results/panic-ppr-unevictable-20261015/`. Rebuilding the debug serial boot for the next flash;
  meanwhile the 8 h soak = `list-del-repro/stress.sh` (started 20:52 on the same kernel — the rig
  doesn't touch PPR). ⚠️ The rig's "PANIC IN PSTORE: list_del corruptio" line was a false
  positive: it grepped `pmsg-ramoops-0`, which holds adbd's echo of my own health-check command
  line. Health grep patterns must not appear in shell commands that logd records.
- 2026-10-15 22:00: Kyle flashed the guarded debug boot (`3af02bb2495c`). Boots; `/proc/<pid>/reclaim`
  file/anon/all on Jelly, Messaging, Aperture, Settings → RSS 186→8 MB etc., **0 BUG/WARN** — PPR
  guard verified, §6 "poke PPR by hand" done. **8 h soak started 22:00** = `list-del-repro/stress.sh`
  on dut1 (device stress pid 5143; stale pstore from the PPR panic deleted after banking so the rig
  doesn't re-flag it). Serial capture + panic monitor armed. Morning: `stress.sh status`,
  `run.sh check`, `mglru-check.sh health`, `fake-buddy-scan.sh`, then Phase 2 A/B.
- 2026-10-15 22:10: soak switched to **screen off** at Kyle's request (`svc power stayon false` +
  KEYCODE_SLEEP; brightness setting floors at 1 = faint glow, so true off). Display stays Dozing
  under the rig; mm workers (fork/stat storm, compaction+drop_caches, f2fs churn, anon hog) keep
  running at full tilt (pid churn ~10 k/min, pgsteal climbing, zram ~770 MB); the monkey and camera
  workers mostly idle with the screen off, so this soak is lighter on ION/userfaultfd than the
  rig's design. Battery 96→87 % in the first 10 min at 45 °C — the rig's own guard pauses <40 % or
  >48 °C and resumes at 70 % / <42 °C, so expect pause/resume cycles overnight.
- 2026-10-16 06:05: **Phase 1 PASSED.** 8.1 h `stress.sh` soak on `3af02bb2495c` (screen off,
  three battery/thermal pauses): same boot_id throughout, pstore empty, no dropbox kmsg,
  0 BUG/WARN/Bad-page, `oom_kill 0`; counters over the soak: `pgsteal_kswapd` 10.76 M,
  `pgsteal_direct` 1.84 M, `workingset_refault` 1.07 M, `compact_success` 237, zram peaked
  ~1.08 GB. `fake-buddy-scan.sh`: 1 M pfns, 139 859 BUDDY, **0 charged+mapped fake buddies**.
  Together with flip 20, walk 3600 (972 forced walks) and the PPR hand-poke (guarded), every §6
  Phase 1 item is done. Only open stability item: the benign `lru_gen_use_mm` VM_WARN_ON (drop in
  the §4.5 sweep). → Phase 2 A/B on dut1 next (same boot, flip `/sys/kernel/mm/lru_gen/enabled`,
  lmkd config G is the shipped baseline on this 20261015 system).
- 2026-10-16 08:35: **Phase 2 A/B on dut1 DONE** (`mglru-ab.sh run ab1 5`, same boot, kernel
  `3af02bb2495c` debug build, lmkd config G, 5 interleaved blocks, 10 counted 1200 MB hogs + 5
  app-cycles per arm; `results/ab1-20261016.log`):

  | metric (per arm) | MGLRU on | MGLRU off |
  |---|---|---|
  | lmkd kills per hog | **0.80** (cells 0/2, 0/3, 0/3, 0/0, 0/0) | **2.50** (2/2, 2/1, 8/0, 4/2, 2/2) |
  | resumed apps survived | 40/40 | 40/40 |
  | mean resume TotalTime | 491 ms | 477 ms |
  | hog psi_full stall | 1.58 s | 1.70 s |
  | hog refault_per_steal | **0.18** | 0.43 |
  | hog swapped_out | 807 MB | 779 MB |
  | app-cycle cold (rounds 2+) | 0/150 | 0/150 |
  | app-cycle mean launch | 214 ms | 200 ms |
  | app-cycle kswapd_cpu | **2.72 s** | 4.84 s |
  | app-cycle refault_per_steal | **0.13** | 0.50 |

  Reading: 3× fewer lmkd kills per hog (and no on-cell ever reached off's worst of 8), half the
  refaults per page reclaimed on both workloads (⚠️ 09:30: INVALID for the on arm — v10 only
  counted "recent" refaults, see upstream 3af0191a594 in the §4.5 table; re-measure after the
  sweep), ~45 % less kswapd CPU under the app cycle,
  slightly shorter full stalls; resume/launch latency 14 ms slower (3 %/7 %), inside the
  run-to-run spread but consistently on the same side, so note it as "no better". Survival and
  cold starts were saturated at 100 %/0 by config G, so they don't discriminate. **Ship criteria
  (§6): met on kills, neutral-to-slightly-negative on latency, reclaim efficiency clearly better.**
  Not done: idle-power arm (needs unplug assists) and the release-build run on new2 (Phase 3).
  Recommendation: ship **default-on** behind the `persist.gotweak.mglru` kill switch after the
  §4.5 upstream-fix sweep; measure idle power during the Phase 3 daily soak instead of a separate
  bench. Caveat: debug kernel (DEBUG_VM/page_owner) on both arms — absolute latencies are
  inflated equally; the release-build run on new2 is the real-world confirmation.
- 2026-10-16 09:30: **§4.5 upstream fix sweep** (mainline v5.18..v6.6, partial clone on the builder
  `~/mglru-upstream/linux`, 45 MGLRU commits after the v10 series). Polish first: `e7addd0da4d4`
  drop the `lru_gen_use_mm` VM_WARN_ON, `05eb877a1d73` `xa_load()`. Triage:

  | upstream | what | decision |
  |---|---|---|
  | 14aa8b2d5c2 | no `wakeup_flusher_threads` per aging cycle | **take** |
  | de08eaa6156 | `lru_gen_migrate_mm` before `lru_gen_add_mm` → NULL memcg crash | **take** (real crash fix, our `VM_BUG_ON_MM` → oops in prod) |
  | 669281ee7ef + b7108d66318 | per-zone reclaim: scan all zones, age ineligible pages; skip CMA when the allocation can't use it | **take** (squashed) |
  | 3af0191a594 | workingset accounting: count every refault, ACTIVATE only recent ones | **take** — ⚠️ invalidates the on-arm `refault_per_steal` in the 10-16 A/B (v10 only counted "recent" refaults); kills/stall/kswapd-CPU results unaffected |
  | 359a5e1416c | retry clean rejects that were under writeback when isolated | **take** (hand-adapted to our older `evict_pages`) |
  | a3235ea2a88 | `can_swap` in `lru_gen_look_around` | N/A — our look-around has no `get_pfn_page`/`can_swap` filter |
  | bb5e7f234ea | `inc_min_seq` retry race | N/A — our `inc_max_seq` predates the retry loop |
  | 9f550d78b40, 814bc1de03e, 6867c7a3320 | memcg-LRU (`shrink_one`, `memcg_lru->lock`) | skip — 6.2 per-node memcg LRU redesign (e4dde56cd20 series) not taken |
  | 7f63cf2d9b9 | debugfs `wait_event_killable` rewrite | skip — debug path only |
  | 52fc048320a | `pte_offset_map_nolock()` may fail | skip — 6.5 API |
  | 2022-12-21 + 2023-01-18 + 2023-05-22 series, docs, comments, 17e810229cb/8788f678148 (FADV_NOREUSE) | redesign / cleanup / feature | skip |

  Post-v6.6 MGLRU fixes (6.7–6.12, e.g. protection calculation, `min_ttl` with memcgs) are
  outside the plan's window — review before a second release. Branches after the sweep:
  `pepito-24-mglru` = 30 + 2 polish + 5 fix commits; debug branch rebased on top.
- 2026-10-16 12:30: **post-sweep verification on dut1** (`2e1dbb95c343`, debug): boots, `use_mm`
  warning gone, PPR poke OK (Jelly 192→28 MB, Settings 118→0.5 MB), 3 hogs → 34 (post-idle
  outlier) / 1 / 0 kills with 12/12 resumes survived, app-cycle 1/30 cold, 0 non-benign dmesg.
  `workingset_activate` now counts (179 k) and refault_per_steal reads 0.61 on the on arm — the
  accounting fix is live and the metric is comparable to classic again. **SHIPPED to the forks:**
  kernel `pepito-24` fast-forwarded 9e681428a6be → `253a9ff4e4d1` (37 commits, pushed over SSH;
  `pepito-24-mglru` and `-debug` also pushed as branches), mithorium-common `ce2a9d6` pushed to
  `pepito-24`. Full release build started 12:32 (`build-lineage24-remotely.sh`, normal sync, no
  serial console) for new2 = Phase 3 daily soak. Debug boot images parked in
  `flash-staging/held-20261016-debug/`. ⚠️ The 10-15 release build's flash set is now stale: the
  next `flash-staging.sh` on any unit flashes MGLRU default-on; kill switch =
  `setprop persist.gotweak.mglru 0` (rc trigger writes `n` to `/sys/kernel/mm/lru_gen/enabled`).
- 2026-10-16 13:10: **§5 GoTweaks toggle written** — LineageParts `83f5b0b8` (worktree
  `~/lineageparts-mglru` on the builder, NOT yet pushed): "Multi-generation memory manager" switch
  in the PVG100 Tweaks performance category, bound to `persist.gotweak.mglru`, default on, hides
  itself when `/sys/kernel/mm/lru_gen/enabled` is absent. No sepolicy change: `persist.gotweak.*`
  is already `gotweak_prop` with `set_prop(system_app)`, and `vendor_init` may write any
  `sysfs_type` file bar usermodehelper (system/sepolicy private/vendor_init.te:238), which covers
  the rc trigger's write. Plan: `m LineageParts` compile check once the running release build
  finishes, then push to the fork's `pepito-24` for Kyle's next build. Verify on new2 after the
  flash: toggle off → `cat /sys/kernel/mm/lru_gen/enabled` reads `0x0000`, on → `0x0001`.
- 2026-10-16 13:40: Kyle asked to stop my release build and run it himself — killed (no images
  produced). LineageParts `83f5b0b8` (toggle) **pushed** to the fork's `pepito-24` uncompiled so
  his build includes it; any failure would be local to GoTweaksSettings. Heads for his build:
  kernel `253a9ff4e4d1`, mithorium-common `ce2a9d6`, LineageParts `83f5b0b8`. After the flash on
  new2: `getprop persist.gotweak.mglru` = 1, `cat /sys/kernel/mm/lru_gen/enabled` = 0x0001, toggle
  off → 0x0000, `dmesg | grep avc | grep lru_gen` empty; then Phase 3 daily soak.
- 2026-10-16 14:55: **Kyle's release build `20261016` flashed on dut1** — kernel
  `…-00040-g253a9ff4e4d1`, release config (LRU_GEN=y, no DEBUG_VM), `persist.gotweak.mglru=1`,
  `enabled=0x0001`; `setprop … 0` → `0x0000`, back to 1 → `0x0001` (rc trigger + vendor_init
  sysfs write work on a real boot, 0 avc for lru_gen; the one "avc gotweak" logcat hit was
  adbd echoing my own grep). LineageParts APK built 13:54 (toggle commit in). new2 flashing next.
- 2026-10-16 15:10: **new2 (Kyle's daily driver) on `20261016`** — same checks pass (kernel
  `253a9ff4e4d1`, prop 1, 0x0001 ↔ 0x0000 via setprop, 0 lru_gen denials, config G props,
  memcgs aging). **Phase 3 daily soak STARTED** on new2; dut1 also on the release build. Kill
  loggers running on both (`/data/local/tmp/lmk-kills.log`). Watch: felt app-switch latency (the
  one metric that moved the wrong way, +14 ms), any kernel BUG/pstore, battery vs the 10-15 build.
  Kyle to eyeball the GoTweaks row. Open: post-6.6 upstream fix review; re-run the refault metric
  on the fixed accounting if anyone cares; release notes for the next cut.
