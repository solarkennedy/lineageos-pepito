# LineageOS 23.2 — Radio / Telephony / Modem (pepito/PVG100) — converge-on-working-4.19 era

> **Started 2026-07-06 (session `radio8`).** Supersedes `PLAN-radio.old2.md` (the RFSA/QRTR
> bring-up era, radio1–radio8) and `PLAN-radio.old.md` (the original era). Read those only for
> historical evidence — their central thesis (modem needs in-kernel RFSA svc 28; gate is
> "modem-internal", disassemble the MPSS) was **falsified**. Control-plane work in the archive
> is still valid. Sibling `PLAN-radio-compat.md` (HIDL→AIDL shim) is downstream of a healthy modem.

---

## ⏭️ NEXT SESSION — START HERE (reset `radio14`, 2026-07-07 — big-picture review with Kyle)

> **⚡ STRATEGIC PIVOT (session `qmux`, 2026-07-07, Kyle's call): the primary lane is now the
> legacy IPC-stack backport — see `PLAN-qmux.md`.** P0 below survives as that plan's Phase 0
> gate (run it FIRST). The guardrail "do NOT port `msm_ipc_router`" is formally REVERSED.

**Strategic reset: the Ghidra/RE lane is PARKED (Kyle's call). Rationale: radio13's "AP-side
hypothesis space FULLY CLOSED" only closed the *static* space (SMEM/SMSM content, announcement
tuples, channel sets, hosting entity). Two black-box controls were never run, and both are
cheaper and more decisive than decoding QSR4-obscured Hexagon:**

> **⚡ UPDATE radio14 (2026-07-07): P2 RAN and is DECISIVELY NEGATIVE — see P2 section.** On the
> wire, the modem issues ZERO NEW_LOOKUP for the buffer service even under 267 RFSA re-announces,
> while announcing its own services fine → it fails BEFORE any QRTR bus discovery (confirms
> radio10's pre-wire `Smem_get_buffer`). **The AP QRTR presentation is NOT the gate.** This
> collapses the "dynamic dialogue" thread (#2 below) as a *fix* lever — the modem doesn't consume
> the buffer service over the bus at all. **P0 (stock-on-DUT / EFS-NV) is now the primary open
> lever**, with the SMEM-content lane (what `Smem_get_buffer` reads modem-internally) behind it.
> P1's dialogue capture is now diagnostic-only (nice-to-have), not on the critical path.

1. **The unit confound.** Every stock-vs-pepito comparison in radio1–13 is CROSS-UNIT
   (A11 `81eed371` vs A16 `c39a6acf`), yet this plan itself flags the buffer method as
   "plausibly OEM-build/**NV-configurable**" (Caveat section below) and never treated per-unit
   NV/EFS as a variable. Nobody has shown the DUT's own modem+NV take the RFSA path under stock.
   (PLAN-diag.md "Reference track" designed exactly this excursion 2026-07-05; it was never run
   to the decisive observable. Kyle recalls an A11 flash on the DUT that "loaded the right
   thing" without a full boot — no record found in any PLAN/memory, and it cannot have captured
   `rfsa_req`.)
2. **The dynamic dialogue.** Nobody has captured the healthy 3.18 control-plane *conversation*
   (message set / order / pacing at modem HELLO) and diffed it against our bespoke <1ms
   38-message replay burst. All stock-side evidence so far is static (dump_servers snapshot,
   rfsa_req counter, masked F3). NOTE the radio12 "replay revert = NEUTRAL" result does NOT
   validate the replay — no-replay and broken-replay are indistinguishable (the exact fallacy
   radio8 was corrected for, see "⚠️ CORRECTED" below).

### P0 — Stock-on-DUT modem health check (kills the unit confound; one flash round-trip)
The cleanest possible A/B available in this whole project: the DUT's modem partition + NV/EFS
have never been reflashed (`mmcblk0p1` untouched), so booting stock on `c39a6acf` runs the EXACT
same modem binary + device data with only the AP software changed.
- **Kyle:** back up current LOS state as needed, flash stock (same recipe as `81eed371`: stock
  boot+vendor, A11 GSI on top) onto `c39a6acf`. A full UI boot is NOT required — only
  rmt_storage + modem need to come up.
- **Validate (adb):** mount debugfs → `cat /d/rmt_storage/info` → **Request count ≥ 1**, no
  `rmts_get_buffer api failed`. Optionally cycle per_mgr and watch it increment. Note it's the
  kernel-RFSA debugfs (`/d/rmt_storage/`) on 3.18, same as on the A11.
- **Fork:**
  - **Healthy** → unit's NV/EFS is fine; the gate is genuinely our AP software. Bonus: run P1's
    stock captures on THIS unit while it's stock (identical NV to every later pepito test),
    then reflash back to the LOS build for P2.
  - **Fatal** → the modem's data-dependent branch keys on *device-local* state (EFS/NV), not
    anything the AP presents; ALL AP-side work is moot → pivot to EFS/NV diff/repair against
    `pepito-stock-backup-20260706`.

### P1 — Healthy-dialogue capture (stock side; zero builds)
Goal: the healthy NEW_SERVER/table-sync dialogue — who sends what, in what order, how many
services, what pacing — as the converge-target for P2. Diff against pepito's qrtr_0 ipc_logging
capture (radio13, 6 cycles, already decoded).
- **Lane A — the modem's own view (NEW; reads what Ghidra was hunting, off the wire instead):**
  `qdsp6m.qdb` contains F3 instrumentation for the modem's **`ipc_router_core.c` at ssid 500**,
  including the receive-path drop errors ("`illegible message received`", "`control message too
  short`", "`Unexpected msg of size %`", "`register server %u:%u failure`", "`Xport cannot
  receive`"). Kyle's verbose mask (`Diag.cfg` = SET_ALL_MSG_MASK rt_mask 0xFF) already enables
  all ssids. Re-run the radio9 recipe (`HOWTO-modem-diag-capture.md`) across per_mgr cycles on
  the stock phone; **widen `decode_rmts.py`'s filter beyond rmts_api.c** to ssid 500 + QCCI
  files. Check first whether radio9's qmdl output dirs are still on the A11's storage — the
  verbose captures were never copied to the laptop (only the strace is in `diag-tools/captures/`).
- **Lane B — the AP's view:** 3.18 has legacy debugfs — look for `/d/ipc_logging/` contexts
  (ipc_router, `*_smd_xprt`) and `/d/ipc_router*` on the stock phone; dump across a per_mgr
  cycle. This gives the AP-side control-message sequence natively (msm_ipc_router's table sync
  at HELLO — the thing our replay hack emulates).

### P2 — Replay-shaping experiment — ❌ RAN 2026-07-07 (radio14), DECISIVELY NEGATIVE → P2 DEAD, lever is P0/SMEM
**Result: the whole P2 hypothesis class is falsified. The modem never issues a NEW_LOOKUP for the
buffer service, so no amount of NEW_SERVER shaping (timing/pacing/pruning/ordering/re-announce)
can matter — the modem fails BEFORE any QRTR bus discovery.** This confirms radio10's pre-wire
`Smem_get_buffer` conclusion on the wire and redirects effort to P0 (stock-on-DUT / EFS-NV) and
the SMEM-content lane.

**The decisive capture (V1 re-announce + qrtr_0 ipc_logging, artifact
`diag-tools/captures/qrtr_v1_reann_20260707.log`):** with `reann_svc=0x1c` armed, an `echo restart`
modem SSR was captured by continuously draining `/d/ipc_logging/qrtr_0/log` (200×50ms). Over the
5s active window the AP sent the modem **267 NEW_SERVER(0x1c) announcements** (`TX CTRL cmd:0x4
SVC[0x1c:...]`) — Request count stayed **0**, fatal identical. Modem egress across two boot
attempts in-window: only `cmd:0x4 SVC[0x2b:0x1202]` (the modem announcing its OWN service — proves
its QRTR stack came up) and `cmd:0x6` DEL_CLIENT churn. **ZERO `cmd:0xa` NEW_LOOKUP from the modem
for ANY service; zero RX reference to svc 0x1c or its port.** So even while (a) being bombarded
with 267 RFSA announcements and (b) successfully announcing its own services, the modem never asks
the bus for the buffer provider. It dies in `rmts_get_buffer` before any bus lookup.

**Why V2/V3 were NOT run (logically moot, not skipped for cost):** V2 (stock-shaped allowlist +
pacing) and V3 (ordering) all vary HOW the NEW_SERVER set is delivered. Since the modem issues no
NEW_LOOKUP for the buffer service under any condition, delivery shaping cannot change the outcome —
there is no dialogue shape to find. radio13's "0x1C not retained in the modem's server table" is
real but **irrelevant to the fatal**: the modem never queries that table for the buffer path (it
takes the SMEM-first branch and dies there, radio10).

**Method notes for the archive:** `echo restart > /d/msm_subsys/modem` boots the modem in ~1s
(HELLO+reann land in-window) but wedges the MSS after a few rapid cycles (Port halt timeout →
reboot to recover; per_mgr voter cycle can NOT recover a halt-wedged modem). The graceful per_mgr
cycle (`ctl.restart vendor.per_mgr`) is robust but SLOW (~14s to powerup) so it overshoots a short
capture window. Capture recipe that worked: arm knob → drain qrtr_0 → background a 200×(drain +
`sleep 0.05`) loop → `echo restart` 1s in → analyze RX CTRL. Tool `qcap.sh` pattern in scratch;
`qrtr-list` on A16 confirms 0x1c is a live local server (`0x1c 0x101 node 1`).

---

#### (superseded) original P2 staging notes — ✅ STAGED 2026-07-07 (radio14), awaiting build+flash
Hypothesis class: the modem retains NEW_SERVER(0x1C) only under dialogue conditions our one-shot
<1ms 38-message HELLO burst violates (ordering / pacing / ctrl-queue overflow / arrival-vs-
client-init window). Consistent with ALL standing evidence: Ghidra proved the insert is
filterless-verbatim *once reached*, and the buffer-path client retries ~10× (−3 timeout) before
fatal — so a re-announce landing mid-retry-window should be picked up on a later retry.

**Staged commits (kernel `pepito-bringup-lineage-23.2`, compile-verified `net/qrtr/qrtr.o`
clean with mi8937_defconfig + clang-r574158):**
- `206a5ff44239` — Reapply "synchronous HELLO reply + local-server replay" (⚠️ HEAD had it
  REVERTED via radio12's `e50d43f2caf2` — yet radio13's flashed build clearly replays 38
  NEW_SERVER, so local HEAD ≠ flashed build. This branch is now the single source of truth:
  replay is back IN, with knobs. **Sync this exact HEAD to Stellaris16 before building** —
  the known local-vs-build-server divergence gotcha.)
- `c3c02d85c64d` — the knobs. debugfs `/sys/kernel/debug/qrtr_replay/`: `delay_us` (pacing),
  `allowlist` (comma list of svc ids, hex ok, empty = all), `first_svc` (ordering),
  `reann_svc`/`reann_inst`(=0x101)/`reann_interval_ms`(=10)/`reann_duration_ms`(=5000)
  (periodic re-announce to the last-HELLO node, armed per-HELLO i.e. per-SSR), `stats`
  (replay_last_sent/skipped, reann_sent, cache_cnt). **Defaults = pre-knob behavior**, so cold
  boot is unaffected; deviation from original spec: re-announce stops on the duration deadline
  only (no auto-stop-on-RFSA-DATA — rfsa_req is the success signal anyway). Re-announce runs on
  its own ordered workqueue (a blocking send to a zombie modem parks only that worker; kernel-
  context sends only, per the userspace D-state gotcha). Replay now snapshots the cache and
  sends outside the lock so pacing can't stall qrtr_sendmsg tracking.

**Run recipe (per variant: set knobs → SSR → read observables; no reflash):**
```sh
mount -t debugfs debugfs /sys/kernel/debug   # gotcha: mount manually first
cd /sys/kernel/debug/qrtr_replay
# V1 — re-announce alone (sharpest: tests the retention window directly):
echo 0x1c > reann_svc                        # 0 disables again
echo restart > /d/msm_subsys/modem
cat stats /d/rmt_storage/info                # expect reann_sent ~40+ per window
# V2 — stock-shaped table (+ optional pacing):
echo 0 > reann_svc; echo "0xe,0x1c" > allowlist; echo 2000 > delay_us
# V3 — ordering only:
echo "" > allowlist; echo 0 > delay_us; echo 0x1c > first_svc
```
- Observables per SSR: `stats` (did the shaping actually apply), qrtr_0 ipc_logging / kprobe
  `qrtr_endpoint_post` (wire truth), `/d/rmt_storage/info` **Request count** (the win
  condition), fatal line via smem-id-421 SFR auto-log.
- First validation after flash, BEFORE variants: default-knob SSR → confirm `stats`
  replay_last_sent ≈ 38 and fatal unchanged (baseline sanity; also confirms this build replays
  at all, resolving the HEAD-vs-flashed ambiguity above).
- Any variant that makes rfsa_req tick names the root cause → then MINIMIZE to the single
  sufficient deviation and keep that as the permanent fix.

### PARKED (Kyle, 2026-07-07): the RE lane
Ghidra receive-path decode (`FUN_87559fdc`→`FUN_8755af70`) and the `DAT_88e5c760` live-read are
parked; resume ONLY if P0–P2 all come back dead. This also resolves the plan's self-contradiction
(standing guardrail "do NOT resume Hexagon disassembly" vs radio13 next-step #1) in favor of the
guardrail. The Ghidra project + scripts remain intact (see "Tooling to reuse" below).

---

## radio13 evidence (kept for reference — the settled facts below still stand)

**radio13 ran the radio11 "next step" A/B and closed two of its three threads. Net: the AP side is
byte-identical to stock in *static* content; the working model is modem-internal QCCI cache
population over QRTR (unverified against modem memory — see radio14 caveats above).**

### What radio13 SETTLED
1. **On-device A/B DONE — instance-encoding hypothesis FALSIFIED on the wire.** Rebuilt the wiped
   qrtr-services as `diag-tools/qrtr-list.c` (freestanding arm64, no libc; binary on A16
   `/data/local/tmp/qrtr-list`). Dump on A16 `c39a6acf`:
   - **RFSA svc 0x1C → `inst 0x101, node 1`** — *byte-identical* to stock A11's radio9 dump_servers
     (`0x1c | inst 0x101 | node 1`). Decodes to instance 1, exactly what the modem's matcher wants.
   - **RMTFS svc 14 (0xe) → `inst 0x1, node 1`** (version 1, instance 0; userspace rmt_storage).
   So the RFSA announcement encoding is *correct and stock-identical*. The "instance/node
   mismatch" idea this A/B existed to test is dead. (Stock A11 can't run qrtr-list: 3.18 phh GSI
   uses `msm_ipc_router`/AF_MSM_IPC, not AF_QIPCRTR(42) → `socket() -97`; use radio9's recorded
   stock tuple.)
2. **radio11 candidate (b) [`param_1[0x2d]` gate] ELIMINATED by decompile + observation.**
   Re-decompiled `rmts_get_buffer` (`FUN_87602d40`) and the prep fn `FUN_87603290`: byte **0x2d**
   of the rmts client context is the *"multi-partition rmts / use-shared-buffer"* flag — it drives
   BOTH (a) the loop over `PTR_s__boot_modem_fs1_882065d0` that opens the 6 EFS partitions
   (modem_fs1/fs2/fsg/fsc/rfnvbak) AND (b) entry into the RFSA buffer path. Since the modem
   *provably opens all those EFS partitions* over RMTFS svc 14 (radio8: 140 OPENs of exactly those
   paths), **byte 0x2d MUST be 1** on pepito ⇒ the RFSA path IS entered, not skipped. So the sole
   surviving radio11 candidate is **(a): `qmi_client_init_instance` for RFSA svc 0x1C fails its
   local service-cache lookup** (−3 timeout ×10 → fatal), which reads a local cache (no wire
   traffic — matches radio10).
3. **Matcher chain fully decoded.** `qmi_client_init_instance` (`FUN_87560db0`) →
   `get_service_list` (`FUN_87560bd0`): reads the service list into **20-byte (0x14) entries** and
   compares **entry byte[+2] == requested instance (1)**. The list is built by **`FUN_8755fb40`**,
   which iterates a **runtime QMI service-source registry** (`DAT_88e5ca1c`, count `DAT_88e5ca10`,
   lock `DAT_88e5ca00`), calling each source's **vtable+0xc enumerate-callback**. RFSA-not-found ⇒
   no registered source yields svc 0x1C @ inst 1 in the modem's cache.

### BOTH radio13 sub-tracks RAN (2026-07-07) — they CONVERGE: gate is modem NEW_SERVER→table RETENTION for 0x1C
Two agents ran in parallel; results reconcile with no contradiction.

**Static (Ghidra) — the modem's service-cache code has NO bug; the entry is never RETAINED.**
- QRTR/IPC-router CCI xport `ops` vtable = **`0x887523e8`**; enumerate-callback (the one `FUN_8755fb40`
  invokes) = **`FUN_87e8dd60`**. It packs **entry byte[+2] = (stored_instance >> 8) & 0xff** (and
  byte[+1]=version=instance&0xff). RFSA wire 0x101 → byte[+2]=1 → *matches*; RMTFS 0x001 → byte[+2]=0.
  Packing provably correct, identical for both — a structural invariant (matcher `FUN_87560bd0` and
  this enumerate only interoperate with instance in bits[15:8], which is why every instance>0 QMI
  service resolves on this shipping binary).
- Insert = **`FUN_8755af70`** (← `FUN_8755a010` ← notify chain `FUN_87559fdc`/handler `FUN_87e8de50`)
  into a **32-bucket hash `DAT_88e5c760`** (bucket=`service&0x1f`, lock `DAT_88e5c740`). It stores
  `{service,instance,addr,port}` **verbatim, NO service-id filter/range check**. Lookup `FUN_8755b800`
  is generic (matches `node[0]==service` + version mask `0xff & (qver^nver)==0`).
- ⇒ RFSA yields zero servers ONLY because **bucket 0x1C of `DAT_88e5c760` holds no node at query
  time** — NEW_SERVER(0x1C) was never *retained*, not filtered. Runtime table-population gap,
  upstream of all the cache code.

**On-device (qrtr_0 ipc_logging, 6 cycles) — AP delivery is PERFECT and SYMMETRIC.** Each cycle the
AP kernel HELLO-replay broadcasts 38 NEW_SERVER to the modem in one <1ms burst containing BOTH
`SVC[0xe:0x1]→0x4033` and `SVC[0x1c:0x101]→0x404c` (135µs apart, same node, ports == local ns DB),
~50–135ms **before** the fatal. Same announcer (kernel, no comm — not a qrtr-ns-vs-replay split),
same timing. **Modem emits ZERO NEW_LOOKUP (from anyone) and ZERO DATA to the RFSA port 0x404c**,
yet drives 5 RMTFS transactions to 0x4033 from the SAME burst, then fatals. No DEL_SERVER of 0x1c.

**Reconciled root cause (working vs broken, one line):** the modem **receives** NEW_SERVER(0x1C) on
the wire (proven) but does **not retain** it in its own server table `DAT_88e5c760` (proven the code
has no filter), while the sibling 0xE from the *identical burst* lands and is used. Since the modem
takes NO NEW_LOOKUP and still retains 0xE unsolicited, it *does* accept unsolicited NEW_SERVER — so
the divergence is a **data-dependent step in the modem's NEW_SERVER receive→insert path keyed on
something specific to the 0x1C announcement** (candidate: the instance field 0x101 vs 0x001, or a
parse quirk in the QSR4-obscured `FUN_87559fdc`/`FUN_8755acf0`). radio5 already showed announcing
RFSA at instance 0x1 also failed — but that test is confounded (the modem's RFSA client asks for
instance 1, so byte[+2] must be 1 to match; announcing at inst 0 breaks the matcher regardless).

### radio13's ranked next steps — SUPERSEDED by radio14 P0–P2 (RE lane parked); kept for the record
1. **(static, Ghidra) Fully decode the NEW_SERVER receive→insert path** `FUN_87559fdc` → `FUN_8755a010`
   → `FUN_8755af70` and its field parse `FUN_8755acf0` (the one obscured by QSR4 register-arg loss) —
   looking for a **data-dependent accept/drop condition** that could reject the 0x1C NEW_SERVER
   (instance high-byte handling, addr/port validation, per-service dedup). This is the one static
   hop that can still name the bug without modem memory.
2. **(decisive but BLOCKED) Read `DAT_88e5c760` on a live modem** — walk 32 bucket heads at
   `(&DAT_88e5c760)[i*3]`, follow `node[+0x18]`=next, read `node[0]`=service; a 0x1C node present on
   stock A11 / absent on pepito confirms the retention gap. Needs modem memory: XPU ramdump=zeros,
   diag build-masked → the standing wall. (Lock `DAT_88e5c740` if live.)
3. **(residual, static) Version mask** — if a 0x1C node ever IS present, check the low-byte version
   the AP publishes for RFSA vs what the modem's `rfsa_service_obj` client requests (`FUN_8755b800`
   filters on `0xff & (qver^nver)`). Low odds (both announce version 1) but cheap once #1 is read.

**Tooling to reuse:** Ghidra project `…/7d648fc4-…/scratchpad/ghidra/proj/mpss` (survived, 916M,
fully analyzed; GP set/saved; scripts in `…/ghidra/scripts/`, incl. new `decomp_at.java`,
`refsdump.java`). Query: `analyzeHeadless <proj> mpss -process modem.elf -noanalysis -scriptPath
<dir> -postScript <s>.java <hex,args>`. Ghidra at `/home/kyle/Projects/ghidra_12.1.2_PUBLIC`.
qrtr-list: source `diag-tools/qrtr-list.c`, prebuilt on A16 `/data/local/tmp/qrtr-list`.

---

## North star (the whole strategy in one line)

**Do what the official LineageOS Mi8937 build already does — it works.** santoni/land/ugg/prada
run **official LineageOS (thru v21) on the same 4.19.325 kernel, the same unified `Mi8937` tree,
and the same modem variant** as pepito, with working telephony (official builds require it).
pepito is a hand-grafted bring-up (`pepito.dts` isn't even upstream). So the modem fatal is a
**pepito-specific deviation** from a known-good config — find and remove the deviations, don't
invent new mechanisms.

### Evidence this is the right frame (2026-07-06, verified)
- Official `android_kernel_xiaomi_msm8937` branch `lineage-23.2` = kernel **4.19.325** (== ours;
  we forked it as `pepito-bringup-lineage-23.2`).
- All six official `Mi8937` wiki variants (santoni/Redmi 4X = variant4, Redmi 3S/3X/4, Note 5A
  Prime, Y1 Prime) list kernel **4.19**, LineageOS thru **21**, telephony working.
- Modem is the **unified family image** `8940.gen.prod / MPSS.TA.2.3.C1` — confirmed from
  santoni/ugg/prada `NON-HLOS.bin` on Stellaris16. pepito's build (`-214411`, Palm `WS241`) is
  *newer* than santoni (`-184176`) / ugg (`-190122`). Same SoC, same modem, same kernel, same tree.

### Caveat (radio9 review) — there are TWO known-goods, and only one shares our modem
"Converge on official Mi8937" validates the **AP side** against **Xiaomi** modem builds. The one
component pepito can never converge is the modem image itself: Palm `-214411 WS241` is a
*different OEM's build* of the family image, and the `fs_rmts` buffer-acquisition method is
plausibly OEM-build/NV-configurable. So use both ground truths for what each is good for:
- **stock A11 (`81eed371`)** = the ONLY known-good sharing this exact modem build + NV/EFS →
  ground truth for "what does THIS modem do when healthy" ([[two-device-methodology]]).
- **official santoni 4.19** = ground truth for "what must the 4.19 AP side look like".

## Current status (2026-07-06, post-reset flash)

**The fatal still reproduces**, unchanged:
```
fs_device_efs_rmts.c:161:[6 ,1572864, -1996169536] EFS: rmts_get_buffer api failed
```
`1572864 = 0x180000` (1.5 MiB buffer), `-1996169536 = 0x890C0000` (inside modem_mem —
treat as a cookie, not necessarily "the address used"). `modem state=ONLINE crash_count=21`
(post-fatal zombie; the panic-survive patch absorbs it).

### Deviation #1 — RFSA re-port — REMOVED (done; necessary, not sufficient)
The tree had re-added the 3.18 `sharedmem_qmi.c` (RFSA, svc 28) + a hook in `msm_sharedmem.c`,
on the wrong assumption 4.19 had "dropped" it. **Official 4.19 `drivers/uio/msm_sharedmem/` is
`msm_sharedmem.c` only.** Reset staged + flashed: driver + Makefile reverted to official
byte-for-byte; kept the working `@0` uio buffer node (`/dev/uio0 "rmtfs" @ 0xf7300000`).
**Result: RFSA gone (rmt_storage debugfs absent, no svc 0x1c) but the fatal is IDENTICAL.**
> **⚠️ CORRECTED (radio9, same day):** "identical fatal without RFSA" only proved the *flashed*
> RFSA wasn't being consumed — it does NOT prove RFSA is unneeded (broken-present and absent are
> indistinguishable to the modem). The A11 discriminator below proved the Palm modem REQUIRES
> RFSA. The removal was a useful falsification step, now reversed: RFSA re-add staged.

## The 4.19 buffer mechanism — SOLVED (session `radio8`, 2026-07-06, no reboot needed)

**The buffer path on 4.19 is: modem → `QMI_RMTFS_ALLOC_BUFF` over RMTFS (svc 14) → userspace
`rmt_storage` replies with the `/dev/uio0` address.** No kernel RFSA is involved anywhere.
Proven by analyzing pepito's own running `/vendor/bin/rmt_storage`:
- `rmt_storage_alloc_buff_cb` + `"Alloc buffer request structure doesn't match expected size
  %u != %zu"` → it **implements the ALLOC_BUFF handler** (serves the buffer to the modem).
- `/dev/uio%u`, `/sys/class/uio/uio%u/maps/map0/addr`, `Mmap Failed for rmts` → it reads the
  `msm_sharedmem` UIO buffer from sysfs and mmaps it itself.

Consequences (big):
- **The RFSA removal was CORRECT and did not break anything** — `rmt_storage` never needed RFSA;
  it is the mainline-style, self-contained buffer server. Mechanism (2) is the real one;
  candidate mechanisms "fixed carveout" and "hyp_assign grant" are NOT how this works.
- **`hyp_assign` failing is genuinely benign** (re-confirmed): the buffer is delivered by value
  over QMI, not by granting the modem access to the AP address. (Consistent with stock-3.18
  working despite the same TZ refusal.) Do not chase `hyp_assign` — de-prioritized again.
- **The AP side is fully ready this boot:** `rmt_storage` mmap'd the buffer (no "Mmap Failed"),
  registered the service (modem file OPENs go through), alloc-buff callback armed. It is
  *waiting* for the modem to ask.

## The blocker — H1 CONFIRMED (2026-07-06, session `radio8`, captured on the wire)

**The modem never sends `ALLOC_BUFF`.** Captured `rmt_storage`'s QMI service socket live during
active modem crash-cycling (this boot the cycling ran late, uptime 234–301s; the boot hook
attached at 236s, right in the window). Decoded every inbound QMI msg_id on the socket:

| msg_id | RMTFS message | count |
|---|---|---|
| `0x0001` | **OPEN** (`/boot/modem_fs1`, `fs2`, `fsg`, `fsc`, `rfnvbak`) | **140** |
| `0x0004` | **ALLOC_BUFF** (request the transfer buffer) | **0** |
| `0x06` (QRTR ctrl) | DEL_CLIENT (crash-loop port churn) | 159 |

So the modem opens its EFS files over RMTFS(14) but **never asks `rmt_storage` for the buffer**,
then fatals on `rmts_get_buffer`. `rmt_storage` is ready and armed (`rmt_storage_alloc_buff_cb`);
the request simply never comes. **H2 is ruled out** — there's no ALLOC_BUFF to reject, so the
`"structure size mismatch"` string is irrelevant here.

## The question now (H1 → why) — two worlds, one discriminator (radio9 review)

The modem's `fs_rmts` layer isn't selecting the ALLOC_BUFF buffer-acquisition method at all.
Two live hypotheses — and note our RFSA falsification does **NOT** distinguish them
(*broken-RFSA-present* and *RFSA-absent* both end in the identical fatal with zero ALLOC_BUFF):

- **World A** — the Palm modem DOES use ALLOC_BUFF when healthy; some **AP-presented boot input**
  on pepito-4.19 stops it from asking → the deviation hunt vs santoni is correctly aimed.
  Candidates: service set announced at the decision moment; RMTFS(14) registration params
  (version/instance encoding); SMEM/boot-env item (old radio6 lane, now with a concrete target).
- **World B** — the Palm modem build acquires the buffer by a **different method** (RFSA
  GET_BUFF_ADDR, an SMEM-published address — whatever stock 3.18 actually serves), never sends
  ALLOC_BUFF anywhere, and the 3.18→4.19 port of *that* method is what's broken. Then
  "converge on santoni" breaks for the buffer path (Xiaomi's modem builds ≠ Palm's) and the
  target becomes "replicate stock Palm's buffer mechanism on 4.19".

### ⚡ DISCRIMINATOR RAN 2026-07-06 (radio9) — **WORLD B CONFIRMED, read-only, no SSR needed**

Evidence chain, all gathered live on the stock A11 (`adb root` works; phh GSI, kernel 3.18.71):
1. **Stock announces RFSA svc 0x1c** — `dump_servers`: `0x1c | inst 0x101 | node 1 (apps)`.
   That's kernel `sharedmem_qmi` (vers=1, inst=1 → IPC-router encoding 0x101).
2. **`/d/rmt_storage/info`** (kernel sharedmem_qmi debugfs): client `rmtfs` id 1, buffer
   `0x180000` (== the fatal's size) @ `0xF7100000` dynamic, **`Request count: 1`** — source
   (stock GPL `sharedmem_qmi.c:119`) increments ONLY in the RFSA GET_BUFF_ADDR handler. Modem
   `crash_count=0` → exactly one modem boot ↔ exactly one GET_BUFF_ADDR served.
3. **Stock `rmt_storage` blob CANNOT be the requester**: `strings` shows uio-sysfs reading +
   `rmt_storage_alloc_buff_cb` (same design as the 4.19 blob), **zero RFSA client code**;
   live process has `/dev/uio0` open + 0x180000 mmap'd. → The requester is **the modem**.
4. Bonus: the radio4-era `stock_ssr.sh` never actually restarted the modem
   (`/d/msm_subsys/` doesn't exist on stock; no PIL lines in its dmesg) — its "no ALLOC_BUFF
   traffic" strace was a no-op artifact, not evidence. No sysfs SSR trigger exists on stock.

**Conclusion: the Palm modem's `rmts_get_buffer` = RFSA GET_BUFF_ADDR (svc 28).** Xiaomi's
modem builds use ALLOC_BUFF (hence official 4.19 needs no RFSA); Palm's build uses RFSA.
The radio8 "phantom" verdict is REVERSED — removing RFSA was converging on the wrong ground
truth. **Honesty note:** radio4 had ALREADY measured stock `Request count: 1` and radio5 had
kprobe-proven the announcement reaches the modem yet elicits nothing
([[radio-rmts-buffer-rootcause]] middle sections — radio8's reframe discarded that evidence).
So the re-add is **necessary but known-insufficient alone**; the live mechanism question is
radio7's QShrink find: modem `rmts_api.c` has TWO impls — `Smem_get_buffer` ("SMEM Kernel
Service", L624-668) and `Get_buffer` (RFSA, L704-828) — and on pepito the selection/client-init
fails pre-wire. radio9 adds: memshare svc 0x34 inst 0x101 is announced on BOTH stock and A16
(symmetric), so simple SMEM-service-presence diff is ruled out too.

### RFSA RE-ADD — STAGED 2026-07-06 (radio9), awaiting build+flash
- `Makefile`: `+ sharedmem_qmi.o remote_filesystem_access_v01.o`
- `msm_sharedmem.c`: hook reconstructed to mirror stock byte-for-byte semantics
  (`sharedmem_qmi_init()` **before** `platform_driver_register` in module init;
  `sharedmem_qmi_add_entry()` in probe after `dev_set_drvdata`; `sharedmem_qmi_exit()` on exit).
- The 4 orphaned re-port files audited vs stock GPL: EI tables / msg id 0x0023 / TLVs
  (req 0x01,0x02; resp 0x02 + opt 0x10 addr) / registration triple (28,1,1) all faithful.
  `pepito.dts` already has `qcom,client-id = <1>` (== `MPSS_RMTS_CLIENT_ID`). Compiled fine in
  the radio5–7 era, so no build risk expected.
- **Change ONE variable**: do NOT revert qrtr.c/smsm.c in this same build (earlier convergence
  advice superseded by World B — those reverts would confound this test).

### Post-flash validation checklist (expectation-managed: radio5 says count will likely be 0)
1. `dmesg | grep sharedmem` → expect "RFSA sharedmem_qmi service registered" EARLY, no errors.
2. `qrtr-services` → svc `0x1c` visible, instance 0x101 (kernel wire-encodes `version|inst<<8`).
3. After modem boot attempts: `cat /d/rmt_storage/info` → **Request count** fork:
   - **count > 0, fatal gone** → done; radio moves to control-plane/[[PLAN-radio-compat]].
   - **count > 0, fatal persists** → modem reached us but reply unusable → audit reply encode
     (dmesg "Error sending get_buffer response"?) / address acceptability (0xf7300000).
   - **count == 0, fatal persists** (the radio5-era result, most likely) → announcement
     delivery is NOT the issue (radio5 kprobe: modem receives NEW_SERVER(0x1c) pre-OPEN at
     both 0x101 and 0x1 encodings, sends zero GET_BUFF_ADDR / zero NEW_LOOKUP) → go to the
     surviving-hypotheses lanes below.
4. dmesg for handler pr_errs: "Unknown client id" (DT client-id mismatch), "get_buffer failed".

### Surviving hypotheses for count==0 (post-radio9 ranking)
- **S1 — Smem-first, no fallback:** modem runs `Smem_get_buffer` before `Get_buffer` and on
  pepito its outcome differs from stock in a way that skips the RFSA fallback. What "SMEM
  Kernel Service" resolves to is unknown (NOT simple memshare-presence — svc 0x34 inst 0x101
  announced on both phones, radio9).
- **S2 — modem QCCI table-match failure for svc 28 specifically** (announcement consumed but
  client-init fails pre-wire; rc invisible without diag).

### New evidence lanes (both use the healthy A11 — its diag WORKS, unlike A16's)
- **L1 — stock F3/diag capture of the healthy selection sequence**: A11 `/dev/diag` is live
  (rmt_storage even holds it open). Capture modem F3 logs across a modem boot (or from the
  ring), decode with the `qdsp6m.qdb` pipeline (radio7 asset) → expect L628 "SMEM Kernel
  Service not found/found" then L704+ "Requesting Shared buffer of size %d" → pins the
  selector ORDER + the rc values stock produces. Then we know exactly which predicate pepito
  must satisfy. (No SSR trigger exists on stock — capture at natural boot via boot-time diag
  logging, or find modem restart via airplane-mode/AT.)
- **L2 — userspace RFSA server experiment on pepito** (only untested announcement variable):
  host svc 28 from a userspace QRTR socket (mimics RMTFS's announcing-entity, which the modem
  demonstrably consumes) serving GET_BUFF_ADDR with the uio address. Cheap daemon; `qrtr`
  userlib pattern exists. Falsifies/confirms "kernel-hosted vs userspace-hosted matters".

## Next actions (priority order, radio9 — post-discriminator)

1. ~~Build + flash the RFSA re-add~~ **DONE 2026-07-06 (flashed, validated).** Result = the
   expected fork: service registered @15.3s (pre-modem), svc 28 inst 0x101 on node 1
   (tuple == stock), device created for rmtfs @ 0xF7300000, benign hyp_assign -99 —
   **Request count: 0**, modem crash_count 15 → zombie ONLINE, fatal unchanged. The AP side
   is now fully serviceable and byte-equivalent to stock's announcement; blocker cleanly
   isolated to modem-side selection (S1/S2). Diagcap hook re-armed post-flash (vendor reflash
   wipes it — re-push `diag-tools/pepito-diagcap.{rc,sh}` after every vendor flash).
2. **L1 stock diag F3 capture** (IN PROGRESS radio9 — pipeline built & validated, boot capture
   pending). Goal: read the healthy A11 modem's own buffer-path F3 to see the branch.
3. ~~L2 userspace RFSA server~~ **DONE 2026-07-06 (radio10) — FALSIFIED. See "L2 COMPLETE"
   section below.** Built `rfsa-userd` (userspace svc 0x1C responder, `diag-tools/rfsa-userd.c`),
   published it in ns + kernel replay cache (userspace port in the svc-28 slot), triggered modem
   SSRs. The modem still sent ZERO traffic to it and fatalled identically. The clean comparison
   (userspace svc 14 works ↔ userspace svc 28 ignored, same hosting) proves hosting-entity is NOT
   the gate. New finding: modem also sends ZERO to memshare (0x34) — the buffer failure is
   PRE-WIRE, in the modem's `Smem_get_buffer` (SMEM-first) branch (S1), not RFSA reachability.
   Next levers moved to the "Next levers after L2" list in the L2 section.

### L1 — qdb decode DONE (static), capture pipeline BUILT (radio9 2026-07-06)
**The buffer path has TWO QMI sub-methods (decoded from `qdsp6m.qdb`, rmts_api.c):**
- `Smem_get_buffer` L624-668: init QMI client for **"SMEM Kernel Service"** → L628 "not found
  %d %d" / L632 "found" → send_msg → L668 "Get_buffer succeeded".
- `Get_buffer` (RFSA) L704-828: L704 "qmi_client_init client=%d" → L706 "qmi_client_init rc=%d
  status=%d" → L719 "Requesting Shared buffer of size %d" → L730 "send_msg_sync rc/status" →
  L775 "xpu-lock success" → L828 "phys-to-virt mapping successful".
- caller `rmts_get_buffer` L1036-1120: L1098 "success" / L1120 "failed %d".
Stock RFSA count=1 ⇒ healthy path is almost certainly **Smem "not found" → fall back to RFSA →
success**; pepito likely does NOT fall back (its SMEM lookup differs). Capture confirms which.

**Capture pipeline (reusable, all in session scratch + `diag-tools/`):**
- `qdsp6m.qdb` (from modem.bin `image/`) is QShrink-4.0: `\x7fQDB`+16B GUID, zlib at 0x40 →
  23MB `qdb.dec`, raw fields `msgid:ss_mask:ssid:srcline:file:fmt` (msgid = field0).
- diag_mdlog `.qmdl` = HDLC frames (0x7e-delim, 0x7d-esc). QSR4 F3 frame: byte0=**0x80**,
  **message-id = LE uint32 at offset 2** (== qdb field0), then args, then the 16B qdb GUID,
  then CRC. Live A11 capture's `diag_qsr4_guid_list.xml` GUID == qdb GUID (079960cf-…) → our
  qdb IS the right DB. Decoder: `scratch/decode_rmts.py qdb.dec <file.qmdl>` (reads offset-2 id,
  filters rmts_api.c/fs_rmts, prints in capture order). Do NOT brute-scan all offsets (tiny
  msgids collide with byte patterns — the 0x80/offset-2 read is exact).
- `diag_mdlog` (`/system/vendor/bin`) works with default mask (captures broad modem F3, incl.
  our target ssids); writes `.qmdl`+guid xml to its output dir.

**Boot-capture hook — ABANDONED after 3 reboots (radio9), pivoted to runtime-SSR capture:**
- Solved seclabel: v1 (no seclabel) → diag_mdlog in restricted domain, denied. v2/v3
  `seclabel u:r:su:s0` (phh su = permissive) → diag_mdlog OPENS `/dev/diag` fine (other domains
  still get `Diag_LSM_Init error=13`). A11 is **Enforcing**; stock DENIES diag_device to nearly
  all domains.
- **The real wall: `diag_mdlog` hard-requires `/sdcard` (→ `/storage/self/primary`) to resolve
  before it honors `-o`; that path isn't up until vold links it at ~20s** (this boot: vold
  linked at 20.01s, diag_mdlog gave up its 30s wait at 19.5s — missed by 0.5s). ~20s is far too
  late for the modem's ~6-11s boot F3 window. `mkdir -p /storage/self/primary` early doesn't
  help (vold owns that link). So boot-race is structurally dead for diag_mdlog.
- **Runtime SSR capture — BLOCKED on the trigger (radio9).** No modem SSR trigger exists on
  stock 3.18: `/d/msm_subsys` absent AND stock `subsystem_restart.c` has NO debugfs write node
  at all (only `trigger_ssr` for video/smp2p-test). PIL driver unbind/bind
  (`pil-q6v5-mss/{un,}bind`) FAILS: unbind shuts modem down but rebind errors `-16` (proxy
  unvote IRQ 435 not freed on unbind → `probe failed`), leaving the modem DOWN (reboot to
  recover — done). Remaining option = craft a diag ERR_FATAL to `/dev/diag` (uncertain bytes).
- **Early-boot capture — BLOCKED by timing across ALL clients.** Modem rmts F3 lands ~6-10s
  (gated behind rmt_storage/modem-diag-channel-open); no diag client is up by then: `diag_mdlog`
  hard-waits on `/sdcard` (vold ~20s); `diag_socket_log` needs a host consumer (adb ~20s);
  `diag_klog` emitted nothing in test. adb/userspace simply aren't up in the ~8s window.

- **User-action SSR: RULED OUT (radio9, Kyle tested).** Airplane toggle, network-mode change,
  engineering menu, SIM pull — NONE restart the modem; it stays `ONLINE`, rfsa_req stays 1. The
  stock modem simply never SSRs short of a reboot. So L1 now needs a crafted diag modem-restart
  command (uncertain) or early-boot logging (blocked) — both grind. → recommend pivot to L2.

### ⚡ L1 BREAKTHROUGH (radio9): on-demand modem restart SOLVED; capture pipeline works; down to the diag mask
**Controlled modem SSR at runtime, NO reboot, NO crash (Kyle's "delay the boot" idea → realized):**
`per_mgr` (`/system/vendor/bin/pm-service`) is the SOLE modem voter (holds `/dev/subsys_modem`).
- `setprop ctl.stop per_mgr` → modem goes OFFLINE **gracefully** (crash_count stays 0).
- `setprop ctl.restart per_proxy` (the missing piece — per_mgr alone won't re-vote) then
  `setprop ctl.restart per_mgr` → modem re-boots → **`rmts_get_buffer` re-runs via RFSA**
  (`/d/rmt_storage/info` Request count increments EVERY cycle — verified 1→2→3→4→5→6). Fully
  repeatable. This is THE tool for capturing modem-boot behavior on the healthy A11.
- No `/d/msm_subsys`, no SSR debugfs, PIL unbind/bind leaks IRQ — but per_mgr cycling is clean.

**Capture pipeline works** (`diag_mdlog -o <dir>`; stop with `diag_mdlog -k` NOT pkill — pkill
loses the unflushed qmdl; don't `rm` the dir while a logger writes). Decoder `decode_rmts.py` +
`qdb.dec` validated: QSR4 frame cmd 0x80, msgid at offset 2 == qdb field0.

**THE REMAINING BLOCKER — diag message mask.** Full census of a clean modem-boot capture: **only
ssid 0** (`apr_memq`) flows, 3773 frames, ZERO ssid 94 (rmts) even across the whole boot. So the
modem's runtime F3 mask has essentially nothing enabled; healthy rmts messages are informational
and masked off. Need `DIAG_CMD_MSG_CONFIG`/`SET_ALL_MSG_MASK` (`7D 05 00 00 FF FF FF FF`,
rt_mask=0xFF fills all levels). Computed the full `/dev/diag` write buffer
(`20 00 00 00 7d 5d 05 00 00 ff ff ff ff ed b2 7e` = pkt_type USER_SPACE_DATA_TYPE 0x20 + HDLC
+CRC-X25) — **but a plain `dd` write gets EINVAL**: `diag_user_process_userspace_data` requires
the writer to hold a registered diag md-session (`diag_md_session_get_pid`≠NULL); a random process
can't set masks. So mask-setting needs EITHER (a) `diag_mdlog -f <Diag.cfg>` with a full-logging
QXDM mask file (diag_mdlog does the session registration — cleanest if a Diag.cfg exists), or
(b) a native diag client that does the DIAG_IOCTL session registration then writes the command.

### ✅ L1 COMPLETE (radio9) — capture capability BUILT; get_buffer branch is build-masked; healthy modem CONFIRMED on RFSA
**Mask solved:** stock `diag_mdlog -f <Diag.cfg>` works — the mask file is just concatenated
HDLC-framed diag commands (diag-revealer format; diag_mdlog prepends pkt_type 0x20 and writes as
a registered client, so no EINVAL). `Diag.cfg` = the 12 bytes `7d 5d 05 00 00 ff ff ff ff ed b2
7e` (SET_ALL_MSG_MASK, rt_mask=0xFF → all msg levels/ssids). **GOTCHA that cost hours: a stale
`diag_mdlog` silently blocks new `-f` instances ("another instance already exists") — ALWAYS
`kill -9 $(pidof diag_mdlog)` and verify none before starting.** With mask on, capture jumps
10× (ssid 94 rmts F3 now present, in QSR4 cmd 0x99 with msgid at offset 12).

**Full working recipe → dedicated runbook:**
`~/Projects/lineage-23/diag-tools/HOWTO-modem-diag-capture.md` (kill stale loggers →
`diag_mdlog -f Diag.cfg -o <dir>` → `ctl.stop per_mgr; ctl.restart per_proxy; ctl.restart
per_mgr` (repeat) → `diag_mdlog -k` → decode). Tools kept on laptop in `diag-tools/`:
`Diag.cfg`, `decode_rmts.py`, `qdb.dec`, `qdsp6m.qdb`.

**Result — the get_buffer BRANCH is NOT capturable (hard limit):** across 3 modem cycles, the
EXACT same 8 rmts_api.c messages every time — `RMTS INIT: status` (L422) + the runtime write
path (L1537-1629) — and NEVER the get_buffer region (L536 Open parti / L624 Smem_get_buffer /
L628 "SMEM Kernel Service not found" / L704 Get_buffer / L719 "Requesting Shared buffer"). Since
INIT-status (end-of-init, AFTER get_buffer) is caught every cycle but get_buffer never is, those
messages are either build-masked (compiled out of the production Palm MPSS) or emitted before the
modem's own diag task inits — either way un-capturable via AP diag. **So diag cannot tell us
whether the healthy modem tries SMEM-first.**

**BUT the decisive fact is settled by `rfsa_req`:** every per_mgr cycle increments
`/d/rmt_storage/info` Request count (1→10 over the session), i.e. **the healthy A11 modem
acquires its EFS buffer via RFSA Get_buffer (svc 0x1C) on every single boot.** Contrast pepito:
rfsa_req stays 0, modem never reaches RFSA. So the healthy path IS RFSA (validates the re-add
direction); the pepito gap is upstream of the RFSA query — the reframe (buffer-path
qmi_client_init fails locally before any wire traffic) stands, now with the A11 confirming RFSA
is the target the pepito modem fails to reach. → **Pivot to L2** (userspace-hosted RFSA on pepito)
to test kernel-vs-userspace QMI service reachability — the remaining testable lever.

### L1 conclusion (radio9): capture stalled, but the REFRAME is sharper than ever
Correlating the decoded two-path structure with the radio5 wire measurement (modem egress =
HELLO + own NEW_SERVER + DEL_CLIENT + 20× DATA to rmt_storage/RMTFS **only**; ZERO to RFSA,
ZERO NEW_LOOKUP, and — checking — zero to memshare 0x34 either): **on pepito the modem's buffer
acquisition fails with NO wire traffic at all and no RFSA fallback.** That means it dies at/after
the local `qmi_client_init` in the buffer path (`Smem_get_buffer` L624 "init client rc/status"
or `Get_buffer` L706 "qmi_client_init rc/status") — BEFORE sending any request — even though the
SAME modem's `qmi_client_init` for RMTFS svc 14 ("Open parti", L536) succeeds every boot (the 4
EFS opens). So the gate is **why the buffer-path qmi_client_init fails when the sibling RMTFS one
succeeds** (QCCI service-table match / instance / node-routing for the buffer service vs svc 14).
The healthy A11 F3 (L624/L628/L706/L719 with rc values) would name it — but capture is stalled on
the SSR trigger. Decoder + `qdb.dec` ready for whenever a capture lands.
- **A11 requires MANUAL re-enable of root ADB after every reboot** (phh setting) — [[two-device-methodology]].
- Boot hook files `scratch/a11-diagcap.{rc,sh}` still on A11 `/vendor` (harmless but adds a 30s
  boot wait) — REMOVE when done (`rm /vendor/etc/init/a11-diagcap.rc /vendor/etc/a11-diagcap.sh`,
  needs remount). Decoder `scratch/decode_rmts.py` + `qdb.dec` ready and validated.
4. **Verify OPEN *replies* on pepito** (no build, anytime): confirm rmt_storage replies success
   + valid handles; `ls -l /dev/block/bootdevice/by-name/ | grep -iE 'modemst|fsg|fsc'`.
5. **Deferred (post-healthy-modem convergence hygiene)**: revert qrtr.c HELLO-reply/replay and
   smsm.c legacy SMSM one at a time; santoni-identical DTS node props; tftp_server crash-loop
   (still matters for GPS/QMI_LOC). Panic-survive patch stays as conscious diagnostic deviation.
6. ~~Santoni NON-HLOS swap~~ — **TESTED + DEAD (radio14, 2026-07-07).** Flashed santoni's
   `NON-HLOS.bin` (`MPSS.TA.2.3.c1`, msm8937, `santoni-n-stable-build`, from
   `santoni_global_images_V11.0.2.0.NAMMIXM`; 84 MiB == pepito modem partition) to A16
   `mmcblk0p1` via `dd` (modem partition is RO by default — `blockdev --setrw` first).
   **PIL/secure-boot REJECTED it before load:** `pil-q6v5-mss: PBL returned unexpected status
   -284557301` → `MBA boot failed(rc:-22)` → `modem: Initializing image failed(rc:-22)`. The
   PVG100 enforces OEM-signed firmware; a Xiaomi-signed modem does not authenticate. (Collateral:
   NON-HLOS also carries adsp+wcnss → those failed auth too until restore.) Restored Palm modem
   from md5-exact backup (`1705ef12ecca35937f17e9c8c293481a`, == `pepito-stock-backup-20260706/
   modem.img`); Palm re-auths clean (`MBA boot done` → `modem: Brought out of reset`), baseline
   `rmts_get_buffer` fatal back. ⇒ **"give up on RFSA via an ALLOC_BUFF (Xiaomi) modem" is
   impossible on this device** — can't run a non-Palm modem at all. The only modems that PIL-auth
   are Palm's own signed builds (`-214411 WS241` = newest), which all use RFSA. This also bounds
   radio14 P0: stock-on-DUT must use Palm's OWN stock image (auths), never a cross-OEM one.
   Staged image kept at `flash-staging/santoni-NON-HLOS.bin`.

## ⚡ L2 COMPLETE (radio10, 2026-07-06) — userspace-hosted RFSA FALSIFIES the kernel-vs-userspace lever

**Result: hosting entity is NOT the discriminator. The modem never queries svc 28 in EITHER
hosting mode, and — new this session — never queries the SMEM-service candidate (memshare 0x34)
either. The buffer acquisition fails entirely modem-internally, before ANY QMI request leaves
the modem for a buffer-provider service.**

### The experiment
Built `rfsa-userd` (freestanding arm64 QRTR daemon, source `diag-tools/rfsa-userd.c`, binary on
A16 `/data/local/tmp/rfsa-userd`): hosts RFSA (svc 0x1C, inst 0x101) from a **userspace** socket
and serves GET_BUFF_ADDR (msg 0x0023) with the uio0 address (0xf7300000 / 0x180000), the exact
reply kernel `sharedmem_qmi` would give. It publishes ONCE to the **local** ctrl port (node 1),
which both registers with qrtr-ns AND lands in the in-tree kernel HELLO replay cache
(`qrtr_local_server_track` snoops any ctrl-port sendmsg from the local node). The cache is a
single (svc,inst)-keyed slot, so the publish **overwrites the kernel RFSA's slot with the
userspace port** → at the modem's boot HELLO the kernel replays svc 28 pointing at userspace.
Replay is the only channel proven to reach the modem in its early window (radio4).

> **Platform gotcha (hard-won, now codified in the tool):** NEVER send a QRTR datagram to the
> modem node (node 0) from userspace. `qcom_smd_qrtr_send` is a blocking `rpmsg_send` that does
> NOT honor MSG_DONTWAIT; a send to a frozen/zombie modem parks the process in uninterruptible
> **D-state** (wedged in `qrtr_node_enqueue`; only an SSR/HELLO unblocks it). `rfsa-userd` reaches
> the modem exclusively via the in-kernel replay path (local-ctrl publish) — zero modem-node sends.

### Measurements (A16, per-SSR via `echo restart > /d/msm_subsys/modem`, kprobe on `qrtr_endpoint_post`)
With userspace RFSA published (svc 28 @ port 32523 in ns + replay cache, kernel's 16445 also live):
- **Daemon received ZERO inbound datagrams** across the SSR (only QRTR BYE/DEL_CLIENT churn). No
  GET_BUFF_ADDR, no connect, nothing.
- **Fatal identical every cycle:** `fs_device_efs_rmts.c:161:[6 ,1572864, -1996169536] EFS:
  rmts_get_buffer api failed`; `/d/rmt_storage/info` Request count stays 0.
- **Modem egress kprobe — the modem's DATA goes ONLY to rmt_storage/RMTFS (svc 14, ports 16433 +
  16437) and QRTR ctrl.** Zero DATA to: userspace RFSA (32523), kernel RFSA (16445), **memshare
  svc 0x34 (16452)**. (16437 = rmt_storage's second/IO socket, not a registered server.)

### Why this is decisive (the clean comparison)
`svc 14` (RMTFS) is **userspace-hosted** (rmt_storage) and the modem talks to it every boot.
`svc 28` (RFSA) moved to **userspace** at the same node, same announce channels, same replay
delivery — and the modem sends it **nothing**. Same hosting entity type, opposite outcome ⇒
"kernel-hosted vs userspace-hosted QMI reachability" is **NOT** the gate. The L2 core hypothesis
is FALSIFIED.

### Sharpened conclusion — the failure is PRE-WIRE, and it's the SMEM-first branch (S1), not RFSA (S2)
The modem emits **zero wire traffic to any buffer-provider service** (RFSA *or* memshare, kernel
*or* userspace) yet still reaches `rmts_get_buffer` and fatals. So it dies at a **modem-local step
before sending any buffer request** — it is not "trying RFSA and failing to be heard" (S2 would
put at least a lookup/connect on the wire; radio5 already saw zero NEW_LOOKUP). This elevates
**S1 (radio7 qdb): the modem runs `Smem_get_buffer` first ("SMEM Kernel Service", rmts_api.c
L624-668) and on pepito its outcome differs from stock such that it never falls back to the RFSA
`Get_buffer` path (L704-828).** Stock A11 ends every boot in RFSA success (Request count ticks);
pepito never reaches RFSA at all. The divergence is entirely inside `Smem_get_buffer`.

- **memshare (0x34) is NOT the modem's wire peer** — announced on both phones (radio9) but the
  modem sends it nothing on pepito, so if "SMEM Kernel Service" == memshare, the modem isn't even
  reaching its send_msg; more likely `Smem_get_buffer` resolves SMEM by a **direct shared-memory
  read** (no QRTR), which would explain zero wire traffic on the whole buffer path. That points
  back at an **SMEM content/layout item the modem reads at buffer-decision time** — the radio6
  SMEM lane, but now with a specific consumer (`Smem_get_buffer`) rather than a blind writer-diff.

### Phase 2 (kernel svc 28 removed, userspace-only) — DEPRIORITIZED, not run (rationale)
Originally staged to remove any two-provider ambiguity. Moot: the replay cache is single-slot
(modem only ever sees one svc-28 port), and the modem sends **zero** svc-28 traffic regardless —
it is not choosing between providers, it never queries svc 28 at all. Removing the kernel one
cannot make the modem start. Not worth a kernel build cycle. (If ever wanted, the daemon already
demonstrates userspace-only reachability without a rebuild — just don't build kernel RFSA.)

### Device left clean
Daemon stopped; its ns entry auto-evicted on socket close; the stale replay-cache slot (dead port
32523) evicted via `rfsa-userd del 32523` (local-ctrl DEL_SERVER). ns shows only kernel svc 28 @
16445. NOTE: my publish overwrote then removed the kernel RFSA's replay-cache slot, so the cache
holds no svc 28 until the next reboot (kernel re-registers at cold boot); immaterial — the modem
ignores svc 28 — and a reboot fully restores it. Tools: `diag-tools/rfsa-userd.c` (source),
`/data/local/tmp/rfsa-userd` (A16). Build: prebuilt clang `--target=aarch64-linux-android
-nostdlib -static -O2 -fno-stack-protector`.

### Next levers after L2 (ranked) — ⚠️ the SMEM content diff is NOT fresh
**Do not re-run "diff all of SMEM" — radio6 already did the presence/size half and the content
half is blocked.** radio6 (2026-07-05) compared stock `/d/smem/mem` vs A16 `/d/smem_toc`: all
items byte-identical in **size** except item 114 (8B, present stock/absent ours) = a symptom
(late/heap-end, modem-written once healthy, never appears pre-fatal on ours). The byte-**content**
comparison stalled on the **stock A11 side**: no `/dev/mem`, no `/proc/kcore`,
`CONFIG_MODULE_SIG_FORCE=y` (can't load an unsigned dumper), so stock item contents were never
readable. That wall still stands. What radio7+radio10 changed is only the SCOPE (failure narrowed
to `Smem_get_buffer` reading one item/region, so a content diff would be targeted, not blind) —
it did NOT unblock the stock read. So:

1. **Find a stock-A11 SMEM-content read primitive** — this is the actual gating blocker, not the
   diff itself. Open questions radio6 didn't chase: does stock `/d/smem/mem` already expose item
   CONTENT (it gave sizes/toc for the presence diff — is the full region dumpable there)? Is there
   a QMI/diag path that reads SMEM? A signed-module or bootloader-assisted angle? Only once a read
   primitive exists is the targeted single-item diff worth doing.
2. **Identify WHICH SMEM item `Smem_get_buffer` reads** (modem-side) — from qdb/QSR metadata or by
   analogy to the working RMTFS sibling — so we know the exact target to compare even without a
   full stock dump, and can sanity-check it on the A16 side (which IS content-readable via
   smem_raw).
3. **stock-A11 F3 of the `Smem_get_buffer` branch** — the ground truth (L628 "SMEM Kernel Service
   not found/found" + fallback), but build-masked/pre-diag-init on the production MPSS (radio9 L1:
   un-capturable via AP diag). Low odds unless a different mask/subsystem is tried.
4. **QCCI (ver,inst) match for the buffer path** (residual S2) — radio5 covered inst 0x1/0x101;
   the untested variable is the **version** field the buffer-service client requests (announcements
   encode ver=1). Cheap to test, but low odds given the zero-wire-traffic (pre-send) evidence.

## Capture mechanism (WORKING — reusable) — `pepito-diagcap`

Early-boot AP-side strace hook; see [[diag-capture-hook]]. Files:
`/vendor/etc/init/pepito-diagcap.rc` + `/vendor/etc/pepito-diagcap.sh` (source in
`/home/kyle/Projects/lineage-23/diag-tools/`). On `on property:init.svc.vendor.rmt_storage=running`
it runs the `.sh`, which retries `pidof` then `exec`s `strace` into tmpfs `/dev/pepito-rmt.strace`
(+ self-log `/dev/pepito-diagcap.log`). **Gotchas learned:** (1) inline `sh -c` in the `.rc` exits
`status 6` — the logic MUST live in a separate `.sh` (init-parser quoting is hostile); the
script-file form attaches cleanly. (2) A vendor **reflash wipes it** (it's a live `/vendor` edit) —
re-push after any vendor flash. (3) `env -i` proved PATH is *not* the issue (bare `pidof` works),
so absolute paths are belt-and-suspenders. **Timing caveat:** it attaches on rmt_storage's
running-transition; the modem's cycling window varies wildly boot-to-boot (234–301s this boot,
~50–150s others), so it's not *guaranteed* to overlap — but modem-side capture is impossible
(ramdump=zeros/XPU, DIAG dead) and no SSR trigger exists, so this hook is the tool. Decode:
msg_id `0x0004` on rmt_storage's socket = ALLOC_BUFF. Disarm: `rm` the `.rc` (needs `adb remount`).

### Other leads (lower priority now)
- **Community santoni data — reframed (radio9):** a boot `dmesg` is USELESS for this (ALLOC_BUFF
  is userspace QMI traffic; it never appears in dmesg). The useful ask on `t.me/mi_msm8937` /
  XDA: `qrtr-lookup` output (service table snapshot) and/or an strace of `rmt_storage` from a
  4.19 santoni. Superseded by the A11 capture for the method question anyway.
- **Hygiene:** SELinux denial `rmt_storage → /sys/.../uio/uio0/name` (permissive now; `genfs_contexts`
  label before Enforcing). Not the blocker.
- (DTS convergence + qrtr.c/smsm.c reverts promoted into Next actions item 3.)

## Standing facts / guardrails (carry-over, updated radio9)
- ~~DO NOT re-add RFSA~~ **REVERSED**: RFSA IS required by the Palm modem (A11 discriminator,
  radio9) — re-add staged. Still valid: do NOT port `msm_ipc_router`, do NOT resume Hexagon
  disassembly (`PLAN-modem-disasm.md`) — re-affirmed radio14 (Ghidra lane parked after the
  radio11–13 excursion; resume only if P0–P2 dead).
- Control plane works: `qcrild` + HIDL `IRadio/slot1` publish; framework "Emergency calls only".
  Downstream SIM/registration blocker = the HIDL→AIDL `vendor.radio-compat` shim
  (`PLAN-radio-compat.md`) — only reachable once the modem is healthy.
- Modem image == stock/siblings; not a wrong-image issue. Firmware-bump avenue closed (pepito
  already has the newest build of the family variant).
- Partition backups: `/home/kyle/Projects/lineage-23/pepito-stock-backup-20260706/` (host) +
  `/data/local/tmp/pepito-stock-backup-20260706/` (device); modem.img verified Palm
  `MPSS.TA.2.3.C1-214411 / 8940.gen.prod / WS241`.
- Build: remote Stellaris16 (10.0.2.43) via `scripts/build-lineage23-remotely.sh`. Kyle owns
  build/flash; I stage + validate on-device ([[feedback-user-does-build-flash]]).

## Device state
A16 `c39a6acf` running the RFSA-re-add build, `/dev/uio0 "rmtfs" @ 0xf7300000` present, kernel
RFSA svc 28 @ 16445 live in ns, modem crash-cycling→zombie (crash_count climbs then freezes
ONLINE). rfsa-userd tested + cleaned up (radio10); replay cache holds no svc 28 until next reboot
(immaterial). A11 `81eed371` = stock 3.18 ground truth (needs manual root-ADB re-enable after
reboot).
