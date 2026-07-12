# LineageOS 23.2 — Legacy IPC-stack backport ("QMUX era": msm_ipc_router + friends) — pepito/PVG100

> **Started 2026-07-07 (session `qmux`).** Kyle's strategic decision after radio14's P2 negative:
> stop chasing single deviations, **backport the stock A11 modem-communication stack wholesale**
> so the AP end of the modem link is stock code, not an emulation of it. This formally REVERSES
> the standing guardrail "do NOT port `msm_ipc_router`" (PLAN-radio.md "Standing facts").
> Consistent with [[feedback-blackbox-before-re]]: black-box convergence over RE.

## Terminology (what "QMUX" means here)

The stock stack has TWO legacy QMI transports:
1. **`msm_ipc_router`** (kernel, `AF_MSM_IPC`=27, SMD `IPCRTR` channel) — what rmt_storage,
   kernel RFSA (`sharedmem_qmi`), memshare, and most A8 QMI clients ride. **This is the layer
   the `rmts_get_buffer` fatal lives next to — it is the backport target.**
2. **qmuxd** (userspace daemon over `/dev/smdcntl*` SMD data channels) — the older transport the
   original Palm OS radio stack used (per PLAN-qrtr.md). NOT involved in the modem-boot fatal
   window (radio13 Lane 2: only IPCRTR is open at that stage). Only needed later, and only if we
   ship the legacy radio userspace (Phase 4b). Verify on-device in Phase 0 whether stock even
   runs qmuxd (A8-era qcril usually uses IPC-router QCCI, not qmuxd).

So the concrete deliverable is: **modem edge speaks native msm_ipc_router protocol, with stock
kernel QMI services (`sharedmem_qmi`, memshare) and stock rmt_storage on top.** QRTR stays for
adsp/wcnss edges (nothing modem-side keeps using it).

## Why this can still work when "AP space is closed" (the honest EV statement)

All prior falsifications compared *content* (SMEM bytes, announcement tuples, channel sets,
hosting entity) or *shaped the QRTR presentation*. The backport changes the **protocol engine**
itself. Concrete deltas that have NEVER been presented to this modem by our AP:

- **HELLO version/capability negotiation.** Legacy HELLO is a 5-word payload
  `{cmd, checksum, versions, capability, reserved}`; the receiver checksums it against
  `IPC_ROUTER_HELLO_MAGIC` and only then negotiates the router protocol version
  (donor `net/ipc_router/ipc_router_core.c:2445` `do_version_negotiation()`, reply built at
  `:2490`; struct in `include/linux/ipc_router.h:53`). **QRTR sends a bare zeroed `cmd=2`** —
  the modem's router has been running every one of our tests in un-negotiated/legacy-fallback
  mode. This sits exactly upstream of radio13's proven-but-unexplained "NEW_SERVER(0x1C)
  received but never RETAINED in the modem's QCCI table" gap.
- **Native distributed table sync** (`process_hello_msg` → `msm_ipc_router_send_server_list`)
  with per-message flow control (`RESUME_TX`), instead of our bespoke <1ms 38-message replay
  burst. radio14 flagged the dialogue as never-tested; P2 only tested *re-announce shaping over
  QRTR*, not the native protocol.
- **Kernel QMI hosting over the native transport**: stock `sharedmem_qmi` (RFSA svc 28) and
  stock `memshare` (DHMS svc 0x34 — the prime "SMEM Kernel Service" suspect) registered through
  msm-QCSI over ipc_router, byte-for-byte stock code, instead of our QRTR reimplementations.

Counter-evidence to stay honest about: P2 proved the modem issues **zero NEW_LOOKUP and zero
buffer-service traffic pre-fatal** — if its buffer path truly never consults anything the AP
feeds (wire OR table), full protocol parity still won't fix it. That is exactly what **Phase 0
measures for one flash round-trip before we invest.**

## Verified facts this plan is built on (checked 2026-07-07)

- Our 4.19 tree is mainline-shaped: `net/qrtr/` + `drivers/rpmsg/qcom_smd.c`; **no
  `net/ipc_router`, no legacy `msm_smd` anywhere** → true backport, nothing to re-enable.
  `mi8937_defconfig`: `CONFIG_QRTR=y`, `CONFIG_QRTR_SMD=y`, `CONFIG_RPMSG_QCOM_SMD` (via
  defconfig), IPC_LOGGING present (we already use `/d/ipc_logging/qrtr_0`).
- **Stock donor source is on disk**: `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/`
  (Palm PVG100 GPL drop, 3.18). Contains everything: `net/ipc_router/{ipc_router_core.c (122K),
  ipc_router_socket.c, ipc_router_security.c,+hdrs}`, `drivers/soc/qcom/ipc_router_smd_xprt.c`,
  legacy `smd.c/smd_init_dt.c/smd_private.c`, `qmi_interface.c` (64.8K, msm QCCI/QCSI over
  ipc_router), `memshare/`, `smem_log.c`, and stock `drivers/uio/msm_sharedmem/sharedmem_qmi.c`.
  (A second copy at `~/Projects/android-pepito-pvg100-kernel-upgrade/kernel_src/`.)
- **Stock transport config from the Palm DT** (`arch/arm64/boot/dts/Pepito/msm8917.dtsi`):
  `qcom,ipc_router { qcom,node-id = <1> }` + per-edge `qcom,ipc_router_smd_xprt` nodes,
  modem edge = `ch-name "IPCRTR", xprt-remote "modem", xprt-linkid 1, xprt-version 1,
  fragmented-data, disable-pil-loading`. No GLINK on this target.
- Physical layer is proven interoperable: our rpmsg `qcom_smd` already exchanges HELLO,
  NEW_SERVER, and full RMTFS QMI transactions with this modem over the same IPCRTR channel.
  Only the protocol engine on top changes.

---

## Phase 0 — GATE ✅ RUN 2026-07-07 (Kyle, in INVERSE form) — **GREEN fork: the gate IS our AP software**

**What ran (stronger than the planned stock-on-DUT): our build flashed onto the healthy A11
unit `81eed371`** — whose modem provably takes the RFSA path every boot under stock (rfsa_req
ticks). Result: **identical `rmts_get_buffer` fatal.** Same unit, same modem binary, same
NV/EFS, same fuses; only the AP software changed ⇒ the gate is 100% in our AP stack
{kernel+DT, vendor, system}. Unit-local EFS/NV is EXONERATED as the discriminator; the
"pivot to EFS/NV repair" fork is dead; this plan's premise is CONFIRMED.

**New capabilities this unlocked:**
- **Same-unit A/B platform**: A11 toggles healthy↔fatal purely by AP software — every candidate
  fix can be validated against the unit's own stock-healthy baseline.
- **The radio6 SMEM-content wall is GONE, same-unit**: stock side has content-readable legacy
  debugfs (`/d/smem`, `/d/smsm`, `/d/smd`, radio13 find); our side has the `be41aede0590` smem
  debugfs. → Targeted same-unit SMEM/SMSM content diff (stock boot vs our boot, identical NV)
  is the cheapest decisive lane and runs in parallel with the backport. Given the modem fatals
  pre-wire, an AP-provided *local* input (SMEM content/layout/write-order) is exactly the
  suspect class this measures.

(The originally-planned stock-on-DUT flash is now redundant; run it only if evidence later
suggests the DUT has an *additional* unit-local problem.)

- **Kyle:** back up LOS state, flash stock (A11 recipe: stock boot+vendor, A11 GSI) on the DUT.
  Full UI boot not required — rmt_storage + modem only.
- **Validate:** mount debugfs → `/d/rmt_storage/info` → **Request count ≥ 1**, no
  `rmts_get_buffer api failed`; cycle per_mgr and watch it increment.
- **Fork:**
  - **Healthy** → unit NV/EFS fine; the gate IS our AP software; the backport has a
    guaranteed-reachable target on this unit. → run the capture package below, reflash LOS,
    proceed Phase 1.
  - **Fatal** → gate is device-local EFS/NV; **ABORT this whole plan** (saves weeks); pivot to
    EFS/NV diff/repair vs `pepito-stock-backup-20260706`.

**Capture package while stock is on the DUT** (defines the convergence spec; ~30 min, adb only):
1. `zcat /proc/config.gz | grep -E 'IPC_ROUTER|MSM_SMD|QMI|SMEM|MEMSHARE'` (if IKCONFIG absent,
   skip — DT + donor defaults suffice).
2. `ps -A` early and at steady state → does **qmuxd / irsc_util** run? note start order of
   rmt_storage vs modem PIL.
3. `/d/ipc_router*` dumps (`dump_servers`, routing table) + `/d/ipc_logging/` contexts
   (ipc_router, `*smd_xprt*`) across a per_mgr cycle — the native healthy dialogue, AP view
   (radio14 P1 Lane B, now on identical NV to all later pepito tests).
4. `ls -l /dev/smd* /dev/msm_ipc* /dev/smem_log`; pull `/vendor/etc/sec_config` (irsc rules) and
   the modem-related `init*.rc` snippets; `file /vendor/bin/rmt_storage` (32/64-bit) +
   `readelf -d` DT_NEEDED closure.

## Phase 1 — Donor strategy + the cheap HELLO probe (1 kernel build, do before the big port)

**1a. Cheap probe — legacy-format HELLO over the existing QRTR path.** ✅ **STAGED 2026-07-07
(session `qmux`), awaiting build+flash.** Kernel branch **`pepito-qmux`**, commit
`e2e78488375e` (parent = `c3c02d85c64d` == the radio14 flashed-lane HEAD; rollback = checkout
`pepito-bringup-lineage-23.2`). Compile-verified `net/qrtr/qrtr.o` clean (mi8937_defconfig,
clang-r574158, LLVM=1). **Sync the `pepito-qmux` HEAD to Stellaris16 before building.**

What it does: knob-gated (default OFF — cold boot identical to today). When
`/sys/kernel/debug/qrtr_replay/legacy_hello` = 1, the kernel-built HELLOs (probe-time +
per-SSR reply) carry the stock 5-word payload — checksum seeded so the receiver's
one's-complement recomputation yields `IPC_ROUTER_HELLO_MAGIC` 0xE110, `versions` from the
`legacy_hello_versions` knob, capability/reserved 0 — byte-for-byte the donor's
`process_hello_msg` reply (`ipc_router_core.c:2488-2494`), so the modem's router
checksum-validates and version-negotiates against our AP for the first time ever.
- ⚠️ **`legacy_hello_versions` defaults to `0x2` (BIT(1) = wire v1 only), NOT stock's `0xA`**:
  stock negotiates v3 (`fls(0xA)-1 = 3`) and QRTR cannot parse ipc-router v3 headers — the
  modem could switch post-HELLO traffic to a format we drop (RMTFS/EFS would break until knob
  cleared + SSR/reboot). 0x2 still exercises the checksum-valid negotiation path while pinning
  v1. `0xA` = deliberate second variant, run it LAST.
- **Run recipe (per variant, no reflash):**
  ```sh
  mount -t debugfs debugfs /sys/kernel/debug          # gotcha: manual mount
  # baseline sanity first: default knobs, one SSR → fatal + replay_last_sent≈38 unchanged
  echo 1 > /sys/kernel/debug/qrtr_replay/legacy_hello
  echo restart > /d/msm_subsys/modem                  # (wedges MSS after a few rapid cycles — reboot recovers)
  cat /d/rmt_storage/info                             # WIN condition: Request count ≥ 1
  # V2 (riskier, last): echo 0xa > .../legacy_hello_versions ; SSR ; expect possible RMTFS breakage
  ```
- Observables per SSR: `rfsa_req` (`/d/rmt_storage/info`), fatal line via smem-421 SFR
  auto-log, and a qrtr_0 ipc_logging drain across the SSR (radio14 `qcap.sh` pattern) — does
  the modem's egress change SHAPE at all (any `cmd:0xa` NEW_LOOKUP, new ctrl types, RESUME_TX,
  even undecodable RX under 0xA)?
- **Any behavior change = huge signal** and possibly a one-liner fix; negative = one cheap build
  spent, proceed with the full port. (Note: negative here does NOT falsify the backport —
  version-negotiation is one delta of several; see "revert was neutral" fallacy.)

> **❌ RAN 2026-07-07 on the DUT — DECISIVELY NEGATIVE, both variants.** Dressed HELLO went out
> per-SSR (TX cmd:0x2 confirmed in qrtr_0 log). V1 (`versions=0x2`) and V2 (stock's `0xA`):
> Request count 0, byte-identical fatal, modem egress shape unchanged (own NEW_SERVER +
> DEL_CLIENT churn, zero NEW_LOOKUP), and V2 caused no header-format fallout — the modem appears
> to ignore the HELLO payload as carried over QRTR. HELLO dressing alone is not the gate.
> Knobs reset to defaults; captures at `/data/local/tmp/qmux1a_v{1,2}.log` on the DUT.

**1b. Pick the code donor per component.** ✅ **RESOLVED 2026-07-07 — the donor was already on
disk**: `~/Projects/android-pepito-pvg100-kernel-upgrade/kernel_src` is a **CAF msm-4.9
(4.9.227)** tree carrying the complete QTI forward-port: `net/ipc_router/` (+Kconfig/Makefile,
+fifo xprt), `drivers/soc/qcom/{ipc_router_smd_xprt.c, ipc_router_glink_xprt.c, msm_smd.c,
smd.c, smd_init_dt.c, smd_private.c, qmi_interface.c}`, `include/uapi/linux/msm_ipc.h`
(AF_MSM_IPC=27 confirmed). Use it as the code donor for every Phase-2 component; stock 3.18
remains the behavior oracle (TODO before switchover: diff 4.9-vs-3.18 HELLO/table-sync paths
for behavior drift — core has ~1300 diff lines, most expectedly mechanical).

## Phase 2 — Kernel backport (each step compiles standalone; hand to Kyle in small increments)

> ⚡ **STATUS 2026-07-07 (session `qmux`): 2a–2d ALL STAGED on `pepito-qmux`** — HEAD
> `c00e30cd0067`. Full-Image link-verified locally (one real integration bug caught+fixed:
> duplicate `qmi_response_type_v01_ei` vs mainline qmi_encdec → preprocessor rename in
> `msm_qmi_interface.h`, commit `c00e30cd0067`). 2a validated ON-DEVICE (DUT flash 2026-07-07:
> `/d/msm_ipc_router` up, `MSM_IPC` in /proc/net/protocols, boot + modem behavior unchanged).
> **The 2e DT node turned out unnecessary** — defaults cover it (node-id via
> CONFIG_IPC_ROUTER_NODE_ID=1; the rpmsg xprt binds by channel name, no DT needed).
>
> ## 🎉 FLIP TEST RAN 2026-07-07 (session `qmux`) — **WIN. The rmts_get_buffer fatal is RESOLVED.**
> First time in the entire radio1–14 arc the pepito modem completes its EFS buffer path.
> On DUT `c39a6acf` (HEAD `c00e30cd0067`): started stock A8 rmt_storage on ipc_router,
> `enable=1`, one modem SSR. Result:
> - **`/d/rmt_storage/info` Request count: 1** (RFSA GET_BUFF_ADDR served) — was 0 every prior boot.
> - **NO `rmts_get_buffer api failed`** after the flip; modem holds `ONLINE`, crash_count frozen
>   at 2 (the single flip-SSR — not the endless cycling of the QRTR baseline).
> - **36 modem services announced** on ipc_router node 0 (dump_servers) — the FULL QMI surface,
>   vs ~1 (own service) before the fatal on QRTR. Includes the classic radio set
>   WDS/DMS/NAS/WMS/VOICE/UIM (absent on QRTR, PLAN-qrtr) **and QMI_LOC svc 0x10=16**
>   (inst 2, node 0) — **dissolves the PLAN-gps LOC-absent blocker and PLAN-qrtr sparse-bus.**
> - `ipcr_rpmsg_write` streamed 48–72-byte router packets to the modem (2b xprt healthy);
>   A8 rmt_storage blob RUNS on A15 bionic (Cluster-C risk cleared).
> - Evidence: `diag-tools/captures/qmux-WIN-20260707/` (dump_servers, rmt_storage_info,
>   dmesg_flip). State left LIVE on the DUT (stock rmt_storage is a transient adb-shell process;
>   make it init-managed to persist — Phase 3 hardening).
>
> **CONCLUSION: the gate was the AP transport/protocol stack all along** — QRTR's non-negotiated
> HELLO + userspace-ns table sync + QRTR-hosted kernel QMI, as a *whole*, never satisfied the
> modem's pre-wire buffer branch; the native msm_ipc_router HELLO/version-negotiation + in-kernel
> synchronous table sync + msm-QMI-hosted stock RFSA/memshare does. (1a alone was negative because
> HELLO dressing over QRTR was one piece; the win needed the whole native chain.)
>
> **ROBUSTNESS ✅ (3 forced SSRs on the DUT):** Request count ticks EVERY cycle (1→2→3→4), zero
> new `rmts_get_buffer` fatals, modem ONLINE each time — identical to stock A11's per-boot RFSA
> behavior (radio9). Not a one-shot; the buffer path is reliably healthy. (crash_count increments
> only because `echo restart` is a forced SSR — bookkeeping, not crashes.)
>
> **PROPAGATION / the telephony fork (measured on the DUT):** the healthy modem's services are on
> **ipc_router node 0** and are **INVISIBLE to the QRTR bus** (`qrtr-list` shows only adsp/node-5
> + local). So the A15 QRTR-based userspace radio (qcrild, GPS HAL) cannot see the modem yet even
> though it's healthy. This is the strategic fork:
>   - **The transport is very likely load-bearing** (the Palm A8 modem was built for ipc_router;
>     its QRTR *receive/retain* path is the broken half — every QRTR-side lever radio5–14 + 1a was
>     negative, ipc_router works with all else equal). If confirmed, a QRTR-side-only fix is
>     impossible → telephony needs the modem edge on ipc_router permanently.
>   - **Therefore telephony requires ONE of:** (4b) legacy A8 radio userspace on ipc_router (stock
>     qcrild/rild — big but every blob has a live A11 reference), or a **QRTR↔ipc_router QMI
>     bridge** so the existing A15 QRTR clients reach the ipc_router modem (smaller, novel, worth
>     scoping first), or (4a-longshot) find a QRTR-side retain fix (low odds given the evidence).
>   - **Phase 4a bisect is now about CONFIRMING transport-is-load-bearing** (and which sub-piece),
>     not finding a QRTR fix — it decides 4b-vs-bridge. Runtime knobs already on the build cover
>     part of it; the rest needs targeted kernel flashes.
>
> **DEVICE-SIDE STAGED (device repo branch `pepito-qmux`, commit `2a47c44c`):** the winning kit is
> now vendor-resident + reboot-reproducible with ZERO boot-behavior change by default —
> `qmux_rmt_storage` + its private A8 lib closure under `/vendor/lib64/qmux`, `qmux-flip-on.sh`,
> and a default-OFF `init.qmux.rc` gated on `persist.vendor.qmux.enable`. Post-flash the win is
> `setprop persist.vendor.qmux.enable 1` (no manual pushes). **TRUE COLD-BOOT still open** (needs
> the xprt enabled before the modem channel probes during *kernel* init — bootarg
> `ipc_router_rpmsg_xprt.enable=1` + early stock rmt_storage; timing needs an observed flash).
>
> → **Next: (1) Phase 4a confirm transport-is-load-bearing → decide bridge-vs-4b; (2) cold-boot
> timing (observed flash); (3) the stock-side A11 capture as root-cause confirmation.** Repro
> tooling: `diag-tools/qmux-flip-on.sh`, evidence `diag-tools/captures/qmux-WIN-20260707/`.
>
> **THE FLIP TEST (once HEAD `c00e30cd0067` is flashed; no further reflash to A/B):**
> ```sh
> mount -t debugfs debugfs /sys/kernel/debug
> # 1. swap rmt_storage to the stock A8 blob (kit pre-pushed to the DUT):
> setprop ctl.stop vendor.rmt_storage
> LD_LIBRARY_PATH=/data/local/tmp/stock-rmt /data/local/tmp/stock-rmt/rmt_storage &
> # 2. flip the modem edge to the legacy router and SSR:
> echo 1 > /sys/module/ipc_router_rpmsg_xprt/parameters/enable
> echo restart > /d/msm_subsys/modem
> # 3. observables:
> dmesg | grep ipc_rtr            # xprt up, HELLO exchange
> ls /d/msm_ipc_router/           # dump_servers: modem's services in OUR table
> cat /d/rmt_storage/info         # Request count ≥ 1 == WIN
> # revert: enable=0, restart nightly rmt_storage, SSR again → QRTR world restored
> ```
> With 2d in, this is a REAL fatal test, not just transport bring-up: kernel RFSA (svc 28,
> stock code) + memshare (0x34) sync to the modem natively at HELLO, and stock rmt_storage
> serves svc 14/EFS — the entire stock modem-facing chain, minus only irsc_util/sec_config
> (security compiled out). Risk: the A8 rmt_storage blob may not run on A15 bionic (Cluster C);
> its exec/link failure is the first thing to check (`logcat`/stderr; libs staged are the
> vendor closure — libqmi_csi/cci, libdiag, libdsutils, JRD tuning libs…; bionic/libcrypto/
> libcutils resolve from the device).

> ⚠️ Original sequencing note (superseded by the runtime flip design): steps are separately
> *compilable* and the switchover is now a RUNTIME toggle (module param + SSR), so the QRTR
> baseline is zero flashes away.

**2a. `net/ipc_router` core.** ✅ **STAGED 2026-07-07: commit `97e77f4fae9b` on `pepito-qmux`**
(donor = the msm-4.9 tree; deltas: 5.4-style wakeup API our CIP tree backported, +`<linux/of.h>`;
`CONFIG_IPC_ROUTER=y` + `NODE_ID=1` in mi8937_defconfig, SECURITY off; compiles clean, symbols
verified, full-Image link check run locally). **Runtime-inert**: no xprt, no `qcom,ipc_router`
DT node, no default-peripheral vote, nothing opens AF 27. Flash validation: boots normally,
`/d/msm_ipc_router` exists, `grep MSM_IPC /proc/net/protocols`, modem behavior unchanged.
Original spec follows:

Files: `ipc_router_core.c`, `ipc_router_socket.c`,
`ipc_router_security.{c,h}` (build with `CONFIG_IPC_ROUTER_SECURITY=n` first — default-permit,
no irsc_util needed; converge to =y + stock `sec_config` + irsc_util only if Phase 3 comes back
RED), `ipc_router_private.h`; headers `include/linux/ipc_router.h`, `ipc_router_xprt.h`,
`include/uapi/linux/msm_ipc.h` (+ non-uapi `linux/msm_ipc.h`); Kconfig/Makefile wiring.
`AF_MSM_IPC=27` collides with mainline `AF_IB` on paper — but nothing registers family 27 at
runtime in our tree (AF_IB has no proto module here); CAF shipped 27 on 4.9/4.14/4.19 the same
way. Port deltas if coming from 3.18: `sock_register`/`proto_ops` signature drift
(`accept(+bool kern)`, `sendmsg/recvmsg` lost iocb, `sk_data_ready` lost len), `setup_timer` →
`timer_setup`, wakeup-source API, `ipc_log_context` (present in our tree). Validation: boots
inert (no xprt), `/d/ipc_router` + ipc_logging contexts appear.

**2b. Transport xprt — Option A (recommended): new `ipc_router_rpmsg_xprt.c`.** ~400–600 lines
modeled on donor `ipc_router_smd_xprt.c`: an `rpmsg_driver` for channel `"IPCRTR"` gluing rpmsg
rx callbacks / `rpmsg_send` to `msm_ipc_router_xprt` ops. Preserve stock xprt properties:
`link_id=1`, initial `version=1`, fragmented-data semantics (fragment at the router layer;
single rpmsg_send per fragment — the SMD FIFO is the same one QRTR uses today, so sizes that
work now keep working). Keep the existing kernel-context-send-only rule (the userspace D-state
gotcha does not apply to the xprt, but never add userspace-triggered synchronous sends).
- **Modem-edge handoff from QRTR:** patch `net/qrtr/smd.c` probe to return `-ENODEV` when the
  rpmsg parent edge is the modem (match remoteproc/edge label), behind the 2a build knob.
  adsp/wcnss keep QRTR (sensors-QMI/audio/wifi untouched).
- **Option B (fidelity escalation only if A converges everything and still RED):** port legacy
  `msm_smd` (`smd.c`, `smd_init_dt.c`, `smd_private.c`) for the *modem edge only* + verbatim
  `ipc_router_smd_xprt.c`; carve the modem edge out of the rpmsg `qcom_smd` DT. Riskier
  (interrupt/SMEM-item sharing with the rpmsg driver on other edges); only buys SMD-signal-level
  fidelity (DTR/state bits) that rpmsg already interops through today.

**2c. Kernel QMI over ipc_router.** Donor `drivers/soc/qcom/qmi_interface.c` (64.8K msm
QCCI/QCSI) + its header → rename to `msm_qmi_interface.{c,h}` (our tree already has mainline
`qmi_interface.c` for QRTR — both must coexist). This is the substrate for 2d.

**2d. Stock QMI services, verbatim.**
- `sharedmem_qmi.c`: replace our QRTR-based re-add in `drivers/uio/msm_sharedmem/` with the
  stock file on msm_qmi_interface (the uio driver + `@0` buffer node + DT `qcom,client-id=<1>`
  stay as-is; the msm_sharedmem hook was already reconstructed to mirror stock — now it calls
  the real stock code). Brings back the real `/d/rmt_storage/info` — same observable as A11.
- `memshare/` (DHMS svc 0x34): swap our 4.19 QRTR memshare for the donor's, over
  msm_qmi_interface + DT per stock 8917.dtsi. Must-have, not optional — it's the prime "SMEM
  Kernel Service" suspect, and on stock it's kernel-hosted over ipc_router.
- Skip for now: `smem_log.c` (list as a convergence spare if RED).

**2e. DT + defconfig.** Add to `pepito.dts` (values verbatim from stock `msm8917.dtsi`):
`qcom,ipc_router { qcom,node-id = <1> }` and the modem xprt node (`ch-name "IPCRTR",
xprt-remote "modem", xprt-linkid <1>, xprt-version <1>, fragmented-data, disable-pil-loading`)
— adapt node shape to whatever binding the 2b xprt consumes. Defconfig: `CONFIG_IPC_ROUTER=y`,
xprt, `MSM_QMI_INTERFACE`, memshare; the qrtr-modem-edge knob default OFF (QRTR baseline).
Remember the build-server gotcha: **sync exact kernel HEAD to Stellaris16 before every build.**

## Phase 3 — Userspace boot-critical set + the switchover test

Only three userspace pieces matter for the fatal window (radio13 Lane 2: modem edge has ONLY
IPCRTR open pre-fatal). qmuxd/qcril/netmgrd are explicitly NOT part of this phase.

1. **Stock `rmt_storage`** (A8 blob; uio-based, `rmt_storage_alloc_buff_cb`, registers RMTFS
   svc 14 over `AF_MSM_IPC` via libqmi_csi). Stage from stock AML0 vendor with its DT_NEEDED
   closure (expect `libqmi_csi, libqmi_common_so, libqmi_encdec, libdsutils…` — exact list from
   Phase 0 capture #4). Pepito-specific stock-blob staging is the sanctioned exception per
   [[build-and-vendor-notes]]. Point the existing `vendor.rmt_storage` service at it.
   Bring-up trick: it does NOT need perfect init integration — start it manually, then per_mgr-
   cycle the modem; every SSR re-runs the whole buffer dance.
2. **irsc_util + sec_config** — only when/if `IPC_ROUTER_SECURITY=y` (not in the first build).
3. **Leave the QRTR world running** for adsp/wcnss (qrtr-ns stays). Nightly qcrild will find no
   modem services and idle/crash-loop — acceptable noise for the test build; silence it with
   `ctl.stop` during measurement if it spams.

**Validation ladder (per modem SSR; all observables are the SAME nodes as on stock A11):**
1. HELLO exchanged + version negotiated → `/d/ipc_logging` ipc_router context.
2. Modem's NEW_SERVERs appear in `/d/ipc_router` `dump_servers` (compare against A11's dump —
   identical tooling both phones for the first time).
3. rmt_storage registers svc 14; modem's ~140 EFS OPENs flow (rmt_storage log/strace).
4. `sharedmem_qmi` registered (dmesg), svc 28 in dump_servers, `/d/rmt_storage/info` exists.
5. **WIN = `Request count ≥ 1`, no `rmts_get_buffer api failed` (smem-421 SFR auto-log), modem
   reaches steady ONLINE with crash_count 0.**

**Fork:**
- **GREEN** → modem healthy on the legacy stack → Phase 4.
- **RED** → diff the dialogue against the Phase-0 stock capture with the *identical*
  instrumentation (ipc_logging + dump_servers, stock vs ours) → converge remaining deltas in
  ranked order: security on + sec_config → HELLO/versions bytes → table-sync order/flow-control
  → Option B (legacy SMD). If byte-parity on the wire dialogue is reached and it STILL fatals →
  the AP transport is exonerated for good with zero residual doubt; the gate is device/modem-
  internal (EFS/NV — should have been caught by Phase 0 — or SMEM content); un-park the RE lane
  per the radio14 guardrail ("resume only if P0–P2 dead" — this would make it truly dead).

## Phase 4 — Endgame forks (decide only after a GREEN Phase 3)

- **4a (preferred): bisect back toward the modern stack.** Flip components QRTR-ward one at a
  time to NAME the single sufficient difference: native HELLO payload → native table sync vs
  replay → kernel-QMI RFSA/memshare hosting → xprt/flow control. Whatever flip re-breaks the
  modem is the root cause → implement just that in the QRTR world, drop the rest of the
  backport, keep the nightly-aligned stack (radio-compat/GPS plans continue unchanged).
- **4b (fallback): ship the legacy modem edge.** Consequences to cost honestly: the whole modem
  userspace moves to the A8 QMI stack (stock qcril/rild — the HIDL→AIDL radio-compat shim work
  transfers, stock is IRadio-1.x-era too; GPS = stock loc stack over ipc_router, which likely
  *dissolves* the QMI_LOC-absent-on-QRTR blocker since stock GPS worked; data = netmgrd/qmuxd
  if Phase 0 shows stock uses it). Unaffected: sensors (BHy/I2C), audio (APR/rpmsg), BT, camera,
  wifi. This is Cluster C (A8 blobs on A15) writ large — sizeable but bounded, and every blob
  has a live stock reference on the bench.

## Network attach blocker — VZW MBN (session `simdebug1` 2026-07-08)

**Symptom:** live US Mobile (Verizon MVNO) SIM reads fine (LOADED, IMSI/ICCID good) but LTE attach
never completes: modem acquires the cell (`vrte 3`, not forbidden), no EMM reject, `srv status 0`
forever. **SIM proven good**: same SIM in the stock A8 phone (4373dd0f) attaches in seconds —
IMS + VZWINTERNET PDNs both up and VALIDATED. AP side proven fine: APN db has VZW row with `ia`
type (IMS), `SET_INITIAL_ATTACH_APN` completes Status 0. Hint: `ril.subscription.types=RUIM` —
modem defaulting to CDMA-era subscription mode; VZW needs the **cdmaless** carrier MBN.

**Root cause (disasm-proven):** the nightly Mi8937 qcril blob has the MBN/MCFG load flow
**stubbed out** — `qcril_qmi_nas_check_for_hardware_update()` in `libril-qc-hal-qmi.so` is
literally `strb w0; ret` (0xf6530c). MbnModule loads, PDC endpoint comes UP (svc 0x24 on
ipc_router), `qcril_qmi_start_mbn_update()` runs — and no-ops. Xiaomi ships modems with MCFG
pre-activated so their build compiled it out; Palm relies on AP-driven PDC load (stock A8:
`persist.vendor.radio.sw_mbn_loaded=1`, MBNs in `/vendor/modem_config`, mcfg p41 blank even on
stock — the activated config lives in modem EFS, put there once by stock qcril via QMI PDC).
No prop/db/file staging can revive a stubbed function — that lane is closed.

**Fix lanes:**
1. **(recommended, zero code)** One stock-flash round on the DUT with this SIM in: stock qcril
   PDC-loads + activates `mcfg_sw/generic/na/verizon/cdmaless/mcfg_sw.mbn` for this IIN; the
   selection persists in modem EFS; reflash LOS; LOS never touches PDC (stubbed) so it stays.
   Validate on stock before reflash: `getprop persist.radio.sw_mbn_loaded` = 1 (A8 prop name).
2. **(no-flash)** Small PDC client over AF_MSM_IPC svc 0x24 (LOAD_CONFIG chunked upload +
   SET_SELECTED_CONFIG + ACTIVATE_CONFIG), MBN source already on device at
   `/data/vendor/modem_config/mcfg_sw/generic/na/verizon/cdmaless/`. ~300 lines, rfsa-userd
   pattern; modest modem-EFS risk.
3. (variant of 2) drive qcrild's own MbnModule via its registered QCRIL_EVT_HOOK_* MBN oem-hook
   messages (vendor.qti.hardware.radio.qcrilhook@1.0) — HIDL client plumbing, similar effort.

**Device state left today (live-only, not in tree):** `/vendor/radio/qcril_database/` (nightly
extract — was in proprietary-files-qc-vndr.txt:452 but never extracted; **fix the extraction**),
`/vendor/modem_config/` + `/data/vendor/modem_config/mbn_ota.txt` (stock A8 payload; moot for the
stubbed qcril, useful for lane 2). Runtime `/data/vendor/radio/qcril.db` was rebuilt offline from
the nightly `upgrade/*.sql` (0..10) + manual_prov re-insert (procedure in scratchpad session
simdebug1; radio:radio 660). Radio logging left ON: `persist.vendor.radio.adb_log_on=1`; radio
logcat buffer bumped to 16M (non-persistent).

**Separate bug fixed same session — "Use SIM" toggle trap:** disable toggle deactivates UICC apps
via qcrild, but qcril's `areUiccApplicationsEnabled` getter always answers true → framework never
re-sends enable → SIM wedged NOT_READY across reboots. Fix/workaround: `setprop ctl.restart
qmux_qcrild` (qcril re-activates provisioning from its db). Don't use the toggle. Also: qcril's
`/data/vendor/radio/{qcril.db,iccid_0,…}` must be radio:radio — hand-running qcrild as root
creates them root-owned and the init-managed (user radio) qcrild can't touch them after.

## Risks / guardrails

- **P2's pre-wire evidence** = real chance full parity doesn't fix it → mitigated by the Phase 0
  gate (abort-early) and the Phase 3 RED exit (definitive exoneration is itself valuable).
- Modem-edge-only scope: do NOT touch adsp/wcnss transports (audio/sensors/wifi regressions).
- Never QRTR/ipc_router-send to the modem node from userspace tools (D-state gotcha) — unchanged.
- Keep the panic-survive patch and smem-421 SFR auto-log in all test builds.
- Kyle owns build/flash ([[feedback-user-does-build-flash]]); hand off small compilable
  increments (2a → 2a+2b → … each builds even though only the full set is flash-meaningful).
- Session hygiene: local kernel HEAD vs Stellaris16 divergence — sync before every build.

## Effort estimate

Phase 0 = one flash round-trip + 30 min captures. Phase 1a = one kernel build. Phase 2 = the
bulk: ~3–6 working sessions if msm-4.9 donor pans out (mostly mechanical), +1–2 if porting from
3.18 raw. Phase 3 = 1–2 sessions (blob closure + test cycles). Total to the decisive Phase-3
observable: **roughly a week of sessions**, with the Phase 0/1a off-ramps costing near nothing.

## Cross-refs
- `PLAN-radio.md` — radio14 P0 (== Phase 0 here), P2 negative, all standing evidence.
- `PLAN-qrtr.md` — QRTR bus enumeration tool + the original QMUX-history caution that seeded this.
- `PLAN-sharedmem_qmi.md` / RFSA re-add sections of PLAN-radio — superseded by Phase 2d if this
  plan proceeds (stock code replaces the QRTR reimplementation).
- `PLAN-radio-compat.md` — downstream either way (4a keeps it as-is; 4b re-targets it at stock qcril).
- Donor tree: `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/` (+ `~/Projects/android-pepito-
  pvg100-kernel-upgrade/kernel_src/` second copy).
