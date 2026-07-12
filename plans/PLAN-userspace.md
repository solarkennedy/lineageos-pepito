# LineageOS 23.2 — Userspace Boot Issues (pepito/PVG100, MSM8940/Snapdragon 435, 4.19 kernel)

Tracking crash-loop root causes and fixes across boots. Update after each flash.

---

## Legend
- ✅ Fixed & confirmed working
- 🔧 Fixed, not yet confirmed in a boot log
- ❌ Known issue, not yet fixed
- ❓ Unknown / needs investigation

---

## Boot Milestones

| Boot | Status | Notes |
|------|--------|-------|
| boot.1–5 | ❌ | First-stage init failures (metadata mount, partition layout) |
| boot.6 | ❌ | Second-stage init starts; gatekeeper/camera/livedisplay crash-looping → Zygote dies |
| boot.7 | ❌ | HAL crashes resolved; SurfaceFlinger now the new crash-loop blocker |
| serial.log.17 (2026-06-23) | ❌ | Regression: boot loop — `vendor.qseecomd` exit 255 → keymaster never registers → keystore2/vold stall (see #8) |
| serial.log.18 (2026-06-23) | ❌ | RPMB fixed; new GPU crash loop — SurfaceFlinger `EGL_BAD_ALLOC` (see #9) |
| (2026-06-23, both fixes) | ✅ | `sys.boot_completed=1` at ~30s; qseecomd/keymaster/keystore2/SF all healthy |

---

## Issues

### 8. `vendor.qseecomd` exit 255 → keymaster/keystore2/vold stall (RPMB node type)
**Status:** ✅ Fixed (kernel `CONFIG_MMC_BLOCK_LEGACY_RPMB`); confirmed `boot_completed=1`.

**Symptom (serial.log.17):** `init: Service 'vendor.qseecomd' ... exited with status 255`
every ~5s; `init: Could not find 'android.hardware.keymaster@3.0::IKeymasterDevice/default'`
(199×); vold spins on `android.security.maintenance`; never reaches `boot_completed`.

**Root cause (from recovery-root `pmsg-ramoops`):** stock QTI qseecomd/`librpmb`
opens the legacy block node `/dev/block/mmcblk0rpmb`, but the 4.19 kernel exposes
RPMB as a **character** device (`/dev/mmcblk0rpmb`, major 500) → `rpmb_init` ENOENT
→ qseecomd refuses to start QSEE listeners → keymaster can't reach the TEE.

**Fix:** kernel `drivers/mmc/core/block.c` + `mi8937_defconfig` — see `PLAN-gatekeeper.md`.

**Part 2 (RPMB I/O, not boot-blocking):** making the RPMB area a block device let
qseecomd *open* it, but actual RPMB I/O still failed — the 4.19 block fop only
handled `MMC_IOC_CMD`/`MMC_IOC_MULTI_CMD`, while stock `librpmb` uses the legacy
`MMC_IOC_RPMB_CMD` → `rpmb_emmc_read ... EINVAL` → keymaster generate `-8` /
gatekeeper enroll `-30`. Fixed by re-adding `mmc_blk_ioctl_rpmb_cmd()` +
`case MMC_IOC_RPMB_CMD` to `block.c` (same `CONFIG_MMC_BLOCK_LEGACY_RPMB`). This is
a keystore/credential fix (not a boot crash); full chain in `PLAN-gatekeeper.md`.

---

### 9. SurfaceFlinger `EGL_BAD_ALLOC` crash loop (GPU CP microcode downgrade)
**Status:** ✅ Fixed (restored newer `a530_pm4/pfp.fw`); confirmed `boot_completed=1` at ~30s.

**Symptom (serial.log.18):** SurfaceFlinger SIGABRT in
`SkiaGLRenderEngine::chooseEglConfig` — `eglInitialize ... EGL_BAD_ALLOC`; kernel:
`kgsl-3d0: CP initialization failed to idle`, `GPU PAGE FAULT`, `open(/dev/kgsl-3d0)
errno 110`.

**Root cause:** `a530_pm4.fw`/`a530_pfp.fw` downgraded to stock Android-8 ucode the
4.19 kgsl driver can't init (newer `out/` ucode `PM4 0x5FF066/PFP 0x5FF114` works;
stock `0x5FF063/0x5FF087` does not). See `PLAN-surfaceflinger.md`.

---

### 1. `/metadata` directory missing in system image
**Status:** ✅ Fixed (boot.6 confirms first-stage init completes)

**Symptom:** `init: Unable to move mount at '/metadata' to '/system/metadata': No such file or directory` → SIGABRT in first-stage init.

**Root cause:** After mounting `/metadata` on the ramdisk and switching root to `/system`, init tries to move the bind mount to `/system/metadata`, which didn't exist in the system image.

**Fix:** Added `BOARD_ROOT_EXTRA_FOLDERS := metadata` to `device/xiaomi/Mi8937/BoardConfig.mk`.

---

### 2. `prng_seeder` blocked on `/dev/hw_random` (Permission denied)
**Status:** ✅ Fixed (boot.7: no prng_seeder hang seen in log)

**Symptom:** `prng_seeder: Hanging forever because setup failed: Unable to open hwrng /dev/hw_random: os error 13 (Permission denied)`.

**Root cause:** Vendor `ueventd.qcom.rc` set `/dev/hw_random 0600 root root`, overriding the system's `0400 prng_seeder prng_seeder` rule. `prng_seeder` runs as uid 1092 (not root) → EACCES.

**Fix:** Changed `device/xiaomi/mithorium-common/rootdir/etc/ueventd.qcom.rc`:
```
/dev/hw_random            0400   prng_seeder prng_seeder
```

---

### 3. `vendor.gatekeeper-1-0` crash loop (SIGABRT)
**Status:** ✅ Fixed (boot.7: gatekeeper no longer appears in crash logs)

**Symptom:** `android.hardware.gatekeeper@1.0-service` crash-loops immediately with SIGABRT. Blocks system_server → blocks Zygote.

**Root cause:** `@1.0-impl.so` calls `hw_get_module_by_class(GATEKEEPER_HARDWARE_MODULE_ID)`. No `gatekeeper.msm8937.so` in vendor (marked `DISABLE_DEPS`). Calls `LOG_ALWAYS_FATAL`. Root cause of absence: no `qseecomd` binary in vendor blobs — TrustZone-backed gatekeeper can never work.

**Fix:** Replaced hardware gatekeeper with software implementation in `device/xiaomi/mithorium-common/mithorium.mk`:
- Removed: `android.hardware.gatekeeper@1.0-impl`, `@1.0-service`, `@1.0.vendor`
- Added: `android.hardware.gatekeeper@1.0-service.software`
- Removed `gatekeeper.xml` from `DEVICE_MANIFEST_FILE` in `BoardConfigCommon.mk` (software service ships its own vintf fragment)

---

### 4. `vendor.qseecomd` / `init.qti.qseecomd.sh` hang
**Status:** ✅ Fixed (boot.7: no qseecomd errors in log)

**Symptom:** `start vendor.qseecomd` fires on `post-fs`; no binary at `/vendor/bin/qseecomd`. `init.qti.qseecomd.sh` then spins waiting for `vendor.sys.listeners.registered` which is never set.

**Root cause:** Mi8937 vendor blobs only contain `hvdcp_opti` and `sensors.qti` — no `qseecomd`.

**Fix:** In `device/xiaomi/mithorium-common/rootdir/etc/init.target.rc`:
- Added `disabled` to `service vendor.qseecomd`
- Removed the `start vendor.qseecomd` and `exec init.qti.qseecomd.sh` lines from the `on post-fs` block

---

### 5. `vendor.qcamerasvr` crash loop (Exec format error)
**Status:** ✅ Fixed (boot.7: no qcamerasvr errors in log)

**Symptom:** `vendor.qcamerasvr` exits with code 127 (ENOEXEC) repeatedly.

**Root cause:** Service at `init.target.rc:90` tries to exec `/system/vendor/bin/mm-qcamera-daemon`. File is a blankfile placeholder → ENOEXEC. Camera will not work until a valid binary is obtained.

**Fix:** Added `disabled` to `service vendor.qcamerasvr` in `device/xiaomi/mithorium-common/rootdir/etc/init.target.rc`.

---

### 6. `vendor.livedisplay-sdm` crash loop (SIGSEGV)
**Status:** ✅ Fixed (boot.7: SDM variant no longer starting; sysfs variant runs fine)

**Symptom:** `vendor.lineage.livedisplay-service.sdm` crashes immediately with SIGSEGV.

**Root cause:** SDM LiveDisplay HAL variant uses kernel interfaces incompatible with 4.19 kernel.

**Fix:** Removed `vendor.lineage.livedisplay-service.sdm` from `PRODUCT_PACKAGES` in `mithorium.mk`. Sysfs variant (`livedisplay-service.sysfs`) starts and registers all three interfaces (AdaptiveBacklight, ColorEnhancement, ReadingEnhancement) successfully.

---

### 7. `surfaceflinger` SIGABRT — **CURRENT CRITICAL BLOCKER**
**Status:** ❌ Not yet fixed

**Symptom:** SurfaceFlinger starts (pid 953), crashes with SIGABRT ~0.4 seconds later. Its `onrestart` triggers `restart --only-if-running zygote` which kills Zygote. System cannot display anything.

**Root cause:** Unknown — needs tombstone or logcat. HWC (`hwcomposer.qcom.so`) and gralloc (`gralloc.msm8937.so`) are both present and built in `out/vendor/lib{,64}/hw/`. The rapid SIGABRT (0.4s) suggests an assertion failure in the HWC or EGL initialization path rather than a missing library. Likely candidates:
- `hwcomposer.qcom` failing to open the display hardware (mdss/mdp node, permissions, or ioctl incompatibility with 4.19 kernel)
- EGL/GLES driver initialization failure (`libGLESv2_adreno.so`, `libEGL_adreno.so`)
- Missing or mismatched vendor graphics libraries

**Next steps:**
- Need logcat / tombstone from `/data/tombstones/` to see the abort message and stack trace
- Check if `adb` connects briefly before Zygote is killed and grab logcat
- Alternatively: check kernel dmesg for GPU/display driver errors around t=63s
- Verify SELinux isn't blocking display device node access

---

### 8. Missing vendor binaries — several services can't start
**Status:** ❌ Not yet fixed (lower priority — likely not causing the surfaceflinger crash)

Services with "No such file or directory":
| Service | Expected binary | Impact |
|---------|----------------|--------|
| `qcom-c_core-sh` | `/vendor/bin/init.qcom.class_core.sh` | Init script for core services |
| `vendor.qrtr-ns` | `/vendor/bin/qrtr-ns` | QTI router nameserver (IPC routing) |
| `irsc_util` | `/vendor/bin/irsc_util` | IPC security config util |
| `vendor.per_mgr` / `pm-service` | `/system/vendor/bin/pm-service` | Peripheral manager |
| `vendor.sensors.qti` | `/vendor/bin/sensors.qti` | Sensor HAL binary |

**Root cause for `sensors.qti`:** Binary exists in `vendor/xiaomi/Mi8937/proprietary/vendor/bin/sensors.qti` but is marked `DISABLE_DEPS` in `proprietary-files.txt` and not referenced in `Mi8937-vendor.mk` → not installed to `out/vendor/bin/`. The remaining binaries (`qrtr-ns`, `irsc_util`, etc.) are Qualcomm proprietary binaries that were never extracted.

**Fix:** For `sensors.qti`: add it to `Mi8937-vendor.mk` or `Android.bp`. For the rest: disable the services in rc files since the binaries are unavailable.

---

### 9. `vendor.sensors-hal-1-0` exits with status 1
**Status:** ❌ Not yet fixed

**Symptom:** `vendor.sensors-hal-1-0` (pid 911) exits status 1 at t=62.22s, before class `hal` finishes starting.

**Root cause:** Likely related to missing `sensors.qti` binary (issue #8) — the HIDL sensors HAL wrapper needs the underlying sensor daemon or driver. Also `vendor-sensor-sh` (init.qcom.sensors.sh) exits status 1, suggesting sensor sysfs paths are not set up correctly.

**Fix:** TBD. Investigate after surfaceflinger is fixed and logcat is available.

---

### 10. Audio HAL: `android.hardware.audio.core.IModule/default` not found
**Status:** ❓ May be non-fatal

**Symptom:** `audioserver` reports "Could not find android.hardware.audio.core.IModule/default in the VINTF manifest. No alternative instances declared in VINTF."

**Root cause:** Android 15/16 `audioserver` first tries the new AIDL audio HAL interface. The device ships legacy HIDL-based `audio.primary.msm8937.so` only. If the AIDL→legacy bridge/adapter is not installed, audioserver may fail to open audio.

**Assessment:** The legacy `audio.primary.msm8937.so` is built and present. Whether audioserver gracefully falls back to it (via `android.hardware.audio@7.1` HIDL path or an audio adapter HAL) needs to be confirmed once the system gets further in boot.

---

### 11. `misctrl` exits status 1 (oneshot)
**Status:** ❓ Unknown impact

**Symptom:** `misctrl` (oneshot service, pid 951) exits with status 1 ~54ms after start at t=63.28s.

**Root cause:** Unknown. Service identity not yet traced to a specific binary. Exits immediately and doesn't appear to block boot — marked oneshot so init doesn't restart it.

---

### 12. SELinux denial: `hal_thermal_default` netlink socket
**Status:** ❌ Not yet fixed (lower priority)

**Symptom:** `avc: denied { create } for comm="android.hardwar" scontext=u:r:hal_thermal_default:s0 tcontext=u:r:hal_thermal_default:s0 tclass=netlink_kobject_uevent_socket permissive=0`

**Root cause:** Thermal HAL tries to create a netlink kobject uevent socket to monitor thermal events, but the SELinux policy doesn't grant this to `hal_thermal_default`.

**Fix:** Add to `device/xiaomi/mithorium-common/sepolicy/vendor/` (or `hal_thermal_default.te`):
```
allow hal_thermal_default self:netlink_kobject_uevent_socket create_socket_perms_no_ioctl;
```

---

### 13. `lineage.hardware.radio.config@1.0::IRadioConfig/default` not found
**Status:** ❓ Expected / acceptable

**Symptom:** hwservicemanager repeatedly fails `ctl.interface_start` for `lineage.hardware.radio.config@1.0`.

**Root cause:** This Lineage-specific radio config HAL is not declared in the vendor manifest and likely not needed for basic functionality. Cosmetic error, probably not blocking.

---

### 14. Hardware keymaster likely has same problem as gatekeeper
**Status:** ❓ Not yet manifesting as a crash (may be masked by surfaceflinger crash)

**Assessment:** `android.hardware.keymaster@3.0-impl` + `@3.0-service` are still in `mithorium.mk`. Like the gatekeeper, there is no `keymaster.msm8937.so` in vendor (marked `DISABLE_DEPS`) and no `qseecomd`. The passthrough impl will call `LOG_ALWAYS_FATAL` if it can't find the hardware module. This may become the next crash-loop blocker once surfaceflinger is fixed.

**Preemptive fix:** Switch to software keymaster equivalent — likely `android.hardware.security.keymint@1.0-service.software` or `android.hardware.keymaster@4.1-service.strongbox` (needs investigation to find correct AOSP software fallback).

---

## Next Steps (Priority Order)

1. **Get tombstone / logcat for surfaceflinger crash** — either grab it from `/data/tombstones/` via recovery, or try connecting adb before Zygote dies
2. **Fix surfaceflinger** (issue #7) — diagnose from tombstone, then fix HWC/display/EGL issue
3. **Add sensors.qti to vendor mk** (issue #8) — trivial fix, may unblock sensors
4. **Disable missing-binary services** (issue #8) — add `disabled` to `qcom-c_core-sh`, `vendor.qrtr-ns`, `irsc_util`, `vendor.per_mgr` in init.qcom.rc / init.target.rc
5. **Preemptively fix keymaster** (issue #14) — before it becomes the next blocker
6. **Fix thermal HAL SELinux** (issue #12) — one-line policy addition
7. **Investigate audio AIDL fallback** (issue #10) — once system boots far enough for logcat
