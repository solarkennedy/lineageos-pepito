# Pepito Camera Bring-up Plan

> ⚠️ **SUPERSEDED (2026-06-27):** the failure analysis in this file (IMGLIB algo-lib /
> ION dma-buf behavioral gap) is **wrong** — root cause is now [`PLAN-camera.md`](PLAN-camera.md):
> the rear MCT **session-id is 0**, which QTI imglib rejects. The Phase 1–5 plumbing below
> (DTS, blobs, overlayfs, dlopen chain, linker, SELinux) is still valid and in force.

**Hardware:** Palm PVG100 (MSM8940 / Adreno 505)
**Stack target:** stock Palm AML0 `camera.msm8937` HAL + stock interface blobs via pepito overlayfs + Lineage camera provider

> **Cross-ref (2026-06-26 holistic session):** camera is **Cluster C** in `PLAN.md`
> "Holistic cross-cutting analysis" — a stock-Palm-Android-8-blob-on-4.19-kernel ABI gap
> (the IMGLIB `Invalid idx -1` is an ION/dma-buf / MCT-cleanup behavioral diff vs 3.18, not
> a missing blob and not a clock/DTS issue). It is independent of the radio/GPS/sensors QMI
> work; the lever is the two-device methodology at the ioctl/dma-buf level (what cracked
> RPMB in `PLAN-gatekeeper.md`).
**Current status:** ⚠️ Stock-HAL HAL load chain is **fully fixed** — provider no longer crashes, daemon runs, and the stock HAL reports `num_cameras=2`. The remaining blocker is **daemon-side IMGLIB MCT session creation** (`module_imgbase_start_session: Invalid idx -1` → `New session [0] creation failed`), which makes framework enumeration report 0. As of 2026-06-24 this is **proven to be environmental, not a missing blob** (see update below).

> **2026-06-24 update #2 — IMGLIB blocker is environmental; missing libs are a RED HERRING.**
> Using the working Android 11 GSI control phone (stock AML0 vendor, cameras work) as
> reference, established:
> - **`libmmcamera_imglib.so` and `libmmcamera2_imglib_modules.so` are byte-identical
>   (md5 match) between pepito and the working control.** (`e6de3a85…`, `14cbda10…`)
> - **The 4 "missing" algo libs (`libllvd_smore.so`, `libmmcamera_ppeiscore.so`,
>   `libmmcamera_sw_tnr.so`, `libmmcamera_edgesmooth_lib.so`) are absent on the control
>   too**, yet its camera works. Same wrapper libs (`libmmcamera_llvd.so`,
>   `libmmcamera_trueportrait_lib.so`) with the same unresolved impls on both. So the
>   missing libs do **not** cause the failure.
> - Therefore the difference is the runtime environment: **Android 16 + 4.19 kernel
>   (pepito) vs Android 11 + 3.18 kernel (control)** running the *same* daemon binaries.
>
> Failure mechanism on pepito (daemon `module_imglib_create_topology`):
> - `ppeiscore`/`llvd`/`sw_tnr` fail to load their impl libs — **non-fatal** (logged but
>   topology continues; control behaves the same).
> - `imglib_trueportrait` was fatal until `libtrueportrait.so` (from `system.bin` dump)
>   was added live — that cleared the trueportrait "Can not init".
> - **`imglib_oem1` (`module_oem_feat1_init`) is the sole remaining fatal module.** It
>   fails with **no preceding dlopen error** — its lib loads (only a benign
>   "img_algo_post_process can be NULL" warning), but `oem_feat1_init` returns failure.
>   The identical binary succeeds on the control. Each failed module is left in the
>   topology with idx -1, so `module_imgbase_start_session` hits `Invalid idx -1` and the
>   whole MCT session creation aborts.
>
> Dead ends ruled out: providing the missing libs (not the cause); `dummyalgo` stubs for
> the missing frameproc libs (made dlopen succeed but registered bad indices → *more*
> `Invalid idx -1`; reverted).
>
> **Answered via control capture (fresh daemon restart pid 21060 + real picture, full
> IMGLIB verbosity `logmask 0xffffffff`):** the control logs **zero** `create_topology`,
> `module_imgbase_init`, `Can not init`, or `imglib_oem1` lines. Its working session shows
> `mct_stream_start_link: iface=0x0, isp=0x0, pproc=0xf48c2850, imglib=0x0` — **imglib is
> not engaged in the pipeline at all** (`imglib=0x0`). The control's camera works with
> imglib effectively bypassed; the same benign imglib errors appear (`AllocateBuffers:
> Invalid dimensions 0x0`, faceproc "Library not loaded") but are non-fatal because imglib
> isn't in the pipeline.
>
> **So the real difference:** on pepito, opening the camera (even the HAL's
> `initCapabilities` capability-query `camera_open`) creates an MCT session that **engages
> imglib**, calls `module_imglib_start_session`, which fails (`Invalid idx -1` from the
> idx-(-1) modules) and aborts the whole session (`start_session did not succeed on all
> modules` → `New session [0] creation failed` → daemon never ACKs → kernel
> `NEW_SESSION ... rc -110` timeout). On the control the same open does **not** make imglib
> mandatory. Why imglib is mandatory/engaged in pepito's session but bypassed on the
> control — with identical daemon binaries — is the open question. Leading theory: a subtle
> difference in MCT pipeline assembly driven by the Android-16 userspace or 4.19-kernel
> ISP/sensor sub-module reporting, causing imglib to be linked into the session topology.
>
> No imglib property knob disables `oem1`/the topology wholesale (checked strings: only
> per-feature flags like `camera.llvd.preview.disable`, `persist.camera.imglib.tp.*`,
> `persist.camera.feature.cac`, `ea_bypass`/`force_ea` — none gate oem1 or topology
> inclusion). Could not read the control daemon's `/proc/<pid>/maps` (SELinux denied).
>
> **DEFINITIVE mechanism (captured control daemon startup with correct log timing —
> clear-before-restart):** The control's daemon `server_process_module_init` →
> `module_imglib_create_topology` logs the **identical** failures to pepito:
> ```text
> cannot load libmmcamera_ppeiscore.so / libmmcamera_llvd.so / libmmcamera_sw_tnr.so
> cannot load libmmcamera_trueportrait_lib.so   (control lacks libtrueportrait.so)
> module_imglib_create_topology: Can not init the module imglib_trueportrait
> module_imglib_create_topology: Can not init the module imglib_oem1
> ```
> The control fails **more** modules than pepito (it also fails `trueportrait`; pepito
> now passes it since `libtrueportrait.so` was added) — **yet the control's camera works.**
> So `create_topology` "Can not init" is conclusively **non-fatal**.
>
> The divergence is entirely in **`module_imglib_start_session`** (per-session, at
> `camera_open`):
> - **Control:** `module_imgbase_start_session` returns `session_cnt 1` (valid) for the
>   modules whose impl libs are present — `imglib_chroma_flash`, `imglib_optizoom`,
>   `imglib_refocus`, `imglib_stillmore`, `imglib_ubifocus`, `paaf`, `quadracfa` — and the
>   failed modules are simply **excluded**. Session starts; camera works (with
>   `mct_stream_start_link … imglib=0x0`, i.e. imglib not bound into the stream).
> - **Pepito:** `module_imgbase_start_session: Invalid idx -1` (×4–5) → `module_imglib_
>   start_session: Can not start the session` → `mct_pipeline_start_session: start_session
>   did not succeed on all modules` → `New session [0] creation failed`. The failed
>   modules are **retained with idx -1** instead of excluded, so start_session aborts.
>   (`moduleMask` is `65535` on BOTH — not the difference.)
> - Verified all impl libs for the "works-on-control" modules (`optizoom`, `stillmore`,
>   `ubifocus`, `chromaflash`, `paaf`, `quadracfa`, `dcrf`) have **all DT_NEEDED resolvable
>   on pepito** — so it is not a secondary namespace/dlopen gap.
>
> **Conclusion:** identical daemon binaries + identical create_topology failures, but
> pepito's `start_session` treats idx-(-1) modules as fatal while the control excludes
> them. This is an **environmental behavioral difference** (Android 16 userspace / 4.19
> legacy-camera kernel vs Android 11 / 3.18), not a missing blob and not a config knob
> found so far. Plausible root: ION/dma-buf `img_algo_preload`/`AllocateBuffers` behavior
> on 4.19 (the control logs `AllocateBuffers: Invalid dimensions 0x0` / `preload … rc -4`
> as non-fatal), or MCT module-list cleanup differing under the backported legacy camera
> path. Needs daemon-level tracing (strace/gdb) or a targeted kernel-side comparison —
> beyond live lib-swapping.
>
> Candidate fixes once that's known: (a) find a way to disable the `oem1`/AOST imglib
> feature so it's excluded from the topology (chromatix/feature flag/property); (b) treat
> as an Android-16/4.19 ABI issue in the imglib dependency chain. Live-pushed real libs
> currently in pepito's overlay lowerdir (not yet in the build): `libtrueportrait.so`,
> `libsdm-color.so`, `libtinyxml2_1.so`.

> **2026-06-24 update #1 — provider dlopen chain (RESOLVED, see below):** Stock-HAL
> experiment built/flashed. The provider SIGSEGV was root-caused to `camera.msm8937.so`
> failing to `dlopen`; a chain of missing/unreachable dependency libs was resolved one
> link at a time, ending with `libstdc++.so`. The provider now loads cleanly.

> **2026-06-24 update — provider SIGSEGV root-caused to dlopen failure chain:**
> The SIGSEGV (`CameraModule::notifyDeviceStateChange+4`, null `mModule` at +0x8)
> is a *symptom*: `camera.msm8937.so` never loads, so `mModule` stays null, and the
> first device-state callback from `cameraserver` derefs null. The real error is in
> the dlopen, surfaced via `vndksupport`:
> ```text
> E vndksupport: Could not load /odm/lib/hw/camera.msm8937.so from default namespace:
>   dlopen failed: library "<lib>" not found: needed by <dep> in namespace (default).
> E CamPrvdr: Could not load camera HAL module: -22 (Invalid argument)
> ```
> Stock AML0 (Android 8.1) blobs reference libs that are either removed from modern
> Android or not exposed to the vendor linker namespace. Fixes applied in order, each
> advancing the dlopen one DT_NEEDED further:
>
> 1. **`/odm/lib` overlay never mounted** → `libmmcamera2_mct.so not found`. Root cause:
>    `/vendor/odm/lib` mountpoint dir didn't exist (nothing installed there directly).
>    Fix: install `$(TARGET_COPY_OUT_ODM)/lib/.placeholder` (device.mk). Overlay now
>    mounts; all three overlays (`/odm/bin`, `/odm/lib`, `/odm/etc/camera`) active. ✅
> 2. **`libandroid.so` + `libjnigraphics.so` not in vendor namespace** → needed by
>    `libVDBeautyShotAPI.so` (a `DT_NEEDED` of `camera.msm8937.so`). Fix: vendor
>    `linker.config.json` `requireLibs` via `PRODUCT_VENDOR_LINKER_CONFIG_FRAGMENTS`. ✅
> 3. **`libstdc++.so` not in vendor namespace** → needed by `libTsProcess.so`.
>    *First attempt:* added to `requireLibs` — **did not work.** `requireLibs` only
>    exposes libs that some namespace *provides* to vendor; `libandroid`/`libjnigraphics`
>    are provided (verified: 21 occurrences in `/linkerconfig/ld.config.txt`), but
>    `libstdc++.so` is a deprecated stub the system does not provide to vendor, so the
>    require is silently dropped (0 occurrences). *Working fix:* **bundle** the stock
>    8.1 `libstdc++.so` (from `system.bin.extracted/lib/`, 32-bit ARM, `DT_NEEDED` only
>    `libc.so`, exports `_Znwj`/`_ZdlPv` etc.) into the pepito overlay so it resolves
>    in-namespace at `/odm/lib/libstdc++.so`, same as the other camera blobs
>    (`pepito_libstdcpp` module). Reverted the `requireLibs` entry. ⏳ (flashing now)
>
> **Verified before flash:** the full transitive `DT_NEEDED` closure of
> `camera.msm8937.so` resolves after fix 3 — no `UNRESOLVED` entries, and none of the
> 4 truly-missing libs (below) appear in it. So fix 3 should be the last blocker for
> the provider to load, set `mModule`, stop the SIGSEGV loop, register, and enumerate.
>
> **Separately deferred — 4 libs missing from the AML0 dump entirely**, only `dlopen`'d
> by the *daemon's* algo modules during pipeline init (NOT in the provider's HAL load
> chain, so they do not block provider startup or basic enumeration):
> | Missing lib | Needed by (overlay lib) | Effect if absent |
> |---|---|---|
> | `libtinyxml2_1.so` | `libhdr_tm.so` | trivially a versioned alias of `libtinyxml2.so` (present) → symlink/shim |
> | `libsdm-color.so` | `libhdr_tm.so` | QTI display-color lib; likely obtainable from a Xiaomi/QTI vendor dump |
> | `libllvd_smore.so` | `libmmcamera_llvd.so` | LLVD low-light algo; stock AML0 tolerated absence |
> | `libtrueportrait.so` | `libmmcamera_trueportrait_lib.so` | TruePortrait algo; stock AML0 tolerated absence |
> These likely map onto the original `module_imgbase_start_session: Invalid idx -1`
> daemon failure — the imgbase submodules fail init when their algo impl `dlopen`s
> fail. Resolve after the provider is confirmed loading.

> **2026-06-23 update (superseded by 06-24 above):** On the now-fully-booting build
> (RPMB + GPU regressions fixed; see `PLAN.md`), the camera **provider service
> crash-loops** with a SIGSEGV (`CameraModule::notifyDeviceStateChange+4`, null deref
> at +0x8). Originally read as "module open returned nothing"; 06-24 confirmed the
> module open fails because the `dlopen` of `camera.msm8937.so` fails on a missing
> dependency lib (see chain above), not because enumeration returned zero.

Last Lineage 23 source-HAL flash findings:
- Device boots as `model:PVG100 device:pepito`; `sys.boot_completed=1`.
- `ro.hardware.camera=pepito` is active.
- Pepito overlayfs mounts are active for `/vendor/odm/bin`, `/vendor/odm/lib`, and `/vendor/odm/etc/camera`.
- ICU bind mounts are active for stock 32-bit camera blobs under `/vendor/odm/lib`.
- `/data/vendor/qcam` is a symlink to `/data/vendor/camera`, matching the Lineage HAL socket path to the stock daemon path.
- `cameraserver`, `android.hardware.camera.provider-service_32.lineage`, and `mm-qcamera-daemon` start.
- `dumpsys media.camera` still reports `Number of camera devices: 0`.
- The active provider maps `/vendor/odm/lib/hw/camera.pepito.so`, `/vendor/odm/lib/libPmcamera_interface.so`, `/vendor/odm/lib/libPmjpeg_interface.so`, and `/vendor/odm/lib/libPomx_core.so`.
- HAL enumeration reports two cameras and sorts them as rear logical id 0 and front logical id 1; opening rear id 0 uses `/dev/video1`.
- Rear/front sensor nodes are present again: `video1=msm-sensor` for `camera@0`, `video2=msm-sensor` for `camera@2`, `v4l-subdev15=ov12a10`, `v4l-subdev16=s5k4h8`.
- Stock logical IDs are installed everywhere checked: rear `CameraId=0`, front `CameraId=2` in `/vendor/etc/camera`, `/vendor/etc/overlayfs/pepito/camera`, and `/vendor/odm/etc/camera`.
- Kernel logical session-id fix is verified live: rear opens post `Evt_session_id=0`; front opens post `Evt_session_id=2` instead of the auto-assigned `/dev/videoN`.
- Direct chromatix XML install under `/vendor/etc/camera` is verified live and removed the daemon `module_sensor_start_session: failed NULL pointer detected s_list` failure.
- Current primary failure moved to IMGLIB: `module_imgbase_start_session: Invalid idx -1`, followed by `mct_pipeline_start_session: start_session did not succeed on all modules`.
- Stock `libmmcamera2_imglib_modules.so` references several support blobs missing from the generated pepito runtime. `libmmcamera_sw2d_lib.so` was live-pushed and became visible through `/vendor/odm/lib`, but did not clear `module_imgbase_start_session: Invalid idx -1`. A broader stock support-blob pass (`cac3`, `dcrf`, `dummyalgo`, `facedetection`, `tuning`, `tuning_lookup`, plus `sw2d`) is also visible through `/vendor/odm/lib` and still does not clear the same IMGLIB failure.
- Runtime IMGLIB properties `persist.camera.imglib.ea_bypass=1`, `persist.camera.imglib.force_ea=0`, and `camera.llvd.preview.disable=1` were tested live and did not change the failure; the test properties were reverted.

Working stock-vendor control from Android 11 GSI with original Palm Android 8.1 AML0 vendor:
- Attached control phone reports Android 11 system with `ro.vendor.build.fingerprint=Palm/PVG100/Pepito:8.1.0/OPM1.171019.019/v1AML-0:user/release-keys` and `ro.vndk.version=27`.
- Stock services run: `camera-provider-2-4`, `qcamerasvr`, and `cameraserver`.
- `dumpsys media.camera` exposes two normal/public API1 cameras through `legacy/0`: camera 0 back/90/flash, camera 1 front/270/no flash, API2 not directly supported.
- Working provider maps stock `/vendor/lib/hw/camera.msm8937.so`, `/vendor/lib/libmmcamera_interface.so`, and stock HIDL camera provider/device implementation blobs.
- Working stock daemon maps `libmmcamera2_imglib_modules.so`, `libmmcamera_imglib.so`, `libmmcamera_ov12a10.so`, and `libmmcamera_s5k4h8.so` without the Lineage source-HAL IMGLIB startup failure.
- Working V4L topology matches our Lineage 23 probe state: `video0=msm-config`, `video1=msm-sensor`, `video2=msm-sensor`, `v4l-subdev15=ov12a10`, `v4l-subdev16=s5k4h8`.

---

## Confirmed Hardware

Source of truth:
- Stock `vendor.bin.extracted/etc/camera/camera_config.xml`
- Live device inspection for service/property state

| Slot | Position | Sensor | Actuator | EEPROM | Flash | CSID | Mount |
|------|----------|--------|----------|--------|-------|------|-------|
| 0 | Rear | **OmniVision OV12A10** (12MP) | DW9800 VCM | qtech_ov12a10 | PMIC (gpio33) | core 0, 4-lane | 90° |
| 2 | Front | **Samsung S5K4H8** (8MP) — primary supplier | — | — | — | core 1, 4-lane | 270° |
| 2 | Front | **GalaxyCore GC8034** (8MP) — alternate supplier | — | GC8034 OTP | — | core 0, 4-lane | 270° |

The front camera is dual-sourced (S5K4H8 vs GC8034). The stock `mm-qcamera-daemon` probes both and picks whichever is present. The GC8034 uses core 0 (same as rear); that is handled by daemon sequencing, not a DTS conflict.

**GPIO map** (from stock pepito.dts pinctrl nodes):

| Signal | GPIO | Camera |
|--------|------|--------|
| MCLK0 | gpio26 | Rear |
| RESET0 | gpio36 | Rear |
| STANDBY0 | gpio35 | Rear |
| MCLK2 | gpio28 | Front |
| RESET2 | gpio40 | Front |
| STANDBY2 | gpio39 | Front |
| VDIG (shared) | gpio62 | Both |
| VANA (shared) | gpio68 | Both |
| Flash strobe | gpio33 | Rear flash |
| Front flash en | gpio50 | Front flash |

**Voltage rails:**
- `cam_vdig`: 1.2 V (1200000 µV)
- `cam_vana`: 2.8 V (2800000 µV)
- `cam_vaf`: 2.85 V (2850000 µV)
- `cam_vio`: 1.8 V (shared IOVDD, same phandle as touchscreen VIO)

---

## Stack Layers

```
Android Camera API
      ↓
android.hardware.camera.provider-service_32.lineage   ← running ✅
  (Lineage's HIDL camera provider wrapper)
      ↓
camera.{ro.hardware.camera}.so
  Next flash: stock camera.msm8937.so selected by `ro.hardware.camera=msm8937`; uses stock Palm libmmcamera/libmmjpeg interface blobs ⚠️
      ↓
mm-qcamera-daemon   (/vendor/odm/bin via pepito overlayfs)        ← running ✅
  Stock Palm daemon receives NEW_SESSION, starts MCT, then tears down before ACK ⚠️
      ↓
Kernel camera drivers (msm-cam, csiphy, csid, ispif, vfe, cci, cpp)
  + sensor kernel drivers (ov12a10, s5k4h8, gc8034 via CCI/I2C)   ← rear/front nodes present; daemon IMGLIB startup still fails ⚠️
```

---

## Current Blocker — `camera.msm8937.so` dlopen dependency chain (2026-06-24)

The active blocker is the stock HAL failing to `dlopen`. See the **2026-06-24 update**
at the top of this file for the full chain and fixes. Summary state:

- `/odm/lib` overlay mount — **fixed** (placeholder mountpoint dir).
- `libandroid.so` / `libjnigraphics.so` namespace exposure — **fixed** (linker config).
- `libstdc++.so` — **bundled** into the overlay (`requireLibs` doesn't work for it;
  not a system-provided lib). Flashing now. Verified as the last unresolved lib in
  `camera.msm8937.so`'s transitive closure.
- 4 algo-impl libs missing from the dump (`libtinyxml2_1`, `libsdm-color`,
  `libllvd_smore`, `libtrueportrait`) — **deferred**; daemon-side only, not in the
  provider load chain. These likely correspond to the historic IMGLIB failure below.

Useful live commands for this chain:
```bash
adb shell getprop init.svc.vendor.camera.provider   # "restarting" = still crash-looping
adb logcat -d -b crash,system | grep -E "vndksupport|CamPrvdr|Could not load"
# transitive DT_NEEDED walk of the HAL to find the next missing lib:
adb shell 'for f in /odm/lib/*.so /odm/lib/hw/*.so; do readelf -d $f 2>/dev/null | grep NEEDED; done'
```

### Historic daemon-side IMGLIB failure (pre stock-HAL, still relevant for algo libs)

The HAL/provider can reach the stock daemon and kernel sensor nodes. The previous session-id mismatch is fixed: the 4.19 legacy camera path now sends stock logical camera IDs from DT `cell-index` instead of auto-assigned `/dev/videoN` numbers.

The previous sensor-list failure is also fixed. Stock `libmmcamera2_sensor_modules.so` hardcodes `/vendor/etc/camera/` for XML loading; installing the three chromatix XMLs directly under `/vendor/etc/camera` eliminated:

```text
module_sensor_start_session: failed NULL pointer detected s_list
```

The current daemon-side failure is later in MCT startup:

```text
mct_controller_new: Creating new mct_controller with session-id 0
ISP isp_module_start_session: session id 0
IMGLIB module_imgbase_start_session: Invalid idx -1
IMGLIB module_imglib_start_session: Can not start the session
mct_pipeline_start_session: start_session did not succeed on all modules
mct_controller_new: Start session failed with status -1
New session [0] creation failed with error
```

Kernel/provider side still reports `NEW_SESSION` timeout, but that is now downstream of the daemon failing to start all MCT modules and never ACKing the event:

```text
Evt_type=8002000 Evt_id=1 Evt_cmd=0
Evt_session_id=0 Evt_stream_id=0 Evt_arg=-1
camera_v4l2_open : NEW_SESSION event failed,rc -110
```

High-signal blob mismatch found in this pass:
- Loaded stock `libmmcamera2_imglib_modules.so` contains `module_sw2d_init` / `module_sw2d_set_parent` and references `libmmcamera_sw2d_lib.so`.
- Stock Palm AML0 vendor dump contains `lib/libmmcamera_sw2d_lib.so`; our generated pepito vendor tree and flashed runtime were missing it.
- Live-pushing `libmmcamera_sw2d_lib.so` made `/vendor/odm/lib/libmmcamera_sw2d_lib.so` visible with `u:object_r:vendor_file:s0`, but the daemon still failed with `module_imgbase_start_session: Invalid idx -1`.
- Further string/stock comparison found additional stock support blobs absent from runtime: `libmmcamera_cac3_lib.so`, `libmmcamera_dcrf_lib.so`, `libmmcamera_dummyalgo.so`, `libmmcamera_facedetection_lib.so`, `libmmcamera_tuning.so`, and `libmmcamera_tuning_lookup.so`.
- These stock support blobs are added to `proprietary-files.txt`, `proprietary-files-camera.txt`, generated `Android.bp`, generated `Mi8937-vendor.mk`, copied into `vendor/xiaomi/Mi8937/proprietary/vendor/lib/overlayfs/pepito/`, and verified live under `/vendor/odm/lib`; the failure remains unchanged.
- Runtime `camera.land.so` depended on `libLmcamera_interface.so`/`libLmjpeg_interface.so`. Palm stock `camera.msm8937.so` depends on `libmmcamera_interface.so`/`libmmjpeg_interface.so`, and stock `libmmcamera_interface.so` exports the session-aware helper set that matches the Mi8937 interface source more closely than the land interface.
- The previous tree used pepito-only source-built modules: `camera.pepito`, `libPmcamera_interface`, `libPmjpeg_interface`, and `libPomx_core`, and set pepito `ro.hardware.camera=pepito`. That was verified live but did not clear `module_imgbase_start_session: Invalid idx -1`.
- The tree is now switched to a pepito-only stock-HAL experiment: `ro.hardware.camera=msm8937`, no `camera.pepito` package, stock `camera.msm8937.so`, stock `libmmcamera_interface.so`, stock `libmmjpeg_interface.so`, `libqomx_core.so`, `libcamera_imgproc.so`, `libopencv_java3.so`, `libTsProcess.so`, and `libVDBeautyShotAPI.so` installed through `/vendor/lib/overlayfs/pepito`.

Next pass:
- Build and flash the stock-HAL experiment.
- Verify `ro.hardware.camera=msm8937`, provider maps `/vendor/odm/lib/hw/camera.msm8937.so`, and the stock interface/helper blobs map from `/vendor/odm/lib`.
- Check `dumpsys media.camera`; success target is the stock control shape: two `legacy/0` API1 cameras, rear id 0 orientation 90, front id 1 orientation 270.
- If enumeration still fails, capture provider linker errors and daemon session logs to distinguish stock-HAL load failure from daemon-side MCT/IMGLIB failure.

Build validation note: local targeted build was attempted for the new stock camera blob modules, but this environment refuses local builds with `Please ask the user to build remotely and not locally on this system`. No Soong validation was possible here.

## Resolved Since Initial Plan

- Kernel DTS camera nodes are present and probe rear/front sensors.
- Stock Palm `mm-qcamera-daemon` is installed and no longer a blankfile.
- Pepito camera configs and chromatix XMLs are extracted and mounted into the camera search path.
- `camera_config.xml` is installed at `/vendor/etc/camera/camera_config.xml`; the daemon reads this path directly.
- `camera_config.xml` is also installed into `/vendor/etc/overlayfs/pepito/camera/` so the pepito `/vendor/odm/etc/camera` overlay contains the same stock logical-ID config.
- Pepito bin/lib/camera overlayfs mounts are active.
- ICU APEX libraries are bind-mounted into `/vendor/odm/lib` for stock 32-bit camera blobs.
- `/data/vendor/qcam` bridges to `/data/vendor/camera` so Lineage HAL and stock daemon agree on socket location.
- Stock ISP submodule libraries are present; the earlier `failed: opening libmmcamera_isp_*` errors are gone.
- CPP firmware `cpp_firmware_v1_5_0.fw` is present; CPP hardware init now runs.
- Camera gyro/EIS QMI path is disabled with pepito props; the earlier `qmi_cci_xport_ctrl_port_init ... failed -97` blocker is gone.

## Phase 1 — Kernel DTS: Add Pepito Sensor Nodes ✅

**File:** `kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito/camera.dtsi` (new)

pepito.dts already includes:
- `delete-msm89x7-camera-sensor-mtp.dtsi` — removes the upstream MTP sensor nodes
- `restore-old-msm8937-camera-pinctrl.dtsi` — restores correct GPIO pin defs (RESET/STANDBY gpios match pepito)

Status: implemented and verified on live hardware. The replacement sensor nodes now create rear/front video and subdev entries. The original implementation guidance is retained below as reference for future DTS audits.

```dts
&cci {
    /* Rear: OV12A10 12MP, actuator DW9800, eeprom qtech_ov12a10 */
    qcom,actuator@0 {
        cell-index = <0>;
        reg = <0>;
        compatible = "qcom,actuator";
        qcom,cci-master = <1>;
        cam_vaf-supply = <&pm8937_l22>;
        qcom,cam-vreg-name = "cam_vaf";
        qcom,cam-vreg-min-voltage = <2850000>;
        qcom,cam-vreg-max-voltage = <2850000>;
        qcom,cam-vreg-op-mode = <80000>;
    };

    qcom,eeprom@0 {
        cell-index = <0>;
        compatible = "qcom,eeprom";
        qcom,cci-master = <1>;
        reg = <0>;
        cam_vdig-supply = <&pm8937_l23>;
        cam_vio-supply = <&pm8937_l6>;
        cam_vaf-supply = <&pm8937_l22>;
        qcom,cam-vreg-name = "cam_vdig", "cam_vio", "cam_vaf";
        qcom,cam-vreg-min-voltage = <1200000 0 2850000>;
        qcom,cam-vreg-max-voltage = <1200000 0 2850000>;
        qcom,cam-vreg-op-mode = <200000 0 100000>;
        pinctrl-names = "cam_default", "cam_suspend";
        pinctrl-0 = <&cam_sensor_mclk0_default &cam_sensor_rear_default &cam_sensor_verg_default>;
        pinctrl-1 = <&cam_sensor_mclk0_sleep   &cam_sensor_rear_sleep   &cam_sensor_verg_sleep>;
        gpios = <&tlmm 26 0>, <&tlmm 36 0>, <&tlmm 35 0>, <&tlmm 62 0>, <&tlmm 68 0>;
        qcom,gpio-reset   = <1>;
        qcom,gpio-standby = <2>;
        qcom,gpio-vdig    = <3>;
        qcom,gpio-vana    = <4>;
        qcom,gpio-req-tbl-num   = <0 1 2 3 4>;
        qcom,gpio-req-tbl-flags = <1 0 0 0 0>;
        qcom,gpio-req-tbl-label = "CAMIF_MCLK0", "CAM_RESET0", "CAM_STANDBY0",
                                   "CAM_GPIO_VDIG", "CAM_GPIO_VANA";
        status = "ok";
        clocks = <&gcc GCC_CAMSS_MCLK0_CLK_SRC>, <&gcc GCC_CAMSS_MCLK0_CLK>;
        clock-names = "cam_src_clk", "cam_clk";
        qcom,clock-rates = <19200000 0>;
    };

    qcom,camera@0 {
        cell-index = <0>;
        compatible = "qcom,camera";
        reg = <0>;
        qcom,csiphy-sd-index = <0>;
        qcom,csid-sd-index   = <0>;
        qcom,mount-angle     = <90>;
        qcom,actuator-src    = <&qcom_actuator0>;   /* phandle to actuator@0 */
        qcom,eeprom-src      = <&qcom_eeprom0>;      /* phandle to eeprom@0   */
        qcom,led-flash-src   = <&led_flash0>;        /* phandle to qpnp flash */
        cam_vdig-supply = <&pm8937_l23>;
        cam_vana-supply = <&pm8937_l22_ana>;         /* verify against stock */
        cam_vio-supply  = <&pm8937_l6>;
        cam_vaf-supply  = <&pm8937_l22>;
        qcom,cam-vreg-name = "cam_vdig", "cam_vana", "cam_vio", "cam_vaf";
        qcom,cam-vreg-min-voltage = <1200000 2800000 0 2850000>;
        qcom,cam-vreg-max-voltage = <1200000 2800000 0 2850000>;
        qcom,cam-vreg-op-mode     = <200000 80000  0  100000>;
        pinctrl-names = "cam_default", "cam_suspend";
        pinctrl-0 = <&cam_sensor_mclk0_default &cam_sensor_rear_default &cam_sensor_verg_default>;
        pinctrl-1 = <&cam_sensor_mclk0_sleep   &cam_sensor_rear_sleep   &cam_sensor_verg_sleep>;
        gpios = <&tlmm 26 0>, <&tlmm 36 0>, <&tlmm 35 0>, <&tlmm 62 0>, <&tlmm 68 0>;
        qcom,gpio-reset   = <1>;
        qcom,gpio-standby = <2>;
        qcom,gpio-vdig    = <3>;
        qcom,gpio-vana    = <4>;
        qcom,gpio-req-tbl-num   = <0 1 2 3 4>;
        qcom,gpio-req-tbl-flags = <1 0 0 0 0>;
        qcom,gpio-req-tbl-label = "CAMIF_MCLK0", "CAM_RESET0", "CAM_STANDBY0",
                                   "CAM_GPIO_VDIG", "CAM_GPIO_VANA";
        qcom,sensor-position = <0>;
        qcom,sensor-mode     = <0>;
        qcom,cci-master      = <1>;
        status = "ok";
        clocks = <&gcc GCC_CAMSS_MCLK0_CLK_SRC>, <&gcc GCC_CAMSS_MCLK0_CLK>;
        clock-names = "cam_src_clk", "cam_clk";
        qcom,clock-rates = <24000000 0>;
    };

    /* Front: S5K4H8 8MP (primary) — gc8034 handled identically below */
    qcom,eeprom@2 {
        cell-index = <2>;
        compatible = "qcom,eeprom";
        qcom,cci-master = <0>;
        reg = <2>;
        /* S5K4H8 has no separate eeprom node in stock — only GC8034 has OTP */
        /* Add only if gc8034_otp eeprom driver is present */
        cam_vdig-supply = <&pm8937_l23>;
        cam_vio-supply  = <&pm8937_l6>;
        qcom,cam-vreg-name = "cam_vdig", "cam_vio";
        qcom,cam-vreg-min-voltage = <1200000 0>;
        qcom,cam-vreg-max-voltage = <1200000 0>;
        qcom,cam-vreg-op-mode     = <105000  0>;
        pinctrl-names = "cam_default", "cam_suspend";
        pinctrl-0 = <&cam_sensor_mclk2_default &cam_sensor_front1_default &cam_sensor_verg_default>;
        pinctrl-1 = <&cam_sensor_mclk2_sleep   &cam_sensor_front1_sleep   &cam_sensor_verg_sleep>;
        gpios = <&tlmm 28 0>, <&tlmm 40 0>, <&tlmm 39 0>, <&tlmm 62 0>, <&tlmm 68 0>;
        qcom,gpio-reset   = <1>;
        qcom,gpio-standby = <2>;
        qcom,gpio-vdig    = <3>;
        qcom,gpio-vana    = <4>;
        qcom,gpio-req-tbl-num   = <0 1 2 3 4>;
        qcom,gpio-req-tbl-flags = <1 0 0 0 0>;
        qcom,gpio-req-tbl-label = "CAMIF_MCLK2", "CAM_RESET2", "CAM_STANDBY2",
                                   "CAM_GPIO_VDIG", "CAM_GPIO_VANA";
        status = "ok";
        clocks = <&gcc GCC_CAMSS_MCLK2_CLK_SRC>, <&gcc GCC_CAMSS_MCLK2_CLK>;
        clock-names = "cam_src_clk", "cam_clk";
        qcom,clock-rates = <19200000 0>;
    };

    qcom,camera@2 {
        cell-index = <2>;
        compatible = "qcom,camera";
        reg = <2>;
        qcom,csiphy-sd-index = <1>;
        qcom,csid-sd-index   = <1>;
        qcom,mount-angle     = <270>;
        qcom,eeprom-src      = <&qcom_eeprom2>;
        cam_vdig-supply = <&pm8937_l23>;
        cam_vana-supply = <&pm8937_l22_ana>;
        cam_vio-supply  = <&pm8937_l6>;
        qcom,cam-vreg-name = "cam_vdig", "cam_vana", "cam_vio";
        qcom,cam-vreg-min-voltage = <1200000 2800000 0>;
        qcom,cam-vreg-max-voltage = <1200000 2800000 0>;
        qcom,cam-vreg-op-mode     = <105000  80000  0>;
        pinctrl-names = "cam_default", "cam_suspend";
        pinctrl-0 = <&cam_sensor_mclk2_default &cam_sensor_front1_default &cam_sensor_verg_default>;
        pinctrl-1 = <&cam_sensor_mclk2_sleep   &cam_sensor_front1_sleep   &cam_sensor_verg_sleep>;
        gpios = <&tlmm 28 0>, <&tlmm 40 0>, <&tlmm 39 0>, <&tlmm 62 0>, <&tlmm 68 0>;
        qcom,gpio-reset   = <1>;
        qcom,gpio-standby = <2>;
        qcom,gpio-vdig    = <3>;
        qcom,gpio-vana    = <4>;
        qcom,gpio-req-tbl-num   = <0 1 2 3 4>;
        qcom,gpio-req-tbl-flags = <1 0 0 0 0>;
        qcom,gpio-req-tbl-label = "CAMIF_MCLK2", "CAM_RESET2", "CAM_STANDBY2",
                                   "CAM_GPIO_VDIG", "CAM_GPIO_VANA";
        qcom,sensor-position = <1>;
        qcom,sensor-mode     = <1>;
        qcom,cci-master      = <0>;
        status = "ok";
        clocks = <&gcc GCC_CAMSS_MCLK2_CLK_SRC>, <&gcc GCC_CAMSS_MCLK2_CLK>;
        clock-names = "cam_src_clk", "cam_clk";
        qcom,clock-rates = <24000000 0>;
    };
};
```

> **Regulator phandles:** The stock DTS uses numeric phandles. Cross-reference against `vendor-legacy/qcom/msm8940-pmi8950.dtsi` plus the ugg/land DTS to find the correct `pm8937_l*` labels. The pattern is consistent across MSM8940 siblings, but the exact labels still need to be verified before patching.

> **Clock names:** The upstream Mi8937 kernel uses `GCC_CAMSS_MCLK{0,2}_CLK_SRC` / `GCC_CAMSS_MCLK{0,2}_CLK`. Verify against `drivers/clk/msm/clock-gcc-8952.c` or the existing land DTS fragment.

**TODO — pepito.dts include:**
```dts
#include "pepito/camera.dtsi"
```

**Verification:** After flashing, `dmesg | grep -E "cci|csiphy|csid|ov12a10|s5k4h8|gc8034"` should show CCI probe success and sensor I2C probe attempts.

---

## Phase 2 — Vendor Blobs: Acquire Camera Stack ✅

The stock `vendor.bin.extracted` (AML0 backup) contains the daemon, camera config XMLs, chromatix tuning, ISP submodules, imglib support libraries, and CPP firmware now used by the live build.

### 2a. mm-qcamera-daemon (camera server binary)

Status: replaced with the real stock Palm binary via the pepito overlayfs path. Historical source priority was:
1. **Stock Palm vendor.img** — pull from AML0 backup if it's in `/vendor/bin/`: `ls ~/Personal-Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/vendor.bin.extracted/bin/`
2. **Xiaomi Mi8940 (ugg) nightly** — ugg uses the same SoC and is most likely ABI-compatible
3. **Lineage 17/18 Mi8937 build** — older builds may have the binary from a Xiaomi dump

```bash
# Check if we already have it in the AML0 backup
ls ~/Personal-Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/vendor.bin.extracted/bin/mm-qcamera-daemon
```

> Note: `mm-qcamera-daemon` built against Android 8.1 userspace may have bionic symbol mismatches against Android 16. If the Palm binary crashes at startup, fall back to a Lineage 17/18 nightly binary built against a closer Android version. The Mi8937 source-built camera HAL (QCamera2) talks to `mm-qcamera-daemon` via Unix socket; the daemon ABI is usually stable within the same QCAM version line.

### 2b. Sensor shared libraries

Required blobs (to be extracted from stock Palm vendor or a Xiaomi MSM8940 dump):
```
# Sensor drivers
vendor/lib/libmmcamera_ov12a10.so          # rear sensor
vendor/lib/libmmcamera_s5k4h8.so           # front sensor primary
vendor/lib/libmmcamera_gc8034.so           # front sensor alternate

# Actuator
vendor/lib/libactuator_dw9800.so           # rear VCM AF

# EEPROM
vendor/lib/libmmcamera_qtech_ov12a10_eeprom.so
vendor/lib/libmmcamera_gc8034_otp_eeprom.so # gc8034 OTP eeprom

# Core camera pipeline (already partially present from §C vendor extract)
# Verify these are installed:
vendor/lib/libmmcamera2_sensor_modules.so
vendor/lib/libmmcamera2_iface_modules.so
vendor/lib/libmmcamera2_isp_modules.so
vendor/lib/libmmcamera2_pproc_modules.so
vendor/lib/libmmcamera2_stats_modules.so
vendor/lib/libmmcamera2_mct.so
vendor/lib/libmmcamera2_cpp_module.so
vendor/lib/libmmcamera2_c2d_module.so
vendor/lib/libmmcamera_dbg.so
vendor/lib/libmmcamera_imglib.so
vendor/lib/libmmcamera_faceproc.so
```

Pepito camera blobs are now listed in canonical `device/xiaomi/Mi8937/proprietary-files.txt` under the `Camera stack (pepito)` and `Camera configs (pepito)` sections. `proprietary-files-camera.txt` exists, but `extract-files.py` currently parses `proprietary-files.txt`, so the canonical list must carry the pepito entries.

### 2c. Chromatix tuning + camera configs

Installed from stock backup at `vendor.bin.extracted/etc/camera/`:
- `camera_config.xml` — sensor routing config; installed both for direct `/vendor/etc/camera/` access and pepito overlay access.
- `ov12a10_chromatix.xml` — rear tuning.
- `s5k4h8_chromatix.xml` — front tuning (S5K4H8).
- `gc8034_chromatix.xml` — front tuning (GC8034).

These are proprietary stock vendor assets. Regenerate the vendor tree with:
```bash
cd /home/kyle/android/lineage-23/device/xiaomi/Mi8937
PYTHONPATH=../../../tools/extract-utils python3 extract-files.py -n -m /home/kyle/Projects/lineage-23/backup-stock-android-8.1-AML0/vendor.bin.extracted
```

Runtime path:
- Extracted configs install to `/vendor/etc/overlayfs/pepito/camera/`.
- `init.xiaomi.device.rc` mounts that directory over `/odm/etc/camera` for `ro.vendor.xiaomi.device=pepito`.
- Extracted daemon/libs install to `/vendor/bin/overlayfs/pepito/` and `/vendor/lib/overlayfs/pepito/`, then init overlays them onto `/odm/bin` and `/odm/lib`.

---

## Phase 3 — HAL Runtime: Stock `camera.msm8937` Provider Path ⚠️ (flashed; dlopen chain being resolved)

Current experiment: use the stock Palm AML0 HAL/interface ABI as a unit, while keeping the Lineage camera provider service. **This has been built and flashed** (06-23/06-24); the provider now reaches the `dlopen` of `camera.msm8937.so` and the remaining work is satisfying that load's dependency chain (see 2026-06-24 update at top).

Implemented tree state:
- `ro.hardware.camera=msm8937` for `ro.vendor.xiaomi.device=pepito`. Verified live.
- `camera.pepito` is no longer packaged for pepito.
- Stock `camera.msm8937.so` installs to `/vendor/lib/overlayfs/pepito/hw/`, then appears at `/vendor/odm/lib/hw/` through the pepito `/odm/lib` overlay. Verified live.
- Stock direct HAL deps install to `/vendor/lib/overlayfs/pepito/`: `libmmcamera_interface.so`, `libmmjpeg_interface.so`, `libqomx_core.so`, `libcamera_imgproc.so`, `libopencv_java3.so`, `libTsProcess.so`, and `libVDBeautyShotAPI.so`.
- Plus the 4 imgbase algo-impl libs added earlier: `liboptizoom.so`, `libremosaic_daemon.so`, `libseemore.so`, `libubifocus.so` (live under `/vendor/odm/lib`).
- Stock daemon/libs/configs continue to mount through the pepito overlayfs branches for `/odm/bin`, `/odm/lib`, and `/odm/etc/camera`.

Two init-RC fixes were required to get the provider to even start (it was previously a silent duplicate-service no-op):
- Removed the `vendor.camera.provider` service block from `mithorium-common/.../init.target.rc`. It was parsed first and `disabled`, so init discarded the Lineage RC (which carries the `interface aidl .../ICameraProvider/internal/0` line) as a duplicate. The Lineage RC now owns the service.
- Enabled `vendor.qcamerasvr` (removed `disabled` in `init.target.rc`); `init.xiaomi.rc` then restarts the provider once the daemon is running.

Vendor linker namespace fix (`device/xiaomi/Mi8937/configs/linker.config.json`, wired via `PRODUCT_VENDOR_LINKER_CONFIG_FRAGMENTS` in device.mk):
```json
{ "requireLibs": ["libandroid.so", "libjnigraphics.so", "libstdc++.so"] }
```
These three system libs are `DT_NEEDED` (transitively) by `camera.msm8937.so` but not in the default vendor namespace's link to system. `requireLibs` exposes them. Regenerated into `/vendor/etc/linker.config.pb`, which `linkerconfig` folds into the generated `ld.config.txt` at boot.

Reasoning:
- The Android 11 GSI control with stock AML0 vendor proves stock `camera.msm8937.so` + stock `libmmcamera_interface.so` can enumerate two API1 cameras on this hardware.
- The Lineage 23 source-built HAL path could enumerate sensor nodes and reach the daemon, but daemon-side IMGLIB failed session startup before `NEW_SESSION` ACK.
- Using the stock HAL/interface pair tests whether the remaining failure is caused by source-built interface/session ABI drift rather than kernel topology or missing sensor blobs.

Historical source-built paths:
- `camera.land` and then `camera.pepito` were useful for proving provider-to-daemon connectivity and kernel sensor probe state.
- Both source-built paths still converged on the same daemon-side `module_imgbase_start_session: Invalid idx -1` failure.
- The old recommendation to prefer `camera.land`/`camera.pepito` is superseded by this stock-HAL experiment.

## Phase 4 — `ro.hardware.camera` Property ⚠️

Implemented in `device/xiaomi/Mi8937/rootdir/etc/init.xiaomi.device.rc` with a pepito branch:

```sh
on property:ro.vendor.xiaomi.device=pepito
    setprop ro.hardware.camera msm8937
    enable vendor.qcamerasvr
```

This tells the Lineage camera provider to `dlopen("camera.msm8937.so")`. Sensor selection remains driven by stock `camera_config.xml` and the stock daemon modules.

## Phase 5 — SELinux ⚠️

The `mithorium-common/sepolicy/vendor/mm-qcamerad.te` and `hal_camera_default.te` exist already. Verify:
- `vendor.qcamerasvr` is labeled correctly (should be `mm-qcamerad` domain)
- `/odm/bin/mm-qcamera-daemon` has `file_contexts` entry for `mm-qcamerad_exec`
- `/odm/etc/camera/` files are readable from `mm-qcamerad` and `hal_camera_default`

Expect additional denials on first boot with camera enabled. Collect from `adb logcat -s SELinux:E` or `dmesg | grep avc` and add pepito-specific rules to `device/xiaomi/Mi8937/sepolicy/vendor/` rather than `mithorium-common` if the paths are pepito-only.

---

## Previous Lineage Source-HAL Baseline

Captured via `adb root` on the last source-HAL flashed build:
- `ro.product.brand=Palm`
- `ro.product.model=PVG100`
- `ro.hardware.camera=pepito` on the last source-HAL flash; next stock-HAL flash should report `msm8937`.
- `cameraserver` is running.
- `android.hardware.camera.provider-service_32.lineage` is running.
- `mm-qcamera-daemon` is running in `u:r:mm-qcamerad:s0`.
- `/vendor/odm/bin`, `/vendor/odm/lib`, and `/vendor/odm/etc/camera` are pepito overlayfs mounts.
- `/data/vendor/qcam -> /data/vendor/camera` exists for socket compatibility.
- `/sys/class/video4linux/video1` and `video2` exist as `msm-sensor` nodes.
- `/sys/class/video4linux/v4l-subdev15` is `ov12a10`; `v4l-subdev16` is `s5k4h8`.
- `dumpsys media.camera` still reports zero cameras due to the NEW_SESSION timeout.

Note: non-root shell context cannot reliably inspect camera vendor paths, set debug properties, or control camera services. Use `adb root` before live camera debugging.

---

## Phase 6 — Verification Sequence

After flash:
```bash
adb root

# 1. Camera kernel drivers and sensors present
adb shell 'for n in /sys/class/video4linux/video* /sys/class/video4linux/v4l-subdev*; do printf "%s " "$n"; cat "$n/name" 2>/dev/null; done'
adb shell dmesg | grep -E "cci|ov12a10|s5k4h8|gc8034|csiphy|qcom_cam_smmu|legacy_msm_post_event|NEW_SESSION"

# 2. Init/property/overlay state
adb shell getprop ro.hardware.camera
adb shell mount | grep -E "/vendor/odm/(bin|lib|etc/camera)|libicu"
adb shell ls -l /data/vendor/qcam /vendor/etc/camera/camera_config.xml /vendor/odm/etc/camera/camera_config.xml

# 3. Daemon/provider state
adb shell ps -AZ | grep -E "qcamera|camera.provider|cameraserver"
adb shell dumpsys media.camera

# 4. Focused failure capture
adb logcat -b all -d | grep -Ei "CameraProvider|QCamera|mm-camera|mm_qcamera|NEW_SESSION|legacy_msm_post_event|cpp|isp_module_start_session|mct_pipeline_stop_session"
```

---

## Known Unknowns / Risks

| Risk | Mitigation |
|------|-----------|
| `mm-qcamera-daemon` ABI mismatch (Android 8 binary on Android 16 bionic) | Source from Lineage 17/18 nightly first; fall back to Palm stock only if compatible |
| Front camera dual-sourcing: S5K4H8 probe fails, GC8034 probe fails | The stock daemon probes both in sequence; replicate that behavior by ensuring both `libmmcamera_s5k4h8.so` and `libmmcamera_gc8034.so` are installed |
| Regulator phandle mismatch in DTS (stock 8.1 DTS used pmic-id-specific phandles) | Cross-reference `ugg.dts` or `prada.dts` for the same ldo labels — the MSM8940 family uses consistent pm8937_l* naming |
| OV12A10 clock rate: 24 MHz vs 19.2 MHz | Stock DTS shows 0x16e3600 = 24000000 Hz for MCLK0; verify this matches what the sensor driver expects — some OV12A10 configurations use 19.2 MHz. Adjust `qcom,clock-rates` in camera.dtsi if sensor doesn't probe. |
| Camera HAL header build failures | Likely `msmb_camera.h` / `msm_ion.h` — copy from `kernel/xiaomi/msm8937/include/uapi/media/` |
| SELinux denials for overlayfs camera mount | Add `allow init vendor_file:dir mounton;` or equivalent to pepito's sepolicy; pattern exists in other Mi8937 variant bring-ups |

---

## TODO Checklist

- [x] **DTS:** Create/include pepito camera nodes for rear OV12A10 and front S5K4H8/GC8034-compatible slot.
- [x] **DTS:** Verify regulators/clocks enough for live kernel sensor nodes to appear.
- [x] **Blobs:** Add stock Palm `mm-qcamera-daemon`, sensor libs, actuator/eeprom libs, core camera libs, ISP submodules, imglib support libs, and CPP firmware.
- [x] **Blobs:** Regenerate `vendor/xiaomi/Mi8937/{Android.bp,Mi8937-vendor.mk}` with `extract-files.py -n -m` and verify listed inputs exist.
- [x] **Configs:** Install `camera_config.xml` and chromatix XMLs; keep `camera_config.xml` available at `/vendor/etc/camera/camera_config.xml` and through pepito overlayfs.
- [x] **Configs:** Keep stock Palm logical `CameraId` values (`0` rear, `2` front); do not map IDs to transient `/dev/videoN` nodes.
- [x] **RC:** Set `ro.hardware.camera=msm8937`, mount pepito bin/lib/camera overlays, bind ICU libraries, bridge `/data/vendor/qcam`, disable gyro/EIS QMI path, and enable `vendor.qcamerasvr`.
- [x] **Runtime:** Confirm provider and stock daemon run after boot.
- [x] **Runtime:** Confirmed source-HAL path could enumerate two sensor nodes and reach the daemon before failing IMGLIB session startup.
- [x] **Runtime:** Verified daemon receives logical session `0` for rear and `2` for front instead of transient `/dev/videoN`.
- [x] **Runtime:** Build/flash stock-HAL experiment; verified `ro.hardware.camera=msm8937` and provider maps `/odm/lib/hw/camera.msm8937.so`.
- [x] **Init:** Fix duplicate `vendor.camera.provider` definition (init.target.rc was discarding the Lineage AIDL RC); enable `vendor.qcamerasvr`.
- [x] **Overlay:** Fix `/odm/lib` overlay never mounting (missing `/vendor/odm/lib` mountpoint dir) via `.placeholder`.
- [x] **Linker:** Expose `libandroid.so`/`libjnigraphics.so`/`libstdc++.so` to vendor namespace via `requireLibs`.
- [ ] **Runtime:** Confirm post-`libstdc++` flash that `camera.msm8937.so` loads, provider stops crash-looping (`init.svc.vendor.camera.provider=running`), and `mModule` is non-null.
- [ ] **Blobs:** Resolve the 4 deferred algo-impl libs — symlink `libtinyxml2_1.so`→`libtinyxml2.so`; source `libsdm-color.so`; decide whether `libllvd_smore.so`/`libtrueportrait.so` can stay absent.
- [ ] **Runtime:** Check whether `dumpsys media.camera` matches the Android 11 stock-vendor control with two API1 legacy cameras.
- [x] **Kernel/UAPI:** Stage logical session-id mapping from DT `cell-index` through `legacy_camera_init_v4l2()` and camera V4L2 session/event paths.
- [ ] **Kernel/UAPI:** Compare 4.19 camera-legacy NEW_SESSION/event ACK structs and ioctls against stock 3.18 Palm camera UAPI.
- [ ] **CPP/session:** Investigate why CPP init reports `stream_cnt:0` during the failed session.
- [ ] **SELinux:** Review denials after focused camera restart; only add pepito-specific rules if denials block camera paths.
- [ ] **Verify:** Once NEW_SESSION ACK completes, confirm `dumpsys media.camera` lists cameras, then test rear and front preview.
