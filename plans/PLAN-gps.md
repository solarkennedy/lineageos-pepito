# LineageOS 23.2 — GPS / GNSS / Location Stack (pepito/PVG100)

> ## ⛔ PARKED (2026-06-29) — blocked on the modem, NOT on anything GPS-side.
> GPS userspace is **done** (Phases 1–3: configs + 7 libs + `gps.prop`, verified). The
> only remaining blocker is **QMI_LOC (svc 16) absent from the QRTR bus** because the
> modem **fatals on every boot** and survives only as a post-fatal zombie that *reports*
> `ONLINE` (EFS `rmts_get_buffer` fail). A zombie modem can't host the GNSS/LOC service.
> **Do NOT do more GPS work until the modem is genuinely healthy** — with ONE exception,
> added 2026-07-03: the **Track 1 de-risk tests** (see "Session 2026-07-03" below) SHOULD
> run now. They test the park's key assumption on the stock witnesses without touching
> the modem.
> **Unblock = fix the modem's RMTFS ALLOC_BUFF exchange with `rmt_storage`** — see
> `PLAN-radio.md` "2026-07-02: modem-fatal status" (the RFSA port was completed 2026-06-29
> and falsified — the modem never queries it).
> **TZ is a red herring — now PROVEN (2026-07-02, `PLAN-tz.md`):** stock 3.18 fails the same
> `MEM_PROT_ASSIGN` SMC64 call identically and its modem works without it; the `-95` was an
> errno-remap artifact; both SMC conventions rejected on both kernels. Never re-enter that hole.
> **RESUME HERE:** after the modem reaches *genuine* ONLINE (crash_count 0, no `Fatal
> error on the modem` in dmesg), re-run `qrtr-services` → if **svc 16 appears**, the HAL
> stack is ready and GPS should fall through. If 16 is still absent with a healthy modem,
> *then* reopen `pd-mapper` / modem-GNSS-NV. Not before.
> **✅ 2026-07-07 (gps2): Track 1 test 1 RAN — the park's key assumption is CONFIRMED.**
> The healthy stock modem announces **QMI_LOC svc 0x10, instance 0x2, on the modem node**
> (`dump_servers` on A11), alongside the full canonical radio set. "Watch for canonical
> svc 16 on the modem node" IS the right resume tripwire after all (the 2026-07-03
> "may be wrong tripwire" worry is resolved — see Session 2026-07-07 below). GPS stays
> parked; the modem campaign is the whole critical path.

## Session 2026-07-07 (gps2) — Track 1 test 1 RAN: healthy modem DOES announce LOC(16). Park assumption CONFIRMED.

Ran the A11 registry dump live (`adb root` re-enabled by Kyle; both phones on bench):

```
# A11 (81eed371, stock 3.18, healthy modem, crash-free):
cat /d/msm_ipc_router/dump_servers
0x00000010 |0x00000002 |0x00000000 |0x00000049 |   ← QMI_LOC svc 16, inst 2, NODE 0 = MODEM
```

**Findings (all three Track-1 questions answered by one dump + one A16 sweep):**

1. **LOC is announced by the healthy Palm modem** — svc `0x10` inst `0x2` on node 0 (the
   modem), canonical ID, hosted directly on the modem (NOT an apps-node user-PD →
   independently re-confirms pd-mapper is moot). Legacy PDS (svc 6) is absent — this modem
   is LOC-generation. **The park logic holds: fix the fatal and GPS should fall through.**
2. **The "QTI-remapped service IDs" inconsistency is RESOLVED as (a) zombie-bus artifact.**
   The healthy stock modem announces the full CANONICAL radio set on node 0 (~45 services:
   WDS 1, DMS 2, NAS 3, QOS 4, WMS 5, Voice 9, UIM 0x0B, PBM 0x0C, LOC 0x10, SAR 0x11,
   WDA 0x1A, …). The A16 snapshots that lacked them (42/54-service sweeps) were taken on
   the post-fatal zombie. Measured now on A16: **node 0 announces exactly ONE service**
   (svc 43/0x2b inst 0x1202 — also present on stock, evidently pre-EFS). So there is no
   remapping; the modem simply fatals before registering its service constellation.
3. **Resume tripwire (final):** after a genuinely healthy modem boot (crash_count=0, no
   fatal in dmesg), `qrtr-services` shows **svc 16 on the modem node** (expect inst
   encoding ~0x2xx in QRTR's version|inst<<8 form; stock IPC-router shows inst field 0x2).
   Then: outdoor field test → Phase 4 assist stack.

**Track 1 tests 2–3 disposition:**
- Test 2 — **✅ PASSED same day (2026-07-07, Kyle, GPSStatus2 on the A11):** even
  *indoors*, with fresh aGPS data, the A11 shows **numbered SVs with signal bars** (no
  fix — not needed for the proof). Side-by-side the A16 showed zero SVs (expected: zombie
  modem, no LOC session possible). So on stock, the full chain — LOC session open → GNSS
  engine armed → RF/antenna → live SV observations — WORKS on this exact hardware. "Stock
  GPS works on this hardware" is now an observation, not an assertion. (An outdoor fix was
  not captured; if ever needed, GPSStatus2 stays installed on the A11, location permission
  granted. Note its clock is wildly wrong with no network — slows TTFF, doesn't hide SVs.)
- Test 3 (A16 pre-fatal sweep) — **DEPRIORITIZED to pointless**: the fatal lands ~40ms–11s
  into modem boot (EFS init), long before the GNSS task would register LOC, and finding 2
  already resolved the inconsistency test 3 was designed to arbitrate.

**Conclusion: nothing GPS-side changed and nothing GPS-side is actionable. The ONLY path
to GPS is the modem-fatal campaign (`PLAN-radio.md`, currently: find a stock-A11 SMEM
content read primitive → targeted `Smem_get_buffer` item diff). GPS remains parked with
its endgame now FULLY de-risked — both park assumptions (LOC announced by healthy modem;
RF/engine chain produces SVs on this hardware) are observed facts as of 2026-07-07.**

---

## Session 2026-07-03 — expert review: the park is right, but its key assumption is untested

A full review of the GPS/radio/qrtr/tz state **validated the park decision** (GPS
userspace is genuinely done; nothing GPS-side left to fix; modem-first ordering is
correct; the tftp_server/pd-mapper/TZ/RFSA rule-outs are all well-earned — do not
reopen them). But it flagged that the plan rests on one **unproven assumption**:

> **"healthy modem ⇒ QMI_LOC(16) appears on QRTR."**

There is **no observation, ever, of this modem announcing LOC on any router** (the QMUX
caution below was already on file). That assumption is testable NOW, on the bench,
without fixing the modem — and if it's false, the modem-fatal campaign won't deliver GPS
at the end. Spend one bench session proving the destination exists.

### Track 1 — de-risk tests (cheap; run NOW, in parallel with the modem work)

1. **A11 (`81eed371`, stock kernel+vendor, healthy modem): dump the legacy IPC-router
   service registry.** `cat /sys/kernel/debug/msm_ipc_router/dump_servers` (or the
   equivalent 3.18 debugfs file; mount debugfs if needed). Look for service `0x10` (16).
   The legacy IPC-router and QRTR generations ride the same modem service registry over
   the same SMD `IPCRTR` channel, so "does the healthy stock modem announce 16"
   transfers directly to our QRTR world.
   - **16 present →** the park logic is CONFIRMED: fix the fatal and GPS should fall
     through. Record the exact service/instance encoding seen — that becomes the
     resume tripwire.
   - **16 absent on healthy stock →** GPS has a SECOND, independent blocker (LOC is
     reached via QMUX/SMD-DATA, or not hosted at all on this modem) — know this
     *before* betting the GPS outcome on the modem campaign.
   - Also note whether the classic radio IDs (1/2/3/5/9/11) appear — calibrates the
     service-ID inconsistency below.
2. **android8-adb (true stock, no root needed): field-verify that stock GPS actually
   gets a fix** — `dumpsys location` while a GPS app runs, outdoors. "Stock GPS works
   on this hardware" is asserted throughout this file but has **never been observed on
   this bench**. ~20 min closes it.
3. **A16: `qrtr-services` sweep in the PRE-fatal window.** The 2026-07-02 boot fatal'd
   at t≈215s — a ~3.5-minute pre-fatal window (vs the earlier ~100ms-after-EFS-open
   pattern). Run `qrtr-services` repeatedly inside that window (and immediately after a
   manual SSR: `echo restart > /sys/kernel/debug/msm_subsys/modem`), then diff pre- vs
   post-fatal service lists. May show 16 (or its remapped form) appearing then
   vanishing — which would confirm the decode, the gating, AND the resume tripwire in
   one measurement.

### Inconsistency to nail down: the "QTI-remapped service IDs" story

The enumerator found the classic radio set (1/2/3/5/9/11 — DMS/NAS/WDS/UIM) **absent**,
yet qcril "works". But qcril uses the same canonical QCCI service objects
`loc_api_v02` does — if NAS=3 genuinely isn't on the bus, qcril's lookups should fail
exactly like LOC's `rc:-2`. Two candidate resolutions: **(a)** the 42/54-service
snapshots were taken on a **post-fatal zombie** boot, after the modem BYE'd services —
i.e. not representative of the pre-fatal bus; or **(b)** an enumerator decode/filter
artifact. Either way, **"watch for 16" may be the wrong tripwire.** Resolve via
Track-1 test 3, plus (optional) a one-off strace of qcril's `qmi_client_get_service`
lookups to see what a "healthy" bus looks like to a canonical QCCI client here.

### Corrected resume criterion (supersedes the banner's "watch for svc 16")

After a genuinely healthy modem boot (crash_count=0, no fatal in dmesg): re-run
`qrtr-services` and watch for **whatever LOC signature Track 1 established** —
canonical 16 or its actual on-bus form. If present → outdoor field test → then Phase 4
assist stack. If absent with a healthy modem → Track 1's A11 answer picks the fork:
- stock **does** announce 16 → investigate modem GNSS NV / `fsg`/`fsc` provisioning
  (Palm EFS content);
- stock does **not** announce 16 → transport-generation (QMUX) problem — much deeper;
  re-plan before spending anything further.

### Notes folded to the radio side (owned by `PLAN-radio.md` TODO; recorded here)

- **Reorder recommended:** promote **mainline `rmtfs`** (linux-msm; open-source,
  QRTR-native, implements ALLOC_BUFF explicitly, plaintext-loggable) AHEAD of the
  strace-and-diff steps — one swap is both the instrument and a candidate outright fix.
  Hand-decoding raw QMI TLVs from strace across two blob generations (QRTR vs
  `AF_MSM_IPC`) is the expensive fallback.
- **Check bytes, not version strings:** md5 the pepito modem image vs a sibling
  nightly's. If byte-identical AND siblings run the same nightly `rmt_storage` fine,
  the "Palm RMTFS dialect" hypothesis is dead on arrival and the differentiator narrows
  to EFS/NV content (`modemst1/2`, `fsg`, `fsc` — which ARE Palm's) or kernel-side
  environment.
- **Branch-plan the capture:** if the strace shows **no ALLOC_BUFF request ever
  arrives**, the modem fails *before* talking to `rmt_storage` (it expects the buffer
  address via some older mechanism) — a different investigation than "bad reply".
  Decide what each branch implies before the capture session.

---

**Status (2026-06-26):** Userspace location stack is **fully fixed and verified**
(Phases 1–3: configs + 7 plugin libs + `gps.prop`, see below). The HAL loads clean,
opens its QMI_LOC client, and the framework drives a live tracking request. **New, real
blocker found:** the modem's **QMI_LOC service is not discoverable over QRTR**
(`qmi_client_get_service() rc: -2` / `Service instance id is -1`), so `GnssAdapter`
blocks "waiting for open", capabilities never arrive, and the engine never tracks — **no
SVs, indoors or outdoors, even after AGPS download + cold reset** (field-tested
2026-06-26). This is a modem-side QMI-availability problem, one layer below the HAL —
the same *class* as the radio QMI work, not a HAL/config/lib issue. See
"Session 2026-06-26 — the real blocker" below.

> **Prime suspect: `tftp_server` (the modem RFS service) is crash-looping** — it serves
> `/persist/rfs/apq/gnss`, squarely in the modem GNSS data path. Secondary suspects:
> `pd-mapper` absent (if QMI_LOC is PD-hosted); modem GNSS NV/config. Resolve against
> `android11-adb` (stock GPS works on the same physical modem).

> **Holistic-session caution (2026-06-26):** there is **no positive evidence QMI_LOC has
> ever worked** on this hardware, and per the device owner the **original Palm OS used
> QMUX/qmuxd** — an older QMI transport than our QRTR-only model — so QMI_LOC may never have
> been a QRTR-announced service at all. Before chasing `tftp_server`/`pd-mapper`, **get
> positive evidence: build a QRTR service enumerator** (step 2 below, now promoted to FIRST)
> to confirm whether QMI_LOC (svc 16) is on the bus and whether the modem exposes user PDs.
> See `PLAN.md` "Holistic cross-cutting analysis" → Cluster A.

**Earlier status (2026-06-25):** GNSS HAL was already running + publishing
`IGnss@1.0–2.1/default`; the blockers were thought to be only **missing location configs
+ un-extracted plugin libs + unprovisioned `gps.prop`**. Those were all real and are now
fixed (Phases 1–3) — but fixing them revealed the deeper QMI_LOC blocker above.

> Builds on `PLAN-radio.md` (the QMI-over-QRTR keystone). GPS is one of the QMI
> subsystems `qrtr-ns` was expected to unblock; the transport half is done, the
> location-userspace half is what remains.

## Legend
- ✅ Working / proven on-device
- 🔧 Present but not yet runtime-verified
- ❌ Missing / the active blocker

---

## Session 2026-06-26 — the real blocker: modem QMI_LOC not discoverable over QRTR

After Phases 1–3 (configs + 7 libs + `gps.prop`, all live-pushed) the HAL loads clean
and the framework drives a real `HIGH_ACCURACY` request (`mStarted=true`). Verbose loc
logging (set `DEBUG_LEVEL = 5` in **`/vendor/etc/gps.conf`** — `gps.prop`'s DEBUG_LEVEL
did NOT take) shows the engine init reaching the QMI_LOC client open and **failing
there**:

```
LocSvc_ApiV02   open: Enter mMask:0x0 mQmiMask:0x0
LocSvc_api_v02  locClientOpen: Service instance id is -1
LocSvc_api_v02  locClientQmiCtrlPointInit: qmi_client_get_service() rc: -2      ← QMI_SERVICE_ERR
LocSvc_GnssAdapter openMeasCorrCommand: Capabilities are not known, wait for open  ← blocks forever
```

`qmi_client_get_service() rc: -2` = the QMI **LOC** service (type 16) is **not in the
QRTR service list**. The GnssAdapter waits for the open to publish capabilities; it
never does → no tracking start → no SV/position. Confirmed end-to-end: field test
outdoors with AGPS downloaded + GPS cold-reset still produced `measurement events = 0`,
`last location = null`, zero `reportSv`/NMEA.

> **DIRECTLY MEASURED 2026-06-26 (PLAN-qrtr.md):** built a QRTR bus enumerator
> (`qrtr-services`) and dumped every registered service. **Service 16 (QMI_LOC) is
> absent from the bus** (42 services registered; decode verified via RMTFS(14)+SMGR(256)).
> This is *positive evidence* that the modem isn't advertising LOC — it is **not** a
> client-side instance/version filter bug. The RFS/`pd-mapper`/modem-GNSS-NV path below is
> the correct direction, and `qrtr-services` now measures whether each fix makes 16 appear.
> (Aside: the classic radio QMI set 1/2/3/5/9/11 is *also* absent as small-IDs — radio works
> via QTI-remapped service IDs — so don't expect LOC under id 16 to "come back"; the modem
> has to be made to host the GNSS/LOC service at all. See PLAN-qrtr.md Results.)

### What this is NOT (ruled out this session)
- **Not** a HAL/lib/config problem — Phases 1–3 are done; all 7 libs load; gps.conf
  parses (CAPABILITIES=55 read). The HAL gets as far as the QMI_LOC open.
- **Not** a transport mismatch — `qmuxd` is **absent** (system is QRTR-only), so the loc
  client uses QRTR, the same transport qcril uses successfully. The QRTR/`qrtr-ns`
  service mechanism works (radio proves it); QMI_LOC specifically isn't advertised.
- **Not** the `gnssNameCb` "success" earlier — `name=qcom;MPSS.TA.2.3.C1-214411` is a
  static modem version string, **not** proof of a live QMI_LOC link (the earlier read
  was too optimistic). The authoritative signal is `qmi_client_get_service rc:-2`.
- **Not** signal/TTFF — outdoors + AGPS + cold reset, still zero SVs.

### Prime suspect: `tftp_server` (modem RFS service) is crash-looping
dmesg shows `vendor.tftp_server` restarting every ~5 s and exiting 255. Running it
directly:
```
ASSERT : Line=423 : Cond=sock_res == TFTP_SOCKET_RESULT_SUCCESS
ASSERT : Line=590 : Cond=result == 0
tftp_server.c:594  TFTP-Error : Exiting with error -1
```
It asserts on **socket creation**. `tftp_server` = the QTI **RFS (remote file system)
server** the modem uses to read/write `/persist/rfs/apq/gnss` — i.e. GNSS
almanac/calibration/NV. **Hypothesis:** with RFS dead, the modem GNSS task can't
initialize, so it never advertises QMI_LOC → `rc:-2`. (RFS is distinct from `rmt_storage`,
which serves modem EFS `modemst1/2` and *is* working — QMI_RMTFS svc 14 is on the bus.)

### ROOT-CAUSED + FIXED 2026-06-26 — it's a WRONG-BLOB problem, not caps/SELinux/perms
strace of the crashing binary shows the failing call is **`socket(AF_MSM_IPC=27) =
-1 EAFNOSUPPORT`** (strace prints "AF_IB" for family 27; QTI headers call it
`AF_MSM_IPC` — see the `sockaddr->family == AF_MSM_IPC` assert string). Our kernel is
**QRTR-only** (`/proc/net/protocols` has `QIPCRTR` and nothing else) — there is no legacy
`msm_ipc_router`, so any `AF_MSM_IPC` socket fails. **This is the radio `msm_ipc_router`
story again, applied to RFS:** the on-device `/vendor/bin/tftp_server` (md5 `93e226f1`,
`DT_NEEDED libqmi_csi/libqmi_common_so`) is the **legacy IPC-router-generation** binary —
it physically cannot run on this kernel. The `dac_read_search` denial is downstream noise.

The **nightly** ships a *different, QRTR-native* `tftp_server` (md5 `5886a857`,
`DT_NEEDED libqsocket.so + libqrtr.so`, uses `sockaddr->qrtr.sq_family == AF_QIPCRTR`,
self-gates on `"qrtr-ns service is not ready"`, and references `/mnt/vendor/persist/rfs/
apq/gnss/`). We had shipped the wrong one.

**Fix (committed to the tree, same pattern as `qrtr-ns`):**
1. Swapped `proprietary/vendor/bin/tftp_server` → nightly QRTR-native blob (`5886a857`).
2. Staged its missing dep `proprietary/vendor/lib64/libqsocket.so` (nightly) + added the
   copy line to `mithorium-common-vendor.mk` (next to `libqrtr.so`; `libqrtr.so` already
   on device). `libqsocket.so` deps = libc++/libc/libm/libdl only — clean closure.

**PROVEN live** (pushed both to `/data/local/tmp`, `LD_LIBRARY_PATH` set): the nightly
binary opens `AF_QIPCRTR` cleanly (no assert) and **actively registers RFS services on the
bus** — `sendto(cmd=4 NEW_SERVER, …, port 0xfffffffe)` for service `0x1000` instances 1–11
(one per remote PD). Runs steadily, no crash loop.

**Open question (the actual test):** does a live RFS server now let the modem GNSS task
init and **advertise QMI_LOC(16)**? Re-run `qrtr-services` (PLAN-qrtr.md) after flashing the
vendor image — watch for service 16 to appear and `/persist/rfs/apq/gnss/` to get populated.
If 16 still doesn't appear, fall to the secondary suspects (`pd-mapper`, modem GNSS NV).

#### RESULT (flashed + rebooted 2026-06-26): RFS fixed, but QMI_LOC STILL ABSENT
- ✅ `tftp_server` now **runs** (no crash loop; live md5 `5886a857`) and **registers RFS on
  the bus**: `qrtr-services` went 42 → **54 services**, the 12 new ones being service
  **`4096`(0x1000) instances 1–12 on node 1** (AP) — exactly tftp_server's RFS endpoints.
  So the fix is mechanically correct and the legacy `AF_MSM_IPC` crash is gone for good.
- ❌ **QMI_LOC(16) is still not on the bus**, and **`/persist/rfs/*` is still empty**
  everywhere. No `LocSvc`/`qmi_client_get_service` activity. The modem crashed+SSR'd once at
  boot (IPA, crash_count=1, absorbed by the panic-survive patch) *with tftp_server already
  up* (class core), so the "modem retries GNSS once RFS is alive" path was effectively
  already exercised — LOC still didn't appear.

**Verdict: dead RFS was a real, necessary fix but NOT the gate for QMI_LOC.** The empty
`/persist/rfs/apq/gnss` is most likely a *symptom* (GNSS never ran → nothing written) rather
than a cause (those dirs are populated at runtime). RFS is hereby ruled out as the LOC
blocker. **Keep the fix** (the legacy blob genuinely can't run on a QRTR-only kernel).

**`pd-mapper` RULED OUT as the LOC blocker (2026-06-26).** Earlier note promoted it; that was
parroting the old "QMI_LOC is commonly user-PD → needs pd-mapper" hypothesis, not the evidence.
Three checks falsify it:
- **(A)** the GPS-working **nightly userspace ships NO pd-mapper and no servreg daemon** — yet
  it's the mithorium build where siblings' GPS works. pd-mapper isn't required for GPS here.
- **(B)** the **modem already announces ~12 services on QRTR (node 5) with no pd-mapper** —
  so "modem announces a service over QRTR" works without any AP servreg daemon; LOC just isn't
  among them. pd-mapper is an AP-side servreg/PDR daemon, NOT on the modem's announce path.
- **(C)** `libloc_api_v02` discovers LOC via plain `qmi_client_get_service` /
  `qmi_client_get_service_instance` — **no servreg/PD-locator path in it at all.**

**Real problem (narrowed): the modem itself is not announcing a LOC service on QRTR** — purely
modem-side. Candidate causes, best-fitting first:
1. **Modem boot instability** — IPA `ERR_FATAL` ~265 ms post-powerup → SSR (crash_count=1,
   survived only via the panic patch). If the modem's GNSS/LOC task inits *after* that crash
   point it never runs. **Cheapest lever:** confirm `CONFIG_RMNET_IPA=n` actually landed in the
   running kernel (memory: it didn't, due to a stale `.config`) for a 0-ERR_FATAL modem boot,
   then re-check LOC. Do this first.
2. **Palm modem GNSS NV/provisioning (AML0)** — GNSS may be disabled/differently provisioned.
   Ground-truth on stock **A11** (GPS works on the *same physical modem* → proves it CAN do LOC,
   and does so with no qrtr-ns and no pd-mapper — independent confirmation pd-mapper is moot).
3. **Service-ID remapping** — classic radio set (1/2/3/5/9/11) is also absent, so this modem
   uses QTI-remapped IDs; LOC may not be under 16. But `loc_api_v02` hardcodes the canonical LOC
   service object, so a remap would be a dead end for the stock HAL anyway.

**Separate AP-side issue noted (not the LOC blocker):** dmesg shows framework
`Could not find android.hardware.gnss.IGnss/default in the VINTF manifest` — A15 wants the
**AIDL** `gnss.IGnss`, we publish only **HIDL** `IGnss@1.0–2.1`. May be a benign fallback,
but worth confirming the framework actually binds the HIDL HAL. Even if fixed, the HAL still
can't get QMI_LOC from the modem — so LOC(16) remains the deeper blocker.

### Secondary suspects
- **`pd-mapper` absent** — if QMI_LOC is hosted in a modem protection-domain (user-PD),
  it won't advertise without PD localization. `pd-mapper` is not in the tree (radio TODO:
  not in the nightly; build from Linaro source or extract from an FP3 payload). Weaker
  lead — siblings reportedly run the control plane without it, but whether sibling **GPS**
  works without pd-mapper is unconfirmed.
- **Modem GNSS NV/config (Palm AML0)** — the Palm modem image differs from siblings only
  in OEM NV; GNSS could be disabled/differently-configured. Resolve against stock.

### Next steps (cheap → expensive)
1. **Fix `tftp_server`** — ✅ DONE 2026-06-26 (see "ROOT-CAUSED + FIXED" above). It was the
   wrong (legacy `AF_MSM_IPC`) blob; swapped in the nightly QRTR-native one + `libqsocket.so`.
   Proven to register RFS on QRTR live. **Next: flash vendor, re-run `qrtr-services`, check
   if QMI_LOC(16) now appears.**
2. **Enumerate QRTR services** — no debugfs/tooling on-device today; build/push a tiny
   `qrtr` lookup (or enable `CONFIG_QRTR` debugfs) to *directly* confirm whether QMI_LOC
   (svc 16) is registered. Turns the hypothesis into a fact. **(PROMOTED TO FIRST,
   2026-06-26 holistic session: get positive evidence before fixing `tftp_server`/`pd-mapper`
   — esp. since the original Palm stack used QMUX, not QRTR, so QMI_LOC may never have been a
   QRTR-announced service. This is "option 1" in `PLAN.md` Cluster A; the turn-key tool +
   decision tree live in `PLAN-qrtr.md`.)**
3. **Two-device ground truth (needs A11 back)** — on stock `android11-adb` (GPS works on
   the *same physical modem*): does stock run `tftp_server`/`rfs_access`? Is there a GPS
   PD? What QMI/RFS services exist? Stock uses legacy IPC-router, but "does the modem
   advertise LOC and does RFS run" transfers.
4. **`pd-mapper`** — only if 1–3 point at PD hosting; source/build it then.

---

## ⚠️ Bench note (2026-06-25): A11 ground-truth phone is OFFLINE

The two-device methodology needs `android11-adb` (stock 3.18 + stock 8.1 vendor) as
GPS ground truth, but **it is not currently reachable**:

- `adb devices` shows only `c39a6acf` (our A16 bringup).
- The `~/.bin/android11-adb` wrapper is currently pointed at `ANDROID_SERIAL=4373dd0f`
  ("Silver" — not connected); the methodology's gold A11 serial `81eed371` is
  commented out in the wrapper and also absent from `adb devices`.

**Before the A11-dependent steps below, reconnect the gold A11 phone and fix the
wrapper** (uncomment `81eed371`, or repoint it). Until then, the config/blob/packaging
steps (which don't need A11) can proceed; the *authoritative* config values
(SUPL/AGPS server, `izat.conf`/`gps.conf` deltas, what daemons stock actually runs)
should be pulled from A11 rather than trusted from the generic mithorium defaults.

---

## What's already in place (✅ — verified live on `android16-adb`, 2026-06-25)

| Layer | State | Evidence |
|---|---|---|
| QMI/QRTR transport | ✅ | `qrtr-ns` running (pid 1036), `qcrild` running (pid 1587), `vendor.peripheral.modem.state=ONLINE`. GPS rides the same plane radio proved out. |
| GNSS HAL service | ✅ running | `gnss_service` = `/vendor/bin/hw/android.hardware.gnss@2.1-service-qti` (pid 912); `init.svc.gnss_service=running`. |
| HIDL IGnss surface | ✅ published | `lshal`: `android.hardware.gnss@1.0/1.1/2.0/2.1::IGnss/default` all served by pid 912. Framework can bind the HAL. |
| Location data dirs | ✅ | `init.qcom.rc` makes `/data/vendor/location{,/mq,/xtwifi}` + `/dev/socket/location/{mq,xtra,dgnss}` (gps:gps). |
| Some location configs | ✅ partial | `/vendor/etc/gps.conf`, `flp.conf`, `gnss_antenna_info.conf` install (generic mithorium). |
| `libgnss.so` | ✅ | `/vendor/lib64/libgnss.so` present. |

So the framework→HAL→(QRTR)→modem skeleton is wired and the HAL is alive. The gap is
everything the HAL `dlopen`s and parses *after* it starts.

---

## The active blockers (❌ — captured from a clean HAL restart, 2026-06-25)

Restarting `gnss_service` and watching its init produced this exact failure cascade:

```
E gnss@2.1-service-qti: cannot open file:/data/vendor/location/gps.prop
E LocSvc_misc_utils:  dlopen failed: library "libloc_net_iface.so" not found
E LocSvc_utils_cfg:   Error opening /vendor/etc/izat.conf  No such file or directory
E LocSvc_GnssAdapter: initEngHubProxy: failed to parse conf file          ← engine hub dead
E LocSvc_misc_utils:  dlopen failed: library "libdataitems.so" not found
W LocSvc_SystemStatusOsObserver: Unable to create dataitem:15
E LocSvc_misc_utils:  dlopen failed: library "libcdfw.so" not found
E LocSvc_GnssAdapter: initCDFWService: dlGetSymFromLib getQCdfwInterface failed
E LocSvc_misc_utils:  dlopen failed: library "liblocationservice_glue.so" not found
E LocSvc_LocationAPI:  createOSFrameworkInstance: dlGetSymFromLib failed
W LocSvc_LocIpc: send: failed reason: No such file or directory
```

…and when GPSStatus2 actually requested a fix:

```
E LocSvc_APIClientBase: locAPIUpdateTrackingOptions:406] invalid session: 0.
```

`invalid session: 0` = the HAL never got a valid QMI_LOC tracking session up before
the app asked it to update tracking options. The init failures above are upstream of
that: with the engine hub failing to parse its conf and the support plugins missing,
the location engine never reaches a usable tracking state.

### Breakdown of each blocker

1. **❌ Missing location configs (packaging gap — highest leverage, no A11 needed).**
   The source tree *has* the configs but **doesn't install them**:
   - `device/xiaomi/mithorium-common/gps/etc/` contains `izat.conf`, `lowi.conf`,
     `sap.conf`, `xtwifi.conf` — but `gps/etc/Android.bp` only defines `prebuilt_etc`
     modules for `gps.conf`, `flp.conf`, `gnss_antenna_info.conf`, and
     `gps/gps_vendor_product.mk` only `PRODUCT_PACKAGES += gps.conf flp.conf
     gnss_antenna_info.conf`.
   - Net: `izat.conf` (and `lowi.conf`/`sap.conf`/`xtwifi.conf`) **never land on
     `/vendor/etc`** → `initEngHubProxy: failed to parse conf file`. This is the most
     load-bearing miss — the engine hub proxy is core to the fix path.

2. **❌ Un-extracted proprietary plugin libs.** The HAL `dlopen`s several QTI plugins
   that aren't in the vendor image. Availability in the mounted nightly
   (`/mnt/vendor-nightly`):
   | lib | in nightly? | role | on A16? |
   |---|---|---|---|
   | `libdataitems.so` | ✅ `lib64/` | SystemStatus data-items (network/connectivity feed) | ❌ |
   | `libcdfw.so` | ✅ `lib64/` | constellation/carrier-data framework | ❌ |
   | `liblocationservice_glue.so` | ✅ `lib64/` | OS-framework glue (network-location / connectivity injection) | ❌ |
   | `liblbs_core.so` | ✅ `lib64/` | LBS core (often a transitive dep of the above) | ❌ |
   | `libloc_net_iface.so` | ❌ not in nightly | AGPS data-call / network interface | ❌ |
   | `libengine_hub.so` | ❌ not in nightly (by that name) | engine-hub proxy backend | ❌ |
   The four nightly-present libs should be staged via the same legacy extractor path
   used for `qrtr-ns`/`pm-service`. The two **not** in the nightly need sourcing —
   check whether they're (a) under a different SONAME, (b) a `+source`-built module in
   the gps tree, or (c) genuinely absent and the feature degrades gracefully. Walk the
   `DT_NEEDED` closure of each staged lib (`readelf -d`) per `PLAN-vendor-extract.md`.

3. **❌ `gps.prop` not provisioned.** HAL logs `cannot open
   file:/data/vendor/location/gps.prop`. This was the exact crash-loop trigger noted
   in `PLAN.md` §C that led to `loc_launcher` being force-stopped. Determine how stock
   provisions it (A11) — typically copied/merged from `/vendor/etc/gps.conf` +
   per-device overrides at first boot, or shipped as a prebuilt. Provision it (empty or
   default is often enough to clear the open error) before re-enabling `loc_launcher`.

4. **❌ `loc_launcher` deliberately disabled.** `init.qcom.rc:495` has `service
   loc_launcher … disabled` with a comment "Disabled until GPS config files are
   extracted … and qcrild is sourced." Both preconditions are now closer to met
   (qcrild is up; configs are step 1). `init.xiaomi.rc:65` additionally `stop
   loc_launcher` on `persist.sys.xtra-daemon.enabled=*` — and that prop is currently
   `true` on A16, so even if enabled it'd be stopped. **Note:** `loc_launcher` spawns
   the *assistance* daemons (xtra-daemon for predicted ephemeris, lowi-server for
   Wi-Fi positioning, slim_daemon for sensor assist, garden_app). A **bare GNSS fix
   does not require them** — the core position engine is a modem QMI_LOC service the
   HAL talks to directly. So loc_launcher is for AGPS/XTRA/assist quality, **not** a
   prerequisite for first-fix. Sequence it *after* a raw fix is confirmed.

5. **❌/🔧 `libloc_net_iface.so` + `LocIpc send failed`.** The IPC send failure and the
   net-iface miss are the AGPS/data-call path (SUPL over cellular data). Deferred —
   needs the cellular **data** path which radio hasn't reached yet (`PLAN-radio.md`
   item 12). Standalone GNSS doesn't need it.

---

## The dependency chain (what blocks a first fix, in order)

```
framework Location request
   ↓  (binds HIDL IGnss — ✅ works)
gnss@2.1-service-qti HAL
   ↓  parse /vendor/etc/{gps,izat,…}.conf      ← ❌ izat.conf missing → engine hub fails  [step 1]
   ↓  dlopen libdataitems/libcdfw/liblbs_core  ← ❌ not extracted                          [step 2]
   ↓  read /data/vendor/location/gps.prop       ← ❌ unprovisioned                          [step 3]
   ↓  open QMI_LOC client over QRTR  → modem    ← ✅ transport up (qrtr-ns/modem ONLINE)
   ↓  locAPIStartTracking → QMI_LOC_START_REQ   ← ❌ "invalid session: 0" (downstream of above)
GNSS engine on modem → SV measurements → fix
```

The hypothesis to validate: **steps 1–3 are what's actually wedging the session.** The
transport is proven (radio plane works), so once the HAL's own init stops failing it
should be able to open a QMI_LOC session and start tracking. The `invalid session: 0`
is almost certainly a *consequence* of the engine never initializing, not an
independent QMI_LOC fault — but confirm against A11 if it persists.

---

## Plan of attack

### Phase 0 — reconnect A11 + ground-truth the stock GPS path (do first)
Reconnect the gold A11 phone (`81eed371`), fix the `android11-adb` wrapper, then pull
the authoritative stock config + observe how stock actually runs location:
```bash
# stock location configs — the authority, replaces guessing from mithorium defaults
android11-adb pull /vendor/etc/gps.conf      ./ref-gps/
android11-adb pull /vendor/etc/izat.conf     ./ref-gps/
android11-adb pull /vendor/etc/flp.conf      ./ref-gps/
android11-adb pull /vendor/etc/lowi.conf     ./ref-gps/
android11-adb pull /vendor/etc/sap.conf      ./ref-gps/ 2>/dev/null
android11-adb pull /vendor/etc/xtwifi.conf   ./ref-gps/ 2>/dev/null
android11-adb pull /vendor/etc/apdr.conf     ./ref-gps/ 2>/dev/null
# how stock provisions the runtime prop
android11-adb shell 'ls -l /data/vendor/location/ /data/misc/location/ 2>/dev/null'
android11-adb shell 'cat /data/vendor/location/gps.prop 2>/dev/null'
# which location daemons stock actually runs (SMGR-era stack, like sensors)
android11-adb shell 'ps -A | grep -iE "loc|xtra|lowi|slim|garden|gnss|gps|izat"'
android11-adb shell 'getprop | grep -iE "gps|gnss|loc|xtra|izat|sap|supl"'
# stock SUPL/AGPS server + key gps.conf deltas vs our generic copy
android11-adb shell 'grep -iE "SUPL|AGPS|XTRA|NTP|GPS_LOCK|NMEA" /vendor/etc/gps.conf'
```
Cross-check: stock 3.18 is the **legacy IPC-router + SMGR** generation (no QRTR/no
`qrtr-ns`), exactly like sensors — so *don't* copy stock's daemon *topology* wholesale;
copy its **config values** (SUPL host, lock masks, NMEA settings) and use them to
correct our mithorium `izat.conf`/`gps.conf`. The transport stays QRTR on our side.

### Phase 1 — install the missing configs (no A11 needed; highest leverage) — ✅ DONE + VERIFIED 2026-06-26
1. ✅ Added `prebuilt_etc` modules for `izat.conf`, `lowi.conf`, `sap.conf`,
   `xtwifi.conf` in `device/xiaomi/mithorium-common/gps/etc/Android.bp` (mirrors the
   existing `gps.conf` block: `vendor: true` → installs to `/vendor/etc`).
2. ✅ Added all four to `PRODUCT_PACKAGES` in `gps/gps_vendor_product.mk` (included in
   the build via `mithorium.mk:232`).
3. ⏳ **TODO (needs A11):** reconcile the *contents* against the A11 pull from Phase 0
   (SUPL server, lock masks, etc.). Currently shipping the generic mithorium values —
   `izat.conf` ships `GTP_MODE=DISABLED`, `GTP_WAA=DISABLED`, `SAP=MODEM_DEFAULT`.
   Re-scope any pepito-specific value via `TARGET_DEVICE_PEPITO` if it diverges from
   siblings (see `PLAN.md` layering).
4. ✅ **Verified on-device 2026-06-26** (flashed + rebooted): `/vendor/etc/{izat,lowi,sap,
   xtwifi}.conf` all present; `gnss_service` restart no longer logs `Error opening
   izat.conf`, `initEngHubProxy: failed to parse conf file`, or the "Unrecognized value
   for GTP MODE / SAP Mode" warnings. HAL now parses izat.conf (`isXtraDaemonEnabled:
   xtra-daemon enabled: 1`). Remaining HAL-init errors are all Phase 2/3 (missing libs +
   `gps.prop`).

### Phase 2 — stage the proprietary plugin libs (nightly extract) — ✅ DONE IN-TREE 2026-06-26
Walked the full `DT_NEEDED` closure (`readelf -d`) and cross-checked every dep against
what's already on `android16-adb` `/vendor/lib64` (source-built or previously staged).
`liblbs_core`/`libizat_core`/`libloc_core`/`liblocation_api`/`libgps.utils`/`libmdmdetect`/
`libperipheral_client`/`libqmi_*`/`libjson`/`libsqlite`/`libxml2` are **already present**;
the 64-bit GNSS HAL is the only consumer, so 64-bit only. **7 libs** were missing and
all exist in the nightly:

1. ✅ Copied from `/mnt/vendor-nightly/lib64/` into
   `vendor/xiaomi/mithorium-common/proprietary/vendor/lib64/`:
   `libdataitems.so`, `libcdfw.so`, `liblocationservice_glue.so`, `liblocationservice.so`,
   `libloc_api_v02.so`, `libpdmapper.so`, `liblowi_client.so`.
   (The last 3 are transitive: `liblocationservice_glue`→`liblocationservice`→`liblowi_client`;
   `liblbs_core`→`libloc_api_v02`,`libpdmapper`.)
2. ✅ Wired all 7 into `PRODUCT_COPY_FILES` in
   `vendor/xiaomi/mithorium-common/mithorium-common-vendor.mk` (same legacy path as
   `libqrtr.so`). They were already listed in `proprietary-files-qc-vndr.txt` (4 of them)
   — the install mk is the authoritative path in this tree's legacy-extractor state.
3. ⏳ **`libloc_net_iface.so` deferred** — not in the nightly; it's the AGPS/SUPL
   data-call interface and needs the cellular **data** path (`PLAN-radio.md` item 12)
   anyway. Its `dlopen failed` log is non-fatal for a standalone GNSS fix. `libengine_hub`
   turned out **not** to be a real missing lib — the engine-hub *proxy* failure was
   purely the missing `izat.conf` (Phase 1, now fixed).
4. ⏳ **Verify after flash:** restart `gnss_service` → the `dlopen failed` lines for the
   7 staged libs are gone; `LocSvc_SystemStatusOsObserver: Unable to create dataitem`
   clears. (`libloc_net_iface` may still log until Phase 4.)

### Phase 3 — provision `gps.prop` + first-fix test (standalone, no AGPS) — ✅ PROVISIONING DONE IN-TREE 2026-06-26
1. ✅ Provisioned `/data/vendor/location/gps.prop` as an **empty file** seeded at boot
   in `init.qcom.rc` (`on post-fs-data`, right after the location-dir `mkdir`s; `write`
   + `chown gps gps` + `chmod 0660`). Confirmed via on-device `strings libgps.utils.so`
   that `gps.prop` is an **optional key=value override** parsed alongside `gps.conf`
   ("wrong format in gps.prop") — absence is **non-fatal** for the HAL; an empty file
   clears the `cannot open` log and pre-empts the Phase-4 `xtra-daemon` crash-loop.
   Authoritative stock provisioning still to be cross-checked against A11 (Phase 0).
   **Live-pushed + verified 2026-06-26 (no reflash):** all 7 Phase-2 libs `adb push`ed
   to `/vendor/lib64` (root remount) + `gps.prop` seeded → restart `gnss_service` →
   **all 7 staged libs load cleanly** (none appear in `dlopen failed` anymore), and the
   `gps.prop` / `izat.conf` / engine-hub errors are gone. The **only** remaining dlopen
   misses are the three known-optional ones: `libloc_net_iface.so` (AGPS, deferred),
   `liblocdiagiface.so` (diag, not in nightly), `vendor.qti.gnss@4.0-service.so` (QTI
   extension service — separate process, pulls a `vendor.qti.gnss@1.0`→@4.0 HIDL chain;
   **not** needed for a basic AOSP IGnss fix — do not chase). So the library/config
   wall is **down**; the HAL loads complete.
   **~~QMI_LOC link CONFIRMED working (2026-06-26)~~ — RETRACTED (2026-06-26, restated
   2026-07-03): `gnssNameCb` returning the static modem version string is NOT proof of a
   live QMI_LOC link** (see "Session 2026-06-26 → What this is NOT"); the authoritative
   signal is `qmi_client_get_service rc:-2` = LOC absent from the bus. Kept for the
   procedural details only: drove GPSStatus2 via ADB
   (`input keyevent WAKEUP` + `wm dismiss-keyguard` — the device was locked, which is
   why earlier `am start` left the provider `OFF`). Once unlocked + foregrounded, the
   gps provider registered a live `HIGH_ACCURACY` request (`mStarted=true`), and the
   HAL **connected to the modem's QMI_LOC engine** — proof:
   `GnssCallbackJni: gnssNameCb: name=qcom;MPSS.TA.2.3.C1-214411;` (the modem returned
   its GNSS engine identity over QRTR). So QMI_LOC-over-QRTR works end-to-end; the
   `qrtr-ns` keystone covers GPS as predicted. `IGnssPsds` (XTRA/PSDS) is absent
   (expected — that's AGPS assist).

   **Open: no SV/position yet.** Over multiple minutes with the request active:
   `GNSS measurement events = 0`, `last location=null`, no `reportSv`/NMEA. The engine
   responds to QMI_LOC queries but isn't streaming SVs. Two candidates, **must be
   distinguished by a sky-view test** (the engine couldn't be tested outdoors via ADB):
   (a) **no sky view / indoors** — cold start with no XTRA/AGPS sees nothing indoors and
   can take 5–15 min to first fix even outdoors (must decode ephemeris at 50 bps); or
   (b) the modem GNSS session isn't fully arming (RF/clock/GNSS-config). `DEBUG_LEVEL=5`
   is set in `gps.prop` but the loc stack did **not** emit verbose `LocApiV02` logs — a
   separate logging-config thread to pull if deeper tracing is needed.
   **Next: physically take the device outdoors / to a window, keep GPSStatus2 open, and
   capture** `logcat | grep -iE "reportSv|GnssSvStatus|NMEA|reportPosition|svCount"`.
   SV-in-view callbacks appearing → it's just signal/TTFF (done). Still nothing after
   10–15 min outdoors → investigate modem GNSS arming (candidate b).
2. **Do NOT** re-enable `loc_launcher` or `xtra-daemon` yet (they add AGPS/assist and
   were the prior crash-loop source). Keep `persist.sys.xtra-daemon.enabled=false` for
   the bare test.
3. Outdoors / by a window, start a fix (GPSStatus2 or `cmd location` /
   `dumpsys location`). Watch for:
   ```
   adb logcat | grep -iE "LocSvc|ApiV02|QMI_LOC|GnssAdapter|SV|fix|position"
   ```
   Success = `locAPIStartTracking` reaches a valid session (no more `invalid session:
   0`), `QMI_LOC_EVENT_GNSS_SV_INFO_IND` arrives, SVs appear in GPSStatus2, then a fix.
4. If the session still fails *after* configs+libs+prop are in: it's a genuine QMI_LOC
   service issue (modem location service not registering over QRTR) — pivot to the
   QMI-discovery angle and ground-truth against A11's location stack.

### Phase 4 — AGPS / XTRA / assist (after standalone fix works; deferred)
- Re-enable `loc_launcher` (and its assistance daemons) once configs+prop are proven;
  fix the `init.xiaomi.rc` `stop loc_launcher` trigger logic so enabling xtra doesn't
  immediately kill it.
- `libloc_net_iface.so` + SUPL/XTRA need the cellular **data** path → blocked on
  `PLAN-radio.md` item 12 (software RMNET). Wi-Fi positioning (`lowi-server`) needs
  `lowi.conf` (Phase 1) + Wi-Fi up.
- NTP/XTRA predicted ephemeris (`xtra-daemon`) needs network — re-enable last.

---

## Validation checklist (run in order)
1. `/vendor/etc/izat.conf` (+ lowi/sap/xtwifi) present on device.
2. `gnss_service` restart log: **no** `failed to parse conf file`, **no** `dlopen
   failed` for the staged libs.
3. `/data/vendor/location/gps.prop` opens (no `cannot open file` error).
4. Cold start outdoors: `invalid session: 0` is gone; `QMI_LOC` SV-info indications
   arrive; GPSStatus2 shows satellites.
5. Time-to-first-fix < a few minutes outdoors (standalone, no AGPS).
6. (Phase 4) AGPS/XTRA reduces TTFF; SUPL reachable once data is up.

---

## Two-device methodology (GPS)
When GPS misbehaves on A16, the question is "how does it work on stock A11?" — but note
the **generation gap**: stock A11 is legacy IPC-router + the SMGR-era location stack
(no `qrtr-ns`), the same split as sensors (`PLAN-sensors.md`). So from A11 take the
**config values and provisioning behavior** (SUPL host, lock masks, how `gps.prop` is
created, which assist daemons run), **not** the transport topology. Our side stays
QRTR + `qcrild` + the source-built `gnss@2.1-service-qti` HAL.

```bash
# A16 (ours): is the HAL session actually starting?
android16-adb shell 'logcat -c; setprop ctl.restart gnss_service; sleep 4; \
  logcat -d | grep -iE "LocSvc|ApiV02|QMI_LOC|GnssAdapter|EngHub|dlopen"'
# A16: confirm the QMI transport the HAL rides is still healthy
android16-adb shell 'getprop | grep -iE "modem.state|qrtrns|qcrild"'
# A11 (stock truth): config values + daemon topology (after reconnect)
android11-adb shell 'grep -iE "SUPL|XTRA|NMEA|GPS_LOCK" /vendor/etc/gps.conf'
android11-adb shell 'ps -A | grep -iE "loc|xtra|gnss|gps"'
```

---

## Service / blob cross-reference

| Item | Path | Backing | State |
|---|---|---|---|
| `gnss_service` | `/vendor/bin/hw/android.hardware.gnss@2.1-service-qti` | `libgnss.so`, `libloc_core.so` | ✅ running; IGnss@1.0–2.1 published |
| `gps.conf`/`flp.conf`/`gnss_antenna_info.conf` | `/vendor/etc/` | prebuilt_etc | ✅ installed |
| `izat.conf`/`lowi.conf`/`sap.conf`/`xtwifi.conf` | (source only) | **needs prebuilt_etc + PRODUCT_PACKAGES** | ❌ not installed → engine-hub parse fail |
| `libdataitems.so`/`libcdfw.so`/`liblocationservice_glue.so`/`liblbs_core.so` | `/vendor/lib64/` | nightly (✅ present, un-extracted) | ❌ stage from nightly |
| `libloc_net_iface.so` | `/vendor/lib64/` | not in nightly (AGPS data-call) | ❌ defer (needs data path) |
| `gps.prop` | `/data/vendor/location/gps.prop` | provisioned at runtime | ❌ unprovisioned |
| `loc_launcher` (+ xtra/lowi/slim/garden) | `/vendor/bin/loc_launcher` | assist daemons | ⏸ disabled; AGPS only, not first-fix |
| QMI_LOC over QRTR | kernel `qrtr`/`qrtr-smd` + `qrtr-ns` | modem location service | ✅ transport up (radio plane) |

## TODO order (GPS-only)
1. ▫️ **Phase 0:** reconnect A11 (`81eed371`), fix wrapper, pull stock `*.conf` +
   observe `gps.prop` provisioning + daemon topology.
2. ✅ **Phase 1 (done in-tree 2026-06-26):** packaged `izat.conf`/`lowi.conf`/`sap.conf`/
   `xtwifi.conf` (`Android.bp` prebuilt_etc + `gps_vendor_product.mk`). → expected to
   clear `initEngHubProxy: failed to parse conf file`. Pending build+flash verify;
   content reconcile to A11 still TODO. **Highest leverage.**
3. ✅ **Phase 2 (done 2026-06-26):** staged all 7 missing libs from the nightly; all load
   cleanly (`libloc_net_iface` deferred to Phase 4; `libengine_hub` was a non-issue).
4. ✅/⏸ **Phase 3:** `gps.prop` provisioned + HAL init fully clean (done 2026-06-26);
   the fix test itself is **blocked on the modem** (QMI_LOC absent — see PARKED banner).
5. 🔧 **Phase 4:** AGPS/XTRA/SUPL/lowi — re-enable `loc_launcher`, fix the
   `stop loc_launcher` trigger; blocked on cellular **data** (`PLAN-radio.md` item 12)
   for SUPL/XTRA network access.

> **STALE — superseded 2026-07-03.** Phases 1–3 are done. Resume at the top-of-file
> **PARKED banner** + **"Session 2026-07-03"** section: run the Track 1 de-risk tests
> now (stock witnesses, no modem fix needed); everything else waits on the modem
> (`PLAN-radio.md` "2026-07-02: modem-fatal status").
