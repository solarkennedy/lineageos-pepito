# SurfaceFlinger Crash Investigation — ✅ RESOLVED 2026-06-05; ⚠️ REGRESSED + RE-FIXED 2026-06-23

**Context:** t=123s into userspace boot, surfaceflinger receives SIGABRT and kills zygote cascade.
Observed in boot log after §A/§B resolved; init, servicemanager, vold confirmed running.

**Resolution (2026-06-05):** Two missing Adreno 505 blobs (`libadreno_utils.so`, `libllvm-glnext.so` + `libllvm-qcom.so`)
added to vendor tree. LineageOS boot logo confirmed visible on-device 2026-06-05.

---

## ⚠️ 2026-06-23: SurfaceFlinger crash returned — different root cause (GPU CP microcode)

After the RPMB fix let the device boot again (see `PLAN-gatekeeper.md`), SurfaceFlinger
crash-looped once more — but this time it was **not** missing blobs:

```text
libEGL: eglInitialize(...) failed (EGL_BAD_ALLOC)
SurfaceFlinger: no suitable EGLConfig found, giving up
  → SkiaGLRenderEngine::chooseEglConfig → abort (SIGABRT)
kgsl kgsl-3d0: GPU PAGE FAULT addr=FCCC7000 ; CP initialization failed to idle
Adreno-GSL: open(/dev/kgsl-3d0) failed: errno 110 (ETIMEDOUT)
```

Root cause: the Adreno A506 CP microcode `a530_pm4.fw`/`a530_pfp.fw` had been
**downgraded to the stock Android-8 (3.18-era) version**, which the 4.19 kgsl
driver cannot init. `serial.log.15` (2026-06-16 morning) booted with the newer
`out/` ucode (`PM4 0x5FF066 / PFP 0x5FF114`); the proprietary blob was swapped to
the stock ucode (`0x5FF063 / 0x5FF087`, matching the AML0 backup) at 2026-06-16
21:17, after that good boot.

Fix (confirmed live: adb-push + reboot → `boot_completed=1` at ~30s, SF stable,
`AdrenoGLES PFP 0x5ff114 / ME 0x5ff066`): restored the newer ucode into
`vendor/xiaomi/Mi8937/proprietary/vendor/firmware/a530_p{m4,fp}.fw` (broken stock
copies saved as `*.stock-3.18-bak`). Installed via `Mi8937-vendor.mk`
`PRODUCT_COPY_FILES`. **Guard against re-pulling the stock 3.18 ucode over it.**
Note: the missing `zap-shader` DT node was a red herring — a5xx loads the zap by
name (`.zap_name = "a506_zap"`), so it was the CP microcode, not zap.

---

## Status

| Item | State |
|---|---|
| Root cause 1 identified | ✅ `libadreno_utils.so` missing from vendor blob set |
| Root cause 1 fix applied | ✅ Blobs added, vendor.mk updated, vendor.img built 2026-06-05 15:57, flashed — confirmed on-device |
| Root cause 2 identified | ✅ `libllvm-glnext.so` missing — `libGLESv2_adreno.so` DT_NEEDED, absent from vendor lib/lib64 |
| Root cause 2 fix applied | ❌ Pending blob acquisition + vendor.mk update |
| pmsg logcat analysed | ✅ (boot.flinger.1.log, 2026-06-05 16:12) |
| Tombstone retrieved | ❌ /data not mounted in recovery; not needed — root cause confirmed via pmsg |

---

## Root cause — `libadreno_utils.so` not extracted

`libEGL_adreno.so` depends on `libadreno_utils.so` (direct `DT_NEEDED`). That library is
**completely absent** from the vendor partition — neither in `/vendor/lib/` nor `/vendor/lib64/`.
When SurfaceFlinger starts and the EGL loader calls `dlopen("libEGL_adreno.so")`, the dynamic
linker fails because `libadreno_utils.so` is unresolvable. The EGL loader logs:

```
couldn't find an OpenGL ES implementation, make sure one of
persist.graphics.egl, ro.hardware.egl and ro.board.platform is set
```

…and SurfaceFlinger calls `abort()`.

**Why it was missed:** `proprietary-files-qc-vndr.txt` lines 239 and 255 list
`vendor/lib/libadreno_utils.so` and `vendor/lib64/libadreno_utils.so` correctly, but the
blob was not present on the source device at extraction time, so `mithorium-common-vendor.mk`
was generated without it (confirmed: `libadreno_utils.so` appears nowhere in the vendor tree).

**Confirmed present:** `ro.hardware.egl=adreno`, `ro.board.platform=msm8937`, all other EGL
blobs (`libEGL_adreno.so`, `libGLESv1_CM_adreno.so`, `libGLESv2_adreno.so`,
`libq3dtools_adreno.so`, `libq3dtools_esx.so`, `eglSubDriverAndroid.so`, `libgsl.so`,
`vulkan.adreno.so`) are on-device and correctly listed in the makefile.

---

## Fix

### Step 1 — Obtain the blob from an Adreno 505 source device

Any of: santoni / land / ugg / prada (all MSM8937 + Adreno 505).

Option A — from a running LineageOS device over adb:
```bash
adb pull /vendor/lib/libadreno_utils.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib/libadreno_utils.so
adb pull /vendor/lib64/libadreno_utils.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib64/libadreno_utils.so
```

Option B — from a TheMuppets vendor zip for santoni or land (same Adreno 505 blob set).

### Step 2 — Add entries to `mithorium-common-vendor.mk`

In `vendor/xiaomi/mithorium-common/mithorium-common-vendor.mk`, add the two missing lines
alongside the existing `libgsl.so` entries (32-bit block around line 10, 64-bit block
around line 21):

```makefile
# 32-bit block — after libgsl.so line
    $(LOCAL_PATH)/vendor/lib/libadreno_utils.so:$(TARGET_COPY_OUT_VENDOR)/lib/libadreno_utils.so \

# 64-bit block — after libgsl.so line
    $(LOCAL_PATH)/vendor/lib64/libadreno_utils.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libadreno_utils.so \
```

### Step 3 — Rebuild and flash vendor.img

> **Note:** `extract-files.py -n -m` cannot be used here — it requires all listed blobs to
> be present on disk to generate ELF metadata for Android.bp. Since mithorium-common only
> has a partial blob set extracted, running it clobbers the vendor mk with a partial output.
> The vendor mk is hand-maintained for this reason.

```bash
./scripts/build-lineage23.sh   # or: m vendorimage
./scripts/flash-staging.sh
```

---

## Root cause 2 — `libllvm-glnext.so` (and `libllvm-qcom.so`) not extracted

After `libadreno_utils.so` was added and flashed (2026-06-05), SF continued crashing.
pmsg-ramoops-0 from `boot.flinger.1.log` (16:12) shows:

```
Could not load /vendor/lib64/egl/libGLESv2_adreno.so from sphal namespace:
  dlopen failed: library "libllvm-glnext.so" not found:
  needed by /vendor/lib64/egl/libGLESv2_adreno.so in namespace sphal.
eglInitializeImpl:283 error 3008 (EGL_BAD_DISPLAY)
failed to initialize EGL
Abort message: 'failed to initialize EGL'
```

`libllvm-glnext.so` is the LLVM shader compiler for Adreno; `libGLESv2_adreno.so` has it as a
direct `DT_NEEDED`. Both `libllvm-glnext.so` and `libllvm-qcom.so` are listed in
`proprietary-files-qc-vndr.txt` with a leading `-` (disabled) and `DISABLE_DEPS` — they were
never extracted and never added to `mithorium-common-vendor.mk`.

**Confirmed absent** from `/vendor/lib/` and `/vendor/lib64/` on device (verified via adb in recovery).

### Fix

Same pattern as root cause 1. Obtain from any Adreno 505 source (santoni/land/prada/ugg):

```bash
adb pull /vendor/lib/libllvm-glnext.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib/libllvm-glnext.so
adb pull /vendor/lib64/libllvm-glnext.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib64/libllvm-glnext.so
adb pull /vendor/lib/libllvm-qcom.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib/libllvm-qcom.so
adb pull /vendor/lib64/libllvm-qcom.so \
  vendor/xiaomi/mithorium-common/proprietary/vendor/lib64/libllvm-qcom.so
```

Add to `mithorium-common-vendor.mk` alongside the `libadreno_utils.so` entries:

```makefile
    $(LOCAL_PATH)/vendor/lib/libllvm-glnext.so:$(TARGET_COPY_OUT_VENDOR)/lib/libllvm-glnext.so \
    $(LOCAL_PATH)/vendor/lib/libllvm-qcom.so:$(TARGET_COPY_OUT_VENDOR)/lib/libllvm-qcom.so \
    $(LOCAL_PATH)/vendor/lib64/libllvm-glnext.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libllvm-glnext.so \
    $(LOCAL_PATH)/vendor/lib64/libllvm-qcom.so:$(TARGET_COPY_OUT_VENDOR)/lib64/libllvm-qcom.so \
```

Then rebuild vendor.img and flash.

> **Note:** There may be further missing deps in the same blob family after this fix —
> `libllvm-qcom.so` is included preemptively since it is also absent and commonly needed
> by the same Adreno stack. If another `dlopen failed` appears, check pmsg again.

---

## Secondary: GateKeeper HAL abort

`pmsg-ramoops-0` also shows:
```
Abort message: 'Unable to open GateKeeper HAL'
```
backtrace through `libhidlbase.so::PassthroughServiceManager::openLibs` — the gatekeeper
HIDL service can't find its passthrough impl (`gatekeeper.msm8937.so` or TEE-backed impl).
This is a separate crash from surfaceflinger; investigate after SF is resolved.

Likely cause: `android.hardware.gatekeeper@1.0-impl.so` not present or not listed in
vendor manifest. Check:
```bash
adb shell ls /vendor/lib64/hw/ | grep gatekeeper
grep -r "gatekeeper" vendor/xiaomi/mithorium-common/mithorium-common-vendor.mk
```

---

## Secondary: `vendor.sensors.qti` exit(1)

Sensor HAL exits immediately with status 1. Separate from the SF crash; investigate after
SF is resolved.

Likely causes:
- ADSP firmware not staged to `/vendor/firmware/` or wrong file names
- Missing `/vendor/etc/sensors/` config files (sensor_def_qcomdev.conf etc.)
- `sensors.qti` HIDL service tries to open `/dev/msm_isp` or similar and lacks permission

**To verify once adb is stable:**
```bash
adb logcat -b all | grep -i sensor
adb shell ls /vendor/etc/sensors/
adb shell ls /vendor/firmware/ | grep -i adsp
```

---

## Notes

- `lineage.hardware.radio.config@1.0` not found: benign, logged by hwservicemanager on any
  device without a radio config HAL. Not related to this crash.
- `chmod 0755 /system/bin/ip` EROFS: benign, init.qcom.rc:145 legacy script running against
  read-only system partition as expected on Android 10+.
- `mem_cgroup_update_lru_size` kernel WARNING: consequence of zygote teardown, not a cause.
  Known 4.19 CIP accounting race during mass thread exit under memcg.
