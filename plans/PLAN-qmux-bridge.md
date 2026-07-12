# LineageOS 23.2 — QRTR ↔ IPC-Router QMI bridge (pepito/PVG100)

> **Started 2026-07-07 (session `qmux`).** Downstream of the qmux WIN (`PLAN-qmux.md`): the modem
> is now healthy on the **legacy IPC Router** (AF_MSM_IPC, node 0), announcing its full QMI
> surface (36 services incl QMI_LOC svc 16). But the A15 userspace radio/GPS stack speaks
> **QRTR** (AF_QIPCRTR, node 1) and looks for the modem there — where it is absent. This plan
> makes the two transports interoperate so the existing A15 userspace reaches the ipc_router
> modem, **without dragging over the A8 radio userspace.**

---
## 🎉🎉 SOLVED 2026-07-07 — NO BRIDGE NEEDED. Architecture D (transport-probe override) → LIVE TELEPHONY.

**The A15 QTI QMI stack (`libqmi_cci.so`) already contains a full IPC-Router (AF_MSM_IPC=27)
backend** (proven: `qmi_cci_xport_ipcr_deinit` + `socket(27)` at 3 call sites). It picks QRTR vs
ipcr at runtime in `qmi_cci_xprt_qrtr_supported()` by a single probe: `socket(AF_QIPCRTR)` — if it
succeeds → QRTR, if it fails **EAFNOSUPPORT** → ipcr. On our kernel QRTR exists (adsp needs it) so
it picks QRTR and misses the modem.

**Fix = a ~10-line `LD_PRELOAD` (`diag-tools/qmi-force-ipcr/qmi_force_ipcr.c`, built
`libqmi_force_ipcr.so`) that returns EAFNOSUPPORT for `socket(AF_QIPCRTR)` only.** libqmi_cci then
uses its own native ipcr backend → talks to the modem directly. No bridge daemon, no translation
shim, no A8 libs.

**VALIDATED end-to-end on DUT `c39a6acf`** (modem in the qmux WIN state; `qcrild` launched with the
preload): **`gsm.sim.state=LOADED`, operator `Verizon`, `gsm.network.type=LTE`**, framework reads
**live LTE cells** (mcc 311 / mnc 480, earfcn 5230, pci 308, tac 15, "US Mobile", EMERGENCY avail,
NOT_REG_SEARCHING), qcrild holds AF_MSM_IPC sockets, ~25 AP client ports on the ipc_router bus.
Evidence: `diag-tools/captures/qmux-ipcr-telephony-20260707/proof.txt`. (Signal still acquiring
indoors — regs show SEARCHING — but the SIM read + real cell measurements prove the full radio
stack works over ipcr.)

**⇒ The bridge daemon (Arch B) and translation shim (Arch A) below are UNNECESSARY.** Kept for
the record / as fallbacks if an edge case needs them.

### ✅✅ COLD-BOOT COMPLETE 2026-07-08 — telephony + GPS come up automatically, stable, no boot loop
A single `persist.vendor.qmux.enable=1` now yields, on the next boot: modem ipc_router-healthy
(Request count 1), **SIM=LOADED/Verizon/LTE**, and the **gnss HAL up with the shim → live `gps
provider`** (QMI_LOC svc 16 bound on ipcr), system_server stable. Validated on the DUT.

Final working design (all in files we own, ships reliably):
- **Daemons are init SERVICES** (`init.qmux.rc`): `qmux_rmt_storage` (class core) + `qmux_qcrild`
  (class main, radio user, `setenv LD_PRELOAD libqmi_force_ipcr.so`). The flip script `start`s
  them. *Why:* init runs the flip via `exec_background` and SIGKILLs its process group on exit —
  backgrounding the daemons killed them (the bug that blocked cold-boot telephony). Defining
  `qmux_qcrild` here also sidesteps the vendor `qcrild.rc` blob entirely (no more extract-revert
  fragility, no flip-script-injection fallback).
- **GPS via a conditional wrapper** (`mithorium-common` `8d3ec33`): the gnss service execs
  `gnss-qmux-wrapper.sh`, which preloads the shim **only when `persist.vendor.qmux.enable=1`** and
  otherwise execs the HAL unchanged (boot-safe; no-op on other variants). Solves both the
  init-can't-expand-`${prop}`-in-setenv problem and the boot-loop hazard.
- Commits: device `796189dc` (init services) + `fb74a46b`/`9b38b2bf` (lib + kit); mithorium
  `8d3ec33` (gnss wrapper). Kernel `c00e30cd`.

Remaining niceties: full GPS position fix outdoors; the ~14s modem-SSR in the flip still runs
mid-boot (works, but a bootarg `ipc_router_rpmsg_xprt.enable=1` + class-core stock rmt_storage
would avoid the SSR entirely); data/rmnet; sepolicy before enforcing.

### ✅✅ PRODUCTIONIZED 2026-07-10 (session `qmuxtoggle`) — flip script RETIRED, selection is static. VALIDATED ON DEVICE (two cold boots, 2026-07-10).

**Validation results:** cold boot fully autonomous — `ro.vendor.qmux.enable=1`, qmux services up
via the `on boot && =1` trigger, modem ipc_router-native from its FIRST PIL boot (`Request
count: 1`, **crash_count 0 — the early-boot rmts blip is gone**), 34 modem QMI services, SIM
LOADED / US Mobile / LTE, PS attach HOME, data CONNECTED + VALIDATED (VZWINTERNET on
rmnet_data1), IMS chain up (`QMI_DAEMON_STATUS=1`, `DATA_DAEMON_STATUS=1`, `ims_enabler=ok`).
**Boot 1 found one bug:** `init.target.rc` had its own unconditional `start vendor.rmt_storage`
(a second free-run site) → both rmt_storages ran; fixed in mithorium `0ac1b3a` (start removed;
init.qmux.rc is the single selection site) and confirmed on boot 2 (nightly never starts,
exactly one rmt_storage process). The DUT's leftover `persist.vendor.qmux.enable` was cleared
(set to empty = unset for the shim); `ro.` governs alone. Still pending: `setenforce 1` smoke
(Phase 5) and a GPS sky-view fix check.

The runtime flip (exec_background `su`-domain `qmux-flip-on.sh` + persist prop + mid-boot ~14s
modem SSR) is replaced by static boot-state selection. Commits: kernel `42169bd392bd`, device
Mi8937 `4a2f66cc`, mithorium `95880fc` (all on `pepito-rmnet`), plus a hand-edit to the
non-git generated `vendor/xiaomi/Mi8937/Mi8937-vendor.mk` (dropped `vendor.qti.rmt_storage.rc`
from PRODUCT_PACKAGES — re-appears if `extract-files` regens; the committed
`proprietary-files.txt` no longer lists it, so a regen from the committed list stays correct).

Architecture (each piece self-gates, so the build is one image for all 5 variants):
1. **Kernel** — `ipc_router_rpmsg_xprt.enable` is now an int tri-state, default `-1` = auto via
   `of_machine_is_compatible("xiaomi,pepito")`. Pepito's modem edge lands on ipc_router at the
   FIRST IPCRTR channel probe of cold boot (drivers/-before-net/ link order beats
   qcom_smd_qrtr, same mechanism the SSR re-probe validated). No SSR, and the first modem PIL
   boot should no longer fatal (kills the cosmetic crash_count=2 rmts blip). Explicit
   `enable=0/1` (bootarg or sysfs + SSR) keeps bench A/B.
2. **libinit** — sets `ro.vendor.qmux.enable` (0 default, 1 on pepito) in
   `vendor_load_properties`, before init parses triggers.
3. **init.qmux.rc** — no script, no persist trigger: `on boot && property:ro.vendor.qmux.enable=1`
   starts `qmux_rmt_storage` (now with stock `shutdown critical` + `ioprio rt 0`) +
   `qmux_qcrild` + `qmux_netmgrd` + IMS daemons; `=0` starts the nightly `vendor.rmt_storage`,
   whose service definition moved here verbatim because the blob
   `vendor.qti.rmt_storage.rc` is no longer shipped (it free-ran the QRTR rmt_storage on
   pepito). netmgrd dirs/sysctls moved into the same gated triggers. QMI clients start
   stock-shaped and block in QCCI service discovery until the modem is up (~42s) — the old
   "start qcrild after the flip" sequencing existed only because of the flip.
4. **Shim** — `qmi_force_ipcr.c` gate: explicit `persist.vendor.qmux.enable` (either value)
   wins, else `ro.vendor.qmux.enable`. Preloaded unconditionally as before (gnss rc unchanged
   mechanically).
5. **sepolicy round 2** (was parked) — `ro.vendor.qmux.` labeled `vendor_qmux_prop`;
   ims/hal_imsrtp get `vendor_qmux_prop` read + generic-socket rules; Palm `tunning`
   (mmcblk0p18) labeled `modem_efs_partition_device`; second (no-`soc/`) genfs spelling of the
   rmtfs UIO node. **No su/flip domain needed — the enforcing blocker this file tracked is
   structurally gone.**

Escape hatches (document in release notes): `setprop persist.vendor.qmux.enable 0` + reboot
no-ops every preload (daemons idle on QRTR; modem stays ipcr-side unless the kernel is also
told `ipc_router_rpmsg_xprt.enable=0` by bootarg/sysfs+SSR). The gnss boot-loop hazard class is
structurally dissolved on the production path (modem is ipcr-native before
LocationManagerService ever inits the HAL), but a MIXED override state (shims off, modem
ipcr-side) recreates it — the old hazard note below still applies to bench experiments.

Validation on next flash (cold boot, no setup): `getprop ro.vendor.qmux.enable` = 1;
`init.svc.qmux_rmt_storage/qmux_qcrild/qmux_netmgrd` = running, `init.svc.vendor.rmt_storage`
absent/stopped; `/d/rmt_storage/info` Request count ≥1 with modem crash_count **0** (blip
gone); SIM LOADED/LTE + data CONNECTED + GPS as before; then `setenforce 1` smoke for the qmux
domains. Bench flip recipe preserved at `diag-tools/qmux-flip-on.sh` (no longer in the image).

### Productization — earlier staging notes (device Mi8937 branch `pepito-qmux`, commit `fb74a46b`)
Ships the fix in the build (radio):
- `qmux/qmi_force_ipcr.c` + `Android.bp` → `cc_library_shared libqmi_force_ipcr` into
  `/vendor/lib64` (PRODUCT_PACKAGES). (LD_PRELOAD basename resolves in the default vendor lib
  path; the linker namespace refuses a `/data` preload, so it must live under `/vendor`.)
- `qmux/qcrild.rc` — device-tree override of the vendor blob (removed from `proprietary-files.txt`
  + `Mi8937-vendor.mk` PRODUCT_PACKAGES to avoid a dup install). Adds only
  `setenv LD_PRELOAD libqmi_force_ipcr.so` to qcrild/qcrild2/qcrild3; services stay `disabled`.
- `qmux-flip-on.sh` starts qcrild AFTER the modem is ipcr-healthy → one
  `setprop persist.vendor.qmux.enable 1` brings up modem + telephony. Compile-checked -Werror.

**⚠️ First productized flash (2026-07-07): qcrild.rc override did NOT ship** — the vendor
`qcrild.rc` blob overrode our device-tree copy because the untracked `Mi8937-vendor.mk` edit was
reverted by a parallel `extract-files` (the risk flagged in `fb74a46b`). `libqmi_force_ipcr.so`
shipped fine, modem came up ipcr-healthy at boot (persist qmux hook), but qcrild started on QRTR
(no shim) → no SIM/network. **Fixed `e851c6ac`:** `qmux-flip-on.sh` now detects whether the
shipped qcrild.rc carries the LD_PRELOAD and, if not, launches qcrild with the shim directly —
robust against vendor-tree churn. Verified on-device with the *shipped* .so: SIM=LOADED (Verizon),
LTE. Clean path (qcrild under init as radio user with the setenv) still wants the qcrild.rc
override to actually ship once the vendor tree settles.

### ⚠️ BOOT-STABILITY HAZARD (found 2026-07-08 — caused a boot loop)
**Enabling qmux (modem on ipc_router) on a build WITHOUT the gnss→ipcr routing boot-loops the
device.** Root cause (Watchdog stack, decisive): at boot `LocationManagerService.onBootPhase` →
`GnssNative.isSupported()` → `initializeHal()` → `native_class_init_once()` makes a **synchronous**
call into the gnss HAL that BLOCKS when the HAL can't reach QMI_LOC — and the modem being on
ipc_router while the (un-preloaded) gnss HAL still uses QRTR is exactly that. The block hangs
system_server's main thread 60s → Watchdog `*** GOODBYE!` → system_server crash-loops (bootanimation
never clears). Triggered here by setting `persist.vendor.qmux.enable=1` on a build lacking the gnss
preload. **Recovery: `setprop persist.vendor.qmux.enable 0` (+ clear `persist.vendor.qmux.gnss_preload`)
and reboot** → historical default (modem fatal) boots fine.

Implications for productionization:
- **NEVER enable qmux on a build without the gnss preload routing** (this + un-flashed device).
- The productionized build SHOULD be safe (gnss HAL preloads → uses ipcr → reaches QMI_LOC when the
  modem is healthy), BUT only if the **qmux flip completes before** LocationManagerService inits the
  gnss HAL. The flip is triggered early (`init.svc.vendor.rmt_storage=running`, class core) and gnss
  init is a late boot phase, so ordering usually holds — **but the modem SSR in the flip (~14s) racing
  the boot is a real risk; validate the productionized boot carefully before trusting auto-boot.**
- Consider a safety belt: gate location/gnss until qmux reports healthy, or bound the gnss HAL init.
- Testing hygiene: use NON-persist props when experimenting on an un-ready build (a persist
  `qmux.enable=1` makes the next reboot loop).

### Remaining
1. **Cold-boot ordering** (shared with `PLAN-qmux.md`): the flip currently runs post-boot via the
   qmux hook; qcrild starts after it. For true cold boot the modem must be ipcr-healthy before
   qcrild QMI init (bootarg `ipc_router_rpmsg_xprt.enable=1` + early stock rmt_storage). The
   `start vendor.qcrild` from the hook already sequences correctly for the enable-flow. **Now also a
   boot-stability requirement (see hazard above), not just a nicety.**
2. **GPS — ❌ REVERTED 2026-07-08 (the first attempt BOOT-LOOPED).** What was tried and why it
   failed, so it isn't repeated:
   - Attempt: `setenv LD_PRELOAD ${persist.vendor.qmux.gnss_preload:-}` in the shared source gnss
     rc (mithorium-common `fb1df5c`), property set by the flip script (device `c1bf4a32`).
   - **Failure 1 — init does NOT expand `${property}` in a `setenv` value.** LD_PRELOAD became the
     literal string `${persist.vendor.qmux.gnss_preload` → `CANNOT LINK EXECUTABLE ... library
     "${persist.vendor.qmux.gnss_preload" not found` → gnss HAL crash-restart loop → system_server
     hung binding the HAL (`GnssNative.initializeHal`) → Watchdog → boot loop.
   - **Failure 2 (latent) — shared tree.** Even if expansion worked, mithorium is shared; other
     variants (santoni/land/…) don't ship `libqmi_force_ipcr.so`, so any non-empty LD_PRELOAD
     would break their gnss HAL too.
   - Reverted: mithorium-common `5c29bbb`, device `f92bd031`. Recovered the DUT by removing the
     setenv on-device + reboot.
   **A correct GPS mechanism must be:** (a) real (no property-expansion-in-setenv), (b)
   pepito-only WITHOUT editing the shared mithorium rc with a hardcoded preload, and (c)
   **boot-safe** — a gnss HAL that can't reach QMI_LOC hangs system_server at boot (the hazard
   above), so location/gnss must be gated until qmux is healthy, or the HAL init bounded, or the
   gnss HAL launched (with the preload) only after the modem is ipcr-healthy AND only on pepito.
   The analysis that GPS *should* work once routed still holds (modem-centric loc stack, QMI_LOC
   svc 16 on ipcr, gnss HAL has no caps) — it's the *delivery* that needs a safe design.
3. **Full registration + data (rmnet):** confirm registration completes with adequate RF and the
   data path (rmnet/IPA/qmi_wwan, independent of QMI transport) works. Control plane is proven.
4. **sepolicy — ✅ STAGED 2026-07-08 (permissive-ready, not enforcing).** Collected from the
   permissive AVC denials. mithorium `b5a77c7` + device `3ef081a2`:
   - Labels: `/vendor/bin/qmux_rmt_storage` → `rmt_storage_exec` (runs in rmt_storage domain,
     inheriting uio/efs/socket); `/vendor/bin/gnss-qmux-wrapper` → `hal_gnss_qti_exec`. qcrild
     keeps the rild domain (rild_exec).
   - Rules: rmt_storage loads its A8 lib closure + /dev/diag; rild gets `self:socket
     create_socket_perms` (AF_MSM_IPC = generic `socket` class here; base rild only had ioctl);
     hal_gnss self-exec + `vendor_qmux_prop` read. rmt_storage/hal_gnss already had socket perms.
   - **Neverallow fix — NO WRAPPER (mithorium `da1b309`, device `2fdf2534`):** a gnss wrapper is
     fundamentally impossible under HAL sepolicy — `hal_neverallows.te` lets a halserverdomain
     `execute_no_trans` only `shell_exec`/`toolbox_exec` (kills a C wrapper's self-exec), a separate
     neverallow blocks anything but init transitioning into a HAL domain (kills a wrapper-domain),
     and `vendor_shell_exec` execute is also neverallowed (kills a shell wrapper). So the gnss
     service execs the HAL **directly** and preloads `libqmi_force_ipcr.so` unconditionally; the
     **shim is prop-gated internally** (only forces ipc_router when `persist.vendor.qmux.enable=1`),
     making it a no-op when qmux is off / on other variants — safe to preload everywhere. Shim now
     ships via mithorium `gps_vendor_product.mk`.
   - **Known follow-up for enforcing:** the flip script (`qmux-flip-on.sh`) still runs in the
     permissive `su` domain (init.qmux.rc `exec_background`); move it to a dedicated domain and add
     the `vendor_qmux_prop` setter before flipping to enforcing.
---

## The problem in one paragraph

`PLAN-qmux.md` proved the pepito A8 modem only completes its boot (RFSA buffer path) when the AP
speaks native **ipc_router**, not QRTR — the modem's QRTR receive/retain path is the broken half.
So the modem edge is committed to ipc_router. Its QMI services (WDS/DMS/NAS/WMS/VOICE/UIM,
QMI_LOC 16, …) now live on ipc_router node 0. The A15 vendor userspace (qcrild, loc HAL, IMS,
data) is compiled for QRTR and discovers services via the QRTR bus / `qrtr-ns`, where the modem
is invisible (`qrtr-list` on the DUT shows only adsp/node-5 + local). We need a translation layer
so QRTR-side clients transparently reach the ipc_router modem. QMI payloads are byte-identical on
both transports (QMI is transport-agnostic); only the **router framing** (node/port addressing,
HELLO, NEW_SERVER/NEW_LOOKUP control) differs — so the layer never has to parse QMI, only router
headers. Both transports use the modern **QCCI "a port is a client"** model (no QMUX/CID
multiplexing), which is what makes a router-level translation sufficient and small.

## Prior art (web research, 2026-07-07)

1. **`scintill/libqipcrtr4msmipc`** — Joey Hewitt, 2018, **GPLv3**, ~**280 LOC**, 2 files
   (`main.c` + `Makefile`). https://github.com/scintill/libqipcrtr4msmipc
   **This is our exact translation primitive, in our exact direction** (run an AF_QIPCRTR app on
   an AF_MSM_IPC kernel). An LD_PRELOAD shim that intercepts `socket`, `bind`, `getsockname`,
   `sendto`, `recvfrom` via `dlsym(RTLD_NEXT,…)` and:
   - translates `struct sockaddr_qrtr {sq_node,sq_port}` ↔ `struct sockaddr_msm_ipc`
     (`MSM_IPC_ADDR_ID`);
   - on a `sendto(QRTR_TYPE_NEW_SERVER → QRTR_PORT_CTRL)` it converts the announce into a
     `bind()` with the packet's service/instance and returns without a real send;
   - **works around a kernel bug**: `getsockname()` on AF_MSM_IPC NULL-derefs, so it uses
     `IPC_ROUTER_IOCTL_LOOKUP_SERVER` instead.
   Known limits (verbatim comments): *"TODO store on per-socket basis; for now we assume only
   one socket per program"* and *"XXX we don't know, but a valid sq_node should be good enough
   for libqrtr"*. Only `sendto`/`recvfrom` are hooked (NOT `sendmsg`/`recvmsg`). → excellent
   starting code; needs per-socket state + msg-variant coverage for a multi-client daemon like
   qcrild. Reusable directly for a **Phase-1 spike**.
2. **ModemManager — WWAN device types** (authoritative). https://modemmanager.org/docs/modemmanager/wwan-device-types/
   > "older SoCs have rpmsg support exclusively, others have both rpmsg and QRTR **(but the
   > latter not for modem management)**, and newer SoCs have full support for QRTR (including
   > modem management)."
   **Independent confirmation of our whole thesis:** for this SoC generation, QRTR exists but is
   *not the modem-management transport* — modem QMI rides rpmsg/ipc_router. Our modem is
   ipc_router-native by design; its QRTR-for-modem path was never the intended one. We are on a
   documented, well-trodden path, not fighting the hardware.
3. **`linux-msm/qrtr`** (libqrtr + `qrtr-ns`, `qrtr-lookup`, `qrtr-cfg`).
   https://github.com/linux-msm/qrtr — reference for the QMI-over-router client/service model and
   the `qrtr-ns` discovery daemon we already ship. No ipc_router bridge in-tree, but the libqrtr
   service-announce / client API is the model for the bridge's QRTR side. (In-kernel QMI + NS
   background: LWN https://lwn.net/Articles/729924/.)
4. **postmarketOS msm89x7 / pmaports !1640** ("make modem work on downstream again";
   rmtfs/qrtr). https://gitlab.com/postmarketOS/pmaports/-/merge_requests/1640 — corroborates
   that MSM8916/8937-class modem bring-up rides rmtfs + the legacy transport; general reference,
   no drop-in bridge. (Our own `reference-postmarketos-msm89x7` study aligns.)

**Takeaway:** the translation direction we need is a solved problem at the socket-shim level
(scintill, GPLv3 — license-compatible with our GPL kernel/AOSP-vendor mix for a vendor daemon or
preload). Nobody ships a turnkey *central bridge daemon* for this, so that piece we build — but
the hard primitive (AF_QIPCRTR↔AF_MSM_IPC address + control translation, incl. the getsockname
kernel-bug workaround) already exists to crib from.

## Architecture options

### A — LD_PRELOAD socket shim, per client (scintill-derived)
Inject an AF_QIPCRTR→AF_MSM_IPC translation into each A15 QRTR client (qcrild, qcrild2, loc HAL,
…) so its QRTR socket calls actually hit the ipc_router kernel and reach the modem directly. No
extra process; smallest code (start from the 280-LOC shim).
- **Pros:** tiny; direct (no proxy hop); ipc_router's *in-kernel* NS handles discovery, so no
  qrtr-ns dependency for shimmed clients.
- **Cons / risks:**
  - **AT_SECURE=1 gotcha — KNOWN on this device.** bionic ignores `LD_PRELOAD` when a binary is
    AT_SECURE (file caps / setuid). We hit exactly this on pm-service ([[pmservice-refbase-atsecure]]).
    If qcrild carries file caps, the preload is silently ignored → must drop caps per binary (as
    we did for pm-service) or the approach fails for that binary. **Decisive; check in Phase 0.**
  - Multi-socket/multi-client state (the shim's single-socket TODO) — qcrild opens many QMI
    clients; needs real per-fd state.
  - Coverage: must also hook `sendmsg`/`recvmsg`/`close`/`setsockopt` (QTI libs likely use msg
    variants), not just `sendto`/`recvfrom`.
  - Per-binary integration surface (every QRTR client that needs the modem).

### B — Central bridge daemon (recommended shipping form)
One userspace daemon holding both an AF_QIPCRTR and an AF_MSM_IPC socket. It **discovers** modem
services on ipc_router and **re-announces** them on QRTR (qrtr-ns then advertises them to all
clients normally); it proxies the data plane with a NAT-style connection table mapping each QRTR
client `{node,port}` to a dedicated ipc_router client port to the real modem service.
- **Pros:** applied ONCE; zero per-binary changes; immune to AT_SECURE (doesn't inject into
  vendor binaries); centralized, debuggable, restartable; fixes the old "QTI-remapped/absent
  service IDs on the QRTR bus" problem by announcing canonical IDs (WDS/DMS/…/LOC 16 as the
  A15 clients expect); one daemon covers ALL services generically.
- **Cons:** more code (~1–2k LOC) — connection tracking, indication routing (modem→N clients),
  SSR handling (services vanish/reappear), instance/version mirroring.

### C — In-kernel bridge (fallback)
A kernel module tying the qrtr router and ipc_router router together (forward NEW_SERVER + data
between node 0 and the QRTR bus). Most elegant re: reusing existing router machinery; highest
risk and hardest to iterate. Only if B has a perf/latency problem (unlikely — QMI is small
control-plane traffic; data rides rmnet/IPA, never QMI).

## Recommendation — staged, de-risk cheaply then build the robust form

**Phase 1 spike with A (LD_PRELOAD)** to prove end-to-end interop for the least code, then
**Phase 2 build B (bridge daemon)** as the shipping architecture (unless the spike shows the shim
path is clean AND caps-free, in which case hardening A is on the table). Rationale: the spike
validates the load-bearing unknown — *does an A15 QMI client actually complete a QMI transaction
with this ipc_router modem?* — in an afternoon, using existing 280-LOC prior art; B is then built
with that confidence and without the injection/AT_SECURE fragility for the permanent form.

---

## Phase 0 — Empirical recon (read-only, on the DUT in the WIN state)

Decides A-vs-B specifics. Bring up one QRTR client and observe.
1. **qcrild transport + caps:** `ls -lZ /vendor/bin/qcrild`; `getcap` / `getfattr -n
   security.capability /vendor/bin/qcrild` (→ is it AT_SECURE? decides if LD_PRELOAD is even
   possible without a caps-drop); `strings | grep -iE 'qrtr|qipcrtr|libqmi'` (does it use the
   open-source libqrtr we packaged, or the QTI QMI lib? — determines the interception point).
2. **What it looks up:** start qcrild manually (`setprop persist.vendor.radio.autostart 1` or
   direct exec) with the modem in the WIN state; capture its QRTR control traffic
   (`/d/ipc_logging/qrtr_0` or an strace of `sendto`/`sendmsg` to QRTR_PORT_CTRL) → the exact
   `{service, instance}` NEW_LOOKUPs it issues. This is the target set the bridge must satisfy,
   and confirms the "port = client" QCCI model on the wire.
3. **Reverse-dependency check:** does the modem, on ipc_router, ever issue NEW_LOOKUP for a
   service the AP hosts on QRTR? (Watch ipc_router `dump_servers` + the modem's lookups.) If yes,
   the bridge needs the reverse direction too; expected minimal (boot-critical AP services the
   modem consumes — RFSA/memshare/rmt_storage — are already on ipc_router).

## Phase 1 — LD_PRELOAD interop spike (fork scintill/libqipcrtr4msmipc)

Goal: one A15 QMI client completes one real QMI transaction with the ipc_router modem.
- Fork the 280-LOC shim; add `sendmsg`/`recvmsg`/`close`, minimal per-fd state (replace the
  single-socket globals with an fd→{service,instance,node} table). Keep the
  `IPC_ROUTER_IOCTL_LOOKUP_SERVER` getsockname workaround (verify it's still needed on our 4.19).
- Target the **simplest** service first — DMS (svc 2, device info: get model/IMEI) or a bare
  `qrtr-lookup`-style client — not full qcrild, to isolate transport interop from RIL complexity.
- If qcrild is AT_SECURE (Phase 0), either drop its caps ([[pmservice-refbase-atsecure]] method)
  or run the spike with a non-cap test client.
- **WIN = a QMI request from a QRTR-API client returns a modem response over ipc_router.** Proves
  the entire bridge thesis. Then decide: harden A, or build B.

## Phase 2 — Bridge daemon (the shipping architecture)

Single vendor daemon (`qmux-bridge`), C, no QMI parsing — router-header level only.
- **Discovery (ipc_router side):** open AF_MSM_IPC; enumerate + subscribe to modem NEW_SERVER/
  DEL_SERVER (node 0). Maintain the live modem service set.
- **Publication (QRTR side):** open AF_QIPCRTR; for each modem service, announce NEW_SERVER on
  the QRTR control port (qrtr-ns picks it up → all QRTR clients discover it). Mirror the
  modem's `{service, instance(version)}`; small per-service fixup table only if a client expects
  a different instance than the modem announces.
- **Data plane (NAT-style):** for each distinct QRTR client `{node,port}` that sends to a
  bridged service, lazily open a dedicated AF_MSM_IPC client port to that modem service; forward
  QMI payloads both ways verbatim; demux modem→client by the ipc_router client port; route
  indications (unsolicited modem broadcasts) to every registered client. epoll loop; a
  connection/idle timeout reaps stale entries.
- **SSR handling:** on modem SSR, tear down mapped ports, re-run discovery, re-announce on QRTR.
- **Never** userspace-send to the modem *node* over QRTR (the D-state gotcha is QRTR→modem-node;
  here the modem side is ipc_router to a *healthy* modem — but verify AF_MSM_IPC sendmsg doesn't
  block uninterruptibly on a zombie modem during SSR; use non-blocking + poll).
- Integration: init service (class late / after `qmux_rmt_storage`), gated behind the existing
  `persist.vendor.qmux.enable`; SELinux permissive during bring-up (add `qipcrtr_socket` +
  `msm_ipc_socket` rules before enforcing).

## Phase 3 — Extend & integrate

- **GPS:** once radio works, LOC svc 16 is already bridged (it's in the modem's announce set) →
  the A15 loc HAL should find it on QRTR. Combined with the done GPS userspace work
  ([[gps-bringup]]), this is the thing that *unblocks* GPS (it was blocked by LOC-absent-on-QRTR,
  `PLAN-qrtr`/`PLAN-gps`). Validate: `qmi_client_get_service()` for 16 succeeds; SVs indoors.
- **Radio up the stack:** qcrild → HIDL `IRadio/slot1` → the HIDL→AIDL `vendor.radio-compat`
  shim ([[radio-modem-transport]], `PLAN-radio-compat.md`) → framework SIM/registration. All of
  that A15 integration is preserved by the bridge.
- **Data (rmnet):** QMI control (WDS/WDA) bridges; the data path itself is rmnet/IPA/`qmi_wwan`,
  independent of the bridge. Verify after control-plane telephony works.
- **Harden:** cold-boot ordering (bridge up before qcrild binds), sepolicy enforcing, remove the
  `persist.vendor.qmux.enable` gate once stable.

## Risks / open questions

- **AT_SECURE / caps on qcrild** (Phase 0 decides) — the specific thing that could sink the
  LD_PRELOAD path; irrelevant to the bridge daemon.
- **Instance/version mismatch** per service (client filter vs modem announce) — small fixup table.
- **Indication fan-out & multi-client correctness** — the real complexity in B; get request/
  response first, indications second.
- **Reverse (modem-as-client to AP QRTR services)** — expected minimal; confirm in Phase 0.
- **AF_MSM_IPC userspace send blocking during SSR** — use non-blocking + poll, never block on a
  zombie modem.
- **licensing:** scintill is GPLv3; fine for a standalone vendor daemon/preload (not linked into
  Apache AOSP components). Keep the bridge daemon a clean-room router-level proxy; reuse
  scintill's address/ioctl translation with attribution.

## Cross-refs
- `PLAN-qmux.md` — the WIN this is downstream of (branch `pepito-qmux`; kernel HEAD
  `c00e30cd0067`, device Mi8937 HEAD `2a47c44c`); repro `diag-tools/qmux-flip-on.sh`, evidence
  `diag-tools/captures/qmux-WIN-20260707/`.
- `PLAN-qrtr.md` — the QRTR bus enumerator (`qrtr-list`/`qrtr-services`) — the bridge's QRTR-side
  measurement tool; also the original "LOC absent / radio set QTI-remapped on QRTR" finding this
  bridge resolves.
- `PLAN-gps.md` / [[gps-bringup]] — LOC 16 consumer, unblocked by the bridge.
- `PLAN-radio-compat.md` / [[radio-modem-transport]] — the HIDL→AIDL path above qcrild, preserved.
- [[pmservice-refbase-atsecure]] — the AT_SECURE/LD_PRELOAD gotcha bearing on Architecture A.

## Sources
- scintill/libqipcrtr4msmipc — https://github.com/scintill/libqipcrtr4msmipc
- ModemManager WWAN device types — https://modemmanager.org/docs/modemmanager/wwan-device-types/
- linux-msm/qrtr — https://github.com/linux-msm/qrtr
- In-kernel QMI handling (LWN) — https://lwn.net/Articles/729924/
- postmarketOS pmaports !1640 — https://gitlab.com/postmarketOS/pmaports/-/merge_requests/1640
