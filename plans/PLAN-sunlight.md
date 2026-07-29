# PLAN-sunlight — Sunlight readability (SVI / LiveDisplay "Automatic outdoor mode")

**Status (2026-07-28 eve): ✅ FLASH-VALIDATED END-TO-END (flash #2).** Under Enforcing, zero denials: Settings-driven outdoor mode flips the DSPP curve; ALS auto-engage fired on a flashlight test (engage at lux-cross, disengage on removal) through framework→HAL→kernel. Gamma-0.50 curve (Kyle-approved via live sre-probe A/B). Flash #1 exposed the HAL probe race → fixed by pinning `se_path` (§5a). Remaining: real-sunlight acceptance pass + commit sweep (changes staged, uncommitted). Not release-blocking.
**Goal:** restore the stock "crank the gamma in sunlight" behavior — Qualcomm **SVI (Sunlight Visibility Improvement)** — as LineageOS **LiveDisplay → Sunlight Enhancement**, including its ALS-driven "Automatic outdoor mode".

---

## 1. What the feature is

Qualcomm SVI (marketing: Apical **Assertive Display**) reads the ambient light sensor and applies a content-adaptive gamma/tone-curve stretch through display post-processing, keeping the image legible outdoors at a backlight the sun would otherwise wash out. It is NOT extra backlight — it trades shadow/midtone fidelity for perceived contrast.

Modern survival path: LineageOS LiveDisplay exposes it as `ISunlightEnhancement` ("Automatic outdoor mode" in Settings → Display → LiveDisplay). The framework side (lineage-sdk) handles the ALS auto-trigger; the HAL only needs a working on/off backend.

## 2. Stock evidence (two-device methodology — pulled from the A8 backup tree)

Stock PVG100 **shipped SVI**:

- `backup-stock-android-8.1-AML0/vendor.bin.extracted/app/SVIService/SVIService.apk` — vendor SVI control app.
- `backup-stock-android-8.1-AML0/vendor.bin.extracted/bin/mm-pp-dpps` — the post-proc daemon. Strings show the full machinery: `InitLightSensor`, `PostLightSensorValue`, `LuxStartPoint`/`LuxEndPoint`, `IndoorMaxLuxLevel`/`OutdoorMaxLuxLevel`, `kSviSetStrengthCmd`/`kSviGetStrengthRangeCmd`, `config.svi.xml`, `ro.qualcomm.svi`, `ro.qcom.svi.sensortype`, and per-frame histogram-LUT writes to the display fd.
- No `config.svi.xml` found loose in the extracted vendor `etc/` — likely packed inside the APK or generated; locate it before tuning (§5 Phase 1).
- ⚠️ The stock witness is gone from the bench (Silver now runs our A16). Runtime confirmation (`getprop ro.qualcomm.svi`, live daemon state, on/off screenshots outdoors) needs a stock unit if one ever returns; not required to proceed — the blobs are evidence enough.

## 3. Current state on our A16 build — why it's dead today

Three stacked reasons, all confirmed in-tree 2026-07-28:

1. **HAL feature not compiled.** We ship only the sysfs LiveDisplay variant (`mithorium-common/mithorium.mk:300` — the Qualcomm SDM variant SIGSEGVs on 4.19 and was removed). Enabled soong flags: `enable_ab`, `enable_ce` (mithorium.mk), `enable_re` (Mi8937/device.mk:213). **`enable_se` is not set.**
2. **No kernel backend.** The sysfs SE service probes, in order: `SE_PATH`/`SRE_PATH` cflag overrides, else `/sys/class/graphics/fb0/hbm`, `/sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm`, then `/sys/class/graphics/fb0/sre` (`hardware/lineage/interfaces/livedisplay/aidl/sysfs/SunlightEnhancement.cpp:26-56`). Our kernel's `fb0/hbm` node (`mdss_fb.c:1153`) is a **Xiaomi SDM439-only stub** — on pepito it answers "hbm is unsupported" — and `Mi8937/rootdir/etc/init.xiaomi.device.rc:113` deliberately `chmod 0000`s it so the HAL can't false-positive on it. There is no `sre` node anywhere in the tree.
3. **The stock mechanism is a retired blob class.** `mm-pp-dpps` is an A8 vendor blob driving the old mdss histogram-LUT path — exactly Cluster C. Do not try to run it (see §6).

**No free backlight headroom:** our WLED inherits `qcom,fs-curr-ua = <20000>` (`vendor-legacy/qcom/pmi8950.dtsi:495`), identical to the stock DTB (`dts-3.19-pepito/pepito.dts:8504`, `0x4e20` = 20000 µA/string, 3 strings, OVP 17.8 V matching `pepito/battery_usb.dtsi`). Brightness 255 is already stock-max; only overdrive past Palm's spec could add lumens (§4 Option B).

## 4. Design options

**Option A — kernel-side gamma stretch behind an `sre` sysfs node (RECOMMENDED).**
Implement a real `sre` attribute in the display driver that pushes an alternate gamma / tone curve when enabled, then point the LiveDisplay sysfs SE backend at it.
Two candidate write paths, decide empirically in Phase 1:
  - **A1 — MDP post-processing:** program the MDSS PP gamma/enhancement LUT from the kernel (same hardware block mm-pp-dpps drove from userspace). More faithful to stock SVI (panel-independent, per-frame content still untouched — a fixed "outdoor" LUT, not adaptive). Look at `mdss_mdp_pp.c` for an in-kernel entry point we can call with a precomputed LUT.
  - **A2 — panel-side DCS commands:** send an FT8613 gamma-bank / CABC-off / contrast command set over DSI (like the Xiaomi SDM439 HBM code sends backlight-IC commands). Simpler plumbing (we own `dsi-panel-ft8613-720p-video*.dtsi` + the panel driver), but needs FT8613 command values — mine the stock 3.18 GPL kernel (`~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/`) and the decompiled SVIService/dpps config for what Palm actually programmed.
A fixed two-state curve (normal / outdoor) is entirely acceptable — that's all LiveDisplay models anyway.

**Option B — WLED overdrive "HBM" (crude fallback / possible complement).**
Temporarily raise `fs-curr-ua` above the 20 mA stock spec (qpnp-wled supports up to 30 mA/string) behind the same sysfs toggle. Real lumens, but overdrives the panel's rated backlight → lifetime/thermal risk on a 2018 LCD. If pursued at all: cap conservatively (≤25 mA), and only as the SE toggle (user-intentional, ALS-bounded), never as the normal brightness ramp. Verify the WLED sink registers accept live current updates without a re-init glitch.

**Option C — resurrect stock `mm-pp-dpps`/SVIService — REJECTED** (§6).

## 5a. Implementation as staged (2026-07-28) — Option A1, MDP hist-LUT

Decision: **A1** (DSPP PA histogram/enhance LUT — the exact block stock SVI drove). A2 was dropped: the stock DTB defines **zero** panel CABC/gamma command sets, so stock never used panel-side commands; our mdss has the CABC cmd infra but no FT8613 command values exist to feed it.

**Kernel (`kernel/xiaomi/msm8937`, uncommitted):**
- `mdss_mdp_pp.c` (~line 4604): `sre_enhist_lut[256]` — gamma-0.50 value-channel curve, 10-bit, monotonic (128→725 vs identity 512; white preserved). Strength chosen by Kyle live on the DUT 2026-07-28 via sre-probe A/B (0.62 → "stronger" → 0.50 approved) + `mdss_mdp_enhist_sre_config(mfd, enable)` — fills the v1_7 cache structs exactly as `pp_hist_lut_cache_params_v1_7` does (kernel memcpy instead of copy_from_user, mirroring the `mdss_mdp_dither_config(..., copy_from_kernel)` precedent), sets `PP_FLAGS_DIRTY_ENHIST`; applied at next frame commit. Enabling ENHIST auto-sets `PA_DSPP_OP_ENABLE` (pp_v1_7 opmode logic) — self-contained. `mdss_mdp_pp_resume` re-marks ENHIST dirty from `enhist_sts`, so the curve **survives screen off/on**.
- `mdss_mdp.h`: declaration next to `mdss_mdp_hist_lut_config`.
- `mdss_fb.c`: `sre` DEVICE_ATTR_RW (0644) in `mdss_fb_attrs` next to `hbm`; store gates `mfd->index == 0`, accepts any uint (HAL writes "2" = SeMode::SRE), normalizes to 0/1.
- Node is family-generic (any MDP-1.16 sibling), NOT pepito-gated — per Kyle 2026-07-28: gating waived, siblings on our branch may carry it.

**Device (`device/xiaomi/Mi8937/device.mk`):** `enable_se` bool + **`se_path` pinned to `/sys/class/graphics/fb0/sre`** (added after first-flash debugging 2026-07-28 — see below). With `SE_PATH` set the HAL binds our node directly in "HBM mode" and writes `1`/`0`; the kernel store accepts any uint.

**⭐ First-flash finding — the probe race (why `se_path` is mandatory):** flash #1 (without `se_path`) came up with everything registered but every toggle failing `SunlightEnhancementService: Failed to set SunlightEnhancement state`. Root cause: the HAL's default probe checks `fb0/hbm` FIRST; the upstream HAL rc chowns `hbm` to system at `on init`, the HAL probes at `class hal` start, and the `init.xiaomi.device.rc` `chmod 0000` only executes at `on boot` — so the probe passes on the still-0644 system-owned `hbm`, binds the dead SDM439 stub, and the later chmod turns every write into EACCES for the rest of the session. (My earlier claim that the chmod "steers the probe to sre" was WRONG — it loses the race.) Proven live: `stop/start vendor.livedisplay-sysfs` after boot re-probes with hbm at 0000 → falls through to `sre` → direct binder `setEnabled` drove the kernel node perfectly. Note the HAL restart leaves system_server holding a dead proxy (framework toggles go nowhere until reboot) — fine for bench validation via `service call`, not a production path.

**Everything else was already upstream (verified, no changes):**
- HAL rc (`vendor.lineage.livedisplay-service.sysfs.rc`): already `chown system system .../fb0/sre`; service runs system/system.
- sepolicy (`device/lineage/sepolicy/common/`): `genfscon sysfs /devices/virtual/graphics/fb0/sre → sysfs_livedisplay_tuneable` + `hal_lineage_livedisplay_sysfs` rw — Enforcing-ready out of the box.
- Framework: `OutdoorModeController` (lineage-sdk) provides "Automatic outdoor mode"; defaults `config_outdoorAmbientLux=12000`, hysteresis 1500, `config_defaultAutoOutdoorMode=true`. Feature appears in Settings automatically once the HAL registers SunlightEnhancement.
- FCM: the mithorium `framework_compatibility_matrix.xml` livedisplay entry is legacy-HIDL `optional` — irrelevant to the AIDL service (vintf fragment `sysfs-se.xml` ships via the soong select).

**Pre-flash live test tool — `diag-tools/sre-probe/` (BUILT, untested on device):** programs the *same* LUT via the existing `MSMFB_MDP_PP` ioctl on the CURRENT kernel — no reboot/flash needed. Root shell: `./sre-probe on|off`; takes effect next frame (tap the screen). Built on Stellaris16 (netbook lacks the ndk sysroot; `build.sh` paths are the server's). Use this FIRST to judge the curve strength outdoors before committing to a flash cycle; if the strength needs revisiting, regenerate the table in both `sre-probe.c` and `mdss_mdp_pp.c` (they must stay identical).

**Build:** kernel image + vendor (HAL rebuild) — full `build-lineage23.sh` is simplest.

## 5. Phases

**Phase 0/1/2 — ✅ DONE 2026-07-28 (collapsed):** mechanism decided (A1) and implemented per §5a. The feared sibling crash-loop is moot: the `sre` node is generic MDSS-PP and registers on every family kernel, so the SE probe always succeeds. sepolicy/rc/overlay all turned out to be upstream-complete; no `TARGET_DEVICE_PEPITO` gating (waived by Kyle). Leftover (optional, tuning-only):
- [ ] Extract `config.svi.xml` from SVIService.apk for Palm's lux thresholds + strength range — only if our 12000-lux default or gamma-0.62 strength feels wrong in validation.

**Phase 3 — validate: ✅ DONE 2026-07-28 (flash #2):**
- [x] Kernel + HAL build clean; node `-rw-r--r-- system system`, label `sysfs_livedisplay_tuneable`, Enforcing, zero avc denials.
- [x] Direct node write works (dmesg `sre: enabled/disabled`), visual shift confirmed.
- [x] Framework: `display_temperature_mode 3` (forced outdoor) drives the node; boot-time state restore works (`sre: disabled` at boot).
- [x] ALS auto-engage: flashlight on RPR0521 in MODE_DAY → engage/disengage observed in dmesg, mIsOutdoor transitions.
- [ ] Real-sunlight acceptance pass (outdoors, max brightness) — the point of the feature; do on a sunny day.
- [ ] Reboot-with-outdoor-forced persistence spot-check (expected fine — framework restores state at boot).
- Note (upstream behavior, not a bug): OutdoorModeController skips hardware writes while the screen is OFF — switching modes with the screen off leaves the previous curve until the next screen-on transition resyncs.
- [ ] Toggle appears in LiveDisplay settings; on/off visibly changes rendering; survives Enforcing (no new denials).
- [ ] Automatic outdoor mode: cover/flashlight the RPR0521 ALS → auto-engage above threshold, disengage below (hysteresis sane).
- [ ] Outdoor A/B photos for the release notes.
- [ ] No interaction with existing color state: night light, the `libsdm-color.so` transform path (memory `display-color-transform` — ⚠️ never `ctl.restart vendor.hwcomposer-2-1` live), and reading-enhancement mode compose correctly.

## 6. What we are NOT doing

- **Not running stock `mm-pp-dpps`/SVIService (Option C).** A8 blob against 4.19 mdss debugfs/ioctl surfaces + the removed-for-SIGSEGV SDM color stack — the exact ABI-gap class Cluster C retired by source-building. Use the blobs as *documentation* (configs, LUT shapes, lux thresholds), never as runtime.
- **Not reviving the SDM LiveDisplay HAL variant** — removed for cause (SIGSEGV on 4.19, `mithorium.mk:300`).
- **Not overdriving WLED silently in the normal brightness ramp** — any past-spec current stays behind an explicit, ALS-bounded toggle, if Option B happens at all.
- **Not making this adaptive/per-frame** like true Assertive Display — a fixed outdoor curve is the scope.

## 7. Pointers

- HAL backend: `hardware/lineage/interfaces/livedisplay/aidl/sysfs/SunlightEnhancement.cpp` (+ `Android.bp` soong flags `enable_se`, `se_path`, `sre_path`; vintf frag `sysfs-se.xml`).
- Existing flags: `mithorium-common/mithorium.mk:300-306` (sysfs variant, ab+ce), `Mi8937/device.mk:212-213` (re).
- hbm stub + lockdown: `kernel/.../mdss_fb.c:1144-1231`; `Mi8937/rootdir/etc/init.xiaomi.device.rc:113`.
- WLED: ours `pepito/battery_usb.dtsi` `&wled` + `vendor-legacy/qcom/pmi8950.dtsi:463,495`; stock `dts-3.19-pepito/pepito.dts:8485-8508`.
- Stock SVI blobs: `backup-stock-android-8.1-AML0/vendor.bin.extracted/{app/SVIService/,bin/mm-pp-dpps}`.
- Stock kernel source: `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/`.
- Related memories: `display-color-transform`, `sensors-ssc-sns-missing` (RPR0521/ALS path), `feedback-benchmarks-thoroughness`, `feedback-user-does-build-flash`.
