# PLAN-bhy-pollmode.md — Prevent the BHy hub crash across suspend (poll-mode / stock-parity)

**Owner:** unassigned (hand-off plan for another agent)
**Status:** ✅ ROOT-CAUSED + FIXED — `8dc0c83fbe0b` (2026-09-20). §16 is the answer; §1-15 are the investigation trail. Remaining: new2 confirmation night.
**Device:** Palm PVG100 (pepito), MSM8937, LineageOS 23.2 (A16), kernel `android_kernel_xiaomi_msm8937` 4.19.x, branch `pepito-rmnet`.
**Driver:** `kernel/xiaomi/msm8937/drivers/misc/bhy/` (Bosch BHI160B fuser hub at i2c-2 0x28, Samsung "BHA250" variant forward-ported).

> **One-line goal:** stop the BHy hub firmware from crashing (to `FIRMWARE_IDLE`)
> under suspend/resume churn, instead of only resetting it after the fact. Palm's
> stock A8 driver keeps the same hub + same RAM patch alive for years; it runs a
> suspend-aware **poll-mode + software watchdog + live-lock detector** that our
> port dropped. Port the minimal effective subset.

---

## 0. Read first (context + what's already done)

Two BHy bugs were root-caused and fixed earlier; this plan is the third, separate piece.

| Commit | What it fixed | Memory |
|---|---|---|
| `0f46503b31ef` | `>256 B` FIFO reads hung the i2c-msm-v2 controller (BLOCK mode, DMA off) → 25 s unlock stall. Fix = drain FIFO in 250 B chunks. | [[bhy-hub-wedge-no-recovery]], [[i2c-msm-v2-block-mode-limit]] |
| `5b6a5ac104f9` | Recovery never fired: monitor parked on `ram_patch_loaded`; a param-ack wedge read "healthy" via CHIP_STATUS. Fix = `hub_ever_loaded` keeps the monitor armed + `param_ack_timeout()`/`param_wedged` fail-fast → Reset#0. | [[bhy-param-ack-hang-unlock-stall]] |

**What those DON'T fix, and why this plan exists.** Field-validated over two multi-hour
carries on new2 (`9c2e6b00`, build 20260913 #28). The user-visible slow unlock is gone
(71 unlocks, worst dispatch 360 ms). But the second carry's logpersist showed the hub
**crashing repeatedly overnight** (21:49→07:40, ~10 h): `MCU Malfunction Detected` ×111,
`Reset sequence started` ×12, `Ram patch loaded successfully` ×7. Each reset reloaded the
firmware; the hub ran briefly, then crashed back to `FIRMWARE_IDLE`, and the watchdog reset
it again. **Reset recovers but does not prevent — it became an all-night reset loop.** It
self-healed by morning, and daytime/active use runs clean for 16+ h. The crash correlates
with **overnight idle = suspend/resume cycling**, not active use.

Keep the two commits above as the safety net. This plan adds prevention *on top*; do not
remove the reset ladder or the fail-fast.

---

## 1. The trigger (CORRECTED 09-14 — read this before the rest)

> ⚠️ **The crash is NOT suspend-triggered. It follows a 9-DoF FUSION-sensor burst.**
> Correlating the 09-14 overnight logpersist: every reset cluster was preceded (by 2–27 min)
> by the HAL enabling **rotation vector (kernel handle 11 / sensorservice 0xc)** +
> **linear acceleration (10 / 0xb)** at 50 Hz. The requester is
> **`com.google.ccc.abuse.droidguard.events.b`** (Google DroidGuard / Play Integrity
> telemetry, uid 10109): it registers both for ~10–30 s then unregisters, every 5–40 min,
> around the clock. Plain accel (1) is on constantly and is NOT the discriminator.
> Enabling RV makes the hub power up mag + gyro and run the BSX 9-DoF fusion — the same
> thing a compass heading (Android Auto navigation, AR, any compass app) drives, only AA
> drives it continuously and in a magnetically hostile car.
> **This explains the overnight reset LOOP:** reset → reload → DroidGuard's next burst
> re-enables RV → fusion crashes the MCU again → watchdog → reset … all night.
> It also explains "overnight only": DroidGuard bursts continue overnight while the phone
> is stationary; 17 daytime bursts did NOT crash it, so it is **intermittent per burst**
> (stationary / no-motion, or cumulative state, may be a co-factor — to be bisected).
> Suspend/resume is coincident, not causal. Poll-mode remains relevant to *recovery*
> (§6 Option C) but is no longer the prime *prevention* lever.

**Hypothesis (revised):** the Palm BHI160B RAM-patch firmware crashes to `FIRMWARE_IDLE`
intermittently during or shortly after a rotation-vector (9-DoF fusion) enable/disable
cycle — either in the fusion math, or in the mag/gyro physical-sensor bring-up/teardown
the hub performs internally (via its soft-pass-thru to the BMI160/BMM150). Prevention
means understanding *that* transition: what config/sequence our stack applies vs stock,
and whether stock survives the identical DroidGuard load (silver runs Play Services too).

**Older hypothesis (kept for the record, now secondary):** suspend-aware poll-mode as the
reason stock stays healthy. Stock does have poll-mode + a SW watchdog + live-lock
detection (§3) and lacks our reset ladder; those are worth porting for *faster, gentler
recovery*, but the 09-14 data says the crash follows fusion enables, not suspend.

**Current synthesis (see §12 for the 09-14 repro data that produced it):** the crash needs
**BOTH** a 9-DoF fusion burst (DroidGuard's RV/linacc, above) **AND** the idle/autosleep
state — neither alone does it. Fusion-burst-alone while awake does NOT crash (bench-proven,
§12); the crash only appears overnight, when the device autosleeps ~59% of the time
(`wcnss_wlan`-driven, §12). So "fusion vs suspend" is a false choice: it's the fusion
session *interacting with* our suspend/resume handling (or with Doze deferring the FIFO
drain). Stock takes the identical fusion load and routinely switches to poll-mode without
crashing (§4/§12) — the leading explanation and the prevention lever, still to be confirmed
by a clean stock overnight. Per [[feedback-blackbox-before-re]], characterize on silver
before porting; do not assume poll-mode is the cure until silver survives an overnight that
new2 fails.

---

## 2. What our driver does now (the suspect surface)

`drivers/misc/bhy/bhy_core.c`:
- **IRQ:** `bhy_request_irq()` (~2483) — `request_threaded_irq(..., IRQF_TRIGGER_HIGH |
  IRQF_ONESHOT)`, level-high oneshot; `device_init_wakeup(dev, 1)`. INT stays high until
  the FIFO is drained; a failed drain re-fires (this was the 09-09 storm).
- **Suspend** `bhy_suspend()` (~7880): sets `HOST_CTRL_MASK_AP_SUSPENDED` on the hub, then
  `enable_irq_wake(irq)`. **The IRQ remains armed as a wake source across suspend.**
- **Resume** `bhy_resume()` (~7940): clears `AP_SUSPENDED`, `disable_irq_wake`, writes
  `BHY_REG_FIFO_FLUSH = 0xFF` (flush-all).
- **Recovery only:** `mcu_monitor_thread` (10 s poll) + Reset#0-3 ladder + (committed)
  `param_wedged` fail-fast. `check_watchdog_reset()` reads only CHIP_STATUS.
- **Absent** (grep-confirmed, all 0 hits): poll-mode, `poll_enable_flag`, `sw_watchdog`,
  live-lock detection, PM/fb notifier, poll delay, hrtimer. It *does* have some
  `host_status` helpers (13 refs) — check whether they're wired to the watchdog.

So across suspend we lean entirely on a level-high wake IRQ + a post-hoc reset. No mode
switch, no early live-lock catch.

---

## 3. What stock has (the map — from the A8 zImage, string-level)

Decompress the stock kernel and read the BHy strings to guide the port (do NOT blind-port;
use as a map, then observe live on silver — §4):
`Z=/home/kyle/Projects/android-pepito-backups/c39a6acf/stock-full-AML0/extracted/zImage`
(gzip member, inflate in python; see [[bhy-hub-wedge-no-recovery]] for the snippet).

Stock BHy mechanisms **we lack**, with their log-string anchors:
- **Poll ↔ IRQ mode switch:**
  - `bhy_irq_to_pollmode  switch to poll (delay=%lldms)` — switches to polling the FIFO at
    a computed delay (rate-derived).
  - `bhy_irq_to_pollmode--not-switch--rate=%d,poll_enable_flag=%d` — gated by sensor rate +
    a `poll_enable_flag`.
  - `bhy_poll_to_irqmode--switch to irq` / `already in interrupt mode` — switches back.
- **Software watchdog:** `bhy_sw_watchdog_work_func` + `&client_data->mutex_sw_watchdog`
  (a workqueue watchdog with its own lock, richer than our 10 s CHIP_STATUS poll).
- **Live-lock / liveness detection (the wedge itself):**
  - `Live lock detected!!!` + `Dump register after live lock condition`
  - `Read host status failed` / `Host status is still good`
  - `Read chip control failed` / `Chip control indicates CPU still running`
  - `Hardware watch dog bark!!!`, `Check point triggered but passed`
- **Suspend/resume notifier:** `--bhy--notifier_callback--bhy-suspend-` /
  `--bhy--notifier_callback--bhy-resume-`, plus `bhy_op_suspend`/`bhy_op_resume`
  (`Enter op suspend`/`Enter op resume`) distinct from `bhy_suspend`/`bhy_resume`.
  ⇒ stock does extra hub-state management on the suspend/resume edges (very likely the
  poll↔irq switch), driven off a notifier, not just dev_pm_ops.

Stock's likely model: on suspend (or when the IRQ path is unreliable) → `irq_to_pollmode`;
the SW watchdog periodically checks host-status + chip-control + live-lock and switches
back / recovers. This keeps the hub off the level-wake-IRQ across suspend.

⚠️ The stock driver is a **different variant** (plainer Bosch/Palm; no `BHA250`, no
`mcu_monitor`/Reset ladder). Don't try to merge whole files; lift the *mechanism*.

---

## 4. Phase 0 — Characterize stock live on silver (BLACK-BOX, do this first)

Silver (`4373dd0f`) is stock A8, unrooted, but **`shell` can read `dmesg`** on it. It's the
witness. (Roster/roles: [[dut-tcp-adb]], [[fleet-versions-20260903]]. Verify serialno first.)

- ⚠️ Stock logs BHy **very** verbosely (`[D]7BHY<bhy_set_sensor_conf>` per conf), so its
  kernel ring rotates in ~5 min. Cumulative `dmesg | grep -c` is unreliable — sample with
  `dmesg -w` / short windows, or `logcat -b kernel`.
- ⚠️ Use `/usr/bin/grep`, not the shell-hooked `grep` (rtk) — it gives false counts on big
  logs ([[rtk-grep-false-negative]]).

Questions to answer on silver:
1. **When does `irq_to_pollmode` fire?** At suspend? On IRQ stall? Continuously? Correlate
   with screen-off / suspend entries. This tells you the switch trigger to copy.
2. **Does stock ever log `Live lock detected` / `Hardware watch dog bark` / `MCU`
   malfunction in normal use?** If yes, stock *does* wedge and recovers by poll/watchdog
   (recovery matters more than prevention). If never, stock genuinely prevents it.
3. **Run silver overnight** (on a charger; [[bench-usb-hub-drain-trap]]) with sensors
   enabled and capture `logcat -b kernel` to a file. Compare against new2's overnight
   (reset loop). **Decisive:** does stock survive the same idle/suspend window without a
   crash loop? This is the go/no-go for "poll-mode prevents it."

Deliverable of Phase 0: a one-paragraph verdict — *prevention* (port the suspend poll-mode
switch) vs *faster recovery* (port the live-lock + host-status watchdog) vs *both*.

---

## 5. Phase 1 — Reproduce our crash deterministically (replicate the DroidGuard burst)

The trigger is now known (§1), so a bench repro is straightforward: **replicate
DroidGuard's pattern** on new2 via sysfs, phone stationary on the bench, root over USB:
```
cd /sys/bus/i2c/devices/2-0028
# enable linacc(10) + RV(11) at 50 Hz (conf = rate_lo rate_hi latency_lo latency_hi ...)
printf '\x0a' > sensor_sel; printf '\x32\x00\x00\x00\x01\x00\x04\x00' > sensor_conf
printf '\x0b' > sensor_sel; printf '\x32\x00\x00\x00\x01\x00\x04\x00' > sensor_conf
sleep 25            # DroidGuard holds them ~10–30 s
printf '\x0a' > sensor_sel; printf '\x00\x00\x00\x00\x00\x00\x00\x00' > sensor_conf
printf '\x0b' > sensor_sel; printf '\x00\x00\x00\x00\x00\x00\x00\x00' > sensor_conf
sleep 90            # then idle; crash arrived 2–27 min after a burst in the field
# repeat 15–30×; watch: dmesg 'MCU Malfunction Detected' / 'Reset sequence started',
# op_mode read latency (~0.05 s healthy vs ~2 s wedged), CHIP_STATUS FIRMWARE_IDLE.
```
A first such loop was started 09-14 (see [[bhy-param-ack-hang-unlock-stall]] for the
result). If it crashes within a few cycles → deterministic repro; then **bisect**: RV alone
vs linacc alone vs gyro(4)/mag(2) alone, burst length, idle gap, stationary vs moving,
and enable-only vs enable+disable (is the crash on teardown?). If it never crashes on the
bench but does overnight, the co-factor is real (no motion for hours? battery vs charger?
thermal?) — vary those.

Older notes on suspend-based repro (now secondary):
- Suspend/resume churn was the earlier suspected trigger. ⚠️ **USB adb blocks suspend on
  this build** (`78db000.usb failed to suspend`, aborts in 0.12 s) — see
  [[bhy-hub-wedge-no-recovery]]. So a bench repro needs real suspend: either
  (a) forced `echo mem` + RTC wakealarm loop from a root shell while USB is briefly idle,
  or (b) untethered (screen-off idle) with logpersist, read back on USB.
- ⚠️ **TCP adb keepalive recreates the churn trigger** and confounds — its unicast traffic
  drives suspend/resume ([[bhy-hub-wedge-no-recovery]]). Do NOT debug the crash over TCP;
  use USB for observation and logpersist for the untethered window.
- Enrol an accel client so the hub is producing across suspend (screen-off releases the
  HAL accel — force via sysfs `sensor_sel`/`sensor_conf` at `/sys/bus/i2c/devices/2-0028/`,
  or keep a real client). Distinguish a real wedge from an idle accel by **timing a param
  op** (`op_mode` read): ~0.05 s healthy, ~2 s wedged. Never infer from event freshness
  ([[bhy-hub-wedge-no-recovery]] false-positive).
- Tell = `dmesg` shows `MCU Malfunction Detected` / the hub reads `FIRMWARE_IDLE` on
  CHIP_STATUS while register I/O still works.

If you cannot force it on the bench, fall back to logpersist over a natural overnight (as
was done 09-14) — slower loop but real.

## 6. Phase 2 — Minimal viable prevention (pick per Phase 0 verdict)

Ranked, do the smallest that Phase 0/1 support. Keep the committed reset ladder + fail-fast
as the fallback under all of these.

**Option 0 — fix the fusion-enable crash itself (NEW, now first; prevention proper).**
- Once Phase 1 gives a bench repro, compare **our** RV/linacc enable sequence against
  **stock's** under the same DroidGuard load. Stock silver runs Play Services, so DroidGuard
  bursts hit it too: does silver's hub survive them? (`dmesg` readable unrooted; look for
  `Live lock detected`/`Hardware watch dog bark`/reset.) If stock survives the identical
  bursts, the difference is in *our* stack — candidates, in order: the ALGORITHM-page
  `working_mode` mask (stock writes `working mode mask`; check what ours sets),
  `meta_event_ctrl`/`fifo_ctrl` config, the mag/gyro sub-sensor config the hub applies
  (stock has FOC/offset/`bmi160_foc_*` paths), enable/disable *ordering* (RV vs linacc,
  which first, teardown order), or the 50 Hz rate. Diff live values via the sysfs nodes on
  new2 vs silver's equivalents.
- If stock ALSO crashes under DroidGuard bursts, it is the firmware; prevention is then
  "don't let DroidGuard's pattern reach a broken fusion path" (e.g. serve RV from a
  different path, or rate-limit/coalesce the enable churn) and the real win is Option C
  (fast, gentle recovery) — accept that and move on.
- Also test the obvious knob: does the crash need the *disable* (teardown)? If enable-only
  never crashes, leaving mag/gyro powered (or debouncing the disable) may sidestep it.

**Option A — suspend-aware poll-mode (the stock analog; now secondary to Option 0).**
- On `bhy_suspend` (or a registered PM notifier), switch the hub to poll-mode: stop relying
  on the level-wake IRQ (`disable_irq_wake` / mask), and either let the hub idle its FIFO
  or arm a poll on resume. On `bhy_resume`, switch back to IRQ. Mirror stock's
  `irq_to_pollmode(delay)` / `poll_to_irqmode`. A poll is an hrtimer/delayed-work that runs
  `bhy_read_fifo_data()` (already chunked, safe post-`0f46503b`).
- Rationale: removes the level-wake-IRQ-across-suspend interaction that is the prime crash
  suspect, without touching the (opaque) firmware.

**Option B — don't arm the IRQ as a wake source across suspend.**
- Cheapest experiment: in `bhy_suspend`, skip `enable_irq_wake()` (and gate wake behavior)
  so the hub isn't driving the AP awake mid-suspend. If the crash stops, the wake-IRQ path
  was the trigger and Option A is the productized form. If not, poll-mode alone won't help
  and you're in Option C territory.

**Option C — richer watchdog + live-lock detection (faster catch, if crash is unpreventable).**
- Extend `check_watchdog_reset()` beyond CHIP_STATUS: add host-status + chip-control
  (CPU-running) reads (stock: `Host status is still good`, `Chip control indicates CPU
  still running`) and a live-lock signature, so a crash is caught in <1 s instead of the
  10 s poll, and (from the committed fix) a param probe. Cap the reset loop: after N failed
  resets fall to poll-mode instead of a 30 min `skip_reset` backoff (the loop that ran all
  night). Lower `RESET_TIMEOUT` (currently 30 min) regardless.

Note the committed recovery review flagged follow-ups worth folding in here: make the
`irq_force_disabled` guard atomic (test-and-set) so a sysfs+IRQ race can't double-disable
the IRQ; two-strike (not one) latch for `param_wedged`; add a param read to the health
probe; include `param_wedged` in the Reset#0 condition. See [[bhy-param-ack-hang-unlock-stall]].

## 7. Phase 3 — Implement in our tree

- Files: `drivers/misc/bhy/bhy_core.c` (+`bhy_core.h`). Likely new: a poll worker
  (hrtimer or delayed_work), a `poll_enable_flag`, mode-switch helpers, optional PM/fb
  notifier registration in `bhy_probe`. Keep names close to stock for grep-ability
  (`bhy_irq_to_pollmode`/`bhy_poll_to_irqmode`).
- Preserve: the 250 B chunked `bhy_read_fifo_bytes()`, the `param_wedged` fail-fast, the
  monitor + reset ladder (as fallback), `hub_ever_loaded`.
- Kernel-style: tabs; kernel-doc-ish comments explaining *why* (this tree's convention).
- ⚠️ pepito's `bhy@28` has **no `bhy,ldo_enable`** → `reset()` is soft-reset only (no LDO
  power-cycle). Poll-mode must not assume a hard reset is available.

## 8. Phase 4 — Validate

- ⚠️ **Kyle builds + flashes** ([[feedback-user-does-build-flash]]): stage, describe, stop.
  Builder is Stellaris16 (10.0.2.43); it builds the *dirty* working tree
  ([[builder-tree-divergence]]) — so an uncommitted change is testable. Read `out/error.log`.
- Success criteria (in priority order):
  1. **No MCU-malfunction / reset loop overnight.** Repro Phase 1 (forced suspend loop, or a
     natural overnight with logpersist). new2 must go a full idle-overnight with **zero**
     `MCU Malfunction Detected` and **zero** `Reset sequence started`, or a bounded few that
     recover in <2 s and don't recur — vs the 12-reset/111-malfunction loop on `5b6a5ac`.
  2. Sensors stay live across suspend (accel event stream resumes promptly on wake; param
     op stays ~0.05 s; `bhy` IRQ/poll advancing).
  3. No user-visible regression: unlock dispatch stays sub-second (was ≤360 ms); no new
     `TIMEOUT_ERROR`; auto-rotate works after resume.
  4. Battery: no standby-drain regression (the reset loop's `reset_wlock`/`patch_wlock`
     churn should be gone). A/B the airplane/idle floor if in doubt ([[xo-shutdown-suspend-floor]]).
- Capture with logpersist (already enabled on new2: `persist.logd.logpersistd=logcatd`);
  kernel lines ARE bridged into logpersist (the `param_ack_timeout` line was captured), so
  `Reset sequence started` / `MCU Malfunction` will show. Pull `/data/misc/logd/` and grep
  with `/usr/bin/grep`.

---

## 9. File / reference map

| What | Where |
|---|---|
| Our BHy driver | `kernel/xiaomi/msm8937/drivers/misc/bhy/{bhy_core.c,bhy_core.h,bhy_i2c.c,bhy_host_interface.h}` |
| Our IRQ / suspend / resume | `bhy_core.c` `bhy_request_irq` (~2483), `bhy_suspend` (~7880), `bhy_resume` (~7940) |
| Our recovery (keep as fallback) | `bhy_core.c` `mcu_monitor_thread`, `reset()`, `check_watchdog_reset()`, `param_ack_timeout()` |
| Stock kernel (poll-mode map) | `~/Projects/android-pepito-backups/c39a6acf/stock-full-AML0/extracted/zImage` (gzip member; inflate + strings) |
| Live stock witness | silver `4373dd0f` (A8, unrooted; `shell` reads dmesg). Verify serialno; roster `~/.config/pepito/units.conf` |
| Problem unit | new2 `9c2e6b00` (A16 build #28; logpersist on; real IP 10.0.2.123 not roster's .103) |
| Committed fixes | `0f46503b31ef` (FIFO chunk), `5b6a5ac104f9` (recovery) on `pepito-rmnet` |
| Sensors plan (parent) | `PLAN-sensors.md` (has the 09-09 + 09-13 banners) |

## 10. Gotchas (read before touching hardware)

- [[feedback-blackbox-before-re]] — characterize stock live (Phase 0) before disassembling; use the zImage strings as a map only.
- [[bhy-hub-wedge-no-recovery]] — USB adb blocks suspend; TCP adb recreates the churn trigger; the flat-accel false-positive (always time a param op).
- [[rtk-grep-false-negative]] — use `/usr/bin/grep` on load-bearing counts, never the hooked `grep`.
- [[builder-tree-divergence]] — builder builds the dirty tree; compare with `rsync -rncc`, not `git status`; read `out/error.log`.
- [[feedback-user-does-build-flash]] — stage + describe, no flashing/reboots from the agent.
- [[bench-usb-hub-drain-trap]] — park units on a wall charger for overnight runs.

## 11. Acceptance criteria
- [ ] Phase 0 verdict written (prevention vs recovery vs both), backed by silver overnight data.
- [ ] Deterministic (or repeatable overnight) repro of the MCU-idle crash on new2.
- [ ] Minimal prevention implemented (Option A/B/C per verdict), reset ladder + fail-fast retained.
- [ ] Overnight validation: zero (or bounded, <2 s, non-recurring) `MCU Malfunction`/`Reset` vs the `5b6a5ac` loop.
- [ ] Sensors live across suspend; unlock sub-second; no `TIMEOUT_ERROR`; auto-rotate post-resume.
- [ ] No standby-drain regression.
- [ ] `PLAN-sensors.md` banner + `MEMORY.md` updated; committed on `pepito-rmnet`.

## 12. 2026-09-14 repro findings — corrects §5 method (READ)
- **Fusion burst ALONE (awake) does NOT crash it.** 20× [RV+linacc @50 Hz 25 s → off → idle 90 s], stationary, USB-awake: 0 malfunction/reset, op_mode 0.05–0.06 s throughout. So the §5 bench loop is necessary-but-insufficient — a co-factor is required.
- **`echo mem` cannot force a suspend on this build** — it aborts at `78db000.usb` (`platform_pm_suspend … -16`) in ~0.15 s **even when unplugged** (confirmed via a device-side `nohup`, no adb shell held). So a scripted forced-suspend repro is impossible here. ⚠️ Delete the "forced `echo mem` loop" idea.
- **But the device autosleeps heavily on its own:** boottime 74251 s vs awake-clock 29954 s ⇒ **~59 % asleep**, 128 real `Resume caused by IRQ 71, wcnss_wlan` in one ring (WiFi-driven churn — same wake source as the 09-09 bug). Suspend is real; only the *manual* path is broken.
- ⇒ **The suspend co-factor can only be exercised by NATURAL autosleep** (screen-off, unplugged, no wakelocks, left idle) — i.e. an overnight with logpersist, not a script. Refined trigger = **DroidGuard 9-DoF fusion burst + real autosleep**; both needed.
- **Live stock comparison (silver, 4373dd0f) is the decisive experiment and it's running.** Stock takes the identical DroidGuard RV/linacc load and fires `bhy_irq_to_pollmode` **routinely** (4 switches in the first 5 min), 0 `Malfunction`/`Live lock`/`watch dog bark`. A durable sampler is running at `/data/local/tmp/bhy-sample.raw` (stock's ring rotates ~5 min). **Go/no-go:** if silver survives a full idle-overnight clean while new2 crashes, poll-mode is confirmed as the prevention and Option A/Option 0 is the fix. If silver also crashes, it's the firmware ⇒ Option C (gentle recovery).
- **Method for the implementer:** do NOT script `echo mem`. Reproduce by (a) leaving new2 idle-overnight with logpersist and reading `/data/misc/logd/` back on USB, and (b) running silver's sampler alongside. Bisect the FUSION side (RV vs mag/gyro, enable-only vs teardown, rate) on the awake bench where it's safe; the suspend side only exists naturally.

## 13. 2026-09-15 — Probe #1 STAGED (skip resume FIFO_FLUSH) + same-unit A/B protocol
The overnight crash needs fusion + autosleep (§12). `bhy_resume()` unconditionally writes
`FIFO_FLUSH=0xFF` on every resume (~128/night); flushing all FIFOs while 9-DoF fusion runs
is the leading single trigger, and stock never does it (poll-mode). **Staged (uncommitted)
in `bhy_core.c`:** module param `bhy_resume_flush` (default 0 = skip the flush; the batched
data still arrives on the next IRQ). This isolates ONE variable and, unlike skipping
`AP_SUSPENDED`, has no suspend-prevention side effect (the hub still batches + the AP still
sleeps normally).

**Test on dut1 (`c39a6acf`), same-unit A/B via the runtime param — no reflash between nights:**
1. Build the `pepito-rmnet` working tree (has both committed fixes + this probe), flash dut1.
2. Confirm the param path: `ls /sys/module/*/parameters/bhy_resume_flush` (built-in, likely
   `/sys/module/bhy_core/` or `/sys/module/bhy/`). Default reads 0 = flush skipped.
3. **Night A (flush OFF, default):** leave dut1 idle/unplugged overnight. Morning: pull
   `/data/misc/logd/`, `/usr/bin/grep -c "MCU Malfunction Detected"` and `"Reset sequence"`.
4. **Night B (flush ON = original):** `echo 1 > /sys/module/.../bhy_resume_flush`, repeat.
- **Flush OFF clean + Flush ON crashes ⇒ the resume flush is the trigger.** Productionize
  (drop the flush unconditionally, or keep it only when no fusion sensor is active) and this
  plan's big poll-mode port may be unnecessary.
- **Flush OFF still crashes ⇒ not the flush.** Next probes, in order: (b) skip the
  `AP_SUSPENDED` toggle too (⚠️ may stop the device suspending — watch boottime-vs-awake), 
  (c) don't arm `enable_irq_wake` across suspend, then (d) the full poll-mode port.
- new2 stays the concurrent unfixed control (crashes nightly as daily driver).

## 14. 2026-09-15 — Probe #1 flashed to dut1 (build #30); test setup refined
dut1 flashed with the resume-flush probe (build #30, `bhy_resume_flush=0` default = flush
skipped). ⚠️ **Test-condition gotcha:** dut1 had `stay_on_while_plugged_in=15` (stay-awake-
while-charging ON) → would NOT autosleep on the charger, confounding it like silver. Set to
0. Correct overnight setup = **on the charger, screen off, WiFi ON, airplane OFF, no held
adb session.** This gives full battery + new2's real crash conditions (wcnss_wlan wake-churn
+ DroidGuard fusion bursts + autosleep). ⚠️ Do NOT use airplane mode: it drops WiFi (the
wake source) and may throttle DroidGuard → risk of a false "clean". Night A = flush skipped;
Night B = `echo 1 > /sys/module/bhy_core/parameters/bhy_resume_flush` (same-unit A/B).

## 15. ★ IMPLEMENTATION PLAN (2026-09-17) — investigation done, ready to build
Root cause + fix direction are settled; this is the build plan. Keep the committed recovery
(`0f46503b` chunked reads, `5b6a5ac` reset-monitor + param-wedge) as the safety net.

**Two test beds, two questions (Kyle, 09-17):**
- **dut1 (`c39a6acf`) = "does it WORK?"** — functional validation of every build *before* it
  goes near the daily driver: boots, hub loads, param path present, sensors stream (accel / RV /
  auto-rotate), wake gestures (SMD / tilt / pickup), unlock timing, the device still autosleeps
  (boottime vs awake clock), no new dmesg errors, poll↔irq switches logged as expected. Hours,
  on USB, same afternoon. dut1 CANNOT reproduce the crash (no attesting-app load) — a clean
  dut1 night is NOT evidence of prevention; never read it that way.
- **new2 (`9c2e6b00`) = "does it PREVENT?"** — the stress bed. Real DroidGuard load crashes it
  reliably *over time* (~10-12/night), never on demand. Only a dut1-passed build goes on it;
  then 1-2 normal-use nights per cell, crash count from logpersist vs its own ~10/night
  baseline. Reachable over Tailscale `100.82.14.21:5555`; logpersist on.

**What we know:** crash = MCU → FIRMWARE_IDLE during suspend/resume while 9-DoF fusion (RV/linacc)
is active. Stock survives the identical load (silver, 170 suspends, 0 crashes) using **hrtimer
poll-mode** + a richer watchdog; our driver uses only the level-wake-IRQ + the `bhy_suspend`
`AP_SUSPENDED|=` + `enable_irq_wake` / `bhy_resume` `AP_SUSPENDED&=~` + `FIFO_FLUSH=0xFF` handshake.
The crash is somewhere in that handshake-with-fusion.

### Phase 1 — Bisect the suspend handshake on new2 (cheap, isolating; may yield a 1-line fix)
One probe build, module-param toggles (like the committed `bhy_resume_flush`), flip per night at
runtime — no reflash between nights (`/sys/module/bhy_core/parameters/…`):
- `bhy_resume_flush`: 0 = skip the resume `FIFO_FLUSH=0xFF`.
- `bhy_suspend_apsusp`: 0 = skip the `AP_SUSPENDED` set/clear.
- `bhy_suspend_irqwake`: 0 = skip `enable_irq_wake` (⚠️ verify wake-gesture sensors — SMD/tilt/
  pickup — still function; those legitimately need the wake path).
**STAGED 09-17 (uncommitted, `bhy_core.{c,h}`).** ⚠️ Defaults are now ALL 1 = original
behaviour (this flips `bhy_resume_flush` from the §13/14 probe's default of 0), so a fresh boot
of the probe build IS the known-crashing baseline and every cell is a deliberate runtime flip.
Every suspend/resume logs the live values (`Enter suspend (apsusp=1 irqwake=1)` /
`Enter resume (flush=1)`), so logpersist itself records when a flip took effect — no need to
note wall times. Also fixes a latent wake-refcount drift: resume now undoes `enable_irq_wake`
only if suspend actually armed it (`irq_wake_armed`), instead of re-testing `irq_force_disabled`.
**dut1 first (same afternoon):** flash the probe, then flip each toggle on dut1 for an hour or
two and check its side effects before it ever spends a night on the daily driver —
`bhy_suspend_apsusp=1` must not stop autosleep (compare `/proc/uptime` vs the dmesg clock:
the device must keep sleeping), `bhy_suspend_irqwake=1` must not break pickup / tilt /
significant-motion wake, and all three must leave accel/RV streaming and unlock sub-second.
**Then new2:** flash, and A/B each toggle one night at a time against the all-on baseline (its
own nightly ~10 crashes is the control; flip at runtime, note the wall time). **A toggle that
drops the night to ~0 = the culprit → minimal fix, no poll-mode port needed.** Metric from
logpersist: `Ram patch loaded successfully` (real crashes) + `Reset sequence started`, split by
the wall time the param was flipped.

### Phase 2 — The fix
- **If one op is the culprit:** guard/drop it (only when a non-wakeup/fusion sensor is active, to
  avoid regressing wake gestures). Add active-non-wakeup tracking in `bhy_store_sensor_conf`
  (a counter; today only `acc_enabled`/`step_*`/`tilt`/etc. bools exist, RV/linacc untracked).
- **If no single op is it (it's the IRQ-driven-across-suspend model itself):** port stock's
  poll-mode: an `hrtimer` drains the FIFO via the committed `bhy_read_fifo_bytes()` at the sensor
  rate (`interrupt_poll_delay_msec`), engaged when non-wakeup sensors are active; in poll-mode,
  `bhy_suspend`/`resume` skip the wake-IRQ + FLUSH handshake and just poll-drain on resume.
  Mirror stock's `bhy_irq_to_pollmode`/`bhy_poll_to_irqmode` + `poll_enable_flag` switch on
  `sensor_conf`. Optionally also port the richer watchdog (host-status + CPU-running) for faster
  detection. Keep it behind a module param (default on) for a clean A/B.

### Validation — dut1 gate, then new2 stress
**dut1 (functional gate, every build, same day):** boots; `Ram patch loaded successfully` once;
`/sys/module/bhy_core/parameters/*` present; accel + RV stream (`sensor_sel`/`sensor_conf` or
a sensor-test app), auto-rotate works after a screen-off/on; pickup / tilt / SMD wake the
screen; unlock dispatch sub-second (the committed win must not regress); device still
autosleeps on the charger with `stay_on_while_plugged_in=0`; in poll-mode builds the
`irq_to_pollmode` / `poll_to_irqmode` lines fire on sensor enable/disable and the poll
actually drains (event stream fresh after a suspend/resume); no new dmesg errors. A build that
fails any of these does NOT go to new2.
**new2 (stress, 1-2 normal-use nights per cell):** success = `Ram patch loaded successfully` /
`Reset sequence started` fall from ~10/night to ~0, with the same functional checks holding in
daily use and no standby-drain regression (the reset loop's `reset_wlock`/`patch_wlock` churn
gone). A bounded few crashes that recover in <2 s and don't recur is acceptable; a loop is not.

### ⚠️ new2 stress-bed preconditions (found 09-17 pm — both would silently void a night)
1. **`stay_on_while_plugged_in` is 15 on new2** (stay-awake-while-charging ON). Boot of 09-17 08:40 →
   16:00: 0 suspends, 0 % asleep. On a charger it never autosleeps ⇒ never crashes ⇒ a false
   "clean". Stress nights need it **0** (or the phone unplugged overnight). Same trap as silver/dut1.
2. **Tailscale (`com.tailscale.ipn`, uid 10204) floods logcat ~130 lines/s** (`gojni`/`App:
   bindSocketToActiveNetwork: no cached default network; noop`) ⇒ logpersist (64 MB) now holds
   only ~2 h; the earlier overnight counts came from a 10 h+ window that no longer exists. It also
   burns ~1750 s CPU per 7.4 h (~6.5 % of a core) — a daily-driver drain in its own right. Until
   fixed (restart/reinstall Tailscale, or it clears when the default network comes back), **count
   crashes from `dmesg`** (1 MB ring, holds a full day of the kernel's low volume; this boot's
   markers: `Ram patch loaded successfully` / `Reset sequence started` / `MCU Malfunction`) with
   `/sys/fs/pstore/console-ramoops-0` as the fallback if it rebooted. Or set
   `persist.logd.logpersistd.buffer=kernel,system` so logpersist ignores `main`.

### Files / risks
- `drivers/misc/bhy/bhy_core.{c,h}` only. Touch: `bhy_suspend`/`bhy_resume` (~7860-7975),
  `bhy_request_irq` (~2483), `bhy_store_sensor_conf` (~2757), the client_data struct.
- Risks: mode-switch races (guard with a mutex, e.g. stock's `mutex_sw_watchdog`); don't break
  wake-gesture sensors (they need the IRQ wake); hrtimer/IRQ refcount balance; interaction with
  the committed `param_wedged`/reset paths. pepito has **no `bhy,ldo_enable`** ⇒ soft reset only.
- ⚠️ Kyle builds+flashes; stage + describe. new2 is the daily driver — nothing reaches it
  without passing the dut1 gate first; it stays reachable (Tailscale `100.82.14.21:5555`) +
  logpersist on.

## 16. ★★★ ROOT CAUSE FOUND 2026-09-17 evening — it was never the hub. Fix STAGED (uncommitted).
**The "overnight MCU crash" is our own `mcu_monitor_thread` racing system suspend.** The dut1
knob cycle's phase B (apsusp=0) turned into a suspend/abort loop (430 suspend attempts in 52 min,
one every ~340 ms) and that made the collision easy to catch in the kernel ring:
```
Enter suspend
i2c-msm-v2 78b6000.i2c: slave:0x28 is calling xfer when system is suspended   (×10 = bhy_read_reg retries)
BHY<check_watchdog_reset> Read chip status failed (-5) -- treating as malfunction
BHY<mcu_monitor_thread>   MCU Malfunction Detected ... Try to Reset#3 → Reset sequence started
Enter resume → Write flush sensor reg error → dpm_run_callback(): bhy_pm_op_resume returns -5
```
Mechanism: the monitor is a non-freezable kthread that reads CHIP_STATUS every 10 s regardless of
PM state. i2c-msm-v2 refuses transfers between its `suspend_noirq` and `resume_noirq` (-EIO) and a
transfer straddling the edge times out (-110). With ~0.4 % of suspends colliding with a 10 s poll,
a phone that suspends 130-3000×/day gets 1-13 collisions/day. Since `5b6a5ac` (09-09) a failed
status read = malfunction = **immediate Reset#3**; the reset's RAM-patch reload then often
straddles the *next* suspend and fails too ("Reset sequence started" without "Ram patch loaded"),
leaving the hub with no firmware for minutes until a later reload sticks — the "reset loop".
Side chains: the failed monitor read arms the bhy_i2c 15 s breaker → the resume's FIFO_FLUSH fails
→ `bhy_resume` early-returned with `in_suspend` still set; the post-reset "Zero length FIFO" IRQ
storm → `int_force_disable` → Reset#0 ("Int High detected"); `cnt_no_response` never cleared, so
strikes accumulated through a 30-min backoff and fired a reset when it lifted, hours later.

**Evidence (all `MCU Watchdog!` = FIRMWARE_IDLE counts are ZERO — the hub firmware has never been
seen crashed in any log we hold):**
| Log | suspends | xfer-when-suspended | chip-status fails | resets | FIRMWARE_IDLE |
|---|---|---|---|---|---|
| new2 09-15 08:15→20:13 (`captures/new2-emerg-20260914`) | 2969 | 72 | 13 (12×-5, 1×-110) | 7 | 0 |
| dut1 09-16 (Night A/B, airplane) | ~160 | 66 | 12 | 3 | 0 |
| dut1 09-17 incl. knob cycle | — | 50 | 10 | 5 | 0 |
| dut1 knob phases A/C/D (normal wake spacing) | 120 | 0 | 0 | 0 | 0 |
| dut1 knob phase B (suspend storm) | 430 | 30 | 6 | 3 | 0 |
Every reset in the 09-15 capture traces to a collision (-5/-110), a stale strike count, or the
post-reset IRQ storm. Stock has no such monitor thread ⇒ "stock survives, we don't", explained.
The DroidGuard fusion correlation was exposure, not cause (its bursts add wakeups/suspends). The
suspend handshake (flush / AP_SUSPENDED / irq_wake) is innocent; phase D (flush=0) changed nothing.

**Fix staged in `bhy_core.c`/`.h` (compiles; knobs removed):**
1. `mcu_monitor_thread` is **freezable** (`set_freezable()`, `wait_event_freezable[_timeout]`): parked
   with user space before any device suspends, thawed after all resume; an in-flight
   `reset()`/reload holds the freezer (≤20 s) so a reload can no longer be torn by a suspend.
2. `check_watchdog_reset()` returns "no evidence" while `in_suspend` (belt to the brace).
3. **3 strikes** (`BHY_MCU_STRIKES`, 30 s > the 15 s breaker cooldown) before Reset#3, and a
   passing poll **clears** the count (no more stale-strike resets).
4. `bhy_resume()` never early-returns before clearing `in_suspend`; bus errors are logged and
   returned at the end. `irq_wake_armed` keeps enable/disable_irq_wake balanced.
5. The three 09-17 bisect module params are removed (handshake exonerated; probe knobs shouldn't ship).
Kept: `0f46503b` chunked reads, `param_wedged` fail-fast, the reset ladder as the safety net.

**Validation (dut1 gate → dut1 night → new2 night):** `diag-tools/bhy-gate/bhy-gate.sh <serial>`
then overnight on the charger (`stay_on_while_plugged_in=0`), then `bhy-gate.sh <serial> night`:
PASS = 0 `calling xfer when system is suspended`, 0 `Read chip status failed`, 0 `Reset sequence
started`, exactly 1 `Ram patch loaded successfully` (boot), sensors/rotate/wake gestures fine.
dut1 alone is now a valid prevention bed: its old build showed the signature every night (12 and 10
fails), so a clean night on the fix build is real evidence; new2 confirms under daily-driver load.
The poll-mode port (§6 A / §15 Phase 2) is **not needed**. §1's "hub crashes during fusion" is
superseded by this section.

### ✅ 09-18 — fix VALIDATED on dut1 (build 20260918)
Natural-churn window on the wall charger, 08:30→15:00 (logpersist): **2331 `Enter suspend`, 0 `calling
xfer when system is suspended`, 0 `Read chip status failed`, 0 `MCU Malfunction`, 0 `Reset sequence
started`, 0 reloads, 0 `Unbalanced IRQ`, 0 `bhy_pm_op_resume` errors, 0 `Freezing of tasks failed`.**
Old-build reference: 2969 suspends → 72/13/7 (new2 09-15); dut1 old build 12 and 10 fails/day. At the
old ~0.4 %/suspend rate 2331 cycles ⇒ ~9 expected; P(0) ≈ 1e-4. Gate on USB also clean; monitor thread
confirmed freezable (`/proc/<pid>/stat` flags 0x200040, PF_NOFREEZE clear). Accelerated RTC-wakealarm
storm (`/data/local/tmp/bhy-suspendstorm.sh`, 5 h from 17:19) running on top; poller log
`scratchpad/dut1-storm-mon.log`. ⚠️ Lesson: never `stop adbd`/`adb tcpip` AFTER starting a device-side
nohup script — Android kills the service's whole process group (the first storm died that way). Set TCP
adb first, then start scripts. Next = flash new2, one night with `stay_on_while_plugged_in=0`, then commit.
**09-20 FINAL dut1 number (build 20260918, one boot 09-18 17:16 → 09-20 07:09, wall charger, WiFi,
natural churn + the 5 h storm): `Enter suspend` = 16 036; `calling xfer when system is suspended` = 0;
`Read chip status failed` = 0; `MCU Malfunction` = 0; `Reset sequence started` = 0; reloads = 0;
`Unbalanced IRQ` = 0; resume errors = 0; freezer failures = 0; ack timeouts = 0; IRQ force-disables = 0.**
Old-build rate ⇒ ~64 collisions expected in that many cycles. The fix is proven on dut1; commit-ready.
new2 night = confirmation under daily-driver load, not a gate.

**09-21:** dut1 on the committed build 20260920 (not just the staged tree): second boot 8797 suspends, 0 failures ⇒ ~24 800 cumulative. new2 confirmation night still the only open item.
