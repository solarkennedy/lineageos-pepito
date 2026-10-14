# PLAN-list-del-panic — `list_del corruption` kernel panics on 24.0 (customer report)

Status: **CLOSED 2026-10-14** — root cause found and fixed (BPF ring-buffer pages kmem-charged; on 4.19 `PG_kmemcg` aliases `_mapcount`). Fix on `pepito-24` as `50c36c782d89` (+ `521a7e6f19d2`), not yet in a release build — see the 10-13 evening section. Original status (2026-10-12): open, triage from logs + source only.

## The report

Customer unit on `24.0-20261011-SNAPSHOT-Mi8937_gapps`, Magisk-rooted, running their own root app plus a banking app. Two panics on consecutive boots:

| Time | Uptime | Faulting task | Corrupted entry |
|---|---|---|---|
| 13:53 | 143 s | `s.mobilebanking` pid 27537, CPU 3 | `ffffffbf02100d48` |
| 13:56 | 176 s | `BG Thread #1` pid 7152, CPU 1 | `ffffffbf02116008` |

Both:

```
list_del corruption, <addr>->next is LIST_POISON1 (dead000000000100)
kernel BUG at lib/list_debug.c:55!
pc : __list_del_entry_valid+0x90/0xc4
Tainted: G        W         4.19.325-cip135-st19-perf-gbe4fe4036389 #2
Modules linked in:   (none)
```

Context from the reporter (unrelated to the panic as far as known): they had just added a Magisk module `sepolicy.rule` (`allow priv_app_36 magisk unix_stream_socket { connectto getopt }`), which needed two reboots to apply.

## Logs

`plans/assets/list-del-panic-20261012/`

- `panic1-13-53.txt.gz` — previous-boot kernel log, 13:53 panic (BUG at line 615 when decompressed)
- `panic2-13-56.txt.gz` — same, 13:56 panic (BUG at line 526)

Both are **truncated near the top** (`[[TRUNCATED]]` marker, each exactly 66258 bytes): the log starts at ~15.8 s, so early boot is missing.

Build header in the logs: `Palm/PVG100/pepito:17/CP2A.260605.016/20261011:userdebug/release-keys`, kernel built Oct 5 on Stellaris16, radio `…214411.1.222870.3`.

## Kernel source that crashed

`gbe4fe4036389` = `be4fe4036389`, tip of branch `pepito-24` in `~/android/lineage-23/kernel/xiaomi/msm8937` (the branch is checked out as a worktree in an old session scratchpad; use `git show pepito-24:<path>` or add a new worktree). The 23.2 kernel is branch `pepito-rmnet` (`8dc0c83fbe0b`). Merge base of the two: `342a6915cdaa`.

## Call traces

Panic 1:

```
__list_del_entry_valid+0x90/0xc4
move_freepages_block+0x194/0x220
steal_suitable_fallback+0x3e0/0x4f0
get_page_from_freelist+0x5a8/0xc3c
__alloc_pages_nodemask+0x410/0x1024
new_slab → ___slab_alloc → kmem_cache_alloc
f2fs_alloc_inode ← iget_locked ← f2fs_iget ← f2fs_lookup
__lookup_slow … path_lookupat ← filename_lookup ← vfs_statx ← newfstatat
```

Panic 2 is the same shape, differing only in the middle:

```
move_freepages_block ← steal_suitable_fallback ← get_populated_pcp_list
← get_page_from_freelist ← __alloc_pages_nodemask ← new_slab … kmem_cache_alloc
← __grab_extent_tree ← f2fs_init_read_extent_tree ← f2fs_iget ← f2fs_lookup … newfstatat
```

## What is established

1. **Meaning of the signature.** `move_freepages()` (`mm/page_alloc.c:2175` on `pepito-24`) walks a pageblock and does `list_move(&page->lru, …)` on every page with `PageBuddy` set. It hit a page that is flagged free but whose `lru.next` is `LIST_POISON1`. So something ran `list_del(&page->lru)` on a page after it was returned to the buddy allocator, or freed a page still linked on a private list. The allocator is the detector, not the cause.
2. **Why it panics.** `CONFIG_DEBUG_LIST=y` + `CONFIG_BUG_ON_DATA_CORRUPTION=y`.
3. **The faulting tasks are victims.** Both are an ordinary `stat()` needing a new slab page.
4. **No modules loaded.** Magisk does not change the kernel image; `boot-magisk.bin` carries the same kernel.
5. **`mm/page_alloc.c` is byte-identical between `pepito-rmnet` and `pepito-24`** (not in `git diff --stat pepito-rmnet pepito-24 -- mm`).
6. **No culprit is recorded**, because the kernel has `DEBUG_VM`, `PAGE_OWNER`, `PAGE_EXTENSION`, `PAGE_POISONING`, `DEBUG_PAGEALLOC`, `SLUB_DEBUG` all off (`mi8937_defconfig` on `pepito-24`).

## Inferences (not proven)

- **The corrupted entries are `struct page` pointers in vmemmap**, not data addresses. Registers: page = `…02100d40` / `…02116000`, pageblock end (x25) = `…0210ffc0` / `…0211ffc0`. Assuming `memstart_addr = 0x80000000` (consistent with the per-cpu pointer in x2 landing just under the 3 GB top), these are **pfn 0x104035 and 0x104580**, i.e. phys ≈ `0x104035000` and `0x104580000`, in two **adjacent 4 MB pageblocks** (pfn 0x104000–0x1043ff and 0x104400–0x1047ff).
- The reporter's "one underlying corruption" cannot be literal: the second panic is on a fresh boot. Same bug, same 8 MB of physical memory, two boots running ⇒ suggests a **deterministic actor, plausibly an early-boot allocation**, not random damage. Not checked: whether any reserved-memory / CMA region sits near phys 0x104000000.
- **`W` taint in both boots before the BUG** ⇒ a kernel WARN fired earlier, in the truncated part of the log. Possibly related; unknown.
- **Abnormally high PID numbers for the uptime**: boot 1 pid 17357 at 111 s and 27537 at 143 s; boot 2 pid 2828 at 49 s, 11765 at 104 s, ≥19837 at 176 s. Something was forking very heavily. Guess only: the reporter's root app spawning `su`. A fork-heavy load may be the trigger rather than the cause.

## Suspects

By size of change only, no evidence linking any of them:

- **Page-cache XArray conversion backport**, new in the 24.0 kernel base (upstream caught up 1172 commits; `pepito-rmnet..pepito-24` touches `mm/filemap.c` 206 lines, `mm/shmem.c`, `mm/workingset.c`, `mm/truncate.c`, `include/linux/swap.h`, `lib/radix-tree.c`, new `lib/xarray.c` 2065 lines). A page-cache refcount slip would free a page that is still on a list.
- `kernel/fork.c` (+232 lines in the same range) — not read.
- `drivers/gpu/msm/kgsl*` — the diff read in `kgsl.c` is the events workqueue → kthread worker conversion, no page handling; `kgsl_pool.c` unchanged.
- Any driver keeping pages on its own `page->lru` list (ION page pool, kgsl pool) — unchanged between the branches apart from our `ion-ioctl.c` camera compat (`00388d74ab43`, also on 23.2).

Not known: whether this has ever happened on 23.2, or on any bench unit running 24.0. No mention of it in the shared memory notes.

## 2026-10-12 — module read, debug kernel + repro staged

**Cellular Watcher module (v1.5.7 zip) inspected.** Magisk stub installer, APK into
`/system/priv-app` + privapp allowlist + the `sepolicy.rule` from the report. Nothing kernel-side.
As root it runs airplane/IMS cycles (`cmd connectivity airplane-mode`, `cmd phone ims`,
`svc wifi`), grows logd and runs a 300 s `timeout logcat -b radio,system` boot capture, and
calls `dsd-probe` / `nas-probe` / `imsa-probe` from a second module `pepitodiagcap` under
`timeout 8 env LD_PRELOAD=libqmi_force_ipcr.so`. It forks a handful of processes per cycle,
nowhere near the 20k pids seen, so it is not the heavy forker. Kyle recalls the module was
**not working at the time because of the SELinux rule**, so its root path was likely inert on
the two panic boots. Decision: mimic the failure first, module second.

**Staged (Kyle builds and flashes):**
- Kernel branch `pepito-24-debug-mm` = `pepito-24` + `7060b4f60ae3`: `CONFIG_DEBUG_VM`,
  `CONFIG_PAGE_OWNER`, `page_owner=on` in `CONFIG_CMDLINE` (`CMDLINE_EXTEND=y`, so no
  BoardConfig edit). Debug only.
- `~/android/lineage-23/diag-tools/list-del-repro/` — `run.sh load` (fork storm + cold-stat
  storm over /data for 240 s after boot, pid high-water log), `run.sh check` (pstore/dropbox
  scan), README with the bench cycle.

## 2026-10-12 evening — THIRD occurrence, on our own bench unit (new2)

`~/android/lineage-23/diag-tools/captures/stock-diff-l1/new2-panic-20261012/HANDOFF.md` + raw
pstore. new2 (`9c2e6b00`, build 20261007, **same kernel `gbe4fe4036389`**), panic at uptime
**27625 s (7h40m)**, 17:50, phone in a pocket on a walk. Same BUG, same frames down to
`move_freepages_block ← steal_suitable_fallback`; victim this time is a 32-bit HAL (pid 1434,
`compat_ion_ioctl` → `ion_system_heap_allocate`). On the current new2 boot pid 1431 is
`android.hardware.camera.provider-service_32.lineage`, the only 32-bit HAL in that pid
neighbourhood, so the victim was almost certainly the camera provider (face unlock on wake?).

What the third sample changes:

- **Not an early-boot / first-3-minutes phenomenon.** 7h40m of uptime kills that inference.
  The customer's two early hits were a property of the customer's load, not of the bug.
- **Not the customer's environment.** No Magisk, no watcher, no banking app on new2. The
  Magisk + module escalation step is unnecessary; **drop it**.
- **The fork storm is not the trigger** either. new2's panic boot had nothing of the sort.
- **Memstart correction.** `/proc/iomem` on new2: System RAM `0x40000000–0x849fffff` and
  `0x8ea00000–0xffffffff`; `/proc/zoneinfo` `start_pfn 262144` (0x40000). So `memstart_addr`
  is **0x40000000**, not 0x80000000, and vmemmap = `0xffffffbeff000000`. Re-decoded:

  | hit | page | pfn | phys | pageblock |
  |---|---|---|---|---|
  | customer 13:53 | `…bf02100d40` | 0xc4035 | 0xc4035000 | 0xc4000000 |
  | customer 13:56 | `…bf02116000` | 0xc4580 | 0xc4580000 | 0xc4400000 |
  | new2 17:50 | `…bf02150940` | 0xc5425 | 0xc5425000 | 0xc5400000 |

  Three hits in a 24 MB window of a 2.8 GB machine, two different devices. Nothing is mapped
  there: no reserved-memory node, no CMA pool (venus 0x8f800000, cma 0xf6800000, secure
  0xf7800000, adsp 0xfec00000, qseecom 0xff000000), nothing in `/proc/iomem` (only a
  `reserved` at 0xb0000000–0xb07fffff nearby). Plain movable RAM.
- **Same `W` taint source.** new2's full log shows it is the benign boot-time
  `gic_irq_domain_alloc` WARN (irq-gic.c:1008, twice at 0.155 s). Not related.
- **Same constant registers** in all three dumps: `x26 = 0xf0000000`, `x27 = 0xf0000080`,
  `x24 = ffffff8012158000`. Unexplained; probably code constants, noted for whoever
  disassembles `move_freepages_block+0x194`.
- **Why detection is delayed and clustered.** `steal_suitable_fallback` is the only common
  caller that *walks every page of a pageblock*; ordinary alloc/free only touch list heads.
  A page damaged in block X is therefore invisible until a fallback steal happens to scan
  block X. So the corruption can be arbitrarily older than the panic (boot time included),
  and the 24 MB cluster can mean either a fixed actor or simply that those blocks are the
  ones that get stolen first. `page_owner` resolves this: it will show *when* and *by whom*
  the bad page was last freed.

**Revised strategy:** the bug reproduces on its own on a bench unit in under a day of normal
use. The debug kernel (`pepito-24-debug-mm`) on new2 and dut1, used normally, with
`run.sh check` each morning, is the whole plan. The synthetic load in
`diag-tools/list-del-repro/` is optional acceleration, not a requirement. Preserve
`/sys/fs/pstore/*` after any hit before rebooting again.

## 2026-10-13 — debug kernel on DUT1: two boot blockers, one real bug found

Branch `pepito-24-debug-mm` (fork pushed), serial capture `plans/assets/list-del-panic-20261012/`.

1. **First debug boot (`7060b4f60ae3`) hung at the Palm logo, silent on serial** after LK's
   `Channel alloc freed`. Cause: `CONFIG_PAGE_OWNER` selects STACKDEPOT whose static
   `stack_table` is 8 MB of BSS at the default `STACK_HASH_ORDER_SHIFT=20`; arm64 header
   `image_size` went 43.5 → 51.6 MB and the BSS clear wiped the DTB LK had placed above the
   kernel (no DTB ⇒ no cmdline ⇒ no earlycon). Fix `cdbfe31dac58`: `STACK_HASH_ORDER_SHIFT=16`
   (512 KB), image_size 44.1 MB. **Rule: the kernel's runtime footprint must stay ≈43–44 MB.**
   (`boot_verifier: Signature length exceeds size signature buffer` on serial is normal noise.)
2. **Second boot: kernel + page_owner up, then panic loop at ~29 s every boot:**
   `VM_BUG_ON_PAGE(PageLRU(page) && !lrucare)` → `kernel BUG at mm/memcontrol.c:6104`,
   `mem_cgroup_commit_charge ← mcopy_atomic ← userfaultfd_ioctl`, pid `HeapTaskDaemon` (ART's
   userfaultfd GC). page_owner shows the page allocated an instant earlier by the same
   `mcopy_atomic` call, already `lru|active`. **Real ordering bug** from the Android backport
   `ed11b43e5519 BACKPORT: FROMGIT: userfaultfd/shmem: support UFFDIO_CONTINUE`:
   `mfill_atomic_install_pte()` does rmap + LRU add + set_pte_at and drops ptl, and only then
   `mcopy_atomic_pte()` commits the memcg charge — the opposite of 4.19's contract (after rmap,
   before LRU, under ptl). **Present in the 23.2 kernel (`pepito-rmnet`) and upstream
   lineage-23.2/24.0 too.** Fix: hand `memcg` into the helper and commit after the rmap
   (commit on `pepito-24-debug-mm`, build in progress). Whether this is the list_del culprit is
   unproven; it is at minimum a lruvec-accounting bug on every UFFDIO_COPY and a small
   use-after-free window (commit touches the page after the PTE is live and ptl dropped).
3. Excerpt: `dut1-debugvm-memcg-bug-20261013.txt`.
4. **✅ 09:42 DUT1 BOOTS on `a2980325eb5d`** (fix + page_owner + DEBUG_VM + serial console):
   boot_completed 56 s, `allocated 31457280 bytes of page_ext`, `/sys/kernel/debug/page_owner`
   present once debugfs is mounted (A17 leaves it unmounted; `run.sh check` now mounts it),
   only the benign GIC WARNs. **DUT1 is now the armed witness.** Host serial capture was left
   running on `/dev/ttyUSB0` (session scratchpad `dut1-debug-serial.log`).

**To build this kernel again:** the landing-repo manifest must point
`kernel/xiaomi/msm8937` at `revision="pepito-24-debug-mm"` (reverted after the build so it
cannot ride into a release); `PEPITO_SERIAL_CONSOLE=true ./scripts/build-lineage24-remotely.sh
--boot-only`. Staged quiet/rollback images: `~/android/lineage-24/flash-staging/held-20261011/`.

**Follow-ups:** (a) cherry-pick `a2980325eb5d` (userfaultfd memcg ordering) onto `pepito-24`
and `pepito-rmnet` for shipping builds — it is a real bug regardless of the list_del outcome;
(b) flash new2 with the same debug boot image (new2 is on 20261007 — boot-only is fine);
(c) wait for the next `list_del` hit with page_owner armed.

## 2026-10-13 — REPRODUCED on DUT1 under stress (hit #4), instrumented kernel staged

**Hit.** Unattended stress rig (`diag-tools/list-del-repro/stress.sh`; fork+stat storm,
compaction + drop_caches, f2fs write ring, monkey, camera cycles, anon hog) on the debug
kernel `a2980325eb5d` (DEBUG_VM + PAGE_OWNER + the userfaultfd memcg fix). Panic at
**4153 s uptime, 10:50:39**, 69 min into the stress. Serial excerpt:
`assets/list-del-panic-20261012/dut1-stress-hit1-serial-20261013.txt`; pstore bank:
`diag-tools/list-del-repro/results/pstore-hit-20261013-105039/` (ramoops text has bit flips,
the serial copy is the clean one).

| | |
|---|---|
| signature | `list_del corruption, ffffffbf0210a448->next is LIST_POISON1` → `__list_del_entry_valid ← move_freepages_block ← steal_suitable_fallback` |
| victim | `stat` pid 18034, `newfstatat → f2fs_lookup → f2fs_iget → f2fs_alloc_inode → new_slab` (the customer's exact path, from our `load.sh` stat walker) |
| page | struct page `ffffffbf0210a440` → **pfn 0xc4291, phys 0xc4291000, pageblock 0xc4000** — the customer's first hit was 0xc4035, same pageblock |
| regs | x26/x27 = `PAGE_TYPE_BASE` / `PAGE_TYPE_BASE\|PG_buddy` again, x24 = `ffffff8012159000` |
| battery | 5 % at 54.7 °C, −672 mA under load on the hub; stress now pauses < 40 % / > 48 °C and resumes at 70 % |

Four hits on three devices, all inside phys `0xc4000000–0xc5500000`. Nothing is reserved
there (`/proc/device-tree/reserved-memory`, `memblock/reserved`, ION/CMA all live at
`0x84a00000–0x8fffffff` and `0xf3100000+`). A live `page_owner` dump of the window on the
next boot (`results/po-window-boot0cc9e70b.txt`) shows it full of early-boot kernel
allocations — vmalloc 2177, slab 1274, percpu 499 pages of 6110 — i.e. the window is where
the first deterministic boot-time allocations land on every PVG100, which is why the same
addresses recur across units. The specific pfn was free at the time of the dump.

**So the userfaultfd memcg bug (`a2980325eb5d`) is NOT the list_del culprit** — this hit
is on a kernel that has the fix.

**Reading of the signature.** `LIST_POISON1` is the exact value `list_del()` writes; random
DMA or bit rot would not produce it. A `PageBuddy` page sitting in a free list had its `lru`
unlinked by *someone else's* `list_del(&page->lru)`. With `DEBUG_LIST` that `list_del`
passes silently (its prev/next are consistent while the page is on the buddy list), so it
quietly removes the page from the freelist and poisons it; only a pfn-order walk
(`move_freepages_block`, compaction) ever notices. Users of `page->lru` on pages they do
not own: the ION page pool and the KGSL page pool (both chain pooled pages through
`page->lru`), the LRU lists, and any stale page reference after a free. The list_debug BUG
cannot say which, and `__dump_page_owner` in this tree refuses to report a free page.

**Instrumented kernel `c071078ebd6c`** on `pepito-24-debug-mm` (pushed; build launched
13:00, flash DUT1 when green):
- `page_owner` records the **free stack** (`free_handle`) and dumps alloc + free stacks for a
  FREE page instead of bailing.
- `move_freepages()` detects `LIST_POISON1/2` in a buddy page's `lru` and `dump_page()`s it
  **before** `list_move` trips the BUG → the next hit prints last owner + last free stack.
- `free_pages_prepare()`: `VM_BUG_ON_PAGE(PageBuddy)` → a double free dies at the second
  free with the first free's stack.
- `ion_page_pool_remove()` / `_kgsl_pool_get_page()`: `VM_BUG_ON_PAGE(PageBuddy)` → a pooled
  page that is secretly on a buddy list dies in the pool's own stack.

**Flash blocked on a hand EDL.** `adb reboot edl` and `adb reboot bootloader` both come back
as a normal boot on this unit (kernel logs `Unable to find DT property:
qcom,msm-imem-download_mode`, so the restart reason never reaches LK). The built image sits in
`~/android/lineage-24/flash-staging/boot.bin` (kernel `-00004-gc071078ebd6c`, image_size
44.1 MB, serial on). Procedure: `list-del-repro/stress.sh stop`, EDL by hand, `flash-staging.sh
--no-adb`, then `stress.sh start`. The rollback image is `held-20261011/boot-debug-quiet.bin`
or the previous debug build. ⚠️ `pkill -f wait-for-device` kills the calling shell too.

**Rig fixes:** the watcher missed the 10:50 reboot (panic → adb back inside 90 s), so stress
sat idle 95 min; it now compares `boot_id` every poll. `pgrep -f stress-dev.sh` matched the
adb shell itself; now a pid file. Battery/thermal pause as above.

## 2026-10-13 afternoon — ⭐ ROOT CAUSE: BPF ring-buffer pages are kmem-charged, and on 4.19 PG_kmemcg aliases _mapcount

**Two more crashes fell out of the flash attempts, and both carried page_owner output:**

1. Shutting down for `adb reboot edl` at 6591 s uptime (the stress boot):
   `kernel BUG at mm/page_alloc.c:846` = `page_is_buddy(): VM_BUG_ON_PAGE(page_count(buddy) != 0)`
   from `free_pcppages_bulk ← free_unref_page_list ← release_pages ← … ← do_munmap` in `true`
   (our fork storm). The dumped "buddy":
   `page:ffffffbf020e32c0 count:2 mapcount:-511 … raw: … dead000000000100 dead000000000200 … 00000002fffffe00`
   and page_owner: **`page allocated via order 0, migratetype Unmovable, gfp_mask
   0x7286c0(GFP_USER|__GFP_NOWARN|__GFP_RETRY_MAYFAIL|__GFP_ZERO|__GFP_ACCOUNT) … bpf_ringbuf_alloc`**.
   Bank: `diag-tools/list-del-repro/results/pstore-hit2-20261013-124047-pcp-bug/`.
2. The next boot, 50 s in, while system_server exited for `adb reboot bootloader`: ten
   `BUG: Bad page map in process HintManagerServ pte:600000c4a60fd3 … page dumped because: bad pte`
   (= `page_mapcount(page) < 0` in `zap_pte_range`), pfns 0xc4a5e–0xc4a83 — the same window —
   every one of them page_owner'd to `bpf_ringbuf_alloc`.

**The mechanism.** `_mapcount` and `page_type` are one union in `struct page`. On 4.19,
`memcg_kmem_charge()` marks a `__GFP_ACCOUNT` page with the `PG_kmemcg` *page_type*
(`0xffffffff & ~0x200 = 0xfffffdff`). The A17 kernel's backports
`167e4fa78c8d UPSTREAM: bpf: Memcg-based memory accounting for bpf ringbuffer` (+ the matching
`__GFP_ACCOUNT` in `__bpf_map_area_alloc`) allocate the ring buffer's pages that way, and
`ringbuf_map_mmap → remap_vmalloc_range → vm_insert_page → page_add_file_rmap` then does
`atomic_inc_and_test(&page->_mapcount)`: `0xfffffdff + 1 = 0xfffffe00`. That value passes
`PageType(page, PG_buddy)` (`(v & 0xf0000080) == 0xf0000000`). So every mapped ring-buffer page
is, to the allocator, a free order-0 buddy page — with a poisoned `lru` left over from its own
allocation-time `list_del`. Consequences, all observed:
- `steal_suitable_fallback → move_freepages_block` walks the pageblock, sees `PageBuddy`,
  `list_move`s it → **`list_del corruption, ->next is LIST_POISON1`** (the customer's panic).
- freeing its real buddy → `page_is_buddy()` → **`page_count(buddy) != 0`** (hit #2).
- unmapping it → mapcount goes to −512 → **`BUG: Bad page map … bad pte`** (hit #3, ×10).
- data pages are double-mapped (`2 * nr_data_pages`) so they sit at −510; consumer/producer
  pages at −511. `mapcount:-511` in the dump is this number exactly.

**Live proof on the running unit (no panic needed):** `/proc/kpageflags` + `/proc/kpagecount`
scan (`diag-tools/list-del-repro/fake-buddy-scan.sh`): of 54 868 pages the kernel reports as
BUDDY, **13 have mapcount −511/−510** instead of the buddy value −128 — the ring buffers
system_server has mmapped (`anon_inode:bpf-map` in its maps; 42 bpf-map fds). `page_owner`'s
reader skips `PageBuddy` pages, which is why they never showed in the window dumps.

**Why only 24.0:** the 23.2 kernel (`pepito-rmnet`) carries `ringbuf.c` only up to
`869ee1e4ca46` — no memcg accounting, no `__GFP_ACCOUNT`, so no aliasing. A17's HintManagerService
(ADPF) is what mmaps ring buffers from boot, which is why the customer hit it at 143 s with a
plain stat(). Upstream never had the bug: ring-buffer memcg accounting (5.11) landed after
`page->memcg_data` replaced the `PG_kmemcg` page_type. The same aliasing applies to
`BPF_F_MMAPABLE` arrays via `bpf_map_area_mmapable_alloc`.

**Fix:** `6c2d4dd8cb5b bpf: do not kmem-charge pages that are mmap()ed to user space (4.19)` —
drop `__GFP_ACCOUNT` from `bpf_ringbuf_area_alloc()` and from the `mmapable` branch of
`__bpf_map_area_alloc()`. Everything non-mmapable stays charged. On `pepito-24-debug-mm` (pushed);
**cherry-pick onto `pepito-24` for the next release** (23.2 unaffected). Built into
`flash-staging/boot.bin` = kernel `-00005-g6c2d4dd8cb5b` (debug + instrumentation + fix,
image_size 44.1 MB, serial on); copy in `held-20261011/boot-debug-mm-fix-6c2d4dd8cb5b.bin`.

**13:15 — fixed kernel `-00005-g6c2d4dd8cb5b` flashed on DUT1** (the earlier "EDL doesn't
work" was wrong: the shutdown for `reboot edl` panicked on this very bug, and the panic reboot
overrode the EDL reason; with the stress stopped first, `flash-staging.sh` without `--no-adb`
went straight through). First results: `fake-buddy-scan.sh` → **0** pages at −511/−510 (vs 13
on the old kernel; a first sample at 2 min uptime showed transient one-offs from the two
/proc reads racing, hence the script now samples twice); ring-buffer pages are now visible to
`page_owner` with mask `0x6286c0` (no `__GFP_ACCOUNT`), still landing in pageblock 782
(`0xc3800`), i.e. exactly the window every hit lived in. Stress re-armed 13:17 on the fixed
kernel; previous hit rate under stress was one per ~70 min.

**Validation plan (was: after the hand EDL):** (1) `fake-buddy-scan.sh` must report 0 pages with
mapcount −511/−510 while system_server has ring buffers mapped; (2) `stress.sh` overnight with
no `*** PANIC` (previous rate: one hit per ~70 min of stress, one per few hours of normal use);
(3) ship `6c2d4dd8cb5b` + `a2980325eb5d` on `pepito-24`, drop the debug commits.

**Side findings from the hunt:** `a2980325eb5d` (userfaultfd memcg ordering) is a real, separate
bug and also belongs on `pepito-24`/`pepito-rmnet`. (The earlier note that `adb reboot edl`
does not work on this DT was wrong — see 13:15 above.)

## 2026-10-13 evening — ✅ FIX SHIPPED to the release branches

Evidence at 18:35 (5 h 16 min after the flash): DUT1 on `-00005-g6c2d4dd8cb5b` had no panic and no
reboot (same boot_id since 13:17), `fake-buddy-scan.sh` = 0 fake buddies with 9 bpf-map mmaps live in
system_server. The stress guard was paused ~175 of 316 minutes (thermal ceiling 48 °C; the hub
charges at only ~430 mA), so the fixed kernel saw ≈2 h 20 min of real stress plus 5 h of normal
uptime, against one hit per ~70 min of stress and two shutdown-path crashes on the old kernel.
Kyle: "pretty solid evidence that we got it. Please cherry-pick."

Cherry-picked with `-x` and pushed to `solarkennedy`:

| Branch | New tip | Commits |
|---|---|---|
| `pepito-24` (24.0 release) | `50c36c782d89` | `521a7e6f19d2` userfaultfd memcg ordering (= `a2980325eb5d`), `50c36c782d89` bpf: no kmem-charge for mmapable pages (= `6c2d4dd8cb5b`) |
| `pepito-rmnet` (23.2 release) | `acbe55ebf525` | userfaultfd memcg ordering only (23.2 has no ringbuf memcg backport) |

Both applied without conflict; the 23.2 patch differs from the 24.0 one only in a `mm/shmem.c` hunk
offset. The three debug commits (`7060b4f60ae3`, `cdbfe31dac58`, `c071078ebd6c`) stay on
`pepito-24-debug-mm` only. The next 24.0 release build picks up `pepito-24` automatically
(`manifests/pepito.xml` is back on `revision="pepito-24"`). Neither release branch has been
test-built since the cherry-pick; the identical code was built and run as `-00005-g6c2d4dd8cb5b`.

Still running: `stress.sh` on DUT1 overnight for the long-run confirmation; DUT1 keeps the debug
kernel until the next release flash. new2 is still on the broken `gbe4fe4036389` kernel.

**2026-10-14 13:43 morning check — ✅ CLEAN.** DUT1 uptime 17 h 27 min on `-00005-g6c2d4dd8cb5b`,
same boot_id as the 13:17 flash boot, pstore holds only the pre-flash boot's log (old kernel
`ga2980325eb5d`: 18 × `BUG: Bad page map in process lmkd` during the EDL shutdown — banked in
`results/pstore-preflash-boot-a2980325eb5d-badpagemap/`; the watcher's pattern does not match
"Bad page map", which is a warning, not a panic). Stress log: 715 active minutes (≈12 h) + 548
paused minutes; load average 59 at check time. Old kernel: one hit per ~70 min of this. Scan: 0
charged+mapped fake buddies with 9 bpf-map mmaps live. (`fake-buddy-scan.sh` now classifies by
mapcount −512..−129; under this load the raw flags/count race produces ~1500 mapcount-1 churn pages,
which are not the bug.) Lane closed pending the release build.

## Next steps

1. ~~Morning check~~ done 10-14, clean. **Lane CLOSED 2026-10-14 06:50** per Kyle; stress stopped
   (watcher, device workers, screen-stayon off). DUT1 left running the debug kernel
   `-00005-g6c2d4dd8cb5b` with serial console on, uptime 17 h 34 min at close.
2. Release 24.0 with `pepito-24` ≥ `50c36c782d89`; mention the panic fix in the changelog. Tell the reporter.
3. Flash new2 to the release kernel when convenient (it still panics every few hours of use).
