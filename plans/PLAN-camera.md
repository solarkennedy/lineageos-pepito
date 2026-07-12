# Pepito Camera Bring-up Plan

**Hardware:** Palm PVG100 (MSM8940 / Adreno 505) — rear OmniVision OV12A10 (12MP), front Samsung S5K4H8 / GalaxyCore GC8034 (8MP, dual-sourced).
**Stack:** stock Palm AML0 `camera.msm8937` HAL + stock interface/daemon blobs via pepito overlayfs (`/vendor/odm/{bin,lib,etc/camera}`) + Lineage camera provider.
**Status (2026-07-02):** 🎉 **LIVE PREVIEW + CAPTURE WORK — first real frames on the 4.19
bring-up.** The source-built `camera.pepito` HAL streams end-to-end (Google Camera + Aperture,
rear OV12A10). Path: enumeration ✅ → gralloc `0x7C7C7C7C` poison ✅ eliminated by the source HAL
→ the last blocker (daemon ISP `find_primary_cid` / `stream mapping` → -38) ✅ **root-caused to a
`0x0` `CAM_STREAM_TYPE_ANALYSIS` stream and FIXED** (guard in `QCamera3HWI.cpp`, commit
`2212ac55`). Option 2 (handle translation) was never needed. **Baked in-tree + clean-flash verified
(2026-07-03): rear preview works from the flashed `vendor.img`, no bind-mount** (commits
`2212ac55` + `c8570b91`; `camera.pepito` in PRODUCT_PACKAGES + `ro.hardware.camera=pepito`).
**Still-capture ✅ SOLVED (2026-07-03): BOTH cameras produce real JPEGs** (front 8MP + rear
12MP, live-verified on `c39a6acf`). The `paaf`/`quadracfa` `0×0`-preload theory was **wrong**
(that failure is benign noise — the reprocess pipeline runs fine past it); the actual blocker
was **4 missing JPEG userspace blobs**: the qomx core's `OMX_GetHandle("OMX.qcom.image.jpeg.encoder")`
dlopen of `libqomx_jpegenc.so` failed (`0x80001004`) because it + its dep chain
(`libmmjpeg`, `libmmqjpeg_codec`, `libmmqjpegdma`) were never staged. Staged in-tree
(`pepito_libqomx_jpegenc` etc. in Android.bp + Mi8937-vendor.mk). **Front camera preview +
capture also verified working** (was previously untested). See REMAINING item 2.
Getting here
took a **5-fix chain**, each fix exposing the next (full detail in the RESOLUTION section
below). The historical "Layer 1/2/3" narrative further down records the journey; note two of its
conclusions were later corrected — the session-id fix is `vdev->num` (not `camera_id+1`), and the
recommended "use the HIDL/HAL1 path" candidate was **rejected** (we kept the modern AIDL/HAL3
userspace and fixed the kernel + props instead).

---

## ✅ RESOLUTION — the 5-fix chain (2026-06-29)

All five are in the source tree; enumeration verified on-device (`Number of camera devices: 2`,
Back + Front, full HAL3 static metadata, no SIGSEGV). Each fix unblocked the next:

1. **Kernel — session-id** (`techpack/camera-legacy/camera/camera.c`, `legacy_camera_init_v4l2`):
   `pvdev->session_id = pvdev->vdev->num` (assigned **after** `video_register_device` so `vdev->num`
   is valid), exactly matching stock 3.18. Fixes BOTH the imglib session-0 reject AND the
   HAL↔daemon `cam_socket` alignment (daemon names `/data/vendor/camera/cam_socket<session_id>`;
   HAL connects by video-node number → rear=video1→1, front=video2→2). The earlier `camera_id+1`
   only coincidentally matched the rear (0+1=1=video1) and broke the front (cell-index 2+1=3≠video2).
2. **Kernel — OTP** (`techpack/camera-legacy/sensor/msm_sensor.c` + `include/uapi/media/
   msm_cam_sensor-legacy.h`): added the **TCL/Palm-custom `CFG_SENSOR_OTP_UPDATE` cfgtype**
   (enum value 30, appended) + a no-op `case` in BOTH `msm_sensor_config32` (the 32-bit daemon's
   compat path) and `msm_sensor_config`. The Palm blob sends this cfgtype during OTP init; our
   generic 4.19 kernel lacked it → `default: -EFAULT` → `otp init error -1`. Root-caused via
   strace: the OTP `ioctl(/dev/v4l-subdev15[ov12a10], VIDIOC_MSM_SENSOR_CFG)` returned EFAULT.
3. **Vendor — chromatix + eeprom libs** (layer 2, already in tree): 27 `libchromatix_ov12a10_*` +
   23 s5k4h8 + eeprom libs → `/vendor/lib` so `module_sensor_init` succeeds.
4. **Vendor — perf stub** `libqti-perfd-client.so`: the legacy HAL's "jinghuang" `camera_open`
   dlopens `ro.vendor.extension_library`(=libqti-perfd-client.so); it's absent on our build and
   the stock A8 one is unloadable (needs HIDL `gBnConstructorMap`, removed in modern Android) →
   null handle → the matching close derefs it → SIGSEGV. Built a **no-op stub** (source:
   `vendor/xiaomi/Mi8937/pepito-perfd-stub/perfstub.c`; exports perf_lock_acq/rel/cmd/perf_hint/
   use_profile, zero deps). Integrated: `proprietary/vendor/lib/libqti-perfd-client.so` +
   `cc_prebuilt_library_shared pepito_libqti-perfd-client` in `Android.bp` + `PRODUCT_PACKAGES`.
5. **Property — `persist.camera.HAL3.enabled=1`** (`device/xiaomi/mithorium-common/vendor.prop`):
   the **non-vendor** prop was empty (only `persist.vendor.camera.HAL3.enabled=1` was set, which
   this HAL ignores). Without it the HAL reported HAL1/`device@1.1`, and modern cameraserver
   rejected it (`CameraDevice: Camera id 0 does not support HAL3.2+` → -22 → 0 devices). With it,
   `QCamera2Factory isHAL3Enabled:1` → both cameras enumerate as HAL3.

**Build/flash:** kernel fixes (1,2) are in boot.img (flashed). Fixes 3–5 are in the **vendor**
image → need a full (non-`-b`) build + `vendor.img` flash to bake in for clean boots.
**Pre-merge cleanup:** revert the `[PEPITO-OTP]`/`[PEPITO-CAM]` debug `pr_info` + `FUNCTION_TRACER`
defconfig (kept for the streaming work).

## 🟡 REMAINING — live streaming (separate campaign)

Camera **opens** for a session but `configureStreams`/capture fails: the Android-8 HAL gets a
**poison `cam_format 0x7C7C7C7C`** (uninitialized) and **0×0 dims** for the framework's native
(gralloc) buffers → `iface_util_modify_plane_info_for_native_buf` fail → `start_channel -1` →
`processCaptureRequest` returns -38 → session torn down ("error trying to setup the session").
This is the **modern-framework/gralloc-buffer ↔ Android-8-HAL buffer-handle ABI** boundary — a
distinct, deeper problem, unrelated to the enumeration fixes.

### Option 0 — source-built `camera.pepito` HAL — ✅ **VALIDATED, gralloc poison solved (2026-07-02)**

**RESULT (2026-07-02 live test on `c39a6acf`):** Option 0 works exactly as predicted. The
gralloc provenance problem — the entire reason Option 2 existed — is **solved** by using the
source-built HAL. Option 2 is no longer needed.

**What was done:**
1. `mka camera.pepito` on the remote builder — **compiles cleanly** against Lineage 23.2 (only a
   harmless `V4L2_PIX_FMT_SGRBG14` macro-redefine warning). Settles the "missing legacy headers"
   risk. Artifacts: `vendor/odm/lib/hw/camera.pepito.so` + `libPmcamera_interface.so` +
   `libPmjpeg_interface.so` + **`libPomx_core.so`** (arm 32-bit).
2. **DT_NEEDED closure (don't miss this):** `camera.pepito.so` → `libPmcamera_interface.so`,
   `libPmjpeg_interface.so`; and `libPmjpeg_interface.so` → **`libPomx_core.so`** (Palm OMX core).
   First swap attempt failed dlopen on the missing `libPomx_core.so` → provider crashed in
   `notifyDeviceStateChange()` (the same null-deref from the old plan = "HAL module failed to
   load"). All three Palm libs must be staged. `libPomx_core.so` itself needs only standard libs.
3. **Live swap:** staged the 3 Palm libs into `/vendor/lib` (rw; the vendor/odm namespace searches
   it) + bind-mounted `camera.pepito.so` over the resolved `/vendor/odm/lib/hw/camera.msm8937.so`.
   Reproduce with `/data/local/tmp/apply_pepito_hal.sh` (staged on device) — files in
   `/data/local/tmp/{camera.pepito.so,libPm*,libPomx_core.so}`.

**Verified on-device:**
- `CamPrvdr: Loaded "QCamera Module"`; `get_num_of_cameras: num_cameras=2`; both cameras
  `resource cost 100` — **exactly the A11 working-device signature**. Provider healthy, no crash.
  **The `cam_intf` struct-compat risk did NOT materialize** — source HAL ↔ Palm A8 daemon
  interoperate at enumeration.
- Drove a real capture (LineageOS Aperture): `configureStreamsPerfLocked` gets **real** formats
  (`stream[0]=34/IMPL_DEFINED 1024×768`, `stream[1]=33/BLOB 4000×3000`), `processCaptureRequest`
  gets **real** STREAM INFO dims — **NO `0x7C7C7C7C`, NO `Invalid cam_format`, NO `2088533116`**.
  Session created cleanly as **session 1**. The poison is gone; Path B is fixed as predicted.

**NEW BLOCKER (downstream, unrelated to gralloc) — the next campaign:**
```
isp_util_handle_stream_info: failed: stream mapping              (ISP ERR 7024, daemon pid 1145)
  → iface_util_find_primary_cid: cannot find primary sensor format cids 1   (x9)
  → isp_port_check_caps_reserve: failed: isp_handler_create_internal_link
  → iface_reserve_src_port: this src port can not use!
  → QCamera processCaptureRequest: Channel initialization failed -1
  → Camera3-Device: capture request → Function not implemented (-38) → onError → session torn down
```
The daemon's ISP/iface pipeline has **1 CID** but can't match it to a "primary sensor format", so
it can't build the ISP internal link / reserve the src port. This is a **sensor-format / CSID
datatype negotiation** issue (ISP input-format table vs the CID the sensor/HAL registers), NOT a
buffer-handle issue. Leads to chase next:
- Does the stock HAL register a different `cam_stream_info`/reprocess format than our source HAL?
  (`STREAM INFO ... Format:0` in the request — is `Format:0` what the daemon's primary-CID table
  expects, or is the real sensor raw format being dropped?)
- Compare the CID list the daemon builds on A11 (working, stock HAL) vs A16 source HAL for the
  same stream config — `find_primary_cid` succeeds on A11.
- Sensor-format config: CSI datatype/lane/format come from Palm's `camera_config.xml` + sensor
  lib (`iface`/CSID). Is the source HAL passing the sensor's raw MIPI format through to the ISP,
  or defaulting to 0?
- Whether this ALSO blocks the stock HAL (was previously masked by the earlier poison abort).

**Device state after test: REVERTED to stock baseline** (bind-mount lazy-unmounted, stock HAL
md5 `2f4be79d` restored, `dumpsys`=2). The 3 Palm libs remain in `/vendor/lib` (harmless — stock
HAL ignores them). Re-apply the pepito HAL with `/data/local/tmp/apply_pepito_hal.sh`.

**To bake in-tree (once the ISP blocker is cracked):** add `camera.pepito` + `libPmcamera_interface`
+ `libPmjpeg_interface` + `libPomx_core` to `PRODUCT_PACKAGES` (they build to `/vendor/odm/lib`),
point the provider at it (currently `ro.hardware.camera=msm8937` → loads `camera.msm8937.so`;
either set the prop to `pepito` at build time or install `camera.pepito.so` as the resolved name),
and remove the stock-HAL overlay. Revert the `device.mk:88-89` "uses stock AML0 HAL" note.

### ✅ SOLVED — the `find_primary_cid` blocker was a `0x0` analysis stream (2026-07-02)

The post-gralloc blocker turned out **not** to be a CID/CSID negotiation gap at all — it was a
malformed **`CAM_STREAM_TYPE_ANALYSIS`** stream at **`0×0`**. Decode of the daemon log
(mm-qcamera-daemon pid 1145):
```
isp_util_print_meta_stream_info: Stream type 11 Resolution: 0x0   <-- type 11 = ANALYSIS, 0x0!
isp_util_handle_stream_info: failed: stream mapping               (ISP ERR 7024)
  → iface_util_find_primary_cid: cannot find primary sensor format cids 1   (x9, cascade)
  → isp_port_check_caps_reserve: failed isp_handler_create_internal_link
  → iface_reserve_src_port: this src port can not use!
  → processCaptureRequest: Channel initialization failed -1 → -38 → session torn down
```
The `find_primary_cid`/port-reserve errors were **downstream noise** from the daemon choking on
the 0×0 stream, not the root cause.

**Root cause (traced in the HAL source we own):** `QCamera3HardwareInterface::configureStreamsPerfLocked`
creates the analysis stream from `analysisInfo.analysis_max_res` (via `QCameraCommon::getAnalysisInfo`,
which for HAL3 = `analysis_recommended_res`). The stock A8 daemon reports `analysis_info` as
**`valid=1` but with `0×0` recommended/max resolution** on pepito, so the analysis channel is
created at 0×0 and its 0×0 size is copied into `mStreamConfigInfo.stream_sizes[]` (~line 2295) and
sent to the backend.

**Fix (committed `2212ac55`, `QCamera3HWI.cpp`):** guard the analysis-channel creation against a
`0×0` resolution. Because the meta-config entry is gated on `if (mAnalysisChannel)` (~line 2276),
a NULL channel cleanly drops the malformed stream. **Result: live preview + capture stream
end-to-end** (verified with Google Camera + Aperture on `c39a6acf`; screenshot captured; 0×
`-38`/`Channel init failed`/`find_primary_cid`, healthy capture-result flow). SW face-detect is
the only casualty (no analysis stream) until `analysis_info` is populated with a real resolution.

### REMAINING — finish-line follow-ups

1. **Bake the HAL into the tree — ✅ DONE + CLEAN-FLASH VERIFIED (2026-07-02/03).**
   `camera.pepito` is in `PRODUCT_PACKAGES` (device.mk; pulls its `libPm*`/`libPomx_core`
   shared_libs to `/vendor/odm/lib`), and `ro.hardware.camera=pepito`
   (`init.xiaomi.device.rc`, was `msm8937`) points the provider at it. Commits `2212ac55`
   (analysis guard) + `c8570b91` (bake-in) in the device repo. **A clean `vendor.img` build
   flashed and booted with live rear preview — no bind-mount, all artifacts from the image.**
   The stock `camera.msm8937.so` blob is now dead weight (still staged); retire
   `pepito_camera_msm8937` + `libVDBeautyShotAPI` + the linker fragment as cleanup (verified the
   daemon doesn't need `libVDBeautyShotAPI`).
2. **Still-capture — ✅ SOLVED (2026-07-03): 4 missing JPEG userspace blobs. Both cameras
   capture real JPEGs** (front 2448×3264 + rear 3000×4000, pulled off `c39a6acf` and verified
   as real images; `OMX_GetHandle: Success` → `mm_jpeg_fbd: PROFILE_JPEG_FBD`).
   - **Sub-fix (kept, was real):** `libmmcamera_tintless_algo.so` (+`_bg_pca`) dlopen fail —
     staged earlier, still required.
   - **The `paaf`/`quadracfa` `0×0`-preload theory was WRONG — that failure is benign noise.**
     Live trace (2026-07-03): the `0×0` preload fires at *every* configure — it's triggered by
     `CAM_INTF_META_STREAM_INFO` processing on the *session* stream, where paaf finds no
     PAAF-enabled streams → "Calculate default pre-load params" → `0×0` → `IMG_CORE_PRELOAD
     failed -4` — and the daemon carries on regardless. At capture the offline reprocess stream
     was created with **real dims** (identity `0x20004`, 3264×2448), CPP processed the frame
     (`cpp frame done`), and the HAL reached `encodeData` with real dims. (Preload dims also do
     NOT come from `CAM_INTF_PARM_MAX_DIMENSION` — the sensor got `raw w 3264 h 2448` yet the
     modules still preloaded `0×0`; the imgbase "default" path just yields 0. Harmless.)
   - **REAL ROOT CAUSE: the JPEG encode stage.** `qomx_image_core: OMX_GetHandle:232 Cannot
     load the library` → `-2147479548` (`0x80001004` OMX_ErrorInvalidComponent) →
     `mm_jpeg_session_create` fail → `mm_jpeg_start_job: session not active` → snapshot BLOB
     never returned → `Cancel missing frame … type 3 format 33` loop. The in-tree qomx core
     (`mm-image-codec/qomx_core/qomx_core.c`, default table since pepito has no RENAME_BLOBS)
     dlopens **`libqomx_jpegenc.so`**, which was on NO partition — JPEG encode runs in the HAL
     (provider) process, and no earlier bring-up stage ever reached it, so the blob set was
     never staged. Only the HW engine libs (`libjpegehw`/`libjpegdmahw`/`libjpegdmahw`) were in
     the odm overlay.
   - **FIX: staged the 4 blobs from the A8 AML0 dump into `/vendor/lib`** —
     `libqomx_jpegenc.so` → DT_NEEDED `libmmjpeg.so` + `libmmqjpeg_codec.so` → DT_NEEDED
     `libmmqjpegdma.so` (rest of the closure — `libfastcvopt`, `libcrypto` — already resolves).
     Live-pushed + verified, then staged in-tree: `proprietary/vendor/lib/` +
     `pepito_libqomx_jpegenc`/`pepito_libmmjpeg`/`pepito_libmmqjpeg_codec`/`pepito_libmmqjpegdma`
     in `Android.bp` + `Mi8937-vendor.mk` PRODUCT_PACKAGES (untracked vendor tree). **Needs the
     next vendor.img rebuild+flash to be permanent** (device currently has them via live push).
   - **Front camera (S5K4H8): preview + capture BOTH WORK** (first confirmation ever; session 2,
     8MP). Camera-switch (flip) worked after a camera-stack restart, but **locked up once**
     before it (front→rear flip wedged Aperture; `ctl.restart vendor.qcamerasvr` + app relaunch
     cleared it) — intermittent, needs a repro + log if it recurs.
3. **Restore face-detect — FIX STAGED (2026-07-03), needs build+flash+FD test.**
   `QCameraCommon::getAnalysisInfo` now substitutes **640×480 + sane padding** when the daemon
   reports the valid-but-0×0 `analysis_info` (centralized there so BOTH consumers — channel
   creation and the meta-stream-info sizes at ~`QCamera3HWI.cpp:2319`, where the 0×0 previously
   leaked to the daemon — see the same fixed-up values). Runtime escape hatch if the daemon
   rejects the substituted stream (re-check for the old `find_primary_cid` cascade!):
   `setprop persist.vendor.camera.analysis.subst 0` restores the drop-the-stream behavior
   (the 2212ac55 guard is still in place and handles that path). Test: camera app → point at a
   face → face-detect rectangle; and confirm preview/capture still work with the analysis
   stream active.
4. **Pre-merge cleanup — ✅ DONE (2026-07-03):** stock-blob retirement (`pepito_camera_msm8937`
   + `pepito_libVDBeautyShotAPI` modules, vendor.mk entries, proprietary-files*.txt lines,
   `configs/linker.config.json` + its device.mk fragment — all removed); kernel debug trimmed
   (`[PEPITO-OTP]` pr_infos removed, pure-debug `msm_camera_cci_i2c.c` reverted, `[PEPITO-CAM]`
   demoted to pr_debug, `CONFIG_FUNCTION_TRACER/_GRAPH_TRACER/DYNAMIC_FTRACE` reverted in
   `mi8937_defconfig` — the OTP-cfgtype + session-id fixes remain). The `[PEPITO-ANALYSIS]`
   LOGE in QCamera3HWI stays until FD (item 3) is verified. Stray
   `arch/arm64/configs/mi8937_defconfig.bak` left in the kernel tree (not mine to delete —
   looks like an old savedefconfig artifact; owner to remove).

**Live-hack note (post-clean-flash):** `adb` is **not root by default** after a clean flash —
run `adb root` before any `mount -o remount,rw /vendor` (userdebug supports it). The camera now
comes from the image, so the old `reapply_and_test.sh` bind-mount dance is only needed when
testing an *unflashed* rebuilt `camera.pepito.so`.

### (superseded rationale) Option 0 — retest the source-built `camera.pepito` HAL — deep review 2026-07-02
> ⚠️ **Historical — this was the pre-test hypothesis; Option 0 is now VALIDATED (see the block at
> the top of REMAINING). Kept for the reasoning trail + the tree facts (module deps, header
> paths).**

**Finding:** the tree already contains a full source-built QCamera2 HAL3 for pepito —
`device/xiaomi/Mi8937/camera/mi8937/camera/QCamera2/Android.bp` module **`camera.pepito`**
(compiled with `-DDEVICE_PEPITO`, linking Palm-flavored `libPmcamera_interface` /
`libPmjpeg_interface` — someone already invested in matching it to Palm's stack). It was
abandoned on **2026-06-24** (commit `1afe32c6`; `device.mk:88-89`: *"reaches the daemon but
fails IMGLIB startup"*). But **"fails IMGLIB startup" is exactly the session-id-0 signature**
(`module_imgbase_start_session: Invalid idx -1`) — a kernel bug independent of which HAL is
used — and it was **fixed on 2026-06-27/29** (fix #1, `vdev->num`). The source HAL was written
off for a bug that no longer exists; it has never been tested against the fixed kernel.

**Why it dissolves the gralloc catch-22:** `camera.pepito` is compiled against the in-tree
`display_headers` — the **same source gralloc generation** A16's allocator/mapper/HWC use
(`hardware/qcom-caf/msm8953/display`; note: msm8953, not the msm8998 path cited under Option 2).
It reads `private_handle_t` at the *correct* offsets (`QCamera3Mem.cpp`, `QCamera3HWI.cpp`
include the source `gralloc_priv.h`), so **Path B ceases to exist** while Path A (shim → modern
mapper → A16 gralloc) is untouched. Both paths satisfied simultaneously — the catch-22 was a
property of the stock blob HAL, not of the architecture. It also permanently removes the
"jinghuang" close-crash class and the perf-stub dependency (fix #4 becomes moot but harmless).
This is PLAN.md's own "Why Mi8937" thesis (source-build the HALs to kill the A8-blob ABI gap)
applied to the one subsystem where we departed from it.

**What carries over:** all 5 enumeration fixes are kernel/daemon/prop-side, not HAL-side —
session-id, OTP cfgtype, chromatix/eeprom libs, HAL3 prop all still apply. The daemon-side
stack (mm-qcamera-daemon, sensor/imglib/chromatix blobs) is unchanged.

**The real risk (empirical, ~1 hour to answer):** HAL↔daemon shared-struct compatibility —
the in-tree `cam_intf.h`/`cam_capability_t` layouts vs Palm's A8 daemon modules (mapped
structs, version-fragile). Counter-evidence: in the 06-24 attempt it already *"reached the
daemon"* (socket handshake + session-create protocol interoperated far enough to hit MCT
session start — the same point where the stock HAL died pre-fix), and the `libPm*` naming
says the interface source was already Palm-matched. **Failure signature to watch for:**
garbled static metadata / nonsense dims at enumeration = struct mismatch → fall back to
Option 2.

**Test procedure (no full build needed; kernel fixes already flashed):**
1. `mka camera.pepito` (targeted remote module build — do NOT use
   `build-lineage23-remotely.sh`, it nukes `KERNEL_OBJ` + builds full images; instead
   rsync source + `ssh <remote> 'source build/envsetup.sh && lunch lineage_Mi8937 bp4a
   userdebug && mka camera.pepito'`). **First risk this build settles:** the sibling camera
   HALs (`camera.land/ulysse/wingtech`) are disabled in `device.mk:78` for "missing legacy
   headers in Lineage 23.2" — if `camera.pepito` shares that breakage it won't compile and
   Option 0 is dead → go to Option 2. (It *did* build+run as of 2026-06-24 per device.mk,
   so expected to still build.)
2. **HAL swap mechanism (device-verified 2026-07-02):** `ro.hardware.camera` is **already
   set to `msm8937`** on-device and is immutable at runtime, so `setprop ro.hardware.camera
   pepito` will NOT work. The provider does `hw_get_module(CAMERA_HARDWARE_MODULE_ID)`
   (`hardware/lineage/interfaces/camera/aidl/provider/CameraProvider.cpp:191`) which resolves
   `camera.msm8937.so` — the only copy is `/odm/lib/hw/camera.msm8937.so` (the pepito
   overlay). Live test = **bind-mount `camera.pepito.so` over that path**
   (`mount --bind /data/local/tmp/camera.pepito.so /odm/lib/hw/camera.msm8937.so`), same
   technique as the Option-1 gralloc swaps; reverts on reboot.
3. Restart the provider (`setprop ctl.restart vendor.camera-provider` or the AIDL provider
   service). Checkpoints in order: enumeration still 2 + sane characteristics (proves
   cam_intf compat vs Palm's A8 daemon; garbled dims/metadata = struct mismatch → Option 2)
   → `configureStreams` gets real formats → `processCaptureRequest` without the `0x7C7C7C7C`
   poison → **first frame** (the true acceptance criterion — streaming has never been
   exercised on 4.19 by any path).

### Gralloc swap experiment (2026-06-29) — confirmed root cause + two-path catch-22

**Baseline confirmed (original A16 caf gralloc, `gralloc.msm8937.so` md5=`569b5ef1`):**
`configureStreamsPerfLocked` gets **real** framework formats (34=IMPLEMENTATION_DEFINED,
33=BLOB) and real dims — but when the stock HAL reads the **native buffer handle** at
`processCaptureRequest`, `iface_util_modify_plane_info_for_native_buf` gets
**`Invalid cam_format 2088533116`** (= `0x7C7C7C7C`, poison) →
`iface_util_calculate_frame_length_for_native_buf fail=-1` →
`iface_util_find_primary_cid: cannot find primary sensor format` → `start_channel -1` →
framework sees `Function not implemented (-38)`. The `0x7C7C7C7C` is NOT stale — confirmed live.

**Root cause = gralloc provenance mismatch (two independent buffer-read paths):**
- **Path A — modern wrapper** (`camera.device-impl.lineage.so` → `HandleImporter::importBuffer` →
  `GraphicBufferMapper` → HIDL `IMapper@2.0` → `mapper@2.0-impl-2.1.so` → `hw_get_module` →
  `gralloc.msm8937.so`): the AIDL→HAL3 shim imports framework buffers via the modern mapper.
  Works with A16's caf gralloc.
- **Path B — stock A8 HAL** (`camera.msm8937.so` / QCamera3HardwareInterface → reads
  `private_handle_t.format` directly at compiled-in A8 offsets): reads the same handle but at
  the WRONG offset → gets `0x7C7C7C7C` (a different field / uninitialized padding) → poison.
  The A8 HAL was compiled against an older `gralloc_priv.h` whose field layout differs from the
  caf source-built A16 gralloc.

**Swap experiment (bind-mounted A11's matched gralloc trio over A16):** A11's gralloc
(`gralloc.msm8937` + `libgrallocutils` + `libqdMetaData`, 32+64-bit) has a `private_handle_t`
layout compatible with the A8 HAL (same caf generation as A8) → would fix **Path B**. But it
**broke Path A**: A16's `mapper@2.0-impl-2.1` can't `hw_get_module` A11's gralloc (API mismatch
between caf generations) → `HIDL_FETCH_IMapper` fails → `IMapper::getService()` returns null →
`GraphicBufferMapper::GraphicBufferMapper()` aborts: **`gralloc-mapper is missing`** (SIGABRT at
`HandleImporter::importBufferInternal`). SurfaceFlinger **survived** the swap (pid stable),
and enumeration stayed at 2 — so display is not the constraint.

**Provenance evidence:** A16's `gralloc.msm8937.so` links `graphics.common@1.1` + `libion`
(caf source, no `libhardware`); A11's links `libhardware` + `libqdMetaData` (older caf, legacy
gralloc0 module present). Different md5, different deps, different `private_handle_t` generation.
A11 is itself a caf build (same `gralloc1::BufferManager` symbols) but an older generation whose
handle layout matches A8.

**Catch-22:** A16 gralloc fixes Path A (wrapper import) but breaks Path B (HAL reads poison);
A11 gralloc fixes Path B but breaks Path A (mapper@2.0-impl can't load it). Both paths must be
satisfied simultaneously.

### Option 1 — full A11 gralloc stack swap — ✅ TESTED, BLOCKED by display (2026-06-29)

Bind-mounted the **entire** matched A11 graphics set over A16 (gralloc trio + mapper@2.0-impl +
allocator@2.0-impl, 32+64-bit) and restarted the allocator (`vendor.gralloc-2-0`) so it picked
up A11's gralloc to produce A8-layout handles. The allocator service name is `vendor.gralloc-2-0`
(not `vendor.graphics.allocator-2-0` — that setprop silently fails).

**Camera-side results — best ever achieved:**
- `gralloc-mapper is missing` abort: **GONE** (A11's mapper@2.0-impl loads A11's gralloc fine)
- Camera open: **succeeds** (`rc: 0`)
- Session stability: **stable 2+ minutes, no CONNECT/DISCONNECT retry loop** (first time ever)
- `0x7C7C7C7C` poison: **not reached** (app stayed UNCONFIGURED — see below)
- `configureStreams` / `processCaptureRequest`: **not reached** — CameraX never sent them

**Why CameraX didn't configure streams:** the app opened the camera device but stalled in
`UNCONFIGURED` state. Likely because SurfaceFlinger was already broken (see below) so the
preview Surface was never ready, and CameraX won't configure streams until it has valid output
surfaces. Not a camera-side failure.

**Display-side failure — the blocker:**
- `qdgralloc: ImportBuffer: Unable to retain handle` — SurfaceFlinger (pid 987, still running
  with A16's gralloc in memory from before the swap) could not import buffers allocated by the
  new A11 allocator. Screen went **black**. `screencap` fails.
- Restarting SF would not help: A16's `hwcomposer.qcom` was built against the caf-source gralloc
  generation and can't import A11-layout handles either. SF would crash-loop.
- A11 uses `hwcomposer.msm8937.so` (different name = different binary); swapping HWC cascades
  into the EGL/GPU stack, and `PLAN-surfaceflinger.md` documents the GPU CP microcode must stay
  at the newer 4.19 versions — mixing A11 HWC with A16 GPU/EGL is high-risk.

**Verdict:** Option 1 is **blocked**. The camera side is fully satisfied by A11's gralloc
(stable session, mapper loads, no poison), but display cannot tolerate the swap. The end-state
fix must keep A16's gralloc for display/HWC and translate handles at the camera-HAL boundary
instead → **Option 2 is the path forward.**

**Rollback:** unmount all + reboot restored cleanly (md5 `569b5ef1` confirmed).

### Option 2 — build `camera.provider-service_32.lineage` from source + patch handle translation
*(❌ **OBSOLETE — 2026-07-02.** Option 0 eliminated the gralloc `0x7C7C7C7C` poison outright by
using the source-built HAL, so there is nothing left to translate. This whole section addressed a
problem that no longer exists. Kept only for history + the handle-layout facts. Do NOT pursue —
the remaining blocker is daemon ISP `find_primary_cid`, not buffer handles.)*

Build the AIDL→legacy HAL3 shim from source. Translate the `private_handle_t` fields from the
caf-source layout (what A16's gralloc produces) to the A8-expected layout (what the stock HAL
reads at compiled-in offsets) before passing handles to the stock HAL. This keeps A16's gralloc
(display stays working) and fixes the poison at the translation boundary.

**Shim source located (2026-07-02):** `hardware/lineage/interfaces/camera/aidl/` — buildable
in-tree (`provider/CameraProvider.cpp`, `device/CameraDeviceSession.cpp`; the buffer cache +
`sHandleImporter` live in `CameraDeviceSession.cpp:294/932/949`).

**⚠️ Design corrections from the 2026-07-02 review — the original spec had 4 flaws:**

1. **The premise is inferred, not proven.** Option 1 never reached `configureStreams` (CameraX
   stayed UNCONFIGURED because display died), so "A11-layout handles fix Path B" has never been
   *observed*. Before writing any code: dump raw handle ints for identically-parameterized
   allocations on A16 vs A11 (two-device method) and confirm which A16 field sits at the
   A8-compiled `format` offset — and that it plausibly explains `0x7C7C7C7C` (which smells like
   a fill pattern; if no offset accounts for it, the HAL may be reading a stale copy or
   out-of-bounds and translation alone won't fix it). This experiment also yields the exact
   translation table for free.
2. **`HandleImporter::importBuffer` is the wrong single patch point.** The cached imported
   handle is used in BOTH directions: passed to the legacy HAL *and* used by the shim's own
   mapper ops / returned to the framework in results. In-place translation would feed the modern
   mapper an A8-shaped handle it rejects. Correct design: a **shadow-handle pair** per cached
   buffer — keep the genuine imported handle for shim/mapper use; clone an A8-layout handle
   (dup'd fds) that goes only HAL-ward; reverse-map in the result path; free the shadow on
   `freeBuffer`/cache eviction.
3. **In-process mixed-consumer hazard.** The stock HAL `DT_NEED`s `libqdMetaData` (see the
   `libVDBeautyShotAPI` linker-config note in device.mk). If it calls A16's source-built
   `libqdMetaData` with an A8-shaped shadow handle, the same offset bug reappears one library
   down (metadata-fd/offset positions differ between generations). Need the stock A8
   `libqdMetaData` resolved in the stock HAL's linker namespace (odm overlay) while the rest of
   the process keeps A16's; audit the HAL3 path for any `hw_get_module(gralloc)` /
   `registerBuffer` calls too.
4. **Header corrections.** The A16 gralloc source is `hardware/qcom-caf/msm8953/display`
   (per `QCamera2/Android.bp` + the checked-out tree), **not** msm8998 as previously written.
   For the A8 target layout don't reverse-engineer the blob — the 8.1-era caf `gralloc_priv.h`
   is public (LineageOS lineage-15.1 display repo), and validate against a live handle hexdump
   on `android11-adb`. Also translate **usage semantics** (gralloc1 64-bit producer/consumer vs
   modern BufferUsage), not just field positions.

> ⚠️ **The live camera code is `techpack/camera-legacy/`, NOT `drivers/media/.../camera_v2/`.**
> Both compile, but the running path uses the `legacy_*` symbols (`legacy_msm_post_event`,
> `legacy_msm_create_session`, `legacy_camera_init_v4l2`) — confirmed via `/proc/kallsyms`.
> Editing/instrumenting `camera_v2/` does nothing at runtime. (Cost me a debug-build cycle.)

> Supersedes the failure analysis in [`PLAN-cameras.old.md`](PLAN-cameras.old.md). The
> blob/overlay/dlopen/provider plumbing documented there is correct and still in force —
> only its conclusion about *why the daemon session fails* (IMGLIB algo-lib / ION behavioral
> gap) is wrong. Keep that file for the Phase 1–5 plumbing history.

---

## TL;DR

| | A11 control `81eed371` (camera works) | A16 pepito `c39a6acf` (fails) |
|---|---|---|
| Kernel | stock **3.18.71** | **4.19.325** |
| Android / provider | A11 GSI, **HIDL `camera.provider@2.4`** (legacy API1 / HAL1) | A16, **AIDL `provider-service_32.lineage`** (API2 / HAL3) |
| `mm-qcamera-daemon` + camera libs | stock A8 | **byte-identical** stock A8 (74 libs audited) |
| media/v4l topology | video0=msm-config, video1/2=msm-sensor, media0-2 | **identical** |
| imglib topology (excluded modules) | trueportrait + oem1 | **identical** (trueportrait + oem1) |
| **Rear MCT `mct_controller_new` session-id** | **1** (then 2) | **0** |
| `module_imgbase_start_session` | succeeds | **`Invalid idx -1`** ×3 → session abort |
| `dumpsys media.camera` | 2 cameras | **0** |

**The only difference between working and broken is the session-id.** Everything else is
identical (same binaries, same libs, same topology, same media nodes).

---

## Root cause

QTI's imglib (`libmmcamera2_imglib_modules.so`) uses **session-id `0` as the empty-slot
sentinel** in its per-module session table. When the daemon creates the rear session with
**id 0**:

- generic `module_imgbase_start_session` can't find/allocate a slot → **`Invalid idx -1`**
  (×3, one per active generic imgbase module) → `start_session did not succeed on all
  modules` → `New session [0] creation failed` → the HAL's `NEW_SESSION` wait times out
  (`rc -110`) → framework enumerates **0** cameras.
- `module_faceproc_start_session` and `module_hdr_start_session` **override** the generic
  start_session and survive session-0 (`session cnt 1`) — which is exactly why only *some*
  imglib modules fail. This is the tell that it's per-module session-table handling, not a
  blob/ABI problem.

The working control (A11) never uses session-id 0 — a freshly-restarted A11 daemon's very
first session is **1**, and the same imgbase modules start cleanly.

### Why the session-id is 0 on A16

The MCT session-id equals the V4L2 session video-node number assigned by the kernel
`camera.c` open path: `event_data->session_id = pvdev->vdev->num` (and
`msm_create_session(pvdev->vdev->num, …)`), set in
`drivers/media/platform/msm/camera_v2/camera/camera.c`. On the control this path runs and the
rear session node is video1/video2 → session 1/2.

**On A16 that kernel path is bypassed entirely.** A live kprobe (mechanism verified — 193
hits on `do_sys_open`) shows that during an A16 camera open, **`msm_create_session` and
`msm_post_event` never fire** (0 hits, fresh daemon). So no kernel session is created; the
session-id is assigned in the closed-source daemon/HAL over the socket and defaults to the
**camera index (0 = rear)**.

This tracks the **provider / HAL-entry path** (the second variable that differs between the
two phones):

- A11 reaches the stock HAL through the **HIDL `camera.provider@2.4`** → legacy **API1 /
  HAL1** open. The kernel `camera.c` session path runs → session ≥ 1.
- A16 reaches the *same* stock HAL through the **AIDL `provider-service_32.lineage`** →
  **API2 / HAL3** open. The kernel session path does not run → session = camera-index = 0.

Likely contributing 4.19 factor: the media-controller backport. Sensor entities log
`msm 1b00000.qcom,msm-cam: Entity type for entity ov12a10 was not initialized!` because the
4.19 drivers set `entity.function = MSM_CAMERA_SUBDEV_*` (new media framework) rather than the
old `entity.type = MEDIA_ENT_T_V4L2_SUBDEV`. A malformed media graph can make
`camera_v4l2_open` bail before `msm_create_session`, which would explain the bypass. **Not yet
confirmed** — see Next Steps.

---

## Ruled out (with evidence)

- **IMGLIB / ION dma-buf ABI gap (the old theory): DISPROVEN.** Identical daemon binaries,
  identical libs, identical create_topology (both exclude trueportrait + oem1), identical
  media nodes — and yet one works and one doesn't, differing *only* in session-id.
- **Mixed nightly + A8 libraries: NO.** All 74 camera libs mapped by the A16 daemon+provider
  are byte-identical to the genuine A8 AML0 dump (32-bit), and to the vendor source tree.
  (The initial "7 mismatched" scare was a `find` artifact returning the dump's 64-bit copy.)
  Only `camera.device-impl.lineage.so` (the Lineage AIDL wrapper) correctly comes from the
  nightly.
- **ION heaps / dma-buf: NO.** Heap IDs are identical QTI values across 3.18/4.19. The daemon
  strace through a failed rear session shows **no failing ioctl**; the single error is a
  benign `/dev/media3 ENOENT` (the media-enumeration loop terminator, present on both phones).
- **DTS / clocks: NO.** Sensors probe (`ov12a10 probe succeeded`, `s5k4h8 probe succeeded`);
  the failure is in userspace MCT session creation, well past the hardware layer.
- **TZ / secure path: NO.** Non-secure preview/enumeration doesn't transit TZ; no SCM in the
  failing path.
- **Missing media/video nodes: NO.** A11 and A16 are identical (video0=msm-config,
  video1/2=msm-sensor, video32/33, media0-2).

---

## Layer 1 — session-id 0 — FIXED & flash-verified (2026-06-27)

**Correction to the earlier analysis above:** the live camera path is **`techpack/camera-legacy/`**
(the `legacy_*` symbols), not `drivers/media/.../camera_v2/`. Earlier kprobes on
`msm_create_session`/`msm_post_event` showed 0 hits and led me to believe the kernel session
path was bypassed — that was because those are the *dead* tree's symbols. The live path uses
`legacy_msm_create_session`/`legacy_msm_post_event`, and a debug kernel (FUNCTION_TRACER +
pr_info) confirmed: `camera_v4l2_open` *does* run, creates the session, and posts
`NEW_SESSION` with **`Evt_session_id=0`** for the rear.

Root-cause line, `techpack/camera-legacy/camera/camera.c`, `legacy_camera_init_v4l2()`:
```c
pvdev->session_id = camera_id;   // camera_id == sensor DT cell-index; rear = 0
```
`session_id` then flows into the `NEW_SESSION` event **and** `sensor_info->session_id` (so it
stays consistent). Rear cell-index 0 → session-id 0 → imglib `Invalid idx -1`.

**Fix applied (kernel-only, modern userspace untouched):**
```c
// FIRST attempt (2026-06-27) — SUPERSEDED, do not use:
//   pvdev->session_id = camera_id + 1;   // rear=1 OK by luck, front=3 broke cam_socket
// FINAL (2026-06-29), matches stock 3.18 exactly — assigned AFTER video_register_device:
pvdev->session_id = pvdev->vdev->num;     // rear=video1=1, front=video2=2; never 0
```
`camera_id+1` cleared the imglib `Invalid idx` but later broke the front camera: the daemon
names its HAL IPC socket `/data/vendor/camera/cam_socket<session_id>` and the HAL connects by the
**video-node number**, so front cell-index 2+1=3 ≠ video2 → `cam_socket` mismatch → mm_camera_open
"cannot open domain socket" → crash. `vdev->num` aligns both (and stock 3.18 reads `pvdev->vdev->num`
everywhere). See the RESOLUTION section at the top.

**Flash-verified:** boot probe logs `camera_id=0 -> session_id=1`, `camera_id=2 -> session_id=3`;
daemon creates `mct_controller … session-id 1`; **all** imglib modules start (`chroma_flash,
optizoom, ubifocus, refocus, paaf, quadracfa, stillmore, faceproc, hdr` = `session_cnt 1`);
`Invalid idx -1` **gone**. (Debug kernel also has `CONFIG_FUNCTION_TRACER` — keep for the rest
of the bring-up; both are `[TEMP][pepito]` to revert before merge.)

## Layer 2 — sensor MCT module missing — FIXED live (2026-06-27, needs staging)

**Root cause:** the camera-**image-sensor** MCT module's `module_sensor_init` fails for ov12a10
because two per-sensor blobs don't load:
- **Chromatix libs entirely missing.** The A8 dump has 27 `libchromatix_ov12a10_*.so` (1007
  total); **zero were staged** in the vendor tree or on device (only the chromatix *XMLs* were).
  → `addLib_getSymbol: fail : load_chromatix ov12a10_preview` → `module_sensor_init_chromatix:
  failed: create cm` → `module_sensor_init: failed`.
- **EEPROM lib path mismatch.** `libmmcamera_qtech_ov12a10_eeprom.so` is staged to `/odm/lib`
  (the overlay) but the daemon dlopens it by absolute path **`/system/vendor/lib/`**
  (=`/vendor/lib`) → `dlopen failed`. (Its dep `libmmcamera_eeprom_util.so` also needed there.)

A failed `module_sensor_init` → sensor module unregistered → absent from the session → the
`Null: 0x0` in the session-stream link.

**Fix (live-verified):** pushed the 27 ov12a10 (+23 s5k4h8) `libchromatix_*` + the eeprom libs to
`/vendor/lib`. Result: `module_sensor_init` succeeds, **`Session stream linked successfully`**,
**`Stop module name: sensor`** present. Layer 2 resolved.
**STAGED IN-TREE (2026-06-27):** 50 `libchromatix_{ov12a10,s5k4h8}_*.so` + `libmmcamera_eeprom_util.so`
copied to `vendor/xiaomi/Mi8937/proprietary/vendor/lib/`, added as `cc_prebuilt_library_shared`
modules (no `relative_install_path` → `/vendor/lib`) in `Android.bp`, listed in `Mi8937-vendor.mk`
`PRODUCT_PACKAGES`; the existing `pepito_libmmcamera_qtech_ov12a10_eeprom` module's
`relative_install_path` was removed so it installs to `/vendor/lib` (was `/odm` overlay).
**Bring-up debt:** these land in `/vendor/lib` for the whole Mi8937 target (not pepito-gated —
harmless, names are sensor-specific, but bloats siblings; gate behind `TARGET_DEVICE_PEPITO` later).
gc8034 (alt front) chromatix not staged — this unit probes s5k4h8; add if a gc8034 unit appears.

## Layer 3 — initCapabilities close-path crash — ✅ RESOLVED (2026-06-29, see RESOLUTION at top)

> **Resolved by two fixes:** (a) the OTP `-1` was a missing kernel cfgtype `CFG_SENSOR_OTP_UPDATE`
> (fix #2), and (b) the close-crash itself was the "jinghuang" `camera_open` dlopen of
> `libqti-perfd-client.so` failing → null handle → close deref; fixed by the no-op perf stub
> (fix #4). The detailed investigation below remains accurate as history; the "definitive next
> step" (CCI byte-dump) was done and led to the strace that found the `VIDIOC_MSM_SENSOR_CFG`
> EFAULT → the missing cfgtype.

With the session linking, the provider's capability query now crashes:
```
QCamera3HardwareInterface::initCapabilities()  ->  getCamInfo  ->
mm_camera_intf_close+50  ->  pc 00000000  (SIGSEGV, null function-pointer call)
```
i.e. the cap query opens the camera, the open partially fails, and the **cleanup `close`
derefs a null op** on the half-initialized camera object → provider dies → `dumpsys` still 0,
retry loop. Triggers in the lead-up (still blob/calibration gaps):
- `sensor … oxygen_ov12a_sunny otp init error: -1` — the ov12a10 **OTP/EEPROM read** fails
  (eeprom lib now loads, but the OTP read returns -1; note sensor module variant name is
  `oxygen_ov12a_sunny` vs eeprom config `qtech_ov12a10` — possible module/cal mismatch).
- `sensor_get_cur_chromatix_name_for_type: … module = 4 chromatix_type = 0 is NULL` — a
  specific chromatix (module 4 / a use-case) still resolves NULL despite staging the set.
- `stats_port_check_caps_reserve: Invalid Port capability type` (×5; may be benign).

**ROOT CAUSE = the OTP read failing (confirmed by A11 comparison, 2026-06-27):**
- **A11 (works):** sensor inits clean (`sensor_get_resolution_info: name oxygen_ov12a_sunny …`),
  **no OTP error**, and `mm_camera_intf_close:445: jinghuang,close handle of lib` runs and
  **succeeds** → `getCamInfo … resource cost 100` → **2 cameras**.
- **A16 (fails):** `oxygen_ov12a_sunny otp init error: -1` → a per-camera lib handle is left
  null → **Palm's `jinghuang` patch in `mm_camera_intf_close`** (it `dlclose`s a "handle of
  lib") calls that null pointer → **SIGSEGV pc=0** → provider dies → 0 cameras.

So the close-crash is a *symptom*: Palm's stock HAL/interface `close` patch assumes the open
fully succeeded; the OTP failure breaks that assumption. We can't patch the blob → **the fix is
to make the OTP read succeed.**

**The OTP failure is USERSPACE, not the kernel:** dmesg during the open shows the kernel CCI/I2C
path is healthy — `msm_cci_init hw_version=0x10020004`, sensor+actuator regulators power up,
**zero I2C errors/timeouts/nacks**. So the sensor blob's OTP read returns -1 without the kernel
ever erroring (the same blob succeeds on A11/3.18). `Invalid addr_type=0 / data_type=0` lines
accompany it (likely settings-array terminators; may be benign). The `module 4 chromatix_type 0
is NULL` is almost certainly **benign** — it's a chromatix-XML name gap shared with stock (same
XML on A11, which works).

**Next (no build needed first):**
1. Determine whether ov12a10's OTP is actually populated/readable and *how* stock reads it —
   trace the OTP I2C transactions on A16 (CCI ftrace / `persist.camera.sensor.debug`) and see
   what the sensor returns vs what the lib expects (-1 = data invalid vs read-not-issued).
2. Check the sensor **state/sequence** when OTP is read (streaming on? right register page?) —
   a 4.19 power/stream-timing difference vs 3.18 is the leading hypothesis since the blob+config
   are identical to the working A11.
3. If OTP is genuinely empty/unreadable on this unit, see how stock tolerates it (A11 doesn't
   error) — there may be an OTP-disable/skip path or config.

**Further narrowing (2026-06-27 cont.) — ruled out:**
- **Not a CCI transfer-size diff:** the kernel CCI read path is identical 4.19 vs 3.18
  (`CCI_READ_MAX 12`, `CCI_I2C_MAX_READ 8192`; only cosmetic diffs). (Note: 4.19 has 3 camera
  trees — `camera_v2`, `techpack/camera-legacy`, `techpack/camera-legacy-m`; the live one is
  `techpack/camera-legacy` per kallsyms.)
- **eeprom basic read works:** `eeprom_open: Enter/Exit` succeeds and the lib reads status+date
  (writes `persist.camera.otp.status=ok`, `persist.camera.otp.date.main=20181005` — these props
  are lib *outputs*/symptoms, sticky; A11 leaves them empty). So small I2C reads succeed; the
  **`sunny_8865` calibration-data OTP processing** is what returns -1.
- **OTP-bypass via config does NOT work:** removing `<EepromName>qtech_ov12a10</EepromName>`
  from `camera_config.xml` did not skip the OTP — `otp init error -1` still fires. So the OTP
  read is **intrinsic to the sensor blob's `oxygen_ov12a_sunny` module handling**, not
  config-driven.
- OTP detail isn't loggable at `persist.camera.sensor.debug=4` (the `DEBUGOTP` lines are
  `<SENSOR>< LOW>`), and host `objdump` can't disassemble ARM.

**Definitive next step (needs a debug kernel build):** add `pr_info` in the live CCI read path
(`techpack/camera-legacy*/sensor/cci/msm_cci.c`, `msm_cci_i2c_read_bytes`) to dump the bytes
returned for the ov12a10 OTP/eeprom reads, and compare against what `sunny_8865` expects (and/or
A11). This distinguishes "I2C returns garbage on 4.19" from "data valid but a blob check rejects
it", which decides whether the fix is kernel (CCI read data) or a calibration/sequence issue.
Alternative: disassemble `sunny_8865_read_otp` with `llvm-objdump`/arm-objdump to find the exact
-1 return.

## (superseded) Layer 2 original note

With layer 1 fixed the session proceeds to **stream linking** and fails there:
```
mct_stream_start_link: Start linking Session-stream 0x1000f
mct_stream_link_module_array: Null: 0x0     -> link failed
-> HAL camera_open "jinghuang:error"
-> QCamera3HardwareInterface::initCapabilities() CRASHES (tombstone +454)
-> provider dies -> dumpsys media.camera still 0
```
Module-set comparison (same daemon/MCT/HAL blobs both sides) pinpoints the `Null`:
- **A11 (works):** iface, isp, stats, pproc, imglib, **`sensor`** (6) → `Session stream linked successfully`
- **A16 (fails):** iface, isp, stats, pproc, imglib (5) — **no `sensor`**

So the **camera-sensor MCT module isn't attaching to the session** on A16 → it's the `Null`
in the link chain (sensor→iface→isp→stats→pproc→imglib). The `initCapabilities` crash is a
downstream symptom (the stock HAL doesn't handle the link failure). **NOTE:** this "sensor" is
the **image-sensor MCT module** (libmmcamera2_sensor_modules.so, OV12A10/S5K4H8) — *not* the
ADSP motion/environmental sensors in `PLAN-sensors.md` (accel/gyro/etc. via SMGR/SSC/QMI).
Different subsystem entirely; `PLAN-sensors.md` is unrelated.

Open question: is the sensor-module non-attachment a side-effect of the session-id offset (the
daemon's sensor↔session matching) or an independent sensor-module init/attach gap on 4.19?
**Next:** capture daemon startup + sensor enumeration with higher verbosity on A16 vs A11 —
does the sensor module init, and what session_id does it bind to? (no build needed). See the
cookbook below.

## Kernel camera support is correct for pepito's cameras — verified

Legitimate concern: the 4.19 Mi8937 kernel is built for the **MSM8940 chipset**, not for
pepito's specific cameras, and "siblings stream fine" is weak evidence because land/santoni/ugg
have *different* sensors. A sensor *probe* (I2C ID read) only proves power + slave-addr + CCI,
not streaming. So: does Palm's custom stock 3.18/3.19 kernel contain device-specific camera
drivers we failed to port? **Checked against the stock GPL source + decompiled stock DTB —
answer: no.**

- **No custom/dedicated sensor drivers in stock.** Stock `…/camera_v2/sensor/` has only the
  **generic** `msm_sensor.c` / `msm_sensor_driver.c` / `msm_sensor_init.c` + generic
  `msm_eeprom.c`. There is **no** `ov12a10.c` / `s5k4h8.c` / `gc8034.c`. And **zero**
  `pepito`/`palm`/`pvg100` strings anywhere in the stock `camera_v2` tree → Palm shipped
  vanilla QTI generic, data-driven drivers, not per-device patches. There is no kernel
  "OV12A10 driver" to miss — only a DT node + a userspace lib.
- **The architecture is data-driven:** the generic `msm_sensor` driver reads all
  device-specific values (power rails, GPIOs, MCLK rates, CCI master, slave addr, CSI/CSID
  index) from the **device tree**; sensor register tables + CSI lane mapping live in
  **userspace** (`libmmcamera_<sensor>.so` + `camera_config.xml`).
- **Our 4.19 `pepito/camera.dtsi` is a field-for-field match to the stock DTB** (verified
  against `dts-3.19-pepito/pepito.dts`):

  | Property | Stock 3.18/3.19 DTB | 4.19 `camera.dtsi` |
  |---|---|---|
  | Rear `cci-master` / `csiphy` / `csid` | 1 / 0 / 0 | 1 / 0 / 0 |
  | Rear `mount-angle` | 0x5a (90°) | 90 |
  | Rear MCLK `clock-rates` | 0x16e3600 (24 MHz) | 24000000 |
  | Front `cci-master` / `csiphy` / `csid` | 0 / 1 / 1 | 0 / 1 / 1 |
  | Front `mount-angle` | 0x10e (270°) | 270 |
  | Front MCLK | 24 MHz | 24000000 |
  | EEPROM MCLK | 0x124f800 (19.2 MHz) | 19200000 |

  (Regulators `pm8937_l22/l23/l6/l17`, GPIOs 26/36/35/62/68 also match.) The dtsi also
  deliberately uses the **downstream MSM clock framework** (`clk_mclk0_clk_src`), not the
  mainline CCF path the siblings use — which is why CSID actually powers up.
- **CSI lane config** is in neither DTS — it comes from **Palm's stock `camera_config.xml`**
  (extracted, byte-identical A8, in use). Userspace sensor libs are Palm's stock A8 too
  (audited byte-identical).
- **Live hardware confirms it:** both sensors probe with correct chip IDs (`ov12a10 id 0x1241`,
  `s5k4h8`), CSID reads HW version `0x30040002`, CPP reads `0x40030002`, **zero** kernel
  camera errors except the userspace `NEW_SESSION rc -110`. (This also resolves the old
  `PLAN-cameras.old.md` "CPP `stream_cnt:0`" puzzle — the session dies before any stream is
  added.)

**Residual (honest):** live *streaming* (sensor → CSIPHY lane-lock → CSID → VFE SOF → frame)
is **not yet exercised**, because the session-id bug aborts at `start_session`, upstream of
stream-on — so no frames are produced and there is nothing to capture from the raw video nodes
yet (and the MSM `camera_v2` stack can't be driven like a plain V4L2 device regardless). There
is, however, **no kernel-side reason to expect streaming to fail**: every static config matches
the kernel that streams these exact sensors, and the silicon powers up and probes. The real
frame test is the **acceptance criterion of the session-id fix**.

**GC8034 caveat:** the 4.19 tree carries Xiaomi's `xiaomi_tiare_gc8034.c` (for another device)
and stock used the generic path; but this unit's front probed as **S5K4H8** (generic) and the
rear is **OV12A10** (generic), so GC8034 is not in play here.

## No userspace workaround exists

Tested live: bind-mounted an empty file over every generic imgbase algo impl lib
(`libmmcamera_chromaflash_lib`, `liboptizoom`, `libseemore`, `libubifocus`,
`libmmcamera_{optizoom,stillmore,ubifocus,quadracfa,paaf,dcrf}_lib`, `libremosaic_daemon`,
`libmmcamera_sw2d_lib`) so `create_topology` drops those modules (as the control does for
trueportrait/oem1).

Result: `Invalid idx -1` **disappeared**, but session-0 then failed one level deeper —
`module_imglib_set_session_data: Invalid input … 0x0` → `mct_stream_link_module_array: Null:
0x0` → `mct_stream_start_link: link failed` → `New session [0] creation failed`. **imglib
rejects session-0 at the core stream-link stage too.** Reverted cleanly (bind mounts only;
gone on reboot). Conclusion: the fix must make the session-id ≥ 1.

---

## Fix candidates (SUPERSEDED — historical; the actual fix was none of these)

> ⚠️ **Superseded by the RESOLUTION section at the top.** These were written when the session-0
> bypass was misunderstood. The real fix kept the **modern AIDL/HAL3** path (candidate #1, the
> HIDL/HAL1 route, was explicitly **rejected** — the user wanted modern userspace) and instead
> corrected the kernel session-id to `vdev->num` (candidate #3 done right) + the OTP cfgtype +
> perf stub + HAL3 prop. Candidate #2 (media-controller backport) was not needed. Kept for history.

1. **Drive the stock HAL via the legacy HAL1 path — match the control (RECOMMENDED first).**
   Use the HIDL `camera.provider@2.4` / legacy API1 route (what A11 uses) instead of the AIDL
   `provider-service_32.lineage`. If the HAL1 open engages the kernel `camera.c` session path,
   the session becomes ≥ 1 and imglib accepts it. Buildable via the camera provider + VINTF
   manifest config in `device/xiaomi/mithorium-common`. Highest-likelihood; replicates the
   known-good device.
2. **Fix the 4.19 `camera_v2` / media-controller backport** so `camera_v4l2_open` completes
   and calls `msm_create_session` (session = `pvdev->vdev->num` ≥ 1). Start at the
   `Entity type … not initialized` warning (`media-device.c:615`) — restore correct
   entity.function/links so the graph is well-formed and the open doesn't bail. Kernel change.
3. **Force the session-id ≥ 1** at the assignment site once located (kernel `camera.c`/`msm.c`
   if the path is made to run, or a daemon-side offset if it remains socket-sourced). Blunt
   fallback.

> Note: the rear *must* remain framework camera-id 0 (back-camera convention), so the fix has
> to decouple session-id from camera-index — it cannot simply renumber the cameras.

---

## Next steps

1. **Pin the bypass** (decides fix #1 vs #2, no build needed):
   - Confirm whether the HAL's `/dev/video1` open *succeeds or bails* on A16, and whether
     `camera_v4l2_open` reaches `msm_create_session`. Trace the kprobe-able functions in the
     open path; if needed, a one-line `pr_info` debug kernel in `camera_v4l2_open` logging the
     bail point + `vdev->num` is definitive.
   - Inspect the live media graph (`MEDIA_IOC_ENUM_ENTITIES` / links) for the rear sensor on
     A16 vs A11 to confirm/deny the entity-graph hypothesis.
2. **Try fix #1** (HIDL `camera.provider@2.4` / HAL1) on a build and re-test `dumpsys
   media.camera` + a rear preview/capture. If session-id becomes ≥ 1 and the camera
   enumerates, this is the fix.
3. If #1 doesn't engage the kernel session path, do fix #2 (media-controller / camera_v2).
4. After enumeration works, validate the **full pipeline** on a non-zero session (preview →
   capture). The control runs full imglib on session 1/2, so this is expected to work, but it
   has never been exercised on the 4.19 path.

---

## Reproduction & investigation cookbook

Two rooted PVG-100 on the bench: `android11-adb` (`81eed371`, stock 3.18, **camera works** —
ground truth, Enforcing so kprobe blocked) and `android16-adb` (`c39a6acf`, 4.19 bringup,
Permissive). Both need `adb root`. The device shell is mksh — **push scripts as files**;
complex inline `adb shell '…'` with pipes/`$vars`/`echo` gets mangled.

**Reproduce the failure + read the session-id (A16):**
```sh
# fresh daemon, then provider; the rear cap-query session reproduces the failure
setprop ctl.stop vendor.camera.provider; sleep 1
setprop ctl.restart vendor.qcamerasvr;   sleep 3
logcat -c; setprop ctl.start vendor.camera.provider; sleep 10
logcat -d -b all | grep -E "mct_controller_new: Creating|Invalid idx|New session.*creation failed|num_cameras"
# A16 -> "session-id 0" + "Invalid idx -1"; A11 (via camera app) -> "session-id 1"/"2", no idx error
```

**Confirm the kernel session path is bypassed (A16, Permissive):**
```sh
T=/sys/kernel/tracing
echo 'p:mcs msm_create_session sid=%x0' > $T/kprobe_events
echo 1 > $T/events/kprobes/mcs/enable; echo 1 > $T/tracing_on
setprop ctl.restart vendor.camera.provider; sleep 8; echo 0 > $T/tracing_on
grep -c mcs $T/trace        # -> 0 hits on A16, despite a session being created
# sanity: 'p:popen do_sys_open' fires ~hundreds of times => kprobe mechanism is good
```

**Audit lib provenance (rule out nightly contamination):** dump `/proc/<daemon-pid>/maps`
`.so` list, `md5sum` each, compare against
`backup-stock-android-8.1-AML0/vendor.bin.extracted/lib/<name>` (force the **32-bit** path —
`find` may return the lib64 copy) and `/mnt/vendor-nightly`.

**Key live signatures:**
- Working (A11): `mct_controller_new: Creating new mct_controller with session-id 1`
- Broken (A16): `session-id 0` → `module_imgbase_start_session: Invalid idx -1` →
  `mct_pipeline_start_session: start_session did not succeed on all modules`
- After masking algo libs (A16): `module_imglib_set_session_data: Invalid input …0x0` →
  `mct_stream_start_link: link failed` (proves session-0 rejected at the stream-link core)
- Kernel (both): `Entity type for entity ov12a10 was not initialized!`

---

## Key source locations

- `kernel/xiaomi/msm8937/drivers/media/platform/msm/camera_v2/camera/camera.c`
  — `camera_pack_event()` (`event_data->session_id = pvdev->vdev->num`),
  `camera_v4l2_open()` → `msm_create_session(pvdev->vdev->num, …)`; "msm-sensor" node reg.
- `…/camera_v2/msm.c` — `msm_create_session()`, "msm-config" node reg, event plumbing.
- `…/camera_v2/sensor/msm_sensor_driver.c` — sets `entity.function = MSM_CAMERA_SUBDEV_SENSOR`.
- `kernel/xiaomi/msm8937/drivers/media/media-device.c:615` — `Entity type … not initialized`
  warning (`function == MEDIA_ENT_F_*_UNKNOWN`).
- Reference 3.18 source for diffing: `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/…`
- imglib blob (module list / no module-disable knob, only `g_imgLogModuleMask`):
  `vendor/xiaomi/Mi8937/proprietary/vendor/lib/overlayfs/pepito/libmmcamera2_imglib_modules.so`
  — modules: `imglib_{chroma_flash,dcrf,denoise,faceproc,oem1,optizoom,refocus,stillmore,trueportrait,ubifocus}`.

---

## Cross-references

- `PLAN-cameras.old.md` — Phase 1–5 plumbing (DTS sensor nodes, blob extraction, overlayfs,
  dlopen chain, linker namespace, SELinux). Plumbing valid; failure analysis superseded here.
- `PLAN.md` "Holistic cross-cutting analysis" — camera = **Cluster C** (stock A8 blobs on the
  4.19 kernel). Confirmed: it *is* a kernel-ABI/path issue, specifically the V4L2 session
  path, not ION/dma-buf.
- Memory: `project-camera-session-id-rootcause.md`; two-device methodology in `PLAN.md`.
