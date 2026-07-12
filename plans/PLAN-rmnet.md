# PLAN-rmnet — Mobile DATA (rmnet / IPA) over the ipc_router modem — pepito/PVG100

> **Dedicated work plan, written 2026-07-08 for a fresh agent.** This is a large, mostly-kernel
> task. It assumes NO prior context — read "Background" first. The telephony/GPS control plane
> already works; this is the DATA plane and it has one core blocker: an in-kernel QMI service that
> talks to the modem over the wrong transport.

---

## 0. Mission (one paragraph)
The Palm PVG100 (pepito) modem was brought up on the **legacy IPC Router** transport
(`AF_MSM_IPC`, "qmux") because its QRTR path is broken; telephony (SIM/LTE registration) and GPS
now work. Mobile **data** does not, because the **in-kernel IPA↔modem QMI handshake still runs over
QRTR** while the modem's data-plane QMI services live on ipc_router. **Port the in-kernel IPA QMI
layer back to the downstream `msm_qmi_interface` (ipc_router) API — as a SURGICAL REVERT, not a
rewrite** (see §4: the 4.19 tree's own git history contains the msm-qmi version of these exact
files) — then stage the missing userspace data daemons (`netmgrd`, `ipacm`) with the existing
force-ipcr shim, and bring up a data call.

> **✅✅✅ 2026-07-09 (rmnet2, same day) — PHASES 2+3 DONE TOO: MOBILE DATA WORKS.** Smoke-tested
> live on the DUT with hand-pushed blobs: DataConnectionState=CONNECTED, rmnet_data0 =
> 100.123.254.18/30, **ping 8.8.8.8 over Verizon LTE 3/3 0% loss** — first mobile data on this
> build. All changes committed; **Kyle's next build+flash makes it permanent** (no hand-pushed
> files needed after that). Commits: kernel `pepito-rmnet` (`b9d61514`+`a7fe9caab692`), device
> `pepito-rmnet` (`6fe5d7ec` netmgrd staging + `ea8c29e3` shim LD_PRELOAD scrub), mithorium
> `pepito-rmnet` (`46e63b9` librmnetctl). Blobs in vendor/xiaomi/Mi8937/proprietary (extractor
> regenerated bp/mk). Phase-3 bugs found & fixed: (1) qcrild's dsi connects to netmgrd at qcrild
> init → ordering (flip script starts netmgrd before the framework's first call; on a live system
> restart qcrild after netmgrd); (2) netmgrd's exec'd /system helpers inherited LD_PRELOAD →
> CANNOT LINK → call abort — fixed by unsetenv in the shim constructor. Post-flash validation:
> boot clean → attach → CONNECTED + ping with zero manual steps; watch the early-boot
> rmts_get_buffer blip (2 crashes at ~256s this boot, self-recovered — possibly flip ordering).
> imsdatadaemon still not ready even with data up → that's the VoLTE lane's next lever.
> Remaining here: Phase 4 sepolicy enforcing pass; ipacm only if tethering wanted.
> **Build fix (post-hoc):** librmnetctl failed `linux/rmnet_data.h not found` — the tree's
> `generated_kernel_headers` is a hand-curated UNTRACKED symlink farm at
> `vendor/lineage/build/soong/kernel/include/` (28 pre-existing links into the kernel uapi,
> absolute paths, created during earlier bring-up; travels via rsync, will NOT survive a fresh
> checkout). Added the `rmnet_data.h` symlink there. If this ever regresses on a clean tree,
> recreate the links (ls that dir on a working tree for the list).
>
> **✅ 2026-07-09 FLASH 2 — PHASE 1 COMPLETE & VALIDATED.** Crash loop gone (crash_count 2, one
> early `rmts_get_buffer` blip only), full handshake survives, modem stable. **Bonus headline:
> with the modem stable + usage=2 NV (volte session), the DUT PS-attached to home 311480 LTE and
> HELD it** — the data-plane kernel bug was attach gate #2 all along. Next = Phase 2 (netmgrd).
> Note for §4d: the modem's FILTER_INSTALLED_NOTIF (0x24) did not appear yet — likely tied to
> netmgrd/IPACM activity; recheck during Phase 2. WDA 0x1a on node 0 also to recheck then.
>
> **2026-07-09 LATER (rmnet2 cont.) — FLASH 1 VALIDATED → NEW FATAL → ROOT-CAUSED & FIXED
> (`a7fe9caab692`); AWAITING FLASH 2.** Transport port works: full handshake on the wire
> (INIT ok, ind sent, modem uploads 20 UL rules) — proven via `/d/ipc_logging/kqmi_req_resp`
> (CF/TI/MI per message; THE debug view for this work). Modem then ERR_FATAL'd 84ms after our
> install-filter response (`ipa_qmi_client.c:751 resp.error != QMI_ERR_NONE`, SSR every ~2.8s).
> Root cause: uapi `ipa_qmi_response_type_v01` here is mainline-layout `{u16;u16}` (error @ off 2)
> while the donor encodes resp members with msm's shared enum-based `qmi_response_type_v01_ei`
> (error @ off 4) → install-filter resp carried `error=1` (the `filter_handle_list_valid` byte).
> Fixed with a local u16/u16 EI table used for all 12 resp members in `_v01.c`. Also: "Got bad
> response 49 ... failed 1" = benign GET_APN_DATA_STATS refusal (healthy A11 prints it too — do
> not chase); A11 F3 capture (diag runbook, IPA files) shows the healthy modem sends
> `Filter Installed Notification to A7` ×3 right after the install resp → that 0x24 appearing on
> the DUT wire is the post-fix success marker, ahead of §4d's other checks.
>
> **2026-07-09 session "rmnet2" — PHASE 1 EXECUTED (branch `pepito-rmnet`, off `pepito-qmux`).**
> (a) **NEW EVIDENCE — the missing IPA handshake is an active modem-crash loop**: on the DUT
> (qmux on, 3h uptime) modem crash_count = **99**, dmesg shows repeating
> `modem subsystem failure reason: ipa_util.c:1088: IPA Assert: ipa_util.imm_cmd.clients[cmd_handle].init_done`
> every ~20–40s. The modem's own IPA asserts waiting for the AP's QMI_IPA_INIT_MODEM_DRIVER that
> never arrives. This likely torpedoes attach/IMS on its own → strengthens the
> data→VoLTE→attach dependency theory ([attach-domain-selection]).
> (b) **Revert executed cleanly.** Hunk-review verdict: `8be05ea1c14d` contains ZERO semantic
> changes in the 3 QMI files — pure API mechanics + error-log wording (the locking/buffer-recycling/
> late-clk items in its commit message all live in OTHER files, which we did not touch). The donor
> even retains `wwan_update_mux_channel_prop()` on filter-install, which mainline dropped.
> (c) **Plan gap found: commit `fc218ba267db` ("compatible to kernel-4.19") also touched
> `ipa_qmi_service_v01.c`** — verified 100% `.is_array`→`.array_type` rename (249/249 lines), moot
> under the revert. `_v01.c` is now byte-identical to the `670dc321` donor.
> (d) `5753f0b659cd` (DL flt rule length) re-applied verbatim; only the `req_desc.max_msg_len`
> assignment differs by idiom. All struct fields it needs exist in
> `include/uapi/linux/ipa_qmi_service_v01.h`.
> (e) **Instance encoding verified**: msm `BUILD_INSTANCE_ID(vers=1, ins=2)` = `0x201` = exactly the
> modem's IPA 0x31 instance on the live bus. AP will look up what the modem publishes.
> (f) ipa_v2 dir + full Image.gz compile-verified locally (see Workflow). Phase 0 (stock A11
> capture) NOT done — A11 was offline; backfill before/alongside the flash if desired.
>
> **2026-07-08 planning session (session "rmnet1") — findings folded in below.** Headlines:
> (a) §4 is now a **revert-based port** (commit archaeology: `670dc321` imported ipa_v2 already on
> msm_qmi_interface; `8be05ea1c14d` is the mainline-QMI conversion — the ready-made reverse-map;
> `5753f0b` is the only later QMI-file commit). Substrate symbol coverage verified.
> (b) New **Phase 0**: stock ground-truth capture on the A11 (Kyle is preparing the phone + data SIM).
> (c) **Plan B exists**: BAM-DMUX no-IPA data path, pmOS-proven on msm89x7, drivers already in tree (§4e).
> (d) Phase 2 revised: netmgrd from the **nightly** vendor first (not A8); **ipacm from in-tree
> source** and probably deferrable.

## 1. Background you need (the "qmux" bring-up)
Read these first: `PLAN-qmux.md`, `PLAN-qmux-bridge.md`, and the memory notes
`qmux-backport-lane.md`, `qmux-bridge-lane.md`. Summary:

- **The modem is on ipc_router, not QRTR.** The Palm A8 modem's QRTR receive path is broken (it's
  an ipc_router-native modem, per ModemManager's SoC-generation docs). We backported the legacy
  `net/ipc_router` + a rpmsg transport + the **`msm_qmi_interface`** kernel QMI library +
  stock RFSA/memshare, so the modem completes boot on ipc_router. Kernel branch
  **`pepito-qmux`** (kernel repo `kernel/xiaomi/msm8937`), HEAD ~`c00e30cd`. The
  `msm_qmi_interface` port is commit `1943fbc` — **this is the QMI substrate the IPA port will
  reuse**: `include/soc/qcom/msm_qmi_interface.h` + `drivers/soc/qcom/msm_qmi_interface.c` +
  `lib/qmi_encdec.c`.
- **qmux is enabled at runtime** by `setprop persist.vendor.qmux.enable 1` (persists; an init hook
  flips the modem edge to ipc_router, starts stock rmt_storage + qcrild as init services). Devices:
  DUT = A16 `c39a6acf` (our build), A11 `81eed371` (stock ground truth). `adb root` works.
- **Userspace QMI clients were fixed with a tiny `LD_PRELOAD`** (`libqmi_force_ipcr.so`, source
  `device/xiaomi/Mi8937/qmux/qmi_force_ipcr.c`): QTI's `libqmi_cci` has a built-in ipc_router
  backend and probes `socket(AF_QIPCRTR)` to choose QRTR vs ipcr; the shim fails that probe so it
  uses ipcr. **This trick is USERSPACE-only** — it does not help the in-kernel IPA-QMI.
- **On this kernel `AF_MSM_IPC` (27) maps to the generic SELinux `socket` class** (no dedicated
  class); SELinux is **permissive** (not enforcing) during bring-up.

## 2. The blocker (precise, with evidence)
- Kernel data config (already correct for stock MSM8937): `CONFIG_IPA=y` (IPA **v2**), `IPA3`/`GSI`
  off, `CONFIG_RMNET_IPA=y`, `CONFIG_RMNET=y`, `CONFIG_MSM_RMNET_BAM=y`. Driver:
  `drivers/platform/msm/ipa/ipa_v2/`. The `rmnet_ipa0` netdev **exists** on-device.
- **But `rmnet_ipa0` is DOWN, no IP**, and dmesg shows `rmnet_ipa started/completed
  initialization` → `…deinitialization` **cycling** (tracks modem SSRs) + `ipa … uC is not
  loaded, won't reset Q6 pipes`.
- Root cause: the in-kernel IPA-QMI (`ipa_v2/ipa_qmi_service.c` 1284 lines +
  `ipa_qmi_service_v01.c` 2419 lines) uses the **mainline QRTR QMI** API
  (`#include <linux/soc/qcom/qmi.h>`; `qmi_add_server`, `qmi_handle_init`, `qmi_txn_*`,
  `qmi_send_request`), hosting the AP-side IPA service (svc `0x31` "IPA_A5_SERVICE", inst 1) on
  QRTR.
- The **modem's** data QMI services are on **ipc_router** — verified on the bus
  (`/d/msm_ipc_router/dump_servers`, qmux on): IPA `0x31` (node 0, inst `0x201`, port `0x1b`) and
  WDA `0x1a` (node 0, inst 1, port `0x34`). Not on QRTR.
- ⇒ the QRTR IPA-QMI can never reach the ipc_router modem → the master-driver-init handshake never
  completes → IPA pipes/uC never set up → no data.

## 3. Why the userspace `LD_PRELOAD` trick does NOT apply
Radio/GPS are userspace `libqmi_cci` clients (flip to ipcr with the preload). **IPA-QMI is
in-kernel**; there is no preload. The AP-side IPA QMI service and its client must be moved from
QRTR to ipc_router *in the kernel* — the same class of change as the qmux RFSA/memshare backport.

## 3.5. Phase 0 — stock ground-truth capture (do FIRST; A11 + two-device methodology)
Before touching code, capture what "healthy" looks like from the stock side (A11 `81eed371`, stock
kernel+vendor — the kernel-side IPA handshake runs regardless of the GSI's userspace, so A11 is a
valid witness for this):
- `dmesg | grep -i ipa` — the init sequence, **"master driver init complete"** (or its 3.18-era
  wording), and **whether the uC actually loads on this hardware** (directly answers the §9 uC
  gotcha — if stock never loads uC, stop worrying about it).
- `/d/msm_ipc_router/dump_servers` (mount debugfs first) — the shape of the AP↔modem IPA pairing:
  AP-side IPA_A5 service registration + client connections to modem 0x31/WDA 0x1a.
- `ip link` / `ls /sys/class/net` — which rmnet netdevs stock creates (rmnet_ipa0? rmnet_data*?
  any rmnet0/BAM?). Defines the Phase-3 target state.
- Stock netmgrd/ipacm configs: `ls /vendor/etc/data/`, netmgr config XML — reference for Phase 2.
This is ~30 min and defines exactly what Phase-1/3 success looks like.

## 4. The port (Phase 1 — the load-bearing work; NO SIM needed)

**Goal:** move `ipa_v2`'s QMI layer from mainline QRTR QMI back to `msm_qmi_interface`
(ipc_router), so the IPA↔modem handshake runs on ipc_router.

### 4a. KEY FINDING — this is a revert, not a rewrite (commit archaeology, verified 2026-07-08)
The 4.19 tree's `ipa_v2` history (kernel repo, `git log -- drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c`):
1. **`670dc321d02b`** "msm: ipa: Add support of IPA2 driver" (CAF, Aug 2020, sdm660) — imported the
   whole driver **already on `msm_qmi_interface`**. Its QMI files are near-identical (24 diff
   lines) to the on-disk 4.9 archive kernel:
   `~/Personal-Projects/android-pepito-pvg100-kernel-upgrade/kernel_src/drivers/platform/msm/ipa/ipa_v2/`.
2. **`8be05ea1c14d`** "msm: ipa2: Add changes compatible to kernel-4.14" — **the msm→mainline QMI
   conversion** (814L in `ipa_qmi_service.c`, 113L in `_v01.c`, 56L in `.h`). This commit is the
   exact reverse-map for the port.
3. **`5753f0b659cd`** "Send actual DL flt rule length to Q6" (+52L) — **the ONLY later commit
   touching `ipa_qmi_service.c`**; a real Q6 bugfix that must be re-applied (only ~7 of its lines
   are QMI-API-dependent).

**Procedure:**
- `git checkout 670dc321d02b -- drivers/platform/msm/ipa/ipa_v2/{ipa_qmi_service.c,ipa_qmi_service.h,ipa_qmi_service_v01.c}`
- **Hunk-review `8be05ea1c14d` in those three files** and re-apply any *semantic* (non-API) change
  on top — the commit message admits it also touched locking, buffer recycling, and late-clk init.
  This review is the main craft in Phase 1.
- Re-port `5753f0b659cd` (translate its ~7 API-pattern lines to msm-qmi idioms).
- Reconcile `.h` consumers: `rmnet_ipa.c`, `ipa.c` etc. call the service layer; diff the checked-out
  `.h` against HEAD's for prototype drift (76-line delta vs the 4.9 donor — small).

**Blast radius verified:** mainline `<linux/soc/qcom/qmi.h>` appears ONLY in
`ipa_v2/ipa_qmi_service.h` + `_v01.c` (and ipa_v3, which we don't build). `rmnet_ipa.c` consumes
only the `ipa_qmi_service.h` API. **Substrate verified:** every `qmi_*` symbol the donor calls
exists in our `include/soc/qcom/msm_qmi_interface.h`; `qmi_kernel_encode/decode` are exported by
our `lib/qmi_encdec.c` (qmux backport `1943fbc`). The remaining "missing" names
(`qmi_init_modem_send_sync_msg`, `qmi_filter_*_send`, …) are IPA's own functions defined in
`ipa_qmi_service.c` itself.

**Donor choice: use `670dc321`/the 4.9 archive, NOT stock 3.18.** The 3.18 file is a generation
older (1207 vs 1282 lines, 113-line `.h` drift vs 76). Keep 3.18 only as a tiebreaker for
"what does the A8-era modem expect" questions.

### 4a-legacy. API conversion table (kept for reference; the revert makes most of this automatic)
The donor already uses the target (right column). Header: replace
`#include <linux/soc/qcom/qmi.h>` with `#include <soc/qcom/msm_qmi_interface.h>`.

| mainline QRTR (current 4.19) | msm_qmi_interface (target; 3.18 donor uses these) |
|---|---|
| `qmi_handle_init()` / `struct qmi_handle` (embedded) | `qmi_handle_create()` → returns `struct qmi_handle *` |
| `qmi_handle_release()` | `qmi_handle_destroy()` |
| `qmi_add_server()` (register a service) | `qmi_svc_register()` (+ `struct qmi_svc_ops_options`) |
| `qmi_add_lookup()` / new_server notify | `qmi_svc_event_notifier_register()` + `qmi_connect_to_service()` |
| `qmi_txn_init()`+`qmi_send_request()`+`qmi_txn_wait()` | `qmi_send_req_wait()` (sync) / `qmi_send_req_nowait()` |
| `qmi_send_response()` (from req cb) | `qmi_send_resp_from_cb()` / `qmi_send_resp()` |
| `qmi_send_indication()` | `qmi_send_ind()` / `qmi_send_ind_from_cb()` |
| indication handler array | `qmi_register_ind_cb()` |
| rx handled by qmi core threads | `qmi_recv_msg()` on the handle's notify (msm model) |
| `struct qmi_elem_info[]` (message descriptors) | `struct elem_info[]` (see 4b) |
| `struct qmi_response_type_v01` (mainline) | `struct qmi_response_type_v01` + `qmi_response_type_v01_ei[]` (msm, provided by msm_qmi_interface) |

The msm model is **handle + notify + `qmi_recv_msg()`** (like the stock sharedmem_qmi/memshare we
already ported), not the mainline txn/worker model. Follow the 3.18 IPA-QMI's structure verbatim
where the message set matches.

### 4b. Message tables (`ipa_qmi_service_v01.c`, ~2419 lines) — MOSTLY MOOT via the revert
The `670dc321` checkout gives you the msm-form `elem_info[]` tables directly (the conversion commit
only changed 113 lines here — descriptor renames). Just review the `8be05ea` hunks in this file for
anything beyond renames, and confirm no message tables were added after `8be05ea` (verified: none —
`5753f0b` touches `ipa_qmi_service.c` only). The old field-by-field conversion estimate ("budget
the most time here") no longer applies.

### 4c. Build + integrate
- Work on a NEW branch off `pepito-qmux` (per repo policy: `git checkout -b pepito-rmnet`).
- Keep `ipa_i.h`/the rest of the IPA driver as-is; only the QMI layer changes.
  Reconcile any `ipa_qmi_service.h` prototype/struct drift (diff the `670dc321` `.h` vs HEAD's —
  76-line delta, small).
- Compile-verify locally per file, then a full `Image.gz` link (see Workflow). Defconfig already
  has `CONFIG_IPA=y`/`CONFIG_RMNET_IPA=y`; `CONFIG_MSM_QMI_INTERFACE=y` is on from qmux.
- **Watch for symbol collisions** — the qmux backport already hit one: mainline `qmi_encdec.c`
  and msm `msm_qmi_interface.c` both define `qmi_response_type_v01_ei`; qmux renamed the msm one
  via a `#define` in `msm_qmi_interface.h` (commit `c00e30c`). IPA reusing msm's tables inherits
  that rename automatically — just don't re-introduce a mainline-qmi `qmi_response_type_v01_ei`.

### 4d. Validate Phase 1 (NO SIM required)
The master-driver-init handshake is independent of a data call. After flash, `setprop
persist.vendor.qmux.enable 1`, reboot, then on the DUT:
- dmesg: **`ipa … master driver init complete`** (or equivalent), **no** `uC is not loaded`,
  `rmnet_ipa` **stops cycling** (one clean init, no repeated deinit).
- `/d/msm_ipc_router/dump_servers`: the AP now has an IPA client/connection to the modem's `0x31`
  (a port pairing to node 0 port `0x1b`), instead of nothing.
- `rmnet_ipa0` reaches a non-cycling state (still DOWN until a data call — that's Phase 3).
- kprobe/log the IPA-QMI connect if needed. Success here means the transport is fixed.

### 4e. Plan B — BAM-DMUX data path (no IPA at all); fallback, not primary
If the modem reacts badly to the (first-ever-completed) IPA handshake, there is a real escape
hatch: **pmOS mainline msm89x7 runs mobile data over `bam_dmux` with no IPA** — the modem firmware
on this SoC family still serves the non-IPA embedded data path (see
`postmarketos-redmi4x/FINDINGS.md`; flow control = apps SMSM bits 1/11 — this is also why stock
writes the apps SMSM word). Our 4.19 tree ALREADY has the downstream drivers built in:
`drivers/soc/qcom/bam_dmux.c`, `drivers/net/ethernet/qcom/msm_rmnet_bam.c`,
`CONFIG_MSM_BAM_DMUX=y`, `CONFIG_MSM_RMNET_BAM=y`. Unknowns: whether the *Palm* modem exposes the
BAM-DMUX channel (check for rmnet0/BAM activity in Phase 0 on stock, and on the DUT dmesg), and
Android userspace would need netmgrd configured for `rmnet0` instead of the IPA netdev. Stay on
the IPA lane (it's what stock does and the revert-port is cheap); pivot here only on a hard
modem-side blocker.

## 5. Phase 2 — userspace data daemons (gated on Phase 1)
`netmgrd` + `ipacm` are **missing from the build**. Two sources each — choose deliberately:

**netmgrd — prefer the NIGHTLY vendor blob, A8/AML0 as fallback.** netmgrd is already listed in
`device/xiaomi/mithorium-common/proprietary-files-qc-vndr.txt:441` (`-vendor/bin/netmgrd;DISABLE_DEPS`,
i.e. packaged as a prebuilt module) **but was never extracted** into `vendor/xiaomi` on this box.
The nightly netmgrd was built against this exact CAF-4.19-era `rmnet_ipa` ioctl surface and runs on
Mi-Thorium siblings *with working data* — kernel-interface match by construction; it's a libqmi_cci
client so **force-ipcr fixes its transport** (same as qcrild). The A8 AML0 netmgrd
(`~/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/vendor.bin.extracted/bin/netmgrd`
1.4M) matches the modem's era but a 3.18-era kernel interface — keep it as fallback. Extraction
procedure: `PLAN-vendor-extract.md`.

**ipacm — build from SOURCE, and probably DEFER.** QTI's open-source data-ipa-cfg-mgr is already
in-tree: `vendor/qcom/opensource/data-ipa-cfg-mgr-legacy-um/ipacm/` (Android.bp present), and it's
even referenced — commented out — at `device/xiaomi/mithorium-common/mithorium.mk:276`
(`# ipacm \` + `# IPACM_cfg.xml`). No A8 blob needed. Note ipacm is mainly tethering/offload pipe
programming — **embedded data likely comes up with netmgrd alone**; start Phase 2 minimal
(netmgrd only) and add ipacm when tethering matters.

Staging (mirrors the qmux kit for rmt_storage/qcrild):
- Blobs: binary + vendor lib closure + configs (`/vendor/etc/data/*`, netmgr config XML,
  `dsi_config`, `qmi_fw.conf` if used — cross-check against the Phase-0 stock capture) into
  `device/xiaomi/Mi8937/qmux/` or a new `.../data/` dir; private lib dir via `LD_LIBRARY_PATH`
  only if going the A8-blob route (nightly blobs link against the nightly vendor already staged).
- **Force-ipcr**: add a `qmux_netmgrd` init service in `device/xiaomi/Mi8937/qmux/init.qmux.rc`
  with `setenv LD_PRELOAD libqmi_force_ipcr.so`, `start` it from `qmux-flip-on.sh` AFTER qcrild.
  It reaches WDS(1) / WDA(0x1a) / IPA(0x31) on the bus.
- Validate: runs, connects to WDS/WDA/IPA (dump_servers shows its client ports to node 0),
  programs the IPA data pipes (dmesg / netmgrd logcat).

## 6. Phase 3 — data call (NEEDS the provisioned SIM)
Enable mobile data. Flow: qcrild `QMI_WDS` sets up the PDP context → netmgrd/ipacm program IPA →
`rmnet_ipa0` gets an IP + default route. Validate: `ip addr show rmnet_ipa0` (has an IP),
`ip route`, `ping -I rmnet_ipa0 8.8.8.8`, a browser fetch, throughput. Debug with qxdm-less logs
(qcrild + netmgrd + ipacm logcat, dmesg IPA).

## 7. Phase 4 — sepolicy (permissive-ready; enforcing later)
Add domains/rules for `netmgrd`/`ipacm` (base types exist in the legacy QTI sepolicy; `netmgrd.te`
is already in `device/xiaomi/mithorium-common/sepolicy/vendor/`). Give them the ipc_router socket
like `rild` got (`allow <domain> self:socket create_socket_perms;` — AF_MSM_IPC = generic `socket`
class here). Fold into the qmux enforcing pass. Not blocking while permissive.

## 8. Environment & workflow (how work actually gets done here)
- **You STAGE; Kyle BUILDS & FLASHES.** Do NOT run build scripts / dd / flashing / EDL. Hand off
  small compilable increments; describe what to build/flash/validate, then stop. On-device
  diagnostics over `adb` are fine and encouraged.
- **Kernel compile-check locally** (no flash): use the in-tree clang and mi8937_defconfig, e.g.
  ```
  SCRATCH=<scratchpad>; PATH=<repo>/prebuilts/clang/host/linux-x86/clang-r574158/bin:$PATH \
    make O=$SCRATCH/kout ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- mi8937_defconfig
  make O=$SCRATCH/kout ... drivers/platform/msm/ipa/     # per-dir
  make O=$SCRATCH/kout ... Image.gz -j$(nproc)           # full link — catches symbol/section issues
  ```
- **Remote build server** for Kyle's real builds: Stellaris16 `10.0.2.43` via
  `scripts/build-lineage23-remotely.sh`. **GOTCHA: sync your exact branch HEAD to the build server
  before asking Kyle to build** — local vs build-server divergence has bitten this project.
- **Per-repo branching:** make a new branch in each git repo you touch (kernel, device, mithorium)
  rather than committing on `pepito-qmux` directly, so it's easy to roll back. (Kyle asked for
  this.) Only stage YOUR files — parallel agents have unrelated uncommitted work in these repos.
- **Two devices:** DUT A16 `c39a6acf` (build), A11 `81eed371` (stock reference). `adb -s <serial>`.
  `adb root` works; re-`adb root` after reboots.
- **Enable qmux for testing:** `setprop persist.vendor.qmux.enable 1` then reboot (persist). To
  read the modem bus: `mount -t debugfs debugfs /sys/kernel/debug` then
  `cat /d/msm_ipc_router/dump_servers`. To force a modem re-init: `echo restart > /d/msm_subsys/modem`.

## 9. Gotchas (hard-won; will bite you)
- **BOOT-LOOP if you enable qmux on a build whose gnss/HALs aren't ready** — an unrouted gnss HAL
  init hangs system_server → Watchdog. The current productionized build is fine; just be aware if
  you change HAL wiring. Recovery: `setprop persist.vendor.qmux.enable 0` + reboot.
- **init does NOT expand `${property}` in `setenv`** (it sets the literal string). Gate per-service
  env with a small C wrapper (see the gnss `gnss-qmux-wrapper.c` precedent), never `${...}`.
- **`exec_background` init scripts get their process group SIGKILLed on exit** — long-running
  daemons MUST be defined as init `service`s and `start`ed, not backgrounded from the flip script.
- **A HIDL/HAL SELinux domain executing a shell trips a platform neverallow (build failure)** —
  prefer C wrappers over shell wrappers for anything a HAL domain execs.
- **`/vendor` is read-only** by default; `mount -o remount,rw /vendor` (as root) for on-device
  edits (lost on reflash). dm-verity is `yellow`/relaxed so edits don't brick, but reflash to reset.
- **IPA uC firmware:** `uC is not loaded` may be partly a firmware-staging issue (`ipa_fws`/`ipa_uc`
  images) separate from the QMI transport — check `ipa_fws` presence/loading during Phase 1; the
  IPA v2 path may run without uC (SW path) but confirm. **Phase 0 answers this cheaply**: if stock
  A11 never loads uC either, it's a non-issue.
- **`8be05ea` is not pure API conversion** — its message admits locking, buffer-recycling, and
  late-clk-init changes. The revert MUST be hunk-reviewed so 4.14-era semantic fixes are re-applied
  on top of the `670dc321` files. This is where Phase-1 bugs would come from.
- **Budget one modem-fatal debug iteration.** The old note "CONFIG_RMNET_IPA crashed the modem"
  (PLAN.md TEMP table) dates from the QRTR era. After the port, the AP completes the IPA handshake
  with this modem **for the first time ever** — if some message *content* (not transport) upsets
  it, expect an ERR_FATAL. The SSR panic→pr_err downgrade is still in place and the diag toolkit
  ([[diag-capture-a11-modem-f3]] etc.) applies; don't be surprised, instrument and iterate.
- **Phase-3 "interface up, IP assigned, no packets"** → first suspect is WDA/QMAP data-format
  mismatch: netmgrd's `WDA_SET_DATA_FORMAT` vs the kernel `rmnet_ipa` mux/aggregation config must
  agree (also the classic LineageOS no-mobile-data failure signature). Compare against the Phase-0
  stock netmgr config.

## 10. Reference index
- **PRIMARY donor:** kernel commit `670dc321d02b` (== the 4.9 archive
  `~/Personal-Projects/android-pepito-pvg100-kernel-upgrade/kernel_src/drivers/platform/msm/ipa/ipa_v2/`,
  24 diff lines). Reverse-map: `git show 8be05ea1c14d`. Re-apply: `git show 5753f0b659cd`.
- **Secondary/tiebreaker only:** 3.18 stock donor
  `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/drivers/platform/msm/ipa/ipa_v2/` (msm-qmi IPA,
  modem-era message expectations).
- **ipacm source (build, don't blob):** `vendor/qcom/opensource/data-ipa-cfg-mgr-legacy-um/ipacm/`;
  enable via the commented block at `device/xiaomi/mithorium-common/mithorium.mk:276`.
- **Plan B drivers:** `drivers/soc/qcom/bam_dmux.c`, `drivers/net/ethernet/qcom/msm_rmnet_bam.c`
  (both config'd on already); pmOS evidence `postmarketos-redmi4x/FINDINGS.md`.
- **QMI substrate (already in-tree):** `kernel/.../include/soc/qcom/msm_qmi_interface.h`,
  `drivers/soc/qcom/msm_qmi_interface.c`, `lib/qmi_encdec.c` (qmux commit `1943fbc`).
- **File to port:** `kernel/.../drivers/platform/msm/ipa/ipa_v2/{ipa_qmi_service.c,
  ipa_qmi_service_v01.c,ipa_qmi_service.h}` (currently mainline-qmi).
- **Userspace blobs:** `~/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/vendor.bin.extracted/`
  (`bin/netmgrd`, `bin/ipacm`, `bin/ipacm-diag`, `lib64/*`, `etc/data/*`).
- **force-ipcr shim:** `device/xiaomi/Mi8937/qmux/qmi_force_ipcr.c` → `libqmi_force_ipcr.so`.
- **qmux init/flip:** `device/xiaomi/Mi8937/qmux/{init.qmux.rc, bin/qmux-flip-on.sh}`.
- Plans: `PLAN-qmux.md`, `PLAN-qmux-bridge.md`. Memory: `qmux-backport-lane`, `qmux-bridge-lane`,
  `rmnet-data-plane`.

## 11. Recommended order (revised 2026-07-08)
0. **Phase 0** stock ground-truth capture on A11 (§3.5) — IPA dmesg, uC?, dump_servers pairing,
   netdev inventory, stock netmgr configs. Kyle is preparing the A11 + a data SIM.
1. `git checkout 670dc321d02b -- <the 3 QMI files>` on a new `pepito-rmnet` branch (off
   `pepito-qmux`).
2. Hunk-review `8be05ea1c14d`; re-apply non-API semantic hunks. Re-port `5753f0b659cd`.
3. Reconcile `.h` consumers; compile-clean per-dir, then full `Image.gz` link.
4. Hand to Kyle to flash; validate the handshake (Phase 1 / §4d, no SIM) against the Phase-0
   stock picture.
5. Phase 2: extract + stage nightly netmgrd (force-ipcr); ipacm-from-source only when tethering
   matters. 6. Phase 3 data call (SIM). 7. Phase 4 sepolicy.
If a hard modem-side blocker appears at step 4, evaluate Plan B (§4e BAM-DMUX) before burning
sessions on IPA message content.
