# PLAN — Out-of-service time at the Verizon fringe

**Opened 2026-10-20.** Successor to the investigation plans `PLAN-emergency-only.md` (95 K, mechanism
hunt), `PLAN-stock-diff.md` (lineageos-pepito repo, ROM-vs-stock lanes) and `PLAN-emergency-watchdog.md`.
Those stay as the record. This plan has one goal and one number, and every entry is tagged **FACT**
(captured, with a pointer), **HYPOTHESIS** (with the experiment that kills it) or **DECISION**.

## 0. Goal and the number

**Goal:** a PVG100 on our ROM, carried on Kyle's normal routes, spends no more minutes per day without
usable service than the same hardware on stock A8 did.

**Primary metric — excess OOS minutes:** two phones in the same pocket, same route, same day: our ROM
(new2) and a stock-A8 witness (silver, once it has the second SIM). Count the minutes where the witness
has home service and ours does not. Route-independent; this is the prize, measured directly.
Until the second SIM arrives, the proxy is **per-episode recovery latency** on new2: seconds from the
first sample where the modem can measure a Verizon cell at ≥ −120 dBm to the first REGISTERED-HOME
sample.

**Secondary split (where the minutes go), per episode:**

| Class | Signature (QMI-polled) | Addressable? |
|---|---|---|
| HOLE | `srv_status` 0 / 4 (POWER_SAVE), no cells | no — RF physics, same on stock (FACT F1) |
| FOREIGN-LIMITED | LIMITED/DENIED on 310410 / 310260 | **yes** — the main target |
| HOME-LIMITED | LIMITED / SEARCHING on 311480 | yes |
| IMS-DOWN | REGISTERED-HOME, PS attached, `ims_registered=0` | yes (voice-only outage) |

**Instrument rule:** RSRP and registration come from QMI polls (`nas-probe` NAS 0x4D/0x4F), never from
the framework. Our stack configures threshold-based signal reporting with nothing below −115 dBm, so
`dumpsys telephony.registry` under-reports the hold by construction (10-20 audit). Sampler v10 reads the
framework field — **replace before the first A/B** (§3 E0).

## 1. What is established (do not re-derive)

| # | FACT | Evidence |
|---|---|---|
| F1 | Fringe cell **acquisition** fails ~88 % on both stacks; the backoff loop is shared; ours retries faster | PLAN-emergency-only 09-19 part 4 |
| F2 | **Stick mechanism:** IMS unregistered → modem CM declares voice unavailable → `reg_sim` backoff-forbids the home PLMN and strips LTE. `usage=2` (data-centric) makes CM skip the "leave LTE" branch. Stock parks the same way when IMS is forced down | RE-2 (PLAN-stock-diff §6), bench 10-13/14, silver-stock 10-09 |
| F3 | **No AP command releases a cell at the fault.** Fault windows contain reads only; the only runtime AP→modem writer is `wfc_wlan_bridge`. DSRM self-gates on POOR signal | L3 10-05; 10-20 audit in PLAN-emergency-only |
| F4 | Our modem **camps limited on AT&T/T-Mobile hands-off** (28 onsets in one day, 0 RADIO_POWER). Stock at the same spot **refused** the foreign camp (`emc_attached=0`) and kept searching the home PLMN | 10-19 field day; 09-19 stock F3 (n=1) |
| F5 | Once camped foreign, our modem **stops re-searching home frequencies** (one scan, then nothing for 13 min). A DMS LPM→ONLINE cycle registers in < 15 s whenever a Verizon cell is present | 09-16 F3; radiocycle n≫2 |
| F6 | Suitability (S-criterion, `q-RxLevMin −126` in SIB1) is lost at −120…−127 on any UE; our registered cell held to −125. The stock "−140 hold" is below decode sensitivity and is **not a working link** | 09-16 walk; 10-20 discussion |
| F7 | Stale WLAN-available in the modem DSD caused the 50 s cold re-attach; fixed `18771530` (4 s) | nas-slow-reattach 08-23 |
| F8 | Data-centric shipped default-on in `20261017`. First field day: 0 old-signature sticks (DENIED on Verizon's own cell), 31 foreign-camp onsets at −113…−117 | 10-19 |
| F9 | Units differ below the ROM: silver modem 'D' vs new2/dut1 'E'; new2 carries EFS items the others lack (`nas/aggression_management`, `lte_bandpref`, `sms_only`) | stock-diff 09-30, 10-06 |
| F10 | DSRM `RESET_MODEM` = modem reboot, which wedges MSS on pepito; the skip-list (F6 of the old plan) is **not shipped** | 10-20 audit |

## 2. Hypotheses, ranked by (minutes it could save × chance it is ours to change)

| # | HYPOTHESIS | Kills it / confirms it | If confirmed, the lever |
|---|---|---|---|
| H1 | **Stock keeps hammering the home PLMN while ours parks on the foreign cell** — a modem policy (EFS/NV), separate from F2 | Decode silver's 10-09 park (stock, IMS forced down): which PLMN did it sit on? Foreign ⇒ H1 dead, it was all F2. Home-limited ⇒ H1 alive. Then the 09-18 "−140 hold" F3 (still on silver, never decoded): RRC state while "holding" | copy the EFS/NV items (L7 inputs, `aggression_management`, limited-service HPLMN search timer); assert at boot like `ims_enabler` |
| H2 | **"−122 vs −140" is an artefact** of who camps foreign plus framework reporting, not a hold difference | Same two decodes as H1 + QMI-polled RSRP on both phones at one loss | drop D1 as a goal; stop measuring release RSRP via the framework |
| H3 | **Remaining OOS after data-centric is IMS-driven**: IMS falls at the fringe and does not re-register for minutes; stock re-registers in seconds | Sampler: `ims_registered` vs reg state at every onset for ≥ 3 field days. Bench: six IMSS `0x53` provisioning writes stock does and we don't — do they take on the v01 modem, and does re-registration time change? | `ims_enabler` provisioning parity (§5b lever 1); `ims_test_mode` kick as a last resort |
| H4 | **Unit EFS generation** (new2-only items) changes hold/fallback | EFS-sync A/B already queued 10-19 (back up, remove the three items, 3 min flush, reboot, ≥ 1 day) | nothing to ship; tells us which units stick |
| H5 | **Connected-mode drops**: SIP retries and DNS probes keep the UE in RRC-connected at the fringe, so it fails by radio-link-failure instead of idle drift | F3 at a loss on ours: `T310` / RLF / re-establishment lines in the 60 s before the deregistration | WFC-bridge flap damping; nothing else cheap |
| H6 | **A nudge is the usability floor**: if H1's policy cannot be copied, an automatic DMS radiocycle after N s foreign-limited recovers whatever stock recovers | Already proven to register in < 15 s when a Verizon cell exists (F5). Open: WFC runtime state survives? battery cost? 911 interplay while cycling? | watchdog nudge default-on, "radio" mechanism, N ≈ 90 s, detection-only log kept |

Out of scope (settled, do not reopen): modem static RE (dry, PLAN-stock-diff §6 CLOSE); AP command audits
(F3); MBN loading / `rat_on` / subscription props (Kyle rule); acquisition sensitivity (F1).

## 3. Experiments, in order (one change at a time, ≥ 2 field days each)

| # | Experiment | Cost | Decides |
|---|---|---|---|
| E0 | **Sampler v11** ✅ 10-20 11:02 on new2: `nas-probe sig` (NAS 0x4F sig info + 0x43 cell location: serving RSRP, **srxlev**, neighbours) replaces the framework RSRP; `summarize.py` ✅ (time-weighted per-episode class mix + daily totals; recovery latency needs the second phone) | done | makes every later number comparable |
| E1 | **Decode what already exists** — ⚠️ 10-20 result: the stock hold F3 (`scap6_live/recovery.qmdl`, 09-19 morning) was never pulled out of the session scratchpad and is **gone**; `silver-letgo-20260919.qmdl` is 3 min of silver-on-A16 *registered* (17:18–17:21, Srxlev 17–19, RSRP −108…−116), not a let-go; the 09-18 `silver-spot2` F3 is one minute at 17:21. Surviving stock-side evidence = the written 09-19 summary in PLAN-emergency-only (21-min OOS hold: BPLMN hammering, `PLMN 310-260 is Forbidden`, `emc_attached=0`, no emergency camp) — answers the **non-forbidden** half of H1 (stock prefers OOS-search over a foreign limited camp). The **forbidden** half (10-09 stock park PLMN) has no located capture; needs re-running on silver with diag | done as far as it goes | H1 half-answered, H2 open |
| E2 | new2 baseline ≥ 2 field days on v11, data-centric on, nudge off, Tailscale DNS off | field | the post-data-centric split (H3 size) |
| E3 | EFS-sync A/B on new2 (as queued 10-19) | field, 2 days | H4 |
| E4 | **Two-phone excess-OOS** with the second SIM: silver stock vs new2, same pocket | field, ≥ 3 days | the prize; the only route-independent number |
| E5 | IMSS `0x53` parity on the bench: write the six items via a `qmux` oneshot, measure IMS re-registration time after `ims_test_mode` 1→0 | bench day | H3 lever |
| E6 | Watchdog nudge ON, "radio" mechanism, 90 s, on new2 for ≥ 2 field days; count recoveries, battery, WFC survival | field | H6 ship/no-ship |
| E7 | If H1 alive after E1: locate the policy item (EFS diff silver vs new2 under `nas/`, `mmode/`; F3 `reg_sim`/`sd` lines at the foreign camp decision) and A/B one item at a time | bench + field | H1 lever |

## 4. Ship list (each gated on the experiment that earns it)

| Candidate | Gate | State |
|---|---|---|
| Data-centric default-on | shipped `20261017` | keep; E2 quantifies what it bought |
| DSRM skip `RESET_MODEM` (`data_stall_recovery_should_skip_bool_array={f,f,true,false,true}` in `mithorium-common` CarrierConfig `vendor.xml`) | none — safety fix, F10 | **ship now** |
| WFC-bridge flap damping (hold WLAN_NOT_AVAILABLE ~20 s; cancel if Wi-Fi returns) | E2 shows Wi-Fi-edge IMS churn, or H5 | staged idea |
| IMSS provisioning parity in `ims_enabler` | E5 | not started |
| Home-PLMN re-search policy items at boot | E1 + E7 | not started |
| Watchdog nudge default-on | E6, and only if E7 yields nothing | off by default |

## 5. Rules for this plan (the "science, not guessing" part)

1. A number goes in §6 only with: unit, build, SIM, Wi-Fi state, Tailscale DNS state, nudge state, route
   class (home / commute / out of area), and the instrument (QMI poll vs framework vs F3).
2. One variable per A/B. Never flip a modem setting without the ~3 min EFS flush before reboot.
3. No airplane cycles on the measurement unit (they are themselves the recovery action under test).
4. "Stuck" is called only from the QMI sampler line; a SIM pull reads exactly like a park (`sim=`).
5. A hypothesis that survives its experiment is promoted to §1; one that fails is deleted from §2 with a
   one-line epitaph, not argued with.
6. Kyle runs builds, flashes and field days. Agents stage, decode, summarize.

## 6. Log

- **2026-10-20** — plan opened from the AP-side let-go audit (PLAN-emergency-only, same date). State
  carried in: new2 on `20261017` gapps, data-centric on, nudge off, sampler v10 running since 10-19 20:42
  (framework-sourced RSRP — superseded by E0), EFS-sync A/B queued, second SIM on order.
- **2026-10-20 11:05 — new2 back on the bench; harvest + E0.** Pulled: sampler v10 10-19 20:42 → 10-20 10:55
  (`/tmp/new2-1020/sample-v10.log`), persisted logcat 10-19 17:06 → 10-20 10:28 (38 WOULD-NUDGE, **0 RADIO_POWER**),
  `ap-release-census` (COMMAND class 0; DSRM GET_DATA_CALL_LIST→CLEANUP cycling at 10:54 on the T-Mo camp, 2 skipped
  for poor signal). Build `20261017` gapps, usage=2, nudge off, uptime 1 d 22 h, qcrild never restarted.
  **Episodes today (QMI reg/plmn, framework RSRP):** 07:23–08:39 **at home, Wi-Fi up**: Verizon −115 → AT&T limited →
  T-Mo DENIED (ch 975) ↔ 311480 LIMITED on 5230 at −120…−125, 08:09 Kyle left (Wi-Fi 0), 08:14–08:22 HOLE (lte=4
  POWER_SAVE), 08:30 VZW limited emg, 08:34–08:39 T-Mo denied emg, **08:39 registered** = 76 min, ~45 of them at home
  masked by WFC. 10:53–11:01 second T-Mo DENIED camp at home (8 min, WFC up, IMS registered over IWLAN), self-recovered.
  **Instrument facts from the first `sig` reads (B13 EARFCN 5230, PCI 308):** `srxlev=14` at rsrp −112 ⇒ **q-RxLevMin
  = −126** (confirms F6); `s_nonintra=6` (12 dB) ⇒ inter-frequency measurement starts at RSRP ≤ −114; serving layer
  `prio=0`, inter-freq layers EARFCN 2050 `prio=7` and 1550 `prio=5`, `thrX_high=6`. So from −114 down the modem is
  already measuring higher-priority Verizon layers and anything else it can hear. Framework RSRP read −109 while the
  modem said −112/−113 (framework lags, as predicted).
  Tools: `nas-probe sig` (source + v11 sampler in `diag-tools/nas-probe/` here; build via
  `~/android/lineage-23/diag-tools/nas-probe/build-nosysroot.sh`). Old binary kept on new2 as `nas-probe.v10`.
- **2026-10-20 11:40 — E1 closed as far as the archive allows (see row), E0 complete, first number.** `summarize.py`
  on the v10 log (QMI reg/PLMN classes, time-weighted):
  **10-20 so far: covered 634 min, OUT 149 min (23.5 %) = FOREIGN 105 + HOME-LIMITED 23 + HOLE 21.** Seven episodes:
  two at home on Wi-Fi (40 + 34 min, lost at −115/−120), four out of area (3, 1, 26, 33 min, lost at −104…−122),
  one open at 10:42. The three biggest out-of-area episodes are 70–80 % FOREIGN camp, i.e. the addressable class,
  not holes. Loss RSRPs are framework values (v10); from now on v11 gives the modem's own. Sampler stalls 5–12 min
  when the phone dozes off Wi-Fi — the summarizer caps a sample's coverage at 5 min, so OUT is a floor.
  Stock-side comparison still has no instrument (E4 needs the second SIM); 10-12 memory note: a stick exit came on a
  *different* Verizon carrier (B66 67086), so the backoff is per-cell, which the v11 neighbour list can now watch.
- **2026-10-20 14:28 — E2 walk #1 starts (new2).** Sampler v11 alive (pid 1415, 818 lines), registered 5230/PCI 308
  at −112, srxlev 14, battery 100 %, nudge off, data-centric on, no other change. Route class: Kyle's walk.
  To pull on return: `new2-adb pull /data/local/tmp/rec/sample-v11.log` → `summarize.py`; compare "lost at" RSRP/srxlev
  (now modem-sourced) against the 07:23 and 10:42 home episodes.
- **2026-10-20 14:45 — silver prepped for the E1 re-run (stock A8 v1AML-0, 4373dd0f, no SIM, 38 % charging).**
  Root = `/su` (stdin mode `echo cmd | /su`; uid 0 but CapEff 0xc0 = setuid/setgid only — good for dmesg, useless
  for killing). Native `diag_mdlog` runs fine **as shell** and stops with `diag_mdlog -k` as shell; dry run wrote
  5 MB in 12 s on `Diag-road.cfg` (staged at `/data/local/tmp/Diag-road.cfg`), mux clean (no −107).
  Script: `diag-tools/nas-probe/silver-e1-park.sh arm|status|stop|pull <label>|decode <dir>`.
  **Protocol (needs the SIM, so after the new2 walk):** (1) SIM new2 → silver, wait for `gsm.sim.state=LOADED`
  and voice REG_HOME + IMS registered; (2) `silver-e1-park.sh arm`; (3) by hand on silver: Settings → Mobile
  network → **Enhanced 4G LTE Mode OFF**; (4) `status` every few min; let it park ≥ 10 min; (5) Enhanced 4G ON, wait
  for voice; (6) `pull e1-park1` then `decode <dir>`; read `reg_sim`/`emc_attached`/PLMN lines in the park window.
  **Decides H1's forbidden half:** park on 311480 LIMITED ⇒ real refuse-foreign policy (copy it); park on 310410/310260
  ⇒ no separate policy, it was all IMS (F2). Also gives the stock-side *loss* RSRP if the bench cell wobbles.
  ⚠️ silver's battery collapses under sustained OOS at 95–97 % — keep it on the charger for this bench run.
