# PLAN-perf-battery: Low-Level Performance & Battery Optimization

**Status (2026-07-10):** New lane, not yet started. Opened once telephony/VoLTE landed and
before release productization — this is the "make the tiny phone snappy and long-lived"
pass, not a bring-up blocker. Nothing here is on the critical path in `PLAN.md`.

**Scope:** kernel-level CPU/GPU/IO scheduling, thermal, charging, and wakelock hygiene —
not app-level battery (Doze/App Standby are stock AOSP and out of scope here).

> **Battery Health *data*** (state-of-health %, cycle count, design capacity for the Android 16
> Battery Health screen) is a separate lane — see [`PLAN-battery-health.md`](PLAN-battery-health.md).
> That's about *reporting* numbers the health HAL currently returns null; this file is about
> *reducing* drain. Charge-limit control (LineageOS `IChargingControl`) already works and needs nothing.

---

## Baseline survey (2026-07-10)

Grounded in the actual tree, not general Android advice. Sources: `mi8937_defconfig`,
`device/xiaomi/mithorium-common/rootdir/bin/init.qcom.post_boot.sh`,
`kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito/battery_usb.dtsi`,
`mithorium.mk`.

- **CPU governor:** defconfig default-gov is `performance` (`mi8937_defconfig:515`), but
  `init.qcom.post_boot.sh`'s `8937_sched_dcvs_eas()` (line 154, called for soc_id
  294/295/313) overrides both clusters to `schedutil` at runtime: `hispeed_freq=1094400`
  (perf cluster) / `768000` (power cluster), `hispeed_load=85`, `up/down_rate_limit_us=0`,
  `scaling_min_freq=960000`/`768000`. Input-boost `cpu_boost_freq=1094400`,
  `input_boost_ms=40`. `sched_load_boost=-6` all 8 CPUs. `sched_boost` explicitly disabled.
  This is the stock QTI multi-SoC tune, shared with siblings (ugg/land/santoni/prada) —
  no pepito-specific perf profile exists.
- **CPU hotplug:** `core_ctl` is left enabled for the 8937/8940 branch (the
  `disable_core_ctl()` call only fires in the separate 8917/8920 branch) — dynamic
  hotplug is active, untuned for pepito specifically.
- **Scheduler:** `CONFIG_SCHED_WALT=y`, `CONFIG_SCHED_TUNE=y`, `CONFIG_SCHED_MC=y`,
  `CONFIG_HOTPLUG_CPU=y`, `CONFIG_MSM_PERFORMANCE=y`, `CONFIG_NR_CPUS=8`.
- **I/O scheduler:** `CONFIG_DEFAULT_IOSCHED="cfq"` (`mi8937_defconfig:728-734`) even
  though `MQ_IOSCHED_DEADLINE`, `MQ_IOSCHED_KYBER`, and `IOSCHED_BFQ`+`BFQ_GROUP_IOSCHED`
  are all built. CFQ is legacy/rotational-tuned; BFQ is the modern default for flash
  storage on low-end Android and generally improves perceived UI responsiveness under
  I/O load without a battery cost.
- **zram:** `CONFIG_ZRAM=y`, lz4; sized in `configure_zram_parameters()`
  (`init.qcom.post_boot.sh:814-860`) — 50-75% of RAM (Go-device detection), capped
  4096MB, `swapon -p 32758`. Reasonable as-is.
- **GPU (Adreno 505 / kgsl):** `CONFIG_QCOM_KGSL_IOMMU=y`,
  `DEVFREQ_GOV_QCOM_ADRENO_TZ=y`, `DEVFREQ_GOV_QCOM_GPUBW_MON=y`, `DEVFREQ_THERMAL=y`.
  `init.qcom.post_boot.sh` sets `kgsl-3d0/min_pwrlevel`/`max_pwrlevel` and GPU-BW hwmon
  params in generic SKU blocks (e.g. lines 265-311, 5640-5656, 6063-6071) — **not
  confirmed which branch pepito actually hits**; if none, DTS `qcom,gpu-pwrlevels`
  governs max clock by default. Unverified whether pepito is over- or under-clamped.
- **Thermal:** No `thermal-engine.conf` / msm-thermal userspace config in this tree.
  Handled by source-built Thermal HAL 2.0 at `device/xiaomi/mithorium-common/thermal/`
  (`thermalConfig.cpp` et al.), sensor tables keyed off `/sys/devices/soc0/soc_id`. No
  pepito-specific thermal-zone DTS override exists (uses shared
  `msm8940-pmi8950.dtsi`/base msm8937 DTSI). Charger-side mitigation is in DTS (below).
- **Battery/charging** (`pepito/battery_usb.dtsi:31-56`): `qcom,float-voltage-mv=4400`,
  `thermal-mitigation=<700 600 500 0>` (mA steps), `charging-timeout-mins=1536`,
  `jeita-temp-hard-limit=1`; JEITA cold/cool/warm/hot = 0/10/45/54°C ±1°C hysteresis;
  `fg-iterm-ma=200`, `cutoff-voltage-mv=3350`. No fast-charge (QC/PD current bump) beyond
  stock `qpnp_smbcharger`.
- **Suspend/wakelocks:** `CONFIG_SUSPEND=y`, `CONFIG_PM_WAKELOCKS=y`,
  `CONFIG_PM_WAKELOCKS_LIMIT=0` (unlimited), no `PM_WAKELOCKS_GC`, no `PM_AUTOSLEEP`.
  Nothing caps a rogue wakelock. No live audit done yet — worth checking given how much
  of this stack (qmux/rmnet/ims_enabler/etc.) is freshly bootstrapped bring-up code that
  could plausibly retry against a dead socket and hold the CPU up.
- **PowerHAL:** No source-built PowerHAL. `mithorium.mk:358-359` pulls prebuilt
  `android.hardware.power@1.2.vendor` + `power-service-qti` — stock Qualcomm binary, no
  custom hint/boost logic in this tree.

---

## Options considered

| # | Option | Scope | Risk | Expected payoff |
|---|---|---|---|---|
| 1 | I/O scheduler CFQ → BFQ | `mi8937_defconfig` (global, all Mi8937 siblings) | Low — one-line defconfig flip, BFQ already built | UI responsiveness under I/O load; no expected battery cost |
| 2 | Live wakelock audit on DUT | Diagnostic only, no code change yet | None (read-only) | Find any bring-up-era wakelock leak before it's baked into a release build |
| 3 | GPU pwrlevel clamp check | Diagnostic first; fix would be DTS or pepito-gated | Low to check, unknown until confirmed | Could recover GPU headroom (perf) or clamp waste (battery) — direction unknown until checked |
| 4 | Tune core_ctl/schedutil hispeed params for pepito | Needs pepito-only gating per `PLAN.md` layering rules (not editing shared `init.qcom.post_boot.sh` path directly) | Medium — behavior-tuning, needs on-device A/B feel-testing | Battery vs. responsiveness trade, unclear win without user testing |
| 5 | sched_boost / sched_load_boost re-tune | Shared post_boot.sh | Low to check, likely leave as-is (already battery-leaning) | Low priority |

**Approach:** work top-down by risk. (1) and (2) first since they're cheap/reversible and
don't require new pepito-gating design. (3) next as a read-only check. (4)/(5) only if
(1)-(3) don't already deliver a felt improvement — they need real design work to respect
the "push changes as deep as possible without breaking siblings" rule from `PLAN.md`, and
Kyle does all builds/flashes himself (memory `feedback-user-does-build-flash`), so each
iteration is a real hardware cycle — stage in small increments.

---

## TODOs

- [x] **(1) BFQ default I/O scheduler** — **checked live 2026-07-10, no action needed.**
  `mi8937_defconfig`'s `CONFIG_DEFAULT_IOSCHED="cfq"` turns out to be inert: it only
  governs the legacy non-blk-mq scheduler framework, and the real eMMC queue
  (`/sys/block/mmcblk0/queue/scheduler`) runs blk-mq, which has its own default-elevator
  selection and had already picked `[bfq]` (available list: `mq-deadline kyber [bfq]
  none` — CFQ isn't even offered). Nothing to flip.
- [x] **(2) Wakelock audit** — **checked live 2026-07-10, clean.** `dumpsys power`:
  `mWakeLockSummary=0x0`, `mHoldingWakeLockSuspendBlocker=false`. `/sys/kernel/debug/
  wakeup_sources`: `prevent_suspend_time` is 0 for every source, including all the modem
  IPC endpoints (NAS/UIM show high `active_count` — routine QMI chatter, not a leak).
  No bring-up service is misbehaving.
- [x] **(3) GPU pwrlevel clamp** — **checked live 2026-07-10, not clamped.** Full range
  available: `min_pwrlevel=5`/216MHz to `max_pwrlevel=0`/475MHz (all 6 of the Adreno
  505's levels reachable: 475/450/400/375/300/216MHz), `msm-adreno-tz` governor doing
  normal adaptive DCVS, sitting at 375MHz idle. Not a bug — but see below, this became
  the basis for a new opt-in toggle rather than a fix.
- [ ] (4) core_ctl/schedutil pepito-specific tune — parked pending real A/B feel-testing.
- [ ] (5) sched_boost re-check — parked, likely no action needed.

**New from (3): GPU clock cap toggle — implemented 2026-07-10** (fifth Pepito Tweaks
toggle, commit `329f220`). Since the GPU has its full range available by default, added
an opt-in `persist.gotweak.gpu_clock_cap` that caps `kgsl-3d0/max_pwrlevel` to `3`
(375MHz) instead of the uncapped `0` (475MHz) — a real perf-vs-battery tradeoff, not a
bug fix. Unlike the other four gotweaks this is a **plain sysfs write, not a property**,
so `init.gotweaks.rc` has real triggers in both directions (`=1` → cap, `=0` → restore)
and it applies **live**, no reboot needed either way — the one gotweak that skips the
reboot dialog in `GoTweaksSettings.java`.

Sepolicy gotcha #2, same class as the `gotweak_prop` one: `vendor_init` (the domain that
executes a `write /sys/... ` command embedded directly in an `on property:` trigger
block) has no existing grant to write `sysfs_kgsl`-labeled files. The domain that *does*
have some access (`qti_init_shell`, which runs `init.qcom.post_boot.sh` as a spawned
service) only has `r_file_perms + setattr` — not write — and isn't the domain executing
our trigger anyway. Checked proactively this time rather than rediscovering it on a
flash: added `allow vendor_init sysfs_kgsl:file rw_file_perms;` to `gotweaks.te`,
verified locally with `checkpolicy` (exit 0) before handing off.

**Sixth gotweak: zram compression algorithm — implemented 2026-07-11** (commit
`655f06b`). Checked live state first: `zram0/disksize` is 1.5GiB (~53% of the 2.87GB
total, lands in the survey's expected 50–75% range — nothing wrong with sizing), and
`comp_algorithm` shows `lzo [lz4] zstd` — lz4 active, zstd also compiled in and
available but unused. zstd trades more CPU per page (de)compression for a better ratio
— more effective swap capacity in the same physical disksize — a real, well-known
low-RAM-device tradeoff. `swappiness=100` was already maximally aggressive (explicit in
`init.target.rc`), nothing to add there.

Unlike the sysfs-backed toggles, `comp_algorithm` can't be changed while zram is already
live and acting as swap (would need a full `swapoff`/reset/`mkswap`/`swapon` cycle), so
rather than reinvent that lifecycle, `persist.gotweak.zram_zstd` is read directly inside
`init.qcom.post_boot.sh`'s existing `configure_zram_parameters()` — the function that
already owns zram's one-time-per-boot setup — right before its existing
`ro.config.low_ram`-conditional lz4 write. Reboot-gated, same as low_ram/heap_trim/lmk.

Sepolicy gotcha #3, same class as the first two: `configure_zram_parameters()` runs as
`qti_init_shell` (file_contexts labels the script `qti_init_shell_exec`) — a *third*
distinct domain (neither `system_app` nor `vendor_init`), needing its own `get_prop`
grant on `gotweak_prop`. The actual `sysfs_zram` write needed no new grant — this domain
already writes `comp_algorithm` today for the `low_ram` case. Checked for the domain and
added the grant proactively before ever flashing, verified locally with `checkpolicy`
(exit 0).

Detail/findings as each item progresses will be logged here, not in `PLAN.md`.

---

## User-facing settings UI (no root required) — surveyed 2026-07-10

**Goal:** let a normal user adjust some of the above tunables (I/O scheduler pick,
wakelock/GPU toggles, etc.) from Settings, without needing root — the "phh Treble
Settings"-style dedicated section, but native to this tree.

**Option A — LineageOS "Performance Profiles" — DEAD, ruled out.** Historically (CM/old
LineageOS) this was `PerformanceManagerService` + `lineageos.power` hint constants
(`PROFILE_POWER_SAVE`/`BALANCED`/`HIGH_PERFORMANCE`) surfaced in Settings → Battery. A
full tree search (`frameworks/`, `lineage-sdk/`, `packages/apps/LineageParts`,
`packages/apps/Settings`, `device/`, `vendor/lineage`) found **zero references** — no
service class, no hint constants, nothing feature-flagged off. `lineage-sdk`'s live
internal-service list (`lineage-sdk/lineage-sdk/main/java/org/lineageos/platform/internal/`)
has no `power` package at all; the one Lineage-specific battery feature that *does* exist
now is **Charging Control** (`packages/apps/LineageParts/src/org/lineageos/lineageparts/health/`,
backed by `ChargingControlController`/`FastChargeController` in `lineage-sdk`'s `health/`
package). Conclusion: this feature was fully removed upstream, not just hidden — nothing
to hook into.

**Option A' — LineageOS "LineageHardwareManager" capability bridge — also ruled out.**
This is the mechanism Charging Control/LiveDisplay actually use: a per-device vendor HAL
(`vendor.lineage.hardware`) exposing a fixed capability enum, called by apps via
`LineageHardwareManager` without root. Checked whether Mi8937/pepito already implements
this HAL (`grep -ri "lineagehw\|vendor.lineage.hardware\|LineageHardwareInterface"` across
`device/xiaomi/Mi8937` and `device/xiaomi/mithorium-common`) — **no hits, not implemented
for this device at all.** Even if it were, the capability enum is fixed in shared
`lineage-sdk` framework code (things like high-touch-sensitivity, key-disabler, etc.) —
adding arbitrary new tunables (I/O scheduler, GPU clamp) would mean patching shared
Lineage SDK framework, out of scope for a pepito-only feature and not something upstream
would take. Building this HAL fresh for pepito would be exactly as much work as a bespoke
HAL (option B2 below), with no reuse payoff.

**Conclusion: no existing Lineage plumbing to reuse. A dedicated pepito settings surface
needs its own privilege bridge, built from scratch. Two viable shapes:**

| | B1 — property + init.rc trigger (phh-style) | B2 — small AIDL vendor HAL |
|---|---|---|
| How it works | App writes a `persist.vendor.pepito.perf.*` prop; `init.rc` `on property:` stanza does the actual sysfs write | App binds a root-running AIDL service with typed setters/getters that does the sysfs write |
| New code | Minimal — one prop + one `on property:` block per toggle | A real HAL service (init .rc, .xml manifest, sepolicy domain, AIDL interface, C++/Rust impl) |
| Sepolicy | One new type for the init trigger's sysfs access | New HAL domain + client permission, more surface |
| Feedback to app | None (fire-and-forget; app can't easily read back live state or confirm success) | Synchronous read-back / status possible |
| Fit for this project | Good — toggle list is experimental/evolving, each one is independently addable/removable | Better long-term if the toggle list stabilizes and needs reliable status |
| Ties to `PLAN-release.md` | New sepolicy type needed either way — bundle into the Enforcing SELinux pass already tracked there | Same |

**Recommendation: start with B1.** Smallest new moving-part count, no HAL to write or
maintain, and fits an experimental/growing tunable list well. Revisit B2 only if the
toggle set stabilizes and the app needs live read-back rather than fire-and-forget.

### TODOs (settings UI)

- [ ] Decide final toggle list to expose (candidates: I/O scheduler picker
  CFQ/BFQ/Kyber, GPU max-pwrlevel clamp on/off, `input_boost_ms`/`hispeed_load` presets,
  wakelock diagnostics display) — informed by findings from items (1)-(4) above.
- [ ] New sepolicy type for the init trigger's sysfs write access — coordinate with the
  Enforcing SELinux pass in `PLAN-release.md` rather than doing it twice.
- [ ] Build the settings surface itself: new LineageParts preference screen (reuses
  existing Settings app, signing, install) vs. a fully standalone app (isolated, but
  duplicates LineageParts plumbing) — leaning LineageParts screen, not yet decided.

---

## Android Go-style memory tweaks — enumerated + staged (2026-07-10)

Prior context: a full Android Go product-config inheritance (`go_defaults_common.mk` +
`common_full_go_phone.mk`) was tried on this device and reverted 2026-07-08 (memory
`appwidget-service-missing-go-edition`) — it silently dropped `android.software.app_widgets`
via a hardware-feature-manifest swap, NPE-crashing the Twelve music app. Device is ~2.87GB
RAM (confirmed via `/proc/meminfo` on the DUT) — not Go-tier by Google's own threshold, but
low enough that individual memory tunables are still worth it. Decision: never re-adopt
the Go hardware-feature manifest; expose only the individually-safe tunables as real
Settings toggles instead of an all-or-nothing product-config inherit.

**Enumerated from the actual makefiles** (`build/make/target/product/go_defaults_common.mk`,
`build/make/target/board/go_defaults_common.prop`, `vendor/lineage/config/common_full_go_phone.mk`):

- **Category 1 — build-time only, not real toggles — baked in 2026-07-11**
  (`device/xiaomi/Mi8937` commit `10c561c3`). `PRODUCT_SYSTEM_SERVER_COMPILER_FILTER=speed-profile`,
  `PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD=false`, `PRODUCT_MINIMIZE_JAVA_DEBUG_INFO=true`,
  `MALLOC_LOW_MEMORY=true` (non-eng builds only, matching upstream's own guard) — all four
  added to `lineage_Mi8937.mk`, gated on `TARGET_DEVICE_PEPITO` (matching the file's existing
  convention). One-time build decisions, no runtime knob, so no Pepito Tweaks entry for these.
- **Category 2 — runtime props, staged as live toggles (this section).**
- **Category 3 — the `go_handheld_core_hardware.xml` swap — explicitly SKIPPED.** Diffed it
  against the normal manifest: it drops `app_widgets`/`controls`/`credentials`
  unconditionally, plus `voice_recognizers`/`picture_in_picture`/`activities_on_secondary_displays`
  which are already tagged `notLowRam="true"` in the manifest pepito uses today — meaning
  those three disappear automatically the instant `ro.config.low_ram=true` is set, with
  or without the manifest swap. Never adopting the Go manifest means `app_widgets` stays
  present unconditionally regardless of any Category-2 toggle — the 2026-07-08 crash class
  cannot recur under this design.

### Category 2 — implemented 2026-07-10

Four `persist.gotweak.*` boolean toggles, default off, staged as an `init.rc`
property-trigger bridge (the B1 design above) rather than pepito-gated — the tunables are
generic to any low-RAM Mi8937/mithorium sibling, default-off makes it inert everywhere
else, so it lives at the `mithorium-common` layer per the `PLAN.md` layering rule.

| Property | Sets | Current pepito value | Go value | Apply |
|---|---|---|---|---|
| `persist.gotweak.low_ram` | `ro.config.low_ram` | unset (false) | `true` | reboot (`ro.*`); **discloses loss of PiP/voice_recognizers/secondary-displays feature flags** |
| `persist.gotweak.heap_trim` | `dalvik.vm.heapgrowthlimit`, `dalvik.vm.heapsize` | `192m`/`512m` | `128m`/`256m` | reboot (zygote reads once at its own start) |
| `persist.gotweak.lmk` | `ro.lmk.critical_upgrade`, `upgrade_pressure`, `downgrade_pressure`, `kill_heaviest_task` | unset (lmkd defaults) | `true`/`40`/`60`/`false` | reboot (`ro.*`, lmkd reads once at its own start — a bare `ctl.restart lmkd` cannot pick up a changed value once the `ro.*` is locked for that boot) |
| `persist.gotweak.dexopt` | `pm.dexopt.downgrade_after_inactive_days`, `pm.dexopt.shared` | unset / `speed` | `10` / `quicken` | asymmetric: turning on applies live (not `ro.*`); turning off has no revert trigger, so the old values stick until a reboot. UI shows the same reboot prompt as the other three for consistency, rather than exposing that asymmetry. |

**Files staged (`mithorium-common`, on the pre-existing `pepito-rmnet` branch — already
tracked, not committed here since that branch also carries a large pile of unrelated
in-flight work; Kyle will commit in his own logical chunks):**
- `rootdir/etc/init.gotweaks.rc` — the four `on property:` trigger blocks.
- `rootdir/Android.bp` — new `prebuilt_etc` module `init.gotweaks.rc`.
- `mithorium.mk` — added to `PRODUCT_PACKAGES`.
- `rootdir/etc/init.qcom.rc` — added `import /vendor/etc/init/hw/init.gotweaks.rc`.
- `sepolicy/vendor/property.te` — `system_public_prop(gotweak_prop)`.
- `sepolicy/vendor/property_contexts` — `persist.gotweak.` → `gotweak_prop`.
- `sepolicy/vendor/gotweaks.te` — `get_prop`/`set_prop(system_app, gotweak_prop)`.

**⭐ Sepolicy gotcha hit and fixed during staging:** first attempt declared
`vendor_gotweak_prop` via `vendor_public_prop()` in vendor-side sepolicy, since LineageParts
needs to *write* it. `checkpolicy` (hand-expanded-conf method, per `PLAN.md`'s sepolicy
verification section) caught a global Treble neverallow
(`system/sepolicy/private/property.te:488`, `compatible_property_only` block) that forbids
**any** `coredomain` (which includes every app, `system_app` included) from setting **any
vendor-owned property**, public or internal — this is the system/vendor partition
independence guarantee, not something specific to the internal/public macro choice. Fix:
made the property **system-owned** instead (`system_public_prop(gotweak_prop)`,
`persist.gotweak.*` with no `vendor.` infix) — the vendor-side `init.gotweaks.rc` trigger
reads a system property just fine; only the *write* side needed to move. Re-verified with
`checkpolicy -M -c 30 -o /dev/null` against the hand-patched conf: exit 0. General lesson:
whenever an app needs to *set* (not just read) a property that a vendor init trigger acts
on, the property must be system-owned — vendor-owned properties are write-only-from-vendor
by a global neverallow, regardless of which vendor property macro is used.

**LineageParts UI — done 2026-07-10** (`pepito-lineageparts` branch, commit `0e5cce1`):
new Settings > Memory tweaks screen (`perf/GoTweaksSettings.java` + `go_tweaks_settings.xml`,
wired into `parts_catalog.xml`). Four plain `SwitchPreferenceCompat`s read/write the
properties directly via `SystemProperties.get/set` (precedented in stock
`packages/apps/Settings`'s Developer Options controllers; `@UnsupportedAppUsage`, not
`@SystemApi`, but platform-signed system apps are exempted from hidden-API enforcement).
Every toggle shows a shared "Restart required" `AlertDialog` (Restart now → `PowerManager
.reboot(null)`, requires the newly-added `android.permission.REBOOT` — signature
permission, auto-granted to this platform-signed app) — uniform across all four rather
than only the three that strictly need it, to avoid the `dexopt` toggle's asymmetric
live-apply/reboot-to-revert behavior looking like a bug.

**First validation flash (2026-07-10): caught two real bugs, both fixed and re-verified.**

1. **sepolicy — `vendor_init` couldn't read `gotweak_prop`.** This build turned out to
   already be running Enforcing (the `selinux-enforcing-prep.md` flip had landed), which
   caught it immediately: `ParseTriggers() failed: unexported property trigger found` for
   all four `on property:` triggers in `init.gotweaks.rc` — none of them had registered at
   boot, so the toggles were fully inert. `get_prop(system_app, gotweak_prop)` covered the
   app side but not the vendor-init side that has to evaluate the trigger condition in the
   first place — declaring a property `system_public_prop` does not imply this. Fixed with
   `get_prop(vendor_init, gotweak_prop)` in `gotweaks.te`; re-verified locally with
   `checkpolicy`, then confirmed clean on a second flash (`dmesg | grep gotweak` — trigger
   parsed, no `avc: denied`).
2. **Navigation — the screen was unreachable from Settings.** `parts_catalog.xml` only
   drives in-app search indexing; a LineageParts fragment needs its own `activity-alias`
   with an `IA_SETTINGS` intent-filter + `com.android.settings.category` meta-data to
   actually appear inside stock Settings' navigation. Missed this initially (worked from
   the catalog entry alone, which is necessary but not sufficient). Added the alias,
   injecting into `com.android.settings.category.ia.system` (Settings > System) — commit
   `e3a290b`. Renamed the visible label to "Pepito Tweaks" per Kyle. Note for future
   LineageParts additions: **both** a `parts_catalog.xml` entry (search) **and** an
   `activity-alias` (navigation) are required for a screen to be user-reachable at all.

**Scope expanded 2026-07-10 per Kyle: "Pepito Tweaks" is now a general pepito-specific
settings section, not just low-RAM tuning.** First addition: the QS horizontal volume
slider toggle (`qs_show_volume_slider`, `PLAN-pvg100isms.md`/memory `qs-volume-slider`) —
duplicated here (commit `4dd436c`) alongside its existing home under Settings > System >
Status bar, by explicit choice (both entry points kept, not moved). No new Java/bridge code
needed: it's a `lineageos.preference.LineageSecureSettingSwitchPreference`, which
self-binds to `LineageSettings.Secure` given just the XML `android:key` — same mechanism,
different category, in `go_tweaks_settings.xml`. Its pepito-default-on behavior is
unrelated to this section (already handled by the `xiaomi_pepito_overlay_lineagesettings`
RRO's `def_qs_show_volume_slider=true`, predates this work).

Checked and confirmed a true top-level "Settings > Pepito Tweaks" tile (sibling to
Network/Battery/Display/System) is not achievable without directly editing AOSP's
hardcoded `packages/apps/Settings/res/xml/top_level_settings.xml` — no third-party
injection point exists for new top-level tiles, only for sub-items within an existing one.
Decided to stay nested under Settings > System rather than take on that AOSP-edit /
repo-sync-conflict risk.

**Not yet done:** on-device validation of the actual toggle behavior — confirm the
Pepito Tweaks screen appears under Settings > System, each toggle persists across a
restart prompt, `getprop` shows the expected `ro.config.low_ram`/`dalvik.vm.*`/
`ro.lmk.*`/`pm.dexopt.*` values after reboot, and (for `low_ram`) confirm
`pm list features` drops `picture_in_picture`/`voice_recognizers`/
`activities_on_secondary_displays` as expected while `app_widgets` stays present.

---

## CPU cluster auto-disable under Battery Saver — implemented 2026-07-11

Root-only lever a normal user can't get to even with stock Android's Battery Saver
(which works through app-visible restrictions - background limits, sync throttling,
refresh rate - never raw CPU hotplugging). Confirmed live topology first:
`cpu0-3` cap at 1.4GHz, `cpu4-7` at ~1.1GHz (`scaling_max_freq`), all 8 online by
default; verified `cpu0` specifically can be hotplugged off and back on this kernel
(some ARM kernels reserve the boot CPU and refuse).

**Not a Pepito Tweaks toggle** - this one follows the *existing* stock Battery Saver
switch/tile automatically, rather than adding a second redundant switch. Given the
realistic user base ("just me and a few other people"), the design goal was memory
efficiency over building a from-scratch mechanism: `device/xiaomi/mithorium-common`'s
`XiaomiParts` (`org.lineageos.settings`) is already `android:persistent="true"` in this
tree (used for Doze/Dirac), so `GotweaksBatterySaverReceiver` piggybacks on that
already-persistent process rather than standing up a second one. It registers
dynamically for `PowerManager.ACTION_POWER_SAVE_MODE_CHANGED` from
`BootCompletedReceiver` (that broadcast is "only sent to registered receivers" per its
own javadoc — a manifest `<receiver>` can't catch it) and mirrors `isPowerSaveMode()`
into `persist.gotweak.cpu_cluster_saver`; `init.gotweaks.rc`'s `on property:` triggers
do the actual `write`s to `cpu{0,1,2,3}/online` — live, no reboot, either direction.

Sepolicy gotcha #4, same class as the prior three: `vendor_init` has base-policy
*read* on `sysfs_devices_system_cpu` (a blanket `r_dir_file(domain, ...)` grant in
`system/sepolicy/private/domain.te`) but no write grant — the only existing write
grants belong to `qti_init_shell` and an unrelated per-script domain
(`vendor_init-qti-dcvs-sh`), neither of which runs our trigger. Added
`allow vendor_init sysfs_devices_system_cpu:file rw_file_perms;`, verified with
`checkpolicy` before flashing.

No new sepolicy needed for the property write itself: `XiaomiParts` shares
`android:sharedUserId="android.uid.system"` + platform signing with LineageParts, so
it resolves to the same `system_app` domain and inherits the existing
`set_prop(system_app, gotweak_prop)` grant automatically.

**Kill switch added 2026-07-11** (`persist.gotweak.battery_saver_hook`, default
on) — a seventh Pepito Tweaks toggle (`org.lineageos.lineageparts` commit `879d2ac`,
`GotweaksBatterySaverReceiver` commit `1e970d6`), since this whole mechanism is new and
unvalidated on real hardware. `GotweaksBatterySaverReceiver.apply()` ANDs it into the
`isPowerSaveMode()` check; no new sepolicy needed (already covered by the
`persist.gotweak.` property_contexts prefix). Flipping it in Settings also directly
recomputes `cpu_cluster_saver` against the *current* battery-saver state (rather than
just writing the hook-enabled prop and waiting for the next Battery Saver change), so
disabling it restores all 8 cores immediately.

**Extended to the GPU clock cap too — 2026-07-11** (`org.lineageos.lineageparts`
commit `0a8b5eb`, mithorium-common commit `10e2e0c`; retitled the toggle "Our own
Extreme Battery Saver," since that's genuinely what it is now — a real equivalent to
Pixel's exclusive feature, built from root access this device actually has).
`GotweaksBatterySaverReceiver` now sets a second property,
`persist.gotweak.battery_saver_gpu_cap`, alongside `cpu_cluster_saver`. This one needed
real care: `gpu_clock_cap` already has an independent *manual* Pepito Tweaks toggle
writing the same `kgsl-3d0/max_pwrlevel` sysfs node — naively reusing that property
from the auto-hook would mean turning Battery Saver off could silently clobber a
standing manual "always capped" preference. Fixed by OR-composing the two properties
at the `init.gotweaks.rc` layer (a pattern already used elsewhere in this tree, e.g.
`init.xiaomi.rc`'s multi-condition `on property:` triggers): each has its own
"turn on" trigger, but the "turn off" trigger only fires when *both* are 0. `battery_
saver_hook` gates both levers together; no separate kill switch per lever.

**Not yet validated on-device** — check after flashing: `ps -A | grep settings`
confirms `org.lineageos.settings` is alive and stays alive; toggling Battery Saver
(Quick Settings tile) flips `persist.gotweak.cpu_cluster_saver` +
`persist.gotweak.battery_saver_gpu_cap`, `cpu{0,1,2,3}/online`, and
`kgsl-3d0/max_pwrlevel` all within a second or two; UI responsiveness with only
`cpu4-7` live; `logcat -s GotweaksBatterySaverReceiver` for the on/off log lines; and
specifically the OR-composition — turn the manual GPU cap toggle on, then toggle
Battery Saver off, and confirm the GPU stays capped (manual preference must survive).

## Battery benchmark campaign — A8-stock vs A16, idle dataset COMPLETE (2026-07-14)

**Method** (`diag-tools/perf-bench/`): coulomb-counter deltas via `dumpsys battery`
(works unrooted), on-device samplers, mW-first (mA inflates as voltage sags).
Acceptance philosophy: same hardware + we own the stack ⇒ any cell where A16
loses to stock is a bug. Phones: A8 witness `4373dd0f`, A16 DUT2 `81eed371`
(hw_serial now in every meta — DUT2 will be flashed stock-8.1 for within-unit
validation of all of this).

| Cell (airplane, mW) | A8 stock | A16 | Verdict |
|---|---|---|---|
| Screen-on idle, brightness 255 (matched max) | 780 | 1208/1277 (n=2, ~1243) | ⭐ **+59% — top idle bug** |
| Screen-on idle, setting 128 | 787/836/843 (~822) | 943/955/879 (~926) | +13% — but A8's 128 ≈ max panel (log mapping, eyeball-confirmed); true gap is the 255 row |
| Battery Saver screen-on idle | 639 (−22%) | 924 (−3%) | stock saver = framework restrictions; our levers idle-neutral |
| Forced-Doze standby, Wi-Fi on | ~10 (overnight <1%/9.6h) | 483/420/525 (~476) | ⭐ **~48× — wcnss churn** |
| Forced-Doze standby, Wi-Fi OFF | — | 142/90 (~116) | residual ~12× vs stock-with-Wi-Fi — bug #3 |
| Standby w/ saver (churn regime) | — | 475 vs 525 (−10%) | parked cores only help while churning |

**Root causes / open bugs (idle):**
1. **+59% screen-on idle @ matched max.** Same physical panel model.
   Backlight-DTS hypothesis FALSIFIED 2026-07-14 (desk): WLED node identical
   to stock across all 13 params (base pmi8950.dtsi already stock-valued;
   our `battery_usb.dtsi` override lands OVP 17800mV + 3 strings exactly on
   stock) and panel bl-min/max 1/4095 both. Next discriminators: screen-on
   idle cell at brightness 0 on both (gap survives ⇒ pipeline/SoC-floor,
   gap collapses ⇒ 4.19 qpnp-wled driver behavior — then compare
   `/sys/class/leds/wled/brightness` at 255 both phones); side-by-side
   eyeball at 255. One real DTS delta found: stock panel has
   `qcom,mdss-dsi-pan-enable-dynamic-fps` (dfps porch mode), ours doesn't —
   weak suspect, keep on list. Then: display pipeline (HWC/GPU composition),
   SoC floor (960MHz min-freq?).
2. **wcnss Wi-Fi suspend churn (~360mW of standby).** `dmesg`: "Resume caused
   by IRQ 71, wcnss_wlan" = 323/324 resumes + `wcnss_wlan_suspend_noirq`
   returns -1 (aborts). Stock sleeps ~10mW WITH Wi-Fi on ⇒ fix = diff
   prima/wcnss suspend offloads (ARP/NS, MC filter, wowlan) against live A8.
   **2026-07-15 desk analysis — host-config FALSIFIED, quiet-mode-arming is
   the prime suspect (increment 1 staged):**
   - ini falsified: our `WCNSS_qcom_cfg.ini` vs stock A8's is identical on
     every power key (`gEnableImps/Bmps=1`, `hostArpOffload=1`,
     `gEnableSuspend=3`, `McastBcastFilter=3`, modulated DTIM 3). Only two
     ours-only keys, both PROVEN unparsed by prima (qcacld-isms; zero refs in
     the driver) — removed as hygiene (`mithorium-common/wifi/`, staged).
   - Mechanism mapped: fw-side suspend filtering is armed ONLY by the Android
     "quiet mode" driver command `SETSUSPENDMODE 1` → `hdd_suspend_wlan()`
     (mcast/bcast filter + ARP offload + modulated-DTIM BMPS re-enter). The
     kernel's own PM suspend path (`wlan_suspend`) never arms it. Chain on
     A16 exists end-to-end in source (ClientModeImpl screen-off →
     WifiNative → supplicant AIDL `sta_iface.cpp` → qcwcn lib_driver_cmd
     private-ioctl fallthrough → prima `hdd_driver_command`), but whether it
     FIRES at runtime is unverified — every prima-side log is VOS INFO-level
     (invisible). The -1 noirq abort = `-EPERM` from
     `__hddDevSuspendNoIrqHdlr` (isWlanSuspended false, or RX mid-suspend) —
     consistent with quiet mode never armed.
   - **Staged for next flash (kernel, 3 pr_info lines):** log SETSUSPENDMODE
     receipt (`wlan_hdd_main.c`) + "quiet mode armed
     (mcastBcastFilter=%d set=%d)" / "disarmed" (`wlan_hdd_early_suspend.c`)
     — every future bench dmesg timestamps arming against IRQ-71 tallies.
   - **Decisive experiment (works on current build, root, no flash):**
     `diag-tools/wlan-suspendmode/` (static musl aarch64, built + ioctl
     smoke-tested against stock prima) hand-sends SETSUSPENDMODE via the
     same private ioctl. Doze bracket baseline → `wlan-suspendmode 1` →
     doze bracket → compare resume counts + mW. Churn collapses ⇒ arming
     gap confirmed (then root-cause framework gating: `ClientModeImpl`
     `mSuspendOptNeedsDisabled` bits, `wifi_suspend_optimizations_enabled`,
     high-perf/multicast locks); churn persists ⇒ fw/filter angle next.
   - Post-flash passive check: watch dmesg for framework-initiated
     "SETSUSPENDMODE 1 received" at screen-off WITHOUT the tool.
   **⭐⭐ 2026-07-15 LIVE RESULT (diagnostic flash) — arming WORKS, the
   FILTER VALUE is the bug:** screen-off → `SETSUSPENDMODE 1` →
   `quiet mode armed (mcastBcastFilter=0 set=1)`; screen-on disarms. The
   framework/supplicant/ioctl chain is fully healthy — "never armed" is
   falsified. The 0 (= FILTER_NONE, ini wants 3) is deterministic masking in
   `hdd_conf_suspend_ind`/`hdd_conf_hostoffload`: ARP offload clears the
   broadcast bit (0x02), **NS offload clears the multicast bit (0x01)** —
   `fhostNSOffload` DEFAULT-ON in our 4.19 CAF prima (`hostNSOffload` unset
   in both inis; `gMCAddrListEnable` default-0, not involved). Net effect:
   fw suspends with NO mcast/bcast filter → every LAN SSDP/mDNS/foreign-ARP
   frame → IRQ 71 host wake (~2-4s cadence on this LAN = the 323/324
   signature). Hypothesis for stock's ~10mW: 3.18-era prima defaulted
   hostNSOffload OFF → multicast bit survives (armed value 1) → mcast dies
   in fw. Stock GPL drop withholds prima (like BHy) — can't source-diff;
   trade-off of NS-offload-off = IPv6 unreachable while suspended
   (= stock behavior; harmless: wlan IPv4 has ARP offload, rmnet unaffected).
   **NEXT (needs rooted adb — dirty flash reset the Rooted-debugging
   toggle):** append `hostNSOffload=0` to /vendor ini live, reboot (prima
   built-in, ini read at startup), verify armed line shows
   `mcastBcastFilter=1`, doze bracket vs 476mW baseline. If confirmed →
   durable fix = `hostNSOffload=0` in `mithorium-common/wifi/` ini
   (stock-matching for all prima siblings; flag in commit message).
   NB: `logcat -b kernel` works as shell — kernel diagnosis no longer
   needs root. Also observed: screen re-woke itself 20s after keyevent-26
   off (existing screen-wake bug, not chased).
   **2026-07-15 pm — fix mechanism CONFIRMED live; power validation
   pending:** `hostNSOffload=0` live-patched into /vendor ini + reboot →
   screen-off arms `mcastBcastFilter=1 set=1` exactly as predicted.
   Durable one-liner STAGED in `mithorium-common/wifi/WCNSS_qcom_cfg.ini`
   (with comment; affects all prima siblings — stock-matching). Doze
   bracket was aborted at 12 min for Kyle's clean flash — **rerun after
   the clean flash** (start-row ritual: unplug, saver off,
   `doze_enabled=0`, `persist.lifemode.enabled=0`, verify armed line
   shows filter=1, then force-idle 45 min; compare vs 420–483mW and
   IRQ-71 resume share). Post-clean-flash re-setup: Rooted debugging
   toggle, TCP adb, and note DUT ini reverts if the flashed image predates
   the staged fix (re-apply live). Unrelated find: 07-15 dirty flash lost
   the gapps set (image-side priv-apps gone → Play Store SecurityException
   crash-loop from orphaned /data copy) — clean flash + gapps zip resolves.
   **⭐⭐ 2026-07-16 — `hostNSOffload=0` SHIPPED IN A REAL BUILD, AND THE
   HYPOTHESIS IS FALSIFIED: armed value is fixed, the churn is NOT.**
   Observed incidentally while chasing the bhy wedge (`PLAN-sensors.md`) on
   Gold (`81eed371`, our A16 `_gapps`, build 20:31): screen-off →
   `SETSUSPENDMODE 1` → `quiet mode armed (mcastBcastFilter=1 set=1)`. So the
   staged ini fix works end-to-end exactly as designed — value went 0 → 1,
   the NS-offload mask no longer eats the multicast bit. **But the churn
   survived it: 42 × `Resume caused by IRQ 71, wcnss_wlan` in 51 s
   (21:40:21→21:41:12) ≈ 1.2 s cadence — no better than the 2–4 s cadence
   the fix was meant to cure.** This kills the 07-15 hypothesis that
   armed=1 ≈ stock's ~10 mW: filtering multicast alone is not sufficient.
   **Why, in hindsight:** 1 = FILTER_ALL_MULTICAST. The **broadcast** bit
   (0x02) is still cleared by **ARP** offload (`hdd_conf_hostoffload`), which
   the 07-15 analysis already identified but treated as benign. Foreign ARP /
   broadcast frames alone are evidently enough to sustain the churn — and this
   LAN is broadcast-heavy. The ini wants **3** (mcast+bcast) and we are still
   only getting 1.
   **NEXT:** try `hostArpOffload=0` alongside `hostNSOffload=0` → expect
   `mcastBcastFilter=3 set=1` → churn should collapse if the mechanism is
   right. Trade-off to weigh before shipping: ARP offload off means the fw no
   longer answers ARP while suspended, so the host wakes for ARP directed at
   it (may partially reintroduce wakes; also affects reachability-on-LAN).
   Measure the resume tally + doze bracket for filter=1 vs filter=3 before
   choosing. **mW bracket for even the filter=1 state is STILL not run** —
   both are unmeasured; the falsification above is resume-count-only.
   ⚠️ This churn is not merely a battery bug: it is the trigger for the bhy
   hub wedge that kills all sensors until reboot (`PLAN-sensors.md`, bhy dies
   376 ms after the full wake ending a ~51 s churn burst). Fixing it has a
   second payoff — and while it is unfixed, **any Wi-Fi-connected idle device
   is exposed to the sensor wedge**.
   **✅ 2026-07-17 — `hostArpOffload=0` VALIDATED: filter=3 arms and wifi-caused
   AP resumes go to ZERO.** Staged in the tree (`mithorium-common/wifi/
   WCNSS_qcom_cfg.ini`, `hostArpOffload=1`→`0`, with `hostNSOffload=0`). Live-
   verified on DUT1 (`c39a6acf`, kernel #7 Jul-17): patched both ini copies
   (see the /data-copy trap below), rebooted → screen-off logs
   `quiet mode armed (mcastBcastFilter=3 set=1)` (was 1). **Wifi-isolated result:
   `Resume caused by IRQ 71, wcnss_wlan` = 0 across ~15 min / 3 screen-off
   adb-disconnected windows**, vs the filter=1 storm (94/boot, 30–70/min bursts).
   Only remaining wake causes: 3× benign "misconfigured IRQ 1 mpm" + 1× RTC
   alarm. Connectivity intact (ping 8.8.8.8 23 ms, 0% loss) — the LAN-
   unreachable-while-asleep trade-off is the accepted, stock-matching cost.
   ⚠️ **`wakeup_count` is a MISLEADING metric here** — it counts every wake
   source (timers/alarms/binder), so the quick filter=1(52.7/min)-vs-
   filter=3(74.7/min) `wakeup_count` bracket looked like a *regression*; it was
   pure fresh-boot non-wifi noise on the filter=3 side. Use the wifi-isolated
   `Resume caused by IRQ 71` count, not `wakeup_count`, for this bug.
   ⚠️ **/data-copy trap:** prima reads `/data/vendor/wifi/WCNSS_qcom_cfg.ini`
   (`vendor.wlan.driver.config`), which the wifi HAL creates **create-if-missing**
   from `/vendor` — it is NOT refreshed each boot (observed stale-dated older
   than the boot). A clean flash (userdata zeroed) regenerates it, so the shipped
   fix applies fine; but a **dirty** flash or a live `/vendor` edit needs the
   `/data` copy patched/deleted too or the change is silently ignored.
   **Still open:** the definitive mW/standby-power delta (filter=1 vs filter=3)
   — the resume-source elimination is proven, but the battery number is the
   deferred overnight unplugged bracket (with `adb disconnect` — a registered
   TCP session alone drives ~46 unicast resumes/min, unfilterable).
3. **~106mW unattributed Wi-Fi-off residual.** Known minor: health-service
   BOOTTIME_ALARM every 60s. Next: per-window resume-reason deltas.
4. **Doze-dream wedge**: ambient DozeService held DOZE_WAKE_LOCK the whole
   window (no AOD hw). Mitigated `settings put secure doze_enabled 0`; root
   cause (pulse path) open; consider default-off for pepito if unfixed.

**Workload teaser (parked lane):** dark 2-thread sha256: A8 320mW vs A16 784
(evening) but next-morning A16 cells 508-626 — between-cell variance exceeds
lever effects; fixed-power-not-fixed-work confound identified. Needs
work-counted load v2 (joules/task) before believing any lever ranking.
CPU-park lever did show −19% same-session. Full table: `results/summarize.sh`.

**Methodology hall of fame (hard-won):** metas record everything incl.
wakefulness + hw_serial; keyguard forces 10s screen timeout (dismiss + verify
or the cell is dark); stock-8.1 airplane via `settings put` half-applies
(cell_on=2 desync — UI toggles only); A8 `wm dismiss-keyguard` is P+ (use
keyevent 82); load-average is D-state-inflated on these kernels (gate on CPU
idle%); RTC wakealarm needs clearing before writing; `pgrep -f`/`pkill -f`
self-match their own wrapper (split the pattern); battery floor lives in
battery-bench.sh itself (BATT_FLOOR to override).

## CT-3 wall-truth validation (2026-07-15/16) — fuel gauge bypassed, fix impact measured

**Why:** the coulomb-counter method (`dumpsys battery`) is per-unit-gauge-biased —
cross-unit comparisons were unreliable (the +59%/+13% idle numbers above mixed real
regression with per-unit gauge calibration noise; see the within-unit stock-flash
validation that preceded this). Kyle has an AVHzY CT-3 USB power meter with logging
(`/home/kyle/.bin/AVHzY.py`, serial protocol at `/dev/ttyACM0` — **device node
renumbers on replug, sometimes to `/dev/ttyUSB0` (wrong — that was a different
serial cable) or back to `/dev/ttyACM0`; always verify with a quick 3-sample read
before trusting a path**). Technique: charge phone to 100% through the CT-3
in-line, wait for `dumpsys battery` `status: 5` (Full, not just `level: 100`) —
below Full the charger is still delivering real charge current and readings are
contaminated. Once Full, the CT-3's live reading ≈ true system power, no gauge
involved. Caveat baked into every number here: phone stays on USB power/CT-3
throughout (screen-off states are NOT deep-Doze — adb/USB keeps it from fully
suspending), so absolute screen-off numbers run a bit high vs a true unplugged
Doze bracket; only same-methodology comparisons (unit-vs-unit, stock-vs-A16) are
apples-to-apples.

**Gotcha discovered:** a brightness `settings put` doesn't apply instantly — the
CT-3's 2s-interval log sometimes shows a clean step-change 10-20s (5-10 samples)
into the window even after a 25-40s pre-wait before starting to sample. Always
eyeball the raw per-sample sequence for a step and average only the settled tail,
never trust a flat window-mean blindly.

**Stock-vs-stock cross-unit check (witness `4373dd0f` vs Gold `81eed371`,
both stock 8.1, same methodology):**

| State | Witness | Gold (stock) | Delta |
|---|---|---|---|
| Screen-off | 301mW | 304mW | ~1% |
| Brightness 128 | 862-886mW | 871mW | ~1-2% |
| Brightness 255 | 854mW | 900mW | ~5% |

Two different physical units converge tightly — confirms unit-to-unit variance on
stock is small, and validates the CT-3 method itself (it's the coulomb-counter/fuel-gauge
that was unreliable cross-unit, not the hardware).

**⭐⭐ Same-unit (Gold `81eed371`) stock vs A16 fixed-build (today's flash, incl.
`hostNSOffload=0` wcnss fix + BT signing-key fix), wall-truth:**

| State | Stock 8.1 | A16 (fixed build) | Delta |
|---|---|---|---|
| Screen-off | 304mW | 410mW | **+35%** |
| Brightness 128 | 871mW | 931mW | **+7%** (was +13-27% pre-fix) |
| Brightness 255 | 900mW | 1273mW | **+41%, ~373mW absolute — still the top open bug** |

**Reading these against the fixes:** brightness-128 parity improved substantially
(the earlier ~800-950mW cross-unit spread collapses to a tight +7%) — plausible
partial credit to the wcnss/other changes reducing background churn during the
screen-on window. **But brightness-255 tells a new story**: stock is nearly FLAT
128→255 (871→900mW, confirming the log-curve/saturation theory), while **A16 shows
a real, distinct jump 931→1273mW** — i.e. A16's backlight-to-power curve is more
linear/aggressive than stock's saturating one. This reframes bug #1 above: it's
not (only) "A16 draws more at the same brightness," it's "A16's 255 setting drives
something harder than stock's 255 does" — panel backlight duty is prime suspect
again (the earlier DTS-identical falsification compared *config*, not *runtime
duty at the top of the curve*; worth re-checking `/sys/class/leds/wled/brightness`
actual value at setting=255 on both, live, next session) — display pipeline /
compositor is the fallback suspect if the duty matches.

Screen-off is still elevated (+35%, ~106mW) even on the fixed build and even
accounting for the USB-attached-not-true-Doze caveat — some background churn
persists post-wcnss-fix; needs a same-methodology (CT-3, Full, USB-attached)
screen-off comparison specifically, not the deep-Doze bracket numbers from
Bug #2 above (different measurement regime, not directly comparable to this row).

**⭐⭐⭐ 2026-07-16 — bug #1 ROOT CAUSE FOUND: missing gamma/log brightness curve, not
hardware/panel.** Live sysfs read on A16 (Gold, rooted) at 4 settings: 20→wled=321,
64→wled=1028, 128→wled=2056, 255→wled=4095. Every point satisfies
`wled = round((setting/255) × 4095)` exactly — **A16's brightness-to-backlight
mapping is perfectly LINEAR across the entire range, zero gamma/log correction.**
This directly explains the CT-3 finding above: human brightness perception (and
every stock Android brightness curve) is logarithmic, so proper implementations
compress the upper slider range — most of the "useful" differentiation happens
low-to-mid, and the top of the slider adds only modest extra light for
disproportionate extra power. Stock's near-flat 871→900mW (128→255) IS the
gamma-corrected behavior working as intended; ours draws the full linear 2× duty
increase because there's no curve to compress it. This reframes the bug from
"hardware/panel/pipeline" (both already falsified) to a **framework brightness-curve
config bug** — likely a missing/misconfigured `display-device-config.xml`
brightness-to-nits/nits-to-backlight curve, or `BrightnessMappingStrategy` default
falling back to linear because the device XML lacks a proper curve table. Fully
software-fixable, no DTS/kernel/panel work needed. **Confirmed 2026-07-16: no brightness curve exists anywhere.** Searched the full
device tree (`device/xiaomi/`, all Mi8937 siblings: santoni/land/ugg/prada) for
`display_device_config`/`brightness curve`/`display-device-config.xml` — zero
hits. Searched on-device (`/vendor/etc`, `/system/etc`, `/odm/etc`, every XML
grepped for "brightness") — zero hits, nothing shipped in the built image either.
This is not pepito-specific; the gap is inherited by the whole shared Mi8937
family (Lineage/Mi-Thorium tree never added one for this SoC generation), so a
fix belongs at the `mithorium-common` layer per the usual layering rule, not
pepito-only. **Fix direction: add a `display-device-config.xml` (or the
brightness-curve section AOSP expects — check current AOSP/Lineage docs for the
exact schema+path, `frameworks/base`'s `DisplayDeviceConfig`/
`BrightnessMappingStrategy` reads it) with a proper gamma-corrected
brightness-to-backlight curve.** Without one, `BrightnessMappingStrategy` falls
back to a naive linear default — exactly matching the measured 1:1
`wled = setting/255 × 4095` behavior. A reasonable starting curve: match or
approximate stock's observed behavior (near-flat power 128→255, i.e. duty should
already be ~85-95% by setting=128) — could reverse-engineer stock's actual duty
curve if unrooted-workaround found, or just start from a standard perceptual
gamma (~2.2-2.4) mapping setting→duty and tune from real CT-3 measurements after
each iteration. This is a config-only fix, buildable+testable without any
kernel/DTS changes — good first target for the bug-fix pass.

**2026-07-16 — sustained dark-load + forced-idle CT-3 numbers (Gold, A16 fixed
build, same session as the brightness-curve finding above):**

- **Sustained dark load (2×`sha256sum /dev/zero`, non-cycling — fixed the
  kill/respawn-every-30s script that was too noisy for instantaneous sampling):
  1949mW, extremely clean (settled range 1942-1969mW, governor ramp-to-max-clock
  visible as a step at ~20s in).** Stock same-methodology number not yet
  captured this session (needs the witness A8 back on the CT-3, or Gold
  reflashed to stock — deferred, noted as a follow-up).
- **Forced-idle (deep Doze, CT-3-wired so no unreachability risk): 351mW
  settled, stdev only 11mW, NO periodic wake spikes across a 160s/80-sample
  window.** Strong positive signal for the wcnss fix — the pre-fix churn
  signature (IRQ-71 resume every 2-4s) would show as dozens of visible spikes
  in a window this long, and there are none. Caveat: not a like-for-like
  comparison against the 476-525mW broken-build numbers above (those used
  unplugged+airplane+long-window coulomb-counter methodology, this is
  USB-attached+CT-3+short-window) — but IS directly comparable to this same
  build's own non-forced-idle screen-off number (410mW, same session, same
  method) → forced-idle correctly saves ~59mW as expected.
- **⭐ Follow-up 10-minute forced-idle window (300 samples, 2s interval) —
  CONFIRMS the short window, no timescale caveat left: 348mW mean, stdev 11mW,
  min 328/max 401mW, ZERO samples above 1.5× the median across the full 10
  minutes.** No periodic wake spikes at any timescale from seconds to minutes
  (rules out both the old IRQ-71-every-2-4s signature and slower Doze
  maintenance-window churn). This is as clean a standby confirmation as the
  CT-3 method can give without a true unplugged multi-hour run — **the wcnss
  `hostNSOffload=0` fix looks solid.**

**⭐⭐ Stock sustained dark-load captured (witness `4373dd0f`, same CT-3
methodology, Full charge): 1438mW settled** (1401-1579mW range; note the
transient here runs the OPPOSITE direction from A16's — starts high ~1830mW for
the first ~20s then drops and settles lower, vs A16's low-then-ramps-up-to-max
pattern; different governor/thermal behavior, not a measurement artifact —
settled tail used in both cases).

## Dark-load wall-truth verdict

| Unit/OS | Sustained dark load (2×sha256sum, screen off, CT-3, Full charge) |
|---|---|
| Witness (stock 8.1, `4373dd0f`) | 1438mW |
| Gold (A16 fixed build, `81eed371`) | 1949mW |
| **Delta** | **+511mW, +36% — real regression, cross-unit but stock-vs-stock cross-unit variance was only ~1-5% elsewhere in this campaign, so unit variance doesn't explain this gap** |

Points back at governor/scheduler tuning (CPU frequency floor, cluster
placement, DVFS aggressiveness under sustained load) as the likely cause —
consistent with the original suspicion from the campaign's parked workload/lever
lane, now confirmed clean and trustworthy with a proper sustained (non-cycling)
load instead of the noisy kill/respawn script. **Good next target for the fix
pass**, alongside the brightness-curve fix above: profile CPU frequency/cluster
residency during this exact sustained-load scenario on both builds (same unit
ideally) to pin the specific governor knob.

## 2026-07-16 (pm) — framework code read + DUT1 profiling: BOTH fix directions corrected

**⭐⭐ Brightness-curve fix direction was WRONG — a DDC/nits gamma table would not
have changed anything.** Read the actual A16 framework code before staging:

- `DisplayDeviceConfig.createBacklightConversionSplines()`
  (`frameworks/base/services/core/java/com/android/server/display/DisplayDeviceConfig.java:2657-2671`)
  builds the brightness-float→backlight spline as a **linear rescale of the
  backlight array itself** — the `screenBrightnessMap` nits table (and the
  `config_screenBrightnessNits`/`config_screenBrightnessBacklight` overlay
  arrays) feed *autobrightness* and nits conversions only. Adding a
  gamma-shaped nits map would NOT reshape manual setting→duty. The proposed
  `display-device-config.xml` fix would have been a no-op flash cycle.
- Where the perceptual curve actually lives on modern Android: **the Settings
  slider UI** (`com/android/internal/display/BrightnessUtils.convertGammaToLinear`)
  maps slider *position* through a gamma curve into the linear brightness
  float. `settings put system screen_brightness N` **bypasses that** (int→float
  linear via `BrightnessSynchronizer`) — so the measured `wled = setting/255 ×
  4095` linearity is *standard modern-AOSP behavior* (a Pixel does the same
  under `settings put`), not a missing-config bug. A real user dragging the
  slider already gets gamma compression: mid-slider = low duty.
- **Consequences for the bench numbers:** the b128 rows compare different
  luminances (A16 at 50% duty vs stock at ~90% per the eyeball note) — not
  apples-to-apples. The genuinely open question is only the **top of the
  range**: at setting 255, A16 drives full 4095 duty; what does *stock* drive
  at 255? Its kernel-side log map may compress the top (max setting ≠ max
  duty).
- **Discriminator (needs Silver `4373dd0f` online, read-only, no root):** set
  brightness 128 and 255 on stock, read `/sys/class/leds/wled/brightness`
  (path may differ on 3.18 — enumerate `/sys/class/leds/` first), plus
  side-by-side eyeball at 255.
  - Stock duty at 255 **< 4095** ⇒ A16's max is objectively brighter+hungrier
    than stock's max ⇒ fix = cap max backlight to match stock luminance — the
    framework knob is a one-line RRO overlay:
    `config_screenBrightnessSettingMaximumFloat` (falls back to int
    `config_screenBrightnessSettingMaximum`, default 255 = 1.0 float). Verify
    which one A16's `DisplayManager` actually honors when staging.
  - Stock duty at 255 **= 4095** ⇒ same duty, +373mW gap ⇒ per-duty
    efficiency bug (qpnp-wled runtime register comparison next — DTS *config*
    matched but 4.19-vs-3.18 driver register programming may not).
  - Worth computing either way once duty is known: display power *per duty
    unit* on both (b128 row hints A16 may draw more per duty — 521mW increment
    at 2056 duty vs stock 567mW at ~3700 — but that hinges on the unverified
    "128≈max" eyeball).

**⭐⭐ Dark-load +36%: A16-side profiling done on DUT1 (`c39a6acf`, USB,
2026-07-16) — governor/placement is CLEAN; new prime suspect is a stock
screen-off freq cap that A16 lacks.**

- Profile under 2×`sha256sum /dev/zero`, screen off: both threads land on the
  perf cluster (CPUs 1,3), policy0 pegged 1401MHz (time_in_state: ~99s of
  ~99s window), **power cluster spends ~92% of the window at its 768MHz min**
  (9082/9917 units) — placement and DVFS are behaving exactly as designed. No
  smoking gun.
  - ⚠️ Sampling gotcha: live `scaling_cur_freq` reads showed policy4 "pegged"
    at 1094MHz every sample — pure observer effect (each sampler wake +
    `dumpsys` binder call ramps the little cluster right when it's read).
    `time_in_state` deltas are the trustworthy signal, not polled cur_freq.
- **Thermal ruled out on A16:** 4 min sustained at 1401MHz → `apc1-cpu*`/
  `cpuss*` sensors reach only 41-43°C, `scaling_max_freq` untouched, no
  step-zone mitigation. And since stock would sit at similar temps, stock's
  1830→1438mW settle at ~20s **cannot be thermal either**.
- **New hypothesis that fits everything:** the bench ritual forces a 10s
  screen timeout — stock's ~20s power settle lines up with *screen-off*, and
  stock Qualcomm perfd classically applies a **screen-off CPU max-freq cap**
  (msm_performance `cpu_max_freq`, typically to ~1.0-1.1GHz). A16
  (prebuilt `power-service-qti`, no perfd profile in tree) demonstrably does
  NOT cap: this whole profile ran screen-off at 1401MHz.
- **Efficiency math says this would explain the entire delta:** A16 increment
  = 1949−410 = 1539mW at 1401MHz delivering 2×135 = 271MB/s (measured this
  session, `dd|sha256sum`) → 5.7mJ/MB. If stock caps at 1094MHz: increment
  1438−304 = 1134mW at a predicted ~212MB/s → 5.4mJ/MB. **Near-parity
  joules-per-work** — i.e. not an efficiency regression at all, just a
  different operating-point policy (A16 races-to-idle at max; stock crawls
  capped). The fixed-power-not-fixed-work confound again, in wall-power form.
- **Discriminator (needs a stock unit online, shell-only):** run the same
  2-thread load on stock, read `scaling_cur_freq` screen-ON vs screen-OFF
  (expect 1401 → cap), and measure `dd|sha256sum` MB/s for the real
  joules/MB comparison.
- **Fix direction if confirmed:** replicate a screen-off max-freq cap on A16.
  Cheap infra already exists: screen-state receiver in the persistent
  XiaomiParts process (same pattern as `GotweaksBatterySaverReceiver`) →
  `persist.gotweak.*` prop → `init.gotweaks.rc` trigger writes
  `scaling_max_freq` — and the `allow vendor_init
  sysfs_devices_system_cpu:file rw_file_perms` sepolicy grant from gotweak #4
  already covers the write. Decide cap value from the stock read. Caveat to
  weigh: race-to-idle at 1401 is *equally efficient* per the math above, so
  this only wins wall-power for genuinely unbounded background loads — but
  matching stock keeps the "equal-or-better every cell" acceptance bar.

## ⭐⭐⭐ 2026-07-16 (later pm) — dark-load "+36% regression" ROOT-CAUSED and
## DISSOLVED: it was suspend freeze-cycling, not the CPU platform. CPU at parity.

Silver (`4373dd0f`, stock 8.1) on USB+CT-3, DUT1 (`c39a6acf`, A16) moved to TCP
adb (10.0.2.157:5555). Long falsification chain, every step live-verified:

1. **Screen-off perfd-cap hypothesis (above): FALSIFIED.** Stock keeps the big
   cluster at 1401MHz under load with the screen off (`mWakefulness=Asleep`,
   `scaling_max_freq` untouched, 60s watch). No stock screen-off cap exists.
2. **Throughput anomaly discovered:** stock toybox `dd|sha256sum` = 166MB/s
   vs A16's 135 (same nominal freq). To kill the toybox-implementation
   variable, built **`diag-tools/perf-bench/cpubench/`** — static-musl
   fixed-work SHA-256 bench (same recipe as wlan-suspendmode; `-t` threads,
   `-d` secs, `-b` buffer bytes), identical binary on both phones. Result:
   stock 48.5MB/s/thread, A16 **16-18** — 2.9×, buffer-size-independent
   (16KB L1-resident same as 1MB ⇒ NOT memory/BIMC).
3. **CPR/voltage hypothesis: FALSIFIED.** `/d/cpr-regulator/apc_corner/debug_info`
   live: corner 6 IS correct for 1401MHz (`qcom,cpr-corner-frequency-map` in
   `msm8937-regulator.dtsi:392`; corner 7 = 1497.6 bin-1 only), current_volt
   1225mV sits 35mV *below* the scaled ceiling (1260) with error ≈ 3 quot —
   the loop stepped down and settled where this silicon wants it. CPR healthy.
4. **Clock-lie hypothesis: FALSIFIED.** `simpleperf stat -e cpu-cycles` during
   the starved run: counter ticks at **1.399GHz** while on-CPU, IPC 1.7 —
   real clock true, code healthy. But total cycles ÷ rate = the task was
   **on-CPU only ~34% of wall time**. Starvation, not slowness.
5. **Starvation mechanisms, traced (ftrace sched_switch/sched_waking on the
   pinned CPU):** task drops to **D state and the CPU idles ~360ms** per
   cycle; the thread that eventually wakes it belongs to **pid 544 =
   `android.system.suspend-service`**. It's the **kernel freezer**: whenever
   the device is asleep (screen off / Dozing), Android autosuspend repeatedly
   runs freeze_processes → (suspend attempt aborts) → thaw, freezing ALL
   userspace ~⅔ of wall time. TCP-adb-over-Wi-Fi keeps pulsing wakeups, so
   the device thaw/refreezes continuously (each abort cycle also churns
   migration/N stopper wakeups every ~6.5ms via suspend-service binder
   traffic). Memory pressure (majflt=0), cgroup quota (not built), autogroup,
   core_ctl isolation (A/B `enable=0`: no change), and thermal (trips
   85-125°C vs 34°C actual, cpufreq cooling cur=0) all individually falsified
   along the way.
6. **Proof:** verified `mWakefulness=Awake` (the earlier "recovered little /
   still-starved big" split was literally the 60s screen timeout re-sleeping
   the device between runs) → **A16 unpinned 2-thread = 48.2MB/s/thread ≡
   stock's 48.5**. Clocks, CPR, scheduler, placement, IPC: all at parity.

**Consequences:**
- **The CT-3 dark-load row (1949 vs 1438mW, "+36%") is INVALID as a
  CPU-efficiency comparison** — the A16 phone was freeze-cycling (~⅓ hashing
  duty + suspend-churn overhead) while stock hashed at full duty awake. The
  cross-unit caveat (Gold vs witness silicon) stacks on top. Rerun both
  same-unit with wakefulness pinned; A16 may well match or win at equal work.
- **⭐ Bench methodology rule (add to every workload cell):** any screen-off
  cell with on-device work on A16 runs inside the freezer-cycling regime
  unless a wakelock is held. Pin wakefulness explicitly: screen-on +
  `svc power stayon true` (only works while plugged!) or hold
  `/sys/power/wake_lock` (root) for screen-off work cells, and record
  `mWakefulness` in the meta at start AND end. This is very likely the
  root of the old "between-cell variance exceeds lever effects" problem
  that parked the workload lane.
- **The screen-off idle +35% row (410 vs 304mW) also mixes regimes** — A16
  suspend-churning vs stock quietly awake — so part of that gap is churn
  cost, not platform draw. The suspend-abort churn loop itself (why no
  backoff? what aborts it while USB-attached?) is now the best candidate
  for **bug #3's ~106mW residual** and worth its own pass with matched
  regimes. Note the irony: pre-`hostNSOffload=0`, wcnss aborted suspend so
  early the freezer barely engaged; the fix makes suspend attempts get
  further, so work-while-asleep now freezes MORE. Not a regression — asleep
  phones aren't supposed to be doing shell work — but it changes bench math.
- Stock big-cluster taskset EINVALs = stock core_ctl HOTPLUGS cores
  (`online=0,2` at idle, offline cpus reject affinity); A16 core_ctl
  ISOLATES instead and additionally **rotates the isolated big pair every
  ~100-300ms** (11000000→01100000→10010000… live-polled). The rotation
  wasn't the starvation mechanism (falsified by A/B), but it EINVALs
  pinned-affinity tools at random and is untuned churn — parked observation
  for the core_ctl item (4).

## ⭐⭐ 2026-07-16 (later pm) — brightness bug #1 ANSWERED: stock's max is only
## ~70-73% duty; A16's max is real 100% — "the +41% @255" is mostly extra light

CT-3 power-vs-setting sweep on Silver (`4373dd0f`, stock 8.1, battery at Full
status:5, adaptive off, screen pinned on; sysfs led duty unreadable as shell on
stock — same-panel power used as the duty proxy, valid since WLED DTS is
stock-identical). Settled-tail means (b20's first ~18s contaminated by post-wake
activity — the raw-sequence-eyeball gotcha again):

| setting | stock mW | incr over 363mW screen-off | A16 (Gold, same method) | A16 incr over 410 |
|---|---|---|---|---|
| 20 | ~730 | ~375 | — | (~+100 predicted) |
| 64 | ~815 | ~460 | — | — |
| 128 | ~960 | ~605 | 931 | 521 |
| 192 | ~970 | ~615 | — | — |
| 255 | ~985 | ~630 | 1273 | 863 |

- Stock's curve is loggy and saturates by ~setting 128 (matches the old
  "A8's 128 ≈ max panel" eyeball); **max display increment ≈ 630mW ≈ 70-73%
  duty** at A16's measured ~0.21-0.25 mW/duty-step scale.
- **A16 at 255 = true 4095 duty = ~1.4× stock's max luminance, +~235mW.**
  At *matched luminance* (A16 setting ≈ 180-190), A16's display increment ≈
  stock's — the mid-range is already at parity or better (A16 931 vs stock
  960 @128, though A16 is dimmer there — linear vs log curve).
- So the remaining true regressions at matched conditions are only the
  **screen-off baseline gap** (410 vs 363 same-method — suspend-churn regime
  question, see above) — not the panel, not the pipeline, not the curve
  per se. The 07-14 "+59% top idle bug" row inherits this dissolution too.
- Side-by-side eyeball at 255 (A16 should be visibly brighter) = cheap
  confirmation, needs both phones in hand.

## ⭐⭐ 2026-07-16 (evening) — screen-off churn quantified: the #1 wake source on
## the bench is the HOST'S adb TCP connection; true standby is ~4× better

Focused session on the screen-off/suspend-churn gap (Kyle's pick). DUT1
unplugged on TCP adb, all counters from `/sys/power/suspend_stats` + coulomb
counter, wake cadence from `logcat -b kernel` "Resume caused by" wall
timestamps.

| regime (screen off, unplugged, Wi-Fi assoc.) | suspends/min | drain |
|---|---|---|
| host adb server holds a registered TCP conn — even with ZERO commands sent | 46-47 | 91-94mA ≈ ~350mW |
| host fully `adb disconnect`ed (582s window, tail incl. reconnect burst) | **6.0** | **33.9mA ≈ ~130mW** |

- Every wake in the churn regime is `IRQ 71 wcnss_wlan` at a metronomic
  ~550ms — **unicast traffic from the host's adb server connection** (adbd
  keeps the TCP session; the adb host server chats on it). Not filterable by
  design — mcast/bcast filters don't apply to unicast-for-us. Hand-arming
  quiet mode (`wlan-suspendmode 1`, delivered OK) changed nothing, as
  expected in hindsight.
- **⭐ BENCH RULE (the big one):** a merely-*registered* TCP adb session
  multiplies standby wake rate ~8× and drain ~3×. Every screen-off cell
  taken with TCP adb connected — including this whole campaign's "silent"
  windows where no commands were sent — carried this tax. `adb disconnect`
  before any standby window; reconnect after. (USB adb on the CT-3 has an
  analogous-but-different footprint: USB keeps the SoC from deep suspend
  entirely — the known caveat.)
- **~130mW no-adb standby ≈ the old Wi-Fi-OFF residual (116-142mW)** → the
  wcnss/`hostNSOffload=0` fix is confirmed doing its job at the wake-source
  level (Wi-Fi-on standby no longer costs more than Wi-Fi-off); what remains
  is the bug #3 residual class (health-service 60s BOOTTIME alarm etc.), plus
  reconnect-tail contamination in this quick number. The definitive cell
  stays the deferred overnight unplugged bracket (with NO adb registered).
- **Quiet-mode framework arming: still unverified this boot.** No
  SETSUSPENDMODE/armed prints in the kernel log all boot — but the 07-15
  21:38 kernel appears to lack the pr_info diagnostic patch (hand-delivered
  SETSUSPENDMODE also printed nothing, though the tree has the patch —
  possibly the tool's ioctl enters via the wext priv handler and bypasses
  the patched `hdd_driver_command` path, so "no print" ≠ "patch absent").
  Framework state (`dumpsys wifi`) says suspend-opts enabled, ungated, no
  locks; the `CMD_SET_SUSPEND_OPT_ENABLED` handler lives in the always-active
  ConnectableState, so the source chain is intact. Re-verify with prints on
  the next flash that carries the diagnostic patch. Lower priority now: with
  adb disconnected the wake cadence is ~6/min regardless.
- **Lever documented for later, deliberately NOT staged:** SystemSuspend's
  short-suspend backoff is OFF by default upstream
  (`kDefaultShortSuspendBackoffEnabled=false`, threshold 0 —
  `system/hardware/interfaces/suspend/1.0/default/main.cpp:64-71`), tunable
  via `suspend.*` sysprops (`short_suspend_backoff_enabled`,
  `short_suspend_threshold_millis`, `backoff_threshold_count`,
  `max_sleep_time_millis`, sysprop names in `SuspendProperties.sysprop`).
  With the adb tax removed the real cadence (~6/min) doesn't obviously
  justify it; revisit only if the overnight bracket shows a high
  short-suspend share (`dumpsys suspend_control_internal` has the counts).
- Freezer context from the afternoon applies here too: each of those suspend
  cycles freezes userspace — at 46/min the phone was spending ~⅔ of wall
  time frozen (the dissolved "CPU regression"), at ~6/min it's a rounding
  error.
- Bench-state note: DUT1 still has quiet mode hand-armed (persists until
  SETSUSPENDMODE 0 or reboot — it's the desired production state anyway);
  `/data/local/tmp` carries cpubench, wlan-suspendmode, suschurn/,
  selfbracket scripts. Battery ~75% after the day's diagnostics.
- ⭐ Tooling gotcha for on-device standby scripts: `sleep` is
  CLOCK_MONOTONIC and does NOT advance across suspend — a script pacing a
  quiet window with sleeps advances at the *awake duty cycle* (a 40s wait
  took >9 wall minutes at ~4% awake). Pace with `date +%s` re-checks on each
  wake + an RTC `wakealarm` backstop (clear before write), or just bracket
  from the host with two visits and reconstruct cadence from kernel-log
  timestamps.

**Decision for Kyle — two clean options:**
1. **Cap max to stock luminance:** one-line RRO
   `config_screenBrightnessSettingMaximumFloat ≈ 0.72` (verify exact knob
   wiring in A16 DisplayDeviceConfig when staging; mithorium-common overlay
   layer). Max-slider power drops ~235mW → b255 ≈ stock's 985 modulo the
   baseline gap. Battery parity, loses the brightness headroom.
2. **Keep the brighter max as a feature** + release-note it ("max brightness
   exceeds stock ~40%; battery at max slider correspondingly higher").
   Optionally also reshape the slider curve for perceptual comfort
   (slider-UI gamma already handles most of it).
   Leaning matters: Kyle's acceptance bar is "equal-or-better than stock in
   power" — option 1 satisfies it literally at every setting; option 2
   satisfies it at matched luminance and is user-visibly better outdoors.
