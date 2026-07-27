# LineageOS 23.2 — Sensors Bring-up (pepito / PVG100)

> ## ✅ SOLVED 2026-07-23 — STEP COUNTER WORKS (was always 0). Fix = use the hub's NATIVE step handles, not the custom pedometer slot.
>
> **Fix validated on hardware the same day.** `std_step_handles=1` (new
> `bhy_core.c` module param, **now default 1**) skips the custom-pedometer
> indirection and lets the hub's own handle-18/19 frames through. Live result
> on DUT1 with a real walk: step counter climbed **0 → 5 → 6 → 7 → 8 → 13 → 18
> → … → 30**, monotonic, stopping when walking stopped; **zero**
> `Param is not accepted`. Note the hub delivers in **bursts** (several `+5`
> jumps), and `step_counter` is cumulative *since boot* — an app showing a
> different running total (observed: app said 10 while the sensor said 30) is
> doing its own baseline/daily accounting, not a sensor fault.
>
> **The patch (4 coordinated changes + 1 independent bug fix):**
> 1. `std_step_handles` module param (`0644`, default 1) — runtime A/B, escape hatch.
> 2. FIFO parser no longer drops native 18/19 frames (it dropped them so the
>    synthesized pedometer frames couldn't duplicate; in native mode they ARE
>    the source).
> 3. `bhy_store_sensor_conf` skips `enable_pedometer()` for 18/19 — its
>    `-EINVAL` used to `return` early, before `step_*_enabled` was ever set.
> 4. `sync_sensor()` restores the native step sensors at their last requested
>    rate after a hub reset (newly reachable now that the wedge recovery fires);
>    new `step_det_delay`/`step_cnt_delay` in `bhy_core.h`.
> 5. **Independent:** `enable_pedometer()` now rolls back its `static int count`
>    on a failed enable. It was bumped *before* the hardware attempt and never
>    rolled back, so after the first failure every later enable hit the
>    `(int)enable != count` early return — a **fake success** that never touched
>    the hub. That is why a later `sensor: 19, enable: 200` "succeeded" and
>    reported `cnt = 0`, and why it could never re-arm for the rest of the boot.
>
> ⚠️ **No recursion:** `enable_sensor(18/19)` → `bhy_store_sensor_conf` is
> guarded by `!std_step_handles`, so `enable_pedometer` is never re-entered.
> The legacy path is unaffected (slot 60 is not intercepted). The `shealth`
> sysfs path (~6852) still drives the custom slot **by design** — that is
> Samsung's own feature, not the Android step sensors.
>
> ⭐ **The decisive evidence was already in the logs, before any patch:**
> `bhy_store_sensor_conf` writes the hardware param *first* and only logs
> `sensor: N, enable: M` *after* that write succeeds. `sensor: 19, enable: 1`
> appears, and only the **nested** `CUSTOM_3_WU` write is refused. So the
> firmware always accepted the standard handle — worth remembering as a
> log-reading technique: know which line proves which step succeeded.
>
> Historical root-cause record follows.
>
> **Symptom (as originally reported):** `android.sensor.step_counter` (0x10) and `step_detector` (0x0f)
> enumerate fine and a subscriber attaches with `result=OK`, but the count is
> pinned at **0** forever — walking never moves it. Confirmed live on DUT1
> with a real pedometer app (`com.kjm.stepcounter`) subscribed and a real walk
> (Significant Motion fired `1.00` at the same time, so the hub *was* seeing
> the motion). **This is NOT the suspend/resume wedge and NOT a release-bringup
> regression — it has never worked on our build.**
>
> **Root cause (source-confirmed, `drivers/misc/bhy/bhy_core.c`):** Android's
> step sensors are **not** native hub sensors here. The driver *synthesizes*
> both from the hub's custom pedometer slot:
> ```c
> #define PEDOMETER_SENSOR  BHY_SENSOR_HANDLE_CUSTOM_3_WU   /* = 60 */
> #define PEDOMETER_CYCLE   50 /* HZ */
> ...
> if (sensor_type == PEDOMETER_SENSOR)
>         generate_step_data(client_data);   /* makes step det + step cnt */
> ```
> A HAL write of `sensor_sel = BHY_SENSOR_HANDLE_STEP_COUNTER (19)` or
> `STEP_DETECTOR (18)` is intercepted in `bhy_store_sensor_conf` (~2659-2670)
> and redirected to `enable_pedometer()` → `enable_sensor(CUSTOM_3_WU, …)` →
> `bhy_write_parameter()`. **Palm's firmware answers that param write with
> `ack == 0x80`** = "not accepted" → `-EINVAL`:
> ```
> [I]BHY<enable_pedometer><6690>enable pedometer 1
> [E]3BHY<bhy_write_parameter><215>Param is not accepted
> [E]3BHY<enable_pedometer><6695>enable pedometer error
> ```
> No pedometer frames ever arrive → `generate_step_data()` never runs → 0.
>
> ⭐ **Same bug class as `3ff1a97`** (the wake-channel INITIALIZED meta event):
> this driver is **Samsung-derived** and assumes a custom-slot mapping that
> Palm's BHI160B firmware does not share. Note `bhy_host_interface.h` *does*
> define standard `STEP_DETECTOR = 18` / `STEP_COUNTER = 19` (and `_WU` 50/51)
> — **leading hypothesis: Palm's firmware implements the standard handles
> natively and the CUSTOM_3_WU indirection should be bypassed.**
> ✅ **CONFIRMED on hardware 2026-07-23** — see the SOLVED banner above.
>
> 🐛 **Secondary bug — refcount leak makes the failure permanent.**
> `enable_pedometer()` (~6675):
> ```c
> static int count;
> if (enable) count++; else { if (count-- <= 0) count = 0; }
> if ((int)enable != count) return 0;      /* short-circuit */
> ```
> `count` is incremented **before** the hardware attempt and **never rolled
> back when it fails**. So attempt #1 fails leaving `count == 1`; every later
> enable sees `count == 2 != 1` and returns **0 = fake success** without
> touching hardware. Observed exactly: a later `sensor: 19, enable: 200`
> "succeeded" and ran `report_last_step_counter_data` → `STEP: last step
> cnt = 0`. **The step counter cannot be re-armed for the rest of the boot.**
> Worth fixing regardless of the primary cause.
>
> **Ground truth still needed (two-device rule — do NOT guess from the
> Samsung driver):** stock 8.1 has a *working* step detector + counter
> (Silver `4373dd0f`, handles 0x11/0x12 of 22 h/w sensors). Silver is a **user
> build with no root**, so `dmesg` and `/sys/class/bst/bhy/*` are both
> permission-denied — the stock driver's slot choice could not be read out on
> 2026-07-23. Options: (a) static-analyse stock `sensors.native.so` /
> the stock BHy kernel driver from the A8 dump for its handle mapping;
> (b) try enabling standard handle 18/19 directly on our build and watch for
> `ack == 0x80`; (c) dump the RAM-patch firmware's advertised sensor list.
>
> **Related delta found the same day:** stock enumerates **22** h/w sensors vs
> our **20**. BHy side is at parity (15/15); the two missing are both
> `com.bb.sensor.rawprox` (type `33171025`, primary + non-wake secondary) on
> the RPR0521/SSC side. Standard proximity/light are all present, so this is
> believed inert for normal apps — logged as a known delta, not a blocker.

> ## ✅ 2026-07-23 — BHy suspend/resume wedge fix FLASHED + VALIDATED (kernel `dcada22167b7`)
>
> The `int_debug()`-routing recovery fix described below was built and flashed
> on 2026-07-23 and **works**. Before the flash a live wedge was caught on the
> old kernel (storm of `Read bytes remain reg failed` / `Get firmware
> timestamp failed` + `bhy_suspend: Read host ctrl reg failed` at 06:49:48,
> **no** `Reset#`, all 16 BHy sensors frozen ~2 h while the SSC/RPR0521 path
> stayed live — the clean discriminator). After the flash: hub alive, IRQ
> servicing normally, RAM patch loaded, Significant Motion firing on real
> motion, no wedge signature. ⭐ Diagnostic tell for "BHy dead vs SSC fine":
> compare `Recent Sensor events` wall-clock per sensor in `dumpsys
> sensorservice` — a 2-hour-stale accel next to a current prox is the wedge.
> ⚠️ Do **not** read a stationary phone's flat accel (`-0.00,-0.00,10.00`) as
> a wedge; sample *during* motion or cross-check Significant Motion.
>
> ⚠️ Separately staged 2026-07-23 (unflashed): **`/data/misc/sensor` was never
> created** on our build (stock makes it in `init.target.rc`, "#add for
> BHI160"), so the BST HAL fails every
> `open file /data/misc/sensor/bhy_profile_calib_*` and calibration never
> persists. Fix = `mkdir /data/misc/sensor 0770 system system` +
> `bhy_data_file` type/label + `hal_sensors_default` rules. ⚠️ The HAL is a
> **vendor** domain and the path is **core** `/data`, which `domain.te`'s
> "vendor domains may only access files in /data/vendor" neverallow forbids
> (permits no more than `{append getattr ioctl read write map}` — not even
> `open`); the path is hardcoded inside the prebuilt `sensors.native.so` so it
> cannot move to `/data/vendor`. Worked around with the public
> `data_between_core_and_vendor_violators` typeattribute. **NOT verified with
> checkpolicy** (no local build artifacts) — expect a possible late
> `sepolicy_neverallows` failure on the remote builder.

> ## 🔴 OPEN 2026-07-16 — BHy hub wedges after suspend/resume churn; recovery exists but is unreachable. Fix STAGED, UNFLASHED. (SUPERSEDED — see the 2026-07-23 banners above; the fix is now flashed and validated.)
>
> This is the real content of the long-running "i2c-2 bus wedge → sensors-HAL
> binder starvation → ~143s system-wide ANR" story. **The central claim was
> wrong.** Reproduced and dissected live on Gold (`81eed371`).
>
> **The bus is not wedged — only the hub is.** All **76** `i2c-msm-v2
> TIMEOUT_ERROR` were `slv_addr:0x28` (bhy); **zero** at `0x60` (wusb3801), and
> wusb3801 read 0x60 successfully *throughout the storm* (zero `Failed to read
> port status`), including IRQs taken mid-storm. A wedged bus would have failed
> those too. The Type-C chip is innocent — the contention theory in
> `bhy_i2c.c`'s header and `pepito.dts`'s `&i2c_2` comment is **falsified**.
> Not USB/car-related either: the storm started **2m42s after** the plug and
> **kept climbing after unplug** — the original ANR was never an Android Auto
> session. **⚠️ Correction (2026-07-18):** the earlier claim here that
> `persist.vendor.usb.config=adb` "pins the gadget so Android Auto has never
> been possible / accessory is not supported" is **WRONG**. On the live unit
> that property is empty, the kernel + configfs gadget fully support accessory
> mode (`CONFIG_USB_F_ACC=y`, `accessory.gs2`), and the phone *does* enter
> accessory mode every connection. AA fails for an unrelated reason (missing
> `SYSTEM_AUTOMOTIVE_PROJECTION` role holder → gearhead `:car` CDM crash). Real
> cause + fix now tracked in `PLAN-release.md` (Android Auto checklist item).
>
> ⭐ **Technique that settled it:** a second, healthy device on the same bus is
> the cleanest discriminator between "bus wedged" and "slave hung". wusb3801 at
> 0x60 was the control; it had only just been brought up.
>
> **Trigger = suspend/resume churn.** `21:40:21→21:41:12`: 42 resumes, all
> `IRQ 71, wcnss_wlan`; last resume `21:41:12.327`, first timeout
> `21:41:12.703` — **376 ms later**. bhy dies on the full wake ending ~51 s of
> thrash (consistent with the flush-complete-after-resume bug in this lane).
> The churn only *appears* to stop because the resulting error spin prevents
> suspend. `hostNSOffload=0` IS working (`quiet mode armed
> (mcastBcastFilter=1 set=1)`) but **1 = multicast-only; broadcast still
> wakes** → see `PLAN-perf-battery.md`.
>
> **Repro (fast): Wi-Fi connected + screen off + idle ~1 min + wake.**
> Wi-Fi must be *connected* — that's what drives the churn.
>
> **Why it never recovers.** `mcu_monitor_thread` (every 10 s) → `reset()` →
> `bhy_load_ram_patch()` exists and is correct. During the storm **all four
> triggers were simultaneously unreachable**:
>
> | Trigger | Why dead |
> |---|---|
> | Reset#0 `irq_force_disabled` | only set by `int_debug()`, called **only** from `bhy_read_fifo_data()`'s "Zero length FIFO" path — never its three i2c-error returns |
> | Reset#1 accel timeout (15 s) | gated `if (acc_enabled)` — **false when screen off** |
> | Reset#2 duplicate-accel | same gate |
> | Reset#3 MCU watchdog | reached, but `check_watchdog_reset()` reads CHIP_STATUS over the wedged bus, fails, and did `return 0; /* Ignore reg_read fail. */` = **"healthy"** |
>
> **Core bug: "I can't read the chip" was reported as "the chip is fine."**
> The monitor woke ~30× over 5 min and did nothing, silently (its only prints
> live inside the `acc_enabled` branch). Meanwhile the IRQ
> (`IRQF_TRIGGER_HIGH | IRQF_ONESHOT`) re-fires forever because only draining
> the FIFO de-asserts INT → ~11k IRQs and **12,700 log lines that evicted
> dmesg and destroyed the storm onset**. Use `logcat -b kernel` (separate
> buffer, wall-clock stamps) for anything time-correlated.
>
> **Staged (not yet flashed):**
> 1. `check_watchdog_reset()` → `return 1` on read failure. Safe:
>    `bhy_read_reg()` only fails there after `BHY_MAX_RETRY_I2C_XFER` full
>    retries, or during a breaker cooldown that itself needed a full retry loop
>    to fail — never transient.
> 2. New `bhy_i2c_clear_degraded()` (bhy_i2c.c, decl. bhy_core.h) called at the
>    **top of `reset()`**. Load-bearing: the recovery reloads the RAM patch over
>    the very bus the breaker tripped on, and runs *because* it tripped —
>    leaving it armed fails-fast (-EIO) every reload op incl.
>    `BHY_REG_RESET_REQ`, so the recovery would silently accomplish nothing.
>
> ⚠️ **Gotcha:** pepito's `bhy@28` has **no `bhy,ldo_enable`** → `ldo_enable_pin
> < 0` → `reset()` **always** `goto direct_ram_patch`. **The LDO power-cycle
> branch is dead code on this device** — put reset-related changes at the *top*
> of `reset()`.
>
> ⚠️ **Open risk:** with no LDO pin, recovery is a **soft** reset (i2c write).
> If the hub refuses *all* i2c (not just big FIFO reads) it fails too —
> unknown, since the breaker masked small ops behind fast -EIO. The log
> decides: `Ram patch loaded successfully` = fixed; `Write reset reg failed` =
> needs a real power-cycle, next step cycling `bhy,vdd_i2c/1p8/2p85`
> (pm8937_l5/l6/l10).
>
> **Validated, keep:** the `bhy_i2c.c` breaker measurably works — inter-timeout
> gaps were 68×~2.04 s (in-loop retries) then 7× **15.9 / 24.8 / 17.5×5 s** =
> the 15 s cooldown + one ~2.37 s retry. The system stayed responsive, **no
> ANR** — it turned the 143 s ANR into survivable degradation. The widened 15 s
> was right; the original 2000 ms would have vanished inside the 2.04 s retry
> cadence.
>
> **Test:** reboot, repro, then
> `dmesg | grep -iE "Reset#|Read chip status failed|Ram patch loaded|Write reset reg failed"`
> and `cat /proc/interrupts | grep bhy`. Success tell = auto-rotate returns
> without a reboot.
>
> **🔴 2026-07-17 — THE `check_watchdog_reset` FIX IS INSUFFICIENT: caught a live
> wedge on build #8, recovery did NOT fire, needed a reboot. Follow-up fix STAGED.**
> First flash (#7) ran 6 heavy-churn cycles clean but never triggered a wedge, so
> the recovery was unproven. On build #8 (Jul-17 12:22) a **natural wedge fired
> live** (trigger was a registered adb-TCP session — filter=3 kills *broadcast*
> churn but adb-TCP is *unicast*, ~46/min, unfilterable → suspend/resume churn →
> hub wedges on a resume). Captured storm (`bhy_core.c`, `bhy_read_fifo_data`):
> ~10 real `0x28` i2c timeouts, then the breaker fast-fails → **7,829** iterations
> of `Read bytes remain reg failed` / `Get firmware timestamp failed` at ~27 µs
> cadence. **Zero** `MCU Malfunction Detected` / `treating as malfunction` /
> `Reset#` — the recovery never ran; system went unresponsive (adb dropped) →
> reboot.
>
> **Root cause of the non-recovery (source-confirmed):** `bhy_read_fifo_data`'s two
> i2c-error returns (`Read bytes remain reg failed` @~2077, `Read fifo data failed`
> @~2102) do `mutex_unlock; PERR; return` **without disabling the IRQ**. Only the
> *zero-length-FIFO* path calls `int_debug()` (the sole place that
> `disable_irq_nosync` + sets `irq_force_disabled`). The IRQ is level-high +
> `ONESHOT`, so a failed drain re-fires forever, monopolising `mutex_bus_op` at
> µs cadence. That defeats **both** recovery routes: `Reset#0` needs
> `irq_force_disabled` (never set here), and `Reset#3` (the `check_watchdog_reset`
> fix) runs in `mcu_monitor_thread` every 10 s but can't win `mutex_bus_op` against
> the storm (or its 1-byte `CHIP_STATUS` read slips through and reports "not idle"
> = 0). **So the check_watchdog_reset return-value fix was necessary but
> structurally unreachable** — nothing quiesces the screaming IRQ. Secondary: once
> wedged, `bhy_suspend` fails (`Read host ctrl reg failed` → `bhy_pm_op_suspend
> returned -5` → `Abort: Callback failed on 2-0028`), aborting system suspend.
>
> **FOLLOW-UP FIX STAGED 2026-07-17 (`bhy_core.c`, unflashed):** route both
> i2c-error returns in `bhy_read_fifo_data` through `int_debug()` — same as the
> zero-length path — so after `INT_DEBUG_COUNT` (=1000, ~27 ms of fast-fail, or
> ~8 s incl. the pre-breaker real-timeout phase) the IRQ is masked and
> `irq_force_disabled` set → `Reset#0` → `reset()` → RAM-patch reload. IRQ
> refcount stays balanced (`int_debug` disables, `reset()` re-enables). Scoped to
> `bhy_read_fifo_data` only (the IRQ-driven reader); `detect_init_event` /
> `detect_self_test_event` share the bug but aren't in the re-fire loop.
> **Tunable to consider if ~8 s is too slow:** a dedicated lower i2c-error
> threshold instead of the shared 1000. **Test after flash:** repro the wedge and
> confirm `Read bytes remain reg failed` count is *bounded* (not 7 k+), followed by
> `Reset#0` → `Ram patch loaded successfully`, sensors self-restore with no reboot.
> If instead `Write reset reg failed` appears, the soft reset isn't enough → the
> regulator power-cycle path (no `ldo_enable` on pepito) is the next lever.
>
> ⭐ Meanwhile the **trigger** is reduced in real use: `hostArpOffload=0`
> (filter=3) took wifi *broadcast*-caused resumes to 0 (`PLAN-perf-battery.md`,
> 2026-07-17), so an untethered idle phone is much less exposed — but unicast
> churn (any active connection) can still wedge it until this follow-up fix lands.

> ## ✅ SSC REGRESSION CLOSED — AUTONOMOUS COLD BOOT VALIDATED UNDER ENFORCING 2026-07-11
> Second validation flash: **fully autonomous cold boot → 20/20 h/w sensors**
> under Enforcing, zero intervention. Trigger fired at 32.6s
> (init.target.rc:239, the property-first `&& post-fs-data` form), persist
> partition bind-mounted on /persist, daemon `u:r:sensors:s0` as system, no
> daemon file errors, no AVC denials, live prox events at boot. The
> vendor.prop `persist.vendor.usb.config=adb` seed also validated (adb
> survived first boot; no mass-storage window). Root-cause narrative and the
> full fix inventory below. **Committed 2026-07-11** (other lanes' pending
> hunks in the same files left untouched): mithorium-common `45a8c30`
> (sensors) + `85f87e5` (usb seed), Mi8937 `cb5a90d3` (sepolicy label),
> vendor/xiaomi `df86661` (blob+packaging). ⚠ `scripts/build-lineage23.sh`
> (the $OUT/root/persist fixup) is NOT in any git repo — release item: get
> scripts/ under version control.
>
> First-flash (2026-07-11 AM) findings, for the record: the original
> `on post-fs && property:ro.vendor.xiaomi.device=pepito` trigger form never
> fired on this init (bind mount missing → daemon fsa failed at boot; 20/20
> reachable only via manual mount + adsp SSR), and system.prop cannot seed
> the vendor-namespace `persist.vendor.usb.config` (came up empty on fresh
> userdata → mass_storage-only gadget, no adb: `05c6:f000`).

## 2026-07-10 — SSC prox/ALS regression: root cause and fix

**Root cause: mithorium-common `4a83a0d` ("drop vestigial stock sensors.qti
daemon") removed a load-bearing component.** Palm's ADSP-side SMGR does not
self-initialize like the Xiaomi siblings': at DSP sensor init it reads its
sensor registry over QMI from **two services hosted on the APPS side by the
stock `sensors.qcom` daemon** (SNS_REG2 `0x10f:0x2` + `0x118:0x3202` on node
1 — the daemon links `libqmi_csi`, the QMI *service host* library; our
nightly `libsensor1`/HAL stack is client-only). No server → the DSP SNS stack
aborts init → registers **zero** SNS services → `libsensor1:
qmi_client_get_service_list error -2` → no prox/ALS.

Why the removal looked safe: it was validated by a **live HAL restart** — but
the DSP had already probed at boot *with the daemon present*; the boot-time
role was invisible. The commit's own "sanity-check next clean flash" note was
the regression. (The 7/05 evening BHy flash was boot.img-only, so no
SSC-verified cold boot ever ran a daemon-less vendor until 7/10.)

**Second, stacked cause — the `/persist` symlink:** the daemon's A8 fsa code
rejects `/persist/sensors/...` when `/persist` is the common symlink to
`/mnt/vendor/persist` (`sns_fsa_la.c: invalid directory path` at file init →
**every** DSP registry read answered with an error → SNS still aborts, proven
by ADSP-SSR wire captures in `/d/ipc_logging/qrtr_5`). The original design
(BoardConfigCommon.mk comment + `TARGET_DEVICE_PEPITO` gate) knew this — but
`BOARD_ROOT_EXTRA_SYMLINKS` **has no consumer in the A16 build system**, so
the gate never did anything and the on-image symlink is a *stale `$OUT/root`
artifact* that ships verbatim in every build.

**Live proof chain (all on the DUT, no reflash):**
1. Stock daemon (from the A8 backup) run manually → registers `0x10f`/`0x118`
   on QRTR node 1; DSP port 7 immediately fires dozens of registry reads at it
   on ADSP restart.
2. With `/persist` symlink or unreadable `sns.reg`: reads answered with
   uniform 22-byte QMI error responses → no SNS after ADSP restart.
3. With a **real /persist dir + bind mount + readable registry**: file init
   passes, reads return data, and after `echo restart >
   /d/msm_subsys/adsp` the ADSP announces the full SNS family on node 5
   (`0x100:0x3201` SMGR + `0x107/0x108/0x10d/0x115/0x118/0x12c`) → HAL
   restart → `SMGR version=23`, `RPR0521 Proximity & Light` enumerated →
   **`dumpsys sensorservice` = 20/20 running**.
4. SELinux ruled out early (identical failure in Permissive).

**The uid subtlety:** launched as root, the daemon self-demotes to
(nobody,nobody) via CAP_SETUID (documented in legacy-um `sensors.te`) and
then can't read the system-owned registry. As `user system` **without file
caps** it cannot demote — that's why the service must carry `caps: 0` in
config.fs and user system in init.target.rc.

**Fix (committed 2026-07-11 — see banner for hashes):**
- `scripts/build-lineage23.sh` — replaces the stale `$OUT/root/persist`
  symlink with a **real directory** before every image build (the only
  reliable mechanism left; BOARD_ROOT_EXTRA_* is dead).
- `mithorium-common/rootdir/etc/init.target.rc` — restored
  `vendor.sensors.qti` service (class core, user/group system, disabled) +
  pepito-gated `on post-fs` **bind mount** of `/mnt/vendor/persist` onto
  `/persist`.
- `mithorium-common/rootdir/bin/init.qcom.sensors.sh` — restored
  `start vendor.sensors.qti` in `start_sensors()`.
- `mithorium-common/config.fs` — `[vendor/bin/sensors.qti]` mode 0755
  AID_SYSTEM **caps: 0** (no NET_BIND_SERVICE — AT_SECURE class + would
  enable the nobody-demotion).
- `mithorium-common/BoardConfigCommon.mk` — comment corrected (mechanism
  dead; documents the real fix locations).
- `Mi8937/sepolicy/vendor/file_contexts` — `sensors.qti` →
  `u:object_r:sensors_exec:s0`: reuses the complete legacy-um `sensors`
  domain **written for this exact daemon** (persist registry, /dev/sensors,
  socket+qipcrtr QMI incl. `msm_sock_ipc_ioctls` allowxperm, diag on
  userdebug). No new .te rules → no neverallow exposure.
- `vendor/xiaomi/Mi8937` (not git) — stock `sensors.qcom` staged as
  `proprietary/vendor/bin/sensors.qti` (md5 `8e5a9941…`), `cc_prebuilt_binary`
  module in Android.bp, `sensors.qti` in Mi8937-vendor.mk PRODUCT_PACKAGES.

**Validation on next flash (cold boot):**
1. `dumpsys sensorservice | head -3` → **20 h/w sensors** (not 16).
2. `ps -A | grep sensors.qti` → running as **system** (not nobody).
3. `logcat -s Sensors` → no `invalid directory path` / `reg file not open`
   (the `Waiting for diag service timed out` line is cosmetic).
4. `qrtr-list` (in /data/local/tmp) → SNS family `0x100–0x12c` on node 5.
5. `ls -ld /persist` → real dir with persist content (bind mount live).
6. Under Enforcing: `logcat -d | grep "avc.*sensors"` clean. Known separate
   papercut: one boot-time `hal_sensors_default` denial on a
   `system_data_file`-labeled dir "sensor" (persist partition, p53) — cosmetic
   so far, track in the release sepolicy pass.

**Device state left on the bench (2026-07-10 ~23:00):** 20/20 sensors live
(DSP-side SNS survives until next ADSP reset); rootfs `/persist` symlink
restored to as-shipped; test daemon killed; `sns.reg` temporarily 0666 (next
boot's `start_sensors()` chown fixes it; a clean flash wipes anyway); stock
daemon + qrtr-list left in `/data/local/tmp`. **A plain reboot before the fix
flash returns to the broken state** (no daemon in the image) — flash the
staged build instead.

**Durable debugging gotchas from this session:**
- `/d/ipc_logging/*/log` reads are **destructive** (drain the buffer) — use
  `log_cont` streamed to a file for captures.
- QRTR node 7 = **wcnss**; it hosts an SNS-lookalike `0x100:0x100` (plus
  `0xf:0x1`, `0x33:0x301`) — an impostor when grepping for SMGR (real SMGR =
  `0x100:0x3201` on node 5). This briefly derailed the session.
- One ADSP `echo restart > /d/msm_subsys/adsp` cycle is safe (audio bounces
  and recovers); no MSS-style wedge observed across 3 cycles.

> ## ✅ SUBSYSTEM COMPLETE (2026-07-05)
> **All 20 h/w sensors running with live data on `android16-adb`**: 4 RPR0521 prox/ALS
> via SSC/SMGR + 16 Bosch via BHy (`bst,bhy` + `sensors.native.so`) — accel, gyro, mag,
> pressure and all fusion/step sensors delivering events to apps (phyphox-verified).
> Two independent fix tracks: (1) prox/ALS = per-variant `sensor_def_qcomdev.conf` as a
> base file (2026-06-29, below); (2) BHy data delivery = three stacked kernel bugs
> (`438e117` frame ABI u16, `946cdd2` req_fw reset race, `3ff1a97` wake-channel
> INITIALIZED meta event) — see the BHy section. Remaining loose ends are non-blocking
> tree cleanup only (see Checklist).

**Prox/ALS status (2026-06-29): SOLVED + committed. Delivery fixed to base
files (the overlay was too late).** `qrtr-ns` unblocked the transport; the missing
piece was the per-variant SMGR board-config `sensor_def_qcomdev.conf`, **absent on
pepito**. The first staging attempt delivered it via a `pepito` **overlayfs mount**
(like the siblings) and **regressed on a clean flash** (`No Sensors`) — the overlay
mounts in the late `on property:ro.vendor.xiaomi.device=pepito` block, *after* the
ADSP probes sensors at boot. Fixed by delivering the conf as **real base files in
`/vendor/etc/sensors/`** (present at the first-stage `/vendor` mount, before the
probe). **Confirmed on-device:** with the conf written to base `/vendor/etc/sensors`
+ reboot, `dumpsys sensorservice` = **4 h/w sensors running** (RPR0521 prox + ALS,
live data, SystemUI bound to proximity).

The "sns.reg is correct so it should work" reasoning was wrong: the sensor list comes
from the **conf at probe time**, not the persisted registry. `sns.reg` was the right
stock `20a4ca02` the whole time the overlay build showed 0.

**Why base files, not the overlay (decisive test):** on the flashed device the base
`/vendor/etc/sensors` had only an empty `hals.conf` (overlay shadowed it later) → 0
sensors. Writing the real conf into the **base** dir (overlay still re-mounted on top
afterward, shadowing it for normal access) → **4 sensors** after reboot. The only
thing that changed enumeration was the conf being a real file present at the earliest
`/vendor` mount. (Siblings get away with the overlay likely because they run no early
`vendor.sensors.qti` and their SSC HAL reads the conf late; pepito's probe path needs
it early. Base files are the robust mechanism regardless.)

**Committed / staged for next flash:**
- `device/xiaomi/mithorium-common` @ `cfa0863`: `configs/sensors/hals.conf`
  empty → `sensors.ssc.so` (a real base file; obsolete "empty for stability"
  workaround dropped) + rationale comment in `mithorium.mk`.
- `vendor/xiaomi/Mi8937` (not a git repo — staged on disk): Palm
  `sensor_def_qcomdev.conf` (md5 `b4cf5068`) at
  `proprietary/vendor/etc/sensors/`, installed to **base** `/vendor/etc/sensors/`
  via a `Mi8937-vendor.mk` `PRODUCT_COPY_FILES` line.
- `device/xiaomi/Mi8937/rootdir/etc/init.xiaomi.device.rc`: the `pepito` sensors
  **overlay mount was removed** (net-zero vs committed state — the overlay add was
  never committed). The overlay copy lines + `overlayfs/pepito/sensors/` source dir
  were deleted.

**CONFIRMED 2026-06-29: clean build + flash reproduces 4 sensors** — `/vendor/etc/sensors`
shows real base files from the image (no overlay), `hals.conf=sensors.ssc.so`, conf
md5 `b4cf5068`, `dumpsys` = 4 h/w sensors running with live data. The fix is complete
and reproducible from source. Remaining work is accel/gyro/mag only (below).

**Sibling caveat (bring-up debt):** the Palm conf now lands in the *shared* base
`/vendor/etc/sensors` for all Mi8937 variants. Siblings shadow it with their own
overlay, but their early ADSP probe would read Palm's conf first. Harmless in
practice (only pepito is built from this tree); revisit if `TARGET_DEVICE_PEPITO`
gating is ever wired (see PLAN.md layering TODOs).

**Remaining (follow-up, not blocking): accel/gyro — root-caused 2026-06-30, separate
subsystem.** Only **RPR0521 prox/ALS** come via SSC, and that's complete. Accel/gyro
are a **Bosch BHy sensor hub (BMI160) on the AP Linux bus i2c-2 @ 0x28** (HAL =
`sensors.native.so`, not SSC) — and **our `pepito.dts` disabled `&i2c_2`**, the very
bus it sits on, on a false "vestigial empty bus" premise copied from the 4.9 fork.
Stock 3.18 has `bhy@28` (+ a `wusb3801x@60` USB-C controller) on that bus. Needs a
kernel-driver effort (the `bst,bhy` driver is absent from the Palm GPL release; the
4.19 tree has mainline IIO `bmi160` instead). See "Accel/gyro/mag — root-caused" below.

**Confirmed working on true stock (2026-07-02):** `android8-adb` `dumpsys sensorservice`
lists **22 h/w sensors running** — 6 RPR0521 prox/ALS via SSC + **16 Bosch sensors** via
BHy HAL (accel, gyro, mag, pressure, orientation, gravity, linear accel, rotation
vector, step detector/counter, significant motion, PDR, activity recognition). The BHy
hub kernel workqueue `[bhy_wq]` is live (pid 258). This is the only device where the
full sensor stack has been observed working end-to-end.

**Proven from the dump, not guessed:**
- ADSP firmware is **byte-identical to stock** (md5 `adsp.mdt`/`adsp.b04` match
  exactly) → the `adsp.*` image is *not* the problem. Expected: the firmware lives
  on the `modem` partition (`mmcblk0p1`), which our `vendor.img` flash never
  touches, so we already run Palm's 2020 ADSP.
- Our `/vendor/etc/sensors/` has **only an empty `hals.conf`**; stock ships
  `hals.conf` + a **209 KB `sensor_def_qcomdev.conf`** (the SMGR registry seed:
  every sensor's driver, I²C bus/address, SMGR id, calibration defaults).
- Our `/persist/sensors/sns.reg` (md5 `fae6e49a…`) **differs** from stock's
  (`20a4ca02…`, same 25468 B) → our registry was seeded *without* Palm's board
  config, consistent with the missing `.conf`.

> Supersedes [`PLAN-sensors.old.md`](PLAN-sensors.old.md). Forward-only. The old
> plan's entire "load `sensors.ssc.so`, it blocks forever in QRTR before HIDL
> registration" storyline is **closed** — that blocker was the missing `qrtr-ns`
> name service, exactly as [`PLAN.md`](PLAN.md) and [`PLAN-radio.md`](PLAN-radio.md)
> predicted. See the 2026-06-25 evidence below.

## Legend
- ✅ Working / proven on-device  - 🔧 Present, not yet verified  - ❌ Missing / active blocker

---

## TL;DR — what changed and what's left

| Layer | Old plan (pre-qrtr-ns) | Now (2026-06-25) |
|---|---|---|
| QRTR transport / name service | ❌ `NEW_LOOKUP` for SMGR svc 256 hangs forever | ✅ `qrtr-ns` answers; lookup resolves |
| `sensors.ssc.so` HIDL registration | ❌ blocks before registering → no `sensorservice` | ✅ registers `ISensors/default` cleanly |
| HAL ↔ ADSP SMGR QMI link | ❌ never reached | ✅ live: `SMGR version=23` reply received |
| Sensor enumeration | ❌ never reached | ❌ **SMGR returns 0 sensors** ← the only remaining blocker |

The fight in the old plan ("SSC vs SMGR — wrong HAL", `/persist` symlink, missing
`libqmi_encdec`, hals.conf empty-for-stability) is **all resolved or obsolete.**
One problem remains, and it is on the DSP, not the AP.

---

## Corrected architecture model (read this first)

The old plan and the 2026-06-24 methodology note conflated two independent axes and
concluded "A16 was chasing the wrong sensor HAL." That was a wrong turn, exactly
analogous to the radio "modem speaks 27 not 42" misread. The two axes:

1. **AP-side HAL filename** — `sensors.ssc.so` (the QTI multihal sub-HAL the
   `android.hardware.sensors@1.0-service` aggregator dlopens). This is just the
   library name; it does **not** mean the "SSC/SEE" DSP framework.
2. **DSP-side sensor framework** — pepito's ADSP runs the **legacy SMGR** (Sensor
   Manager, the DSPS-era framework), *not* the newer SSC/SEE. Confirmed live: the
   HAL logs `Init the smgr_sensor1_cb for SMGR sensor1 connection`, `sendSMGRVersionReq`,
   `processAllSensorInfoResp`. SMGR reports protocol **version 23**.

**These coexide.** The nightly `sensors.ssc.so` HAL speaks the **SMGR** QMI
protocol to the DSP. So the real picture is:

```
Physical sensors (BMI160 accel/gyro, prox/ALS, mag) on I2C/SPI wired to the ADSP
        ↓
ADSP firmware (adsp.* image) running the SMGR sensor framework + sensor drivers
        ↓  QMI (service 256 / SMGR family), riding QRTR over the SMD `adsp` edge
qrtr-ns  ← maintains the service directory, answers NEW_LOOKUP   (THE 2026 unblock)
        ↓
libsensor1.so  (QMI client inside the HAL)
        ↓
sensors.ssc.so  (QTI multihal sub-HAL, dlopen'd from hals.conf)
        ↓
android.hardware.sensors@1.0-impl.so  (multihal aggregator)
        ↓  HIDL
android.hardware.sensors@1.0-service  → sensorservice → apps
```

There is **no separate AP-side sensor daemon** in this path. The nightly ships
**no `sensors.qti` / `sensors.qcom` binary** — the HAL talks QMI to the DSP
directly. (Our tree currently still starts a vestigial `vendor.sensors.qti` =
stock Palm `sensors.qcom` renamed; that is stock-legacy-path debris — see Cleanup.)

### Two-device rule, restated for sensors (same as radio & GPS)

> **Updated 2026-07-02:** `android11-adb` is **not a runtime witness for sensors** —
> its A11 GSI never loads the BHy hub firmware (`ram_id`=0, `dumpsys sensorservice` =
> 0 sensors, `sensors.qcom` crash-loops with SELinux denials). Use **`android8-adb`**
> (true stock) for runtime behavior (running daemons, `dumpsys`, live data) and
> `android11-adb` for hardware facts only (device nodes, sysfs, DTB).

Stock `android11-adb` (3.18) runs `sensors.qcom` + `@1.0-impl.so` over the **legacy
in-kernel IPC router** — a *different router generation* with its name service in
the kernel, so it has no `qrtr-ns`. **Do not port stock's daemon topology** (same
lesson as "don't port `msm_ipc_router`" for radio, and the GPS note in MEMORY).
Take from stock its **config values and hardware facts** — which physical chips,
the sensor registry contents, the ADSP sensor board-config, the firmware image —
**not** its userspace shape. Our AP side is already correct (it matches the
nightly, which every working sibling uses on this exact kernel).

---

## Ground-truth evidence — live SSC retest on `android16-adb`, 2026-06-25

Procedure (reversible, non-destructive): `echo sensors.ssc.so > /vendor/etc/sensors/hals.conf`,
`setprop persist.vendor.debug.sensors.hal v`, restart `vendor.sensors-hal-1-0`,
capture logcat. Device then reverted to the flashed default (empty hals.conf).

```
qti_sensors_hal: Init the smgr_sensor1_cb for SMGR sensor1 connection.
qti_sensors_hal: sendSMGRVersionReq
qti_sensors_hal: waitForResponse: timeout=1000
qti_sensors_hal: context_sensor1_cb: msg_type 1, msg Id 1   ← REPLY from ADSP
qti_sensors_hal: processResp: SMGR version=23               ← SMGR is alive
qti_sensors_hal: getSensorList
qti_sensors_hal: context_sensor1_cb: msg_type 1, msg Id 5   ← REPLY from ADSP
qti_sensors_hal: processAllSensorInfoResp: SensorInfo_len: 0 ← ZERO sensors
qti_sensors_hal: updateSensorList
qti_sensors_hal: SensorsContext::getSensor handle 1 is NULL!   (accel)
qti_sensors_hal: SensorsContext::getSensor handle 11 is NULL!
qti_sensors_hal: SensorsContext::getSensor handle 3 is NULL!
qti_sensors_hal: updateSensorList: Proximity disabled!
android.hardware.sensors@1.0-service: Loaded library from sensors.ssc.so
android.hardware.sensors@1.0-service: HAL specifies version 1.4, but does not
                                      implement set_operation_mode()   ← benign (old 2g)
HidlServiceManagement: Registered android.hardware.sensors@1.0::ISensors/default
LegacySupport: Registration complete for ...ISensors/default.
```

What this proves:
- **Transport: solved.** A version request was answered (`SMGR version=23`). The
  HAL thread is **not** stuck in `qrtr_recvmsg` (wchan check: main thread in
  `binder_ioctl`, workers in `do_select`/`poll`/`futex` — all normal). The old
  "service 256 never advertised → wait forever" wall is gone.
- **HIDL: solved.** `ISensors/default` registers; `dumpsys sensorservice` returns
  `No Sensors on the device` + `devInitCheck : 0` (a *successful* empty query, not
  a hang). `sensorservice` runs.
- **Blocker: the ADSP SMGR has no sensors configured.** `SensorInfo_len: 0` is a
  clean reply containing an empty list — the DSP enumerated nothing. The HAL's
  static handles (1=accel, 3, 11, proximity) all resolve to NULL.

Supporting state on `android16-adb`:
- ADSP subsystem `ONLINE` (`/sys/bus/msm_subsys/devices/subsys1` = adsp ONLINE).
- `/dev/sensors` char node (major 498) present.
- `/vendor/etc/sensors/` contains **only** an empty `hals.conf` — **no
  `sensor_def_qcomdev.conf`** (the SMGR board/registry seed). **This is the root
  cause.**
- `/mnt/vendor/persist/sensors/` has `sns.reg` (25468 B, md5 `fae6e49a…`),
  `sns.reg.bak`, `sns.reg.disabled`, and an **empty** `registry/registry/` dir.
  Stock's `sns.reg` is the same size but a **different** md5 (`20a4ca02…`) — ours
  was seeded without the right board config.
- `/persist` is a symlink → `/mnt/vendor/persist` (the old per-pepito bind-mount
  hack is **not** active and is not needed — the SSC HAL never tripped on it).

---

## Root cause (confirmed 2026-06-26): pepito never gets `sensor_def_qcomdev.conf`

The DSP answered, so SMGR is loaded and running — it just has **no sensor
definitions**, so it instantiates nothing. On DSPS/SMGR the instantiated sensor set
comes from (a) the sensor drivers in the ADSP image and (b) the board config that
tells SMGR which chip is on which bus/address. (a) is **identical to stock** (md5
proven). (b) is **missing**.

**How siblings get (b) — and why pepito doesn't:** the nightly does *not* put
`sensor_def_qcomdev.conf` in the base `/vendor/etc/sensors/` (it has only
`hals.conf`). Each variant mounts its own copy at runtime via an **overlayfs**
block in `init.xiaomi.device.rc`:

```
on property:ro.vendor.xiaomi.device=wt8937   # (santoni)
    mount overlay overlay /vendor/etc/sensors ro lowerdir=/vendor/etc/overlayfs/wt8937/sensors/:/vendor/etc/sensors
on property:ro.vendor.xiaomi.device=prada
    mount overlay overlay /vendor/etc/sensors ro lowerdir=/vendor/etc/overlayfs/prada/sensors/:/vendor/etc/sensors
... (riva, rolex, ugg→ulysse, ugglite→ulysse, land)
```

**Precise confirmation (2026-06-26):** pepito *does* have a branch
(`init.xiaomi.device.rc:47-56`), but it mounts only `/odm/{bin,lib,etc/camera}` and
**omits the `/vendor/etc/sensors` overlay line** that every sibling has (`:131` land,
`:138` prada, `:147` riva, `:156` rolex, `:166` santoni, `:175` ugg, `:184` ugglite). So on
pepito `/vendor/etc/sensors/` stays empty-`hals.conf` → SMGR is never told what sensors
exist → `SensorInfo_len: 0`. (Our `proprietary-files-device.txt` even *lists*
`sensor_def_qcomdev.conf`, but maps it to the sibling `overlayfs/{prada,ulysse,
wt8937}/` paths and nothing mounts those for pepito.) This is the canonical **Cluster B**
miss — see `PLAN.md` "Holistic cross-cutting analysis".

This is the **same bug class** as GPS (`izat.conf` not installed for pepito) and
radio (dual-SIM manifest on single-SIM pepito): a per-variant asset the pepito
branch never delivers.

**Crucially, the right config is pepito-specific, not a sibling's.** A sibling's
`sensor_def_qcomdev.conf` describes *that* phone's chips/buses/addresses. Pepito's
real sensor hardware (BMI160 + Palm prox/ALS/mag) is described by **Palm's own**
209 KB `sensor_def_qcomdev.conf`, which we already have in the stock dump:
`backup-stock-android-8.1-AML0/vendor.bin.extracted/etc/sensors/sensor_def_qcomdev.conf`.

---

## What was done (2026-06-26) — fix validated + staged

**Live validation on `android16-adb` (proven, reproducible):**
1. Pushed Palm's `sensor_def_qcomdev.conf` →
   `/vendor/etc/sensors/sensor_def_qcomdev.conf`; set `hals.conf = sensors.ssc.so`.
2. Moved `/persist/sensors/sns.reg` aside → the stack **regenerated it from the
   conf**, producing a registry **byte-identical to stock** (`20a4ca02…`).
3. **Rebooted** (the ADSP reads the registry + probes sensors at *DSP boot*; an AP
   HAL restart alone does not re-probe). After boot: `dumpsys sensorservice` →
   `Total 4 h/w sensors, 4 running`, RPR0521 prox + ALS, live events flowing,
   SystemUI bound to proximity.

> **Note (2026-06-29):** the overlay staging described in earlier drafts was
> **reverted** — it mounts too late for the ADSP probe and gave 0 sensors on a clean
> flash. Final delivery is **base files** (see Status block at the top). Sequence
> below (push conf, reseed `sns.reg`, reboot) is still the correct *live* recipe; the
> only change is that the conf is now a real base file from the build, not an overlay.

**Staged in-tree (final — base files, committed):**
- `device/xiaomi/mithorium-common` @ `cfa0863`: `configs/sensors/hals.conf`
  = `sensors.ssc.so` (real base file).
- `vendor/xiaomi/Mi8937` (not git): `proprietary/vendor/etc/sensors/sensor_def_qcomdev.conf`
  (Palm's, 214457 B, md5 `b4cf5068`) + `Mi8937-vendor.mk` `PRODUCT_COPY_FILES` →
  base `/vendor/etc/sensors/sensor_def_qcomdev.conf`.
- `init.xiaomi.device.rc`: pepito sensors overlay mount removed (net-zero vs HEAD).

On a clean flash, `/persist` reseeds `sns.reg` from the base conf at first boot.

---

## Accel/gyro/mag — BHy sensor hub — ✅ **COMPLETE, LIVE DATA VERIFIED 2026-07-05**

**Final state (flash-verified):** `ram_id=11696`, `dumpsys sensorservice` = **20 h/w
sensors, 20 running**, live events in sensorservice for accelerometer (50 events),
gyroscope, magnetometer, pressure, linear acceleration — and **zero** `Data discarded
due to timestamp overlapping` in `bsthal`. Apps (phyphox) show live BHy data.

**The data-delivery blocker was three stacked kernel bugs, fixed 2026-07-05:**
| Commit | Fix |
|---|---|
| `438e117` | Frame ABI: restore `{u16 handle; u8 data[20]}` — the HAL (disassembled) reads a u16 LE handle at +0, payload at +2. Reverts the falsified `eb715f1` u8 theory. |
| `946cdd2` | `bhy_store_req_fw`: don't wait for a post-reset IRQ (BHI160B asserts INT only once firmware runs) — the CHIP_STATUS `FIRMWARE_IDLE` poll is the real gate. Fixes intermittent `ram_id=0` / "Reset ready status wait failed" / 4-sensor boots. |
| `3ff1a97` | `detect_init_event`: accept META_EVENT_INITIALIZED on the **wake-up** meta channel (0xF8/248) — Palm's firmware uses it; Samsung-derived driver only matched 0xFE/254, leaving the driver stuck in READY, never injecting the TIMESTAMP_SYNC(255) frames the HAL's clock estimator needs → every event timestamped 0 → discarded at the monotonicity gate. **This was the original "sensors register but no data" bug.** |
| `1405423` | Revert of `86112ac` debug logging (dmesg flood while in READY state) — cleanup, included in next kernel build. |

Historical investigation record follows (kept for reference).

---

### (historical) registration ✅, data delivery ❌ — 2026-07-03

> **Full execution detail: [`PLAN-bmi160b.md`](PLAN-bmi160b.md)** — driver integration,
> DTS node, HAL wiring, and the fixes that got sensors to register.

**20 h/w sensors register in sensorservice on `android16-adb`:** 4 RPR0521 (prox/ALS via SSC)
+ 16 Bosch sensors via BHy (accel, gyro, mag, orientation, pressure, gravity, linear accel,
rotation vector, game RV, geomagnetic RV, significant motion, step detector, step counter,
PDR ×2, activity recognition). `sensors.native.so` (BST BHy HAL) loads under Android 15
multihal. Sensors activate with `result=OK`. BUT: no sensor data events reach sensorservice
— apps (phyphox) see sensor names but no data. See **Current Blocker** below.

### ~~Root cause: handle is u16, HAL expects u8~~ — **FALSIFIED 2026-07-05 (disassembly + live logs). u8 fix REVERTED (`438e117`).**

The 2026-07-03 strace diagnosis inverted the frame ABI. **Ground truth from disassembling
`sensors.native.so` (lib64, BST BHy HAL 1.3.20.0, `event_read_thread_func` +
`hw_read_fifo_frame`):**

```c
struct fifo_frame { u16 handle; u8 data[20]; };   /* 22 bytes — the ORIGINAL layout */
```
- `hw_read_fifo_frame`: `read(fd, buf, 22)` (mov w2,#0x16)
- handle: **`ldrh` (16-bit LE load) at buf+0**; dispatch jump table valid for handles 1..255 only
- payload parsed **from buf+2**: accel = s16 x/y/z at +2/+4/+6, s8 status at +8
- TIMESTAMP_SYNC (255): u64 AP-ts at +2 (data[0..7]) + u32 fw-ts at +10 (data[8..11]) —
  exactly what our driver's IRQ handler enqueues
- So the strace bytes `fc 00 …` were a **correct** u16 LE 0x00FC=252, not a corrupted u8+pad.

**Live confirmation on the u8 kernel (built 2026-07-05 11:21, flashed):** after HAL restart,
`logcat -s bsthal` shows `Unknown sensor handle: 35318` (= 0x89F6 = 0xF6 | first-data-byte<<8),
`process data failed with ret: -22` — every frame rejected, **including the INITIALIZED meta
event after RAM-patch load**, which is why on this build the 16 Bosch sensors don't even
register anymore (`dumpsys` = 4 sensors, RPR0521 only). The u8 change was doubly harmful.

**Reverted in kernel commit `438e117`** (restores `u16 handle; u8 data[20]`).

### Actual open question: why did the ORIGINAL (u16) build read frames but never notify?

Disassembly narrows it to one silent drop path for a parsed accel event — the **per-sensor
timestamp-monotonicity gate**:

1. HAL computes `event_ts = ap_ts_sync − ns_per_tick × (fw_ts_sync − hub_ts_event)`, where
   `ap_ts_sync`/`fw_ts_sync` come **only** from driver-injected TIMESTAMP_SYNC(255) frames,
   `hub_ts_event` from hub TIMESTAMP_LSW/MSW frames (252/253 non-wake, 246/247 wake), and
   `ns_per_tick` from `bsx_ts_estimator_process` (fed only by 255-frames).
2. Clamped to `elapsedRealtimeNano()+300`; then **`if (event_ts <= last_ts[sensor]) discard`**
   — logs `Data discarded due to timestamp overlapping` at log level ≥3, and only a
   *successful* enqueue writes the eventfd. Matches the strace exactly (frames read, no write).
   If the sync globals are still 0 (no 255-frame processed), every event computes ts=0 → dropped.
3. Driver-side inputs verified OK: `bhy_get_ap_timestamp` uses `get_monotonic_boottime`
   (matches HAL's elapsedRealtime clock); fw-ts read from reg 0x6C (datasheet-correct);
   255-frame enqueued on every IRQ before FIFO drain.

**The HAL is fully observable**: shipped `/vendor/etc/bhy/config.ini` has `HAL_LOG_LEVEL=V`
(g_log_level=4 confirmed read at init), log tag `bsthal`. After flashing the u16 kernel, if
data still doesn't flow, `logcat -s bsthal` will name the drop ("Data discarded due to
timestamp overlapping" / "Unknown sensor handle" / "One frame data lost due to data queue
full") — no more strace archaeology needed.

### Second bug found on the `438e117` flash (2026-07-05 afternoon): RAM-patch load races INT

The u16 flash came up with only 4 sensors because `bhy_store_req_fw` failed:
`Reset ready status wait failed` → `ram_id=0` → HAL aborts enumeration and never
retries. **Deterministic** (reproduced via HAL restart at t=1799 s). Mechanism: after
`BHY_REG_RESET_REQ` the BHI160B does **not** assert INT (it only does once uploaded
firmware runs), so the 50 ms spin for the IRQ-driven `RESET_FLAG_READY` flip passes
only when a stale INT-high happened to be pending — that's the `detect_init_event`
zero-length-FIFO storm at 81.336 s, and why some boots (e.g. the u8 build that morning)
loaded firmware fine. Samsung's own `bhy_load_ram_patch` has this identical wait
**commented out ("Ignore checking")**; only the sysfs `req_fw` path (the one the HAL
uses) kept it. **Fixed in kernel `946cdd2`**: same bypass; the `CHIP_STATUS
FIRMWARE_IDLE` poll right after is the real upload-ready gate, and the INITIALIZED
meta-event handshake is IRQ-driven later regardless.

### ORIGINAL NO-DATA BUG FOUND (2026-07-05 evening, proven live): INITIALIZED meta event arrives on the wake-up channel

The `438e117`+`946cdd2` flash validated both fixes (ram_id=11696, 20 sensors registered,
accel activated) and exposed the endgame, exactly as the disassembly predicted:
`logcat -s bsthal` = **`Data discarded due to timestamp overlapping` 25×/s** — every event
dying at the HAL's per-sensor monotonicity gate.

Causal chain (all observed, none inferred):
1. dmesg: all hub traffic flows through `detect_init_event` → driver stuck in
   `RESET_FLAG_READY` → `bhy_irq_work_func`'s normal path never runs → **no
   TIMESTAMP_SYNC(255) frames injected** → HAL ts-estimator globals stay 0 → every event
   computes ts=0 → discarded.
2. First FIFO batch after `Ram patch loaded successfully`: `F7 · F6 · F8[3]` — **Palm's
   firmware emits the boot meta events on the WAKE-UP meta channel (0xF8/248)**;
   `detect_init_event` only matched non-wake 0xFE/254 → META_EVENT_INITIALIZED never
   recognized → stuck READY. (Samsung's firmware evidently used the non-wake channel.)

**Fixed in kernel `3ff1a97`**: match both meta channels in `detect_init_event` +
`detect_self_test_event` (same latent bug for self-test results).

**Validation for next flash (`438e117` + `946cdd2` + `3ff1a97`):**
1. `ram_id` ≈ 11696; 20 sensors in `dumpsys sensorservice`.
2. phyphox accel/gyro/mag — expect live data. This should be the one.
3. If anything is still off: `logcat -s bsthal` (verbose already on) + `dmesg | grep BHY`
   name the stage. No-reboot retest: `kill $(pidof android.hardware.sensors@1.0-service)`.
4. After success: drop the `detect_init_event` PINFO debug logging (`86112ac`) — it
   floods dmesg at 25 lines/40 ms while in the READY window.

---

The accel/gyro on pepito are **not** SSC/SMGR sensors — they are a **Bosch BHy sensor hub
(BHI160B) on the AP's Linux I²C bus i2c-2 at address 0x28**, driven by `drivers/misc/bhy/`
and exposed to Android by **`sensors.native.so`**, *not* the SSC path.

**Evidence (all ground-truthed, 2026-06-30; runtime confirmed 2026-07-02):**
- **`android8-adb` (true stock) — runtime proof:** `dumpsys sensorservice` lists **22
  h/w sensors running**, including 16 Bosch sensors (accelerometer, magnetometer,
  gyroscope, pressure, orientation, gravity, linear accel, rotation vector, game
  rotation vector, significant motion, step detector, step counter, geomagnetic
  rotation vector, PDR ×2, activity recognition). Kernel thread `[bhy_wq]` is live
  (pid 258). `hals.conf` lists both `sensors.ssc.so` + `sensors.native.so`. This is
  the authoritative witness for how the sensor stack looks when fully functional.
- Stock `init.target.rc` chowns `/sys/class/i2c-dev/i2c-2/device/2-0028/bmi160_foc_*`,
  `bma2x2_foc_*`, `sensor_conf`, `sensor_sel`, … → a BMI160 driver at **i2c-2/0x28**.
- Stock DTB (`dts-3.19-pepito/pepito.dts`) has, under `i2c@78b6000` (= i2c-2):
  `bhy@28 { compatible = "bst,bhy"; reg = <0x28>; … irq GPIO 61; vdd_i2c / vdd_1p8 /
  vdd_2p85 supplies; }` **and** `wusb3801x@60` (a discrete USB-C CC controller).
- `android11-adb` confirms the hardware layer: device `2-0028` exists, driver `bhy`
  bound, `rom_id`=11693 (0x2DAD), `driver_version`=1.3.18.0. But `ram_id`=0 (no
  firmware loaded) and `dumpsys` = 0 sensors — the A11 GSI userspace never initializes
  the hub. Do not use `android11-adb` as a runtime reference for sensors.
- **Our `pepito.dts` disables `&i2c_2`** on the false premise (copied from the
  incomplete **4.9 fork** DTS) that it's a vestigial empty bus with "no wusb3801, no
  sensors, nothing." The real stock 3.18 bus carries the BHy **and** the USB-C
  controller. Disabling i2c_2 killed the accel/gyro bus (and the USB-C CC controller —
  a separate latent bug; our DTS comment wrongly claims PMI8950 USBIN handles it).
- 4.19 kernel has the **mainline IIO** `bmi160` driver (`drivers/iio/imu/bmi160/`,
  compatible `bosch,bmi160`, `CONFIG_BMI160_I2C` **not set**) — but **NOT** the Bosch
  downstream `bst,bhy` sensor-hub driver. The `bst,bhy` source is **absent from the
  Palm GPL kernel release** (vendor sensor-hub driver, not shipped).

**Two implementation paths (both non-trivial — needs a dedicated effort + boot test).
See [`PLAN-bmi160b.md`](PLAN-bmi160b.md) for the full execution plan (Path B / IIO
has been deleted there — the BHI160B is a hub, not a bare BMI160, so the IIO driver
cannot probe it):**

- **Path A — match stock (`bst,bhy` + `sensors.native.so`).** Port the out-of-tree
  Bosch BHy driver to 4.19 (source not in Palm GPL → find Bosch's `bhy`/`bhi160`
  driver elsewhere), re-enable `&i2c_2` with the `bhy@28` node (resolve the 3 supplies
  + IRQ GPIO 61 to 4.19 regulator/tlmm phandles), and keep `sensors.native.so` (a
  stock Palm 8.1 blob → Android-15 ABI risk) in hals.conf. Closest to stock; most
  moving parts.
- **Path B — mainline IIO BMI160.** Enable `CONFIG_BMI160_I2C`, add a
  `bmi160@28 { compatible = "bosch,bmi160"; }` node on i2c-2, and bridge IIO → Android
  sensors (AOSP has no standard IIO sensors HAL → needs a shim/HAL). Driver already in
  tree; the HAL bridge is the work. No mag/no fusion from BMI160 alone.

**First, low-risk milestone (either path): prove the bus + chip.** Re-enable `&i2c_2`
**with a child node present** (the old zero-child `i2c-msm-v2` boot-hang at ~7.28 s was
blamed on an empty bus; stock runs this bus fine with children) and confirm a device
appears at `2-0028` / IIO device created. ⚠️ Re-enabling i2c_2 risks the boot hang —
test on a boot you can recover (pstore/ramoops), not blind.

**Magnetometer: CONFIRMED present (2026-07-02).** `android8-adb` `dumpsys sensorservice`
lists a `BOSCH Magnetometer Sensor` (android.sensor.magnetic_field) plus a `BOSCH Pressure
Sensor` (android.sensor.pressure). The BHI160B hub provides full 9-DoF fusion (accel +
gyro + mag) plus barometer. (`6-0034` on i2c-6 remains unidentified; `2-0060` is the
wusb3801 USB-C controller, not a sensor.)

Success = `dumpsys sensorservice` on `android16-adb` matches `android8-adb`: 22 h/w
sensors (6 RPR0521 via SSC + 16 Bosch via BHy), live data.

---

## Tree cleanup — revert the stock-daemon detour — ✅ DONE 2026-07-05

Executed as written below, with two deltas: `sensors.native.so` is **kept** (it turned
out to be the required BHy HAL, not legacy debris), and the `/persist/sensors`
registry-dir setup in `init.qcom.sensors.sh` is kept (SSC HAL reseeds `sns.reg`).
Commits: mithorium-common `4a83a0d` (service + start hook + bind-mount + config.fs),
Mi8937 `b7e9e6f` (extraction manifest); vendor-tree staging removed on disk (not git).
Removal was validated live first: `vendor.sensors.qti` stopped + HAL restart → all 20
sensors re-enumerate with data. Original plan text follows for reference:

- **Drop the empty-`hals.conf` workaround.** Set
  `device/xiaomi/mithorium-common/configs/sensors/hals.conf` (or pepito override)
  back to the nightly's one line: `sensors.ssc.so`. Rationale ("blocks before HIDL
  registration") is obsolete — it now registers cleanly.
- **Remove the vestigial `vendor.sensors.qti` daemon.** The nightly has no such
  binary; the SSC HAL talks QMI directly. Drop `vendor.sensors.qti` service from
  `rootdir/etc/init.target.rc`, the `start vendor.sensors.qti` in
  `init.qcom.sensors.sh`, the `config.fs` entry, and stop staging stock
  `sensors.qcom`-as-`sensors.qti`. (First verify on-device the HAL still enumerates
  with `sensors.qti` stopped — it should; it was already idle during the retest.)
- **Drop `sensors.native.so`** from packaging — it is stock Palm's Bosch BHy HAL
  for the legacy path, finds no device, and is not in the nightly.
- **Drop the `/persist` bind-mount hack** in `init.qcom.sensors.sh` (the pepito
  `rm /persist; mount --bind` block). It existed only for the stock daemon's Android-8
  path canonicalization bug; the nightly SSC HAL uses `/mnt/vendor/persist/sensors/`
  via the standard symlink, which is what siblings use. Keep only the
  `/persist/sensors` ownership/perms setup if the SSC HAL needs it (verify).
- **Keep** `qrtr-ns` packaged (already done for radio) — it is the load-bearing
  dependency for sensors too.

After cleanup, the sensor AP stack is byte-for-byte the nightly's; the only
pepito-specific delta should be the **DSP firmware/registry** from step 2.

---

## What is NOT the problem (closed)

- ❌ ~~Missing `qrtr-ns` / QRTR service 256 never advertised~~ — **fixed**, the
  whole reason this subsystem is now testable.
- ❌ ~~`sensors.ssc.so` blocks before HIDL registration~~ — registers cleanly.
- ❌ ~~`/persist` symlink canonicalization~~ — was a *stock-daemon* bug; the SSC HAL
  is fine with the symlink.
- ❌ ~~Missing `libqmi_encdec` / dependency closure~~ — resolved long ago.
- ❌ ~~"Wrong HAL, should port stock SMGR daemon"~~ — wrong turn; the SSC HAL *is*
  the SMGR client and is correct. Don't port stock's daemon topology.
- ⚠️ `HAL specifies version 1.4, but does not implement set_operation_mode()` —
  benign; registration completes regardless (old §2g).
- ⚠️ `Thread Pool max thread count is 0 ... serviceName: sensorservice` — benign
  framework-side warning (sensorservice is the consumer), not the blocker.

---

## Checklist

- [x] Transport unblocked by `qrtr-ns` (radio-validated, sensor-confirmed 2026-06-25)
- [x] `sensors.ssc.so` registers `ISensors/default`; SMGR link live (`version=23`)
- [x] **Root-caused `SensorInfo_len: 0`** → missing pepito `sensor_def_qcomdev.conf`
- [x] ADSP image md5-confirmed identical to stock (from `modem.bin`) → H1 dead
- [x] Stock registry/config obtained from the **dump** (`persist.bin`, extracted vendor) — no A11
- [x] **Live-validated:** conf + reseed + reboot → **4 h/w sensors running** (RPR0521 prox/ALS)
- [x] Overlay delivery tried → **0 on clean flash** (mounts too late for the ADSP probe)
- [x] **Base-file delivery validated on-device** (real conf in base `/vendor/etc/sensors` → 4 sensors)
- [x] **Committed/staged:** mithorium `hals.conf`=sensors.ssc.so (`cfa0863`) + base `sensor_def_qcomdev.conf` (vendor tree)
- [x] **Clean build + flash CONFIRMED (2026-06-29): 4 sensors, base files from the image (no overlay), conf md5 `b4cf5068`**
- [x] **Accel/gyro root-caused (2026-06-30):** Bosch BHy/BMI160 on Linux i2c-2@0x28 (`sensors.native.so`), NOT SSC; `&i2c_2` wrongly disabled in pepito.dts; `bst,bhy` driver absent from GPL
- [x] **Runtime confirmed on true stock (2026-07-02):** `android8-adb` = 22 h/w sensors (6 RPR0521 + 16 Bosch including accel/gyro/mag/pressure); `[bhy_wq]` kernel thread live. `android11-adb` NOT a runtime witness (A11 GSI never loads hub firmware).
- [x] **BHy kernel + HAL wired (2026-07-02/03):** `sensors.native.so` + `bst,bhy` driver + `input` group + i2c-dev sysfs attrs all wired. 20 sensors register in sensorservice. See `PLAN-bmi160b.md`.
- [x] **PERMISSION_DENIED fixed (2026-07-03):** expanded ueventd rules from 8 to 21 attrs; `sensor_conf` now `0660 system system` → all BOSCH sensors activate `result=OK`
- [x] SELinux: `sysfs_bhy` type + genfscon + `hal_sensors_default.te` staged in `Mi8937/sepolicy/vendor/`
- [x] ~~Root-caused: u16 handle shifts data 1 byte~~ — **FALSIFIED 2026-07-05 by sensors.native.so disassembly + live `bsthal` logs; HAL reads u16 LE handle at +0, data at +2. u8 kernel made it worse (broke registration too: `Unknown sensor handle: 35318`). Reverted in `438e117`.**
- [x] **req_fw RAM-patch load race fixed (`946cdd2`)** — flash-verified: `ram_id=11696`, "Ram patch loaded successfully", reproducible across HAL restarts
- [x] **Wake-channel INITIALIZED meta event fixed (`3ff1a97`)** — THE original no-data bug; flash-verified 2026-07-05
- [x] **DATA FLOWING (2026-07-05):** 20/20 sensors running, live events for accel/gyro/mag/pressure/linear-accel in sensorservice, zero timestamp discards, phyphox shows data
- [x] PLAN.md sensors row updated (✅ live data verified 2026-07-05)
- [x] Debug-log cleanup: `86112ac` reverted in-tree (`1405423`) — lands with the next kernel build (flashed kernel still has the READY-window dmesg spam until then; harmless post-fix since READY is now transient)
- [x] **Tree cleanup DONE (2026-07-05):** dropped `vendor.sensors.qti` (service in `init.target.rc`, `start` in `init.qcom.sensors.sh`, config.fs caps block — mithorium-common `4a83a0d`), `/persist` bind-mount hack (same commit; registry-dir setup kept — SSC HAL reseeds `sns.reg` there), `sensors.qcom`→`sensors.qti` extraction line (Mi8937 `b7e9e6f`), and the vendor staging (Android.bp module + mk line + binary; vendor tree, not git). **Verified live before removal**: daemon stopped + HAL restart → 20 sensors re-enumerate with data. `sensors.native.so` kept (it's the BHy HAL, required). Sanity-check next clean flash: sensors still enumerate at boot (init script edits ride vendor.img).
```
