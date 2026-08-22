# PLAN-wifi-calling — VoWiFi (Wi-Fi Calling) on pepito — **EVIDENCE ARCHIVE**

> ⛳ **The active plan is [`PLAN-vowifi.md`](PLAN-vowifi.md)** — what to do next, in ~200 lines.
> **This file is the historical record**: parts 1–18, every hypothesis raised and how it was
> killed, the tooling ground truth, and the captures index. Come here to find out *why* something
> is already ruled out, or to recover a technique — not to plan work. Nothing further should be
> appended here; new findings go in `PLAN-vowifi.md` and only get archived back once settled.


**Status (2026-08-06, part 17 — READ THIS FIRST):** ✅ **The carrier-activation confound was raised, tested, and CLOSED in one session. Part 15's verdict is RESTORED — now on real evidence.** The gate is genuinely structural: it is not reading carrier entitlement, Wi-Fi availability, or WFC provisioning. **The RE lane is unambiguously the whole story.**

1. **The gate:** `QPConfigurationHandler::qpGetPreferredRAT` (`qpIMSPolicyManager.cpp:504→510`) reads `ratMask N WFC 2 CallmodePreference 1` and takes the **"WFC OFF"** branch; `extractIWLANRAT` (:449) and the `WFC ON` branch (:524) **never run**. Downstream, `qipcallh_if_wifi_calling_enabled → ret 0`.
2. ⭐⭐⭐ **THE CONTROL THIS LANE NEVER HAD (part 17, `cap-p17c`).** Kyle correctly objected that *no SIM in parts 9–16 had carrier-side WFC activated at capture time* — he enabled it only on 2026-08-06, after every capture. So the "carrier-independent" claim rested on two unprovisioned lines. **Tested properly:** Warp SIM moved into the F3 rig, with **every** variable satisfied at once — carrier-activated **and Pixel-verified end-to-end (airplane-mode Wi-Fi call)**, `wifi_call=2 (ON)` + `pref=1 (WLAN_PREFERRED)` in the modem, `client_prov=1`, `volte=1`, **IMS REGISTERED**, **Wi-Fi UP at 10.0.2.106 throughout**, VZW CDMAless MBN live (`EPDG_FQDN length 12`). Result:
```
qpGetPreferredRAT invoked          35        WFC OFF branch (:510)   35/35
WFC ON branch (:524)                0        extractIWLANRAT (:449)   0
ratMask distribution:  1 (×22), 1024 (×8), 32768 (×4)   — never 0x40
qipcallh_if_wifi_calling_enabled: wfc_status - 2  →  ret - 0   (×80)
ds_iwlan_s2b_profile_is_wlan_pref: IWLAN? 0   (apn len 3 ×70, len 11 ×56)
DplHandOverSetCNEProfileForMetrics: never called
```
  **Byte-identical to the unactivated captures.** ⇒ Carrier activation, Wi-Fi presence, and full provisioning change **nothing**. The confound is closed and the hypothesis is falsified.
3. ⭐⭐ **RAT encoding CONFIRMED live (part 16's inference was right): bit *n* ↔ RAT *n*.** `ratMask 1024 → extractGWTOrLRAT ratVal 10 → returning 10`; `ratMask 1 → ratVal 0`. So LTE=10↔`0x400`, and **IWLAN=6 would be `0x40` — a bit that has never appeared in any mask across every capture in this lane.** ⇒ **The live lead stands and is now the best one: suspect the caller that BUILDS `ratMask`, one level above the predicate.** It is not carrier state, not Wi-Fi state, and not the WFC store — all three are now excluded by experiment.
4. **RE route:** Ghidra 12.1.2 + Hexagon has the image fully analysed; scripts + dumps preserved at `diag-tools/modem-re/`. 🔴 The IMS module's msgid→code mapping is **proven unrecoverable** by any affine base (3 attacks, working controls) — **find the function structurally, do not retry msgid arithmetic.**
5. **Part 18 (2026-08-06, offline analysis + 4 live rig captures): a new modem input found and controlled — but it is not the gate.** The Wi-Fi **radio switch** (ps_sys `PS_SYS_CONF_DATA_SERVICE_WIFI_SETTING`) read **0** on both units while Wi-Fi was up, and `PDPManager.cpp:878 HandleWifiRadioChange` had never fired in this lane. ✅ **`DSD 0x34 TLV 0x13` (u8) sets it, `0x35` reads it — confirmed live**, with the whole chain logged by the modem (`ds_qmi_dsd.c:4698` → `ds_mppm` → `ds_iwlan_s2b` → `qpDcm.c:12698` → `PDPManager.cpp:878`). It **resets to 0 on every modem restart**, and a no-change write is absorbed — force `0→1`. 🔴 **With the switch ON, the gate is unchanged**: 3 further `:504` evaluations, `ratMask` still `1024`, WFC-OFF 3/3, `ret - 0` ×49. ⭐ It is the first input ever to provoke IMS into `GetIMSAllowedServices RAT = 6` (IWLAN). ✅ Also excluded en route: **`CallmodePreference` = the IMSS `0x53 0x15` preference; both 1 and 3 take WFC-OFF.** ⇒ Of the branch's three logged inputs, two are now experimentally dead; **`ratMask` is the whole remaining question, and it is built upstream of PDPManager** (already IWLAN-free at `HandleRatNotification :1017`, which is fed by CM/DS). **Next capture should widen the filter to `cmph|ds_mppm|ds_3gpp` around a `:1017` event** — the mask's origin has never been looked at. Also: `ServiceOnRatMask = 0x644e` **has bit 6 set** ⇒ IWLAN is configured and allowed; only the live mask lacks it.
6. ⚠️ **Do not re-run carrier/SIM experiments.** Every combination that could matter has now been observed. Evidence: `diag-tools/captures/a11-rig-wfc-f3-20260805/part17-WARP-*`.

Earlier status entries below.

**Status (2026-08-06 part 15):** ⚠️ **The conclusion below was asserted on inadequate evidence — neither line was WFC-activated carrier-side at capture time — but part 17 re-ran it as a proper control and the conclusion HELD.** Read part 17 for the evidence that actually supports it. Original text unchanged.

⭐⭐⭐ **The gate is CARRIER-INDEPENDENT — proven.** A native-PLMN T-Mobile line (US Mobile × TMO, 310260, IMS REGISTERED, both runbook gates passed) hits the *identical* wall as Verizon: `qipcallh_if_wifi_calling_enabled: wfc_status 2 → ret 0`. Per part 13's own framing this is the stronger outcome — the block is **structural, not a Verizon entitlement refusal**, and the RE is now unambiguously the whole lane. ⭐⭐⭐ It also produced a **much better RE target** than qipcallh: `qpIMSPolicyManager.cpp:504→510` — `qpGetPreferredRAT` reads `ratMask N WFC 2 CallmodePreference 1` and takes the **"WFC OFF"** branch **78/78 on TMO and 32/32 on VZW**, so `extractIWLANRAT` (line 449) and the `WFC ON` branch (line 524) *never* run. The predicate is **4 source lines**, all its inputs are logged, and msgids `164805/164806/164807` are consecutive (⇒ 3 adjacent QSR descriptors = a strong binary fingerprint). Meanwhile TMO *does* differ everywhere else — `OperatorMode 9` (vs 0), `GetPreferredRAT with Measurements` runs, ANDSF RAN measurements run, priority-list `change bitmask:5` — so the rest of the chain is alive and carrier-sensitive; only the WFC gate is stuck. **Next: Ghidra (Hexagon) → read the `:504→:510` predicate.** Earlier:

**Status (2026-08-05 part 14):** ⭐⭐ RE lane groundwork done, target not yet located. The prerequisite for *any* modem RE in this project is solved: **QSR4 msgids are not stored in the image** — code materialises `QSR_BASE + 8 × msgid` into a NOLOAD `0xf8xxxxxx` section via Hexagon `immext`, and the DIAG runtime converts pointer→msgid. Main-module base is `0xf8000000` (89,840/106,271 descriptors fit); **IMS lives in a second module** (msgid band 140000–219999) whose base solves to ≈`0xf84f73xx` but **cannot be pinned to a single 8-byte slot statistically** — adjacent slots map to adjacent msgids in the same file, so locality/purity scoring plateaus. `qipcallh.c` compiles to ≈`0x8720f000`–`0x87290000`. ⚠️ Also learned: `llvm-objdump` text output desyncs on data-in-code and silently drops whole files' immediates — decode `immext` from raw words. **Next: Ghidra (Hexagon) for function boundaries + xrefs**, then read `qipcallh_if_wifi_calling_enabled`'s predicate. In parallel: TMO-MVNO SIM inbound for the part-13 runbook discriminator. Earlier:

**Status (2026-08-05 part 13):** ⭐⭐⭐ `req_wqe_prof_mask == 0` is **a symptom, not the cause** — the chain above it is now mapped end to end from the modem's own F3. IMS **does** run its handover machinery and **does** push the WFC Wi-Fi thresholds to ANDSF; what it never does is hand the HO engine a target RAT of IWLAN: `qpDplHandOverParamsSet_ex: Unprocessed SRAT = 0, TRAT = 0` (NONE/NONE), because qipcall computes `TRAT MASK 0x00`, because `qipcalliface_get_ho_wlan_srv_status` returns "no service" (17), and ultimately because `qipcallh_if_wifi_calling_enabled` returns **0 despite `wfc_status=2`, `dm_vowifi_disabled=0`, `dm_volte_disabled=0`** — an undiscovered 4th condition. With TRAT never IWLAN, `qpDplWiFiMeasurementsSetParamEx` never inits, so `DplHandOverSetCNEProfileForMetrics` (the sole writer of `req_wqe_prof_mask`) is never called. **Both of part 12's "next" suspects are dead:** `Enable VoWifi = 1` already (iDM_Services_Mask is fine), and the SET_HANDOVER_CONFIG lever was exercised live (below). Also found: a genuine **modem-internal cold-boot race** (IMS pushes the thresholds while ANDSF's ICCID is still invalid) — real, but not the gate. **Next: narrow RE of `qipcallh_if_wifi_calling_enabled`'s 4th condition** — the one remaining unknown. Earlier:

**Status (2026-08-05 part 12):** ⭐⭐⭐ The gate is **`req_wqe_prof_mask == 0`** — ANDSF's WLAN-quality (WQE) machinery is never armed, so it never measures Wi-Fi, so the VZW MAPCON `WiFiAvailable` condition can never be evaluated, so the ims APN stays cellular-first and `is_wlan_pref` returns 0. Only **IMS** can arm it (`qpDplHandOver.c DplHandOverSetCNEProfileForMetrics` → `DS_SYS_IOCTL_SET_WQE_PROFILE_TYPE`), and it never makes that call — **the arming order is IMS → ANDSF → AP report, i.e. the opposite end of the chain from where we have been pushing.** Also this session: the `0x20 WLAN_AVAILABLE` TLV map was ground-truthed and our four-session-old report proved **malformed** (`0x12` is `wqe_status`, not DNS — the old "DNS rejected" mystery); a correct full report is accepted and parsed but still inert. First ANDSF priority-list dump obtained (policy IS loaded; ims carries a second tech, ordered cellular-first). DSD `0x29`/`0x22` proven inert from the modem's own logs. IMS handover config (IMSS `0x5e`) already holds valid Wi-Fi thresholds −65/−80. **Next: what makes IMS arm WQE** — SET_HANDOVER_CONFIG's unset tail, the `Enable VoWifi` bit in `ims_settings_set_ims_config`, else targeted RE of that caller. Earlier:

**Status (2026-08-05 part 11):** ⭐⭐⭐ The `is_wlan_pref` gate (part 9) is the modem's **own ANDSF rule manager**, MBN-provisioned (`/data/andsf.xml` + `andsf_rule_mgr_active:1` in `/data/ds_andsf_config.txt`). VZW policy even says "WiFi available + idle → WLAN preferred" (MAPCON_6) — so the evaluation is failing on a condition input, not on missing policy intent. Profile-store hypothesis FALSIFIED (no WLAN-pref param exists; 0x35=apn_bearer has no IWLAN bit; 0x3e=roaming_disallowed). All DSD levers (0x20/0x22/0x29) accepted-but-inert even combined. **Next: F3 capture of the ANDSF evaluation on the rig with the SIM** (grep `ds_andsf`/`APNPriorityListInfo`), DIAG EFS verify of the policy files, and if needed a forced-WLAN policy EFS write on the rig. Earlier:

**Status (2026-08-04 part 6):** new lane, not blocking release. ⭐⭐ Path (A) CLOSED (part 5: no AP-side IWLAN arming API in this firmware). ⭐⭐ **Path (B) AP-side chain fully bench-validated (part 6): cnd was never broken (ICneService is factory-vended), CneApp↔cnd↔datad↔modem-DCM all live; only missing AP hop = CneApp as priv-app (restricted-network permission). Yet the modem still never initiates WLAN (no GET_WIFI_QUALITY, no RAT=WLAN PDP_ACTIVATE) even with everything armed** — remaining suspect is a modem-side entitlement/arming input; discriminators = A11 F3 capture, then an active T-Mobile SIM. Feasibility audit DONE — verdict: **every AP-side component of the legacy (modem-centric) VoWiFi chain already ships in our stack.** Remaining unknowns are provisioning/carrier-layer, not architecture. **Phase 1 STAGED (unflashed): legacy-mode steering** — see "Staged" below. Phase 0 recon still pending (DUT was off TCP adb).

**Goal:** IMS registration over Wi-Fi (ePDG/IKEv2) + calls/SMS over Wi-Fi on the Verizon SIM, using the legacy modem-centric architecture stock used.

---

## Why this is plausible at all

Stock Palm 8.1 shipped Wi-Fi Calling — which means the hard part (ePDG IKEv2 client + IMS-over-WLAN in the 2017 MPSS) is proven modem capability:

- `vendor.bin.extracted/.../default.prop`: `persist.data.iwlan.enable=true` (legacy IWLAN data path enabled on stock).
- Stock system ships `com.ts.android.wfcactivation` with priv-app grants in `privapp-permissions-verizon.xml` — the Verizon WFC activation app.
- The Verizon `cdmaless` MBN (the config set our modem already runs — `PLAN-mcfg.md`) is where ePDG FQDN + VoWiFi policy live.

**Architecture constraint:** on this MPSS, VoWiFi is **modem-centric ("legacy mode")** — IKEv2/IPsec to the carrier ePDG and IMS-over-WLAN signaling run inside the modem. The modern AOSP path (`IwlanDataService`, AP-side IKEv2, "AP-assisted mode") requires modem support that predates us — closed. The AP's jobs in legacy mode:

1. Report WLAN connectivity/address to the modem (QMI WDS/DSD).
2. Provide the reverse data path (`rev_rmnet*` via netmgrd) so modem ePDG IPsec traffic egresses over wlan0.
3. Provisioning: WFC enable/preference via QMI IMSS (+ radio-config).

## Nightly-stack audit (2026-08-04, all on-disk in `vendor/xiaomi/Mi8937/proprietary/vendor/`)

| Component | Finding |
|---|---|
| `bin/netmgrd` + `lib64/libnetmgr*.so` | Full legacy IWLAN machinery intact: `netmgr_qmi_iwlan_*` link association, `netmgr_kif_rev_rmnet_cfg_req`, `netmgr_main_process_iwlan_enabled`, `ndc ipfwd enable iwlan`. |
| `etc/data/netmgr_config.xml` | Ships `iwlan_enable=1` and pre-configures `rev_rmnet0`–`rev_rmnet8`. |
| `lib64/libril-qc-hal-qmi.so` | 313 iwlan refs. Reads **`ro.telephony.iwlan_operation_mode`** with both `legacy` and `AP-assisted` value strings → legacy mode is prop-selectable, not dropped. Also has `QCRIL_QMI_RADIO_CONFIG_CLIENT_PROVISIONING_ENABLE_VOWIFI` (+ `…WIFI_CALL_ROAMING`). |
| Kernel `msm8937_defconfig` | `CONFIG_RMNET=y`, `CONFIG_RMNET_IPA=y` — reverse-rmnet data path present. |

## Open unknowns (ranked by risk)

1. **Verizon ePDG accepting the device.** Stock can no longer register on Verizon's network (device too old) → the stock witness is dead for this lane, and there's real risk the Wi-Fi path is IMEI-gated too. Counterpoint: our A16 build holds Verizon LTE + IMS registration today, and VoWiFi auth is EAP-AKA against the SIM. Only answerable by attempting the tunnel from the DUT.
2. **IMSS v01 WFC provisioning** — expected rerun of the VoLTE gap: A15 qcril speaks IMSS v02, modem is v01-only, so the Settings toggle likely never reaches the modem. Fix pattern exists: v01 QMI writes via `diag-tools/nas-probe/`-style tooling (cf. `ims_test_mode`, `PLAN-volte.md`); check for WFC-related NV/EFS items first.
3. Does the Verizon cdmaless MBN actually carry ePDG config, and is the modem's IWLAN RAT enabled in it? (`diag-tools/mcfg-lane/` techniques apply.)
4. imsdatadaemon / IMS data-path readiness over IWLAN APN type — untested interaction with the qmux/ipc_router stack.

## Carrier-specificity (2026-08-04)

The stack work is ~all carrier-agnostic (modem ePDG client, netmgrd/rev_rmnet, legacy-mode prop, v01 provisioning fix). Verizon-specific pieces:

- **ePDG FQDN + VoWiFi policy** = MBN data, not code. Stock ships per-carrier MBNs (verizon cdmaless / att volte / tmo / generic row) and our qcril MBN pipeline selects per-ICCID (`PLAN-mcfg.md`) — other carriers come "for free" at this layer.
- **Carrier-config WFC keys** — per-carrier, LineageOS defaults cover the majors.
- **Both top risks are Verizon-specific:** IMEI-gating (unknown #1) and **entitlement** — stock's `com.ts.android.wfcactivation` is an entitlement client; Verizon/AT&T gate WFC behind a server-side activation handshake. If that flow is dead for this device class, Verizon WFC fails with a perfect tunnel and there is no ROM-side fix (eSIM-lane shape).
- **Hedge: T-Mobile SIM as the diagnostic fallback** — most WFC-permissive US carrier (no meaningful IMEI whitelist, lightweight entitlement), stock tmo MBN on board. If Verizon rejects at ePDG/entitlement, a TMO attempt separates "our stack is broken" from "Verizon said no." Fold into Phase 2/3 if Verizon stalls.

## Staged 2026-08-04 (unflashed)

⭐ Staging-time discovery: **mithorium-common wires the framework for AP-assisted IWLAN** — its framework-res overlay points `config_wlan_data_service_package` / `config_wlan_network_service_package` / `config_qualified_networks_service_package` at `vendor.qti.iwlan`, a data service our modem can't use **and which isn't even packaged** (no APK in any proprietary-files list; only the @1.0 HIDL libs). So IWLAN transport was double-dead: framework pointed at a ghost service. Netmgrd's side needs nothing: it reads `persist.vendor.data.iwlan.enable` (already `true` in mithorium `vendor.prop`) + the shipped `netmgr_config.xml` `iwlan_enable=1`.

Changes (both pepito-gated, sibling-inert):

1. `Mi8937/overlay-pepito/frameworks/base/core/res/res/values/config.xml` (new) — empties the three service-package strings → `AccessNetworksManager` legacy mode (IMS APN stays on the cellular transport, qcril reports RAT=IWLAN itself).
2. `Mi8937/device.mk` pepito block — `ro.telephony.iwlan_operation_mode=legacy` (`PRODUCT_SYSTEM_PROPERTIES`; libril-qc-hal-qmi reads it to own the IWLAN RAT).

⚠️ **Overlay-precedence caveat:** `overlay-pepito` is appended to `DEVICE_PACKAGE_OVERLAYS` *after* mithorium-common's overlay; whether the later dir wins for the same resource is unverified in this tree (the existing overlay-pepito file overrides SettingsProvider only, no collision precedent). **Post-flash check #1:** `adb shell cmd overlay lookup android android:string/config_wlan_data_service_package` must come back empty. If mithorium wins, re-scope (conditional include in the mithorium overlay, or explicit RRO with priority).

**No new sepolicy** (props + overlay only). **Carrier config needs no staging:** on userdebug, `adb shell cmd phone cc set-value carrier_wfc_ims_available_bool true` (+ `carrier_wfc_supports_wifi_only_bool`, editable-mode keys as needed) flips it at runtime — bake an overlay/carrierconfig only after the experiment proves out.

## Experiment sequence

Failure modes separate cleanly: no tunnel attempt = AP-side plumbing; tunnel attempted but rejected = carrier gating (unknown #1).

- [ ] **Phase 0 — DUT recon (no flash):** probe IMSS v01 for WFC state TLVs (wfc_enabled / wfc_preference / roaming) with the existing v01 tooling; note current `ro.telephony.iwlan_operation_mode` / `persist.data.iwlan.enable` values on the DUT; confirm `rev_rmnet` interfaces can be created.
- [x] **Phase 1 — AP-side enable (pepito-gated per layering rule):** STAGED 2026-08-04 (see "Staged" above) — legacy-mode overlay + `ro.telephony.iwlan_operation_mode=legacy`. Awaiting build+flash. Post-flash: verify the overlay won (`cmd overlay lookup`, check #1 above), then `cmd phone cc set-value carrier_wfc_ims_available_bool true` → confirm the WFC toggle appears in Settings.
- [ ] **Phase 2 — provision + attempt:** enable WFC (UI first; v01 writes if the toggle doesn't land, per unknown #2). Watch: `ip xfrm state/policy`, rev_rmnet ifaces up, netmgrd logs, DSD indications, IMS registration tech (`dumpsys telephony.registry` → WLAN). Current SIM is an AT&T-network MVNO (US Cellular) — fine as attempt #1, but AT&T is the most IMEI-whitelist-aggressive US network for IMS features, so a failure there is weak evidence; escalate through the Verizon SIM (proven IMS-registered on this stack) and a TMO SIM (most permissive) before concluding anything carrier-side.
- [ ] **Phase 3 — validate:** call + SMS over Wi-Fi with airplane-mode-except-Wi-Fi (the zero-coverage use case); then handover behavior LTE↔Wi-Fi (nice-to-have; legacy handover may be rough).
- [ ] Sepolicy pass under Enforcing for whatever new paths light up (rev_rmnet, xfrm, imsdatadaemon).

## Session log 2026-08-04 (Phases 0–2 partial, live on DUT, AT&T-MVNO SIM)

**Framework legacy mode is LIVE without a rebuild.** The flashed build had the prop but the static overlay LOST the merge (all `DEVICE_PACKAGE_OVERLAYS` collapse into one auto-generated vendor RRO, `framework-res__lineage_Mi8937_gapps__auto_generated_rro_vendor.apk`, where mithorium's value wins). Fixes:
- **Permanent (staged, unflashed):** the three empty strings moved into `rro_overlays/xiaomi_pepito_overlay` (runtime RRO, priority 31, beats the static merge); the dead `overlay-pepito/frameworks/base/core/.../config.xml` deleted.
- **Live now:** three fabricated overlays `com.android.shell:WfcLegacy{Data,Net,Qns}` (persist across reboot, in `/data/resource-cache`) — `cmd overlay lookup` confirms empty. Remove once the RRO ships: `cmd overlay disable` + delete.

**Framework→modem WFC path confirmed broken exactly as predicted.** With `wfc_ims_enabled=1` (DB write + phone-process restart; note: a bare `content update` does NOT propagate — restart or real Settings toggle needed), telephony pushes `ImsConfig setConfig` items 27=2/26=1 into org.codeaurora.ims → qcril → **v02 0x6B, which this modem doesn't implement** (PLAN-volte, error 57). Silent no-op.

**v01 ground truth (imss-probe, force-ipcr preload):** `GET/SET_CLIENT_PROVISIONING_CONFIG` (0x54/0x53) carries WFC. REQ TLVs: 0x10–0x13 u8 bools (client-prov/volte/vt/presence), **0x14 u32 wifi_call (0=unsupported 1=off 2=ON), 0x15 u32 wifi_call_preference (1=WLAN_PREFERRED, 3=CELLULAR_PREFERRED), 0x16 u32 wifi_call_roaming**; GET resp = same +1 (0x11…0x17). `imss-probe setmsg32` (new subcommand, built on Stellaris16 — local machine lacks the soong sysroot) writes u32 TLVs; **live-validated:** preference 3→1 accepted and persisted. Modem now reads wifi_call=ON, pref=WLAN_PREFERRED.

**⭐ Blocker for this SIM (US Mobile "Dark Star", AT&T 310-410): NO IMS provisioning at all.** IMSA: NOT_REGISTERED, reg_failure_error=0 (the "never attempts" signature); GET 0x40 IMPU **empty** (Verizon SIM showed `sip:…@vzims.com` from its MBN); client-prov bools all 0 (per-SIM store — Verizon read volte=1). Means **no VoLTE on this SIM either** — a per-ICCID MBN-selection question (`PLAN-mcfg.md`), upstream of WFC. WFC on this SIM is blocked behind that, not behind the WFC stack.

**Misc:** `airplane_mode_on=1` in settings while radio is IN_SERVICE on LTE (desynced — pre-existing). ⚠️ Never `am broadcast -a android.intent.action.AIRPLANE_MODE` on this box: with the setting at 1 it re-applies airplane state and kills Wi-Fi (= TCP adb). Learned the hard way.

**Next:** swap in the **Verizon SIM** (proven IMS+VoLTE): set `wfc_ims_enabled=1` for its sub, flip its per-SIM client-prov (`setmsg32 0x53 0x15 1`, check 0x14), then watch for the ePDG attempt (`ip xfrm state`, rev_rmnet, IMSA reg over WLAN). Open question queued behind that: does the modem learn WLAN availability (DSD/WDS path) on our stack.

## Session log 2026-08-04 part 2 — Warp SIM: full WFC provisioning live, blocked on the WLAN-report chain

**Warp (US Mobile × Verizon, 311480) is the right test SIM: IMS REGISTERED + SMS/VoIP FULL_SERVICE** on LTE within seconds of radio-on (VZW cdmaless MBN provisions it; IMPU `sip:…@vzims.com` present). Note: airplane-mode had genuinely powered the radio off post-SIM-swap — `cmd connectivity airplane-mode disable` is the safe fix (never the broadcast).

**Done and validated live:**
- Per-SIM v01 provisioning written and confirmed: `wifi_call=2 (ON)` + `wifi_call_preference=1 (WLAN_PREFERRED)` (`imss-probe setmsg32 0x53 0x14 2` / `0x15 1`). Enum ground truth: pref 1=WLAN_PREFERRED, 3=CELLULAR_PREFERRED (the AT&T-MVNO SIM's store read wifi_call=2/pref=3; per-SIM store confirmed).
- Framework: `wfc_ims_enabled=1, wfc_ims_mode=2` for sub 3; fabricated overlays re-created (**they do NOT survive reboot** — shell frro's are purged at boot; the `xiaomi_pepito_overlay` RRO change is the real fix and re-fabricate is required after every reboot until it ships).

**The missing link, root-caused two levels down: nobody tells the modem WLAN is up.**
1. In this legacy architecture the WLAN reporter is **imsdatadaemon** (`cs_startService: Case WLAN… Get IP from CnE`) — it learns Wi-Fi from **CnE (`cnd`), which our build does not ship** (`persist.vendor.cne.feature=1` is set, stock has cnd, we don't). The 20260526 nightly OTA carries the full CnE stack; extracted (cnd + 16-lib closure incl. `vendor.qti.data.factory@2.0–2.3`, `latency@`, `lce@1.0` — files in scratchpad `cne/`, needs re-extraction or proper staging) and **run live from /data/local/tmp: cnd registers `vendor.qti.data.factory@2.0–2.3::IFactory` in hwservicemanager** (no VINTF rejection). No force-ipcr needed so far (it idles in epoll).
2. Even with cnd up, **datad never advances**: starts, bounces the absent `vendor.imsrcsservice`, then idles — registers NO QMI service on ipc_router (server-diff across restart = empty; contrast `ims_rtp_daemon`, whose QCSI service registers fine = svc 0x31 inst 0x101 node 1). `libqmi_csi` supports both transports with a QRTR probe the DT_NEEDED shim should defeat, so transport is probably not the blocker — datad seems to be waiting for a trigger.
3. Found + fixed en route: **imsqmidaemon cold-boot ordering bug** — at boot it starts before the qmux stack is ready and never sets `vendor.ims.QMI_DAEMON_STATUS`; a `ctl.restart` connects instantly and sets `=1`. Feed into `PLAN-release.md` cold-boot hardening (datad's prerequisites are broken on every cold boot today; didn't unblock datad by itself though).

**Decisive next step — stock-witness architecture question (does NOT need network registration):** on `android8-adb`, map which AP daemons register which QMI services on ipc_router (stock datad's DCM service id + whether it registers at boot), who launches cnd's clients, and how the WLAN report flows (datad→modem via QCSI DCM? DSD WLAN_AVAILABLE? NAS wfc-status from qcril?). That tells us exactly what our datad is waiting for. Alternative RE path: strings/disasm datad's state machine around `DATAD STARTED`.

**Current DUT experiment state (all volatile or reversible):** fabricated WfcLegacy* overlays enabled; cnd running manually from `/data/local/tmp/cne` (dies on reboot); WFC NV per-SIM writes persist in modem EFS; `wfc_ims_enabled=1` for subs 2 and 3 persists.

## Session log 2026-08-04 part 3 — STOCK WITNESS (A8 + Warp SIM, rooted, Permissive)

⭐⭐ **Two premises of this lane were wrong, both corrected by the witness.**

**1. Stock is NOT too old to register — it registers fine on the Warp SIM.** `dumpsys connectivity` on stock A8: LTE CONNECTED with **both `VZWINTERNET` and an `IMS` PDN up**, `gsm.operator.alpha=US  Mobile` (311480). The "device retired off Verizon" belief evidently applied to the native VZW SIM, not this MVNO one. **The A8 is a live full-runtime witness again** — the three-device methodology is fully restored for telephony work.

**2. 🔴 Verizon's WFC entitlement REFUSES this device — the definitive carrier-gate data point.** UI toggle → `com.ts.android.wfcactivation` `VzwEmergencyAddressActivity` → **"Unable to activate Wi-Fi calling at this time. Please try again later."** ([screenshot](assets/a8-wfc-entitlement-refused-20260804.png); `startVerizonInternetConnection` runs, i.e. it deliberately reaches the entitlement server over VZWINTERNET, not Wi-Fi). Nothing useful in unrooted logs — the app doesn't log its HTTP exchange. Whether the block is the retired IMEI or the MVNO sub is unresolved, but **stock itself cannot turn WFC on for this SIM.** Consequence: there is no "working reference trace" to capture on stock — it never gets to the ePDG. Our DUT is not behind stock here; both are gated at the same wall, ours at a different level.

**Root access on the A8 (fresh flash 2026-07-23):** `su` is a **setuid wrapper at `/su`** invoked as **`/su <absolute-path> [args]`** (`/su /system/bin/sh -c "…"`). Bare `/su -c` and `/su sh -c` both fail "exec failed". SELinux Permissive; `/data/local/tmp` is NOT writable even via the wrapper (use `/sdcard`). Note the A15-built `imss-probe` **segfaults on 8.1 libs** — a stock-side probe needs an 8.1 build (`build-a11.sh` is the precedent).

**Falsified (important, saves future digging): "our datad is broken because it registers no QMI service."** Diffing the stock ipc_router server table across `stop/start imsdatadaemon` shows **stock datad registers NOTHING either** — identical to ours. The `[IMS_FATAL] qpNetSetReadFds - DataD IPC socket not available` line also appears on stock: **normal noise, not a fault.** So our datad is behaving like stock's; the DUT gap is narrower than part 2 assumed. What stock's datad *does* show that ours doesn't: `QCNEA |CAC| processResponse` traffic — i.e. an active CnE conversation (stock ships cnd as a real init service; ours was hand-run). Stock service map captured for reference (services on node 0 = modem, node 1 = AP-hosted).

**Where that leaves the lane.** AP-side we now have: framework legacy mode, modem WFC provisioned ON + WLAN_PREFERRED (v01, ours only — stock's is entitlement-blocked), CnE available to package. The untested link is still "modem learns WLAN is usable and initiates ePDG", and the next hypotheses are (a) the Verizon cdmaless MBN carries no ePDG FQDN for this vintage, (b) the modem wants an explicit WLAN-availability QMI indication we don't send, (c) a modem-side provisioning/entitlement bit that only the (refused) entitlement flow sets. Test (a) first — it is a read-only IMSS/MBN sweep on the DUT and it is cheap.

**⭐ Hypothesis (a) FALSIFIED 2026-08-04 — the modem IS ePDG-provisioned.** Static grep of the stock MBNs (`backup-stock-android-8.1-AML0/vendor.bin.extracted/modem_config/mcfg_sw/`, no device needed) — the **Verizon cdmaless set our modem already runs** carries:
`epdg_fqdn:wo.vzwwo.com;` · `/data/iwlan_s2b_config.txt` · `<WiFiAvailable>0/1</WiFiAvailable>` policy · NV `/nv/item_files/ims/qp_ims_wifi_config`, `/nv/item_files/modem/mmode/wifi_config`, `qp_ims_emerg_wifi_disable` · `wifi_avg_interval/sampling/alpha` measurement tuning.
So the modem knows where Verizon's ePDG is and how to score Wi-Fi. **Prime suspect is now (b): nothing on our AP tells the modem WLAN is available/usable** — the CnE→datad→modem report chain. Those NV items are concrete inspection targets (read them via imss-probe/NV sweep).
Fallback-carrier note: the tmo MBN carries `epdg_fqdn:epdg.epc.mnc260.mcc310.pub.3gppnetwork.org` and att `epdg.epc.att.net` — an active TMO line would be provisioned too.

⚠️ **Reality check on the whole lane:** with stock refused by Verizon's entitlement server, the odds that Verizon's ePDG accepts our hand-provisioned attempt are materially lower than at lane open. Recommend timeboxing (a)/(b) and, if the modem still won't initiate, testing a **T-Mobile SIM** before spending further — TMO's entitlement is the permissive one, and it cleanly separates "our stack can't" from "Verizon won't".

## Session log 2026-08-04 part 4 — hypothesis (b) tested directly: modem ACCEPTS a hand-sent WLAN report but does not initiate ePDG

DUT re-verified: Warp SIM (US Mobile×VZW 311480), **IMS REGISTERED on LTE**, modem WFC still provisioned (IMSS v01 GET 0x54: wifi_call=2 ON, pref=1 WLAN_PREFERRED — persisted from part 2). `vendor.ims.QMI_DAEMON_STATUS=1`; imsqmidaemon/imsdatadaemon/ims_rtp_daemon all running; the three fabricated `WfcLegacy{Data,Net,Qns}` overlays still enabled.

**⭐⭐ NEW TOOL: `diag-tools/nas-probe/dsd-probe` — talks to QMI DSD (svc 0x2A) over force-ipcr.** Built on Stellaris16 (`build-dsd.sh`, same recipe as imss-probe). Message IDs ground-truthed via `parse_idl_any.py` on `dsd_qmi_idl_service_object_v01` @0x25508 and they match the public CAF data_system_determination IDL: `0x20 WLAN_AVAILABLE_REQ`, `0x21 WLAN_NOT_AVAILABLE_REQ`, `0x24 GET_SYSTEM_STATUS`, `0x25 SYSTEM_STATUS_CHANGE (register)`, `0x27 BIND_SUBSCRIPTION`. Commands: `dsd-probe` (GET system status), `dsd-probe get 0xNN`, `dsd-probe wlanup <mac> <ipv4> [dns1 dns2]`, `dsd-probe wlandown`, `dsd-probe session …` (bind+register then hold open + poll).

**⭐⭐ Hypothesis (b) is HALF-CONFIRMED and HALF-REFUTED. The modem's DSD accepts a WLAN-available report — so "the AP can't tell the modem WLAN is up" is FALSE at the QMI level — but reporting it does NOT make the modem start the ePDG tunnel.**
- `wlanup <mac> <ipv4>` → **RESULT result=0** (accepted). `wlanup <mac> 0.0.0.0` (mac-only) → also accepted.
- The earlier `INVALID_ARG (48)` failures were purely my TLV encoding: (1) IPv4 must be sent in **network byte order** (raw `in_addr.s_addr` bytes, NOT `ntohl`'d), and (2) the DNS TLVs **0x12/0x13** are rejected by this modem — drop them; mac+ipv4 alone is the accepted minimal report. `bind_subscription(sub=0)` also returns 48 (try sub=1 next time; not needed — WLAN_AVAILABLE works clientless).
- **After a valid `wlanup 78:24:af:7b:47:ea 10.0.2.157`: NO reaction.** `ip xfrm state/policy` empty, no `rev_rmnet*` UP, IMSA still `REGISTERED` over cellular, ServiceState still `isWifiCallingEnabled=false` / `mIsIwlanPreferred=false`, WLAN NetworkRegistrationInfo still `UNKNOWN`. GET_SYSTEM_STATUS shows no WLAN system added. A one-shot DSD report is necessary-but-not-sufficient.

**What's still missing before the modem will initiate ePDG (revised suspect list):**
1. **Modem IWLAN RAT not enabled.** qcril's `TurnOnAPAssistIWLANSyncMessage` / `DSDModemEndPoint::sendAPAssistIWLANSupportedSync` + netmgrd's `netmgr_main_process_iwlan_enabled` normally arm the modem's IWLAN RAT first. Our qcril is in legacy mode, so the AP-assist turn-on may never fire. This is the top new lead — probe/force it.
2. **A resident CnE conversation, not a one-shot.** Stock/datad gate on CnE: datad's `qpdplSetupCNERoute…getNetConfig return -1 … Awaiting NetID from CNE`, and its `wlan_notifier` (wpa_ctrl → wlan0) never arms without it. The modem may want the continuous DSD client (bind+register+periodic wifi-quality inds), which is exactly what cnd/CneApp provide.

**CnE packaging progress (the intended reporter chain), all extracted from the 20260526 nightly this session (`scratchpad/cne-stage/`):**
- `CneApp.apk` (`com.qualcomm.qti.cne`, sharedUserId `com.qualcomm.qti.qtidataservices`, persistent, coreApp) + the 8 CNE framework jars (`com.quicinc.cne.{api,constants}`, `vendor.qti.hardware.data.cne.internal.{api,constants,server}`) pulled from vendor.img/system_ext.img (sdat2img).
- Installed CneApp via `pm install` (needed `settings put global verifier_verify_adb_installs 0` + `--bypass-low-target-sdk-block`). It **runs** and does its Android-side job (WlanStaInfoRelay sees Wi-Fi, retrieves country code) **but fails its one critical hop:** `NativeHalConnector: getService error NoSuchElementException / Error in get IFactory Service`. It wants **`vendor.qti.hardware.data.cne.internal.server@1.0::IFactory`**, which **cnd does NOT register** — cnd (hand-run from `/data/local/tmp/cne`) only registers `vendor.qti.data.factory@2.0–2.3::IFactory` (for datad) + `…data.latency@1.0`. So the Android→cnd WLAN feed is broken at cnd, and separately a `pm install`'d CneApp lands in `untrusted_app` and can't reach vendor hwservices under Enforcing anyway.
- Nightly main vendor `manifest.xml` only declares `vendor.qti.data.factory@2.3` + `data.latency@1.0` — **no `cne.internal.server` entry**, consistent with cnd not registering it. Why cnd skips it (feature flag / config / missing dep) is the open question for the packaging path.

**Two forward paths (unchanged in shape, sharper now):**
- **(A) cheap, do first:** force the modem IWLAN RAT on (suspect #1) via qcril/imss/dsd, then re-send `dsd-probe wlanup` and watch for ePDG. If the modem tunnels, the whole downstream works and the remaining job is just wiring a resident reporter.
- **(B) the real productization:** package cnd + CneApp + the CNE jars properly (vendor + system_ext, platform-signed/placed, VINTF `cne.internal.server` entry, sepolicy for the `cnd`↔`qtidataservices` hwservice), and figure out why cnd doesn't register `internal.server::IFactory`. Only worth it once (A) proves the modem will initiate.

**DUT state left behind (mostly volatile):** CneApp **installed** (persists across reboot, but inert/harmless — untrusted_app, fails IFactory lookup); cnd from `/data/local/tmp/cne` **not currently running** (dies on reboot); modem WFC NV provisioning persists in EFS; `wfc_ims_enabled=1` persists; fabricated `WfcLegacy*` overlays enabled (purged on reboot); IMS debug log props left ON (`persist.vendor.ims.disable*=0`) — reset for release. No change to the working LTE/IMS/data chain.

## Session log 2026-08-04 part 5 — ⭐⭐ PATH (A) CLOSED: this modem has no AP-side IWLAN arming API at all

Path (A) was "force the modem IWLAN RAT on, then re-send the WLAN report and watch for ePDG." Both mechanisms qcril uses to do that **do not exist in this modem's firmware**, and no amount of correct AP-side reporting moves it.

**⭐⭐ The modem's DSD is an older revision than the A15 IDL: it implements message ids ≤ 0x47 and returns `NOT_SUPPORTED (57)` for every id ≥ 0x49.** Established by sweeping all 59 DSD REQ ids with empty payloads (`dsd-probe get 0xNN`); ids the modem implements answer `MISSING_ARG (17)` or `0`, absent ones answer 57. Consequences:
- **`0x65 QMI_DSD_SET_CAPABILITY` → 57.** This is what qcril's `handleTurnOnAPAssistIWLANSync` sends (msg id ground-truthed from the disassembly: `mov w1, #0x65` beside the `QMI_DSD_SET_CAPABILITY_REQ_V01` log strings). **Suspect #1 from part 4 is FALSIFIED** — there is no AP-assist IWLAN turn-on to force. Legacy mode isn't a choice here, it is the only thing the modem speaks.
- **`0x53 SET_WIFI_SERVICE_CAP` → 57.** Stock CnE's `CneQmiDsd::sendWiFiServiceCap()` sends this (u64 = 1) right after the WLAN report — so **stock's cnd gets the same 57 on this modem.** Not a missing step on our side.

**The full stock-CnE bring-up sequence, replayed exactly, changes nothing.** Disassembling the stock A8 `vendor/lib64/libcne.so` gives CnE's real order: `bindAndRegisterForDsdInd()` = `0x27` bind + `0x38` indication-register, then `sendInitialModemNotifications()` = `0x20` WLAN_AVAILABLE → `0x53` svc-cap → `0x43` WQE profile status. Replayed via the new `dsd-probe arm`:
- ⭐ **`bind_subscription` needs sub = 1, not 0** — the enum is 1-based. That is the whole explanation for part 4's `INVALID_ARG (48)`; with sub=1 it returns result=0.
- bind + indication-register (stock's 0x11/0x12/0x14/0x19 **and** the full 0x10–0x1b set) + WLAN_AVAILABLE all return result=0 — and then **zero indications arrive, ever**. No WQE profile-init, no start-wifi-measurement, nothing. The modem never asks the AP for anything.
- `GET_SYSTEM_STATUS (0x24)` never gains a WLAN system: available-systems stays one entry (`0 / 3 / so_mask=0x1000`) and the per-APN preferred-system table keeps `ims` on it, across a 90 s held-open client.
- **`0x29 SET_APN_PREFERRED_SYSTEM("ims", …)` is accepted for every value 0–3 and is a pure no-op** — the preferred-system table doesn't change. Accepting an out-of-range value is the tell: nothing validates or consumes it in legacy mode.
- **Decisive: a full radio power-cycle (`nas-probe radiocycle`) with a resident bound DSD client holding WLAN-available across it re-registers IMS over cellular** (`voip_service_rat=1`), `ip xfrm state` empty, no `r_rmnet*` UP. So this isn't a "modem only evaluates WLAN at registration time" ordering problem either.

**Where that leaves the lane.** Every AP→modem lever reachable over QMI is now either exercised (WFC provisioned ON + WLAN_PREFERRED via IMSS v01; WLAN reported and accepted via DSD 0x20; APN preferred-system set) or proven absent from the firmware (0x53, 0x65). The remaining difference from stock is **not a message we are failing to send** — it is that stock has a *resident CnE conversation* (`QCNEA |CAC| processResponse`) feeding datad continuously, which is path (B). But since the modem emits no WQE/measurement indications at all — the very requests a resident client exists to answer — (B) looks unlikely to flip this on its own. **Recommendation: before spending on (B)'s packaging work (cnd + CneApp + VINTF + sepolicy), test a T-Mobile SIM** — it separates "our stack can't" from "Verizon won't" for a fraction of the cost.

**Tooling added:** `diag-tools/nas-probe/dsd-probe.c` gained `arm <mac> <ipv4> [hold_s] [all]` (replays the stock CnE sequence, then holds the client open printing indications), `svccap [u64]`, and a generic **`raw <msgid> [T:len:val …]`** sender — the last makes any future DSD message a one-liner with no rebuild. Rebuild with `build-dsd.sh` on Stellaris16 (local box lacks the soong sysroot).

**DUT state:** unchanged and healthy — LTE + IMS REGISTERED + VZWINTERNET validated after the radio cycle. Experiment state reverted (`ims` APN preferred-system back to 0, WLAN_NOT_AVAILABLE sent). `cnd` from part 4 is running by hand again from `/data/local/tmp/cne`.

## Session log 2026-08-04 part 6 — PATH (B) bench-validated end-to-end on the AP side; modem still won't contemplate WLAN

⭐⭐ **Part-4's core diagnosis was WRONG: cnd is not broken and registers everything it should.** `vendor.qti.hardware.data.cne.internal.server@1.0::ICneService` is never a standalone hwservice — it is **vended through `vendor.qti.data.factory@2.x::IFactory::createCneIService()`** (symbols in `vendor.qti.data.factory@2.2.so`: `Factory_V2_2::createCneIService(internal.server::IServiceCallback) → ICneService`, plus `createCneIApiService`). CneApp's `NativeHalConnector` looks up `vendor.qti.data.factory@2.0::IFactory` — exactly what cnd registers. The part-4 "NoSuchElementException" was pure **sepolicy**: `untrusted_app` denied `{ find }` on `hal_datafactory_hwservice` (avc logged, permissive=1). No missing VINTF entry, no cnd config flag. **The nightly CnE stack is complete as-is.**

**Full CnE chain brought live on the bench** (setenforce 0 + `cmd deviceidle tempwhitelist` + `pm grant READ_PHONE_STATE` + targeted `am broadcast --include-stopped-packages -p com.qualcomm.qti.cne -a BOOT_COMPLETED`):
- CneApp → cnd: `createCneIService success`, `Connected to service SUCC`; pushes `notifyWifiAvailable(v4=true, validated=true)`, default-network, country code.
- cnd → CneApp (the reverse command channel works too): `RatRequested{rat=11(TYPE_MOBILE_IMS), slot=1}` → DataCallAgent `requestNetwork` for the IMS network — **fails with the restricted-network SecurityException**: `CONNECTIVITY_USE_RESTRICTED_NETWORKS` is signature|privileged, ungrantable to an installed app. ⇒ **priv-app packaging is a hard requirement, and it is the LAST missing AP-side hop.** Every other link is proven.

⭐⭐ **datad's DCM service works and the modem actively uses it — two prior "facts" corrected.** Enabling datad logging (`persist.vendor.ims.disable{ADB,Debug,IMS}Logs=0` + restart) revealed: `qmi_dcm_register_service rc: 0`, then immediately `dcm_connect request from Modem`, `LINK_ADDR_REQ` (modem sends its link-local v6 + port 9099), `REGISTER_APP_STATE`, and `PDP_ACTIVATE_REQ(apn=ims, RAT=cellular)` which datad fulfills via DSI (`ENETISCONN`, rmnet_data0, returns IPv6 to modem). So the IMS PDN is **AP-mediated through DCM** on this stack, and part-2's "datad registers NO QMI service" was an artifact of the silenced logs / cold-boot ordering bug, and part-3's stock server-diff "registers NOTHING either" is equally suspect (the diff method missed QCSI DCM).
- DCM vocabulary in datad covers the whole WFC flow: `GET/STOP/UPDATE_WIFI_QUALITY`, `WIFI_QUALITY_IND` (datad has a wpa_ctrl `wlan_notifier` RSSI engine), `HO_MEASUREMENT_*`, `WLAN_TZ`, and `cs_startService: Case WLAN → Get IP from CnE` via `libcneapiclient` (loaded in datad). The WLAN leg = modem sends `PDP_ACTIVATE(RAT=WLAN(4))` → datad fetches the wlan0 net from cnd.

🔴 **But the modem still never takes the first WLAN step.** With DCM live + modem connected + WFC NV ON/WLAN_PREFERRED + CnE feeding wifi state + a held-open DSD client reporting WLAN_AVAILABLE, a fresh radiocycle still re-registers IMS over cellular only; the modem never sends `GET_WIFI_QUALITY`, never `PDP_ACTIVATE(RAT=WLAN)`, DSD system status never gains WLAN. (Part-5's radiocycle predates the live DCM, so this is a genuinely new — and negative — data point.) Also checked: `GET_QIPCALL_CONFIG (0x37)` carries **no wifi TLVs** on this modem (no device-level WFC store there), and the VZW cdmaless MBN's `qp_ims_wifi_config` is sane (rove thresholds 0x41/0x4B ≈ −65/−75 dBm).

**Remaining suspects (narrowed):** (c) a modem-side entitlement/provisioning bit only the (Verizon-refused) entitlement flow sets, or an undiscovered arming message (IMSS/other svc) telling qipcall WLAN exists. **Discriminators, in cost order:** (i) **A11 F3 diag capture** (same modem fw, stock vendor so cnd runs natively) with the Warp SIM + Wi-Fi up — watch qipcall/policyman decide; (ii) **active T-Mobile SIM** on the DUT.

**Path (B) productization spec (all hops bench-proven except the priv-app grant):**
1. `CneApp.apk` (presigned) → `product/priv-app` (or system_ext), pepito-gated; privapp-permissions XML: `CONNECTIVITY_USE_RESTRICTED_NETWORKS`, `READ_PRIVILEGED_PHONE_STATE`, `PACKET_KEEPALIVE_OFFLOAD`, `MAINLINE_NETWORK_STACK`, `INTERACT_ACROSS_USERS`; default-grant runtime perms (READ_PHONE_STATE, location) via default-permissions XML. `persistent` then auto-starts it (no receiver gymnastics needed).
2. CNE framework jars (8) → system_ext/framework as on the nightly donor.
3. `cnd` + 16-lib closure → vendor, init service (after qmux stack), force-ipcr via the DT_NEEDED shim pattern. VINTF: `vendor.qti.data.factory@2.0–2.3` + `data.latency@1.0` (what cnd registers; `internal.server` needs **no** entry — factory-vended).
4. sepolicy: `cnd` vendor domain (upstream qcom `cnd.te` precedent); seapp_contexts entry for `com.qualcomm.qti.cne` → a domain allowed `hal_datafactory_hwservice:hwservice_manager find` (name-keyed seapp entry works with the QC presig).
5. Cold-boot ordering: the imsqmidaemon/datad ordering bug (part 2) must be fixed or datad's DCM registers late/never — now known to matter even more (PLAN-release).
6. Reset `persist.vendor.ims.disable*Logs=1` + `dumpWiFiLogs=0` for release.

**DUT state after part 6:** Enforcing RESTORED (the CneApp→cnd hop needs setenforce 0 to re-establish after any restart until packaged); IMS debug logs left ON; CneApp installed with READ_PHONE_STATE/location granted; cnd still hand-run from `/data/local/tmp/cne` (dies on reboot); datad restarted with logging live, DCM registered, modem connected; LTE + IMS + data verified healthy (Enforcing, CONNECTED, ping OK).

## Session log 2026-08-04/05 part 7 — A11 F3 rig prepped (Silver), pre-flash capture banked

**Silver (4373dd0f) is no longer the stock-A8 witness: flashed to the A11 GSI capture rig (rooted, booted) 2026-08-04 night.** The stock full-runtime witness for telephony is GONE again — plan accordingly (part 3's restoration is obsolete; static artifacts + this rig are the reference now).

**Banked before the flash → `diag-tools/captures/a8-silver-preflash-20260804/`:**
- Fresh `modemst1`/`modemst2`/`fsg` EFS snapshot — a modem NEVER touched by our v01 writes = clean comparator for the entitlement-bit hunt + restore insurance.
- `a8-stock-wifi-bounce-full.log` — stock CneApp wifi-bounce baseline (no SIM): same notification feed our bench chain produces; no stock-only Android-side magic. Stock runs `cnd` as user `system`, whole CnE stack in `/system` (pre-Treble) — supports the priv-app packaging spec.
- Static refs (CNEService.apk, cne XMLs/configs) already in `backup-stock-android-8.1-AML0/system.bin.extracted/` — not re-pulled.

**Next session runbook (rig is up, SIM insert pending — Kyle will assist):**
1. Verify rig: serialno 4373dd0f, root, stock vendor daemons (cnd, imsdatadaemon) running under the GSI; DIAG alive (stock kernel → diag works, per `diag-tools/HOWTO-modem-diag-capture.md` + memory `diag-capture-a11-modem-f3`).
2. **Insert Warp SIM** (currently in the DUT — WFC provisioning is per-SIM/per-ICCID in the modem store).
3. Rebuild probes for A11 libs (`build-a11.sh` precedent; A15-built binaries segfault on old userspace): imss-probe + dsd-probe at minimum. Re-provision on the rig's modem: `imss-probe setmsg32 0x53 0x14 2` + `0x15 1`; confirm via GET 0x54.
4. **F3 capture** with IMS/qipcall/policyman/DSD subsystems enabled through: wifi connect → `dsd-probe wlanup`/`arm` → radiocycle. Goal: the modem's internal reason for never starting WLAN (suspect (c) entitlement bit vs missing arming input).
5. **DIAG EFS reads**: `/nv/item_files/ims/qp_ims_wifi_config`, `/nv/item_files/modem/mmode/wifi_config`, `qp_ims_emerg_wifi_disable`, and a full `/nv/item_files/ims/` listing to hunt unknown entitlement/provisioning items. Diff against the pre-flash EFS snapshot and the MBN defaults (rove thresholds 0x41/0x4B ≈ −65/−75 dBm already confirmed sane).
6. If an EFS gate item is found: evaluate DIAG EFS write to flip it (rig first, then decide DUT path).

## Session log 2026-08-05 part 8 — A11 rig LIVE, F3 pipeline built, modem-internal ground truth at last (no-SIM baseline)

**Rig = Silver `4373dd0f`**, phh A11 GSI on stock 3.18.71 kernel + **stock vendor**: `cnd`, `imsdatadaemon`, `imsqmidaemon`, `ims_rtp_daemon`, `rild`, `netmgrd` all run **natively as init services** — i.e. the resident CnE conversation we could only hand-run on the DUT. `/dev/diag` + SMD_MODEM diag queues live; SELinux Enforcing; `adb root` works.

**⭐⭐ Tooling: `diag-tools/decode_f3.py` (new).** `decode_rmts.py` only handled cmd `0x80`; a real capture is **~99% cmd `0x99`** (247k/268k frames), the arg-bearing QSR4 type it silently dropped. Reverse-engineered layout: `04:11` = 64-bit timestamp, **`12:15` = msgid** (brute-forced: 100% of msgids resolve at offset 12), `16:17` = ?, `18..` = args, last 2 = CRC. ⭐ **Args are packed at NATURAL width, not 32-bit** — calibrated against `EPDG_FQDN set with length` (single byte `0x0c`). Decoder does file-regex filtering, `--census`, `--raw`. Validated: **0 unknown msgids across 247k frames**, 724 distinct message types with args substituted.
- ⚠️ **Per-unit modem builds differ**: the rig's live QShrink GUID is `aa70ba0d-…`, our in-repo `qdb.dec` is `079960cf-…`. **Always decode with the `<guid>.qdb` diag_mdlog writes into the capture dir** (zlib @ 0x40). Reassuring: the two DBs have **identical 4813-file source sets** → same MPSS codebase, different build stamp, so findings transfer.

**⭐ Rig-vs-DUT modem equivalence PROVEN (no SIM needed):** the DSD id sweep on the rig reproduces the DUT exactly — implemented through `0x47`, and everything `0x48`+ (incl. **`0x53` and `0x65`**) returns NOT_SUPPORTED. Part 5's "no AP-side IWLAN arming API" now holds on two independently-flashed units.

**⭐⭐ The modem's IWLAN stack is present, initialized, and Verizon-provisioned.** F3 across an on-demand modem restart (`per_mgr` cycle) shows `ds_iwlan_s2b_config_read_params_from_file` → **`EPDG_FQDN set with length 12`** (= `wo.vzwwo.com`), IKEv2/ESP rekey timers, PDN throttle tables, `epdg_addr_reslvr_wp_iface_init`. Hypothesis (a) is re-falsified *from the modem's own logs*, not just MBN greps.

**⭐⭐ Mechanism found for "accepted but inert": our DSD WLAN report never reaches the IWLAN module.** With F3 running, `dsd-probe arm/wlanup` (DSD answers `result=0`) produces **ZERO** `ds_iwlan_s2b_*` messages — while the modem-restart capture shows the module normally processing DSD events (`ds_iwlan_s2b_dsd_event_cb()` → `wp_iface_hdlr_dsd_event_cb: WLAN related DSD Event. Radio Mask N`, values 255/0/0/0/57/1, first one → **`Received WLAN unavailable event. Don't process.`**). So DSD ACKs the report at the service layer without it becoming IWLAN state.
- **Confound, not yet resolved: no SIM.** A native-`cnd`-driven Wi-Fi off/on (Wi-Fi genuinely up, 10.0.2.106) *also* produced zero IWLAN messages — so with no subscription the module ignores WLAN events from **any** source. The rig cannot discriminate "our report is malformed" from "no SIM ⇒ IWLAN inert" until the SIM is in. **That is the next experiment.**

**Key F3 strings to grep once the SIM is in** (mined from the DB): `ds_iwlan_s2b_wp_iface_hdlr.c:247` Radio Mask / `:258` WLAN-unavailable; `epdg_addr_reslvr_*` (`send_dns_query`, `No FQDN available`, `WIFI not avail. Ignore`); `ds_iwlan_s2b_process_nv_refresh_event: … WLAN offload config NV: Disabled/Enabled` ⭐ (a modem NV that gates WLAN offload wholesale — prime suspect if the SIM doesn't unblock it); `qipcalliface_ho_mgr.c` (`is_wwan_iwlan_handover_required`, `update_E911_capability … WFC status %d and Wifi srv status %d`); `PDPRATHandlerVoLTE.cpp:615 Init - IWLAN enabled, RegType[%d]`.

**Probe status on the rig:** the **A16-built `imss-probe` and `dsd-probe` run fine** (GSI's A11 bionic loads them) — no Stellaris16 rebuild needed, and no force-ipcr preload (stock vendor is natively ipc_router). `nas-probe` (both builds) fails DMS/NAS connect `rc=-17` (client-slot contention with native rild) — use `svc`/settings for airplane cycling instead.

**Captures banked:** `diag-tools/captures/a8-silver-preflash-20260804/` (pre-flash EFS + stock CnE baseline). Working captures in scratchpad `rigdiag/` (dry/nv/wlanup/cnd .qmdl + `rig_qdb.dec`) — promote the SIM-in ones to `diag-tools/captures/`.

## Session log 2026-08-05 part 9 — ⭐⭐⭐ ROOT CAUSE FOUND: the modem's own "ims" APN profile is not WLAN-preferred

Warp SIM moved to the A11 rig. ⚠️ **The phh GSI defaults to GSM/WCDMA — Verizon 311480 is LTE-only, so nothing registers until Settings → preferred network = LTE.** After that: **LTE registered (US Mobile 311480) + IMS REGISTERED** (`imsa-probe`: `ims_registered=1`, `voip_service_rat=1`), Wi-Fi up, stock `cnd`/datad native. Evidence archived in `diag-tools/captures/a11-rig-wfc-f3-20260805/`.

**⭐⭐⭐ THE GATE (modem restart with SIM, `sim3-modem-restart-iwlan.txt`):**
```
ds_iwlan_s2b_profile.c:1165  ds_iwlan_s2b_profile_is_wlan_pref: apn len 3 IWLAN? 0
ds_iwlan_s2b_rt_acl.c:489    ds_iwlan_s2b_rt_acl_is_cfg_supported. WLAN not pref for profile 1. Return FALSE.
```
The IWLAN module loads the modem's **own 3GPP profile 1** (apn `ims`, len 3, pdn type 3, subs 1, `Attr:0x110011`, `is_apn_disabled 0`) and asks *is WLAN preferred for this APN* → **0** → rejects the profile before any ePDG/DNS/IKE work. That is why every AP-side lever for 4 sessions did nothing.

**The consequence, one layer up (`sim1-qipcall-wfc-decisions.txt`):**
```
qipcallh.c:45812  qipcallh_if_wifi_calling_enabled: wfc_status - 2, dm_vowifi_disabled - 0, dm_volte_disabled - 0
qipcallh.c:45832  qipcallh_if_wifi_calling_enabled: ret - 0
qipcalliface_ho_mgr.c:2994  get_pref_system | wwan rat service 2, wlan rat service 17   (17 = WLAN no-service)
qipcalliface_ho_mgr.c:2270  get_preferred_rat_for_ims_pdn: pref_rat 2, Voice pref 1, WFC status 2
```
⭐ **WFC provisioning was never the problem.** `wfc_status=2`, both DM kill-switches 0 (`dm_vowifi_disabled=0` — *the entitlement-bit hypothesis (c) is falsified*), and it still returns **not-enabled**. The third condition is the WLAN service that IWLAN refuses to create.

**Falsified this session:**
- **Enum theory:** setting `wifi_call=1` propagates (`wfc_status - 1`) but `ret` stays 0 — so 2-vs-1 was never the issue.
- **Pristine-modem read:** a never-written modem already has `wifi_call=2` (ON) + pref=3 (CELLULAR_PREFERRED) — **our DUT `wifi_call=2` write was always a no-op**; only preference differed.
- **Hypothesis (a) re-killed from the modem's own logs:** `EPDG_FQDN set with length 12` = `wo.vzwwo.com`, plus IKEv2/ESP/NATT timers — ePDG provisioning is complete.
- **`dsd-probe wlanup` proven inert *inside* the modem:** zero `ds_iwlan_s2b_*` messages while DSD returns result=0 (`wlanup-no-iwlan-reaction.txt`). The report never becomes IWLAN state. (Native `cnd`'s reports were equally inert pre-SIM.)

**Where the IWLAN flag comes from — next lane.** `ds_iwlan_s2b_config.txt` carries only IKEv2/ESP/ePDG params (no APN list), so `is_wlan_pref` reads it elsewhere. Leads, in order:
1. **The modem's 3GPP profile itself** — read/modify profile 1 over **QMI WDS** (`nas-probe wds` already dumps profiles; it fails on the rig with `rc=-17` client contention but works on the DUT). Look for an APN-bearer/RAT-mask/`wlan_pref` param and try setting IWLAN. **Cheapest and most direct — do first.**
2. **ANDSF/policy delivery** — `ds_iwlan_s2b_profile_resolve_addr_family. IP type in policy is %d` implies a policy object; the modem has `ds_andsf_wqe_prof_mgr.c`, and **stock ships `/system/etc/cne/andsfCne.xml` + `SwimConfig.xml`** (in `backup-stock-android-8.1-AML0/system.bin.extracted/etc/cne/`) which our build does not. This is the CnE/path-B angle with a concrete artifact to port.
3. `ds_qmi_dsd.c` has a **WLAN-preference get/set** (`Client indicating/querying WLAN preference` → `ps_sys_conf_set_ex : wlan preference %d`) — a *global* pref distinct from the per-APN flag; find its msg id within the implemented ≤0x47 set and try it.

**⭐ Which APN store is this? NOT the build's `apns-conf.xml`.** Two separate databases, and the distinction is the whole point:
- `apns-conf.xml` → the **Android framework** APN DB. Its `network_type_bitmask` does include IWLAN on our Verizon IMS entry — but the modem cannot see it. Editing it will not move this gate.
- The **modem's own 3GPP profile store in EFS**, provisioned from the **carrier MBN**: the VZW cdmaless `mcfg_sw.mbn` carries `/Data_Profiles/Profile1..5` = **Profile1 `ims`**, 2 `vzwadmin`, 3 `vzwinternet`, 4 `vzwapp`, 5 `VZWEMERGENCY` (binary TLV records; APN names ASCII-visible). Matches the F3 exactly (`profile id 1`, `APN length read from 3gpp profile: 3`). The IWLAN module reads **this** one.

⇒ **Verizon's own MBN profile set is what reads `IWLAN? 0`** — i.e. stock could not have done WFC off this profile set either, which squares with stock's entitlement refusal. The profile does carry an attribute mask (`Attr:0x110011` in F3), so the flag may live in bytes we haven't decoded yet. **Do first next session (needs the DUT — rig's rild hogs the clients, `rc=-17`): `nas-probe wds` to dump profile 1's params/attrs live, then try a WDS modify-profile to set the IWLAN/bearer bit.** If the MBN genuinely never sets it, the remaining candidate for who *would* is the ANDSF policy (`andsfCne.xml`) — which converges back on the CnE/path-B work.

**Rig notes:** A16-built `imss-probe`/`dsd-probe` run as-is (no rebuild, no force-ipcr); `nas-probe` can't get DMS/NAS (`rc=-17`). Modem EFS on the rig now has `wifi_call=1`/pref=1 written by this session — restore from the pre-flash snapshot if pristine state is needed.

## Session log 2026-08-05 part 10 — DUT: modem profile store dumped raw; the IWLAN flag is not yet identified

DUT back up (SIM LOADED, US Mobile 311480, LTE). ⚠️ After a fresh boot `adb root` is needed or `/vendor/lib64/libqmi_force_ipcr.so` reads as "Permission denied" (looks like "missing shim" — it isn't).

**⭐ Tool: `nas-probe wdsraw` (new, built on Stellaris16, binary + source updated in-tree).** `do_profiles()` had `default: break; /* keep it quiet */` which silently dropped every profile TLV we don't decode — i.e. exactly the ones we need. `wdsraw` = same as `wds` plus `hexdump_tlv()` on undecoded TLVs. Full dump archived: `diag-tools/captures/a11-rig-wfc-f3-20260805/dut-wds-profiles-raw-20260805.txt`.

**Modem profile store on the DUT confirms the MBN** (independent of `apns-conf.xml`): `[1] IMS`, `[2] vzwadmin`, `[3] vzwinternet`, `[4] vzwapp`, `[5] VZWEMERGENCY`, `[6] roamless`, `qdp_profile_ia`. Attach PDN list = profiles 1,3; attach APN "IMS". Profile 1 carries ~40 TLVs.

**Profile 1 (IMS) vs profile 3 (vzwinternet) — the only differing TLVs:**
`0x1f` 1 vs 0 (P-CSCF-via-PCO, expected for IMS) · `0x25` 1 vs 3 · `0x31` 1 vs 3 · `0x3d` 0 vs 1 · `0x41` 1 vs 0 · `0x42` 1 vs 0.
**None is obviously a RAT/bearer mask, so the IWLAN flag is still unidentified.** Mask-shaped candidates (identical in both profiles, so probably defaults): **`0x35` len 8 = `00×7 80`** (64-bit mask, only bit 63 set — smells like an APN-type-mask "unspecified" sentinel), **`0x37` len 2 = `00 ff`**, **`0x46` len 4 = `ff 00 00 00`**.

**⭐ TLV types ground-truthed offline** (no internet): `parse_idl_any.py libqmiservices.so 0x25440 0x2B` decodes `wds_qmi_idl_service_object_v01` → GET_PROFILE_SETTINGS RESP layout. Result: **`0x35` is the only `u64` in the profile** (types: `0x37` u16, `0x46` u32, `0x45` u32[10], `0x47` u16[10]).
⇒ **`0x35` = `apn_type_mask` almost certainly, and profile 1 holds `0x8000000000000000` = the `UNSPECIFIED` sentinel — the IMS profile declares NO APN type.** Prime candidate for why IWLAN won't take it (an IWLAN/WLAN-preferred decision usually keys off the APN *type*, e.g. the IMS bit `0x02`). ⚠️ Bit meanings not yet verified on this vintage — the IDL gives types, not names/enums; confirm against `qmi-enums-wds.h` (`QMI_WDS_APN_TYPE_MASK_*`) or by comparing with a profile whose type is known.

**Next session, in order:**
1. Verify the `apn_type_mask` bit table, then try **WDS MODIFY_PROFILE** on profile 1 setting the IMS bit (and any RAT/bearer param) — **on the rig first**, watching F3 for `is_wlan_pref: IWLAN? 1`. ⚠️ Our tool's other labels are unverified against the IDL too (it decodes `0x2A` as `apn_disabled`; the IDL says `0x2A` is an AGG of type 0x2a size 52 — **so that label is WRONG** and `wds` output should be re-checked).
2. If `0x35` is `apn_type_mask` with an "unspecified" sentinel, the fix candidate is a **WDS MODIFY_PROFILE** setting the IMS bit (+ IWLAN bearer if a separate param exists), then re-read `is_wlan_pref` on the **rig** (only place with F3 visibility).
3. ⚠️ **Profile 1 is the live IMS/VoLTE PDN.** Snapshot the full TLV set first (done — file above), change one param at a time, re-verify IMS registration after each, and do experimental writes on the **rig** rather than the daily-driver path if possible.
4. Still open in parallel: port stock's `/system/etc/cne/andsfCne.xml` + `SwimConfig.xml` (the ANDSF policy that plausibly sets WLAN-preference per APN).

## Session log 2026-08-05 part 11 — DUT: profile-flag hypothesis falsified; ⭐⭐⭐ the per-APN WLAN preference is the modem's OWN ANDSF RULE MANAGER, provisioned from the MBN

DUT (US Mobile SIM, LTE + IMS registered) + offline MBN/QDB/IDL work. All experiment state reverted; DUT verified healthy at session end (profiles 1/6 pristine, IMS REGISTERED, data VALIDATED, ping OK).

**⭐ TLV ground truth corrected (authoritative: public `wireless_data_service_v01.h`, Sushrut1101/android_vendor_qcom_proprietary, `qmi/data/`; local copy pulled during session; field order matches our IDL parse of msg 0x28/0x2B):**
- **0x35 = `apn_bearer`** (u64 RAT mask), NOT apn_type_mask. Part 10's guess was wrong. Bits on this vintage: G=0x01, W=0x02, L=0x04, ANY=bit63 — **empirically swept: 0x08/0x10/0x20/0x40/0x80 all REJECTED (err 81, ext-err TLV 0xE0=0x0001), 0x07 and ANY accepted ⇒ NO IWLAN bit exists in this firmware's apn_bearer.**
- Full corrected map around the previous "candidates": 0x37=op_pco_id(255), 0x38=pco_mcc(311!), 0x39=pco_mnc{480,pcs=1}, 0x3a/0x3b/0x3c=max_pdn_conn_{per_block,timer}/pdn_req_wait, 0x3d=app_user_data_3gpp, **0x3e=roaming_disallowed** (tmo/att ims=1 = "no IMS PDN while roaming", NOT a WFC flag), 0x3f=pdn_discon_wait_timer, 0x41/0x42=lte/umts_roaming_pdp_type, **0x43/0x44=iwlan↔lte roaming-HO-allowed (already 1 on our profile)**, 0x45=failure_timer_3gpp[10], 0x46=override_home_pdp_type (0xff=unset — explains the "Override home pdn type not set" F3), 0x47=op_reserved_pco_id_list, 0x25=pdp_context number (matches profile #). ⇒ **The 3GPP profile store has NO WLAN-preference parameter at all on this IDL vintage — the profile-modify lane is CLOSED.**
- Tooling: `nas-probe` gained **`wdsget <idx>`** (one-profile raw dump) and **`wdsmod <idx> <tlv> <len> <val> --yes-touch-nas`** (MODIFY_PROFILE_SETTINGS 0x28 + auto read-back). Built on Stellaris16, binary+source in-tree. MODIFY req layout: mandatory TLV 0x01={type u8=0,index u8}, then same TLV ids as GET resp.

**⭐ New DSD messages ground-truthed and exercised (all in the implemented ≤0x47 range):**
- **0x22 SET_WLAN_PREFERENCE (mandatory u32) / 0x23 GET (resp TLV 0x10 u32)** — the global `ps_sys_conf wlan preference`. Was **0** on the DUT (never set by anything in 4 sessions). Set to 1: accepted, persists across clients. **Falsified as sufficient**: with pref=1 + WLAN_AVAILABLE held + radiocycle → IMS re-registers on cellular, no xfrm, no WLAN system.
- **0x29 SET_APN_PREFERRED_SYSTEM** wire format: TLV 0x01 = {len u8, apn bytes, pref_sys u32} (`raw 0x29 0x01:8:3:69:6d:73:1:0:0:0` = ims→WLAN). Combination global-pref=1 + ims-pref=WLAN + WLAN_AVAILABLE held + radiocycle → **still cellular-only**. Every AP→modem DSD/WDS lever is now exhausted.

**⭐⭐⭐ THE MECHANISM (offline, MBN + QDB): `is_wlan_pref` is answered by the modem's own ANDSF rule manager.** The carrier MBNs provision a modem-side ANDSF policy engine (nothing to do with the AP's andsfCne.xml — which turned out to carry NO routing policy at all, only WQE/CQE thresholds, so "port andsfCne.xml" is dead as a policy fix):
- MBN EFS items **`/data/ds_andsf_config.txt`** (`andsf_rule_mgr_active:1` + RAN-measurement tuning), **`/data/default_andsf.xml`**, **`/data/andsf.xml`** — extracted from vzw/tmo/att MBNs to `diag-tools/mcfg-lane/andsf/`.
- **VZW `/data/andsf.xml` = "ims Policy"**: conditional MAPCON ISRP for APN ims — **MAPCON_6: WiFiAvailable=1 + CallType 00 → AccessTechnology 3 (WLAN) priority 1** (i.e. VoWiFi idle-preferred!), plus RSSI/RSRP-threshold handover rules (WiFi RSSI hi/lo −85/−95, SINR 29/18; LTE RSRP −115/−117) and in-call variants. `<PLMN>0</PLMN>`.
- **TMO and ATT active policies are static LTE-preferred for ims (WLAN pri 2) with `IsAPIOverride=1`** — no conditional flip. ⇒ On those carriers stock flips ims→WLAN at runtime via the **API override**, whose transport we have NOT identified (DSD 0x29 is the obvious candidate but is inert on our unit — possibly only honored when the ANDSF engine consumes it, or arrives via another PS_SYS ioctl bridge).
- QDB corroboration: `ds_andsf_APNPriorityListInfo.cpp` ("API Override: %d, basic_tech/active_tech"), `ds_andsf_priority_list_manager.cpp` (update_priority_list per APN), `ds_andsf_wqe_prof_mgr.c` ("wqe_profile_type from CNE", ignores wlan_srv_chg when req_wqe_prof_mask=0), `ds_andsf_api.c` (`notify_wlan_info`, `notify_ap_policy_refresh_status` — AP can deliver policy), `ds_mppm` registers for WLAN_PREFERENCE_CHANGE.
- Also ruled out: `/nv/item_files/data/wlan_config/wlan_offload_config` = **2 in all three MBNs** (S2B/IWLAN offload enabled) — not a discriminator.

**Why the rig's part-9 result makes sense now:** with native cnd + WiFi up + SIM, `is_wlan_pref` still returned 0 — so the ANDSF evaluation is failing on some condition input (WiFi-availability state inside ANDSF, WQE arming, policy not loaded for this ICCID/PLMN, or the CallType/threshold conditions) — NOT on the AP report itself and NOT on the profile store.

**Next session (needs SIM in the A11 rig — Kyle assist):**
1. **F3 capture with the ANDSF filter — the decisive discriminator, never captured before** (previous filters were ds_iwlan/qipcall only). Grep list: `ds_andsf` (all files), `APNPriorityListInfo`, `priority_list`, `wqe_prof`, `ds_mppm`, `is_wlan_pref`, `rt_acl`, `qipcall`. Sequence under capture: boot with SIM → wifi off/on (native cnd reports) → `dsd-probe raw 0x22 0x01:4:1` + `raw 0x29` ims→WLAN (watch whether ANDSF consumes the API override — `IsAPIOverride` path) → radiocycle. Watch which MAPCON condition fails / whether update_priority_list runs at all.
2. **DIAG EFS reads on the rig**: `/data/andsf.xml`, `/data/default_andsf.xml`, `/data/ds_andsf_config.txt` — verify the MBN actually materialized them in EFS (compare with `diag-tools/mcfg-lane/andsf/vzw-cdmaless-*`); plus the part-7 NV list.
3. If ANDSF turns out inert/unprovisioned: DIAG EFS write of a forced-WLAN policy (`AccessTechnology 3 priority 1` unconditional for ims) on the rig and watch `is_wlan_pref` flip — the cleanest possible confirmation, fully modem-side.

## Session log 2026-08-05 part 12 — A11 rig + SIM: ⭐⭐⭐ the gate is **`req_wqe_prof_mask == 0`** — the modem's WLAN-quality machinery is never armed, and only **IMS** can arm it

Rig (Silver `4373dd0f`, Warp SIM, LTE + IMS REGISTERED, Wi-Fi up, native stock `cnd`/`imsdatadaemon`). F3 evidence banked to `diag-tools/captures/a11-rig-wfc-f3-20260805/part12-*.txt`. Rig verified healthy at session end (LTE, IMS REGISTERED, SMS/VoIP FULL_SERVICE, ping OK); all DSD experiment state reverted (global pref back to 0, ims APN pref back to 0, WLAN_NOT_AVAILABLE sent).

**⭐⭐ Our WLAN report was malformed for four sessions — TLV map now ground-truthed.** The modem's `0x20 WLAN_AVAILABLE` handler parses **wqe_status, DNS/ePDG addresses, SSID, channel, bandwidth, WQE profile type, assoc type, network enum, connection status** (`ds_qmi_dsd.c:1181-1458`). `dsd-probe wlanup` sends only MAC+IPv4, so the modem recorded `invalid wlan_conn_status: 255`, `invalid wlan assoc type: 255`, `network_mode:255` (`part12-wlanreport-minimal-invalid255.txt`). Map established empirically by sending distinctive values and reading the modem's own echo — full table + a copy-paste `raw` one-liner now in the `dsd-probe.c` header:
- **`0x12` = `wqe_status`, NOT a DNS address.** ⭐ Retro-explains part 4's "the DNS TLVs 0x12/0x13 are rejected by this modem": we were writing a DNS IP into a small enum → `Invalid WQE status` → `INVALID_ARG (48)`. DNS IPv4 is `0x13/0x14`.
- `0x1b` SSID (1-byte len prefix) · `0x1c` channel · `0x1d` bandwidth · `0x1e` u64 wqe_profile_type · `0x1f` assoc_type · `0x20` network_enum · `0x21` connection_status.
- A full report is **accepted (result=0) and parsed cleanly** — every "invalid 255" complaint disappears (`part12-wlanreport-full-tlv-calibration.txt`). **And it still changes nothing.** Fixing the report was necessary, not sufficient.

**⭐⭐⭐ The actual gate, one level below part 11's ANDSF finding.** With a *valid* report the modem answers:
```
ds_andsf_wqe_prof_mgr.c:448  wlan_srv_chg_cb: ignore wlan_srv_chg, since req_wqe_prof_mask is 0
```
`req_wqe_prof_mask` is written by exactly one thing — `ds_andsf_sys_ioctl_set_wqe_prof_type` (`:567`), an internal ds_sys ioctl whose only caller is **IMS**: `qpDplHandOver.c:5221 DplHandOverSetCNEProfileForMetrics - Called DS_SYS_IOCTL_SET_WQE_PROFILE_TYPE`. That call **never happens** in any capture, so ANDSF never requests a WQE profile → never starts Wi-Fi measurements (`ds_andsf_start_wifi_meas: wifi measurement not required, return`) → has no RSSI to evaluate the VZW MAPCON `WiFiAvailable` condition against → priority list never changes → `is_wlan_pref = 0` → IWLAN rejects profile 1. **The arming order is IMS → ANDSF → AP report; we have been pushing from the wrong end of the chain all along.** The AP's `wqe_profile_type` (TLV `0x1e`) is only ever *compared* against the IMS-set mask (`:902 WQE profile type passed by CNE is not requested by WQE profile manager`).

**⭐⭐ First-ever ANDSF priority-list dump** (`part12-modem-restart-andsf-plist.txt`, from a verified modem restart). `ds_andsf_rule_manager.cpp:302 == ANDSFPriorityListManager - Printing plist data ==` → 6 APN entries, `API Override: 0/1, basic_tech_num, tech_num`, techs `{0,1}` with 0 listed first. So the policy **is** loaded and the ims APN **does** carry a second access tech — it is simply ordered cellular-first, exactly what the conditional MAPCON rule implies when its Wi-Fi condition is unmet. `No ANDSF Rule to compare` and `Failed to decode andsf file` never appear ⇒ ANDSF is provisioned, not empty.

**Falsified / closed this session:**
- **DSD `0x29 SET_APN_PREFERRED_SYSTEM` is inert, now proven from the modem's side.** Swept pref_sys 0/1/2/3 under F3: each is received (`qmi_dsdi_set_apn_preference_system : apn_name ims pref_sys N`) and each time ANDSF answers `Priority list change bitmask:0 / Priority list unchanged`. The boot dump's `API Override: 1` comes from the policy XML's `IsAPIOverride`, **not** from our writes. Same for `0x22` global pref.
- **`event_update_location_wlan - srv status : 0` is a red herring** — it prints `0` for WLAN_AVAILABLE *and* WLAN_NOT_AVAILABLE. Do not read it as "WLAN not available".
- **IMS is not missing its thresholds.** New: IMSS **`0x5e` = GET_HANDOVER_CONFIG** (`0x5d` = SET) reads back WLAN→1x / WLAN→WWAN / WWAN→WLAN hysteresis = 120 s each and thresholds `-12, -112, -115, -100, -65, -80` — the LTE trio matches the live F3 `qpDplLTEMeasureCallback_ex: TH_1 -112 | TH_2 -115 | TH_3 -100`, and −65/−80 are the Wi-Fi rove thresholds. IMS holds valid WFC handover config and *still* doesn't arm WQE. (SET `0x5d` carries TLVs to `0x2e`; only `0x11`–`0x1a` are populated — the unset tail is unexplored.)
- **Modem EFS cannot be mined offline** — `modemst1`/`modemst2`/`fsg` pulled off the rig are encrypted/scrambled (zero readable filenames, no `andsf`/`epdg`/XML strings). Part 11's step-2 "DIAG EFS reads" needs a real DIAG EFS2 client; there is no shortcut via the raw partitions.
- Native stock `cnd` on the rig **never sends WLAN_AVAILABLE at all** across a full Wi-Fi bounce — expected (the phh GSI ships no CneApp to feed it), so it is *not* evidence about stock behaviour.

**⭐ New provisioning surface worth one more look:** `ims_settings_common.c:2336-2464` shows `ims_settings_set_ims_config` carries **`Enable VoWifi`** (a bit in `iDM_Services_Mask`), `eWFCStatus`, `eWFCPreference`, `eWFCRoamPreference`, `iWFCRoaming` and a **`VoWifi Prov Name`** string — a store distinct from the `0x53/0x54` client-provisioning one we have been writing. Its message id is not yet identified (`0x47/0x48`, `0x22`, `0x5d`, `0x30` inspected via the IDL; none matches the field shape). Note `wfc_status` itself is *not* a second copy: `qipcallh` echoes exactly the value we write to `0x53 TLV 0x14`.

**Next session, in order:**
1. **Find what makes IMS call `DplHandOverSetCNEProfileForMetrics`.** This is now the whole lane. Cheapest probes: the unset tail of SET_HANDOVER_CONFIG (`0x5d` TLVs `0x1b`–`0x2e`) — read `0x5e` first, change one at a time; and identify/GET the `ims_settings_set_ims_config` message to check whether `Enable VoWifi` is actually off in the DM services mask (`dm_vowifi_disabled=0` proves "not disabled", not "enabled").
2. If AP-side probing stalls, disassemble the caller of `DplHandOverSetCNEProfileForMetrics` in the modem image for its precondition (the `iDSSysProfileTypeMask` construction) — a narrow, well-targeted RE question, a fair exception to [[feedback-blackbox-before-re]] now that the black-box levers are exhausted.
3. Only once WQE arms is it worth re-sending the (now correct) full WLAN report and watching for `is_wlan_pref: IWLAN? 1`.
4. Unchanged and still unresolved: whether Verizon's ePDG would accept us even with a perfect stack (stock's entitlement refusal, part 3). An active T-Mobile SIM remains the cheapest carrier-side discriminator.

**Rig operating notes:**
- `setprop ctl.stop per_mgr` then `ctl.restart per_mgr` does **NOT** bring the modem back — `ctl.restart` on an already-stopped service is a no-op and the modem stays down (`init.svc.per_mgr=stopped`, empty `gsm.operator.numeric`). Use `ctl.restart per_proxy` + **`ctl.start per_mgr`**, and confirm the cycle via `Request count` in `/d/rmt_storage/info` (+1 per restart).
- adb drops for ~20-40 s across a modem restart — drive these sequences from a **detached on-device script** (`setsid sh …`) that logs timestamps, then poll the log, rather than from a foreground `adb shell`.
- `diag_mdlog -k` must run **after** the event of interest; a capture stopped early silently loses the modem-boot F3 (cost one wasted cycle this session).

## Session log 2026-08-05 part 13 — A11 rig: ⭐⭐⭐ the full IMS→HO→WQE chain mapped; the gate is `qipcallh_if_wifi_calling_enabled` returning 0

Rig (Silver `4373dd0f`, Warp SIM, LTE + IMS REGISTERED, Wi-Fi 10.0.2.106, native stock `cnd`/`imsdatadaemon`). Evidence: `diag-tools/captures/a11-rig-wfc-f3-20260805/part13-*.txt`. Rig verified healthy at session end (LTE, IMS REGISTERED, SMS/VoIP FULL_SERVICE, ping OK); the one config change made was reverted exactly (see below).

**⭐⭐ Method note that unlocked this: every previous capture was decoded with a filter that excluded the deciding modules.** The banked `.qmdl` files were still on the rig, so parts 9–12's raw captures were simply **re-decoded** with `PDPManager|PDPHandler|PDPRATHandlerVoLTE|ims_settings_common|qpDplHandOver|cmph` — no new device work, and it produced most of this session's findings. Lesson: when a lane stalls, re-decode the captures you already have with a wider file filter before capturing again. (`decode_f3.py`'s 3rd arg is a **source-file** regex, not a text regex.)

**⭐⭐⭐ The chain, top to bottom, all from the modem's own F3:**
```
qipcallh.c:45812   qipcallh_if_wifi_calling_enabled: wfc_status - 2, dm_vowifi_disabled - 0, dm_volte_disabled - 0
qipcallh.c:45832   qipcallh_if_wifi_calling_enabled: ret - 0            <-- THE GATE (4th condition, unknown)
ho_mgr.c:7811      get_ho_wlan_srv_status: ... return iface wlan rat 17 (no service)
ho_mgr.c:4725      set_wwan_iwlan_handover_measurement_params: TRAT MASK 0x00, SRAT MASK 0x0b, Serving Domain 2
qpDplHandOver:5055 qpDplHandOverParamsSet_ex: Unprocessed SRAT = 0, Unporcessed TRAT = 0   (0 = DCM_RAT_NONE)
qpDplHandOver:5102 Params passed by APP are the same as current values, returning !!!
   => qpDplWiFiMeasurementsSetParamEx never INITs
   => DplHandOverSetCNEProfileForMetrics (5211/5221/5233) NEVER called — not even the
      "ProfileMask set is INVALID" branch, so it is not a bad-mask problem, it is never reached
   => req_wqe_prof_mask stays 0  => ANDSF discards every wlan_srv_chg (part 12's line)
```
⇒ **Part 12's "IMS → ANDSF → AP report" arming order was right, but the blocker is one level higher still: qipcall never declares IWLAN a candidate target RAT.** `qpDplHandOver.c:2912/2913` confirms the values reaching the engine: `input SRAT=10 TRAT=25 PREFRAT=6` / `stored SRAT=0 TRAT=0 PREFRAT=0`.

**Falsified this session (both of part 12's proposed next steps):**
- **`Enable VoWifi` is already ON.** `ims_settings_common.c:4518-4530 ims_settings_get_ims_config: Enable VoWifi =1, eWFCStatus =2, eWFCPreference =1, eWFCRoamPreference =0`. The `iDM_Services_Mask` VoWifi bit is set; there is no second provisioning store to fix. Close that lead.
- **SET_HANDOVER_CONFIG (`0x5d`) exercised live — it works, and it is not the arming lever.** `imss-probe setmsg32 0x5d 0x19 <val>` drove the whole path on demand: `QC_IMS_QMI_SET_HANDOVER_CONFIG_REQ` → `ims_settings_set_handover_config: HO WIFI Threshold B Valid = 1, = -65` → `qpDplHandOver.c:6016 DPLUpdateHOConfig: WiFi Config Valid` → `5918 DPLUpdateWiFiConfig: Profile 2 Data Buffer` → `ds_andsf_wqe_prof_mgr.c:1565 Recieve wifi threshold update from IMS`. **It reaches ANDSF and is accepted — and stops at `1689 cache to global cache`** because `ds_andsf_wqe_prof_mgr_is_meas_started: 0`: the threshold path can only *update* profiles already in `req_wqe_prof_mask`, never *request* one. Arming really is exclusive to `DS_SYS_IOCTL_SET_WQE_PROFILE_TYPE`.
- **`PDPManager` never runs its measurement-based RAT selection on VZW.** `2309 GetPreferredRAT ... performMeasurements[1]` (so measurements *are* wanted), then `2339 Initial GetPreferredRAT preferredRAT[0|10]` → `2340 OperatorMode[0]` → `2345 preferredRAT for VZW[0|10]` → `2377 Preferred RAT 0|10`. Line **`2368 Initial GetPreferredRAT with Measurements`** never fires, and the result is never IWLAN. Consistent with part 11: on VZW the routing decision is delegated to ANDSF/MAPCON, not to modem-side Wi-Fi measurement.
- `qipcalliface_ho_mgr.c:4394 "Non IR-92 or TMO mode or VZW. return..."` — an operator-mode early-return that looked like a prime suspect — **never fires**. We pass that gate.
- `IsVoWIFIServiceEnabled` (PDPManager.cpp:5160-5230, the OMA-DM/MDN-match/ATT block) **never runs** on this carrier — an ATT-mode path. Not our problem.

**⭐⭐ Genuine (but secondary) find: a modem-internal cold-boot race on the ANDSF ICCID.** On a modem restart, IMS pushes the WFC thresholds *before* ANDSF has a valid ICCID:
```
[..4440a009] ds_andsf_wqe_prof_mgr.c:1565  Recieve wifi threshold update from IMS: subs_id: 1, num of prof: 2
[..4440a009] ds_andsf_wqe_prof_mgr.c:1589  is iccid valid: 0            <-- too early
             ... 1630/1649/1655/1689 → thresholds only CACHED (profile 0x1 = -65, 0x2 = -80)
[..45057c09] ds_andsf_wqe_prof_mgr.c:2101  iccid_info_chg_hdlr, subs_id: 1, is iccid_valid: 1, iccid_len: 10
```
The ICCID lands ~0.7 s later and **nothing replays the update**; a radio/airplane cycle does not replay it either (`cap-andsf3` shows only `wlan_srv_chg_cb: ignore ... req_wqe_prof_mask is 0`). The `0x5d` write above is the manual replay, and it now runs with `is iccid valid: 1` — proving the race is real and fixable-from-the-AP. **But it changes nothing on its own**, because the threshold path can't arm. Keep it on the list: if the 4th condition is ever satisfied, this race may become the *next* blocker, and the `0x5d` re-push is its ready-made workaround.

**⭐ TLV mapping ground-truthed for IMSS handover config:** SET REQ TLV ids are **GET RESP ids − 1** (same convention as `0x53`/`0x54`, part 2). `SET 0x5d TLV 0x19` writes what `GET 0x5e` reads back as TLV `0x1a` (= "HO WIFI Threshold B"); `SET 0x5d TLV 0x1a` is malformed (`result=1 error=1`) because GET `0x1b` does not exist. GET 0x5e map: `0x11-0x13` = WLAN→1x / WLAN→WWAN / WWAN→WLAN hysteresis (120 s each), `0x14`=1, `0x15`=-12 (1x), `0x16/0x17/0x18` = LTE TH_1/2/3 (-112/-115/-100), `0x19` = Wi-Fi TH_A (-65), `0x1a` = Wi-Fi TH_B (-80). ⚠️ Experiment state fully reverted: 0x19=-65, 0x1a=-80, byte-identical to session start.

**Next session, in order:**
1. **RE `qipcallh_if_wifi_calling_enabled` (qipcallh.c ~45807-45832).** This is now the whole lane, and it is about as narrow as an RE question gets: a small function bracketed by two known QSR4 msgids, three of whose inputs we can already read (`wfc_status=2`, both DM disables 0) and which still returns 0. Find the 4th condition. Locate the function by its msgid immediates in the modem image (Ghidra Hexagon setup from `PLAN-modem-disasm.md`), then read its predicate. A fair exception to [[feedback-blackbox-before-re]] — every black-box lever is now exhausted and the target is precisely known.
2. If the 4th condition turns out to be the WLAN service status (i.e. genuinely circular: no WLAN service → no measurements → no WLAN service), then the loop can only be broken from ANDSF, and the remaining move is the **DIAG EFS write of a forced-WLAN ims policy** (part 11 step 3) — still never attempted, still the cleanest fully-modem-side test.
3. Unchanged: an active **T-Mobile SIM** remains the cheapest carrier-side discriminator, and Verizon's entitlement refusal (part 3) still caps this lane's realistic odds.

## Runbook — T-Mobile SIM discriminator on the A11 rig (written 2026-08-05, part 13; unrun)

**Why this test is worth running, in one line:** TMO's MBN ims rule is *static + `IsAPIOverride=1`* (cellular pri 1, WLAN pri 2) with **no `WiFiAvailable` condition** — so it does not depend on the WQE-measurement machinery that blocks us on VZW. Different carrier mode ⇒ different code in at least three places we've already instrumented (`PDPManager` OperatorMode, `ho_mgr.c:4394`, ANDSF policy shape). Confirmed on-modem: the PDC list carries **`Commercial-TMO`** alongside `CDMAless-Verizon` / `VoLTE-ATT` / `ROW_Generic_3GPP`, so a TMO ICCID gets its own config rather than a generic fallback.

**SIM requirements (all three matter — a miss makes the run inconclusive, not negative):**
- **Active line with a real plan.** The Dark Star lesson (part 1): an unprovisioned SIM has *no IMS provisioning at all*, which kills the test upstream of anything WFC-related.
- **Native T-Mobile, not a TMO MVNO.** MVNOs commonly lack WFC entitlement, and an off-list ICCID may select `ROW_Generic_3GPP` instead of `Commercial-TMO`.
- ⚠️ **Coverage:** we are **B2/B4/B66 mid-band only** on T-Mobile — no B12/B71 low-band (`diag-tools/mcfg-lane/BANDS-ANALYSIS.md`). Indoor LTE may be weak, and we need LTE + IMS up *before* WFC can be provisioned. Test near a window; confirm registration before investing in captures.

**Run it on the rig (Silver `4373dd0f`), not the DUT** — F3 visibility is the entire value of the test. That means pulling the Warp SIM out of Silver. No pre-swap banking needed: the VZW baseline is `cap-init2`, already re-decoded with the correct filter (`part13-*.txt`).

### Step 1 — swap, boot, register
```bash
adb -s 4373dd0f root
adb -s 4373dd0f shell 'getprop gsm.sim.state; getprop gsm.operator.numeric; getprop gsm.network.type'
```
⚠️ **The phh GSI defaults to GSM/WCDMA.** Settings → Network → preferred network type = **LTE**, or nothing registers.

- **Gate A — no LTE registration** (`gsm.operator.numeric` never becomes `310260`): coverage/band problem. Stop; the run is inconclusive, not a negative result.
- **Gate B — LTE up but IMS not registered** (`imsa-probe` → `ims_registered = 0`): the SIM has no IMS provisioning (Dark Star repeat). Stop; fix the line before spending captures.

```bash
adb -s 4373dd0f shell '/data/local/tmp/imsa-probe | grep -E "ims_registered|voip_service|sms_service"'
```

### Step 2 — confirm the modem selected the TMO MBN
⚠️ **`pdc-probe` does NOT work on the rig** — it tries a fixed IDL-minor list `{1,8,10,11,12,15,16}` and the stock vendor `libqmiservices.so` matches none of them (`service object NULL for all tried minors`). Verified 2026-08-05; don't burn time on it. `nas-probe wdsraw` (which would show the APN names) is also unavailable on the rig — `rc=-17`, client-slot contention with the native rild.

**Use the modem's own F3 instead — it's free, since Capture 1 already collects it.** `ds_iwlan_s2b_config.c` logs `EPDG_FQDN set with length %d` at every modem init, and the length identifies the live MBN:

| Length | FQDN | MBN |
|---|---|---|
| 12 | `wo.vzwwo.com` | CDMAless-Verizon |
| 16 | `epdg.epc.att.net` | VoLTE-ATT |
| **42** | `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org` | **Commercial-TMO** |
| 42 | `epdg.epc.mnc001.mcc001.pub.3gppnetwork.org` | ROW_Generic_3GPP ⚠️ same length |

So `12 → 42` is the tell that the config switched. The one ambiguity is ROW_Generic (also 42) — which is what you'd get if the ICCID *isn't* recognised, i.e. exactly the failure case. Disambiguate with `gsm.operator.numeric = 310260` plus the ANDSF policy shape (TMO's ims rule carries **two** access techs + `IsAPIOverride=1`; see `diag-tools/mcfg-lane/andsf/tmo-andsf.xml`). If it looks like ROW_Generic, treat all results with suspicion — the policy under test isn't the one analysed above.

### Step 3 — provision WFC on the new ICCID (the store is per-SIM)
```bash
adb -s 4373dd0f shell 'cd /data/local/tmp && \
  ./imss-probe get 0x54 && \
  ./imss-probe setmsg32 0x53 0x14 2 && \
  ./imss-probe setmsg32 0x53 0x15 1 && \
  ./imss-probe get 0x54 && \
  ./imss-probe get 0x5e'
```
Want `wifi_call=2 (ON)`, `wifi_call_preference=1 (WLAN_PREFERRED)`. **Snapshot `get 0x5e` output into the session log before any `0x5d` write** — a single-TLV SET mutates stored config, and SET REQ ids are GET RESP ids **− 1**.

### Step 4 — Capture 1: modem restart (the decisive one)
The full init trace is where `PDPManager` picks operator mode, qipcall builds the RAT masks, and IMS pushes thresholds. Drive it from a **detached** script (adb drops 20–40 s across a modem restart):

```sh
#!/system/bin/sh
T=/data/local/tmp
log() { echo "[$(date +%H:%M:%S)] $*" >> $T/cap-tmo.log; }
rm -f $T/cap-tmo.log; for p in $(pidof diag_mdlog); do kill -9 $p; done
rm -rf $T/cap-tmo1; mkdir -p $T/cap-tmo1
( setsid diag_mdlog -f $T/Diag.cfg -o $T/cap-tmo1 </dev/null >/dev/null 2>&1 & )
sleep 6; log "mdlog=$(pidof diag_mdlog) rc=$(grep -i 'Request count' /d/rmt_storage/info)"
setprop ctl.stop per_mgr;  sleep 8;  log "per_mgr=$(getprop init.svc.per_mgr)"
setprop ctl.restart per_proxy; sleep 2; setprop ctl.start per_mgr; log "started per_mgr"
i=0; while [ $i -lt 30 ]; do sleep 5; i=$((i+1)); \
  [ "$(getprop gsm.sim.state)" = "LOADED" ] && break; done
log "sim=$(getprop gsm.sim.state) op=$(getprop gsm.operator.numeric) rc=$(grep -i 'Request count' /d/rmt_storage/info)"
sleep 60; log "op=$(getprop gsm.operator.numeric) type=$(getprop gsm.network.type)"
$T/imsa-probe 2>&1 | grep -E "ims_registered|voip_service_rat" >> $T/cap-tmo.log
diag_mdlog -k >/dev/null 2>&1; log "done"
```
⚠️ `ctl.stop per_mgr` + `ctl.restart per_mgr` does **not** restart it — `ctl.restart` no-ops on a stopped service and the modem stays down. Use `ctl.restart per_proxy` + **`ctl.start per_mgr`**, and confirm via `Request count` in `/d/rmt_storage/info` (+1 per restart). Stop `diag_mdlog -k` only **after** the event.

### Step 5 — decode and read the verdict
⭐ Decode with the capture dir's **own** `<guid>.qdb` (per-unit builds differ), and with the **wide** file filter — `decode_f3.py`'s 3rd arg is a source-file regex, and using a narrow one is exactly what hid the answer for four sessions:
```bash
python3 diag-tools/decode_f3.py rig_qdb.dec cap-tmo1/*.qmdl \
  'PDPManager|PDPHandler|PDPRATHandlerVoLTE|ims_settings_common|qpDplHandOver|qipcall|ds_andsf|ds_iwlan|cmph' > tmo1.txt
```

| Watch for | VZW today | TMO result that means progress |
|---|---|---|
| `qipcallh.c:45832 …wifi_calling_enabled: ret` | `0` | **`1`** — the gate is carrier-conditioned |
| `PDPManager.cpp:2340 OperatorMode` | `0` (VZW branch) | any other value |
| `PDPManager.cpp:2368 GetPreferredRAT with Measurements` | never runs | **runs** — measurement path alive |
| `ho_mgr.c:4394 "Non IR-92 or TMO mode or VZW"` | never fires | fires → TMO takes the early-return instead |
| `ho_mgr.c:4725 TRAT MASK` | `0x00` | **non-zero** — IWLAN is a candidate |
| `qpDplHandOver.c:5055 Unprocessed SRAT/TRAT` | `0 / 0` | non-zero TRAT |
| `qpDplHandOver.c:5211/5221 DplHandOverSetCNEProfileForMetrics` | never reached | **reached** — WQE arms |
| `ds_andsf_wqe_prof_mgr.c:448 "req_wqe_prof_mask is 0"` | fires | gone |
| `ds_iwlan_s2b_profile.c:1165 is_wlan_pref: IWLAN?` | `0` | **`1`** — through the wall |

### Step 6 — Capture 2: the API-override shot (TMO-specific, run even if Capture 1 is flat)
TMO's ims rule declares `IsAPIOverride=1`. DSD `0x29` was proven inert on VZW — but against a *conditional MAPCON* policy, where the override flag came from the XML rather than our write. Against a static rule that advertises the override, it's an untested proposition. Sequence under capture: Wi-Fi up → full (correct) WLAN report → `0x22` global pref → `0x29` ims→WLAN → radiocycle.
```bash
# full WLAN report — adjust MAC / IPv4 / SSID for the rig's actual connection
dsd-probe raw 0x20 0x01:6:0x78:0x24:0xaf:0x7b:0x47:0xea 0x10:4:10:0:2:106 \
  0x12:4:1:0:0:0 0x1b:8:7:121:101:108:112:112:117:98 0x1c:2:11:0 \
  0x1d:2:20:0 0x1e:8:1:0:0:0:0:0:0:0 0x1f:4:1:0:0:0 0x20:4:2:0:0:0 0x21:4:3:0:0:0
dsd-probe raw 0x22 0x01:4:1                              # global WLAN preference = 1
dsd-probe raw 0x29 0x01:8:3:69:6d:73:1:0:0:0             # apn "ims" -> pref_sys WLAN
```
Then radiocycle with `cmd connectivity airplane-mode enable` / `disable` (⚠️ **never** `am broadcast -a android.intent.action.AIRPLANE_MODE` — it re-applies airplane state and kills Wi-Fi/TCP-adb). Grep the decode for `ds_andsf_rule_manager.cpp:298 Priority list change bitmask` — **non-zero** means the override was consumed, which is the whole point of this capture.

### Step 7 — if it works
Watch for `ip xfrm state/policy` populating, `r_rmnet*`/`rev_rmnet*` coming UP, and IMSA reporting registration over WLAN (`voip_service_rat` changing from 1). Then: call + SMS over Wi-Fi with airplane-mode-except-Wi-Fi (Phase 3).

### Step 8 — hygiene
Promote the SIM-in captures to `diag-tools/captures/`. WFC NV writes persist per-ICCID in modem EFS (harmless, and they're the provisioning we want). Restore `get 0x5e` values if any `0x5d` write was made. Re-verify LTE + IMS + ping before putting the Warp SIM back.

**Interpreting the outcome honestly:** a TMO win proves our stack can do VoWiFi end to end and localises the block to Verizon — it does **not** deliver WFC on Warp, which is the daily driver. The `qipcallh_if_wifi_calling_enabled` RE remains the only route to that. A TMO failure at the *same* `ret - 0` gate is the stronger result in one sense: it says the block is carrier-independent and structural, and the RE becomes unambiguously the whole lane.

## Session log 2026-08-05 part 14 — RE lane: ⭐⭐ the QSR4 msgid↔modem-code mapping is CRACKED; the specific function is not yet located

Offline only (no device work; Silver was on USB but untouched). Goal was part 13 step 1 — RE `qipcallh_if_wifi_calling_enabled`. Before that function can be found, one prerequisite had to be solved that no previous session had: **given an F3 msgid from the QDB, where is the emitting code?** That is now answered, and it is reusable for every future modem-RE question in this project.

**The three anchors** (identical in BOTH QDBs — `079960cf`/v1AML, which matches our `backup-stock-android-8.1-AML0/modem.bin`, and `aa70ba0d`/v1AMG, Silver's — so msgid assignment is stable across builds):
```
184868:8:51:45807:qipcallh.c:qipcallh_if_wifi_calling_enabled: iface_ptr or nv_ptr is NULL
174223:4:51:45812:qipcallh.c:qipcallh_if_wifi_calling_enabled: wfc_status - %d, dm_vowifi_disabled - %d, dm_volte_disabled - %d
174224:4:51:45832:qipcallh.c:qipcallh_if_wifi_calling_enabled: ret - %d
```
Only three F3 lines in the whole function ⇒ the 4th condition is **silent**, and the function body is ~25 source lines (45807→45832).

**⭐⭐ How QSR4 msgids map to code (the reusable finding):**
- **msgids are NOT stored in the modem image.** Proven statistically, not by absence of a single value: 300 random real msgids appear as LE32 in the 60 MB ELF **13** times vs **9** for a random-integer control. Nothing to grep for.
- The code instead materialises a **descriptor pointer = `QSR_BASE + 8 × msgid`** into a **NOLOAD section at `0xf8xxxxxx`** (outside every loaded segment — that address range appears only as immediates). The DIAG runtime converts pointer→msgid.
- Built with Hexagon `immext` + `##`. **Decoder (validated on 4 known pairs):** for a word `W` with `W>>28 == 0`, `ext_value = ((((W>>16)&0xFFF) << 14) | (W & 0x3FFF)) << 6`; the paired instruction supplies bits `[5:0]` (for `A2_tfrsi`, `imm[5:0] = (next_word >> 5) & 0x3F`).
- **⭐ Scan raw words, not objdump text.** `llvm-objdump-15` desyncs on data-in-code and silently drops whole files' worth of constants — that artefact alone produced a bogus "group A / group B" file split that cost a chunk of this session. Raw-word scanning is immune.
- **Generic send helpers, arg-count calibrated** against the main module (17.5k samples, ≥93 % agreement): `0x875b85f4` = 0 args, `0x875b8a20` = 1, `0x875b8d50` = 2, `0x875b90f8` = 3. Useful as a per-call-site fingerprint.

**⭐ Module map:**
- **Main modem module: `QSR_BASE = 0xf8000000`** — 89,840 / 106,271 referenced descriptors fit; ~50–75 % of each file's msgids are referenced (the rest is dead/inlined code, so <100 % is expected and is not a failure of the model).
- **msgids 140000–219999 are a SECOND module with its own base** — a clean contiguous zero-band under `0xf8000000` (0 % across the whole range vs 50–75 % everywhere else). This band is the IMS block: `qipcallh.c`, `ims_settings_common.c`, `qpDplHandOver.c`, `PDPManager.cpp`, `qipcalliface_ho_mgr.c`. (`qmi_nas.c`/`cmph.c` are a *third* module — also 0 % under both bases.)
- The IMS base solves to roughly **`0xf84f7328`–`0xf84f7348`**, which fits every IMS file at a consistent ~77 % and clusters `qipcallh.c`'s 1596 referenced descriptors into a single ~163 KB code region — the right size for a 46,000-line file. **`qipcallh.c` compiles to approximately `0x8720f000`–`0x87290000`.**

🔴 **Where it stalled: the IMS base cannot be pinned to a single 8-byte slot by statistics.** Shifting the base by one slot maps msgid *m* → *m±1*, which is almost always **the same source file** — so code-locality and file-purity scoring both plateau across ~1000 candidate slots (locality peaked at `0xf84f7340`, purity at `0xf84f93b0` — 1038 slots apart, both flat). The arg-count discriminator, which *would* have resolution, fails here because IMS call sites go through **file-local logging wrappers** (`0x872108e8`, `0x872109d8`, `0x87210ae4`, `0x87210b58`) with their own calling conventions — e.g. `87210b58: jump 0x8721084c; r1:0 = combine(r0, ##…)` passes the descriptor in **r1**, not r0 — instead of calling the generic helpers directly.

**Next session — switch tools, do not re-run the brute force.** The remaining step is exactly what a real disassembler is for: load `modem.elf` in **Ghidra with the Hexagon processor** (setup already proven, `PLAN-modem-disasm.md`), let auto-analysis build functions + xrefs, then either (a) resolve the local wrappers' arg counts to pin the base by the arg-count test, or (b) skip the base entirely — find the ~25-line function structurally in `0x8720f000`–`0x87290000`: `allocframe`, two null-checks → 0-arg msg call, a 3-arg msg call, a short predicate, a 1-arg msg call, `dealloc_return`. Then read the predicate. ⚠️ Budget hours for the Hexagon auto-analysis of a 20 MB text segment.

**Reproduce the workspace (all offline, ~1 min):**
```bash
WORK=<scratch>; mkdir -p $WORK && cd $WORK
7z x -y ~/android/lineage-23/backup-stock-android-8.1-AML0/modem.bin 'image/modem.*'
python3 ~/android/lineage-23/scripts/mpss-reasm.py image modem.elf     # 60 MB, 23 phdrs
/usr/bin/llvm-objdump-15 -d --triple=hexagon --start-address=0x86ce3000 \
    --stop-address=0x88041000 modem.elf > seg10.dis                    # ~17 s
```
⚠️ To disassemble the R-only segments, copy the ELF and OR `PF_X` into every phdr's flags word (`p_flags` at phdr+24) — objdump only decodes `PF_X` segments and silently emits nothing otherwise (it does **not** error).

## Session log 2026-08-06 part 15 — ⭐⭐⭐ T-MOBILE RUN DONE: the gate is CARRIER-INDEPENDENT, and a far better RE target found

A11 rig (Silver `4373dd0f`) with a **US Mobile × T-Mobile eSIM-adapter line** (ICCID `8901240527147049350`, `hplmns=[310260]` = native TMO home PLMN, `carrierName=US Mobile`). Evidence: `diag-tools/captures/a11-rig-wfc-f3-20260805/part14-*`. Rig verified healthy at session end (310260 LTE, IMS REGISTERED, SMS/VoIP FULL_SERVICE, ping 27 ms, Wi-Fi 10.0.2.106).

**Both gates passed — this was a valid test, not an MVNO washout.**
- **Gate A:** registers on **310260** (native T-Mobile PLMN), LTE. ⚠️ Required fixing `preferred_network_mode` (was `1`=GSM/WCDMA-ish per-sub `8`/global `0`) → **9** (LTE/GSM/WCDMA) via `settings put global preferred_network_mode{,1,2} 9` + `cmd connectivity airplane-mode` cycle. The phh-GSI trap from part 9, and fatal on TMO specifically because there is no 2G/3G left to camp on.
- **Gate B:** `ims_registered = 1`, IMPU **`sip:14254035265@msg.pc.t-mobile.com`**, SMS/VoIP/VT/**UT** all FULL_SERVICE. A properly provisioned line — not a Dark Star repeat. The MVNO worry did not materialise.
- Modem restart confirmed via `/d/rmt_storage/info` Request count 1 → 2.

**⭐⭐⭐ VERDICT: `ret - 0` is carrier-independent.** `qipcallh_if_wifi_calling_enabled: wfc_status - 2, dm_vowifi_disabled - 0, dm_volte_disabled - 0` → **`ret - 0`**, exactly as on VZW. Two carriers, two operator modes, two MBNs, two ANDSF policy shapes — identical answer. Per part 13's own framing this is the *stronger* result: the block is **structural, not a Verizon refusal**, and the RE is now unambiguously the whole lane. It also means a TMO win was never going to hand us WFC on Warp.

**⭐⭐⭐ THE NEW RE TARGET — `qpIMSPolicyManager.cpp:504–510`, far better than qipcallh.** A second, independent expression of the same gate, in a file this lane had never looked at. The QDB shows the whole branch as consecutive msgids:
```
164803  line 449  QPConfigurationHandler::extractIWLANRAT retVal %d               <-- NEVER fires, either carrier
164804  line 474  QPConfigurationHandler::extractGWTOrLRAT ratVal %d              <-- fires 78x TMO / 32x VZW
164805  line 504  qpGetPreferredRAT ratMask %d WFC %d CallmodePreference %d
164806  line 510  qpGetPreferredRAT WFC OFF Extracting G,W,L Rat                  <-- ALWAYS taken
164807  line 524  qpGetPreferredRAT WFC ON                                        <-- NEVER taken
164808  line 570  qpGetPreferredRAT returning %d
```
**Every call reads `WFC 2 CallmodePreference 1` and still takes the WFC-OFF branch: 78/78 on TMO, 32/32 on VZW.** Observed `ratMask` values at :504 = 1024 / 1 / 0 / 32768. Why this beats `qipcallh_if_wifi_calling_enabled` as an RE target:
- The condition lives in **~4 source lines (504→510)** vs qipcallh's 20 (45812→45832).
- **All inputs are logged**, so the predicate's variables are known.
- `164805/164806/164807` are **consecutive msgids** ⇒ descriptors 8 bytes apart ⇒ a 3-slot run referenced inside one function = a very strong binary fingerprint (and `164807` is *compiled in but never executed*, so it is present in the image to find).
- Same IMS module band (140000–219999) as qipcallh, so the same QSR base applies — pin it once, get both.

**⭐⭐ What T-Mobile DID do differently (the rest of the chain is alive and carrier-sensitive — only the WFC gate is stuck):**
| Signal | VZW | TMO |
|---|---|---|
| `PDPManager.cpp:2340 OperatorMode` | `0` | **`9`** |
| `PDPManager.cpp:2368 GetPreferredRAT with Measurements` | never runs | **RUNS** |
| `ds_andsf_ran_meas.c:846 lte_meas changed` | — | **runs** (`avg_rsrp: -105 db`) |
| `ds_andsf_rule_manager.cpp:298 Priority list change bitmask` | always `0`/unchanged | **`5`** (×5) — the plist really changes |
| `APNPriorityListInfo API Override` | `0/1` | **`1`**, `basic_tech_num:2 tech_num:2` |
| profiles evaluated by `rt_acl` | profile 1 | profiles **1, 2 and 7** |
| `qipcalliface_ho_mgr.c:5844` | — | `not in vzw vowifi specific mode` (confirms non-VZW config) |
| `ds_iwlan_s2b_profile.c:1165 is_wlan_pref: IWLAN?` | `0` (apn len 3) | **`0`** (apn len 3 *and* 17) |
| `qipcallh.c:45832 ret` | `0` | **`0`** |

So TMO genuinely runs a different carrier mode, arms ANDSF measurements, and mutates its priority list — and still lands on `IWLAN? 0` for every profile. `DplHandOverSetCNEProfileForMetrics` is still never reached.

**Other findings:** TMO's `GET 0x5e` handover config reads **all zeros** (VZW carried 120 s hysteresis + −12/−112/−115/−100/−65/−80) — the part-13 cold-boot race may simply never push thresholds on this carrier; not the gate, but note it. `GET 0x54` on the fresh ICCID read `wifi_call=1 (OFF)`, `pref=1` before our write (⚠️ so pristine ≠ `wifi_call=2` — part 9's "pristine = 2" was VZW-specific); set to `2`/`1` and confirmed. `qpIMSPolicyManager.cpp:1889 GetIMSAllowedServices RAT = 6 ServiceMask = 1287` fires 595× — IWLAN-ish RAT services *are* policy-allowed, reinforcing that the block is the `qpGetPreferredRAT` predicate, not a service-mask denial.

**Next session, in order:**
1. **Ghidra (Hexagon) on `modem.elf`** — locate `QPConfigurationHandler::qpGetPreferredRAT` via the `164805/164806/164807` descriptor run and read the 4-line predicate between :504 and :510. This is the whole lane. Cross-check the answer against `qipcallh_if_wifi_calling_enabled`'s 4th condition — they are very likely the same input.
2. **Pixel control on this same eSIM (Kyle):** does WFC work on a modern AP-assisted stack? Confirms the line/entitlement is good. ⚠️ Interprets narrowly — a Pixel win does **not** prove TMO's ePDG would accept our legacy modem-centric path or this IMEI; it only separates "line has no WFC" from "our stack can't".
3. Capture 2 (the API-override shot, runbook Step 6) is now **lower value** — TMO's `API Override: 1` is already active and the plist already changes, yet `is_wlan_pref` stays 0.

**⭐⭐⭐ ADDENDUM (same session) — PIXEL CONTROL ON THE WARP SIM: Verizon WFC WORKS ON THIS LINE. Part 3's reality check is now OBSOLETE.** Kyle moved the **Warp** SIM (US Mobile × Verizon, 311480 — the daily-driver line) into a Pixel, enabled Wi-Fi calling, completed the E911 address step, and **confirmed working WFC end to end.**

This overturns the single most pessimistic assumption in this lane. Part 3 recorded *"Verizon's WFC entitlement REFUSES this device"* after stock A8 returned "Unable to activate Wi-Fi calling at this time", and concluded there was no working reference and that lane odds had "materially dropped". That refusal was a property of **the device**, not **the line**: the same ICCID provisions and runs WFC fine on modern hardware. Consequences:
- **The "Verizon will say no anyway" cap on this lane is lifted.** The line has WFC entitlement and Verizon's ePDG serves it. If we can flip the modem predicate, end-to-end WFC on the **daily driver** is a real prospect — previously we assumed even a perfect stack would be refused.
- It also re-frames part 15: the TMO run proved the gate is carrier-independent, and this proves the *carrier side* is willing on Warp. Both point the same way — **everything left is inside our modem.**

⚠️ **What it does NOT prove** (keep these honest): the Pixel runs the modern **AP-assisted IWLAN** stack with its own modern IMEI, so this says nothing about whether Verizon's ePDG would accept the **legacy modem-centric** path or a 2017 Palm IMEI. Entitlement on this carrier is plausibly IMEI-conditioned, and stock A8's refusal is direct evidence that *some* device-side check exists. Two mitigations keep it off the critical path for now: (a) we provision the modem's WFC state directly over QMI IMSS v01, bypassing the entitlement app entirely, and (b) we are blocked at `qpGetPreferredRAT` — inside the modem, far upstream of ePDG/entitlement — so an IMEI gate cannot be what we are hitting today. Treat entitlement as a *possible future* gate, not a current one.

**Rig state left behind:** TMO SIM in, WFC provisioned on its ICCID (`wifi_call=2`, `pref=1` — ⚠️ **the "persists in modem EFS" claim is FALSE, corrected by part 17: on 2026-08-06 the same ICCID read back `wifi_call=1 (OFF)`, i.e. exactly its pre-write value, with client-prov/VoLTE/VT bools all 0**); `preferred_network_mode` left at **9** (an improvement — required for TMO registration); IMS debug props unchanged; no `0x5d` writes made, so the all-zero `0x5e` is untouched.

## Amendment 2026-08-06 — ⚠️ the TMO MVNO line has NO WFC voice entitlement; part 15's TMO leg is partly confounded (verdict survives on the Warp leg)

**Pixel airplane-mode test on the US Mobile × T-Mobile line FAILED**: calls refuse with "connect to a network". State in airplane+Wi-Fi (Pixel 9, Wi-Fi 10.0.2.187):
```
IWLAN:  transportType=WLAN  registrationState=HOME  accessNetworkTechnology=IWLAN  mIsIwlanPreferred=true
Voice:  mVoiceRegState = 3 (POWER_OFF)      <-- both subs
```
⇒ the WFC **data** path is real (ePDG tunnel survives airplane mode) but the **MMTEL/voice** service never registers over IWLAN. Settings showing "Wi-Fi calling active/preferred" reflects the *setting + IWLAN transport*, **not** a voice capability.

**⭐ CAUSE FOUND (later same day): the Wi-Fi-calling toggle was simply OFF for this line in the US Mobile app.** Kyle enabled it and entered the E911 address. So this was a plain **carrier-side WFC provisioning gap**, exactly the MVNO risk the part-13 runbook flagged — *not* a device or adapter fault.
- ⚠️ **Not re-tested**: the physical eSIM adapter will no longer re-register in the Pixel (see the logistics note below), so we never confirmed WFC voice coming up after the toggle was flipped. Treat "fixed" as expected-but-unverified.
- An earlier same-session theory that the **eSIM adapter lacked an ISIM** (breaking ePDG EAP-AKA while leaving VoLTE intact) is now the *weaker* explanation and should not be carried forward as fact — the carrier toggle fully accounts for the symptom on its own. It is not disproven, merely unnecessary.

⚠️ **Pixel eSIM logistics (bit us here):** the Pixel manages eSIM profiles natively and in practice tolerates **only one eSIM at a time** — with the physical eSIM-adapter card inserted it hides the internal eSIM lines, and getting the adapter to re-register afterwards is unreliable. Plan SIM-swap experiments around this; the Palm is far more forgiving.
⚠️ **Earlier same-session claim that this was benign VoNR-preference behaviour was WRONG** — the airplane test falsified it. Do not repeat that reading: with VoNR up, "calls stay on cellular" is ambiguous; only the airplane+Wi-Fi call discriminates.

**Impact on part 15 — verdict stands, on a fully validated Warp leg:**
- **Load-bearing**: the **Warp** line passes the **airplane-mode + Wi-Fi call test on the Pixel** (confirmed 2026-08-06) — i.e. WFC voice proven end to end, not just "active" in the UI — and on the Palm with that same SIM the gate still returned `ret - 0`. A demonstrably WFC-capable line hitting our modem's wall is the strong evidence, and it is now a *validated* control rather than an assumed one.
- **Confounded**: the TMO leg is weaker than part 15 stated — that line may never have been WFC-voice-capable at all.
- **Why the confound is limited**: on the Palm we bypass entitlement entirely (QMI IMSS v01 `wifi_call=2` written directly), and `qipcallh_if_wifi_calling_enabled` logged `wfc_status - 2` — the modem *saw* WFC ON regardless of carrier provisioning, so the gate was not reading an entitlement bit. The "not Verizon-specific" claim also stands on its own evidence (OperatorMode 9 vs 0, different MBN, different ANDSF policy shape, identical `ret - 0`).
- ⇒ **When the modem gate is eventually cleared, validate with the Warp SIM, not the TMO MVNO.**

## Session log 2026-08-06 part 16 — Ghidra analysed; IMS msgid mapping proven UNSOLVABLE by affine search; a new data-driven lead on the predicate

**Ghidra is done and is a durable asset.** `modem.elf` imported and fully auto-analysed with `Hexagon:LE:32:default` (Ghidra 12.1.2 + Hexagon extension, ~1 h 45 m, 906 MB project at `<scratch>/mpss/ghidra_proj`). Only the zero-length phdr 21 was skipped. Two headless dump scripts written and run (`<scratch>/mpss/gscripts/`):
- `DumpQsrRefs.java` → `qsrfuncs.txt`: **32,897 functions** with `function_entry | name | call_targets | QSR_constants`.
- `DumpQsrSites.java` → `qsrsites.txt`: **247,192 QSR sites** with `descriptor | address | nearest_call_target | containing_function`. (Ghidra resolves extended constants far better than the raw scan's 106 k.)
⚠️ **PyGhidra**: Ghidra 12 dropped Jython — a `.py` postScript fails with *"Ghidra was not started with PyGhidra"*. Write postScripts in **Java**; Ghidra compiles them on the fly.

🔴 **DEFINITIVE NEGATIVE: the IMS module's msgids do not map to descriptors by ANY affine `base + N × msgid`.** Three independent attacks, each with a working control:
1. **Locality / file-purity scoring** (part 14) — plateaus across ~1000 slots; no resolution.
2. **Structural fingerprint + arg-count signature.** Using Ghidra's real function boundaries and call graph, searched for one function referencing 4 consecutive descriptors (msgids 164805–164808) that *calls* the two helper functions holding 164803/164804, then applied the wrapper-agnostic target-equality pattern implied by arg counts **1,1,3,0,0,1**. Got 23 clean candidates; the best (`D=0xf864ae18`, func `0x87206c5c`, whose `T(D)` is a confirmed **3-arg** wrapper `0x8720b7d4`) implied base `0xf8508ff0` and scored **0.337 vs random-nearby median 0.338**. Falsified. An earlier candidate (`0xf850a608`) was falsified the same way *and* by disassembly — its site was decimal digit-composition code.
3. **Vote-based solving on rare 3-arg messages** — 1786 unexplained 3-arg sites × 2058 IMS-band 3-arg msgids; top base `0xf7fa4db0` scored **0.261 vs random max 0.255**. No peak.
**Controls held throughout**: main module (`base 0xf8000000`, stride 8) reproduces **0.865** arg-count accuracy on 12 k samples every time. The method works; the IMS module is genuinely different.
⇒ **Mechanism**: IMS/QP log sites call **file-local wrappers** (`0x871f5bd8`, `0x87230fc0`, `0x8720b8d0`, `0x872c2418`, `0x87053bfc`, …) that take the descriptor in **r1** plus a second small-int argument (`r1 = #19`, `r2 = #2896`) and do further work before any generic helper. The QSR id for IMS messages is almost certainly computed at runtime from (module, local index) — **no static base can recover it. Do not attempt a fourth time.**
⚠️ Also measured: Ghidra's "nearest call within ±20 bytes" pairing is **noisier** than raw-byte pairing (control 0.601 vs 0.865). For arg-count work use the raw `immext`+`tfrsi` pairing; use Ghidra for boundaries/xrefs/decompilation.

**⭐⭐ NEW LEAD from data already in hand — the caller may never offer IWLAN at all.** `qpGetPreferredRAT` logs its input mask at :504, and across both carriers the observed values are only **`ratMask ∈ {0, 1, 0x400, 0x8000}`** (TMO 78 calls, VZW 32). It returns **10** when it returns anything non-zero, and `GetIMSAllowedServices` is called with **`RAT = 6`** and `RAT = 10` / `RAT = 16`. If the RAT enum places LTE at 10 (bit 0x400 ⇒ consistent with `ratMask 1024 → returning 10`) and IWLAN at 6, then the IWLAN bit would be **`0x40` — a value that never appears in any observed `ratMask`.** ⇒ Hypothesis: the branch at :504→:510 is something like `if (!(ratMask & IWLAN_BIT) || !wfc_ok)`, and we may be failing on the **mask**, not on a WFC condition — i.e. the real culprit could be *the caller that builds `ratMask`*, one level up from where we have been looking. **Test next session:** confirm the RAT enum (`extractGWTOrLRAT` handles G/W/**L**; `extractIWLANRAT` handles IWLAN — decompile both in Ghidra, they are small), then find `qpGetPreferredRAT`'s callers and see what constructs the mask.

**Recommended approach next session (do NOT redo msgid arithmetic):** find `qpGetPreferredRAT` in Ghidra **structurally** — it is a small function that (a) calls two tiny sibling helpers, one of which is never executed at runtime, (b) returns a small enum (0 or 10 observed), and (c) is reachable from IMS policy code. The decompiler plus `qsrfuncs.txt`'s call graph is the right tool; the msgid is a dead end.

## Session log 2026-08-06 part 17 — ⚠️ the carrier-activation confound: every capture in this lane predates WFC activation; rig re-test started but blocked on Enforcing

**The premise correction (Kyle, this session).** None of the SIMs used in parts 9–16 had Wi-Fi calling activated on the carrier side at the time of any capture; he enabled it in the US Mobile app for both lines only on 2026-08-06, after part 15/16 were written. This invalidates the *conclusion* of part 15 (not its observations) — see the corrected header block, item 2. The Warp leg, which the earlier amendment had promoted to "validated control", is confounded for the same reason the TMO leg was: part 3 has stock A8 being refused WFC activation on Warp on 2026-08-04, and the first successful activation was the Pixel run on 08-06.

**Rig state found (Silver `4373dd0f`, TMO SIM `8901240527147049350` still inserted, USB).**
- ⭐ **`GET 0x54` read `wifi_call = 1 (OFF)`, `pref = 1`, and client-prov/VoLTE/VT/presence bools all `0`.** That is byte-identical to what part 15 saw *before* its write ⇒ **part 15's `wifi_call=2` write did not persist**, and its "persists in modem EFS" note is wrong. Recorded as a guardrail.
- ⭐⭐ **Carrier-side activation did not propagate into the modem.** WFC is now on for this line in the US Mobile app, and the modem's store still reads OFF. Expected in hindsight (the phh GSI ships no entitlement/OMA-DM client), but it settles the first half of Kyle's question: **turning WFC on at the carrier does not by itself change the WFC input the gate reads.** The IMSS v01 hand-write stays mandatory.
- `GET 0x5e` handover config all zeros — unchanged from part 15's TMO observation.
- Found unregistered (PS `registrationState=DENIED rejectCause=11`, PLMN-not-allowed) with IMS at `ims_registered=0`, all services NO_SERVICE. An airplane cycle recovered 310260 LTE for ~2 min, then both cellular and Wi-Fi wedged (Wi-Fi HAL reported "enabled" while refusing to scan).

**A reboot fixed the radios and cost us the probes.** Post-reboot the rig is healthy and stable: **310260 LTE HOME**, CS `availableServices=[VOICE,SMS,VIDEO]`, Wi-Fi 10.0.2.106, data validated (ping 8.8.8.8 = 30 ms, APN `Ting Data`/`wireless.dish.com`, 310240). But **all three QMI probes now fail `connect rc=-16`**, and logcat gives the reason outright:
```
avc: denied { create } for comm="imss-probe" scontext=u:r:shell:s0 tcontext=u:r:shell:s0 tclass=socket permissive=0
/sys/fs/selinux/enforce = 1
```
⇒ **`rc=-16` is a SELinux socket-create denial, not client-slot contention** (unlike `nas-probe`'s `rc=-17`). Parts 9–16 were only able to probe because an earlier session had left the rig Permissive; the reboot restored Enforcing. `setprop ctl.stop imsdatadaemon` is likewise refused under Enforcing.

⭐ **The Enforcing block dissolved: probes work fine as `u:r:su:s0`.** Kyle re-enabled root (the reboot had dropped it to plain `shell`); with a real root context the AVC never fires and **no `setenforce 0` is needed**. The earlier `rc=-16` was `u:r:shell:s0` specifically. Record this — it is the difference between "rig is bricked for probe work" and "rig is fine".

### Experiment 1 — rig / TMO line, instrumented (F3)

Provisioned `0x53 0x14=2` + `0x15=1` → read back `wifi_call=2 (ON)`, `pref=1 (WLAN_PREFERRED)`; IMS **REGISTERED** (IMPU `sip:14254035265@msg.pc.t-mobile.com`, SMS/VoIP/VT/UT all FULL_SERVICE). Two captures (`cap-p17a` steady-state, `cap-p17b` across an airplane cycle), decoded with the rig's own `aa70ba0d` QDB and the wide filter.

- ⭐ **The gate is event-driven, not periodic.** In steady state `qpIMSPolicyManager.cpp` only emits lines **312 / 1889 / 1738**; `:504` never fires. It takes a registration/RAT-selection event to invoke it — worth knowing before anyone burns another idle capture.
- 🔴 **Result: 32 invocations, 100 % WFC-OFF branch, on a carrier-activated line.**
```
qpIMSPolicyManager.cpp:504  qpGetPreferredRAT ratMask 1024 WFC 2 CallmodePreference 1
qpIMSPolicyManager.cpp:510  qpGetPreferredRAT WFC OFF Extracting G,W,L Rat
qpIMSPolicyManager.cpp:474  extractGWTOrLRAT ratVal 10
qpIMSPolicyManager.cpp:570  qpGetPreferredRAT returning 10
```
  `ratMask` observed only as **1024 and 1** — still no IWLAN bit. Identical to parts 15/16.
- ⭐⭐ **RAT encoding CONFIRMED from live data (part 16's inference was right):** `ratMask 1024 → ratVal 10 → returning 10` and `ratMask 1 → ratVal 0 → returning 0` ⇒ **bit *n* ↔ RAT *n***, so LTE=10↔`0x400`, and **IWLAN=6 would be `0x40` — a bit that has never appeared in any observed mask.**
- ⚠️ **Validity caveat on THIS capture: Wi-Fi was down.** The airplane cycle killed wlan0 and it never came back, so an absent IWLAN bit here is not conclusive on its own. (Mitigated by experiment 2, and by parts 13/15 which observed the same masks *with* Wi-Fi up at 10.0.2.106 — just on unactivated lines.)

### Experiment 2 — DUT / Warp line, end-to-end (the strongest available line)

DUT `c39a6acf`: Warp **311480 LTE**, **Wi-Fi UP (10.0.2.157)**, root, Enforcing. ⚠️ DUT probes need `LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so` (the binaries carry no DT_NEEDED shim; without it `rc=-3`).

- **Warp's modem store is fully provisioned** — `client_prov=1`, `volte=1`, `wifi_call=2 (ON)`, `pref=1 (WLAN_PREFERRED)` — unlike the rig's TMO ICCID (all bools 0). IMS **REGISTERED**, SMS/VoIP FULL_SERVICE.
- 🔴 **And still nothing.** `voip_service_rat=1` (cellular), **`ip xfrm state`/`policy` both EMPTY** (no ePDG tunnel), no `rev_rmnet`/`r_rmnet` interfaces, `mIsIwlanPreferred=false`, WLAN `NetworkRegistrationInfo` = `UNKNOWN`.

**⇒ This is the exact configuration the carrier-activation hypothesis predicts should work:** a Pixel-verified WFC-capable line, carrier-side activation done, modem reading WFC ON + WLAN_PREFERRED, client-provisioning and VoLTE bits set, IMS registered, Wi-Fi up. The modem still never initiates. **The hypothesis is substantially weakened — but not yet killed**, because the one cell never observed is *ratMask on an activated line with Wi-Fi simultaneously up* (the DUT has no working DIAG; the rig's Wi-Fi died).

### Experiment 3 — ⭐⭐⭐ THE DECISIVE ONE: Warp in the rig, activated, Wi-Fi up (`cap-p17c`)

Kyle swapped the SIMs (Warp → rig `4373dd0f`, TMO → DUT). Every variable satisfied simultaneously for the first time in this lane: **Warp** (carrier-activated *and* Pixel-verified by an airplane-mode Wi-Fi call), `wifi_call=2`/`pref=1` written and verified, `client_prov=1`, `volte=1`, **IMS REGISTERED**, **Wi-Fi UP at 10.0.2.106 confirmed before, during and after**, VZW CDMAless MBN live (`EPDG_FQDN set with length 12`). Modem restart confirmed via `Request count 1 → 2`.

```
:504 qpGetPreferredRAT entry   35     :510 WFC OFF branch   35/35
:524 WFC ON branch              0     :449 extractIWLANRAT   0
ratMask:  1 (×22) · 1024 (×8) · 32768 (×4)      — 0x40 never present
qipcallh_if_wifi_calling_enabled: wfc_status - 2 → ret - 0   (×80)
ds_iwlan_s2b_profile_is_wlan_pref: IWLAN? 0  (apn len 3 ×70, len 11 ×56)
DplHandOverSetCNEProfileForMetrics: 0 calls   ·   req_wqe_prof_mask complaints: 0
```

⇒ **Identical to every unactivated capture. The carrier-activation hypothesis is FALSIFIED and the confound is closed.** Part 15's verdict is restored on evidence that actually supports it. Three inputs are now excluded by experiment as the cause of the WFC-OFF branch: **carrier entitlement/activation, Wi-Fi availability, and the WFC provisioning store.** What remains is the `ratMask` construction — the caller, one level up.

⭐ **Bonus finding: the modem restart did NOT wipe the WFC store** (`wifi_call=2` before and after, logged in `part17-WARP-capture-conditions.log`). So whatever cleared part 15's TMO write, it was not a modem restart — still unexplained, and the "always re-verify `get 0x54` before capturing" guardrail stands.

**Evidence banked:** `part17-WARP-activated-wifiup-gate.txt`, `part17-WARP-activated-wifiup-full.txt`, `part17-WARP-capture-conditions.log`.

### Rig incidents worth remembering
- ⚠️ **Never `stop`/`start` the framework on this GSI to fix Wi-Fi** — it killed `system_server` outright (0 procs, 23 services, `cmd wifi` → "Can't find service: wifi"). It self-recovered after several minutes, but a reboot is the correct tool.
- ⚠️ **An airplane cycle wedges Wi-Fi on this rig (2/2)** and it does not come back via `svc wifi` toggling. **A modem restart does NOT touch Wi-Fi** (separate WCNSS subsystem) — use `ctl.stop per_mgr` → `ctl.restart per_proxy` → `ctl.start per_mgr` as the re-registration trigger whenever Wi-Fi must stay up. This is the pattern to use for any future WFC capture.
- 🔴 **Black screen after reboot = SystemUI crash-loop, not a display fault.** Cause: runtime permissions reset, so SystemUI died inflating `super_notification_shade` (`needs permission android.permission.READ_CONTACTS to read lock_screen_owner_info_enabled`); `com.android.bluetooth` crash-looped on the same. **Fix without a flash: `pm grant com.android.systemui android.permission.READ_CONTACTS` (+ same for `com.android.bluetooth`), then `am force-stop com.android.systemui`.** UI came straight back.
- ⭐ **`adb root` refused ("disabled by system setting") is recoverable from the shell**: `setprop service.adb.root 1` — root (`u:r:su:s0`) was available immediately after, without touching Developer options. Useful because the Settings UI is unreachable when SystemUI is down.
- ⭐ **The gate is event-driven**: in steady state `qpIMSPolicyManager.cpp` emits only lines 312/1889/1738 and `:504` never fires. A capture without a registration/RAT-selection event is wasted.
- ⚠️ `adb pull <dir>/` silently produced nothing; pull the `.qmdl` by explicit filename.

**Device state left behind:**
- **Rig `4373dd0f`:** healthy — **Warp** 311480 LTE, IMS REGISTERED, Wi-Fi 10.0.2.106, SystemUI restored, root on. Modem EFS carries `wifi_call=2`/`pref=1` for the Warp ICCID (desired). Captures in `/data/local/tmp/cap-p17{a,b,c}`.
- **DUT `c39a6acf`:** healthy, TMO SIM (310260 LTE). Read-only this session; no writes.

## Session log 2026-08-06 part 18 — ⭐⭐⭐ OFFLINE, from captures already on disk: the modem believes the **Wi-Fi radio switch is OFF**, and there is an unsent DSD message that sets it

No device work. Pure re-decode + QDB/IDL reading of `part17-WARP-activated-wifiup-full.txt` — the "re-decode before re-capture" guardrail paying out for the second time in this lane.

**⭐⭐⭐ The finding, in one line: `PDPManager.cpp:541 qpDcmGetWIFISetting bIsWIFISetting[0]` — and `PDPManager.cpp:878 HandleWifiRadioChange` NEVER fires in any capture.** The modem's IMS layer holds a Wi-Fi *radio-switch* boolean, it initialises to **0 (off)**, and nothing ever changes it. This is a **distinct input** from every lever this lane has pulled: it is not `wfc_status` (IMSS `0x53 0x14`, verified ON), not WLAN-*available* (DSD `0x20`, verified accepted), not the WLAN preference (DSD `0x22`), not the per-APN preferred system (DSD `0x29`).

**The plumbing, all from the QDB:**
- The flag is the ps_sys conf item **`PS_SYS_CONF_DATA_SERVICE_WIFI_SETTING`**, read via `qpDcm.c:12432 qpDcmGetWIFISetting - Boolean Flag %d` (`ds_sys_conf_get_ex`).
- Its change event is **`PS_SYS_EVENT_WIFI_SETTINGS_CHANGE`** / `qpDcm.c:12698 DS_SYS_EVENT_WIFI_SETTINGS_CHANGE sent`. **Three consumers register for it, and all three are modules this lane is blocked in:**
  - `ds_iwlan_s2b_iface_hdlr.c:1385-1468 ds_iwlan_s2b_wifi_settings_change_cb` — the IWLAN module itself.
  - `ds_mppm.c:2916/4258 ds_mppm_ps_wifi_settings_change_cback` — the policy manager (`ds_mppm` also registers for WLAN_PREFERENCE_CHANGE, part 11).
  - `qipcalliface.c:788-821 qipcalliface_dcm_cb: DCM_MSG_WIFI_SETTINGS_CHANGE_EV — qpdcm_wifiradiostate: %d, bIsWIFISetting: %d` — ⭐ **qipcall's own WFC path consumes it, which makes it the leading candidate for `qipcallh_if_wifi_calling_enabled`'s silent 4th condition.**

**⭐⭐ The unsent lever: DSD msg `0x34` (SET) / `0x35` (GET), TLV `0x13` = wifi switch.** `ds_qmi_dsd.c` has four consecutive handler logs — `:4645 data setting`, `:4661 data roaming`, `:4677 rat preference`, **`:4698 wifi switch`** — each `Client 0x%p … %d ps_res %d` (i.e. each writes a ps_sys conf item). The DSD IDL (`parse_idl_any.py libqmiservices.so 0x25508 0x34 0x35`) gives msg `0x34` REQ = four *optional* TLVs `0x10 u8`, `0x11 u8`, `0x12 u32`, `0x13 u8`, and msg `0x35` = the empty-REQ GET returning the same four. **The type sequence (bool, bool, enum, bool) maps 1:1 onto the handler sequence ⇒ `0x34 TLV 0x13 (u8) = wifi switch`, `0x35` reads it back.** Both are inside the implemented `≤0x47` range, so the modem answers them — part 5's sweep marked them present and nobody looked at what they were.

**Why this fits every observation better than anything left on the list:**
- Explains "DSD `0x20` accepted but inert" precisely: `WLAN_AVAILABLE` reports a *connection*; the wifi *switch* is the radio-state setting, a different ps_sys item with different consumers. We have been reporting the link and never the switch.
- Explains why the gate is carrier-independent (part 17): a radio-state boolean is not carrier state.
- Explains `ratMask` never carrying `0x40` without needing RE: with the switch off, IWLAN is never a candidate RAT.
- ⭐ **`EventChangeRat - ServiceOnRatMask = 0x644e, new RAT mask = 0x400`** (`PDPManager.cpp:1094`) — `0x644e` has **bit 6 SET**, i.e. the modem's *configured/allowed* RAT set DOES include IWLAN; only the *live* mask (`1`/`1024`/`32768`) never does. The capability is there; the availability input is missing. (Corroborated by `GetIMSAllowedServices RAT = 6` firing 595×.)

**⭐ Also learned offline — the whole WLAN-arbitration half of `qpIMSPolicyManager.cpp` is dead code at runtime.** Lines that NEVER fire in any capture: `CheckWifiPrefSettings` (:1189/:1246, reads `iWFCStatus`/`iCallModePreference`/`m_bUESIMGBAEnabled` and returns a RAT), `CheckWWANandWLAN` (:1289-1459), `CheckIMSServiceToOffLoadOnWLAN` (:1497-1710), `GetRegAPNTYPE` (:1011). `qpGetConfiguration` (:312) is a dispatcher keyed by `QP_PM_REQUEST_ID`, and across 2118 calls only IDs **5** (→ `GetIMSAllowedServices`, 1059) and **11** (1048) are ever asked, plus one-offs 3/9/22/12/1. ⇒ The caller never even poses the WLAN questions.

**Also mapped: the `ratMask` pipeline in PDPManager, and where it is already wrong.** `HandleRatNotification (:1017, rat Mask 1 / 1024 / 32768)` → `GetUpdatedWifiPreferences (:1979/:2019)` → `ConsiderCMRatBasedonDomain (:2214/:2218)` → `GetUpdatedRatMaskBasedonMeasurement (:2126 incoming → :2171 outgoing, unchanged)` → `qpGetPreferredRAT (:504)`. **The mask is already IWLAN-free on arrival at `:1017`**, so nothing inside PDPManager drops it — it is never offered. Note `GetUpdatedRatMaskBasedOnPDNThrottling (:2239 "ratmask after pdn throttle/iwlan backoff")` and `GetUpdatedRatMaskBasedOnWLANWWANHysetrisis (:2267/:2287)` never run at all.

### Part 18b — TESTED LIVE THE SAME DAY on rig `4373dd0f` (Warp, 311480 LTE, IMS REGISTERED, Wi-Fi 10.0.2.106). ✅ Mechanism CONFIRMED · 🔴 hypothesis FALSIFIED as the gate.

Four captures, `cap-p18a`–`cap-p18d`. **Verdict up front: the Wi-Fi radio switch is exactly what part 18a said it was — a real, previously-unset, now fully controllable IMS input — and flipping it ON changes nothing at the gate.**

**✅ CONFIRMED — `DSD 0x34 TLV 0x13` (u8) IS the wifi switch, `0x35` reads it back.** Not inference any more; the modem logged its own handler:
```
ds_qmi_dsd.c:4698   Client 0x… wifi switch … ps_res …
```
`get 0x35` on **both** devices read `0x10=1 (data setting) · 0x11=0 (data roaming) · 0x12=1 (rat pref) · 0x13=0 (wifi switch)` — the first three match reality on both units (data on, not roaming), which independently validates the field mapping. Writes return `result=0` and stick.

**✅ CONFIRMED — the full propagation chain, end to end, first time in this lane:**
```
dsd-probe raw 0x34 0x13:1:1
  → ds_qmi_dsd.c:4698                      (QMI handler)
  → ds_mppm_cmd_hdlr.c:9992  Old wifi_settings 0 new wifi_settings 1 subs id = 1
  → ds_iwlan_s2b_iface_hdlr.c:1391/1397    (IWLAN module sees it)
  → qpDcm.c:12698  DS_SYS_EVENT_WIFI_SETTINGS_CHANGE sent
  → PDPManager.cpp:878  HandleWifiRadioChange Current WifiSwitch 0  incoming wifiSwitch 1
```
`qpDcm.c:2541 QpDcmRegisterForDSSys | SUCCESS registering WIFI Common SYS Events with DS` also fires at IMS init, so IMS **is** subscribed — it simply never had anything to receive. **`PDPManager.cpp:878` had never once appeared in this lane before today.**

**⭐ The switch RESETS TO 0 on every modem restart.** Measured directly: `pre 0x35 → 0x13 = 1`, `ctl.stop per_mgr` / `ctl.restart per_proxy` / `ctl.start per_mgr` (Request count 2→3), `boot 0x35 → 0x13 = 0`, and `PDPManager.cpp:541 qpDcmGetWIFISetting bIsWIFISetting[0]` at Init. That is the whole explanation for part 18a's observation — it is not that nothing ever sets it, it is that **nothing on our AP re-asserts it after modem boot** (stock's resident CnE/datad conversation is what would).

**⚠️ Note on part 18a's framing:** the ps_sys item was *already* `1` in `ds_mppm` when first probed mid-session (`WIFI settings change 1 same as MPPM WIFI settings previously stored 1`), so "the modem believes Wi-Fi is off" was only true of the **IMS-side cached copy** read at `PDPManager` Init, not of the data-services layer. A no-change write is silently absorbed — **force a real transition (`0x13=0`, then `0x13=1`) or nothing propagates to IMS.**

**🔴 FALSIFIED as the gate (`cap-p18d`, the decisive one).** Sequence: force `0x13` 1→0→1 (both `HandleWifiRadioChange` transitions logged, IMS ends holding `WifiSwitch = 1`), send a full correctly-formed `0x20 WLAN_AVAILABLE`, then drive RAT re-selection by re-pushing WFC provisioning. Result — **three gate evaluations after the switch was ON**, two of them at `CallmodePreference 1`:
```
:504 qpGetPreferredRAT ratMask 1024 WFC 2 CallmodePreference 1     (×2 post-switch-ON)
:504 qpGetPreferredRAT ratMask 1024 WFC 2 CallmodePreference 3     (×1)
:524 WFC ON branch  0   ·  :449 extractIWLANRAT  0
qipcallh.c:45832  ret - 0  ×49
```
`ratMask` never leaves `1024`. **`0x40` still never appears.** ⇒ The Wi-Fi radio switch is **not** the input the WFC-OFF branch keys on, and it is not what keeps IWLAN out of the mask.

**⭐⭐ But it is not inert either — it is the first thing that has ever provoked IMS about IWLAN.** Immediately after `HandleWifiRadioChange`, IMS ran a burst of policy re-queries: `qpGetConfiguration QP_PM_REQUEST_ID 11` / `5` → **`GetIMSAllowedServices RAT = 6 ServiceMask = 5 by Device = 33039`** repeated. RAT 6 = IWLAN. So the switch does reach IMS policy and IMS does evaluate IWLAN services on it — the decision just never reaches `qpGetPreferredRAT`.

**⭐ Bonus exclusion, free from the same capture: `CallmodePreference` IS the IMSS `0x53 TLV 0x15` WFC preference, and both its values take the WFC-OFF branch.** Writing `0x15=3` made `:504` log `CallmodePreference 3`; writing `0x15=1` made it log `1`. Both → WFC-OFF. That input is now excluded by experiment too.

**Where this leaves the lane.** Inputs to the WFC-OFF branch now excluded *by direct experiment*: carrier entitlement/activation, Wi-Fi availability (DSD 0x20), the WFC provisioning store (`wfc_status`), the WFC preference (`CallmodePreference`), and now the Wi-Fi radio switch. The branch reads `ratMask`, `WFC` and `CallmodePreference` — we have driven the latter two across their ranges with no effect, which leaves **`ratMask`, and it is built upstream of PDPManager entirely** (already IWLAN-free at `HandleRatNotification :1017`). Next question is therefore unchanged and now much better isolated: **who supplies the RAT mask to `HandleRatNotification`, and what would ever make it include bit 6?** That notification comes from CM/DS, not from IMS — so the next capture should widen the filter to the CM/mode-controller side (`cmph.c`, `ds_mppm*`, `ds_3gpp*`) around a `:1017` event rather than staying inside IMS.

**Evidence banked:** `diag-tools/captures/a11-rig-wfc-f3-20260805/part18-wifiswitch-chain.txt`, `part18-gate-after-switch-on.txt`, `part18-capture-conditions.log`; raw `.qmdl`s still on the rig in `/data/local/tmp/cap-p18{a,b,c,d}`.

**Rig state left behind:** reverted — `0x13` back to `0`, `WLAN_NOT_AVAILABLE` sent, WFC store verified `wifi_call=2`/`pref=1`. Health re-checked: **311480 LTE, `mDataConnectionState=2`, IMS REGISTERED, SMS FULL_SERVICE, Wi-Fi 10.0.2.106 routing fine.** Captures in `/data/local/tmp/cap-p18{a,b,c,d}`.

**⚠️ Tooling gotcha that cost time — the rig `.qdb` needs TWO fixes before `decode_f3.py` will read it.** (1) It is zlib-compressed from `0x40`, and the stream ends with a **bad adler32** — plain `zlib.decompress` raises and throws away all 23 MB; decompress in chunks and tolerate the final error. (2) The decompressed text has **records that run together without a newline**, so the line-based parser merges entries and every `file:line` lookup silently returns the wrong record. Re-insert separators — and note the ⚠️ **digit-safe lookbehind, which the first attempt got wrong**:
```python
re.sub(rb'(?<!\n)(?<![0-9])(\d{4,7}:\d+:\d+:\d+:[A-Za-z0-9_./-]+\.(?:c|cpp|h|cc):)', rb'\n\1', blob)
```
Without `(?<![0-9])` the split lands **inside the msgid** (`483651` → `4` + `83651`), which does not just lose records — it **silently mis-attributes frames to the wrong message**. That produced one entirely fictitious finding in this session (see 18c). **Verify after repairing**: `grep -E ':45812:qipcallh\.c:'` must show msgid `174223` (the part-14 anchor, stable across both QDBs). Correct repair yields ~252k records; the buggy one yields ~356k. **Symptoms of an unrepaired DB: `file.c:` with an empty line number, or a format string with another record's text glued to its tail.**

### Part 18c — `ratMask`'s origin traced to the end, and ⭐⭐⭐ the loop turns out to be CIRCULAR (all offline, from `cap-p18c`)

Same boot capture, re-decoded with a **repaired** QDB and a CM/DS filter. All of part 18b re-verified unchanged against the corrected DB before anything new was concluded.

**🔴 CORRECTION FIRST — one finding from the buggy-QDB pass was fictitious.** A mid-session decode appeared to show `ds_mppm_cmd_hdlr.c:2924 "Blocking IWLAN globally for subs_id = 1"` firing. **It does not fire — 0 occurrences with the corrected DB, and a raw msgid scan finds no such frame.** It was a mis-attribution caused by the digit-splitting bug above. `ds_mppm_update_wifi_and_iwlan_availability` runs normally and **never takes its global-block branch.** Recorded because it is exactly the kind of false positive that would have burned a session.

**The `ratMask` provenance chain, now complete:**
```
CM serving-system event  ("CM#>>#DPL_M#0#qpDplSendRatInfoEvent")
  → qpDcm.c:5145 qpDplProcessRatInfoEvent: Received SS Event 0x… from CM
  → GetMappingDCMRAT (sys_mode → DCM RAT)
  → PDPManager.cpp:594  GenericDcmCallback : event type 4
  → PDPManager.cpp:1017 HandleRatNotification - rat Mask {1 | 1024 | 32768}
  → … → qpIMSPolicyManager.cpp:504 qpGetPreferredRAT
```
⇒ **The mask is CM's serving-system view.** CM only reports WWAN systems, so IWLAN can only ever enter it if something first declares a WLAN *service*.

**⭐⭐ `ds_mppm_update_wifi_and_iwlan_availability` is the IWLAN-availability evaluator, it runs 12–13× per boot, and every readiness input it checks is GOOD.** Args recovered by raw-frame extraction (uniform 1-byte packing, or 2-byte in the wide variant):
```
:2877  subs_id 1 · dsd_mask_before 0x0 → 0x1000 · WLAN Offload NV Status 2 (enabled) · WLAN srv_status 0
:2887  Subscription Ready 1 · WLAN Idi Type 1 · is_impi_imsi_ready 1 · rat_pref 0
:2943  dsd_mask_after 0x0 / 0x1000      (0x1000 = the LTE system's so_mask; never an IWLAN bit)
:2924  "Blocking IWLAN globally"  — NEVER TAKEN
```
So MPPM is **willing**: subscription ready, IMPI/IMSI ready (⇒ the old "eSIM adapter has no ISIM" worry is dead from the modem's own logs), WLAN offload NV enabled (=2, matching the MBN), no global block. **Exactly one input fails: `WLAN srv_status = 0`.**

**⭐⭐ And nothing in the modem ever produces a WLAN service change.** IMS's own view, straight from the DCM callback:
```
qipcalliface.c:2552  qipcalliface_dcm_cb: WLAN RAT 17 <ratMask> 64
qipcalliface.c:4184  handle_srv_status_event: WWAN service = 2, WLAN service = 17
qipcalliface.c:4257  IWLAN Srv status changed: from 17 to 17
```
`17` = WLAN no-service, and it never changes *from* 17. In this boot capture the two callbacks that would move it — `ds3gdsdif.c:3871 ds3gdsdif_wlan_srv_chg_cb` and `ds_wlan_meas_conn_status.c:124 ds_wlan_meas_wlan_srv_chg_cb` — fire **zero times**, because nothing on the AP reported WLAN during it.

⚠️ **Amended by `cap-p18e` (below): we CAN make those callbacks fire — and it still changes nothing.** So the accurate statement is not "the event never happens" but the stronger one: **the event is delivered to every consumer and discarded by all of them.**

**⭐⭐⭐ Which closes the loop — and it is genuinely circular, exactly as part 13 step 2 predicted:**
```
WLAN srv_status 17/0
  → MPPM dsd_mask carries no IWLAN
  → CM ratMask never has bit 6 (0x40)
  → qpGetPreferredRAT takes WFC-OFF        (:504 → :510)
  → qipcallh_if_wifi_calling_enabled ret 0
  → qipcall never makes IWLAN a target RAT (TRAT MASK 0x00)
  → DplHandOverSetCNEProfileForMetrics never called → req_wqe_prof_mask 0
  → ANDSF discards every wlan_srv_chg, never measures Wi-Fi
  → VZW MAPCON "WiFiAvailable" never evaluable → is_wlan_pref 0
  → ds_iwlan_s2b rejects profile 1 → no ePDG tunnel
  → ...no WLAN service.  ⟲
```
Every AP-side lever we have exercised (DSD `0x20` WLAN_AVAILABLE, `0x22`, `0x29`, `0x34` wifi switch, IMSS `0x53`/`0x5d`) feeds a node **inside** this ring, which is why each one is "accepted and inert". **This is not a missing message; it is a fixed point.**

**⇒ The only documented entry point OUTSIDE the ring is the ANDSF policy**, because `is_wlan_pref` is answered from MBN-provisioned policy rather than from measurements — so forcing it does not require Wi-Fi service to already exist. That is **part 11 step 3 / part 13 step 2: a DIAG EFS write of a forced-WLAN `ims` policy (`AccessTechnology 3`, priority 1, unconditional) on the rig, still never attempted.** It is now not just "the cleanest test" but the only identified way to break the cycle from our side. Prerequisite (from part 12): modem EFS is encrypted on disk, so this needs a real **DIAG EFS2 client** — building one is the concrete next task.

### Part 18d — `cap-p18e`: everything asserted together, through a full registration. Gap closed; the ring is confirmed from the inside.

The last untested combination: **wifi switch ON *and* a correct full WLAN report, asserted from before SIM-LOADED and re-asserted every 3 s straight through registration**, across a real modem restart (Request count 3→4). Warp, 311480 LTE, IMS REGISTERED, Wi-Fi up throughout.

**⭐⭐ NEW CAPABILITY — the WLAN service-change event now fires, for the first time in this lane.** `ds3gdsdif.c:3871` ×11 and `ds_wlan_meas_conn_status.c:124` ×11, both `tech:2, evnt:1005` (tech 2 = WLAN). So part 18c's "these fire zero times" was an artifact of a capture with **no AP-side WLAN report in it** — corrected above. A repeated, correctly-formed DSD `0x20` with the switch ON does generate genuine `wlan_srv_chg` events inside the modem.

**🔴 And all three consumers discard it, in the same millisecond:**
```
[..353e7281c09] ds3gdsdif.c:3871                ds3gdsdif_wlan_srv_chg_cb:        tech:2, evnt:1005
[..353e7281c09] ds_wlan_meas_conn_status.c:124  ds_wlan_meas_wlan_srv_chg_cb:     tech:2, evnt:1005
[..353e7281c09] ds_andsf_wqe_prof_mgr.c:429     ds_andsf_wqe_prof_mgr_wlan_srv_chg_cb: tech:2, evnt:1005
[..353e7281c09] ds_andsf_wqe_prof_mgr.c:448     ignore wlan_srv_chg, since req_wqe_prof_mask is 0
```
ANDSF says why out loud; the other two simply produce no state change. Downstream, everything is unmoved: **`WLAN srv_status = 0` on all 13 MPPM evaluations** (`dsd_mask_before 0x0/0x1000`, `WLAN Offload NV 2`, global-block branch still never taken), `qipcalliface dcm_cb: WLAN RAT 17` and `IWLAN Srv status changed: from 17 to 17` throughout, **33 gate evaluations with `ratMask ∈ {1, 1024, 32768}`**, `:524 WFC ON` = 0, no xfrm, no tunnel.

⚠️ Also measured: `PDPManager.cpp:541` still reads `bIsWIFISetting[0]` at Init even though we began asserting the switch within ~20 s of the restart — **IMS reads it too early for any AP-side race to win.** Re-asserting after Init works (`:878` fired) but, as part 18b showed, changes nothing.

**⇒ This closes the last "did we test them together" gap.** Every input the ring exposes to the AP has now been driven simultaneously, at the right time, through a real registration. **The event reaches every consumer and each one drops it because a *downstream* part of the same ring is still zero.** That is the definition of a fixed point, and it removes the last reason to keep probing from the AP side.

**⇒ Next task, unchanged and now unavoidable: a DIAG EFS2 client**, to write a forced-WLAN `ims` ANDSF policy (`AccessTechnology 3`, priority 1, unconditional) — the only identified node that is answered from MBN policy rather than from a ring member. Feasibility notes gathered this session: `/dev/diag` is live on the rig, and the userspace write path is `write(fd, "\x20\x00\x00\x00" + diag_payload)` (`0x20` = USER_SPACE_DATA_TYPE, seen in the `diag_mdlog` strace in `HOWTO-modem-diag-capture.md`). EFS2 rides DIAG subsystem command `0x4B` / subsys `0x13`. **Open question to settle first: response routing while `diag_mdlog` holds the memory-device mode** — the DCI interface (`DIAG_IOCTL_DCI_REG`) is the channel designed for userspace request/response and is the likely route. No EFS2 client exists in the tree today (checked).

### Part 18e — the forced-WLAN policy patch, fully specified from the MBN XML (offline, no device)

With the AP side closed, the payload for the EFS write can be pinned down exactly. The VZW `cdmaless` MBN's `/data/andsf.xml` ("ims Policy", 330 lines, extracted at `diag-tools/mcfg-lane/andsf/vzw-cdmaless-andsf.xml`) carries **seven `ims` rules**:

| # | block | ThresholdConditions | CallType | RoutingRule order | RulePriority |
|---|---|---|---|---|---|
| 1 | | WiFiRSSI/SINR | 02 | **WLAN(3) first** | 1 |
| 2 | | WiFiAvailable **0** | 02 | cellular(1) first | 2 |
| 3 | | LTE thresholds | 02 | cellular first | 1 |
| 4 | | WiFiRSSIHigh −85 / SINRHigh 29 | 04, 06 | **WLAN first** | 1 |
| 5 | | WiFiAvailable **0** | 04, 06 | cellular first | 1 |
| **6** | **MAPCON_6** | **`<WiFiThreshold><WiFiAvailable>1</WiFiAvailable>`** | **00 (idle)** | **WLAN first** | **1** |
| 7 | | `<LTEThreshold><LTEAvailable>1</LTEAvailable>` | 00 (idle) | cellular first | 2 |

⭐⭐ **Rules 6 and 7 are a symmetric pair and they decide the idle case — which is the one that matters for registration.** MAPCON_6 would make the `ims` APN WLAN-preferred and it outranks rule 7 (`RulePriority` 1 vs 2) — but its only condition, `WiFiAvailable = 1`, is precisely the fact the ring can never produce. Rule 7's condition, `LTEAvailable = 1`, is true today. So rule 7 wins every time → `is_wlan_pref 0`. **The XML makes the circularity visible as data.**

⇒ **Minimal forced-policy patch: in MAPCON_6, swap its condition for its sibling's** —
```diff
-                  <WiFiThreshold>
-                    <WiFiAvailable>1</WiFiAvailable>
-                  </WiFiThreshold>
+                  <LTEThreshold>
+                    <LTEAvailable>1</LTEAvailable>
+                  </LTEThreshold>
```
One element, **−4 bytes**, exactly one occurrence in the file. Why this shape rather than deleting the gate:
- It uses **only tags already present and demonstrably parsed in this same file** (rule 7 uses this exact block), so no schema guesswork — whereas an empty or absent `<ThresholdConditions>` is untested and could fail the parse (`Failed to decode andsf file`, a string we have never seen and do not want to).
- It keeps `CallType 00`, `IsAPIOverride 1` and `RulePriority 1` untouched, so only the condition changes.
- The condition it adopts is **known-true on our device right now** (we are camped on LTE), so MAPCON_6 becomes effectively unconditional at idle and wins over rule 7 on priority.
- It is a near-null-length edit, which matters if EFS2 writes turn out to be easier in place than as a resize.

**Artifact ready:** `diag-tools/mcfg-lane/andsf/vzw-cdmaless-andsf-FORCEDWLAN.xml` (generated + verified this session; diff against `vzw-cdmaless-andsf.xml` is the four lines above and nothing else).

**Expected outcome if written to the rig's EFS `/data/andsf.xml` and the modem restarted** — watch in this order: `ds_andsf_rule_manager.cpp:298 Priority list change bitmask` non-zero → `ds_iwlan_s2b_profile.c:1165 is_wlan_pref: IWLAN? 1` → `rt_acl_is_cfg_supported` accepting profile 1 → ePDG DNS/IKE activity (`epdg_addr_reslvr_*`) → `ip xfrm state` populating. ⚠️ Any of these appearing would be the first movement in this lane since the modem work began.

⚠️ **Not yet actionable — gated on two things.** (1) A DIAG EFS2 client that can *write* (the one being built now is deliberately **read-only**; writing is a separate, riskier decision). (2) **Read the live EFS copy first** — everything above is derived from the MBN's *source* XML, and the file the rule manager actually parses is whatever the MBN materialised into EFS. Confirm they match before patching. Snapshot the original bytes before any write; do it on the **rig**, never the daily driver.

### Part 18f — ⭐⭐⭐ DIAG EFS2 CLIENT BUILT AND WORKING (read-only). Live modem EFS is readable at last.

New tool: **`diag-tools/efs2-probe/`** (`efs2-probe.c` + `build.sh`, house style, full wire-format header comment). Commands: `hello | ls <p> | cat <p> | hexcat <p> | stat <p> | raw <hex> | plaintest`, `-v` for hexdumps. On device at `/data/local/tmp/efs2-probe`. Captures: `diag-tools/captures/efs2-4373dd0f/`.

**⭐⭐ The channel is DCI, not plain `/dev/diag` — and the plain path is structurally dead on this rig.** Measured (`efs2-probe plaintest`): writing `USER_SPACE_DATA_TYPE (0x20)` or `USER_SPACE_RAW_DATA_TYPE (0x80)` both return **`-1 EIO`**. Cause: `diagchar_write()`'s *first* gate drops every non-DCI pkt_type with `-EIO` while `logging_mode == DIAG_USB_MODE && !driver->usb_connected` — and the diag USB function is not in this rig's USB composition (adb does not count). ⚠️ **This supersedes the `write(fd, "\x20\x00\x00\x00" + payload)` recipe inferred from the `diag_mdlog` strace in `HOWTO-modem-diag-capture.md`: that write path cannot be reached here at all.** The working sequence is `DIAG_IOCTL_DCI_REG (23)` → `client_id`, then `write(fd, LE32(0x40) | LE32(uid) | LE32(client_id) | raw_request)` — **no HDLC framing and no CRC; the kernel does both.**

**Milestone-1 proof — `DIAG_VERNO_F` (request = the single byte `00`) returned the live modem's build:** `Nov 27 2019 14:39:49` / rel `Jul 25 2019 07:00:00` / station `8940.gen`. (It is genuinely the modem, not an apps-processor local answer: `diag_dci_process_apps_pkt` only answers `DIAG_CMD_VERSION` locally when `chk_polling_response()` says no peripheral is registered, which is false with MPSS up.)

**⭐⭐⭐ The gate from part 18e is CLEARED — the live EFS policy matches the MBN source.** `/data/andsf.xml` read off the modem is **11623 bytes** vs the MBN-extracted **11624**, and the *only* difference is a stray leading `\x07` on the extracted copy (a TLV length prefix, `7 == len("<ANDSF>")`, an artifact of our MBN extraction). Everything after byte 0 is **byte-identical**. The MAPCON_6 `<WiFiThreshold><WiFiAvailable>1</WiFiAvailable></WiFiThreshold>` block is present exactly **once** in the live file, at lines 197–199. ⇒ Part 18e's analysis was derived from a faithful copy and stands unchanged.

**Patch artifact rebuilt from LIVE bytes** (not the MBN copy, so it is byte-exact for writing): `diag-tools/mcfg-lane/andsf/vzw-cdmaless-andsf-FORCEDWLAN.xml`, **11619 bytes (−4)**, `diff` against the live read = the three intended lines and nothing else.
- live `sha256:b681897b609a488033912a7ed05beaa6…`
- patched `sha256:1b34312ed7025b5673cdf77aab176a19…`

**Also read live and banked:**
- **`/data/ds_andsf_config.txt`** (315 B) — confirms **`andsf_rule_mgr_active:1`** on the live modem, plus the measurement tuning (`wifi_meas_alpha:65`, `wifi_sampling_interval:1000`, `wifi_avg_interval:5000`, LTE/1x equivalents).
- `/data/default_andsf.xml` (3036 B, "Default Profile"), `/nv/item_files/ims/qp_ims_wifi_config` (512 B, `00 41 00 00 00 4b 00 00 00 06 00 06` then zeros — the 0x41/0x4B ≈ −65/−75 dBm rove thresholds from part 6, confirmed in EFS), `/nv/item_files/modem/mmode/wifi_config` (11 B, `03 01 01 05 00…`), and a **113-entry listing of `/nv/item_files/ims/`**.

**⭐ Build: done locally, no build server needed** — which retires the "probes must be built on Stellaris16" assumption for anything that needs only libc. The trick is to skip the missing `out/soong/ndk/sysroot` entirely: bionic headers from source (`-nostdinc -isystem bionic/libc/include -isystem bionic/libc/kernel/{uapi,uapi/asm-arm64,android/uapi}`) plus the prebuilt crt objects and `libc.so` stub in `prebuilts/runtime/mainline/runtime/sdk/android/arm64/lib/`. Works on a bare checkout. See `diag-tools/efs2-probe/build.sh`.

**Tool/kernel facts worth keeping:**
- ⚠️ **`/dev/diag` has no `.poll` handler** — `poll()`/`select()` return `DEFAULT_POLLMASK` and are useless. `read()` sleeps in `wait_event_interruptible`; the probe times out with a `SIGALRM` handler installed **without `SA_RESTART`** so the alarm breaks the read with `EINTR`.
- **DCI does not filter EFS2.** `diag_dci_filter_commands()` blocks mask-config commands (0x7d/0x73/0x81/0x82/0x60 and some 0x4B/0x12 subcommands); `0x4B/0x13` passes straight through.
- **`entry_type 15`, not 4, means "item file"** (`mode 0160777`). Directories are 1, ordinary EFS files 0 (`mode 0100777`). The commonly-cited 0..4 enum is wrong for this. READDIR layout confirmed empirically: `dirp@4, seqno@8, errno@12, entry_type@16, mode@20, size@24, atime@28, mtime@32, ctime@36, name@40`; item files report `mtime=0`.
- **HELLO's window fields are not device maxima** — first call returns `0x00100000` for all six, later calls just echo whatever the client asked. Read in fixed chunks (512 B) and stop on a short read.
- DCI client IDs are per-open, released via `DIAG_IOCTL_DCI_DEINIT`; `MAX_DCI_CLIENTS` is 10, so leaked registrations from crashing probes could eventually wedge.
- Kill `diag_mdlog` before use (different failure mode from the mask-file case, but still).

**Rig verified healthy afterwards**: 311480 LTE, IMS REGISTERED, SMS/VoIP FULL_SERVICE. **No reboot, no flash, no framework restart, no airplane cycle, no modem restart, and no EFS write of any kind.** `c39a6acf` untouched.

⚠️ **Read-only was enforced and independently audited**: the source defines only opcodes `0, 2, 3, 4, 11, 12, 13, 15` — no WRITE/UNLINK/MKDIR/RMDIR/RENAME/CHMOD/ERASE/TRUNCATE/PUT/DELTREE/SYMLINK constant exists in the file — `OPEN` always sends `oflag = 0` (O_RDONLY), and the only `write()` calls in the program target the `/dev/diag` transport itself.

**⇒ Remaining blocker is now exactly one thing: EFS2 WRITE.** Everything else for the forced-policy experiment is in place — the transport works, the live file is read and hashed, and the patched bytes are ready. Writing is a **separate, deliberate decision** (it mutates modem EFS on the rig) and should be taken with a fresh snapshot in hand and the `modemst1/modemst2/fsg` restore path from `diag-tools/captures/a8-silver-preflash-20260804/` confirmed available.

## Guardrails / notes

- ⭐⭐⭐ **EFS2 works over DCI — `diag-tools/efs2-probe/` (read-only).** `DIAG_IOCTL_DCI_REG (23)` → `client_id`, then `write(fd, LE32(0x40)|LE32(uid)|LE32(client_id)|raw_request)`, **no HDLC, no CRC** (kernel frames it). ⚠️ **The plain `/dev/diag` `\x20\x00\x00\x00`+payload recipe in `HOWTO-modem-diag-capture.md` CANNOT WORK on this rig** — `diagchar_write()` drops every non-DCI pkt_type with `-EIO` while `logging_mode == DIAG_USB_MODE && !usb_connected`, and the diag USB function isn't in this composition. Proof of life: `raw 00` (`DIAG_VERNO_F`) → modem build `Nov 27 2019`.
- ⭐⭐ **Live modem EFS `/data/andsf.xml` == the MBN source** (11623 vs 11624 B; the only delta is a stray leading `\x07` TLV length byte on our extracted copy). Part 18e's patch spec is therefore valid against the real file, and the artifact has been **rebuilt from the live bytes**: `vzw-cdmaless-andsf-FORCEDWLAN.xml`, 11619 B, diff = 3 lines. Live `andsf_rule_mgr_active:1` confirmed from EFS too.
- ⭐ **Probes needing only libc can be built LOCALLY** — skip the absent `out/soong/ndk/sysroot`, use bionic headers from source plus the crt objects and `libc.so` stub in `prebuilts/runtime/mainline/runtime/sdk/android/arm64/lib/`. `diag-tools/efs2-probe/build.sh` is the working recipe; the Stellaris16 detour is only needed when linking vendor QMI libs.
- ⭐ **The forced-WLAN policy patch is fully specified and pre-built** (part 18e): in VZW `/data/andsf.xml`'s **MAPCON_6** (the idle, `CallType 00`, WLAN-first rule), replace `<WiFiThreshold><WiFiAvailable>1</WiFiAvailable></WiFiThreshold>` with `<LTEThreshold><LTEAvailable>1</LTEAvailable></LTEThreshold>` — one element, −4 bytes, one occurrence, using only tags its sibling rule 7 already proves parse. Artifact: `diag-tools/mcfg-lane/andsf/vzw-cdmaless-andsf-FORCEDWLAN.xml`. ⚠️ Read the **live EFS** copy and compare against the MBN source before patching; snapshot first; rig only.
- ⭐⭐ **The circularity is visible as data in the MBN XML.** The idle case is decided by two symmetric rules: MAPCON_6 (WLAN-first, gated `WiFiAvailable 1`, priority 1) vs rule 7 (cellular-first, gated `LTEAvailable 1`, priority 2). The higher-priority WLAN rule's only condition is the one thing the ring can never produce; the lower-priority cellular rule's condition is always true. **Verizon's own policy would prefer Wi-Fi — it just can never find out that Wi-Fi is there.**
- ⭐⭐⭐ **The WFC block is a CIRCULAR dependency, not a missing input (parts 18c/18d).** WLAN service never becomes real (`WLAN RAT 17`, `IWLAN Srv status changed: from 17 to 17`) → no IWLAN in MPPM's dsd_mask → none in CM's ratMask → WFC-OFF branch → no IWLAN target RAT → no WQE → no Wi-Fi measurements → `is_wlan_pref 0` → no ePDG → no WLAN service ⟲. ⭐⭐ **Proven from the inside in `cap-p18e`:** with the wifi switch ON and a correct DSD `0x20` re-asserted every 3 s through a full registration, the `wlan_srv_chg` event (`tech:2, evnt:1005`) **does** fire and reaches `ds3gdsdif`, `ds_wlan_meas` **and** `ds_andsf` — and **all three discard it** (ANDSF says why: `req_wqe_prof_mask is 0`), leaving `WLAN srv_status = 0` on all 13 MPPM evaluations and 33/33 WFC-OFF. **Every AP lever we own feeds a node inside the ring; stop probing from the AP side.** Only identified exit = the **ANDSF policy** (answered from MBN policy, not measurements) ⇒ **build a DIAG EFS2 client and force a WLAN-preferred `ims` policy on the rig.**
- ⚠️ **Don't repeat the "X never fires" mistake:** part 18c concluded `ds3gdsdif_wlan_srv_chg_cb`/`ds_wlan_meas_wlan_srv_chg_cb` fire *zero* times — true only because that capture contained **no AP-side WLAN report**. Before writing "never fires", check the capture actually contained the stimulus.
- ⚠️ **IMS reads the wifi switch too early for any AP-side race to win**: `PDPManager.cpp:541 bIsWIFISetting[0]` at Init even when the switch is asserted within ~20 s of a modem restart. Re-asserting after Init does fire `:878`, but changes nothing.
- ✅ **MPPM's IWLAN-availability evaluator is WILLING — stop suspecting readiness/entitlement bits.** `ds_mppm_update_wifi_and_iwlan_availability` runs every boot with `Subscription Ready 1`, `is_impi_imsi_ready 1` (⇒ **ISIM/IMPI worry is dead**), `WLAN Offload NV 2 (enabled)`, and **never** takes its `:2924 "Blocking IWLAN globally"` branch. Its only failing input is `WLAN srv_status = 0`.
- ⭐ **`ratMask` is CM's serving-system view**, delivered `CM → qpDplProcessRatInfoEvent → GenericDcmCallback event type 4 → PDPManager.cpp:1017`. CM reports WWAN only, so nothing can put bit 6 there until a WLAN service exists. Do not look for a "mask builder" bug — there isn't one.
- ⭐⭐ **NEW LEVER, validated live 2026-08-06: `DSD 0x34 TLV 0x13` (u8) sets the modem's Wi-Fi RADIO SWITCH; `0x35` reads it.** Full chain proven from the modem's own F3: `ds_qmi_dsd.c:4698` → `ds_mppm_cmd_hdlr.c:9992` → `ds_iwlan_s2b_iface_hdlr.c:1391/1397` → `qpDcm.c:12698 DS_SYS_EVENT_WIFI_SETTINGS_CHANGE sent` → `PDPManager.cpp:878 HandleWifiRadioChange`. ⚠️ **Resets to 0 on every modem restart** (measured), and **a no-change write is absorbed silently — force `0x13=0` then `0x13=1`** or IMS never hears it. 🔴 **It is NOT the gate**: with the switch ON and three subsequent gate evaluations, `ratMask` stayed `1024` and the WFC-OFF branch still won. It *does* provoke IMS into `GetIMSAllowedServices RAT = 6` (IWLAN) — the only thing that ever has.
- ✅ **`CallmodePreference` at `:504` IS the IMSS `0x53 TLV 0x15` WFC preference, and BOTH values take the WFC-OFF branch** (wrote 3 → logged 3; wrote 1 → logged 1). Excluded by experiment; do not re-test.
- ⚠️ **The rig `<guid>.qdb` needs two repairs before `decode_f3.py` works**: zlib from `0x40` ends with a **bad adler32** (decompress in chunks, tolerate the final error, or you lose all 23 MB), and the decompressed text has **records glued together without newlines** (re-split on `(?<!\n)(\d{2,7}:\d+:\d+:\d+:[\w./-]+\.(?:c|cpp|h|cc):)`, 109k → 356k records). Tell-tale of an unrepaired DB: decoded lines show `file.c:` with an **empty line number**, and every `file:line` grep returns 0 even for messages that did fire.
- ⭐⭐ **`ServiceOnRatMask = 0x644e` has bit 6 (IWLAN) SET** (`PDPManager.cpp:1094`) — the modem's *configured* RAT set includes IWLAN; only the live mask never does. IWLAN is configured and policy-allowed (`GetIMSAllowedServices RAT = 6`, 595×); the missing thing is an availability input, not capability.
- ⭐ **The `ratMask` is already IWLAN-free when it ENTERS PDPManager** (`HandleRatNotification :1017`) — nothing in PDPManager's mask pipeline strips it, so do not RE the mask-adjust stages (`:2118-2287`); two of the three never even run.
- ⭐⭐⭐ **Verizon WFC WORKS on the Warp line — proven on a Pixel 2026-08-06.** Part 3's *"Verizon's WFC entitlement REFUSES this device"* was about the **device**, not the **line**, and its "lane odds have materially dropped" reality check is **obsolete — do not cite it**. The carrier side is willing; everything left is inside our modem. ⚠️ Not proven: that VZW's ePDG would accept the *legacy modem-centric* path or a 2017 Palm IMEI (Pixel = modern AP-assisted stack + modern IMEI). Entitlement stays a possible *future* gate — we bypass the entitlement app by writing modem WFC state directly over IMSS v01, and we are currently blocked far upstream of ePDG anyway.
- ✅ **The WFC gate IS structural — established by experiment in part 17, not by inference.** Part 15 asserted carrier-independence from two lines that (as Kyle spotted) had **no carrier-side WFC activation at capture time**. Part 17 ran the real control: **Warp in the F3 rig, carrier-activated AND Pixel-verified, Wi-Fi up, `wifi_call=2`, `client_prov=1`, `volte=1`, IMS REGISTERED** → `qpGetPreferredRAT` took the WFC-OFF branch **35/35**, `ratMask` still never carried `0x40`, `ret - 0` ×80 — byte-identical to the unactivated runs. ⇒ **Carrier entitlement/activation, Wi-Fi availability, and the WFC provisioning store are ALL excluded as the cause.** Do not re-open the carrier angle; do not spend further SIMs. The remaining suspect is the code that builds `ratMask`.
- ⭐⭐ **RAT encoding is bit *n* ↔ RAT *n*, confirmed live** (`ratMask 1024 → ratVal 10 → returning 10`; `ratMask 1 → ratVal 0`). LTE=10↔`0x400`; **IWLAN=6 ⇒ `0x40`, never once observed.** This makes "the caller never offers IWLAN in the mask" the strongest live lead in the lane.
- ⚠️ **Use a modem restart, never an airplane cycle, when Wi-Fi must stay up.** `ctl.stop per_mgr` → `ctl.restart per_proxy` → `ctl.start per_mgr` triggers the gate and leaves WCNSS/Wi-Fi untouched; an airplane cycle wedges Wi-Fi on the rig (2/2, unrecoverable without a reboot). Also: **never `stop`/`start` the framework** — it killed `system_server` on this GSI.
- ⭐ **Rig recovery recipes (both cost nothing, both saved a flash):** black screen after reboot = SystemUI crash-loop from reset runtime permissions → `pm grant com.android.systemui android.permission.READ_CONTACTS` (+ `com.android.bluetooth`) then `am force-stop com.android.systemui`. `adb root` "disabled by system setting" → `setprop service.adb.root 1` gives `u:r:su:s0` without touching Developer options (essential when SystemUI is down and the UI is unreachable).
- ⚠️ **Modem WFC provisioning is NOT reliably EFS-persistent per-ICCID.** Part 15 wrote `wifi_call=2` on the TMO ICCID and recorded it as persistent; on 2026-08-06 it read back `1 (OFF)`. **Always `get 0x54` and re-write immediately before any capture** — never assume a previous session's provisioning survived.
- ⚠️ **Carrier-side WFC activation does not reach this modem on its own.** With WFC enabled in the US Mobile app, the store still read `wifi_call=1 (OFF)` — there is no entitlement/OMA-DM client on the rig's phh GSI to receive it. The IMSS v01 hand-write remains mandatory.
- 🔴 **Rebooting the A11 rig restores SELinux Enforcing, which locks out every QMI probe.** `imss-probe`/`imsa-probe`/`dsd-probe` fail `connect rc=-16` with `avc: denied { create } … scontext=u:r:shell:s0 tclass=socket` — this is **SELinux, not client-slot contention** (contrast `nas-probe`'s genuine `rc=-17`). Parts 9–16 worked only because an earlier session had left the rig Permissive. **`setenforce 0` is a prerequisite for probe work after any rig reboot**, and `/sys/fs/selinux/enforce` is the thing to check first when a probe suddenly stops connecting.
- ⭐ **RE target of record: `qpIMSPolicyManager.cpp:504→510`** (msgids `164805`/`164806`, with the never-taken WFC-ON branch at `164807` and the never-called `extractIWLANRAT` at `164803`). Prefer it over `qipcallh_if_wifi_calling_enabled` — 4 source lines vs 20, all inputs logged, three consecutive descriptors for fingerprinting.
- ⚠️ **A fresh ICCID does NOT read `wifi_call=2`.** The TMO SIM read `1 (OFF)`; part 9's "a never-written modem already has wifi_call=2" was a VZW-specific observation. Always `get 0x54` before assuming.
- ⚠️ **phh GSI `preferred_network_mode` is fatal on T-Mobile**, not just suboptimal — TMO has no 2G/3G fallback, so GSM/WCDMA-preferred means *no registration at all*. Set global + per-sub to `9` and airplane-cycle.
- ⭐⭐ **QSR4 msgid → code:** descriptor pointer = `QSR_BASE + 8 × msgid` in a NOLOAD `0xf8xxxxxx` section, `immext`-encoded. **Main module base `0xf8000000` — VALIDATED** (arg-count consistency 86.5 % / 96.2 % across 42 k call sites). Send helpers: `0x875b85f4`/`0x875b8a20`/`0x875b8d50`/`0x875b90f8` = 0/1/2/3 args. **Never grep the image for a raw msgid — they are not stored.**
- 🔴 **The affine model does NOT hold for the IMS module (msgid band 140000–219999) — part 15 correction to part 14.** No `base + N × msgid` fits: an arg-count-consistency sweep over strides 4/8/16 tops out at 0.67 with tiny n, versus 0.87–0.96 for the validated main module. Part 14's "base ≈ `0xf84f73xx`" was a locality-scoring plateau, not a real base. A promising candidate (`0xf850a608`, derived from a 4-consecutive-descriptor + exact (3,0,0,1) arg-signature hit at `0xf864c430`) was **falsified two ways**: it scored 0.412 vs 0.373–0.411 for random nearby bases, and disassembling its site showed decimal digit-composition code, not policy logic. ⇒ **Do not re-run descriptor-fingerprint searches for IMS msgids.** Consecutive descriptors + arg-count patterns are far too common to discriminate (descriptors and code are both laid out in source order, so *every* file produces ordered runs). IMS logging also goes through file-local wrappers (`0x872108e8`, `0x872109d8`, `0x87210ae4`, `0x87210b58`) that pass the descriptor in r1 and take a second small-int argument — consistent with IMS using a different logging API whose msgid is computed at runtime. **Find IMS functions structurally in Ghidra, not by msgid arithmetic.**
- ⚠️ QSR4 strips all format strings and symbol names — `WFC OFF`, `qpGetPreferredRAT`, `QPConfigurationHandler`, `extractIWLANRAT`, `is_wlan_pref` are all **absent** from the image. Only source *file names* survive, in a packed pool at `0x8815bcbf` (nothing points at it). Do not plan on string search.
- ⚠️ **Never trust `llvm-objdump` text for constant harvesting on this image** — it desyncs on data-in-code and drops entire files' immediates without warning, which looks exactly like "that code isn't in the binary". Decode `immext` from raw words instead.
- ⭐⭐ **Never re-open "arm the modem's IWLAN RAT from the AP"** — DSD 0x53 and 0x65 return NOT_SUPPORTED; this firmware's DSD stops at 0x47. Sweep technique: `dsd-probe get 0xNN` over the id list, 57 = absent.
- ⭐ **Never re-open the WDS profile store as the WLAN-pref source** — no IWLAN apn_bearer bit, no WLAN-pref param in this IDL vintage (part 11); 0x3e is roaming_disallowed. Profile 1 is the live IMS PDN: snapshot exists (`dut-wds-profiles-raw-20260805.txt`), keep it pristine.
- ⭐ Exhausted-and-inert DSD levers (do not re-send expecting magic): 0x20 WLAN_AVAILABLE, 0x22 global WLAN preference, 0x29 per-APN preferred system — all accepted, none reaches IWLAN/ANDSF state observably, even combined + radiocycle. Part 12 confirmed 0x22/0x29 inert **from the modem's own F3**, not just by absence of effect.
- ⭐ The DSD WLAN-available report is **accepted but inert** — the modem takes it (with `bind` sub=**1**) and does nothing with it, even across a radio cycle. The gap is not the report, and not IWLAN-RAT-enable (which doesn't exist). ⚠️ Part 12 amendment: the report we sent for four sessions was also *malformed* (`0x12` is `wqe_status`, not DNS; conn_status/assoc/network read as 255=invalid). Sending a **correct** full report changes the parse but not the outcome — the blocker is upstream, in IMS.
- ⭐⭐ **`req_wqe_prof_mask == 0` is a SYMPTOM, not the gate (part 13 amends part 12).** ANDSF does discard every WLAN service change while the mask is 0, but the mask is 0 because qipcall never makes IWLAN a target RAT (`TRAT MASK 0x00` → `qpDplHandOverParamsSet_ex SRAT=0 TRAT=0`), so the WiFi-measurement module never inits and `DplHandOverSetCNEProfileForMetrics` is never reached. Chase `qipcallh_if_wifi_calling_enabled: ret - 0`, not the mask.
- ⭐⭐ **Re-decode before re-capturing.** `decode_f3.py`'s 3rd argument filters by **source file**, so a capture is only as informative as the filter it was read with. Parts 9–12's `.qmdl` files sat on the rig containing the answer the whole time; re-decoding them with `PDPManager|PDPHandler|PDPRATHandlerVoLTE|ims_settings_common|qpDplHandOver|cmph` produced most of part 13 with zero device work.
- ⭐ **Closed leads — do not re-open:** `Enable VoWifi` in `iDM_Services_Mask` is already 1; IMSS `0x5d SET_HANDOVER_CONFIG` reaches ANDSF but can only update thresholds for already-requested profiles (`is_meas_started 0` → stops at "cache to global cache"), never arm one; `PDPManager`'s measurement-based RAT selection (line 2368) is skipped by design on VZW operator mode; `ho_mgr.c:4394`'s IR-92/TMO/VZW early-return never fires; `IsVoWIFIServiceEnabled`'s OMA-DM/MDN-match block is ATT-only and never runs here.
- ⚠️ **IMSS handover-config SET/GET TLV ids are offset by one** (SET REQ = GET RESP − 1), like `0x53`/`0x54`. Writing `SET 0x5d TLV 0x1a` returns malformed; `TLV 0x19` is what lands in GET's `0x1a`. Snapshot `get 0x5e` before any write — a single-TLV SET does change the stored config.
- ⚠️ `event_update_location_wlan - srv status : 0` means nothing — it prints 0 for both WLAN available and not-available.
- ⚠️ Modem EFS (`modemst1/2`, `fsg`) is **encrypted on disk**: pulling the partitions and grepping for `andsf`/`epdg`/XML yields nothing. EFS inspection requires a DIAG EFS2 client.
- Stock A8 witness is **unavailable for live WFC observation** (can't register). Static stock artifacts + the A11 pull rig remain the reference.
- Respect the VoLTE guardrail: no extract-utils regen on mithorium-common (`PLAN-volte.md`).
- Don't touch the working LTE/IMS chain while experimenting: all changes pepito-gated and prop-revertable; the qmux/ipc_router stack is load-bearing.
