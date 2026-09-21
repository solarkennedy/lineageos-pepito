# PLAN — sticky "Emergency calls only" on Verizon (only an airplane toggle clears it)

**Opened 2026-09-15** after Kyle's 2026-09-14 road episode on **`new2` (`9c2e6b00`)**, the daily
driver since ~09-13. **This file is a plan only — nothing is implemented.** Goal: get to the
bottom of the *sticky* "Emergency calls only" state for real, then make the daily driver reliable
(a shipped workaround is acceptable, a root-cause fix is the target). Kyle is willing to run any
experiment; fleet = `new2` (daily, the ONE SIM), `silver` (stock A8 witness, unrooted), `dut1`,
`gold`, `new1`, `gifted`, plus the Pixel 9 as a Verizon comparison.

Companion notes: memory `nas-slow-reattach` (the transient wedge, fixed), `statusbar-bang-tmobile`
(cell-edge transients), `attach-domain-selection` (July: modem abandons the home PLMN when IMS is
unavailable — the mechanism this plan bets on), `sim-uicc-toggle-trap` (different symptom, excluded).

---

## 0. Three different "Emergency calls only" mechanisms — name the one you are looking at

| # | Shape | Duration | Status |
|---|---|---|---|
| **M1** | Cold radio power-up goes IWLAN-first because the modem's DSD still holds WLAN-available; voice waits ~45 s for IMS while LTE data is already up | ~50 s, self-recovers | **FIXED** 2026-08-23 (`18771530`, feeder down-edge + `qmux_wfc_down`); in every build ≥ 20260823, so in `new2`'s 20260913 build |
| **M2** | Serving cell lost at cell edge (RSRP −108…−117) → OUT_OF_SERVICE → emergency-camp on the loudest foreign LTE cell (AT&T 310-410 / T-Mobile 310-260) → their attach is rejected `rejectCause=13` → Verizon re-acquired on the modem's rescan | ~95 s, self-recovers | Explained (Gold 07-24 bench, 07-30 road; RF path proven within 1–3 dB of the Pixel). Not a bug, but the rescan cadence was never tunable (`PLAN-mcfg.md` parked) |
| **M3** | **Sticky:** camped emergency-only on a foreign PLMN (or no PLMN) and it **stays there** until the user toggles airplane mode, after which Verizon comes back in seconds | minutes → indefinite | **NEVER ROOT-CAUSED. This lane.** Seen: Gold 2026-07-20 (right after a flash) and 2026-07-21 (spontaneous, mid-day use), both camped AT&T/T-Mobile with cause 13, both cleared by one airplane toggle; **new2 2026-09-14 on the road** (Kyle: airplane toggle → "right back on Verizon immediately") |

Two facts about M3 that already constrain it:

- **It predates all Wi-Fi-calling work** (July episodes happened before the feeder/IWLAN lane
  existed), so the IWLAN→LTE transition can at most be *one trigger*, not the mechanism.
- **"Airplane clears it immediately"** means: the network is not permanently rejecting us, RF is
  fine at that moment, the SIM is fine, and the bad state is *runtime* state that a DMS
  LPM→ONLINE cycle discards. In a Qualcomm modem that set is small and known: forbidden-TA lists
  (3GPP 24.301 §5.3.2 says they are erased at power-off), a "disabled E-UTRA" verdict and its
  timer, the EMM attach-attempt counter / T3402, the CM domain-selection verdict ("no voice
  possible on this PLMN"), the IMS registration state machine, and qcril's own caches.

---

## 1. Constraints we already have (do not re-derive)

- **The ROM's default network mode is "everything":** `device/xiaomi/Mi8937/pepito.vendor.prop`
  sets `ro.telephony.default_network=33` (NR/LTE/TD-SCDMA/CDMA/EVDO/GSM/WCDMA). Kyle's own stock
  finding (memory `attach-domain-selection`, 2026-07-09): *on stock A11 he had to set the mode to
  LTE/CDMA, not Global, to register — Global's GSM/WCDMA gave the voice-centric modem CS-roam-hunt
  targets → "T-Mobile churn".* DUT1 was later hand-set to LTE-only (`allowedNetworkTypes user=4096`).
  **Nobody has checked what `new2` runs.** This is the cheapest and highest-prior lever in the plan.
- **The modem abandons the home PLMN when it believes voice is impossible there** (July, `nas-probe`
  evidence): voice-centric UE (`usage_preference=1`) + VoLTE-only 311480 + IMS unavailable ⇒ CM
  declines full service on 311480 and hunts roam partners — AT&T LTE attach rejected cause 13 ×17,
  T-Mobile GSM LAU DENIED. That is *exactly* the M3 signature. With IMS registered the modem holds
  Verizon indefinitely. ⇒ **M3 = "IMS became unavailable for a while, and the modem's
  domain-selection escalated to a state it never leaves on its own"** is the leading model. IMS
  loss is the *trigger* (many possible: cell-edge drop, IWLAN→LTE handover failure, SIP timeouts);
  the escalation is the *bug*, and it lives in modem policy inputs we control (mode preference,
  usage setting) or in a watchdog we can add.
- Static modem/IMS config is byte-identical to stock (EFS diff 08-13) and CDMAless-Verizon is the
  active MBN — do not chase MBN/NV content again. The difference vs stock is *runtime driving*.
- `new2` runs the AML modem image (`…C1-214411`, flashed 09-02) — byte-identical to DUT1's and to
  silver's stock-AML modem ⇒ silver is an apples-to-apples witness for bench A/B.
- `new2` state read 2026-09-15 08:18 (USB, read-only): build 20260913 (includes the M1 fix and the
  uicc-toggle fix), root-on-boot ✓ (`persist.vendor.xiaomi.adbroot=1`), WFC on, sitting on
  **IWLAN at home**, `persist.adb.tcp.port` **unset**, **no Tailscale node**, **no persistent
  logging**, radio ring at the 256 KB default ⇒ the 09-14 radio logcat is gone; only the framework's
  in-memory histories may still hold it (§3, pull before the next reboot). `units.conf` still says
  `DAILY=gold` — stale.
- Instruments on hand: `diag-tools/nas-probe/` (`status`, `bands`, `wds*`, `usage`, `voicedom`,
  `mode`, `domain`, `attach/detach`, `radiocycle`), `dsd-probe` (DSD systems; `wlandown`),
  `imss-probe` (IMSS config get/set incl. `ims_test_mode`, P-CSCF port), `imsa-probe` (IMS
  registration + `voip_service_rat`), `efs2-probe` (modem EFS reads), `diag-a16-shim/` (modem F3 +
  log packets on A16; decoders `decode_f3.py qdb.dec`, `decode_f3_ext.py`, `decode_qmi.py`;
  `Diag-all.cfg`, `Diag-lte-ota.cfg` + `make_diag_lte_ota_cfg.py`), `.scat-venv` (QMDL → GSMTAP pcap,
  NAS/RRC decoded in Wireshark), `gold-bang`/`gold-triage` (time-sliced pulls), `reattach-catch.sh`
  / `capcycle.sh` (airplane-cycle catchers), `pepito-diagcap.rc` (init-armed capture pattern).
- Guardrails still in force: never airplane-cycle for WFC bench work; never use the "Use SIM"
  toggle; never QRTR-send to the modem node; never `stop adbd; start adbd` over adb; Kyle owns
  build/flash; diag capture needs ~25 s warm-up before the event of interest.

---

## 2. Hypotheses, ranked

| # | Mechanism | Predicts during the stuck state | Cheapest discriminator | Fix lane if true |
|---|---|---|---|---|
| **H1** | **Domain-selection escalation:** IMS registration is lost (any trigger) → voice-centric CM declares "no voice on 311480" → with GSM/WCDMA in the mode mask it disables E-UTRA / hunts CS roam partners → camps AT&T/T-Mobile limited (cause 13) and never re-evaluates Verizon until a power cycle or a long modem timer | Foreign PLMN or none; **RAT may be GSM/WCDMA** (E-UTRA disabled) or LTE (PLMN hunt); data dead; `nas-probe status` shows mode incl. G/W, `srv_status` limited; radio log shows IMS unregistered *before* the drop | **Bench Cell F** (§5): force IMS off/failing under Global vs LTE-only vs data-centric; read `new2`'s actual mode first (§3) | Ship LTE-only (or LTE/CDMA) as the pepito+Verizon default; optionally `usage_preference` data-centric; watchdog as backstop |
| **H2** | **IWLAN→LTE transition failure when leaving home Wi-Fi** (IMS on IWLAN at home; Wi-Fi vanishes; IMS never re-registers on LTE) — a *trigger* for H1, and on its own it yields "Emergency calls only" with LTE data still working | Carrier label still US Mobile, LTE data OK, voice OOS, `imsa-probe` not registered, DSD may still list WLAN | Cell C (§5): WFC on a Pixel hotspot, IMS on IWLAN, hotspot off | Fix the feeder/handover path; IMS re-kick (IMSS `ims_test_mode` 1→0) as a cheap re-register |
| **H3** | **EMM attach backoff** — 5 failed attaches (e.g. ESM failure on the IMS initial-attach PDN) → T3402 (default 12 min) or a network T3346 backoff | Camped on Verizon, LIMITED, no attach attempts for a fixed ~12 min; NAS OTA shows Attach Reject / ESM cause | Recorder NAS OTA (`0xB0EC/0xB0ED`, `0xB0E2/0xB0E3`) around onset | Attach-config change (initial-attach APN / PDN type via carrier config or WDS profile) |
| **H4** | **qcril stale state** (e.g. the "Already PS attached!" early return, stale radio state) — AP side | `ctl.restart qmux_qcrild` heals it while `nas-probe` still shows the modem detached | Rung ladder (§6/§5): qcrild restart before airplane | Blob is prebuilt → workaround only (restart watchdog) |
| **H5** | **Residual stale WLAN-available** (M1's cousin): Wi-Fi stays *associated but dead* (no down-edge) or the reboot-persistence follow-up (b) of the M1 fix never got answered | `dsd-probe` bare GET shows the WLAN row (tech 02 / rat 0xc9) with no usable Wi-Fi | `dsd-probe` during the episode; Cell C variant "AP stays up but drops internet" | Feeder: also send WLAN_NOT_AVAILABLE on validation loss / on boot always |
| **H6** | **Forbidden lists** — Verizon's own TAI landed on the modem's forbidden-TA list (cause 13/15 received on a home cell) or 311480 landed in the SIM's EF_FPLMN (cause 11) | Manual selection of Verizon works while automatic does not; `nas-probe status` FPLMN not clean | Rung "manual select Verizon" (§6); FPLMN read | Root-cause the reject; watchdog that re-runs PLMN selection |
| **H7** | **Null hypothesis:** it is M2 in a longer coverage hole than Kyle's patience | Recorder shows continuous Verizon-absent PLMN searches, Pixel also without service | Recorder timeline + Pixel note | Nothing to fix; keep the recorder to prove it |

H1 is ranked first because it is the only mechanism that (a) matches both July Gold episodes,
(b) matches Kyle's stock-A11 experience, (c) explains "airplane fixes it in seconds", and (d) is
reproducible on the bench with no RF tricks. H2/H3/H5/H6 are the trigger candidates the recorder
will sort out. Several can be true at once — the fix is defence in depth (§8).

---

## 3. Phase 0 — cheap checks on `new2` (next time it is on USB; ~15 min, read-only, no flash)

⚠️ Do these **before** the next reboot; the framework's in-memory histories are the only trace of
09-14 left. In order:

1. **Evidence pull** (already scripted: `diag-tools/nas-probe/new2-evidence-pull.sh <outdir>` waits for
   `9c2e6b00` on USB then pulls into e.g. `diag-tools/captures/new2-emerg-20260914/`): `dumpsys telephony.registry` (200-entry service-state
   history with timestamps), `dumpsys phone` (SST `mRadioPowerLog`/`mRatLog`/`mAttachLog`/
   `mCdnrLogs`, DataNetworkController + ImsPhone local logs), `logcat -b events,main,system,crash`,
   `dmesg`, dropbox. Look for 09-14 afternoon: carrier-name flips, `mIsEmergencyOnly`, RAT at the
   time, the airplane on/off pair in `mRadioPowerLog`, IMS registered/unregistered transitions.
2. **Network mode actually in force:** `cmd phone get-allowed-network-types-for-users -s 0`
   (bitmask; 4096 = LTE only), Settings → SIMs → Preferred network type, and the modem's view via
   `nas-probe status` (mode_pref, usage_preference, srv_domain, FPLMN, sys-sel state). If the mask
   still contains GSM/WCDMA, H1 has its main ingredient.
3. **Manual vs automatic selection**, data-roaming switch, WFC preference row — `dumpsys
   telephony.registry` `mIsManualNetworkSelection`, `settings list global | grep -Ei
   'preferred_network|data_roaming|airplane|wfc'`.
4. **IMS/DSD baseline while healthy:** `imsa-probe` (registered, `voip_service_rat`), `imss-probe get
   0x54`, `dsd-probe` bare GET (WLAN row present at home is expected while Wi-Fi is up).
5. **Promotion checklist for the daily driver** (runtime props, all reboot-persistent, no flash):
   `persist.adb.tcp.port=5555`; Tailscale on `new2` (always-on VPN + doze whitelist as on Gold,
   "Use Tailscale subnets" OFF); `persist.logd.logpersistd=logcatd`, `persist.logd.size.radio=16M`,
   `persist.logd.size=2M`, `persist.logd.logpersistd.size=64`, rotate 1024; `units.conf DAILY=new2`
   + a Tailscale IP row; `pepito-adb-wrappers`. These are prerequisites for §4 and §6.

Kyle's recollection of the 09-14 episode (answer whenever convenient — it picks the branch):
- What did the status bar say: **US Mobile / Verizon**, **T-Mobile**, **AT&T**, or nothing?
- Was **mobile data** working while it said "Emergency calls only" (open a page)?
- Roughly **how long** it sat there before the airplane toggle, and had Wi-Fi been in use just
  before (leaving home / a hotspot)?
- Did the **Pixel 9** have Verizon service at the same spot?

---

## 4. Phase 1 — the flight recorder on the daily driver (the core deliverable)

Everything below is runtime/on-device, root-only, no ROM change; it is the instrument the rest of
the plan depends on. Battery cost must be measured before Kyle drives with it (§4.4).

### 4.1 AP-side
- `logcatd` persistence as in §3.5 → `/data/misc/logd/` survives reboots and rotation.
- Leave `persist.vendor.radio.adb_log_on=0` for the first week (qcril verbose is enormous); flip
  it on only if the modem-side recorder leaves an AP-side gap.
- **State sampler** (shell script started from the same hook as the modem recorder): every 10 s
  write one CSV line — wall clock, `mVoiceRegState`, `mDataRegState`, RAT, `mIsEmergencyOnly`,
  operator numeric/alpha, `mIsManualNetworkSelection`, RSRP/RSRQ, EARFCN/PCI/CI/TAC, IMS
  registered + `voip_service_rat` (`imsa-probe`), Wi-Fi associated + `vendor.qmux.wfc_bridge`
  status prop, screen state. Every 60 s add `nas-probe status` (srv_status, PLMN, mode_pref, FPLMN,
  attach state) and `dsd-probe` bare GET (system list). Rotate by day. This is the timeline that
  survives even if logcat rotates away.

### 4.2 Modem-side (`diag_mdlog` via `diag-a16-shim`)
- **Road mask**, not `Diag-all.cfg` (the cold-cycle capture ran ~8 MB/min): keep the LTE log-packet
  mask from `Diag-lte-ota.cfg` but trim equip-id 11 to RRC OTA/serving-cell/PLMN-search
  (`0xB0C0–0xB0C4`), NAS EMM/ESM plain+secured OTA and EMM state (`0xB0E0–0xB0EF`), idle/connected
  measurement summaries only (drop ML1 PHY items); add IMS SIP messages (`0x156E`) and the QMI link
  TX/RX items (so qcril↔modem NAS/DSD/IMSS traffic is in the same file). For F3, replace the
  all-SSID mask with a per-SSID mask (DIAG `0x7D` sub-cmd `0x04`) built from the SSIDs of the
  sources we care about — take them from the `ssid` field of `qdb.dec` lines for `reg_*.c`,
  `emm_*`, `sd_*`, `cm*`/`cmregprx`, `lte_rrc_*`, `ims_*`, `qp*`, `RegisterManager` — via a small
  extension of `make_diag_lte_ota_cfg.py`. Target < 10 MB/h; verify on the bench.
- Rotation: `diag_mdlog -s <MB> -n <count>` (max file size / max file number; **verify on the bench
  that it wraps rather than stops**), output under `/data/local/tmp/rec/`, keep ≥ 2 h of history.
  No `-e` (wake lock) — it must not hold the AP awake.
- Warm-up: the QShrink `0x99` stream needs ~25 s after start; irrelevant for an always-on recorder
  but it means captures started *after* an episode begins miss the onset.
- **qdb check for `new2`:** it runs the AML modem now; confirm the capture's
  `diag_qsr4_guid_list.xml` GUID matches the repo `qdb.dec` (DUT1's decoded clean; Gold's handshake
  came back empty — the "per-unit GUID" loose end in `diag-a16-shim/README.md`). If empty on
  `new2`, that is a blocker for F3 decode (log packets still decode via scat).
- Start mechanism: root-on-boot already fires on `new2`; arm the recorder the way
  `pepito-diagcap.rc` does (a vendor init rc with `seclabel u:r:su:s0` executing a script under
  `/data/local/tmp`), disarmed by deleting the rc. Alternative with zero image changes: a Tailscale
  cron from netbook4 that (re)starts it whenever `new2` is reachable at home.

### 4.3 Decode recipe (bank as a script under `diag-tools/nas-probe/`)
- NAS/RRC OTA: `.scat-venv/bin/scat -t qc -d <cap.qmdl> -F <out.pcap>` → Wireshark (GSMTAP: LTE
  RRC, EMM/ESM with reject causes, SIB1 PLMN/TAC, PLMN-search results).
- F3: `decode_f3.py qdb.dec <cap.qmdl> 'reg_|emm_|sd_|cmregprx|ims_|Register|SIP'` plus
  `decode_f3_ext.py` for the `0x79` remainder. QMI: `decode_qmi.py`.
- One `new2-bang "<MM-DD HH:MM>"` wrapper modelled on `gold-bang`: time-sliced radio/main pull +
  registry/phone dumps + the recorder CSV + the qmdl files covering the window →
  `diag-tools/captures/new2-<date>-emerg-<label>/`.

### 4.4 Cost gate before the road
- One night on the bench with the recorder armed: `/sys/power/suspend_stats`, `Resume caused by
  IRQ` cadence, coulomb delta vs the same night without it (technique in memory
  `tailscale-standby-drain`). Accept ≤ ~2× the idle floor; otherwise trim the mask further or run
  the modem recorder only while Wi-Fi is disconnected (the sampler stays always-on).

---

## 5. Phase 2 — bench reproduction (runs in parallel; bench units stay busy)

Every cell: n ≥ 3, recorder running, result = recovery time to voice+data IN_SERVICE on 311480 or
"stuck ≥ 15 min". A stuck state is then probed with the **programmatic rung ladder**, one rung
per 60 s, recording which rung heals it (each rung isolates a layer):
(1) NAS automatic re-register (add a `nas-probe auto` command: NAS `INITIATE_NETWORK_REGISTER`
0x22, automatic) → PLMN-selection layer; (2) `nas-probe radiocycle` (DMS LPM→ONLINE) → modem
runtime state; (3) `setprop ctl.restart qmux_qcrild` → qcril cache; (4) framework airplane
toggle (`cmd connectivity airplane-mode enable/disable`) → what Kyle does; (5) reboot.

### Cell F — deterministic domain-selection cell (run FIRST; no RF tricks; ~1 h)
Reproduces H1 on the bench under full control. Units: `dut1` and `new2` (weekend) with the SIM.
1. Baseline: full service, IMS registered (`imsa-probe`), note `nas-probe status`.
2. Make IMS unavailable, two severities: (a) admin-off `imss-probe setmsg 0x21 0x12 1`
   (`ims_test_mode=1`, the July state); (b) registration-*failing* (closer to the road):
   `imss-probe setmsg 0x21 0x10 <bogus P-CSCF port>` so REGISTER times out.
3. Watch 15 min: does the modem stay attached on 311480 (data alive, voice OOS) or detach and hunt
   (AT&T/T-Mobile cause 13, `srv_status` limited, data dead, `!`)? Which RAT does it camp on?
4. Restore IMS (`setmsg … 0` / port 5060). **Does service come back on its own, and how fast?**
   If not → the sticky bug is on the bench → run the rung ladder.
5. Repeat the 2×2 matrix: mode = current default vs LTE-only (`cmd phone
   set-allowed-network-types-for-users -s 0 4096`, or `nas-probe mode …`) × `usage_preference` 1
   (voice-centric) vs 2 (data-centric, `nas-probe usage 2`). The combination that keeps the modem
   camped+attached on Verizon while IMS is down *and* returns to full service unaided when IMS
   comes back is the shipping default (§8, F1).
   ⚠️ `ims_test_mode` and P-CSCF port are EFS-persistent — restore them (the `ims_enabler` oneshot
   re-asserts `test_mode=0` at boot / WFC-on, but not the port). ⚠️ `usage 2` alone loses SMS-over-NAS
   while IMS is down (July finding) — a trade-off to weigh, not a blocker.
6. **Stock witness (silver, unrooted is enough):** same idea via the UI — Enhanced 4G LTE toggle OFF
   (stock qcril speaks v01, so the toggle really disables IMS) under Global vs LTE/CDMA; observe
   with `dumpsys telephony.registry`. Kyle's July note predicts: Global → hunts T-Mobile; LTE/CDMA
   → stays. Confirming that on stock closes the "is it just our stack" question for H1.

### Cell A — RF loss (foil pouch / cookie tin / microwave-with-door-closed), dwell sweep
Dwell 1 / 5 / 15 / 60 min (60 min crosses Verizon's periodic-TAU + implicit-detach window, i.e. the
network forgets the UE and the next TAU is rejected → forced re-attach). Ours vs silver (SIM swap).
Measures the "drove through a dead zone" case with the *unclean* RF loss that airplane cycling
never exercises.

### Cell B — foreign camp → recovery
Settings → network operators → manually pick **T-Mobile** (then AT&T) → wait for cause 13 /
emergency-only → switch back to **Automatic** → time to Verizon HOME. Reproduces the second half
of every road episode deterministically. Ours vs silver.

### Cell C — leaving home Wi-Fi replay (H2/H5)
Use the Pixel 9 hotspot as the "home AP": WFC on, IMS on IWLAN (`voip_service_rat=0`,
`r_rmnet_data1` present) → **hotspot OFF** (AP vanishes, Wi-Fi stays enabled) → watch the feeder's
down-edge, DSD system list, IMS move to LTE, voice state. Variants: hotspot off + straight into the
foil pouch for 2 min ("drove off into a hole"); hotspot stays up but loses internet (Pixel airplane
mode) = the H5 "associated but dead" case.

### Cell D — reselection churn
`nas-probe mode` / LTE band preference to force B66-only then B13-only then release; mimics the
band-13↔66 inter-frequency handoffs seen in the 07-30 road log.

### Cell E — long-idle arming
10-min and 60-min idle before Cells A/C (the M1 wedge armed with idle time; check whether anything
else does).

Optional: root silver (Magisk-patched stock boot via EDL; its stock boot is banked) so its native
`diag_mdlog` gives stock-side modem F3 for the A/B. Unrooted timing via `dumpsys` is enough to
decide "stock sticks too / stock recovers".

---

## 6. Phase 3 — field protocol while it is still happening (Kyle's episode ladder)

Do this when "Emergency calls only" appears on the road; the recorder captures everything, so no
computer is needed — **your actions are the markers**, just note the clock time.

1. Note the time, the **carrier label**, whether **data works** (open a page), whether Wi-Fi was in
   use in the last few minutes, and whether the **Pixel** has service.
2. **Wait ≥ 3 min** (10 if you can) before touching anything — it separates M2 from M3.
3. Rungs, 60 s apart, stop at the one that heals it:
   (a) Settings → SIMs → Preferred network type: flip to LTE-only (or back) — cheap NAS re-scan
   without a power cycle; (b) Mobile data off → on; (c) Network operators → manual **Verizon**
   (overrides forbidden lists — if this works and Automatic did not, H6); (d) airplane toggle;
   (e) reboot only if (d) fails.
   ⚠️ Do **not** join Wi-Fi / a hotspot before (d): Wi-Fi association changes the modem's WLAN
   state and can mask the failure.
4. Afterwards, at home: `new2-bang "<time>"` (or plug in; the pull script does the rest).

Tethering for remote access is fine *outside* an episode (it does not disturb banked evidence),
and useful for pulls; it needs Tailscale on `new2` + `persist.adb.tcp.port=5555` (§3.5). During an
episode it is the one thing not to do.

---

## 7. Decision tree (evidence → lane)

- Stuck state shows **foreign PLMN / limited / data dead**, preceded by IMS unregistered, modem
  mode includes G/W, and Cell F reproduces it ⇒ **H1**. Fix = F1 (+F3 as backstop). If Cell F
  reproduces it even under LTE-only + voice-centric ⇒ F1 becomes data-centric or F3 (watchdog) and
  the IMS-loss trigger gets its own lane (H2).
- Stuck state shows **US Mobile label, LTE data OK, voice OOS, IMS unregistered** ⇒ **H2** (IMS
  layer). Fix = F2; if the trigger is the IWLAN→LTE move, F4.
- NAS OTA shows **Attach/TAU Reject** with an ESM/EMM cause and a fixed ~12-min silence ⇒ **H3**.
  Fix = F5.
- `ctl.restart qmux_qcrild` heals it while the modem was still detached ⇒ **H4**. Fix = F3 with a
  qcrild-restart rung (last resort).
- Manual selection of Verizon works while Automatic does not ⇒ **H6**; read the reject that put
  the entry there (recorder), then F3 ("re-run PLMN selection" rung).
- Recorder shows Verizon simply absent (no 311480 in PLMN-search results, Pixel also dark) ⇒
  **H7**; the only deliverable is the recorder-backed release-note line plus F3 for faster rescans.
- **Silver does the same thing in the same cell** ⇒ modem/network behaviour; still fixable from
  our side via F1/F3 (stock cannot be changed, we can).

---

## 8. Fix lanes (defence in depth — each is a small, separately flashable increment)

- **F1 — modem policy default (H1):** ship the Cell-F-winning combination for pepito: most likely
  `ro.telephony.default_network=11` (LTE only) or `8` (LTE/CDMA/EvDO) under `TARGET_DEVICE_PEPITO`
  in place of `33` (Verizon has no 2G/3G; emergency calls scan all RATs regardless; note the loss
  of 2G/3G roaming abroad in the release notes). Optionally `usage_preference` data-centric via the
  `ims_enabler` oneshot if Cell F shows voice-centric still escalates under LTE-only. Also a
  one-line **field workaround Kyle can apply today**: set Preferred network type to LTE-only on
  `new2` and drive with it for a week while the recorder runs.
- **F2 — IMS re-kick (H2):** cheapest re-registration without a radio cycle is IMSS
  `ims_test_mode` 1→0 (proven to re-register within seconds); a small watchdog rule "LTE data
  IN_SERVICE, voice OOS, IMS unregistered for > 30 s" → kick, rate-limited.
- **F3 — registration watchdog (backstop for every branch):** a vendor daemon in the qmux domain
  (same shape as `wfc_wlan_bridge`, no sepolicy novelty) that subscribes to NAS system-info
  indications and, when the SIM is present, the radio is ON, and service has been limited /
  foreign / absent for > N s (N ≈ 90 s to stay out of M2's way), escalates: NAS automatic
  re-register → after +30 s DMS LPM→ONLINE (`radiocycle`, 4 s recovery proven) → never more than
  once per 5 min; logs every action so the recorder can grade it. Layer-3 alternative in our
  carried `frameworks/opt/telephony` fork (`ServiceStateTracker` + `Phone.setRadioPower`) if the
  framework needs to know; the vendor daemon is preferred because it is independent of the
  prebuilt qcril.
- **F4 — leave-home transition hardening (H2/H5):** feeder sends WLAN_NOT_AVAILABLE also on
  Wi-Fi validation loss, and always once at boot; verify the IWLAN→LTE handover path with Cell C.
- **F6 — DSRM hardening:** carrier-config skip list for the framework's data-stall recovery on pepito (never RESET_MODEM; decide RADIO_RESTART), and fix/avoid the Tailscale resolver on cellular; see the 2026-09-16 15:30 note.
- **F5 — attach configuration (H3):** initial-attach APN / PDN type / IMS-PDN handling via the
  carrier-config overlay or the WDS profile (`nas-probe wdsmod`), guided by the reject cause.
- Every fix is validated first on the bench cell that reproduced the failure (Cell F/A/B/C), then
  by road days under the recorder.

---

## 9. Acceptance

- Bench: the reproducing cell recovers to full service on 311480 in < 30 s in 20/20 runs on both
  `new2` and `dut1`, with no rung needed.
- Road: **10 consecutive commute days with zero sticky episodes** and every transient < 120 s,
  proven by the recorder's CSV (not by feel); the watchdog's action log shows what it did.
- Release: the winning default + watchdog committed, recorder kept as an off-by-default diag mode
  (arm/disarm documented), release-notes entry replaces the "known issue" line.

---

## 10. Guardrails for this lane

- Evidence before code: no fix ships before its bench cell reproduces the failure.
- Reversibility: every modem write (`ims_test_mode`, P-CSCF port, `usage`, `mode`) is restored at
  the end of each session; `pepito-wfc-virginize backup <serial>` before the first write on a unit.
- No unattended airplane loops on the bench (USB drops after ~2 h); Kyle is present for Cell F.
- The M1 rule stands: WFC bench work never airplane-cycles; Cell F uses IMSS writes, not airplane.
- Do not re-chase MBN content, `rat_on`, `ril.subscription.types` or the SIM-toggle trap here.
- Follow the device across ports on the bench (`new2` has a marginal USB link — use a shallow port).

---

## 11. Optional accelerators

- **A second physical Verizon-MVNO SIM** (a cheap US Mobile Warp line): lets silver ride along on
  every drive as a live stock witness and lets bench A/B run without SIM swaps. Single biggest
  speed-up available; Kyle's call on cost.
- Tailscale + TCP adb on `new2` (already on the promotion checklist) so pulls need no bench visit.
- Root silver (Magisk boot via EDL) only if stock-side modem F3 becomes decisive.

---

## 2026-09-15 evening — FIRST LIVE EVIDENCE (new2 on the bench; read-only pulls + recorder armed)

**What the day looked like** (persisted logcat, 08:13→20:30, `captures/new2-emerg-20260914/timeline-day.txt`,
`stretches.txt`): Verizon HOME for **256 min**, NOT on Verizon for **485 min** — 23 loss episodes,
the longest **208 min (17:05→20:30)** and **90 min (10:46→12:16)**, several of 15–25 min. Inside a
loss the cellular side cycles AT&T B17 (EARFCN 5780, emergency camp) → T-Mobile B2 (975/700,
`DENIED` = cause 13) → **Verizon B13 5230 in LIMITED service, camped but not registered** → back.
Wi-Fi calling over `yelppub` carried voice/data through most of it (IMS on IWLAN), so it was
invisible from the couch.

**RSRP says the evening spot is a Verizon hole for this phone:** on Verizon cells the hourly mean
ran −112…−122 dBm (min −126); AT&T 5780 mean −122, T-Mobile 975 mean −116. At the bench at 20:30
Verizon read −112 → −100 and the phone registered within 20 s of being plugged in (20:30:40,
no user action, Wi-Fi still up). ⇒ the 17:05→20:30 stretch is consistent with **RF-limited**
behaviour, not (yet) with a state wedge. This does NOT explain the road/airplane reports, but it
re-ranks the lane: coverage at home is a first-order factor, and the *sticky* question narrows to
"when Verizon comes back to a usable level, how long until the modem notices?"

**Confirmed H1 ingredients on new2** (`nas-probe status` 20:38): `mode_pref = GSM UMTS LTE`,
`usage_preference = 1 (VOICE_CENTRIC)`, `voice_domain_pref = PS_PREFERRED`, `srv_domain_pref =
CS_PS`, automatic selection; framework allowed types = everything (`preferred_network_mode=33`).

**New model to test, H8 — OOS-scan backoff:** after losing Verizon the modem parks on a foreign
cell and re-searches the home PLMN on a backing-off schedule (Qualcomm OOS scan timers; each cycle
also scans GSM quad-band + WCDMA + 6 LTE bands with the current mode mask). The longer the outage,
the sparser the retry, so on the road Verizon can be back at −105 for minutes before the next
search; a power cycle (airplane) restarts acquisition immediately. Fits home (eventually
recovers), road (looks stuck, airplane fixes "immediately") and July Gold. Discriminators:
recorder's RRC PLMN-search records while camped on AT&T (how often, which bands, was 311480 seen
and at what RSRP), attach attempts vs no attempts while camped LIMITED on 5230, and Cells A/B
recovery latency under Global vs LTE-only.

**Side finding:** Wi-Fi dropped at 20:34:12 by itself — framework `NETWORK_SELECTION_DISABLED_DHCP_FAILURE`
on `yelppub` at the bench (IPv6 addresses removed, DHCP renew failed) — and IMS moved IWLAN→LTE in
2 s (feeder down-edge fired, `handleImsRegistered WWAN` at 20:34:15). Separate reliability item:
the daily driver's Wi-Fi safety net can vanish on a DHCP hiccup.

**Recorder armed on new2 (runtime only):** `diag_mdlog` with `Diag-all.cfg`, rotation `-s 150 -n 25`
(files under `/data/local/tmp/cap/`, ~8 MB/min at cell edge, 13 GB free); state sampler
`/data/local/tmp/rec/sampler.sh` (30 s CSV `sample.log`, `nas-probe status` every 2 min → `nas.log`);
logcatd persistence was already on (≈12 h retention at today's rate); `persist.adb.tcp.port=5555`
set (takes effect next reboot). ⚠️ Every adbd restart kills these (`adb root`/`adb tcpip`); a
reboot kills them too — re-arm with the commands in this section. Host-side
`diag-tools/nas-probe/new2-overnight-pull.sh <outdir>` is scheduled for 06:45 (pulls logd chunks,
rec/, cap/); decode with scat + `decode_f3.py`.

**Asks for Kyle:** leave new2 on the bench overnight with Wi-Fi as usual, no airplane toggles; put
the **Pixel 9 next to it** with Wireless debugging on and tell me the port so both can be sampled
at the same spot (registration retention, not just RSRP); still owed: the four recollection
questions about 09-14.

### 2026-09-16 04:30 — overnight result + a diag-tooling lesson
- **Bench spot overnight: zero outages.** 226 `nas-probe` samples 20:48→04:30 all REGISTERED /
  PS-ATTACHED on 311480 LTE (RSRP −102…−112 at the bench). The coverage hole is the evening spot,
  not the house. Wi-Fi re-associated 22:23 and dropped again 22:33 (same DHCP-failure pattern).
- **⚠️ `kill -9` of `diag_mdlog` wedges the kernel diag mux for the rest of the boot:** every capture
  after last night's first hard kill had **zero modem frames** (`f99=0`, only APSS/WCNSS `0x79`),
  the QSR4 GUID list alternated empty/populated, and dmesg shows `diag: In diagfwd_data_read_done,
  unable to write to mux error: -107` + `unable to get hold of response buffer`. This is very
  likely the "modem QShrink is intermittent per-capture" mystery from 08-13 (those scripts also
  used `kill -9`). Rule: **stop with `diag_mdlog -k` only; a wedged mux needs a reboot.**
  Tools: `diag-tools/qmdl_census.py` (frame census, exit 0 only with modem frames),
  `diag-tools/nas-probe/new2-arm-recorder.sh` (re-arm after boot + census), sampler v2 (fields
  fixed — the v1 bug was exporting `LD_LIBRARY_PATH=/vendor/lib64` globally, which broke `dumpsys`
  inside the script; the vendor env is now scoped to the `nas-probe` call) with a 6 GB pruner for
  `/data/local/tmp/cap`.
- Kyle to reboot new2 when convenient; a host watcher re-arms the recorder automatically on the
  next fresh boot. Today = first road day with the recorder (diag + sampler + logcatd); pull in
  the evening with `new2-overnight-pull.sh <outdir>`.

### 2026-09-16 08:00 — recorder LIVE for the first road day (reach: Tailscale)
- Kyle rebooted ~06:39; `new2` is now tailnet **`pvg100-2` = 100.82.14.21**, LAN **10.0.2.123**, TCP adb
  5555 (persist), root on boot ✓. Roster updated (`DAILY=new2`, addresses filled, gold demoted to
  bench); `pepito-adb new2` / `new2-adb` / `daily-adb` resolve it. TCP adb showed "device still
  authorizing" for ~1 min after connect — retry, don't re-pair.
- Recorder re-armed over Tailscale at 08:00 with `new2-arm-recorder.sh` (`NEW2_SERIAL=100.82.14.21:5555`):
  **modem stream verified** (`qmdl_census.py`: f99=7384 f10=1059 in the first 700 KB). Sampler v2
  running (30 s CSV + `nas-probe` every 2 min + 6 GB pruner). Last night's two modem-less diag files
  deleted. Host collector `new2-day-collector.sh` polls every 15 min until 20:30 →
  `captures/new2-road-20260916/{sample.log,nas.log,collector.log}`.
- Evening: `NEW2_SERIAL=<transport> new2-overnight-pull.sh captures/new2-road-20260916-full` (qmdl
  files are large — prefer USB or LAN for that pull), then decode: `scat -t qc -d <qmdl> -F <pcap>`
  for NAS/RRC, `decode_f3.py qdb.dec <qmdl> 'reg_|emm_|sd_|cmregprx|ims_|RegisterManager'` for F3.

### 2026-09-16 08:10–08:28 — FIRST INSTRUMENTED ROAD EPISODE (walk from home; sampler + radio log; modem F3 lost)
Sampler timeline (`captures/new2-road-20260916/live-0828/`): 08:10:22 Wi-Fi lost (left home) → cellular
emergency-only, cycling T-Mobile 975 / AT&T 5780 / **Verizon 5230 LIMITED-camped at −121…−123 (08:18:29,
08:20:00) without registering**; Kyle set Preferred network type = LTE-only ~08:20 (modem `mode_pref` became
0x0010) → **no effect**; 08:25:09 Pixel-hotspot tether → IMS registered over WLAN 08:25:11 → **08:26:17
registered on Verizon 5230 at −123** (same cell, same level as the LIMITED camps) → IMS moved to WWAN 08:26:20
→ RSRP −102 by 08:27:48 (walking). ⚠️ Confounded by motion; but "registered 66 s after IMS came up over WLAN,
at a level it had refused twice" is exactly what H1 (domain-selection veto lifted by IMS availability) predicts.
Also: the framework kept IMS "registered" on the dead IWLAN until 08:22:02 (12 min after Wi-Fi loss).
Kyle does this walk twice a day ⇒ a repeatable field cell. Return walk = next run (no tether for ≥15 min).

**Modem-side proof still missing — two tooling facts learned the hard way:**
1. **Diag-all.cfg kills the modem F3 stream on the road**: the 08:00 session's 57,586 QShrink frames all
   fall in 08:00:30–08:00:40, then nothing (log packets continued until 08:38). The all-SSID F3 flood
   stalls the modem's F3 sub-stream after ~10 s. ⇒ `diag-tools/make_diag_road_cfg.py` → `Diag-road.cfg`
   (F3 for 18 SSIDs: CM 5, SD 15, CMCNas 18, mmoc 20, IMS 51, mcfg 91, policyman 99, EMM 3007, REG 3010,
   ESM 3011, cmapi 4606, ds3g 5000/5005/5025/5026, ML1-sm/bplmn 9500, RRC 9501, ML1-bplmn 9509; log
   packets: 0xB0C0–0xB0FF RRC/NAS OTA + PLMN search, idle/conn meas, QMI link 0x1544–9, IMS SIP 0x156E).
   ⚠️ SSID 9500 also hosts `lte_ml1_sleepmgr_stm.c` (the worst flooder) — if F3 still stalls, drop 9500.
2. **ONE diag session per boot.** Once the first session of a boot ends — kill -9 (last night), `-k`, or
   exiting on its own (08:06:00 today: mux `-107` then init reaped `diag_mdlog` pid 15648 "exited with
   status 0", cause unknown) — every later session gets no modem data until reboot. `new2-arm-recorder.sh`
   now refuses to arm when dmesg already shows `-107`, arms one `Diag-road.cfg -s 100 -n 40` session, and
   checks log packets (`f10`) rather than F3 for health. Kernel follow-up for PLAN-diag: md-session
   teardown leaves the modem peripheral unattached for new sessions.

### 2026-09-16 09:10 — road recorder verified; analysis pipeline ready
- Kyle rebooted at 09:03; adbd came up as shell this time (`adb root` fixed it — costs nothing when nothing
  is armed yet); ONE session armed with `Diag-road.cfg -s 100 -n 40` at 09:07:34; verified on the session's
  own file: modem F3 flowing continuously (per-10 s counts 20–1900, no stall through 09:11), log packets
  present, APSS chatter gone (f79 62 vs thousands). ⚠️ The arm script's census read the OLD file once
  (`ls -t` before the new file existed) — check the file name carries the session's start time.
- Return walk protocol given (no tether ≥15 min; note time; data off/on → manual Verizon → airplane after
  5 min). Kyle keeps the screen awake on a battery bank (does not confound the cellular side).
- `diag-tools/nas-probe/road-analyze.sh <qmdl> [sample.log]` → `<qmdl>.analysis/{nas-rrc.txt,f3-nas.txt,
  timeline.txt}`. Side find: IMS DPL handover thresholds `TH_1 -112 / TH_2 -115 / TH_3 -100` in
  `qpDplHandOver.c` (banked in memory `wfc-wifi-preference-lane`).

### 2026-09-16 09:12–09:37 — return walk (modem F3 + sampler; session alive through the walk and the bench plug-in)
- **No episode.** Left the destination registered on Verizon at −103 and stayed HOME the whole way, riding B66
  (66536) and B13 (5230) down to **−125 dBm (09:31:25) without losing registration**. Contrast with the morning:
  the phone *left home already in the foreign-camp state* (the home hole, WFC masking it) and then needed 16 min
  to get back onto a route where Verizon is −103…−115. ⇒ **the state you leave in decides; a registered modem
  holds down to −125, an unregistered one does not re-register at −121…−123.** Repro rule for the twice-daily
  walk: check the sampler line before leaving; if it shows AT&T/T-Mobile camp (plmn 310410/310260), the
  outbound walk is the test.
- **Arrival home 09:33:46→09:36:14 (short, M2-shaped) with modem-side detail:** Verizon lost 20 s after Wi-Fi
  came up; RRC `CSP: RRC_E911 ACQ CNF` acquisitions (emergency camping), `BPLMN_MGR: PO is active` background
  PLMN-search windows every ~0.6 s, `reg_state.c: Backoff plmn Search Timer expired` + `BACKOFF PLMN LIST
  (length = 0)` + `CM_FPLMN_LIST_IND` (FPLMN list_size=4) at 09:35:16, Verizon re-acquired and registered at
  −116 at 09:36:14. The AT&T `DENIED rejectCause=13` the framework reported at 09:33:54 came with **no NAS
  activity** (0 EMM OTA packets, 0 EMM F3) — it is the modem's *cached* forbidden-TA state from the morning,
  not a new attempt. Tooling verdict: the road mask delivers RRC OTA (`0xB0C0/0xB0C1`), REG/CM/SD/RRC/IMS F3
  and QMI-link logs; NAS OTA will appear when NAS procedures actually occur.
- ⚠️ Mask still admits the `lte_ml1_*` flood (SSID 9500: `sleepmgr` 30k lines; 9509: rfmgr/dlm) — ~1 MB/min at
  cell edge, sustained, no stall, acceptable for 24 h with `-s 100 -n 40`. Drop 9500 only if volume bites.
- Kyle set Preferred network type = LTE-only during the morning episode; it is still in force (modem
  `mode_pref 0x10`). Leave it — tomorrow's outbound walk under LTE-only from the start is informative either way.

**Tonight (phone at home, reachable over LAN/Tailscale, WFC masking):** when the sampler shows a foreign camp
> 10 min, run the rung ladder remotely with the recorder live (n=3 each, ≥15 min apart):
(a) snapshot (`nas-probe status`, `imsa-probe`, `dsd-probe`); (b) `imss-probe setmsg 0x21 0x12 1` → 10 s →
`… 0` (IMS re-kick, no radio cycle); (c) `nas-probe radiocycle --yes-touch-nas` (DMS LPM→ONLINE = what airplane
does). Recovery to REGISTERED 311480 within ~60 s after (b) or (c) at the same RSRP where it had camped foreign
⇒ state, not RF; which rung works ⇒ the watchdog's action. Neither rung touches adbd, so the diag session lives.
**Tomorrow morning:** outbound walk = the H1 repro with modem F3 (do not tether for 15 min; ladder after 5 min).

### ⭐⭐⭐ 2026-09-16 14:10 — RUNG LADDER RUN LIVE IN THE STUCK STATE: radio cycle = 15 s recovery, IMS re-kick = nothing
Home, Wi-Fi ON, IMS registered over IWLAN (`voip_service_rat=0`), cellular `REGISTRATION DENIED` on T-Mobile
310260 / LIMITED for ≥ 2 min (so a Wi-Fi/IWLAN transition does NOT always un-stick it — it had earlier today
at 12:33, 13:00 and 13:13). Remote ladder over LAN (`diag-tools/nas-probe/new2-rung.sh`, log
`rec/rung.log`), diag session pid alive but its file stopped growing at 12:34 (see below):
- **Rung B — IMS re-kick** (`imss-probe setmsg 0x21 0x12 1` → 8 s → `0`): no effect in 90 s. Cellular drifted
  T-Mobile DENIED → AT&T SEARCHING, never Verizon. (Caveat: IMS stayed "registered" over WLAN throughout —
  8 s may be too short to deregister; retry with 30 s next time.)
- **Rung C — `nas-probe radiocycle` (DMS LPM→ONLINE)**: **REGISTERED 311480 LTE FULL SERVICE within 15 s**
  (14:12:36 → 14:12:54) and held for the whole 2-min watch. Same spot, same minute, same RF.
⇒ **The stuck state is modem-internal, not coverage** (n=1; tonight n≥3). A DMS radio cycle is the proven
un-stick action for the watchdog (F3); the IMS re-kick is not. The morning's "Wi-Fi tether fixed it" was a
weaker version of the same kick (a DSD/IWLAN transition), not RF.
(My script's final "NOT RECOVERED" line was its own grep bug — fixed in `new2-rung.sh`.)

**Kyle's new protocol (good):** at home, when it shows emergency-only, do NOT open Wi-Fi settings (that forces
a scan/reconnect and often kicks it); **plug it into USB** instead — plug-in does not kill the diag session
and gives bench access without the IWLAN confound.

### ⭐⭐ 2026-09-16 15:30 — Kyle's Tailscale-DNS finding pulls in the framework's data-stall recovery (DSRM)
Kyle (separate session): with Tailscale on, its injected resolver does not work on 4G, so DNS is broken on
cellular. The persisted logs show the consequence: `NetworkMonitor` validation probes on the cellular network
fail with `UnknownHostException` (07:44–08:11 today, every 1–4 min), `DSRM-0` declares a data stall, and
escalates: **RECOVERY_ACTION_CLEANUP ×9 (07:55→08:18, tearing the data call down and up every ~3 min),
then RADIO_RESTART chosen at 08:20:17, 08:23:46, 08:26:23**, ended `RECOVERED_REASON_USER` when the tether
came up. Over 09-15/16 the framework chose GET_DATA_CALL_LIST ×51, CLEANUP ×17, RADIO_RESTART ×6,
RESET_MODEM ×2; most were skipped ("skip data stall recovery as in poor signal condition"), but **on 09-15
12:59:25 a DSRM RADIO_RESTART really executed (RILJ RADIO_POWER false→true) and it ended the 12:35→12:59
24-min sticky episode** — the second confirmation, framework-initiated this time, that a radio cycle
un-sticks it (n=2 with my 14:12 radiocycle; plus every airplane toggle Kyle has done).
Consequences:
1. **Confound/trigger:** DSRM churn (PDN teardown, radio restarts) is an AP-side source of radio events at
   cell edge; with Tailscale DNS broken it fires constantly. Fix the resolver (Kyle: Tailscale "Use
   Tailscale DNS"/MagicDNS off on new2) before judging episode counts. On 09-15 (no Tailscale) the
   validation failures were genuine no-data periods, so the sticky state itself predates this.
2. **Hardening item (F6):** DSRM `RECOVERY_ACTION_RESET_MODEM` = a modem reset — on pepito modem restarts
   wedge MSS (memory `radio-rmts-buffer-rootcause`). Carrier-config the DSRM action skip list for pepito
   (`data_stall_recovery_should_skip_bool_array`: skip RESET_MODEM at least; consider keeping RADIO_RESTART
   since it is exactly the un-stick action — or replace DSRM's role with our own watchdog that triggers on
   registration state, not on DNS).
3. The recoveries at 12:34 / 13:03 / 13:13 today were NOT DSRM radio restarts (no RADIO_POWER requests) —
   they were the Wi-Fi/IWLAN transition kicks Kyle observed.

### ⭐⭐ 2026-09-16 16:00–17:00 — the 12:19 episode read from the modem side; three corrections
Session 09:08→12:35 (modem stream alive until 12:35:16), decoded with `road-analyze.sh`:
1. **Losing Verizon at 12:20:13 → the modem never tried Verizon's real frequencies again for 13 min.** It ran
   one system scan at 12:21:05 (`CSP: Prioritize System scan results for Req PLMN` → `PLMN not found` ×3 →
   `4 frequencies prioritized for NAS requested PLMNs`), tried **band-5 EARFCNs 2538/2483/2482/2579 from its
   acquisition DB — all failed**, then band-2 candidates (906/1069 at 12:23, 952/953 at 12:24), camped on a
   foreign cell at 12:31, and did only neighbour-based BPLMN searches on 5780 (AT&T PCI 444/265 at −120) —
   **5230 (B13) and 66536 (B66) were not attempted at all.** Meanwhile ESM retransmitted a PDN CONNECTIVITY
   REQUEST (msg 208, T3482) until 12:23:33 (`MM_CM_PDN_CONNECTIVITY_REJECT_IND`, lower-layer failure) — the
   AP's data-stall CLEANUP asking for a PDN the modem could not deliver.
2. **The "opening Wi-Fi settings brings it back" recoveries at 12:34 (and likely 13:03/13:13) were NOT
   registrations.** At 12:34:07 an `LTE RRC M_BST Update Ind num_plmn:2` arrived (a band-scan-table update
   right after Wi-Fi/IWLAN came up), the modem re-read AT&T's SIB1, then at 12:34:30 "Starting acquisition on
   next freq" and camped on Verizon 5230 (`qpDcm … Cell-Identity 15363, TAC 15`) at −127…−110 — **but stayed
   `srv_status=1 LIMITED`; the 2-min probe said DENIED-on-T-Mobile at 12:33 and 12:37.** The sampler's
   `v=0 d=0 em=false plmn=311480` was the IWLAN-merged framework state masking a limited camp. Only 08:26
   (tether) and 13:03 (Wi-Fi off, `drat=LTE d=0`) were real registrations. ⇒ sampler v4 now logs the modem's
   own `reg=/plmn=/lte=` per sample; never judge registration from the framework fields while IWLAN is up.
3. **Modem-camped-on-Verizon-but-not-registering has no reject behind it:** the three probes camped on 311480
   LIMITED (08:01, 08:18, 08:20) read `NOT_REGISTERED, SEARCHING`, PS DETACHED, `is_forbidden=0`, and there is
   no Attach/TAU on the air in those windows; the framework's 24 `rejectCause=13 … mMcc=311 mMnc=480` lines
   (09:35:19) are the cached AT&T denial reported against the currently camped Verizon cell (no EMM
   activity at that moment). So the veto is not a network reject; it is the modem declining/failing to
   register on an "acceptable but not suitable" cell (S-criterion at −120…−127, q-RxLevMin −126 in SIB1),
   and then **not re-searching the home frequencies** once camped foreign. A DMS radio cycle forces a full
   acquisition that finds 5230/66536 at −116…−121 and attaches (14:12 today, 12:59 yesterday via DSRM).
4. **Bench event 16:45 (USB, −108):** registered on 5230 at 16:45:16, deregistered 6 s later (`hasDeregistered
   hasDataDetached`), DENIED on T-Mobile, camped 5230 LIMITED at 16:46:38, registered again by 16:47:33 and
   held. The 6-s detach at −108 is the next thing to read with modem F3 (network detach? ESM failure?).
5. **Diag stream stalls = AP suspend.** Both stalls (08:06:00, 12:35:16) happened while the phone was asleep;
   at 12:35 the suspend service was retrying every 7.5 s ("Unknown/empty wakeup reason"). Arm script now
   passes `-e` (wake lock) — costs battery, fine on the bank/bench; the "one session per boot" rule stands.

### 2026-09-16 17:40 — overnight automation armed (new2 at home, LAN-reachable)
- Rebooted ~17:20 (root-on-boot raced again → `adb root` by hand; arm script now self-roots). ONE diag session
  since 17:38:35 with `-e` (wake lock held: `diag_mdlog_wakelock`), road mask, modem frames verified
  (f99=12.5k/f10=701 in the first 3 MB). Sampler v4 logs `MODEM reg= plmn= lte=` per 30 s (the truth field).
- Host loops (scratchpad, banked copies in `diag-tools/nas-probe/`): `new2-recorder-watch.sh` arms whenever no
  logger runs (24 h); `new2-auto-ladder.sh` reads the MODEM field every minute and, after ≥10 min off Verizon
  with no active call, runs `rec/rung.sh` (IMS re-kick now 30 s, then `radiocycle`), cooldown 20 min, max 8
  runs, until 07:30 → `captures/new2-road-20260916-full/auto-ladder.log`. Each run = one more (state vs RF)
  data point with modem F3 alive. Morning: `new2-overnight-pull.sh`, then `road-analyze.sh` on the session
  file(s) around each ladder timestamp — the questions: why no attach while camped on 5230 (S-criterion? REG
  backoff?), what the 16:45 six-second detach was, and what the radiocycle changes in CSP/REG.

---

## ⭐ CHECKPOINT 2026-09-17 09:00 — where the root cause stands after two instrumented days

**The sticky state, as observed from the modem (n=2 direct, many indirect):** after losing Verizon at cell
edge the modem enters LIMITED service, runs ONE system scan plus a handful of acquisition-DB candidates
(band 5/2 entries from the road, not the home band-13/66 cells), camps on the loudest foreign cell
(AT&T/T-Mobile, DENIED cause 13), and from then on only does neighbour-based background PLMN searches on
that cell's band. It can also camp on Verizon's own cell at −120…−127 as "acceptable" without attaching.
Nothing rejects it; it simply never re-runs a full acquisition. **A DMS radio cycle (`nas-probe radiocycle`,
a framework RADIO_RESTART, or airplane) forces a full acquisition and it registers within 15 s at the same
level** (14:12 manual; 19:51/20:04 and 12:59 framework-initiated; every airplane toggle Kyle has done).
An IMS re-kick does nothing. Wi-Fi/IWLAN transitions sometimes trigger a re-search (a band-scan-table
update arrived right after the 12:33 association) but mostly only produce a LIMITED camp that the
framework's merged state disguises as service.

**Triggers seen:** genuine RF loss at the home evening spot (Verizon −115…−127 there); leaving home while
already foreign-camped (the 08:10 walk); and **the framework's own data-stall radio restarts** (DSRM, fed by
validation failures = Tailscale's resolver on cellular), each of which is a coin flip at cell edge
(19:51:48 restart → 12 min on AT&T; 20:04:02 restart → back on Verizon).

**Falsified or demoted:** LTE-only mode (episodes continue under it); the IMS-veto reading of "IMS
availability un-sticks it" (the tether case was a search trigger, the 14:10 case shows IMS on IWLAN with
the cellular side still stuck); a network reject on Verizon (none on the air; the 311480 cause-13 lines are
cached AT&T denials); "opening Wi-Fi settings fixes it" (usually a limited camp under IWLAN).

**Open:** whether stock's modem behaves identically at the same spot (two-device test still owed — silver
with the SIM at the evening spot for one evening, `dumpsys` polling, no root needed); the 6-second
register→detach at −108 on the bench (16:45); a reliable multi-hour modem log session (three death modes so
far: AP suspend ×2, unexplained-with-wakelock ×1 — the 3.5-h good session was road mask, no `-s/-n`, no
`-e`, screen mostly on).

### F3 watchdog — concrete spec (ready to build when Kyle says go)
- Vendor daemon `qmux_reg_watchdog` in the qmux domain (same skeleton/sepolicy shape as `wfc_wlan_bridge`):
  QMI NAS client (force-ipcr), subscribes to `SYS_INFO_IND`/`SERVING_SYSTEM_IND`, polls every 15 s as backup.
- Condition: SIM present (UIM app READY), DMS opmode ONLINE (not airplane/LPM), no voice call, and for
  ≥ 90 s continuously: LTE `srv_status` ∈ {NO_SRV, LIMITED, LIMITED_REGIONAL} **or** registered on a PLMN
  ≠ home (311480) in limited/denied state.
- Action: DMS `SET_OPERATING_MODE` LPM → wait 2 s → ONLINE (byte-identical to `nas-probe radiocycle`).
- Back-off: 90 s → 3 min → 6 min → 15 min cap while the condition persists (true coverage holes must not
  churn the battery); reset on FULL service; never within 60 s of a previous cycle; skip while
  `mCallState≠0` (read via `dumpsys telephony.registry` is not available to a vendor daemon → use QMI VOICE
  call-status or the `vendor.qmux.*` prop the framework can set; simplest: NAS `GET_SYS_INFO` + DMS + a
  `voice.call_active` check via QMI VOICE 0x2E GET_ALL_CALL_INFO).
- Logging: one logcat line per decision with srv_status/PLMN/RSRP before and after; status prop
  `vendor.qmux.reg_watchdog` = idle|armed|cycled:<n>.
- Validation: sampler v4 + `auto-ladder.log` style counts on new2 for 3 evenings (expect: no off-Verizon
  stretch > ~2 min while a Verizon cell ≥ −124 exists), then a road week; the bench Cell A (foil) as the
  regression test. Ship behind `TARGET_DEVICE_PEPITO`, default on, `persist.vendor.qmux.reg_watchdog=0`
  opt-out.
- Companion (F6): pepito carrier-config skip list for DSRM `RESET_MODEM` (+ `RADIO_RESTART` once the
  watchdog exists), and the Tailscale DNS fix on the phone.

### 2026-09-17 09:10 — watchdog prototype moves ON-DEVICE (Kyle suspends the netbook overnight)
`diag-tools/nas-probe/new2-sampler.sh` v5: after 20 consecutive 30-s samples (10 min) with the modem off
Verizon and `mCallState=0`, it runs `nas-probe radiocycle` itself, logs before/after to `rec/watchdog.log`
(6 × 10 s follow-up probes), cools down 20 min, max 12 per boot. This is F3 in shell form: the phone
self-heals ≤ 10 min after a stick from today on, while every stick is still counted and (when the diag
session is alive) captured. Pushed automatically when new2 is next reachable (`push-v5.sh`). Later: lower the
threshold toward 90 s once the count/battery trade-off is seen; then the real daemon.

### 2026-09-17 09:20 — agreed protocol for the next two evenings (Kyle: Tailscale DNS now OFF on new2)
**Tonight, part 1 (new2, SIM in):** Wi-Fi OFF on new2 at the home evening spot, Tailscale DNS off, sampler v5
with the 10-min watchdog ON. Measures the unmasked stick rate and the watchdog's recoveries (`rec/sample.log`,
`rec/watchdog.log`). Modem logger: needs the reboot (still pending at 09:20; uptime 57k s) — the watcher arms it.
**Tonight, part 2 (silver, SIM in):** move the SIM to silver (stock A8 `v1AML-0`, unrooted), Wi-Fi OFF, place it at
the same spot for ≥ 2 h; `diag-tools/nas-probe/silver-sampler.sh` is installed and running on silver (one line /
30 s: reg states, operator numerics, emergency-only, RAT, SignalStrength, CellIdentity → `/data/local/tmp/
silver-sample.log`, pull over USB). Compare stick count and durations at the same spot and hour. Stock sticks
too ⇒ modem behaviour, watchdog is the fix and stock users have it as well; stock recovers in ≤ 2 min ⇒ our stack
worsens the modem's search (IWLAN/DSD state, DSRM, mode) and the diff continues.
**Tomorrow:** the Wi-Fi-off day on new2 (unmasked field counts + watchdog log), Tailscale DNS off.

### 2026-09-17 12:00 — first Wi-Fi-off morning: a 73-min hole at the destination, and two Tailscale side-effects
- **09:48:31 loss = plain RF** (modem-triggered deregistration, no serving cell, no radio power event, no DSRM
  action; −117 dBm at 09:46 walking in). Then until 11:01:47 the modem alternated short AT&T camps, two LIMITED
  camps on 5230, and long `srv_status=4 POWER_SAVE` stretches (OOS deep sleep between scans — the H8 cadence made
  visible; 10:20→10:43 = 23 min asleep). The on-device watchdog fired 4× (09:58, 10:18, 10:39, 10:59); the first
  three came back to searching/power-save within a minute (no usable Verizon cell there), the fourth was followed
  by registration at 11:01:47 as Kyle left. ⇒ likely a genuine indoor hole; the modem capture (session 09:22, alive
  all morning) will show whether any Verizon cell was ever seen. Sampler v5 worked as designed.
- **Tailscale floods the log when the phone has no network:** `com.tailscale.ipn` (uid 10204) writes ~270 lines/s
  (`gojni: IPNService.bindSocketToNetwork returned false`, `App: bindSocketToActiveNetwork: no cached default
  network`) → the persisted logcat rolls 2 MB/min and retention drops to ~an hour; it is also CPU spin during
  every outage (battery). Mitigation options: Tailscale on only when remote access is needed; or `logcat -P '~10204'`
  to prune its lines first in the rings. Combined with the DNS-override churn (fixed 09-17), Tailscale is the
  worst-behaved passenger on this phone during outages.
- Diag pulls over the Tailscale relay are unreliable for >5 MB (two failed transfers) — pull over LAN/USB.

### 2026-09-17 12:20 — the 09:48→11:01 stretch read from the modem: a TRUE HOLE, and what a hole looks like vs a stick
Full session file (09:19→12:00, no gaps; `captures/new2-road-20260917/cap/session-0922-full.qmdl`):
- 09:49:11 `srv_status=0`; acquisition attempts 09:48–09:56 on B2 (743/681/754/1130), B5 (2503/2625/2531/2530/
  2617/2529) and B66 (66956) all failed; **no search reported any cell for the whole hour** (only T-Mobile 975
  succeeded once at 10:11:35, AT&T 5780 at −132 per the sampler). Then the SD out-of-service machinery: `sdss.c
  =SD= Ignore pwr_save timeout thrttl` every 37 s → 52 s → 67 s (the OOS scan cadence backing off), `cmss.c
  Handling internal pwr save / Set PWR_SAVE info` (10:13, 10:17), `reg_mode.c HPMLN to be given priority in
  OOS/Power up - 0`, occasional `BPLMN SRCH: Triggering system scan on 975/1100/5780` and band-5 searches.
  **5230 (B13) was never in the OOS scan list** — irrelevant here (nothing receivable indoors) but consistent with
  the home stick pattern.
- Watchdog cycles 1–3 (09:58, 10:18, 10:39): full acquisition after LPM→ONLINE found nothing. Cycle 4 (10:59:42):
  `REG: CM_SERVICE_REQ - AUTOMATIC`, `MMR_REG_REQ PLMN(311-480) RAT(LTE)`, `REG_STATE_REGISTERING`, EMM attach at
  11:01:17 → registered 11:01:47 (Kyle leaving the building). Framework side: 09:48:31 modem-triggered
  deregistration, no serving cell, no RADIO_POWER, no DSRM action ⇒ **plain RF loss**.
**Discriminator for the field logs:** a *hole* shows `srv_status` 0/4, `Ignore pwr_save timeout` cadence and no
cells found; a *stick* shows `srv_status=1 LIMITED` on a foreign PLMN (or 5230 itself) with cells at −116…−125
being measured and no home-PLMN acquisition attempts. Only the stick is fixable by the radio cycle; in a hole the
watchdog just burns ~15 s of radio per cycle (back-off matters).

### ⭐⭐ 2026-09-17 14:00 — bench stick reproduced on USB with modem F3; the key question is now cause-13-on-311480
The home/bench spot (Wi-Fi off) produced a ~30-min episode 13:26→~13:57, modem logging alive, and it self-recovered
(reg=1 by 13:57, then 8 stable samples). What the modem did:
- **It DOES attach, repeatedly.** EMM `Start attach procedure … Start timer T3410`, `Sent LTE_RRC_CONN_EST_REQ w/
  cause 3`, `Building ConnectionRequest` at 13:27:01, 13:27:23, 13:28:46, 13:31:46 — but **no CONN_SETUP /
  ATTACH_ACCEPT ever follows**; each ends REG_STATE_IDLE / `Backoff plmn Search Timer expired`. So the attach
  fails to complete, not "never attempted."
- **RSRP was −123 for almost the whole episode** (one −99 blip at 13:46), and it camped/attach-looped on 5230.
  So this episode is at least partly **marginal-signal-limited**: RRC connection (RACH) failing at −123 is the
  most likely reason CONN_EST never completes. (Confirm with the NAS/ML1 OTA: T300/RACH vs a decoded reject.)
- ⭐ **`rejectCause=13` appears on `mMcc=311 mMnc=480` — Verizon's OWN PLMN — during the episode** (93 framework
  lines 13:52-13:54), alongside a modem forbidden-TA entry `RRC F TA (Roaming) PLMN 310-410 TAC 37133`. Cause 13 =
  "roaming not allowed in this TA." **BUT the modem F3 shows attaches timing out (T3410), not a decoded
  ATTACH_REJECT**, so it is unresolved whether the cause-13-on-480 is a FRESH network reject (→ subscription/TA
  issue, not our stack, possibly a real VZW behaviour) or STALE cause resurfaced on each registry poll. **This is
  now the single most important open question** — it changes the whole diagnosis.
- **Live rungs while stuck, both FALSIFIED as fixes here:** `nas-probe attach` (PS_ATTACH) → `error=3`
  (CM veto, as in July); `usage_preference=2` (data-centric) → still SEARCHING after 90 s. So neither the
  domain-selection veto nor usage-setting is the lever in this RF condition. Watchdog run 5 (radiocycle 13:36)
  also did not recover it within 40 s — unlike yesterday's clean −108 cases. ⇒ at −123 the radio cycle can't help
  because there is no completable cell; the watchdog must back off in that regime (already designed to).

**⇒ Two components now clearly separated:** (1) RF-limited episodes at −120…−127 spots (home evening/bench,
this morning's indoor destination) where nothing AP-side can register because RRC won't complete — only better RF
or the network helps; (2) the true STICK (yesterday −108, registered-level signal, LIMITED-camped, radiocycle
fixes in 15 s). Distinguishing them per-episode = the hole/stick discriminator (srv_status + cells + RSRP).
**The decisive experiment is unchanged and now ready: silver (stock A8) with the SIM at the SAME spot** — if
stock also fails at −123 with cause-13, it is RF/network, not our ROM; if stock registers where ours sticks, our
stack. Second decisive item: **decode the NAS OTA** (scat, `0xB0EC/ED` EMM) from `session-0922` to read whether
the cause-13 is a real ATTACH/TAU REJECT and its exact cause — needs the ML1/NAS-OTA mask items (add to Diag-road.cfg).

### ⭐⭐⭐ 2026-09-18 — CAGE (Faraday) bench method + the key synthesis: the STICK needs a loud competing carrier, which the bench lacks
Kyle's Altoids-tin/foil idea, run on new2 (SIM back in, Wi-Fi on, recorder live). ⚠️ A tethered phone can't be
caged — the USB cable conducts RF in (confirmed: modem read FULL SERVICE in a lidded metal cup on USB). Must go
cable-free (foil wrap / sealed cup).
- **Cage-1 (~30-40 s sealed, 09:57):** dropped to OOS, recovered in <30 s straight onto Verizon B66 at −116, no
  foreign camp.
- **Cage-2 (12 min sealed, 10:21:38→10:33:50):** during the seal it cycled searching↔POWER_SAVE (normal OOS);
  on open it recovered in **~30 s onto Verizon B66 at −121**, no AT&T/T-Mobile detour. **Even a 12-min armed cut
  recovers clean at the bench.** (Modem F3 of the recovery lost: diag_mdlog rotated a new file at 10:33:17 that
  came up modem-less — the one-session-per-boot fragility again; sampler is the source here.)
- ⭐ **Synthesis:** the bench is **Verizon-dominant** — when RF returns, Verizon B13/B66 is the best cell, so the
  modem re-registers on it every time, fast, regardless of dwell. The **stick does NOT reproduce here.** Contrast
  the 09-17 afternoon bench episode (stuck 30 min) — that happened only when it dipped to −126 **and AT&T 5780 /
  T-Mobile 975 were present and louder than Verizon**. ⇒ **The stick is a FOREIGN-CELL-CAMP phenomenon:** on OOS
  recovery, if a competing carrier (AT&T/T-Mobile, cause-13) is louder than a marginal Verizon, the modem camps
  it and does neighbour-only search instead of returning to Verizon; a full acquisition (radio cycle / airplane)
  breaks it. It needs (a) marginal Verizon on restore AND (b) a loud foreign cell — the road/destination, not the
  Verizon-dominant bench. The cage cut isolates the *clean-recovery* half, not the stick.
- ⇒ **Two bench-testable conclusions:** the cage is good for "does it return to Verizon on a clean cut" (yes,
  fast) but cannot reproduce the foreign-camp stick. Reproducing the stick needs a foreign-cell-rich location.

## ⭐ DECISION POINT (2026-09-18) — enough is known to act
**Mechanism (best current model):** two overlapping causes — (1) RF-limited: at −120…−127 RRC/attach can't
complete (any phone struggles); (2) the STICK: foreign-cell camp (cause-13 AT&T/T-Mobile) during OOS recovery
when Verizon is marginal and a competitor is louder, from which the modem doesn't self-return promptly. Radio
cycle / airplane forces a full acquisition and fixes it in ~15 s. IMS-rekick, usage-setting, LTE-only: all
falsified as fixes. Silver (stock) held Verizon through the same walk to −121 (more robust, but didn't hit −127;
not a knockout). DSRM data-stall churn (Tailscale DNS, now off) was an aggravator.
**Two honest paths — Kyle's call:**
- **A. Ship the mitigation (practical fix, ready to build):** the `qmux_reg_watchdog` daemon (spec in the
  2026-09-17 checkpoint) — NAS sys-info, when SIM present + radio ON + no call + limited/foreign/OOS >90 s, do a
  DMS LPM→ONLINE; back off 90 s→15 min so it can't churn a true hole; ship pepito-gated, default on. The shell
  prototype (sampler v5) already caps sticks at ~10 min on-device today. Building the daemon lowers that to ~90 s
  and removes the shell dependency.
- **B. Nail root cause first:** two decisive tests — (i) silver (stock) at the **foreign-cell-rich destination**
  (the indoor spot), does stock also camp foreign/cause-13 or return to Verizon; (ii) decode the **NAS OTA**
  (scat, EMM 0xB0EC/ED) from a real stick to read whether the cause-13 is a genuine network reject (→ possible
  subscription/TA issue, carrier-side) or the modem's own reselection. Needs a reliable modem capture (fix the
  rotation-to-modem-less first) and/or silver rooted for native diag.
**Recommendation:** do both in parallel — build the watchdog (it helps regardless of which root cause), and run
test B(i) on the next trip since it needs no build. B(ii) when a modem capture survives an episode.

### ⭐⭐⭐ 2026-09-18 11:37 — KEY REFRAME (Kyle's observation, proven live): at HOME the "fix" is Wi-Fi calling masking the cellular stick, not cellular recovery
Kyle: "airplane finds Verizon right away, but toggling Wi-Fi does the same thing — makes me think IMS is involved.
Right now it says Verizon no connection with cell on / Wi-Fi off; toggle Wi-Fi on and the no-connection clears
immediately." Proven with the modem truth at a live home stuck-spot (Verizon −121 present but too weak; AT&T −114 /
T-Mobile −118 stronger but forbidden cause-13):
- **CELLULAR modem: reg=2 SEARCHING on AT&T (310410), LIMITED — STILL STUCK, never recovered to Verizon.**
- **IMS: registered, voip_service_rat=0 (WLAN), SMS full service over WLAN; framework net=IWLAN.**
⇒ The UI "service" is 100% Wi-Fi calling; the cellular modem is still stuck underneath. **Toggling Wi-Fi (or
airplane, which also brings Wi-Fi calling back) clears the "no connection" by restoring IWLAN, NOT by fixing
cellular.** This is why "Wi-Fi toggle == airplane toggle" at home.

**What this means for the whole lane:**
1. **At home (Wi-Fi present), the stick is largely COSMETIC / covered** — Wi-Fi calling carries voice+SMS+data
   whenever Wi-Fi is on. "Emergency calls only" only shows at home when Wi-Fi is off or IMS isn't on IWLAN yet.
2. **The ROAD case (no Wi-Fi) is the real reliability problem.** There, airplane genuinely re-registers cellular
   — and Kyle's "airplane fixes it immediately" testimony means **Verizon IS usable on the road when it sticks**,
   i.e. the modem was parked on a forbidden competitor while a usable Verizon existed → the radio-cycle/watchdog
   fix DOES apply there (matches the −108 15-s recovery).
3. **Home marginal spots (Verizon −121, unusable) are NOT watchdog-fixable** — but they don't need to be, Wi-Fi
   calling covers them. Radio cycle correctly can't help there (no completable Verizon); that's fine.
4. ⭐ **The watchdog must key off the CELLULAR modem registration (nas-probe reg/plmn), never the framework voice
   state or `mIsEmergencyOnly`** — IWLAN masks those. The sampler-v5 prototype already does (MODEM field).

**Revised conclusion / recommendation:** the practical fix is still the `qmux_reg_watchdog` (radio cycle when the
CELLULAR modem is stuck on foreign/limited >90 s with SIM+radio-on+no-call, backoff), because it targets exactly
the road case where it matters and where Verizon is usable. It won't (and needn't) fix truly-weak-Verizon home
spots, which Wi-Fi calling already covers. Root-cause "why does auto-mode park on a forbidden stronger competitor
instead of a usable weaker Verizon" remains the modem's reselection policy (hard to change); the watchdog sidesteps
it. Silver-at-a-foreign-rich-spot and the NAS-OTA reject-cause decode remain optional deepening, not blockers.

### ⭐⭐⭐⭐ 2026-09-18 12:25 — TWO-DEVICE CONTROL AT THE SAME SPOT: stock HOLDS Verizon where our stack STICKS ⇒ it's our AP stack, not the modem/RF
Kyle put the SIM in silver (stock A8 `v1AML-0`, unrooted, Wi-Fi OFF) at the SAME home stuck-spot that reliably
sticks new2. **Silver could not be made to stick — it held Verizon throughout.** Log `captures/silver-spot-20260918/`:
- 121 samples 11:49→12:24, **0 non-in-service / 0 emergency-only / 0 foreign-camp**. Held voice+data IN_SERVICE.
- **RSRP reached −125** (dist: −105…−125; 42 samples ≤ −120, incl. −122×12, −123×4, −124, −125). So silver
  **experienced the same weak Verizon (−120…−125) that sticks new2** and held.
- **RAT = 14 (LTE) on ALL 121 samples, including every ≤ −120 sample** ⇒ it held on LTE, did NOT rescue itself
  via 3G. Kills the "silver's stock mode-9 (LTE/G/W) vs new2 LTE-only" confound.
Contrast: new2 at this spot = reg 2/3 SEARCHING/DENIED, camped forbidden AT&T(−114)/T-Mobile(−118), stuck; a
radiocycle just hopped competitors (Verizon −121 not completable at that instant).
**Same modem firmware image across pepito units + same SIM + same spot + overlapping RSRP + same LTE RAT, yet
stock holds and ours abandons Verizon for a forbidden stronger competitor.** ⇒ **The stick is our AP stack's LTE
reselection / NAS behavior, NOT the modem, NOT RF/coverage, NOT signal depth.** Since the modem image is identical,
the difference is what each AP stack *programs/drives* into the modem (system-selection / reselection / NAS).
⚠️ Caveats (honest): n=1 spot, one session each; different physical body (but silver hit −125 and held, so not a
mere antenna edge); not simultaneous (one SIM); finicky positioning. Worth ONE confirmation (repeat at this spot
or a second spot) before treating as bedrock — but it is strong.

**⇒ THE CONCLUSION FLIPS TOWARD A CURE, not just a mask.** A real fix likely exists: make our stack hold weak
Verizon like stock does. Cure-hunt (new lane, ties to [[attach-domain-selection]] / two-device methodology):
- The modem is identical, so diff what the **AP** applies: NAS system-selection-preference, **cell-reselection
  thresholds/hysteresis** (Qrxlevmin, s-nonintrasearch, threshServing/threshX-high/low — SIB-driven but the UE's
  reselection/RLF behavior + `qcril`/NAS knobs differ), FPLMN/forbidden handling, and whether our A15-nightly
  qcril drives reselection more aggressively than stock A8 rild.
- Read stock's behavior: silver is unrooted (no diag/NV read). To compare NV/reselection config we'd need silver
  rooted (Magisk boot via EDL, banked) for `diag_mdlog` + EFS reads, OR infer from a rooted stock-on-c39a6acf
  (the July A11-GSI-on-stack approach). 
- Cheap first look on OUR side: capture new2's modem F3 at the spot (reg/reselection/`sd_ss`/`cmss` reselection
  decisions) to see WHY it abandons Verizon — needs a working (non-modem-less) logger.
**Watchdog: still worth building as the safety net (recovers the road case), but it's now Plan B behind the cure.**

### ⭐⭐⭐⭐ 2026-09-18 17:45 — stock CLINGS to Verizon to −140 and recovers <30 s (Kyle, live at the spot)
Second silver run (stock A8, SIM, Wi-Fi off, at the exact spot). Kyle watched it live: **silver held Verizon
down to −140 dBm before letting go, and recovered in <30 s after a couple minutes in the dead zone.** (Full modem
F3 of this run deferred — first attempt filled the file in 90 s on the all-SSID mask before reaching the spot;
now re-armed with the trimmed `Diag-road.cfg` + `-s 100 -n 20` rotation, verified to capture the reselection
sources at a sustainable rate; capture running on silver, pull whenever it's next on USB.)
**Quantifies the stack gap:** stock clings to Verizon to ~−140 (LTE floor) and recovers fast; **new2/our stack
abandons Verizon at ~−121…−126 — ~15–20 dB earlier — and reselects to the stronger FORBIDDEN competitor (AT&T
5780 / T-Mobile 975, cause-13) and STICKS.** Same modem image, same SIM, same spot. This is now a firm,
quantified behavioral difference, not a one-off.
⇒ **Root cause (confirmed): our AP telephony stack releases/​reselects off weak-but-usable Verizon far too
eagerly and lets the modem camp a forbidden stronger cell.** The cure is to make our stack cling like stock (raise
the release/reselection tolerance and/or stop it parking on a forbidden PLMN). The deferred F3 diff (silver holds
vs new2 abandons) will name the exact knob; the behavioral conclusion no longer depends on it.
Open, at Kyle's pace: pull silver's road-mask capture when next on USB (may already hold a good spot trace);
capture new2's F3 at the spot (clean logger); then the cure. No code yet (Kyle: hold off, no rush).

---

## 12. Next actions (ordered)

1. `new2` on USB: run the evidence pull, then §3.2–3.5 (mode in force, promotion props).
2. Kyle: answer the four recollection questions in §3 when convenient.
3. Bench: **Cell F on `dut1`** (SIM needed — schedule an evening/weekend window), then Cell B and
   Cell C; write the results into this file per cell.
4. Build the road mask + sampler + `new2-bang` (§4), measure the battery cost, arm `new2`.
5. Drive with the recorder; apply the episode ladder (§6). First sticky episode caught with the
   recorder ⇒ decide the branch in §7 and start the matching fix lane in §8.
6. Field experiment in parallel from day one: LTE-only on `new2` for a week (F1's cheap trial).

## Appendix — evidence pull one-liner (run when `new2` is on USB, before any reboot)

```
D=diag-tools/captures/new2-emerg-20260914; mkdir -p $D
for c in "dumpsys telephony.registry" "dumpsys phone" "dumpsys carrier_config" "logcat -b events -d -v threadtime" \
         "logcat -b main,system,crash -d -v threadtime" "dmesg" "cmd phone get-allowed-network-types-for-users -s 0"; do
  adb -s 9c2e6b00 shell "$c" > "$D/$(echo $c | tr ' ,' '__').txt" 2>&1; done
grep -n -E "EmergencyOnly=true|rejectCause=[1-9]|NOT_REG|OUT_OF_SERVICE|mOperatorAlpha" "$D/dumpsys_telephony.registry.txt" | head -50
```

---

## 2026-09-19 — BREAKTHROUGH: stock silver modem-F3 captured through a full OOS→recovery at the home spot

**The capture finally worked** (days of `diag_mdlog` dying were the blocker). Two fixes:
1. **Non-magnetic USB cable.** The magnetic tip's flaky data pins dropped USB every ~2-3 min; each drop SIGKILLed the `/su`-spawned `diag_mdlog` (adbd cgroup cleanup), which also wedged the diag mux. With a plain cable the logger ran continuously for 25+ min, rotating cleanly (`-s 100 -n 20`), pid stable.
2. **Silver's OWN stock qdb.** Our in-repo `qdb.dec` is the A16 build; it will NOT decode stock A8 F3. `diag_mdlog` writes the modem's QShrink DB into the capture dir (`<guid>.qdb`); `build_qdb.py <guid>.qdb out.dec` → 279,485 records (guid `aa70ba0d-…` matched `diag_qsr4_guid_list.xml`). Then `decode_f3.py silver.qdb.dec cap.qmdl '<src-regex>'`.

**The home spot is NOT "weak Verizon only" — it is the diagnostic case:**
| Cell | Band | PLMN | RSRP | On SIM (311-480 Verizon)? |
|---|---|---|---|---|
| EARFCN 975 PCI 477 | B2 | **310-260 T-Mobile** | **−114…−117** (hotter) | ❌ forbidden (in SIM 4-entry FPLMN) |
| EARFCN 5780 PCI 444/265 | B13 | Verizon | −121…−122 | ✅ home, too weak to camp |

**Stock witness — HOLD phase (10:32→10:53, ~21 min OOS, `mIsEmergencyOnly=false` throughout).** Modem F3 (silver.qdb):
- `lte_rrc_csp.c:2869 CSP: PLMN IDs are not the same` ×198; `:3027 CSP: PLMN not found` ×37 — endless BPLMN scan hitting non-home cells.
- `reg_sim.c:5473 PLMN 310-260 is Forbidden`; `reg_sim.c:6887 Forbidden PLMN list (length = 4)`; `reg_sim.c:6872 HPLMN - 311-480` — refuses T-Mobile explicitly, keeps home target.
- `lte_rrc_csp.c:22480 RRC_E911 ACQ CNF Cell barred 0`, `:24238 IMS Emergency Support present`, `emm_reg_handler.c: emc_srv_spt=1 emc_attached=0` — modem EVALUATES emergency service and DECLINES to register emergency-only.
- `reg_state.c LTE IRAT BPLMN` search running the whole time.

**Stock witness — RECOVERY phase (10:53:48, Verizon rose −122→−105).** Modem F3 (recovery qmdl):
- `lte_rrc_csp.c:22401 Acquistion Cnf is success` ×49; `:24414 Selected PLMN index is 0`; `:26341 Proceeding to camped`; `:5517 Sent RRC synch Camped Ind`.
- `emm_utility.c:5868 Sending NAS_EMM_PLMN_CHANGE_IND w/ PLMN 311-480`; `emm_utility.c:3744 sent REGISTERED EVT`; `cmss.c:24974 CM_SRV_IND: mode 9 srv_domain 2 is_stable_in_svc 1`; `srv_status 2`.
- Edge wobble present (`reg_state.c:9897 MMR_ATTACH_FAILED_IND` ×5, `lte_rrc_csp.c:25205 OOS ind in not CAMPED state`) but STILL `emc_attached=0` — never emergency-attaches even while struggling.

**CONCLUSION (stock rule, modem-confirmed):** refuse the forbidden network, never fake emergency-only, hammer the HPLMN background search, snap back to home the instant it clears threshold. This is exactly what our stack fails to do.

**Sharpened hypothesis for new2 (next experiment):** at this same spot our stack either (a) registers **emergency-only on the forbidden T-Mobile cell** then stops the aggressive HPLMN search (→ sticks until airplane/Wi-Fi forces a fresh scan), or (b) waits like stock but fails to re-detect Verizon on recovery. Capture new2 here (same rig: plain cable, road cfg, its own qdb) and diff against this witness.

**Artifacts (session scratchpad, pull to a captures dir before it's cleaned):** `scap6_live.qmdl` (hold), `scap6_recovery.qmdl` (recovery), `silver.qdb.dec`, `silver-f3-resel.txt`, `silver-f3-recovery.txt`.

---

## 2026-09-19 (part 2) — ROOT CAUSE CONFIRMED: new2 reproduces "emergency only" at the same spot; modem QMI shows why

SIM moved to new2 (9c2e6b00, our A16), same home spot, Wi-Fi OFF. **Reproduced immediately.** No diag F3 needed — `nas-probe` (force-ipcr QMI) is modem ground truth. (diag_mdlog's one-session-per-boot budget was spent by a lock-screen `/sdcard`-inaccessible false start; FBE means `/sdcard` needs an unlock before arming. F3 is a reboot+unlock+arm away if we want the internal reasoning, but the QMI state already settles it.)

**Live state (new2, ~11:18):**
- Framework (reliable, Wi-Fi off): `mVoiceRegState=OUT_OF_SERVICE`, **`mIsEmergencyOnly=true`**, operator empty, `mChannelNumber=5230`.
- `nas-probe` GET_SERVING_SYSTEM 0x24: `registration_state=2 (NOT_REGISTERED,SEARCHING)`, **`PS attach=1 (ATTACHED)`**, `CS attach=2 (DETACHED)`, radio_if=lte, PLMN 311-480.
- GET_SYS_INFO 0x4D: `LTE srv_status=1 (LIMITED)`, `true_srv_status=0`, serving cell PLMN 311/480, EARFCN 5230, cell_id 15363, `srv_capability=PS_ONLY`, `is_forbidden=0`.
- GET_SYS_SEL_PREF 0x34: **`usage_preference=1 (VOICE_CENTRIC)`**, srv_domain_pref=CS_PS, voice_domain_pref=PS_PREFERRED, net_sel=AUTOMATIC.
- Framework CS & PS WWAN NetworkRegistrationInfo: `availableServices=[EMERGENCY]`, `emergencyEnabled=true`, `rejectCause=0`; DataSpecificRegistrationInfo `LteVopsSupportInfo mVopsSupport=2 mEmcBearerSupport=2` (VoPS not usable on this cell).

**MECHANISM (modem-confirmed):** new2 is **VOICE_CENTRIC**. It camps and **PS-attaches** on a weak Verizon cell (−118) that offers **PS-only** (no CS, no usable VoPS). Voice-centric domain selection then treats "no voice domain" as "no service" → declares **emergency-only**, even though data is attached. Stock silver at the identical spot stayed full NO_SERVICE (never camped limited, `mIsEmergencyOnly=false`), refused the partial cell, and BPLMN-searched until a full-service cell appeared → clean recovery. **That is the entire difference: our stack accepts a voice-less PS-only camp and calls it emergency-only + sticks; stock refuses and keeps hunting.**

**CURE DIRECTION (no code yet — user hold):** the lever is QMI NAS **usage_setting / voice-centric domain selection** (0x33 set / 0x34 get, `usage_preference`). DATA_CENTRIC would treat the PS attach as service (voice best-effort via VoLTE/WFC) and not collapse to emergency-only when only PS is available. Before choosing: read stock silver's `usage_setting` + limited-service/emergency-camp NV to see what makes stock refuse the partial camp. Cross-ref [[attach-domain-selection]] (usage=1 voice-centric holds), [[nas-slow-reattach]].

**Open test (in progress):** does new2 self-recover when signal returns (like silver did at 10:53) or STICK in emergency-only until an airplane/Wi-Fi toggle? Watch armed on modem truth. Artifacts: `diag-tools/nas-probe/captures/new2-20260919-emergonly/`.

### 2026-09-19 (part 2b) — new2 SELF-RECOVERED in ~9 min (slow attach), + a wakelock confound
Trajectory (hunt.log, today): 11:18→11:26 hard-stuck `reg=2/lte=1 (LIMITED)` on Verizon cell 15363 @ rsrp −118 (signal flat), a brief AT&T (310-410) glance at 11:26, then 11:27:22 `reg=1/lte=2 (FULL)` on the SAME cell 15363 at the SAME −118/−119. Recovered nas-probe: registration_state=REGISTERED, LTE srv=FULL, but **CS attach still DETACHED, srv_capability still PS_ONLY** → "full service" == the EPS/PS attach finally completed; "emergency-only" earlier == the same attach not yet complete, LABELED emergency-only by voice-centric policy. So the stick is fundamentally a **slow/failed EPS-attach on a weak cell** (cf [[nas-slow-reattach]]), not a PLMN/forbidden/coverage problem — new2 latched cell 15363 and retried there for 9 min instead of reselecting like stock.
**CONFOUND:** the whole window the AP was held awake by `diag_mdlog_wakelock` (mWakefulness=Awake). Real-world (screen off, unplugged, AP suspended) the attach retries throttle → the stuck window is almost certainly much longer, matching "stays until airplane toggle." The 9-min self-recovery is a best case, measured awake.
**Next tests:** (1) measure the SUSPENDED-case stuck duration (screen off + unplugged; read on-device hunt.log after) — the true daily-driver scenario; (2) confirm airplane/Wi-Fi toggle clears it instantly (forces fresh attach); (3) optional F3 of the attach retries/reject causes (reboot+unlock+arm, then reproduce) to see WHY the attach takes 9 min on this cell.

### 2026-09-19 (part 2c) — CORRECTION: usage_setting is NOT the stock-vs-ours diff (both voice-centric)
Checked the enums. nas-probe QMI GET 0x34: 1=VOICE_CENTRIC, 2=DATA_CENTRIC → new2 `usage_preference=1` = VOICE_CENTRIC. Silver's modem F3 `cmsds.c ue_usage_setting=0` uses the modem-internal enum (0=voice-centric), so **silver is ALSO voice-centric.** Both phones are voice-centric (the Verizon/US default). So "make new2 data-centric to match stock" was WRONG — stock is not data-centric. Data-centric remains a *candidate behavior change* (it would stop the phone calling a voice-less PS registration "emergency only"), but it is NOT "matching silver," and it is not a proven regression lever.
**Also reframing the delta:** the two runs were not under identical conditions (silver was walked into a deeper dead zone and was OOS ~21 min; new2 sat stationary at −118 with the AP held awake by our diag wakelock and recovered in ~9 min). So we do NOT yet have a clean "ours is broken, stock is fine" behavioral delta at this spot — both are voice-centric, both camp limited on weak Verizon and struggle to complete the attach. The clearest difference so far is the framework LABEL (A16 "emergency only" vs A8 "no service") + which cell each ended on. Whether a real modem-config regression exists is STILL OPEN → that's what the EFS/NV diff + a new2 F3 (to diff decision-making vs silver at the same spot) would settle.

---

## 2026-09-19 (part 3) — silver reflashed to A16 REPRODUCES the stick spontaneously; F3 shows the mechanism = NAS backoff-forbidden after max registration failure

Flashed silver (4373dd0f) from stock A8 to our A16 (build 20260918). SAME hardware that held Verizon to −133 as stock this morning. On A16, sitting on the counter (NOT held in a null), it went to emergency-only ON ITS OWN and stuck: `mIsEmergencyOnly=true`, `registration_state=NOT_REGISTERED`, CS+PS DETACHED, camped LIMITED on an AT&T cell (310-410), `band_pref=0xffffffffbfffffff` (ALL bands — so NOT the band lock), usage=VOICE_CENTRIC. Cleanest A/B yet: only the ROM changed (stock→ours) and behavior went good→stuck. new2 (also our A16) has the same bug. Strongly supports "interaction with our stack."

**Modem F3 of the stuck state (silver's clean diag channel; in-repo qdb.dec matched, unknown-msgid:0):**
- `cmss.c:11685 LTE:cmss_report_rssi(), rsrp=-111` — the modem IS measuring a cell at −110/−111 (weak, present). Framework CellInfo showing rsrp=invalid was just stale.
- **`reg_sim.c:6715 =REG= PLMN (…) is backoff forbidden added for Max registration failure, timer to unblock <ms>`** ← THE STICK. After repeated attach/registration failures, the modem put the home PLMN (Verizon 311-480) on the **temporary backoff-forbidden list** and won't retry it until the timer expires. So it sits emergency-only (camped on AT&T, unusable) meanwhile. Airplane toggle "fixes it" because it resets the modem and clears the backoff → fresh attach.
- Related NV: EFS `/nv/item_files/modem/nas/lte_nas_temp_fplmn_backoff_time` governs the backoff duration.

**The crux still to capture:** WHY do the attaches fail enough to trigger backoff (reject cause vs timeout/RLF at −110)? Those failures preceded the capture. Next = airplane toggle WHILE diag runs → catch the backoff-clear + fresh attach (success, or the reject cause). If the fresh attach fails with a NETWORK reject → external; if it fails on our side (IMS/combined-attach/timeout while the modem measures a fine cell) → our stack. Artifacts: scratchpad silver-a16-stuck.qmdl + silver-a16-stuck-f3.txt.

## 2026-09-19 (part 3b) — CORRECTION: the backoff mechanism is SHARED with stock (not ROM-unique)
Checked stock silver's F3 from this morning: it hit the SAME path — `reg_sim.c:6730 PLMN (311-480) is backoff forbidden ... timer to unblock 61988(ms)`, `reg_sim.c:6715 ...Max registration failure`, `MMR_ATTACH_FAILED_IND`, then `Backoff plmn Search Timer expired` → recovered. So attach-failures-at-weak-signal → temp-backoff-forbidden Verizon → limited/emergency service is NORMAL modem behavior on BOTH stock A8 and our A16. It is NOT a ROM-unique wedge. (Walking back the part-3 "supports ROM interaction" lean.)

**What still differs (candidates, none proven a regression):**
- Framework LABEL: stock A8 presents this as "no service" (mIsEmergencyOnly=false); our A16 presents the same underlying limited/backoff state as "emergency calls only" (mIsEmergencyOnly=true). This is an AP/telephony presentation difference, not necessarily modem.
- Duration is NOT cleanly worse on ours: stock was OOS ~21 min at the spot this morning (repeated ~40-62s backoff cycles until signal improved); silver-A16 was stuck ~8 min on the counter then self-recovered. Different conditions; no matched measurement.
- Stock backoff timers were 39-62 s (readable). Our A16 backoff timer value did not decode (garbled %u). Whether ours is longer, or re-fails in more cycles, is the OPEN question — needs a matched capture at the same signal.

**rsrp question RESOLVED:** the "invalid rsrp (2147483647) on all cells" is a registration-state artifact — when unregistered/emergency-only there is no serving cell, so the framework reports no serving signal. The modem still measures the cell (F3 `cmss_report_rssi rsrp=-110/-111`), and once REGISTERED the framework rsrp is correct (−111/−112). Not a signal-reporting bug in our stack.

**Honest current picture:** most of what we're seeing is weak-signal modem behavior common to both stacks (marginal attach → backoff → limited). The user-visible "emergency calls only" is our A16 framework's wording for it. A true modem-level regression in our ROM is NOT established. The remaining real question = does our stack fail the attach MORE often, or back off LONGER, than stock at the same signal? (matched capture needed.)

## 2026-09-19 (part 3c) — OS-side (IMS/DSRM) investigated live during a stick: NOT the prolonger
User hypothesis: if EFS/NV is ~identical but timing differs (stock 62s vs A16 8min), something in the OS (IMS?) controls it. Captured 20s of logcat (radio+main+system) on silver-A16 during a live stick (counter, −110, mIsEmergencyOnly=true):
- **DSRM: quiet.** No DataStallRecovery, no setRadioPower, no restartRadio, no forced re-attach. The AP is NOT cycling the radio.
- **IMS: victim, not cause.** getImsRegistrationTechnology=-1, ImsPhone what=83 ~1/s — passively retrying IMS reg, failing (no data). Not tearing down the attach, not a busy loop.
- **DataNetworkController churn** = repeated `Data evaluation reason:TAC_CHANGED, disallowed: NOT_IN_SERVICE` — the framework REACTING to the modem bouncing cells/TACs, not a driver.
- Serving "search" cell: earfcn 5780 (Band 13 = Verizon's band) but plmn 310410 (AT&T), VopsSupported=false → modem tried the right band, failed, backed off Verizon, camped emergency-only on forbidden AT&T, bouncing.
**Conclusion:** the OS is not actively prolonging the stick. With EFS/NV ~identical AND OS levers quiet, the stock-vs-A16 timing difference cannot currently be pinned to a ROM component — the time is spent in the MODEM's reselection/backoff at a genuine −110 fringe. Remaining candidates: unfair stock/A16 comparison; a subtle RIL/qmux attach-retry behavior (not visible in these buffers); stochastic RF. Deeper test = modem F3 of the bounce/reselection + exact backoff timer during a clean stick (no mid-capture toggle).

## 2026-09-19 (part 4) — DEFINITIVE: A16 vs stock acquisition behavior is identical (no ROM regression)
Clean silver-A16 F3 capture (no toggle → no handshake flood, 3694 decoded lines) of a natural stuck→recover cycle at −113/−115, vs stock silver's F3 from this morning (~−121 Verizon during its OOS):
- **Acquisition failure rate IDENTICAL: 88%.** A16 = 14 success / 98 failure (`lte_rrc_csp.c:22401`/`22510`). Stock = 71 / 534. Same 88%.
- **A16 backoff timers SHORTER:** 7.7 s & 21.5 s vs stock's 17–62 s (`reg_sim.c:6715 timer to unblock`). A16 retries faster.
- Stock thrashed MORE in absolute terms (534 acq failures) and was OOS ~21 min at the spot — so "stock cleared in 62 s" was one cherry-picked backoff value, not stock's actual recovery time.
**Mechanism (both stacks):** at a marginal fringe (~−110 to −121), RRC cell acquisition fails ~88% of attempts (RF physics — can't reliably decode/RACH a cell that weak). Failed acquisitions → max-registration-failure → short backoff → retry → fail → loop, for minutes, until an attempt gets lucky AND the attach completes. Emergency-only is the framework's label for that window.
**CONCLUSION: no ROM regression.** A16 == stock at the modem level (same 88% acq-fail rate, shorter backoff). The user's "stock was much better" is (a) hold-vs-acquire conflation ("held to −140" = holding an existing link, ≠ acquiring from cold, which fails at the fringe for both), and (b) a cherry-picked 62 s timer vs stock's real 21-min OOS. 
**Caveat:** captures were uncontrolled and at slightly different signal (A16 −113 vs stock ~−121), so a small acquisition-sensitivity difference can't be 100% excluded — but there is no clean evidence of one; rate, mechanism, and backoff all say same-or-better.
**Only usability lever left:** the watchdog (auto-nudge a fresh Verizon retry when stuck = what the airplane toggle does by hand — shortcuts the backoff + retries from clean state, gets lucky sooner). It's a band-aid for RF physics, NOT a fix for a regression (there is none).
