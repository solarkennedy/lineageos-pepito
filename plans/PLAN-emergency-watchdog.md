# PLAN — "Emergency-only" recovery watchdog (battery-safe, no-harm design)

Status: PHASE 0 IMPLEMENTED (dry-run detector + Pepito Tweaks toggle) 2026-09-19. Owner: pepito. Created 2026-09-19.
Companion to `PLAN-emergency-only.md` (the root-cause investigation).

## 0. Why this exists (and what it is NOT)

The investigation (see `PLAN-emergency-only.md` parts 3–4) established, with matched modem-F3
evidence, that the "emergency calls only" sticks are **weak-signal RF physics, not a ROM regression**:
at a marginal fringe (~−110 dBm and below) RRC cell acquisition fails ~**88% of attempts on BOTH our
A16 and stock A8** (measured: A16 14 success/98 fail; stock 71/534 — identical 88%). The modem hits
max-registration-failure, temporarily backoff-forbids Verizon (`reg_sim.c:6715`, timers 7–21 s on A16
vs 17–62 s on stock), and sits emergency-only, thrashing acquisition until an attempt gets lucky and the
attach completes. An airplane toggle "fixes it in seconds" because it clears the backoff list and forces
a fresh Verizon attempt from a clean state.

**So this watchdog is a USABILITY BAND-AID, not a bug fix.** It automates what the airplane toggle does
by hand — nudge a fresh Verizon re-acquire when genuinely stuck — so the daily driver stops sitting on
"!" for minutes. There is no source-level regression to fix; do not frame this as one.

Because it's a band-aid layered on a phone that is otherwise behaving normally, the bar is:
**it must never make things worse, and must cost ~zero battery.** Correctness of *doing no harm* >
aggressiveness of recovery.

## 1. Hard constraints (the acceptance gate)

1. **Battery:** ≈0 measurable impact on standby drain. No polling loop, no held wakelock in the idle path.
2. **No unintended consequences:** must not drop calls/data, must not wipe WFC/VoLTE provisioning, must
   not nudge in a genuine dead zone (wasted energy + delays natural recovery), must not storm.
3. **Reversible / killable:** a single prop or setting disables it instantly; removing it leaves stock behavior.
4. **Observable:** every decision (trigger, skip-reason, nudge, outcome) is logged so we can prove it
   helps and never storms.
5. **Opt-in staged rollout:** ships DISABLED by default; enabled per-device after validation.

## 2. Detection — event-driven, cellular-truth, debounced

### 2.1 Read CELLULAR truth, not the aggregate (WFC masking)
Under Wi-Fi calling the framework's aggregate `ServiceState` can read in-service via IWLAN while the
**cellular** side is stuck. The detector MUST evaluate the WWAN transport specifically:
`ServiceState.getNetworkRegistrationInfo(DOMAIN_PS|CS, TRANSPORT_TYPE_WWAN)` — its `registrationState`
and `availableServices`. (nas-probe `status` over force-ipcr is the ground-truth cross-check / fallback,
but the framework already exposes WWAN reg state, so we prefer it — no process spawn, no QMI round-trip.)

### 2.2 Event-driven, not polled (this is the battery story)
Register a `TelephonyCallback` for `onServiceStateChanged`. The modem already generates these events —
we pay nothing to listen. NO periodic `nas-probe`/`dumpsys` polling loop; that was the battery risk in
the early prototype (`diag-tools/nas-probe/new2-sampler.sh`). Flow:
- On WWAN reg leaving normal service on the home PLMN (311480) → **start a one-shot timer** (see debounce).
- On WWAN reg returning to normal service → **cancel** the timer. Done, nothing else runs.
- The timer is an `AlarmManager` **inexact, non-wakeup** alarm (`setInexactRepeating`/`setWindow` without
  `RTC_WAKEUP`) or a `JobScheduler` job — it must NOT wake the device. If the phone is asleep and the
  timer would have fired, it fires on the next natural wake; that's fine (we only act when the AP is up).

### 2.3 Trigger predicate (ALL must hold)
Nudge only when, at the debounce check:
- WWAN reg = NOT_REGISTERED / emergency-only, off home PLMN, **sustained ≥ DEBOUNCE_SEC**, AND
- **`LTE srv_status == LIMITED`** (i.e., the modem is *camped on a cell* → signal is present) — NOT full
  `NO_SERVICE` with no cells (that's a true dead zone; nudging there is pointless and wastes energy), AND
- optionally: a recent cell view includes a Verizon (311480) cell (evidence home is receivable). Prefer
  the cheap `srv_status==LIMITED` proxy over an explicit `getAllCellInfo` scan (a scan costs power), AND
- `TelephonyManager.getCallState() == IDLE` (no active/ringing call), AND
- no active/handovering data call we'd interrupt, AND
- **not** in a cooldown, and under the per-boot cap (see guardrails).

### 2.4 DEBOUNCE_SEC — set it ABOVE a normal backoff cycle
A16 self-recovers via backoff in 7–21 s; stock up to 62 s. If we nudge inside that, we interrupt a
recovery that would have happened on its own (harm + waste). Start **DEBOUNCE_SEC = 90 s** (comfortably
above the longest observed backoff) and tune up if false-nudges appear. The whole point is to catch the
*multi-minute* sticks, not the routine sub-minute blips.

## 3. The nudge — gentlest mechanism that actually clears the backoff

The nudge must clear the modem's `reg_sim` backoff-forbidden list (else it won't help — the modem will
just re-honor the backoff). Candidate mechanisms, lightest first — **Phase 1 must empirically verify
which one clears the backoff AND does not wipe WFC:**

1. **Network-selection re-scan kick** — QMI NAS set network-selection AUTOMATIC (re-assert), or a
   manual→automatic toggle, to force a fresh PLMN search without a radio restart. Lightest; least likely
   to disturb WFC/data. *Unknown whether it clears the backoff list — TEST.*
2. **Radio power cycle (LPM→ONLINE)** via QMI DMS `set_operating_mode` (LOW_POWER then ONLINE), or
   `nas-probe radiocycle` (the prototype used this). Heavier than #1; equivalent to a fast airplane cycle
   at the modem without the framework's airplane broadcast. *Verify it does NOT wipe the runtime WFC
   provisioning (see ⚠️ below).*
3. **Full airplane toggle** (framework) — known to work but ⚠️ **the WFC lane warns airplane-cycling
   WIPES runtime QMI WFC provisioning** (`memory: wifi-calling-lane` "NEVER airplane-cycle"). AVOID unless
   we also re-assert WFC provisioning immediately after. Last resort.

⚠️ **WFC-wipe guard:** whichever nudge we pick, Phase 1 must check WFC still works after it (a runtime
QMI WFC write is clobbered by a reboot/airplane cycle per the WFC lane). If the chosen nudge disturbs it,
either pick a gentler one or have the watchdog re-run the WFC provisioning assert after nudging.

## 4. Guardrails (anti-storm, anti-harm)

- **Cooldown:** ≥ COOLDOWN_MIN between nudges (start 15–20 min). A stuck phone that a nudge didn't fix is
  probably in real bad coverage; hammering it drains battery for nothing.
- **Per-boot cap:** ≤ MAX_PER_BOOT nudges (start 6). Prevents a pathological loop.
- **Exponential backoff on failure:** if a nudge doesn't recover within RECOVER_WINDOW (e.g., 60 s),
  double the cooldown for the next one (15→30→60 min…). Stop trying after N consecutive no-recoveries
  until the next boot / next real service event.
- **Call/data gate:** never nudge with a call in any non-idle state or an active data transfer.
- **Screen/charge awareness (optional):** it's fine to nudge screen-off (that's when it matters most),
  but consider being more conservative on battery and more eager on charger.
- **Dead-zone guard:** the `srv_status==LIMITED` predicate (§2.3) is the primary dead-zone guard.

## 5. Battery analysis (the user's #1 concern)

- **Idle cost ≈ 0:** detection is event-driven off `onServiceStateChanged` (modem generates these anyway);
  no polling, no wakelock, non-wakeup timer. When the phone is fully in service (the common case), the
  watchdog is completely dormant.
- **Potentially battery-POSITIVE while stuck:** when stuck, the modem is *already* thrashing acquisition
  (~88% failures in a tight loop) — that itself burns power. A nudge that ends the thrash sooner can
  *save* energy vs. letting it grind for minutes. Net battery could be neutral-to-positive.
- **Nudge cost is rare + bounded:** a radio cycle costs a brief power spike, but it's gated by cooldown +
  cap, so at most a handful per day. Negligible vs. a normal day's radio activity.
- **Validation:** Phase 3 does an explicit A/B standby-drain measurement (watchdog off vs on, same
  conditions) to prove ≈0 — reuse the perf-battery-bench methodology (memory `perf-battery-bench`).

## 6. Unintended-consequences register (enumerate → mitigate)

| Risk | Mitigation |
|---|---|
| Nudge in a true dead zone (no Verizon) → wasted battery, delays natural recovery | Require `srv_status==LIMITED` (cell present), not NO_SERVICE; cooldown + backoff |
| Interrupts a backoff cycle that would self-recover | DEBOUNCE_SEC=90 s (> longest backoff 62 s) |
| Drops an active call / data | Gate on `getCallState()==IDLE` + no active data |
| Wipes WFC/VoLTE provisioning (airplane-cycle hazard) | Prefer gentlest nudge; Phase 1 verifies WFC survives; else re-assert WFC after nudge |
| Nudge storm (nudge→fail→nudge) | Cooldown + per-boot cap + exponential backoff |
| Nudge doesn't clear the backoff → useless | Phase 1 proves the chosen nudge clears `reg_sim` backoff before shipping |
| WFC masking hides cellular-stuck / false in-service | Read WWAN-transport reg specifically, not aggregate ServiceState |
| Masks a genuine future modem bug | Full logging (§7) so patterns are visible; not silent |
| Racing the modem during handover / TAC change | Debounce + only act on sustained OOS, ignore transient churn |

## 7. Observability

Log to a ring buffer (logcat tag + optional on-device file, size-capped): every state transition that
starts/cancels the timer, every trigger evaluation with the skip-reason if not nudged, every nudge with
the mechanism used, and the outcome (recovered? time-to-recover? or no-recover). This is how we prove it
helps and never storms — and it's the evidence for the Phase 3/4 acceptance.

## 8. Implementation options (decide in §10)

- **(A) Framework component (RECOMMENDED for battery):** a small system service or a hook in
  `Phone`/`ServiceStateTracker` using `TelephonyCallback` + `AlarmManager`/`JobScheduler`. Event-driven,
  no polling, native access to WWAN reg state and call state. Nudge via TelephonyManager
  (`setRadioPower`) or a QMI call. Ships in the ROM, gated by a prop. Most work, best behavior.
- **(B) Privileged app** with `READ_PRIVILEGED_PHONE_STATE` + `TelephonyCallback`, same event-driven
  design, packaged in the ROM (like the Blocker app precedent, memory `blocker-system-uid-app`). Easier
  to iterate than core framework; still event-driven.
- **(C) Native daemon** reusing `nas-probe` (force-ipcr) for both detection and nudge, as an init service.
  Fastest to prototype and reuses proven tooling, BUT detection would tend toward polling → the battery
  risk. Only acceptable if it subscribes to QMI NAS serving-system *indications* (event-driven) rather
  than polling. Good for the Phase-0/1 experiments; not the shipping form unless indication-driven.

Recommendation: prototype detection + nudge with (C) indication-driven or a thin (B) app on **silver**
(the test unit) to validate the mechanism cheaply; ship as (A) or (B), event-driven, once proven.

## 9. Validation phases

- **Phase 0 — Dry-run detector (ZERO risk, battery-neutral).** Event-driven detector that only LOGS
  "would nudge now (reason…)" — no nudge. Run on silver + optionally the daily driver for a few days.
  Validates: correct stuck-vs-deadzone-vs-blip classification, false-positive rate, how often it'd fire.
  Gate to proceed: detection is accurate and would fire only on real multi-minute sticks.
- **Phase 1 — Nudge mechanism bake-off (on silver at the fringe spot).** With a fresh clean diag F3
  running, induce a stick, then try nudge #1, #2, #3 and DECODE whether each clears the `reg_sim` backoff
  and recovers, and MEASURE recover-time vs natural. Also verify WFC survives each. Pick the gentlest
  that reliably clears the backoff without wiping WFC.
- **Phase 2 — Guardrails + kill switch.** Add cooldown, per-boot cap, call/data gate, exponential
  backoff, disable-prop. Re-run the dry-run+nudge with guardrails; confirm no storm under repeated sticks.
- **Phase 3 — Battery A/B.** Standby-drain measurement watchdog-off vs watchdog-on (idle, in-service).
  Acceptance: ≈0 delta. Also confirm the battery-positive hypothesis while stuck (thrash ends sooner).
- **Phase 4 — Field test.** Enable on silver (or daily driver) for a week at the real fringe/home + on
  the road. Confirm: fewer/shorter "!" episodes, no dropped calls, no WFC breakage, no drain, logs clean.

## 10. Open questions / decisions to make first

1. Which nudge clears the `reg_sim` backoff most gently without wiping WFC? (Phase 1 — the crux.)
2. DEBOUNCE_SEC / COOLDOWN_MIN / MAX_PER_BOOT final values (start 90 s / 15–20 min / 6; tune from Phase 0).
3. Ship form: framework hook (A) vs privileged app (B). Lean B for iteration speed + battery parity.
4. Is the daily-driver home better served by fixing WFC-prefers-Wi-Fi (memory `wfc-wifi-preference-lane`)
   so voice rides Wi-Fi at the fringe — making the cellular stick a non-event for the user? Consider
   pairing the watchdog with that, since the home spot is a genuine −110 Verizon fringe.

## 11. Non-goals

- Not a modem/attach fix (no regression exists; can't beat RF physics at −113).
- Not a general "signal booster" — it only recovers from the *stuck* state, it can't create coverage.
- Not enabled by default until Phases 0–4 pass on a real device.


## 12. Implementation log

### Phase 0 — dry-run detector + toggle (landed 2026-09-19, unbuilt/unflashed)

Built the event-driven detector and, at Kyle's request, the user-facing toggle at the
same time (the toggle is the ergonomic control surface for running the field dry-run on
the daily driver; it ships OFF).

**XiaomiParts** (`device/xiaomi/mithorium-common/parts`):
- NEW `src/org/lineageos/settings/emergencywatchdog/EmergencyWatchdogController.java` —
  event-driven detector. Extends `TelephonyCallback` + `ServiceStateListener`, registered
  from boot on the app's persistent system-UID process. Classifies from **WWAN-transport**
  reg state (not aggregate — WFC masking): `IN_SERVICE` / `EMERGENCY_LIMITED` (camped but
  emergency-only = the nudge target, via `NetworkRegistrationInfo.isEmergencyEnabled()`) /
  `DEAD_ZONE` (not registered, no emergency = no cell) / `POWER_OFF`. On `EMERGENCY_LIMITED`
  arms a **non-wakeup** `AlarmManager.ELAPSED_REALTIME` debounce (`DEBOUNCE_MS=90s`);
  cancels on recovery/deadzone. On fire: re-checks still-stuck + call-idle, then (Phase 0)
  logs `WOULD-NUDGE …` and returns. `DRY_RUN=true` compile constant gates any radio action;
  the nudge is a TODO in `onDebounceElapsed()` for Phase 1/2.
- `BootCompletedReceiver.java` — added `if (EmergencyWatchdogController.isSupported()) register(...)`
  (pepito gate = `ro.vendor.xiaomi.device==pepito`, same as LifeMode).
- `AndroidManifest.xml` — added `READ_PHONE_STATE` + `READ_PRIVILEGED_PHONE_STATE`
  (carried by `sharedUserId=android.uid.system`, no privapp entry; same pattern as LifeMode).
  `MODIFY_PHONE_STATE` deferred to Phase 2 (with the nudge).

**LineageParts** (`packages/apps/LineageParts`) — the "Pepito Tweaks" screen:
- `res/xml/go_tweaks_settings.xml` — NEW "Mobile network" category + `go_tweak_emergency_watchdog`
  switch, `defaultValue=false`.
- `src/org/lineageos/lineageparts/perf/GoTweaksSettings.java` — wired the switch to write
  `persist.gotweak.emergency_watchdog`, **applies live (no reboot prompt)** since the
  controller reads the prop fresh each decision.
- `res/values/strings.xml` — title/summary/category strings.

**Prop / sepolicy:** enable flag = `persist.gotweak.emergency_watchdog` → existing `gotweak_prop`
type (`device/xiaomi/mithorium-common/sepolicy/vendor/property_contexts:58`), already written by
GoTweaksSettings and read broadly → **zero new sepolicy** for Phase 0. Runtime guardrail state
(cooldown/cap timestamps) in Phase 2 will need either a new prop type or XiaomiParts write access
to `gotweak_prop` — decide then.

**⚠️ DRY_RUN gap to remember:** with `DRY_RUN=true`, enabling the toggle makes the watchdog
DETECT-and-LOG only (no radio nudge). That is the intended, safe Phase-0 behavior. The toggle's
summary describes the *real* (recovery) feature; flip `DRY_RUN=false` and land the nudge
(Phase 1 pick + Phase 2 guardrails) before shipping the toggle enabled to anyone but Kyle.

**How to run the Phase 0 dry-run (after build+flash):**
- Enable: Settings → System → Pepito Tweaks → Mobile network → "Auto-recover …", OR
  `adb shell setprop persist.gotweak.emergency_watchdog 1`.
- Watch: `adb logcat -s EmergencyWatchdog` — look for `armed` / `disarmed` / `WOULD-NUDGE`
  / `fire: …skip` lines at the real fringe spot. Validate it fires only on multi-minute
  emergency-only sticks (not blips, not dead zones), and check the classifier against
  nas-probe `status` ground truth.
- Gate to Phase 1: detection accurate, false-positive rate acceptable.

### Fast-iteration knob (added 2026-09-19/20)

Debounce is live-tunable via `persist.gotweak.ewd_debounce_s` (default 90, floor 5, read fresh at each arm; shell-settable — verified `setprop` works for the gotweak_prop namespace on new2). To exercise the WOULD-NUDGE fire path without waiting for a rare multi-minute stick, `setprop persist.gotweak.ewd_debounce_s 15` so the frequent ~30 s fringe drops trip it. Shipping default stays 90 s (prop unset). Field note 09-20 on new2: drops come in two flavors — `emg=true` (emergency-only, cell present → arms) and `emg=false` (OOS, no cell → dead-zone, ignored); all observed so far self-recover in ~26-40 s (< 90 s), which is why no fire had been seen. "Suspended" carrier notification = mobile-DATA network SUSPENDED during the same emergency-only drop (PDN preserved), not an account action — data-plane symptom of the same RF drop.

### FIRST REAL FIRE + two design findings (new2, 2026-09-20 10:32)

Caught a genuine ~3.3-min emergency-only stick on new2 (counter, screen-off). First real
WOULD-NUDGE: `stuck emergency-only 112s, call idle, cell present ... ps=reg3+emg cs=reg3+emg (LTE)`.
Fire path (debounce -> re-check still-stuck + call-idle -> classify -> decide) VALIDATED.

- **Reg state = DENIED (reg3), not SEARCHING (reg2).** The multi-minute sticks are the network
  actively rejecting the attach (backoff/forbidden), distinct from the ~30 s SEARCHING blips.
  Classifier handles both as EMERGENCY_LIMITED (emergencyEnabled=true) — correct.

- **FINDING A — blip resets the debounce.** A 3 s in-service flicker (10:30:15, after 70 s stuck)
  disarmed and re-armed from zero. Real sticks thrash; fully resetting on a sub-blip pushes the
  deadline back on a phone that's practically dead. FIX (Phase 1/2): tolerate brief in-service
  blips — require in-service SUSTAINED (e.g. >=10 s) before disarming, or track cumulative stuck
  time — so a thrashing stick fires promptly.

- **FINDING B — non-wakeup + inexact alarm defers.** Fired 22 s late while awake (112 s vs 90 s),
  and would NOT fire while the AP sleeps. But the real pain is the phone stuck on the counter
  SCREEN-OFF, where a non-wakeup watchdog sleeps too and never recovers it (incoming calls missed).
  REVISION to plan #2.2: the fire alarm should be a WAKEUP (`setExactAndAllowWhileIdle`,
  ELAPSED_REALTIME_WAKEUP) so screen-off sticks recover. Gated by cooldown + per-boot cap this is a
  few wakeups/day — bounded, nothing like a polling loop, so the battery story still holds. Battery
  A/B (Phase 3) must include a screen-off-stick scenario to confirm.

### Findings A + B IMPLEMENTED (2026-09-20, unbuilt)

EmergencyWatchdogController rewritten:
- **B (wakeup):** debounce is now `setExactAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP, ...)` via a
  PendingIntent broadcast to a dynamic NOT_EXPORTED receiver (the listener API has no
  allow-while-idle variant). Fires ON TIME even in Doze/screen-off. Manifest gains
  SCHEDULE_EXACT_ALARM (carried by system UID). Revises plan #2.2 (was non-wakeup).
- **A (blip tolerance):** alarm is CANCELLED on any non-stuck state (so a self-recovering stick =
  ZERO wakeups - keeps battery bounded), but mStuckSinceElapsed is preserved and a return to
  emergency-only within BLIP_TOLERANCE_MS (10 s) continues the same episode instead of resetting.
  So a thrashing stick fires at ~debounce from the TRUE start, and a sustained recovery ends it.
- Still DRY_RUN: detection/fire only. **Wakeup makes it ABLE to act screen-off, but the actual
  recovery (nudge) is not wired yet - so it does not yet save overnight calls, it logs that it
  would.** Next = Phase 1 nudge (does it clear the reg3 DENIED backoff w/o wiping WFC?), then flip
  DRY_RUN. Recommend gating the nudge behind its own prop (e.g. persist.gotweak.ewd_nudge) for safe
  live testing before overnight trust.

### REAL NUDGE implemented (Phase 1 candidate #1 = rescan) (2026-09-20, unbuilt)

Nudge wired up, gated OFF by default so it still ships dry-run:
- **Mechanism: network re-selection** (`setNetworkSelectionModeAutomatic`) - the gentlest candidate
  (no radio restart -> no WFC-wipe, no radio-stuck-off risk). Needs MODIFY_PHONE_STATE (added to
  manifest, carried by system UID). Open question the bake-off answers: does re-asserting AUTOMATIC
  when already automatic actually force a fresh PLMN search that clears the reg3 DENIED/backoff?
  If not, next lever = radio power cycle (`setRadioPower` off/on, heavier; verify WFC survives).
- **Guardrails:** cooldown (`persist.gotweak.ewd_cooldown_s`, default 900 s) + per-boot cap
  (`persist.gotweak.ewd_max_per_boot`, default 6). Both live-tunable.
- **Outcome logging:** after a nudge, logs `recovered <N>s after nudge` (success) or
  `nudge did not recover (re-stuck)` (failure) - this is how we measure whether rescan clears it.
- **Live knobs (all persist.gotweak.*, shell-settable):** `ewd_nudge` 0/1 (master; off=dry-run),
  `ewd_debounce_s` (90), `ewd_cooldown_s` (900), `ewd_max_per_boot` (6).

**Bake-off protocol (after build+flash, new2):**
1. Restart capture; `setprop persist.gotweak.ewd_debounce_s 15; ...ewd_cooldown_s 30`.
2. `setprop persist.gotweak.ewd_nudge 1`. Provoke/await a stick.
3. Watch: `NUDGE #n (rescan)` -> `recovered Ns after nudge` == WORKS; `nudge did not recover
   (re-stuck)` == rescan insufficient -> implement radio-cycle next.
4. Verify WFC survives a nudge (place a Wi-Fi call / check IMS reg) - the do-no-harm gate.

### DECISION 2026-09-21: ships OFF, stays experimental
User changed their mind on "default on once validated" - keep it OFF by default and live with it for
an extended period first. Verified nothing ships it on: no mk/prop/rc/overlay sets the props; code
defaults PROP_ENABLED=false and PROP_NUDGE=false; toggle XML defaultValue=false. Nudge is
DOUBLE-GATED - the Pepito Tweaks toggle only enables detection (emergency_watchdog); the radio action
needs a separate dev flag (ewd_nudge, no UI, default off), so a user enabling the toggle gets
dry-run detection only, never an auto radio action. UI summary now says "experimental". Revisit
default-on only after a long, uneventful live-with-it period. (Nudge mechanism is gentle rescan, NOT
airplane - user's "airplane all the time" worry was a misread of the earlier airplane analogy.)

### BAKE-OFF RESULT #1: rescan is INEFFECTIVE (new2 walk, 2026-09-21 09:32)
First clean captured nudge outcome. 46 s stick (reg2 SEARCHING variant: ps=reg2+emg cs=reg2):
`armed(15s)` -> `NUDGE #1 (rescan)` -> `nudge did not recover (re-stuck)` -> self-recovered ~31 s
after the nudge. So `setNetworkSelectionModeAutomatic` did NOT clear it - confirms the suspected
no-op when selection is already automatic. Caveat: this was the SEARCHING (reg2) variant where a
rescan is least likely to help; the DENIED (reg3) backoff variant is untested by rescan. Decision:
move to the heavier lever = **radio power-cycle** (setRadioPower off/on = DSRM's RADIO_RESTART), which
should force a clean re-attach on both variants. Build it as nudge mechanism #2 (prop-selectable),
with a stuck-off safety (alarm-driven power-on so a killed process can't strand the radio off) and a
WFC-survival check. Durable capture (on-device pidfile loop) finally worked - survived the walk.

### Radio-cycle nudge (mechanism #2) implemented (2026-09-21, unbuilt)
After rescan proved ineffective, added the radio power-cycle lever:
- `persist.gotweak.ewd_nudge_mech` = `rescan` (default) | `radio`. Radio-cycle:
  requestRadioPowerOffForReason(USER) -> WAKEUP alarm to a MANIFEST receiver
  (RadioOnReceiver) that clearRadioPowerOffForReason(USER) after ewd_radio_off_ms
  (default 3000, clamped 1-10s). Power-ON is scheduled BEFORE the off; manifest
  receiver + wakeup alarm => survives Doze and process death, so the radio can't be
  stranded off. Boot-time backstop in start(): if not airplane, clear any stranded
  USER off-vote. Post-nudge 8 s grace so the re-acquire transient isn't logged as
  "did not recover". MODIFY_PHONE_STATE added earlier; nothing new perms-wise.
- Files: EmergencyWatchdogController.java (+radioCycle/mech switch/boot-safety),
  RadioOnReceiver.java (NEW manifest receiver), AndroidManifest.xml (receiver decl).
- TEST PROTOCOL (after build+flash, as root): setprop ewd_nudge_mech radio (+ nudge=1,
  debounce=15, cooldown=30, max_per_boot=100); restart capture; provoke a stick; expect
  `NUDGE (radio-cycle) radio OFF, ON in 3s` -> `radio-cycle: radio ON` -> `recovered Ns
  after nudge` (WORKS) or `nudge did not recover`. THEN verify WFC still works (place a
  Wi-Fi call) - the do-no-harm gate before trusting radio-cycle.

### BAKE-OFF RESULT #2: radio-cycle ALSO ineffective (new2, 2026-09-21 11:14)
Radio-cycle DID really power the radio off (confirmed: data-eval showed RADIO_POWER_OFF at the
11:14:21 power-on) but did NOT recover the stick. Sequence: 11:14:18 NUDGE#1 (reg3 DENIED) -> "did
not recover (46s)" -> 11:15:19 NUDGE#2 (reg2) -> still stuck -> self-recovered ~11:16:40 (~78s after
last cycle, ~2.5min total). So neither rescan NOR a real 3s radio-cycle beats natural recovery.
Possible: (1) 3s off too short; (2) modem forbidden-PLMN/backoff survives an RF power-cycle (only its
own timer clears it); (3) "airplane fixes it in seconds" is partly confirmation/timing bias - these
self-clear on their own schedule (measured 26s..2.5min) and a mid-stick toggle gets the credit.
Rapid cycling may PROLONG (interrupts the modem's own retries) - stopped nudging.

DECISIVE NEXT TEST (ground truth): when new2 is stuck, do a MANUAL airplane toggle and measure
recovery vs how long it was already stuck, several times. If airplane does NOT reliably beat natural
recovery -> no nudge can help; the whole "automate the airplane toggle" premise is wrong and the
watchdog can't fix this (only detection/notification has value). If it DOES -> airplane does more
than an RF cycle (fuller teardown / longer off); replicate via longer ewd_radio_off_ms or the actual
airplane broadcast (WFC-wipe cost). Keep nudge OFF during the manual test to avoid confounding.
Also cheap to try: ewd_radio_off_ms=20000 (longer off) on the automated path.

### COMMITTED + soaking on new2 (2026-09-21)
Committed as-is, off by default, to let it soak while the bake-off plays out over real time:
- device/xiaomi/mithorium-common @ pepito-rmnet: **143e994** "XiaomiParts: add emergency-only
  recovery watchdog (experimental, off)" (controller + RadioOnReceiver + BootCompletedReceiver +
  manifest).
- packages/apps/LineageParts @ pepito-lineageparts: **69219ab8** "GoTweaks: add emergency-only
  recovery toggle (experimental, off)".
Ships OFF/double-gated/experimental (unchanged). new2 = the only unit running it, set to
DETECTION-ONLY at realistic timings for the soak: enabled=1, ewd_nudge=0, ewd_debounce_s=90,
ewd_cooldown_s=900. Goal: measure real-world stick frequency/duration + confirm detection is
accurate and harmless over days. Nudge left off (neither mechanism beat natural recovery).
PARKED for when there's time: the decisive manual-airplane-toggle test (does airplane actually beat
natural recovery, or is it timing/confirmation bias) - that decides whether the nudge is worth
pursuing at all or the watchdog becomes detection+notify only.
KNOWN LIMITATION: the on-device capture (/data/local/tmp/ewd-cap.sh) dies on reboot; for a durable
multi-day soak, add controller self-logging to a file (plan #7 ring buffer) - not yet built.
