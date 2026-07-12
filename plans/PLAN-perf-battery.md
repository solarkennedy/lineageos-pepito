# PLAN-perf-battery: Low-Level Performance & Battery Optimization

**Status (2026-07-10):** New lane, not yet started. Opened once telephony/VoLTE landed and
before release productization — this is the "make the tiny phone snappy and long-lived"
pass, not a bring-up blocker. Nothing here is on the critical path in `PLAN.md`.

**Scope:** kernel-level CPU/GPU/IO scheduling, thermal, charging, and wakelock hygiene —
not app-level battery (Doze/App Standby are stock AOSP and out of scope here).

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
