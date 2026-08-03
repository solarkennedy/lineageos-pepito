# PLAN-perf-battery: Low-Level Performance & Battery Optimization

**Scope:** kernel-level CPU/GPU/IO scheduling, thermal, charging, and wakelock hygiene —
not app-level battery (Doze/App Standby are stock AOSP and out of scope here).

> **Battery Health *data*** (SoH %, cycle count, design capacity for the Android 16
> Battery Health screen) is a separate lane — see [`PLAN-battery-health.md`](PLAN-battery-health.md).
> This file is about *reducing drain*, not reporting health stats. Charge-limit control
> (LineageOS `IChargingControl`) already works and needs nothing.

---

## ⭐ High-level summary (updated 2026-07-23)

**Shipped/working:**
- 7 "Pepito Tweaks" toggles live in Settings (I/O sched needed no change — blk-mq
  already picks BFQ; wakelock audit clean; GPU clamp, zram-zstd, low_ram, heap_trim,
  lmk, dexopt Go-style tunables; "Our own Extreme Battery Saver" auto-hooks CPU-cluster
  hotplug + GPU clamp onto the stock Battery Saver switch).
- **wcnss standby-churn bug FIXED and validated**: `hostArpOffload=0` + `hostNSOffload=0`
  in `WCNSS_qcom_cfg.ini` → wifi-caused IRQ-71 resumes go to zero. This is the biggest
  win of the campaign.
- **Release-final standby number (2026-07-23, true no-adb bracket): A16 beats stock by
  ~58% (64mW vs 151mW)** — see bottom section. Headline number for release notes.
- Brightness/panel "regression" **mostly dissolved**: A16's slider is linear (standard
  modern-AOSP `settings put` behavior, not a bug) while stock's saturates ~70-73% duty
  by setting 128 — so A16 at 255 is genuinely brighter (~1.4×), not just hungrier at
  matched luminance. Open decision: cap max brightness to stock parity, or ship as a
  feature (see bottom section).
- "+36% dark-load regression" **DISSOLVED** — was suspend freeze-cycling from a TCP adb
  connection during the CPU bench, not a real platform CPU deficit. At matched wakefulness
  A16 hashes at parity with stock (48.2 vs 48.5 MB/s/thread). No CPU-side action needed.
- **⭐ Bench methodology rule that resolved most of the campaign's noise:** a merely
  *registered* TCP adb session (even silent) multiplies standby wake rate ~8× and drain
  ~3×; USB adb keeps the SoC from deep suspend entirely. Any screen-off power number
  must be taken fully cable-out or the number is contaminated.

**Open / deferred:**
- Bracket 2 — CT-3 wall-truth, wakefulness-pinned sustained-CPU-load bracket on both
  units (would give a real mW number instead of the MB/s-parity proxy). Deferred by Kyle
  2026-07-23 to chase the BHY sensor-wedge bug (`[[bhy-hub-wedge-no-recovery]]`).
- Brightness-cap release decision — not blocking.
- core_ctl/schedutil pepito-specific tune (item 4) and sched_boost re-check (item 5) —
  parked, low priority, no A/B testing done.
- Settings-UI-for-tunables (B1 property-bridge design) — decided, not yet built beyond
  the Go-tweaks/battery-saver toggles already shipped.
- On-device validation of the Go-tweaks toggles' actual behavior (reboot persistence,
  `pm list features` diff) — not yet done.
- `dumpsys suspend_control_internal` short-suspend-backoff sysprops — documented as a
  lever, deliberately not staged (real cadence post-fix doesn't obviously need it).

---

## ⭐⭐ Responsiveness lane (2026-08-02) — interaction/launch boost was COMPLETELY DEAD; fixed + live-validated, staged

Kyle opened a "make the phone feel more responsive" push (agreed order: ① boost
diagnostic/fix → ② zram-zstd default + 0.5× animation defaults → ③ CT-3 A/B of the
960 MHz big-cluster min-freq floor + core_ctl min_cpus, i.e. finally item 4 with data).

**Finding: every framework interaction/launch boost has failed since bring-up.** The
framework sends `setBoost INTERACTION` on every touch; QTI PowerHAL logged
`Failed process_boost for boost_handle` on each. THREE stacked causes, all proven live
on DUT1 (`c39a6acf`) by fixing each in turn:

1. **`vendor.qti.hardware.perf@2.2-service` never packaged** — listed in
   `proprietary-files-qc-vndr.txt` (+rc) but blobs never extracted into
   `vendor/xiaomi` (same class as libacdbloader/libsdm-color). mp-ctl lives in this
   HAL; without it no boost can execute. Deps also missing: `libqti-perfd.so`,
   `libperfconfig`, `libperfgluelayer`, `libperfioctl`, `libqti-util`,
   `libthermalclient` (closure verified complete against nightly).
2. **No 64-bit `libqti-perfd-client.so` anywhere** — only the 2 KB 32-bit pepito
   camera stub. The 64-bit PowerHAL dlopens this client at runtime (not DT_NEEDED) →
   every boost died client-side. Real 64-bit client from nightly fixes it; 32-bit
   stub kept for camera (different dir, no conflict).
3. **`perfboostsconfig.xml` scroll boosts gated `Kernel="3.18"`/`"4.9"`** — we run
   4.19, so 0x1080 v/h-scroll entries never matched even with the HAL alive. Fixed by
   duplicating the msm8937 4.9 entries as `Kernel="4.19"` (launch boost 0x1081 Type 1
   is unqualified and worked as soon as the HAL ran).

**Validated live:** swipe → policy0 `scaling_min_freq` 960000 → **1344000** for ~1 s
(0x514 = 1.3 GHz → nearest step), boost errors gone, launch boost clean (Settings
cold start 1.28 s). Battery cost ~nil (boost only during interaction).

**Staged (uncommitted), Mi8937 layer (all siblings run our 4.19 kernel and had the
same dead boosts):** blobs under `vendor/xiaomi/Mi8937/proprietary/vendor/`
(bin/hw + etc/init + lib64×7), `Android.bp` (7 new prebuilt modules;
`libqti-perfd-client` now multilib-both: 32=stub, 64=real), `Mi8937-vendor.mk`
(PRODUCT_PACKAGES + rc copy), patched `etc/perf/perfboostsconfig.xml`.

**✅ Init-started-under-Enforcing leg VALIDATED same day (Kyle authorized the DUT1
reboot):** binary+rc live-pushed to /vendor → clean reboot → HAL runs as
`u:r:hal_perf_default:s0` via init, **zero AVC denials, zero boost failures since
boot, swipe → min_freq 960000→1344000**. No sepolicy work needed; the fix is fully
proven end-to-end. Gotchas hit along the way: chcon type is `vendor_file` not
`vendor_file_t` (use restorecon — an unlabeled lib fails dlopen under Enforcing);
mpctl init logs benign `KPM nodes`/`Invalid cluster id 2` errors; `pkill -f`
self-match strikes again.

**Step ② also staged 2026-08-02:**
- **zram-zstd now DEFAULT-ON** (Kyle: "worked with zram for a while, perfectly
  stable — second the decision"). Two synced edits: `post_boot.sh`
  `configure_zram_parameters()` treats unset as on (`!= "0"` check) +
  `GoTweaksSettings.java` toggle default `true`. Toggle still opts out (writes "0").
- **0.5× animation scales default (pepito-gated):** empirically established that
  window/transition scales seed into Settings.Global from SettingsProvider's
  `def_window_animation_scale`/`def_window_transition_scale` fractions at
  settings-DB creation (verified live: global rows exist = 1.0, animator = null →
  never seeded). Staged: 2-line frameworks/base patch (new
  `def_animator_duration_scale` fraction + `loadDefaultAnimationSettings()` seeds
  `ANIMATOR_DURATION_SCALE`; 100% upstream default = no behavior change for
  siblings) + `Mi8937/overlay-pepito/` SettingsProvider overlay setting all three
  to 50%, wired under the `TARGET_DEVICE_PEPITO` gate in `device.mk`. Applies at
  DB creation only — fine for releases (flash always zeroes userdata); dirty
  flashes keep old values. DUT1 set to 0.5× live for feel-preview.

**Step ②b — camera/audio perf locks ✅ VALIDATED + STAGED same day (real 32-bit
client replaces the stub).** History: the Palm "jinghuang" patch inside the
proprietary mm-camera blobs dlopens `ro.vendor.extension_library`
(=libqti-perfd-client.so) at camera_open and **SIGSEGVs on a null dlopen handle at
mm_camera_intf_close** — the whole reason the 2 KB no-op stub existed (stock A8
client couldn't load: perf@1.0 dep). The nightly 32-bit client's deps all resolve
now (32-bit `vendor.qti.hardware.perf@2.2.so` already ships; rest is VNDK), so the
crash precondition is gone. Live-swapped on DUT1 (stub backed up at
`/vendor/lib/libqti-perfd-client.so.stub` + `/data/local/tmp/perfd-stub-backup.so`)
and ran the brittleness gauntlet: **5× open/close cycles (the crash site), rear
photo, front-camera flip, front video w/ audio, zero tombstones/crashes.**
⭐ Smoking-gun trace: `perf_lock_acq: client_pid=<camera-provider>, list=0x101
0x2FE 0x1FFE → output handle=1` — camera's LEGACY opcodes are accepted by mp-ctl.
Audio HAL is the OTHER 32-bit consumer (dlopens it lazily on first stream) —
restarted it, real client maps, playback fine. Camera cold-launch parity-or-better
(999/1004/979 ms vs 1356/1038/987 baseline); real win = in-session locks (open,
snapshot, preview). Staged: real 32-bit client replaces the stub artifact at
`vendor/xiaomi/Mi8937/proprietary/vendor/lib/`; stub source+binary kept in
`pepito-perfd-stub/` as fallback; Android.bp comment updated. Debug technique:
`vendor.debug.trace.perf=1` + restart perf HAL → per-request `ANDR-PERF-MPCTL`
acq/rel logs with client pid + opcode list (prop resets on reboot).

Remaining in the lane (step ③, needs the flashed build): CT-3 A/B of lowering the
permanent 960 MHz big-cluster floor (post_boot.sh) — safer now that scroll boost
supplies interaction-time freq — and core_ctl min_cpus. Also queued (found
2026-08-02 while explaining EAS/uclamp to Kyle): **schedtune is all-zero** —
`/dev/stune/top-app` boost=0 prefer_idle=0 (A16 task_profiles likely no longer
drives stune on this 4.19/CONFIG_SCHED_TUNE kernel; uclamp doesn't exist pre-5.3).
Candidate lever: top-app boost=5-10 + prefer_idle=1 via init → tap-latency A/B,
small power cost; two sysfs writes, live-testable. Post-flash validation
checklist: perf HAL domain/denials/boost (as above), `zram0/comp_algorithm` shows
`[zstd]`, `settings get global animator_duration_scale` = 0.5 on a clean flash,
Pepito Tweaks zstd toggle shows ON, camera open/close + photo + audio playback
clean (jinghuang path now exercises the real client).

---

## Baseline survey (2026-07-10)

Grounded in `mi8937_defconfig`, `device/xiaomi/mithorium-common/rootdir/bin/init.qcom.post_boot.sh`,
`kernel/xiaomi/msm8937/.../pepito/battery_usb.dtsi`, `mithorium.mk`.

- **CPU governor:** defconfig default is `performance`, but `init.qcom.post_boot.sh`
  overrides both clusters to `schedutil` at runtime (stock QTI multi-SoC tune, shared
  with land/santoni/prada/ugg — no pepito-specific perf profile exists).
- **CPU hotplug:** `core_ctl` enabled, untuned for pepito specifically.
- **Scheduler:** WALT + SCHED_TUNE + SCHED_MC, `NR_CPUS=8`.
- **I/O scheduler:** defconfig says CFQ, but real eMMC queue runs blk-mq which already
  defaults to `[bfq]` — the defconfig setting is inert.
- **zram:** lz4, 50-75% of RAM, capped 4096MB — reasonable as-is.
- **GPU (Adreno 505/kgsl):** full pwrlevel range available by default (216-475MHz), not
  clamped.
- **Thermal:** source-built Thermal HAL 2.0, no pepito-specific thermal-zone DTS.
- **Battery/charging** (`battery_usb.dtsi`): float-voltage 4400mV, JEITA limits set, no
  fast-charge beyond stock `qpnp_smbcharger`.
- **Suspend/wakelocks:** unlimited wakelocks, no GC/autosleep caps — worth auditing given
  freshly-bootstrapped bring-up code (qmux/rmnet/ims_enabler) could retry against a dead
  socket.
- **PowerHAL:** stock prebuilt Qualcomm binary, no custom hint/boost logic.

---

## Options considered

| # | Option | Scope | Risk | Expected payoff |
|---|---|---|---|---|
| 1 | I/O scheduler CFQ → BFQ | `mi8937_defconfig` (global) | Low | UI responsiveness; no battery cost |
| 2 | Live wakelock audit | Diagnostic only | None | Catch bring-up-era leaks before release |
| 3 | GPU pwrlevel clamp check | Diagnostic first | Low | Recover perf headroom or clamp waste |
| 4 | Tune core_ctl/schedutil for pepito | Needs pepito-only gating | Medium — needs A/B feel-testing | Battery vs. responsiveness, unclear win |
| 5 | sched_boost/sched_load_boost re-tune | Shared post_boot.sh | Low | Likely leave as-is |

---

## TODOs

- [x] **(1) BFQ default I/O scheduler** — checked live 2026-07-10, **no action needed**:
  `mmcblk0` runs blk-mq and already defaults to `[bfq]`; CFQ config is inert.
- [x] **(2) Wakelock audit** — checked live 2026-07-10, **clean**: `mWakeLockSummary=0x0`,
  all `wakeup_sources` show `prevent_suspend_time=0`. No leaks.
- [x] **(3) GPU pwrlevel clamp** — checked live 2026-07-10, **not clamped**, full
  216-475MHz range available, normal adaptive DCVS. Became the basis for the GPU clamp
  toggle below, not a fix.
- [ ] (4) core_ctl/schedutil pepito tune — parked pending A/B feel-testing.
- [ ] (5) sched_boost re-check — parked, likely no action needed.

### GPU clock cap toggle — implemented 2026-07-10 (commit `329f220`)
Opt-in `persist.gotweak.gpu_clock_cap` caps `kgsl-3d0/max_pwrlevel` to 3 (375MHz)
instead of default 0 (475MHz) — a real perf/battery tradeoff. Plain sysfs write (not a
property), applies **live**, no reboot in either direction — the only gotweak that skips
the reboot dialog.
**Sepolicy gotcha (recurring pattern, hit 4× total this doc):** `vendor_init` (the domain
executing `on property:` sysfs-write triggers) needs its own explicit write grant per
sysfs class touched — base policy read access does not imply write, and no other spawned
domain (`qti_init_shell` etc.) runs these triggers. Added
`allow vendor_init sysfs_kgsl:file rw_file_perms;`, verified with `checkpolicy` before
flashing each time.

### zram compression algorithm — implemented 2026-07-11 (commit `655f06b`)
zstd added as a `persist.gotweak.zram_zstd` toggle alongside the already-live lz4 (both
compiled in; zstd trades CPU for a better ratio = more effective swap on this low-RAM
device). Unlike sysfs toggles, `comp_algorithm` can't change while zram is live as swap,
so it's read inside `configure_zram_parameters()` (the function that owns zram's
one-time-per-boot setup) — reboot-gated. Same sepolicy-gotcha class: `qti_init_shell`
(a third distinct domain from `vendor_init`/`system_app`) needed its own `get_prop` grant
on `gotweak_prop`.

---

## User-facing settings UI (no root required) — surveyed 2026-07-10

**Goal:** expose tunables (I/O sched pick, wakelock/GPU toggles) from Settings without root.

- **Option A — LineageOS "Performance Profiles":** fully removed upstream, zero
  references anywhere in tree. Ruled out.
- **Option A' — `LineageHardwareManager` capability bridge:** not implemented for this
  device at all, and its capability enum is fixed in shared Lineage SDK code — adding
  arbitrary tunables would mean patching shared framework. Ruled out; no reuse payoff
  over building a bespoke HAL.
- **Conclusion: no existing Lineage plumbing to reuse.** Two viable bespoke designs:

| | B1 — property + init.rc trigger (phh-style) | B2 — small AIDL vendor HAL |
|---|---|---|
| New code | Minimal: one prop + `on property:` block per toggle | Full HAL service (init, manifest, sepolicy, AIDL, impl) |
| Feedback to app | None (fire-and-forget) | Synchronous read-back possible |
| Fit | Good — toggle list is experimental/evolving | Better once toggle list stabilizes |

**Decision: B1.** Smallest moving-part count, fits an experimental/growing tunable list.
Revisit B2 only if the toggle set stabilizes and needs live read-back. This is the design
all the Go-tweaks/battery-saver toggles below actually use.

### TODOs (settings UI)
- [ ] Decide final toggle list to expose beyond what's already shipped.
- [ ] New sepolicy type for init-trigger sysfs writes — coordinate with the Enforcing
  SELinux pass in `PLAN-release.md` rather than doing it twice (mostly already covered
  by the per-toggle grants added along the way).
- [ ] Settings surface: LineageParts preference screen (reuses existing app/signing) vs.
  standalone app — leaning LineageParts, not yet decided (moot: already built this way).

---

## Android Go-style memory tweaks — enumerated + staged (2026-07-10)

Prior context: a full Android Go product-config inherit was tried and reverted
2026-07-08 (memory `appwidget-service-missing-go-edition` — silently dropped
`android.software.app_widgets`, NPE-crashed Twelve). Device is ~2.87GB RAM — not
Go-tier by Google's threshold, but low enough that individual tunables help. **Decision:
never re-adopt the Go hardware-feature manifest; expose only individually-safe tunables
as real Settings toggles**, never an all-or-nothing product-config inherit.

- **Category 1 — build-time only, baked in 2026-07-11** (`device/xiaomi/Mi8937` commit
  `10c561c3`): `speed-profile` compiler filter, no debug ART build, minimized Java debug
  info, `MALLOC_LOW_MEMORY=true` (non-eng only). One-time build decisions, no toggle.
- **Category 2 — runtime props, staged as live toggles** (table below).
- **Category 3 — the `go_handheld_core_hardware.xml` manifest swap — SKIPPED.** Diffed
  it: `notLowRam="true"` features (PiP, voice_recognizers, secondary-displays) already
  disappear automatically once `ro.config.low_ram=true` is set, with or without the
  manifest swap. `app_widgets` stays present unconditionally by never adopting the Go
  manifest — the 07-08 crash class cannot recur under this design.

### Category 2 toggles — implemented 2026-07-10
Four `persist.gotweak.*` booleans, default off, staged at the `mithorium-common` layer
(generic to any low-RAM Mi8937 sibling, default-off = inert elsewhere):

| Property | Sets | Pepito default | Go value | Apply |
|---|---|---|---|---|
| `persist.gotweak.low_ram` | `ro.config.low_ram` | unset | `true` | reboot; **drops PiP/voice_recognizers/secondary-displays** |
| `persist.gotweak.heap_trim` | `dalvik.vm.heapgrowthlimit/heapsize` | `192m`/`512m` | `128m`/`256m` | reboot (zygote reads once) |
| `persist.gotweak.lmk` | `ro.lmk.*` pressure/kill knobs | lmkd defaults | Go tunings | reboot (`ro.*` + lmkd reads once) |
| `persist.gotweak.dexopt` | `pm.dexopt.downgrade_after_inactive_days`/`shared` | unset/`speed` | `10`/`quicken` | asymmetric: on=live, off=no revert trigger (sticks until reboot); UI shows same reboot prompt for consistency |

**Files:** `mithorium-common/rootdir/etc/init.gotweaks.rc` (4 trigger blocks) +
`Android.bp` + `mithorium.mk` (PRODUCT_PACKAGES) + `init.qcom.rc` import +
`sepolicy/vendor/{property.te,property_contexts,gotweaks.te}`.

**⭐ Sepolicy gotcha (the load-bearing one):** first attempt made `gotweak_prop`
vendor-owned so LineageParts could write it — `checkpolicy` caught a global Treble
neverallow (`compatible_property_only`) forbidding **any** coredomain (all apps) from
setting **any** vendor-owned property, public or internal. Fix: property must be
**system-owned** (`system_public_prop`, no `vendor.` infix); vendor init triggers can
still *read* a system property fine. **General lesson: whenever an app needs to *set* a
property a vendor init trigger acts on, the property must be system-owned.**

**LineageParts UI — done 2026-07-10** (`pepito-lineageparts` commit `0e5cce1`): Settings
> Memory tweaks screen ("Pepito Tweaks" — scope later expanded to general pepito
settings, not just low-RAM). Plain `SwitchPreferenceCompat`s via `SystemProperties`,
shared "Restart required" dialog (`PowerManager.reboot`, `REBOOT` perm auto-granted to
this platform-signed app).

**First validation flash caught 2 bugs, both fixed:**
1. `vendor_init` couldn't *read* `gotweak_prop` — Enforcing SELinux caught
   `ParseTriggers() failed` for all 4 triggers (none registered at boot). Fixed with
   `get_prop(vendor_init, gotweak_prop)` — declaring a prop `system_public_prop` doesn't
   grant the vendor-init read side.
2. Screen unreachable from Settings — `parts_catalog.xml` only drives search indexing; a
   LineageParts fragment also needs an `activity-alias` with `IA_SETTINGS` intent-filter
   to appear in navigation. **Both are required for any future LineageParts addition.**

Also added: QS horizontal volume slider toggle duplicated here (both entry points kept).
Confirmed a true top-level "Settings > Pepito Tweaks" tile isn't achievable without
editing AOSP's hardcoded `top_level_settings.xml` — stayed nested under Settings > System.

**Not yet done:** on-device validation of toggle persistence/values after reboot,
`pm list features` diff for `low_ram`.

---

## CPU cluster auto-disable under Battery Saver — implemented 2026-07-11

Root-only lever normal Battery Saver can't reach (it only does app-visible restrictions,
never raw CPU hotplugging). Confirmed live topology: cpu0-3 cap 1.4GHz, cpu4-7 ~1.1GHz,
cpu0 hotpluggable on this kernel.

**Design:** not a new Pepito Tweaks toggle — follows the *existing* stock Battery Saver
switch automatically. `GotweaksBatterySaverReceiver` piggybacks on `XiaomiParts`
(already `persistent="true"`), registers dynamically for
`ACTION_POWER_SAVE_MODE_CHANGED` from `BootCompletedReceiver` (manifest `<receiver>`
can't catch this broadcast — must be dynamic), mirrors state into
`persist.gotweak.cpu_cluster_saver`; `init.gotweaks.rc` triggers do the actual
`cpu{0,1,2,3}/online` writes, live, no reboot.
**Sepolicy:** same recurring gotcha — `vendor_init` had base read but no write on
`sysfs_devices_system_cpu`; added the rw grant. No new grant needed for the property
write itself (`XiaomiParts` shares `system_app` domain/signing with LineageParts).

**Kill switch (`persist.gotweak.battery_saver_hook`, default on)** — 7th toggle, since
this mechanism was new/unvalidated; ANDed into the saver check, flipping it recomputes
state immediately.

**Extended to GPU clock cap** (retitled "Our own Extreme Battery Saver" — a real Pixel-
Extreme-Battery-Saver equivalent). Needed care: the GPU cap already has an independent
*manual* toggle on the same sysfs node — naively sharing the property would let toggling
Battery Saver off silently clobber a standing manual preference. Fixed by **OR-composing
two separate properties** at the `init.gotweaks.rc` layer: each has its own "on" trigger,
but "off" only fires when *both* are 0.

**Not yet validated on-device.**

---

## Battery benchmark campaign — A8-stock vs A16

**Method:** coulomb-counter deltas via `dumpsys battery` (works unrooted), mW-first (mA
inflates as voltage sags). **Acceptance bar: same hardware + we own the stack ⇒ any cell
where A16 loses to stock is a bug.** Phones: A8 witness `4373dd0f`, A16 DUT2 `81eed371`.

### Idle dataset (2026-07-14) — initial results, since largely explained/dissolved

| Cell (airplane, mW) | A8 stock | A16 | Verdict |
|---|---|---|---|
| Screen-on idle, brightness 255 (matched max) | 780 | ~1243 | ⭐ +59% — **later explained: A16's max is a real brighter panel state, not a bug (see 07-16 curve finding)** |
| Screen-on idle, setting 128 | ~822 | ~926 | +13% — later shown to compare mismatched luminances |
| Battery Saver screen-on idle | 639 (−22%) | 924 (−3%) | stock saver = framework restrictions; our levers idle-neutral |
| Forced-Doze standby, Wi-Fi on | ~10 (overnight) | ~476 | ⭐ ~48× — **wcnss churn, later FIXED, see below** |
| Forced-Doze standby, Wi-Fi OFF | — | ~116 | residual vs stock — bug #3, unattributed |
| Standby w/ saver (churn regime) | — | 475 vs 525 (−10%) | parked cores only help while churning |

### Bug #1 (brightness) — root-caused 2026-07-16, mostly dissolved
Live sysfs read at 4 settings on A16: `wled = round(setting/255 × 4095)` exactly —
perfectly linear, no gamma. Initial hypothesis (missing `display-device-config.xml`
gamma table) was **checked against actual framework code and found WRONG**:
`DisplayDeviceConfig.createBacklightConversionSplines()` only feeds autobrightness/nits
conversion, not manual-slider mapping. The real perceptual curve lives in the
**Settings slider UI** (`BrightnessUtils.convertGammaToLinear`) — `settings put system
screen_brightness N` bypasses it entirely by design (bench methodology artifact, matches
Pixel behavior too). Real question was only: what does stock drive at its max setting?
**Answer (CT-3 sweep on Silver, 2026-07-16): stock saturates ~70-73% duty by setting 128
and stays flat to 255; A16 hits true 100% duty (4095) only at 255.** So A16 at 255 is
genuinely ~1.4× brighter, not just less efficient — the "+41%/+59%" idle rows above
mostly reflect **more light**, not a platform bug. At matched luminance (A16 ≈180-190)
the display increment is at parity or better than stock. Remaining true gap is only the
screen-off baseline (see churn section). **Open decision, not a bug:** cap max
brightness to stock parity via `config_screenBrightnessSettingMaximumFloat≈0.72` RRO, or
ship the brighter max as an intentional feature (see release-final section at bottom).

### Bug #2 (wcnss standby churn) — ROOT-CAUSED AND FIXED, validated 2026-07-17
`dmesg`: "Resume caused by IRQ 71, wcnss_wlan" firing every 2-4s during standby. Chain of
findings:
- ini-key parity with stock ruled out as the cause; the real mechanism is Android
  "quiet mode" (`SETSUSPENDMODE 1`), armed correctly end-to-end (framework→supplicant→
  driver all healthy) — but the **armed filter value was wrong**: `hostNSOffload`
  default-on in our 4.19 CAF prima was clearing the multicast bit, and separately **ARP
  offload was clearing the broadcast bit** — net effect, fw suspended with essentially no
  mcast/bcast filter on a broadcast-heavy LAN.
- **Fix: `hostArpOffload=0` + `hostNSOffload=0`** in `mithorium-common/wifi/
  WCNSS_qcom_cfg.ini` (stock-matching for all prima siblings). **Validated 2026-07-17:
  `mcastBcastFilter=3 set=1` arms correctly, wifi-caused AP resumes go to ZERO** across
  ~15min of screen-off windows (down from 94/boot). Trade-off accepted: device
  unreachable via LAN discovery while asleep (matches stock; wlan IPv4 keeps ARP
  offload… wait — ARP offload is off, so host wakes for ARP directed at it specifically,
  which is the accepted cost — connectivity/ping intact, 0% loss).
- ⚠️ **`wakeup_count` is a misleading metric for this bug** — it counts every wake source;
  use `Resume caused by IRQ 71` counts specifically.
- ⚠️ **/data-copy trap:** prima reads `/data/vendor/wifi/WCNSS_qcom_cfg.ini`, which is
  create-if-missing from `/vendor` and NOT refreshed each boot — a dirty flash or live
  `/vendor` edit needs the `/data` copy patched/deleted too, or the fix is silently
  ignored. Clean flash regenerates it fine.
- This churn was also the trigger for the BHY hub wedge (`PLAN-sensors.md` /
  `[[bhy-hub-wedge-no-recovery]]`) — fixing it had a second payoff.

### Bug #3 (~106mW Wi-Fi-off residual) — minor, unattributed
Known contributor: health-service BOOTTIME_ALARM every 60s. Not fully chased.

### Bug #4 (Doze-dream wedge) — mitigated
Ambient DozeService held `DOZE_WAKE_LOCK` the whole window (no AOD hw on this device).
Mitigated via `settings put secure doze_enabled 0`; root cause (pulse path) still open —
consider default-off for pepito if never fixed.

### "+36% dark-load regression" — DISSOLVED 2026-07-16
Initial CT-3 number (Gold 1949mW vs witness 1438mW on 2×`sha256sum`, screen off) looked
like a real CPU-efficiency regression. Long falsification chain (screen-off perfd-cap,
CPR/voltage, clock-lie all falsified in turn) led to the real cause via ftrace
`sched_switch`: the A16 unit was **freeze-cycling** — TCP adb over Wi-Fi kept pulsing
wakeups, so Android's kernel freezer (`android.system.suspend-service`) repeatedly froze
all userspace while suspend kept aborting and retrying, leaving the hash task on-CPU only
~34% of wall time. **Proof:** with `mWakefulness` verified `Awake` throughout (no screen
timeout re-sleep), A16 unpinned = 48.2MB/s/thread ≡ stock's 48.5. **CPU/CPR/clocks/
scheduler/placement all at parity — no fix needed.**
**⭐ Bench rule added:** any screen-off cell with on-device work on A16 runs inside
freezer-cycling unless wakefulness is explicitly pinned (screen-on + `svc power stayon
true`, or a held wakelock) — record `mWakefulness` at both start and end of every
workload cell. This was very likely the root of the older "between-cell variance exceeds
lever effects" problem that had parked the workload lane.
Side finding: A16 core_ctl **isolates** big-cluster cores instead of hotplugging them
(stock hotplugs) and rotates the isolated pair every 100-300ms — not the starvation
mechanism (falsified), but untuned churn parked under item (4).

### Screen-off churn quantified (2026-07-16 evening) — the adb-tax discovery
| regime (screen off, unplugged, Wi-Fi assoc.) | suspends/min | drain |
|---|---|---|
| host adb server holds a registered TCP conn (zero commands sent) | 46-47 | ~350mW |
| host fully `adb disconnect`ed | **6.0** | **~130mW** |

Every wake in the churn regime is `IRQ 71 wcnss_wlan` at ~550ms cadence — **unicast
traffic from the host's adb TCP session itself**, not filterable by mcast/bcast filters
(hand-arming quiet mode changed nothing, as expected). **⭐ The big bench rule: a merely
registered TCP adb session multiplies standby wake rate ~8× and drain ~3×** — every prior
"silent" screen-off cell in this campaign carried this tax. USB adb has an analogous
effect via keeping the SoC from deep suspend. `adb disconnect` before any standby window.
The ~130mW no-adb number matched the old Wi-Fi-off residual, confirming the wcnss fix is
working at the wake-source level — what remained was reconnect-tail contamination and the
bug-#3 residual class, resolved by the fully-cable-out bracket below.
**Lever documented, deliberately not staged:** SystemSuspend short-suspend backoff
(`suspend.*` sysprops) — off by default upstream; not obviously needed once adb tax is
removed, revisit only if the overnight bracket shows a high short-suspend share.

---

## CT-3 wall-truth validation (2026-07-15/16)

**Why:** coulomb-counter is per-unit-gauge-biased; cross-unit idle comparisons above
mixed real regression with calibration noise. **Method:** AVHzY CT-3 inline USB power
meter (`/home/kyle/.bin/AVHzY.py`, `/dev/ttyACM0` — renumbers on replug, verify with a
3-sample read first). Charge to `status: 5` (Full, not just level 100%) before trusting
readings — below Full the charger is still delivering real current. Caveat: phone stays
on USB/CT-3 throughout, so screen-off numbers here are NOT deep-Doze (not directly
comparable to the unplugged coulomb-counter numbers) — only same-methodology comparisons
are apples-to-apples. **Gotcha:** brightness settings take 10-20s to visually settle in
the CT-3 log; always eyeball the raw sequence and average only the settled tail.

**Stock-vs-stock cross-unit check** (both stock 8.1) — confirms the CT-3 method and low
unit-to-unit variance (~1-5%):

| State | Witness | Gold (stock) | Delta |
|---|---|---|---|
| Screen-off | 301mW | 304mW | ~1% |
| Brightness 128 | 862-886mW | 871mW | ~1-2% |
| Brightness 255 | 854mW | 900mW | ~5% |

**Same-unit (Gold) stock vs A16 fixed build:**

| State | Stock 8.1 | A16 (fixed build) | Delta |
|---|---|---|---|
| Screen-off | 304mW | 410mW | +35% |
| Brightness 128 | 871mW | 931mW | +7% (was +13-27% pre-fix) |
| Brightness 255 | 900mW | 1273mW | +41%, ~373mW abs |

Brightness-255 delta is now explained by the linear-vs-saturating curve finding above
(A16 is genuinely brighter, not just hungrier). Screen-off +35% gap is explained by the
freeze-cycling/adb-tax findings above (USB-attached ≠ true standby). Both dissolve into
the release-final bracket below rather than remaining open bugs.

**Sustained dark-load numbers (Gold, same session):** 1949mW (2×sha256sum, non-cycling,
settled) vs stock witness 1438mW — this is the number the freeze-cycling investigation
(above) proved invalid as a CPU comparison; real answer is parity. **Forced-idle (deep
Doze, CT-3-wired): 351mW settled** (10-min follow-up: 348mW mean, stdev 11mW, zero wake
spikes) — strong confirmation the wcnss fix eliminated periodic churn even before the
final unplugged bracket.

---

## Release-final numbers campaign (2026-07-23)

Kyle is prepping a real release; asked for the best final apples-to-apples numbers
against stock. Scope: the two remaining gaps from the 07-16 campaign — (1) a true no-adb
standby number (previously only estimated via a short adb-disconnect sample or
USB-attached CT-3 windows) and (2) a wakefulness-pinned CT-3 load bracket (deferred).

**Units:** Silver = `4373dd0f`, freshly reflashed stock 8.1. Gold = `81eed371`, freshly
reflashed to the **A16 release build** (fixes baked in: `hostArpOffload=0` +
`hostNSOffload=0` wcnss fix, BT signing-key fix, cpu0 PSCI guard). Both: SIM out,
airplane off, Wi-Fi on/associated (`yelppub`), screen off, **fully unplugged** (plain USB
adb, not TCP — no way to hedge mid-bracket, host-blind start to end). Gold additionally
had `doze_enabled=0` and battery-saver/lifemode confirmed off.

**Method:** coulomb-counter bracket, realistic window lengths (>1hr), and critically
**fully cable-out for the whole window** — no USB/adb tax at all, applying the 07-16
adb-tax finding for the first time to a real bracket.

**Note on regime:** natural screen-off standby (not forced-Doze `deviceidle
force-idle`) — includes normal Doze maintenance-window cycling, a different (more
real-world) regime than the older forced-Doze citations above. Both units measured
identically, so the comparison is apples-to-apples even though not directly comparable
to the forced-idle rows.

| Unit | Window | Start → end (charge counter, level, voltage) | Avg current | Avg voltage | Avg power |
|---|---|---|---|---|---|
| Silver (stock 8.1) | 07:56:44 → 11:10:11 (3h13m27s) | 655833µAh/86%/4184mV → 535382µAh/62%/3920mV | 37.4mA | 4052mV | **151mW** |
| Gold (A16 release build) | 12:30:56 → 13:51:27 (1h20m31s) | 662042µAh/99%/4401mV → 641919µAh/94%/4180mV | 15.0mA | 4291mV | **64mW** |

**⭐⭐⭐ Result: A16 release build wins natural standby by ~58% (64mW vs 151mW) —
genuinely better than stock, not just at-parity.** Headline number for release notes:
the wcnss quiet-mode fix more than pays for itself once measured without any adb/USB tax
contaminating the window. Satisfies Kyle's acceptance bar outright for this cell.

Caveat: window lengths differ (3h13m vs 1h21m, paced live rather than to a fixed clock) —
both are well past the ~30min coulomb-counter floor, flag as a footnote only.

**Deferred (Kyle is chasing the BHY sensor-wedge bug first,
`[[bhy-hub-wedge-no-recovery]]`):**
- Bracket 2 — sustained CPU load, wakefulness pinned, CT-3 wall-truth on both units —
  would give a real mW number for the dissolved "+36%" finding.
- Brightness-cap release decision (below) — not blocking.

**Decision for Kyle — two clean options on brightness:**
1. **Cap max to stock luminance:** one-line RRO
   `config_screenBrightnessSettingMaximumFloat ≈ 0.72` (mithorium-common overlay layer;
   verify exact knob when staging). Max-slider power drops ~235mW. Battery parity, loses
   headroom.
2. **Keep the brighter max as a feature**, release-note it. Satisfies the acceptance bar
   at matched luminance and is user-visibly better outdoors; loses literal parity at max
   slider.
