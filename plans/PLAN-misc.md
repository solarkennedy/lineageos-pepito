# PLAN-misc: Miscellaneous Papercuts

Catch-all for small but visible bring-up issues on the Palm PVG100 (pepito).

> **2026-06-23 boot status:** device boot was restored after two regressions
> (RPMB device-node type — kernel; GPU CP microcode — vendor blob); `sys.boot_completed=1`
> again. SELinux is still Permissive (bring-up diagnostic). Details: `PLAN.md`,
> `PLAN-gatekeeper.md`, `PLAN-surfaceflinger.md`, `PLAN-userspace.md`.

---

## Audio HAL and ACDB

**Status:** Moved to dedicated [`PLAN-audio.md`](PLAN-audio.md).

**Audio PLAYS through the speaker (2026-07-02)** — the earlier `-517` card registration
failure, audioserver crash, and missing ACDB staging are all resolved. Two leftovers,
both root-caused in `PLAN-audio.md`: (1) false "Wired headphones" UI label from MBHC
jack detection on a jack-less board (DTS + 2-line driver fix staged); (2) Palm A8-era
ACDB files don't match the A12/13-era acdb_loader, so the DSP runs uncalibrated.

---

## 1. Remove second SIM slot

**Status:** DONE

**Problem:** `config_num_physical_slots` is set to `2` in the common overlay, but pepito only has one physical SIM tray.

**Root cause:**
```
device/xiaomi/mithorium-common/overlay/frameworks/base/core/res/res/values/config.xml:408
    <integer name="config_num_physical_slots">2</integer>
```

**Fix:** Override this in the pepito-specific framework overlay to `1`.

```xml
<!-- device/xiaomi/Mi8937/overlay/frameworks/base/core/res/res/values/config.xml -->
<integer name="config_num_physical_slots">1</integer>
```

**Implemented:**

- `device/xiaomi/Mi8937/rro_overlays/xiaomi_pepito_overlay/res/values/config.xml` sets `config_num_physical_slots` to `1`.
- `device/xiaomi/Mi8937/pepito.vendor.prop` sets `persist.radio.multisim.config=ssss` and `ro.telephony.default_network=33`.

**Confirmed:** the second SIM slot UI/path is gone on device.

---

## 2. Fix navigation buttons / gesture navigation

**Status:** DONE

**Problem:** No nav buttons visible on screen and swipe gestures don't work.

**Root cause candidates:**

1. **`config_showNavigationBar` is not overridden.** The AOSP framework default is `false`
   (`frameworks/base/core/res/res/values/config.xml:2772`). Without an overlay forcing it
   `true`, the software nav bar never shows up.

2. **`qemu.hw.mainkeys` fallback.** `init.qcom.early_boot.sh` sets
   `qemu.hw.mainkeys=0` only in emulator/qemu paths. On real hardware this prop may be
   absent or `1`, which suppresses the nav bar.

3. **`config_navBarInteractionMode` defaults to `0`** (3-button nav). Gesture nav needs `2`.

**Fix:**

Add a pepito (or Mi8937) overlay for `frameworks/base/core/res/res/values/config.xml`:

```xml
<!-- Show the software navigation bar -->
<bool name="config_showNavigationBar">true</bool>

<!-- 0 = 3-button, 1 = 2-button, 2 = full gestural -->
<integer name="config_navBarInteractionMode">2</integer>
```

Alternatively, set a system property in `device.mk` (supported on AOSP/LineageOS):
```makefile
PRODUCT_VENDOR_PROPERTIES += \
    qemu.hw.mainkeys=0
```

Setting `qemu.hw.mainkeys=0` via a property tells the framework to show the software nav bar
even on non-emulator hardware; it is the standard trick for devices with no capacitive keys.
The overlay approach is cleaner for LineageOS.

**Implemented:**

- `device/xiaomi/Mi8937/rro_overlays/xiaomi_pepito_overlay/res/values/config.xml` sets `config_showNavigationBar=true`.
- The same overlay sets `config_navBarInteractionMode=2` for gestural navigation.
- `device/xiaomi/Mi8937/rro_overlays/xiaomi_pepito_overlay_lineage/res/values/config.xml` sets `config_deviceHardwareKeys=0`, matching pepito's lack of physical nav/volume keys.

**Confirmed:** navigation works on device.

**2026-07-17 reopened — 3-button nav covers app buttons (taskbar hosts the navbar).**
Symptom: on the GMS *managed-account* set-screen-lock screen (`FLAG_SECURE`, so
`screencap` is black), the on-screen 3-button bar overlapped/covered the footer buttons;
switching to gesture nav made them tappable. Root cause is NOT PepitoLauncher2 and NOT our
`config_navBarInteractionMode=2` overlay (that override is load-bearing: it makes a *clean*
flash default to gesture, because the three `com.android.internal.navigation_bar_mode` RROs
are dynamic/disabled-by-default and priority INT_MAX when enabled — an enabled mode-RRO,
e.g. from a Google/managed settings restore, stomps our priority-31 overlay → 3-button).

The real bug: this build co-installs `Launcher3QuickStepGo` (`com.android.launcher3`) as the
QuickStep/recents provider (`config_recentsComponentName`), and SystemUI
`NavigationBarControllerImpl.supportsTaskbar()` on a phone reduces to
`com.android.wm.shell.Flags.enableTaskbarOnPhones()`. Runtime confirmed
`multitasking/com.android.wm.shell.enable_taskbar_on_phones=true` → SystemUI
`removeNavigationBar()`s and delegates the nav bar to Launcher3's taskbar
(`Window{… Taskbar}` owned by uid a10135), whose 3-button variant mis-insets on this
sw436dp panel. Gesture works because the pill path insets fine.

**Why this build hits it at all:** taskbar-on-phones is a **Google platform default**, not ours —
`enable_taskbar_on_phones` is baked `ENABLED` in `build/release/aconfig/{trunk_staging,bp1a}/`,
inherited by our `bp4a` (`bp4a → bp3a → … → bp1a`), and GMS also pushes the whole `multitasking/`
device_config namespace on (incl. `enable_taskbar_navbar_unification=true`). Every A16 GMS phone
routes nav through the launcher taskbar. What's device-specific is only the **sw436dp micro-display**
(720×1280 @ 264dpi, 3.3"): the taskbar-hosted **3-button** bar mis-insets and overlaps footer
buttons there; normal-size phones lay it out fine. (Kyle uses 3-button daily, so this is a
first-class bug for us, not an edge case.)

**First attempt (flag-only) crash-looped Trebuchet — the flag is ASYMMETRIC.** Forcing
`enable_taskbar_on_phones` off moved nav hosting back to SystemUI's `NavigationBar0` ✅ but
crash-looped `com.android.launcher3` ~every 10 min: `TouchInteractionService.onCreate` →
`TaskbarManagerImpl.addTaskbarRootViewToWindow` → `BadTokenException: another window of type 2019
[TYPE_NAVIGATION_BAR] already exists`. Cause: the flag is read ONLY by SystemUI
(`supportsTaskbar()`); Launcher3's `TaskbarManager` creates its type-2019 window **unconditionally**
(`isTaskbarEnabled()` only checked nav-not-policy-disabled; never read the flag; `createTaskbarActivityContext`
bails only on null Display). `enable_tiny_taskbar` does NOT help (only gates the dock).

**Fix STAGED (2026-07-17, unbuilt) — two halves that must ship together:**
1. `vendor/lineage/release/aconfig/bp4a/com.android.wm.shell/{enable_taskbar_on_phones_flag_values.textproto,Android.bp}`
   → `enable_taskbar_on_phones` DISABLED READ_ONLY (READ_ONLY so the GMS `multitasking` push can't
   re-enable it). SystemUI then hosts its own `NavigationBar` → 3-button insets correctly.
2. `packages/apps/Launcher3/quickstep/…/taskbar/TaskbarManagerImpl.java` — patched
   `isTaskbarEnabled()` to ALSO return false when `deviceProfile.getDeviceProperties().isPhone() &&
   !enableTaskbarOnPhones()` (+import). Mirrors SystemUI's `supportsTaskbar()`, so Launcher3 stops
   adding the second nav window → no collision. Tablets/large-screen (isPhone==false) unaffected.
   Verified both `addTaskbarRootViewToWindow` callers funnel through the guarded early-return
   (`recreateTaskbarForDisplay` line ~846; `onUserUnlocked` loops the then-empty `mTaskbars`).

Net: SystemUI owns nav in ALL modes (3-button + gesture); Overview/QuickStep/gestures still run
via `TouchInteractionService`; no taskbar dock. Both edits touch synced repos (`vendor/lineage`,
`packages/apps/Launcher3`) = bring-up debt. **Verify after flash:** no "Trebuchet keeps stopping";
`dumpsys window | grep mNavigationBar` = `NavigationBar0` (not `Taskbar`) in BOTH 3-button and
gesture; 3-button footer buttons reachable on the GMS set-screen-lock screen; Overview
(recents) still works. `logcat -b crash -d | grep launcher3` clean.

---

## 3. Enable Android Go optimizations

**Status:** IN PROGRESS

**Problem:** pepito has only ~2 GB RAM (MSM8940, low-end). Android Go memory optimizations
are not enabled, so the device will be under more memory pressure than necessary.

**Fix:** Inherit `go_defaults_common.mk` for pepito from
`device/xiaomi/Mi8937/lineage_Mi8937.mk`:

```makefile
# Android Go / low-RAM optimizations for Palm PVG100
ifeq ($(TARGET_DEVICE_PEPITO),true)
$(call inherit-product, build/make/target/product/go_defaults_common.mk)
endif
```

`go_defaults_common.mk` enables:
- `ro.config.low_ram=true` — tells ActivityManager to be more aggressive about killing
  background processes
- `PRODUCT_SYSTEM_SERVER_COMPILER_FILTER := speed-profile`
- `PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD := false`
- `PRODUCT_MINIMIZE_JAVA_DEBUG_INFO := true`
- `MALLOC_LOW_MEMORY := true` (in non-eng builds)
- Adds `go_handheld_core_hardware.xml` permissions file

`go_defaults_common.prop` (pulled in automatically) sets conservative dalvik heap limits:
`dalvik.vm.heapgrowthlimit=128m`, `dalvik.vm.heapsize=256m`.

These may conflict with the existing:
```makefile
# device/xiaomi/Mi8937/device.mk:12
$(call inherit-product, frameworks/native/build/phone-xhdpi-2048-dalvik-heap.mk)
```
That file targets 2 GB RAM devices but uses larger heap ceilings (512m/512m). Keep the
Go defaults — they're more conservative and appropriate here.

**Current change:** `lineage_Mi8937.mk` inherits `go_defaults_common.mk` under `TARGET_DEVICE_PEPITO`, before `full_base_telephony.mk`, so the Go handheld permissions file wins. It also inherits `vendor/lineage/config/common_full_go_phone.mk` so Lineage selects `Launcher3QuickStepGo`. Pepito also skips the old `phone-xhdpi-2048-dalvik-heap.mk` include.

**2026-06-16 first flash result:** device boots normally with root adb. Confirmed `ro.config.low_ram=true`, `dalvik.vm.systemservercompilerfilter=speed-profile`, single-SIM `persist.radio.multisim.config=ssss`, and pepito overlays enabled. Two Go defaults did not fully win in the first build:

- Runtime heap stayed at `dalvik.vm.heapgrowthlimit=192m` / `dalvik.vm.heapsize=512m` because `phone-xhdpi-2048-dalvik-heap.mk` still emitted vendor heap properties.
- `/vendor/etc/permissions/handheld_core_hardware.xml` was still the normal handheld file because this copy destination is first-wins, and `full_base_telephony.mk` was inherited before `go_defaults_common.mk`.

**Second flash result:** `Launcher3QuickStepGo` is installed at `/system/system_ext/priv-app/Launcher3QuickStepGo/Launcher3QuickStepGo.apk`, forced launch does not reproduce the Launcher3 crash, `/vendor/etc/permissions/handheld_core_hardware.xml` is the Go version, and the appwidget service remains absent as expected for Go. Runtime heap is still `192m` / `512m`, so one Go heap fix remains.

**Heap follow-up:** add explicit pepito vendor properties in `lineage_Mi8937.mk`:

```makefile
PRODUCT_VENDOR_PROPERTIES += \
    dalvik.vm.heapgrowthlimit=128m \
    dalvik.vm.heapsize=256m
```

`lunch lineage_Mi8937 bp4a userdebug` product variables now show `ro.config.low_ram=true`, `dalvik.vm.heapgrowthlimit=128m`, and `dalvik.vm.heapsize=256m`. Keep status `IN PROGRESS` until the next flash confirms the runtime heap values.

**Build config check:** `lunch lineage_Mi8937 bp4a userdebug` parses cleanly. `PRODUCT_COPY_FILES` lists `go_handheld_core_hardware.xml` before the normal `handheld_core_hardware.xml` for the duplicate destination.

**Trebuchet/Launcher3 crash found after enabling Go:** normal `Launcher3QuickStep` crashes on low-RAM Go because the app widget service is absent (`cmd package has-feature android.software.app_widgets=false`, `service check appwidget` not found) but the normal launcher still calls `AppWidgetManager.getInstalledProvidersForProfile()` during widget model loading. Switching Lineage inheritance from `common_full_phone.mk` to `common_full_go_phone.mk` sets `PRODUCT_TYPE=go` and selects `Launcher3QuickStepGo` (`WIDGETS_ENABLED=false`).

**Note:** Avoid `go_defaults.mk` (the full version) unless GMS Go apps are also being
included. In this branch `go_defaults.prop` is currently empty; full `go_defaults.mk` only
adds GMS Go release config maps when those files exist in the source tree.

---

## 4. Investigate why ramoops prints are not clearing

**Status:** TODO

**Problem:** `/sys/fs/pstore/console-ramoops-0` and `pmsg-ramoops-0` persist across reboots
and are not being cleared after being read.

**Background:**

The ramoops DTS node (`kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/common/ramoops.dtsi`)
reserves 8 MB at `0xb0000000` with a 2 MB console record, 2 MB pmsg record, and no explicit
`erase-size`. By default pstore does NOT automatically erase old records; something must
explicitly delete them.

AOSP `init.rc` mounts pstore at `/sys/fs/pstore` and sets permissions, but does **not**
delete old records. The deletion is supposed to happen via `logd` or the crash recovery
flow reading and then unlinking the files.

**Things to check:**

1. **Is pstore actually mounted?**
   ```
   adb shell mount | grep pstore
   adb shell ls /sys/fs/pstore/
   ```

2. **Is `logd` / `logcat` reading and clearing pmsg?**
   On Android, `logd` reads `/sys/fs/pstore/pmsg-ramoops-0` on startup and then should
   delete it. Check `logd` logs:
   ```
   adb logcat -b all | grep -i pstore
   ```

3. **Is `dropboxd` or `incidentd` consuming console-ramoops?**
   `console-ramoops-0` is normally read by `incidentd` or uploaded to `dropbox`; after
   that the framework calls `unlink` on the file. If these services aren't running or
   don't have SELinux permission to delete pstore files, the file sticks around.

4. **SELinux denials?**
   ```
   adb shell dmesg | grep "avc: denied" | grep pstore
   adb logcat | grep "avc: denied" | grep pstore
   ```
   Missing `unlink` permission on `pstore_file` for `logd` or `system_server` is a common
   cause.

5. **`erase_each_kmsg_dump` kernel option** — in `CONFIG_PSTORE_RAM`, if
   `erase_each_kmsg_dump` is not set, pstore accumulates dumps until the circular buffer
   wraps. This is a kernel-level concern separate from the Android-level clearing.
   Check:
   ```
   grep ERASE /home/kyle/android/lineage-23/kernel/xiaomi/msm8937/arch/arm64/configs/mi8937_defconfig
   ```
   This option is usually not what people mean by "not clearing" — the Android-level
   userspace deletion is almost always the actual issue.

**Most likely fix:** An SELinux denial is preventing `logd` or `incidentd` from calling
`unlink()` on the pstore files. Start by auditing denials, then add the missing `allow`
rule to the appropriate sepolicy `.te` file in
`device/xiaomi/mithorium-common/sepolicy/`.

---

## 5. scrcpy screen capture — hardware encoder

**Status:** ✅ **SOLVED 2026-07-10.** Hardware AVC encode works. Root cause was a single missing
`dlopen()`ed vendor blob, `libc2d30_bltlib.so`. Staged, awaiting flash.

**Root cause: incomplete blob closure, one level below a `DT_NEEDED` edge.**

`libC2D2.so` **`dlopen()`s** its backend `libc2d30_bltlib.so`. There is no `DT_NEEDED` edge to it,
so the vendor blob closure walk (`PLAN-vendor-extract.md`) never pulled it in — even though
`mithorium-common/proprietary-files-qc-vndr.txt` had *listed* it for ages. With the backend
absent, C2D surface color conversion failed on the encoder's **first input buffer**:

```
I omx@1.0-service: open Color conv forW: 448, H: 800
E omx@1.0-service: Color Conversion failed
E omx@1.0-service: ERROR: ETBProxy() failed!
E omx@1.0-service: ERROR: send OMX_ErrorHardware to Client
E ACodec:  ERROR(0x80001009)                      <- OMX_ErrorHardware
E MediaCodec: Pending dequeue output buffer request cancelled
```

That last line is the symptom two separate disables chased. Setup always succeeded (`ACodec`
logs `setupVideoEncoder succeeded`); only the first `EmptyThisBuffer` failed. The original
`9ccbed5` message was *right* that C2D was to blame — but the library it named (`libC2D2.so`)
was present. The missing piece was the backend one level below it.

**Fix (staged):**

| Change | What |
|---|---|
| `vendor/xiaomi/Mi8937` | `libc2d30_bltlib.so` (32+64) from the **Mi8937 nightly** + `Android.bp` prebuilt + `PRODUCT_PACKAGES` |
| `device/xiaomi/Mi8937/proprietary-files.txt` | pinned entries so a future regen keeps them |
| `mithorium-common@9027d16` | re-enables the encoder in the six `media/media_codecs*.xml` |
| `hardware/qcom-caf/msm8953/media` | AVC entry restored in `mm-core/src/8937/registry_table{,_android}.c` (working tree now pristine upstream) |

**Provenance matters.** The DUT's `libC2D2.so` is the *nightly* build (`81c958…`), not stock A8
(`557294…`). The backend must come from the same nightly `vendor.img`, not from the A8 dump —
`libC2D2` ↔ backend is an internal ABI pair. Extracted root-lessly via
`brotli -d` → `sdat2img.py` → `debugfs -R dump`.

**Verified live** (blob pushed to `/vendor/lib`, OMX service restarted, *before* any flash):

| Path | Before | After |
|---|---|---|
| `scrcpy` (default encoder) | 0 bytes, dequeue cancelled | `OMX.qcom.video.encoder.avc`, 163186 bytes, 11 frames, **0 errors** |
| `adb shell screenrecord` | `Encoder failed (err=-38)` | 45495 bytes |

**Three red herrings — do not chase these again.** All three appear *identically* on the working
stock A11, or are swallowed:

1. `setParameter(allocateNativeHandle) ERROR: UnsupportedSetting` — by design, secure-session only.
2. `component does not support metadata mode; using fallback` — **output** port only;
   `OMXNodeInstance.cpp:1094` literally comments "don't log loud error". Input-side
   `venc_set_meta_mode()` returns `true` unconditionally.
3. `msm_vidc: err: DEFAULT: Calling 0x201002` — benign. `venus_hfi_session_set_property()` maps
   `-ENOTSUPP` → `rc = 0`. It *is* a real (cosmetic) bug:
   `msm_comm_set_color_format_constraints()` passes the HFI **wire** value
   `HFI_PROPERTY_PARAM_UNCOMPRESSED_PLANE_ACTUAL_CONSTRAINTS_INFO` (`0x201002`) where
   `hfi_packetization` expects the `hal_property` **enum** (`0x04000003`), so the property is
   silently dropped — exactly as on stock 3.18, which never sends it at all. Worth fixing
   someday for correctness; it is *not* the encode blocker.

**Structural note.** AVC is the *only* hardware encoder the 8937 OMX registry table exposes; the
`OMX.qcom.video.encoder.{hevc,vp8}` entries in the codec XMLs are vestigial (absent from that
table, so they never reach `MediaCodecList`). Disabling AVC therefore left **zero** hardware
encoders of any codec, and broke all system surface encode — scrcpy, `screenrecord`, camcorder.

**Retest after flash:** `scrcpy --list-encoders` should show `OMX.qcom.video.encoder.avc (hw)`
first; `scrcpy -m1024` should stream; **also test camcorder video recording** in the Camera app,
which shares the surface→AVC path. Wake the screen first — a dozing device creates the scrcpy
virtual display in state `OFF` (`policy=DOZE`) and yields zero frames for *any* encoder, a false
"encoder broken" positive.

**Method note.** This was closed by the three-device methodology: the rooted stock A11
(same silicon, same Venus firmware) was the witness. `grep /proc/<omx-pid>/maps` during a
*working* stock encode showed exactly which C2D backend loads — which no amount of reading
our own source would have revealed. See `feedback-blackbox-before-re`.

---

## 6. Volume quick-settings tile (no physical volume keys)

**Status:** Implemented — crash-on-click FIX STAGED (2026-07-07, needs build+flash)

**Crash root cause (reported: "crashes when clicked too many times"):** the implemented
`onClick()` diverged from the plan below — it called
`sendBroadcast(ACTION_CLOSE_SYSTEM_DIALOGS)` to collapse the shade. Since Android 12
(`LOCK_DOWN_CLOSE_SYSTEM_DIALOGS` compat change), any app targeting SDK 31+ that sends
that broadcast without holding `BROADCAST_CLOSE_SYSTEM_DIALOGS` gets a **SecurityException
thrown back through `sendBroadcast()`**
(`frameworks/base/services/core/java/com/android/server/wm/ActivityTaskManagerService.java:3521`).
The tile builds with `platform_apis: true` → targetSdk 36, and the manifest never declared
the permission → **every click kills the tile process**. It *looks* like it only breaks
after many clicks because `adjustVolume()` runs first (the volume panel still appears),
the service crash is silent, and SystemUI rebinds a fresh process on the next tap — only
rapid repeated clicks trip ActivityManager's crash-loop detection and surface the
"keeps stopping" dialog.

Secondary bug found during review: even with the permission granted, that broadcast is
self-defeating — SystemUI's `VolumeDialogControllerImpl` (line ~1368) dismisses the volume
dialog on `ACTION_CLOSE_SYSTEM_DIALOGS`, so the tile would race against closing the very
panel it just requested.

**Fix staged:** replace the broadcast with `StatusBarManager.collapsePanels()` (hidden API,
fine under `platform_apis: true`), which collapses only the shade and cannot dismiss the
volume dialog; declare `android.permission.STATUS_BAR` in the manifest
(protectionLevel `signature|privileged` — auto-granted to this platform-signed app, no
privapp allowlist entry needed).

**Validate after flash:** open QS, tap the tile 10+ times rapidly — volume panel should
pop each time, shade should collapse, no "VolumeTile keeps stopping" dialog, and
`logcat -d | grep -i volumetile` shows no SecurityException.

**Problem:** pepito has no physical volume buttons. There is no built-in volume QS tile in
this LineageOS/AOSP build to compensate.

**Step 1 — Fix `config_deviceHardwareKeys`:**

The Mi8937 overlay-lineage declares `config_deviceHardwareKeys = 83`, which includes bit
`0x40` (= 64, `KEY_MASK_VOLUME`) for a volume rocker pepito doesn't have.

```
83 = Home(1) + Back(2) + AppSwitch(16) + Volume(64)
 0 = correct for pepito — all navigation is software
```

Create `rro_overlays/xiaomi_pepito_overlay_lineage/` targeting `lineageos.platform`,
gated on `ro.vendor.xiaomi.device=pepito` (same pattern as `xiaomi_prada_overlay_lineage`):

- `Android.bp` — `runtime_resource_overlay`, `vendor: true`
- `AndroidManifest.xml` — `targetPackage="lineageos.platform"`, priority 800, isStatic
- `res/values/config.xml`:
  ```xml
  <integer name="config_deviceHardwareKeys">0</integer>
  ```

Register `xiaomi_pepito_overlay_lineage` in `device.mk` alongside `xiaomi_pepito_overlay`.

**Step 2 — Custom VolumeTile app:**

New directory `device/xiaomi/Mi8937/VolumeTile/`:

```
VolumeTile/
├── Android.bp
├── AndroidManifest.xml
└── src/org/lineageos/pepito/VolumeTile.java
```

`Android.bp` — `android_app`, `platform_apis: true`, `privileged: true`,
`certificate: "platform"`.

`AndroidManifest.xml` — declares a `TileService` with
`android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"` and
`android:icon` / `android:label` ("Volume"). Needs
`<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>`.

`VolumeTile.java`:
```java
public class VolumeTile extends TileService {
    @Override
    public void onClick() {
        AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
        am.adjustVolume(AudioManager.ADJUST_SAME, AudioManager.FLAG_SHOW_UI);
        collapseStatusBar();
    }
}
```
`ADJUST_SAME` + `FLAG_SHOW_UI` pops the system volume panel without changing the level.
`collapseStatusBar()` (inherited from `TileService`) dismisses the shade so the panel
is visible.

Add to `device.mk`:
```makefile
PRODUCT_PACKAGES += \
    VolumeTile
```

**Step 3 — Add tile to default QS set:**

Create `rro_overlays/xiaomi_pepito_overlay_systemui/` targeting `com.android.systemui`,
gated on `ro.vendor.xiaomi.device=pepito`:

- `res/values/config.xml`:
  ```xml
  <string name="quick_settings_tiles_new_default" translatable="false">
      internet,bt,dnd,cast,flashlight,airplane,rotation,wallet,alarm,controls,screenrecord,battery,custom(org.lineageos.pepito/.VolumeTile)
  </string>
  ```

Register `xiaomi_pepito_overlay_systemui` in `device.mk`.

## 7. Torch quick-settings tile — ✅ FIXED, FLASH-VALIDATED + COMMITTED 2026-07-29 (`d9dab112`)

**Symptom:** flashlight QS tile vibrates but never lights the LED. Capture flash
(camera app Flash mode) works fine, so the hardware and the daemon-side flash
driver path were never in question.

**Root cause chain (captured live on DUT1):**
1. SystemUI `FlashlightController` → `CameraManager.setTorchMode` →
   provider HAL `QCameraFlash::initFlash`.
2. `initFlash` reads the flash device node from
   `cam_capability_t.flash_dev_name` (filled by the mm-qcamera-daemon backend) —
   on pepito it comes back **empty**, so the HAL tries `open("/dev/")` →
   `QCamera <MCI><ERROR> initFlash: 178: Unable to open node '/dev/'` →
   returns `-EBUSY` → CameraService reports the misleading
   `setTorchMode: Camera "0" is in use` → tile aborts (haptic only).
3. Why empty: capability-struct layout drift between our LOS-era
   `cam_intf.h` and Palm's A8-vintage sensor-modules backend.
   `flash_dev_name` sits deep in the struct, right after the
   `analysis_info` region — the same neighborhood as the known
   0x0-analysis-resolution backend quirk. Early fields (`flash_available`)
   read fine; this late field reads zeros.

**Fix (committed `d9dab112`):**
`device/xiaomi/Mi8937/camera/mi8937/camera/QCamera2/util/QCameraFlash.cpp` —
if `hasFlash && flash_dev_name` is empty, self-discover the node by
enumerating `/dev/media*` for the `MSM_CAMERA_SUBDEV_FLASH` (=16) entity,
exactly mirroring the sensor-count probe in `mm_camera_interface.c` that
already works in the same process/domain. Kernel side verified:
`msm.c` sets `entity.name` to the devnode name (`v4l-subdev8` on DUT),
4.19 media core backport copies `group_id` in `MEDIA_IOC_ENUM_ENTITIES`,
and unknown-function v4l2 subdevs are mapped to `MEDIA_ENT_T_V4L2_SUBDEV`.
Inert on sibling variants (their backend fills the field). SELinux: both
`/dev/media*` and the flash subdev are `video_device`, which the provider
domain already opens under Enforcing at boot — no sepolicy change needed.

**Round 2 (2026-07-29, after first flash still failed):** the v1 guard only
triggered on an *empty* `flash_dev_name` — but the field actually contains
**garbage, not zeros**: hexdumping the logcat line showed the HAL opening
`"/dev/\x0c"` (byte 0x0c, invisible in the log, so it *looked* like
`'/dev/'`). Guard hardened: fall back whenever the name is empty OR
`access("/dev/<name>", F_OK)` fails.

**Downstream chain PROVEN live before rebuild:** 32-bit `flashtest` probe
(diag scratch; built with the nas-probe recipe on Stellaris16) ran the
HAL's exact ioctl sequence on `/dev/v4l-subdev8` as the provider will:
`CFG_FLASH_INIT` ok → `CFG_FLASH_LOW` → **LED physically lit**
(`led:torch_0` brightness=120 mid-burn) → `CFG_FLASH_OFF`/`RELEASE` clean.
Also verified via a media-enum probe that the entity is discoverable with
exactly the fallback's match: media0 model `msm_config`, entity id=11
name `v4l-subdev8` type 0x20000 group_id 0x10, contiguous ids.

**Validate after flash:** tap torch tile → LED on/off, no vibrate-only;
`logcat -s QCamera` should show `discovered flash node 'v4l-subdev8'`;
regression-check capture flash + camera open/close while torch on
(expect framework to arbitrate: torch drops while camera holds the unit).

⭐ Debug technique: an apparently-empty string in a logcat message can be
unprintable garbage — hexdump the log line (`logcat -d | grep -a … | xxd`)
before trusting `''`.

---

## 8. Removable-storage filesystems — exFAT (+UDF/ISO9660) — STAGED 2026-08-01

**Status:** STAGED, unflashed. User report: exFAT-formatted media does not mount.

**Problem:** pepito mounts removable media (USB OTG on pepito, SD on the siblings)
through vold's PublicVolume, which supports vfat, exfat, ntfs, ext4, f2fs and
iso9660/udf. Only vfat/ext4/f2fs actually worked: exFAT was missing on **both**
halves of the stack, and the ISO9660/UDF kernel drivers were off.

**Root cause (two independent gaps):**

1. **Kernel.** `CONFIG_EXFAT_FS` was `not set` in `mi8937_defconfig`. The driver
   source is already in the tree — `fs/exfat/` is the `linux-exfat-oot` backport
   merged in from `android13-4.19-kona` (Kconfig/Makefile already wired at
   `fs/Kconfig:146`, `fs/Makefile:84`) — it had simply never been enabled.
2. **Userspace.** vold's `Exfat::IsSupported()` requires `/system/bin/mkfs.exfat`
   **and** `/system/bin/fsck.exfat` to be `X_OK` *in addition to* `exfat` appearing
   in `/proc/filesystems`. `external/exfatprogs/` is in the tree, but unlike
   ntfs-3g (shipped by `vendor/lineage/config/common.mk`) Lineage leaves exfatprogs
   to the device tree, and Mi8937 never added it. Kernel driver alone = still no mount.

**Fix (staged):**

- `kernel/…/arch/arm64/configs/mi8937_defconfig`:
  - `CONFIG_EXFAT_FS=y`, `CONFIG_EXFAT_DEFAULT_IOCHARSET="utf8"`
  - `CONFIG_ISO9660_FS=y` + `CONFIG_JOLIET=y` (ZISOFS left off), `CONFIG_UDF_FS=y`
    — vold's `Iso9660.cpp` already tries `iso9660` then `udf` read-only for
    OTG optical/UDF-formatted media; both were dead ends without the drivers.
  - `CONFIG_NLS_UTF8=y` — needed for Joliet/explicit `iocharset=utf8` mounts.
    (exFAT itself does **not** need it: `super.c` special-cases the literal
    `"utf8"` iocharset and skips `load_nls()`.)
- `device/xiaomi/Mi8937/device.mk`: `PRODUCT_PACKAGES += fsck.exfat mkfs.exfat`
  (+ matching `PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST` entries, mirroring
  Lineage's ntfs pattern). Family-wide on purpose — every Mi8937/Mi8917 sibling
  has removable storage.

**Deliberately NOT changed:**

- **NTFS already works** and needs nothing: Lineage ships `mount.ntfs`/`mkfs.ntfs`/
  `fsck.ntfs` (ntfs-3g over FUSE, `CONFIG_FUSE_FS=y` is on) and vold hardcodes
  `fuse\tntfs` into its supported list. The in-kernel `CONFIG_NTFS_FS` stays off:
  it is the legacy read-only driver and would only shadow the rw ntfs-3g path.
- `CONFIG_MSDOS_FS` stays off — `vfat` already covers FAT12/16/32.

**No sepolicy work needed** (verified): `fsck.exfat` is already labelled
`fsck_exec` in `system/sepolicy/private/file_contexts:258` and vold has
`domain_trans(vold, fsck_exec, fsck)`; `mkfs.exfat` runs in vold's own domain
under the existing `allow vold system_file:file x_file_perms`. The `exfat`
fs type is already declared `sdcard_type` in `public/file.te:171`.

**Pre-build validation done on the netbook** (no full build needed):
`make ARCH=arm64 LLVM=1 O=… mi8937_defconfig` resolves all five symbols with no
unmet deps, and `make … fs/exfat/ fs/udf/ fs/isofs/ fs/nls/` compiles the
out-of-tree exFAT backport clean against 4.19 with the AOSP clang — the driver is
version-guarded down to 4.1 (`match_table_t` path for pre-5.6 instead of
`fs_context`/`fsparam_*`).

**Validate after flash:**
- `grep exfat /proc/filesystems`; `ls -l /system/bin/{mkfs,fsck}.exfat`
- `adb logcat -s vold` on insert of an exFAT USB stick via OTG → mounts rw,
  files readable/writable, unmount clean.
- Settings → Storage → format a stick as exFAT (exercises `mkfs.exfat`).
- Regression: a vfat stick still mounts; internal storage unaffected.

---

## 9. Capture flash out of sync with the shutter — ROOT-CAUSED, STAGED 2026-08-01

**Status:** STAGED, unflashed. User report: the LED fires, but not at the moment
the picture is actually taken. Kyle can reproduce on demand.

**Not an app problem.** Aperture (CameraX `LifecycleCameraController`) has no flash
timing surface at all: its `res/values/config.xml` overlay knobs are aux-camera /
video-mode / zoom-ratio only, and the CameraX prebuilt AAR builds `ImageCapture`
internally, so even `ImageCapture.Builder.setFlashType(FLASH_TYPE_USE_TORCH_AS_FLASH)`
— which *does* exist in the shipped `camera-core-1.7.0-alpha01.aar` and is CameraX's
standard escape hatch for devices with broken flash/capture sync — is not reachable
without patching CameraX itself. Keep it in the back pocket as a fallback only.

**Root cause: `pepito/camera.dtsi` deleted `qcom,switch-source` from `led_flash0`.**

`qcom,switch-source` is the *only* source of msm_flash's `switch_trigger`
(`msm_flash.c:910`). With it deleted:

1. `msm_flash_prepare()` (`msm_flash.c:582-592`) returns **-EINVAL** unconditionally
   for a `FLASH_DRIVER_PMIC` flash whose `switch_trigger` is NULL (`platform_flash_init`
   is only set for the GPIO/platform flash type, not ours).
2. `msm_flash_config()` calls `msm_flash_prepare()` at its tail and **returns that
   error** (`msm_flash.c:798-803`). So **every** `VIDIOC_MSM_FLASH_CFG` —
   INIT / LOW / HIGH / OFF / RELEASE — reports failure to the mm-camera daemon,
   *after* the LED side effects for that op have already been applied earlier in the
   same function. That is why the LED visibly lights while the daemon cannot
   sequence it: it never gets a success it can advance its flash state machine on.
3. `msm_flash_query_current()` (`msm_flash.c:697-710`) also short-circuits, leaving
   `max_avail_curr` at -EINVAL, so AEC cannot size the flash pulse either.
4. In `leds-qpnp-flash.c` the per-LED strobe-enable bits (0x80/0x40) are accumulated
   **only onto the switch node** (`:1346`); the switch is the node that actually
   strobes. Nothing drives it when msm_flash has no `switch_trigger`.

This also explains the "CFG_FLASH_INIT ok" reading in the [[torch-tile-flash-dev-name]]
probe — the LED lit, but the ioctl return was not the success it looked like.

**Evidence this is wrong, not deliberate** (the file's old comment claimed pepito's
single-LED wiring justified dropping the switch — the switch is not a second LED):

- **Stock Palm 8.1 keeps it**: `dts-3.19-pepito/pepito.dts:11269`
  `qcom,switch-source = <0x18f>` → `qcom,switch` / `led:switch`.
- **santoni**, the other single-source PMI8950 variant in this tree, narrows
  `qcom,flash-source` to `pmi8950_flash0` and leaves the switch alone
  (`xiaomi-msm8937/wingtech/msm8937/santoni/camera.dtsi:15`).
- Our `pmi8950_switch` node is already **byte-identical** to stock's `qcom,switch`
  (max-current 1000, duration 1280, id 2, current 625, `reg0` = `pon_spare_reg`).
- pepito is the only variant in the entire tree that deletes the property.

**Second divergence found in the same node — flash-LED hardware enable never asserted.**
Stock sets `pinctrl-names = "flash_led_enable","flash_led_disable"` +
`pinctrl-0/1` → TLMM **gpio33** (`rear_flash_led_enable/_disable`), and
`qcom,follow-otst2-rb-disabled` (`pepito.dts:8532`). Our tree *defines* those pinctrl
states (inherited from `msm8937-pinctrl.dtsi`) but nothing referenced them — they had
no phandle in the built DTB — so `leds-qpnp-flash.c` saw `led->pinctrl == NULL` and
never ran its `pinctrl_select_state(gpio_state_active)` (`:1459`); gpio33 sat wherever
the bootloader left it. Same property set as the QCT reference wiring in
`vendor-legacy/qcom/msm8917-cdp-mirror-lake-touch.dtsi:88`.

**Fix (staged)** — `kernel/…/dts/xiaomi-msm8937/pepito/camera.dtsi`:

- drop the `/delete-property/ qcom,switch-source;` line (keep the single-source
  `qcom,flash-source`/`qcom,torch-source` narrowing, exactly like santoni);
- add `&flash_led { pinctrl-names/-0/-1 = rear_flash_led_enable/_disable;
  qcom,follow-otst2-rb-disabled; }`.

Verified by compiling `xiaomi-msm8937/pepito.dtb` and decompiling it: the
`qcom,camera-flash` node now resolves to `led:flash_0` / `led:torch_0` / `led:switch`
like stock, and `qcom,leds@d300` now carries the pinctrl refs. A full property diff of
the flash block against the stock DTB leaves only: phandle numbering, our extra
`io-channels`/`die-temp` (newer driver's thermal-derate path), and item ⚠ below.

**Flash operating current — APPLIED in this same round** (Kyle's call, 2026-08-01).
`qcom,flash_0`'s `qcom,current` was **625 mA** here vs **1000 mA** on stock
(`pepito.dts:8544`). 625 is the upstream *dual*-LED default (625 + 625 across two
LEDs); pepito has one LED and stock drives it at the full 1000 mA. This is the
fallback `flash_op_current` msm_flash clamps to — and with `max_avail_curr` broken
(above), that clamp path is what was in use. Staged as an override in
`pepito/camera.dtsi`:

```dts
&pmi8950_flash0 {
	qcom,current = <1000>;   /* stock; upstream 625 is the dual-LED default */
};
```

⚠ Attribution caveat: because this ships with the timing fix, a brightness change
after flashing cannot be attributed to one or the other without backing this out.
`qcom,max-current` was already 1000 in both trees — only the operating value differed.

After this, the whole `qcom,leds@d300` block is at stock parity; the only residual
DTB differences are phandle numbering and our extra `io-channels`/`die-temp` (the
4.19 driver's IIO thermal-derate path, absent from the 3.18 driver).

**Reported symptom, refined (Kyle, 2026-08-01):** the flash fires **slightly before**
the shutter — visible as a flash reflection in a reflective subject. Consistent with
the diagnosis: the LED pulse is not sequenced against the snapshot frame, so it
completes just ahead of the exposure the daemon actually captures.

**Pre-flash evidence to capture on the CURRENT build** (proves the -EINVAL before the
fix lands, ~30 s on the DUT):

```bash
adb shell dmesg -w | grep -iE "msm_flash|qpnp.*flash" &   # then take a flash photo
# expect: "Enable/Disable Regulator failed ret = -22" from msm_flash_config
adb shell ls /sys/class/leds/            # led:flash_0 / led:torch_0 / led:switch present?
adb shell cat /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null | grep -w 33
```

**Validate after flash:**
- Take a flash photo in Aperture: LED pulse coincides with the capture; subject lit.
- `dmesg` free of the `ret = -22` line during capture.
- **Regressions to re-check** (both go through the same msm_flash LOW path):
  torch QS tile still lights (`d9dab112`), and torch-while-camera-open arbitration.
- Compare exposure against stock Silver if the pulse now looks over/under-bright,
  before touching the current value above.

### §9 addendum — the reflection photo (2026-08-01)

Kyle shot a glossy panel outdoors to catch the LED in-frame. Two readings:

1. **The LED reflection IS in the captured frame** → the LED was lit *during* the
   exposure. So "fires entirely before the shutter" is wrong; whatever the
   sequencing problem is, light and exposure overlap. Revise the symptom to
   "flash fires around the capture but far weaker than expected."
2. **It is a modest specular dot, not a blowout** — and Kyle expected "all white".
   That is what the missing-switch failure mode predicts: the LED is being driven
   at **torch** current, not flash current. `led:torch_0` is `qcom,current = <120>`
   mA; `led:flash_0` is 625 (now 1000) — a ~8x gap. If `msm_flash_high()`'s strobe
   never takes effect (the enable bits accumulate only onto the switch node,
   `leds-qpnp-flash.c:1346`) while `msm_flash_low()` lights the torch trigger
   directly, then **every "flash" photo is really lit by the AEC preflash alone**.
   Weak, and phase-locked to metering rather than to the snapshot frame.

⚠ Confound in that particular frame: it is a **daylight** scene (grass/trees/pavement
visible in the reflection), so AEC exposes for ambient and even a correct 1000 mA
strobe would read as a small bright dot, not a white-out. Judge flash strength in a
**dark room, matte subject ~1 m away**, not against ambient.

**Decisive test, no rebuild needed** — `diag-tools/flash-probe/flash-sample.sh`
polls every flash-block LED classdev and prints edges:

```bash
adb push diag-tools/flash-probe/flash-sample.sh /data/local/tmp/
adb shell sh /data/local/tmp/flash-sample.sh     # then take a flash photo
```

- only `led:torch_0` ever goes non-zero → **confirmed**: no main flash, preflash-only
  capture; the staged switch-source restore is exactly the fix.
- `led:flash_0` (+ `led:switch`) pulses → main flash does strobe, and the complaint is
  a current/AEC question rather than a sequencing one.
- `led:flash_0` pulses well before the shutter → genuine timing desync, keep digging.

Run it **before** flashing the fix (baseline) and again after.

### §9 addendum 2 — preflash-only hypothesis FALSIFIED (Kyle, 2026-08-01)

Kyle confirms on the bench: **there is a preflash, and it is the main strobe that
lands in the picture.** So `msm_flash_high()` does produce a real high-current
strobe and it does overlap the snapshot exposure.

Consequences for the record:

- **Addendum 1's "every flash photo is preflash-only" reading is WRONG — struck.**
  The strobe fires. My static read of the qpnp strobe-bit bookkeeping
  (`leds-qpnp-flash.c:1346`, enable bits accumulating only onto the switch node)
  was therefore incomplete; it was flagged as unverified and it did not hold. Do
  not re-derive that claim from source without a live check.
- **There may be no sequencing bug at all.** preflash → metering → main strobe at
  capture *is* the normal QCT AEC sequence. The original "out of sync with the
  shutter" perception is well explained by the preflash being visible as a separate
  event before the shutter. Treat the timing lane as closed unless the probe shows
  `led:flash_0` firing clearly outside the exposure.
- **The surviving complaint is power, and it has a clean mechanism.**
  `msm_flash_query_current()` returns -EINVAL with no `switch_trigger`, so
  `max_avail_curr` never reaches the daemon; AEC cannot size the pulse, and
  msm_flash falls back to `flash_op_current` — the 625 mA *dual*-LED default —
  instead of driving toward the 1000 mA the single LED is rated for. Both staged
  changes hit exactly that path: the switch-source restore unbreaks the query, and
  the `qcom,current = <1000>` override fixes the fallback.

**Expectation setting:** 1000/625 is 1.6x ≈ **two thirds of a stop**. Real and
visible on a matte subject in a dark room; it will not turn a single 2018 budget
LED into a white-out. Stock is the ceiling here — `qcom,max-current` was already
1000 in both trees, and headroom / clamp-curr / thermal-derate / vph-droop all
already match stock, so there is nothing further to squeeze without exceeding what
Palm shipped.

---

## 10. Variable torch brightness (flashlight slider) — IMPLEMENTED, unbuilt 2026-08-01

**Status:** STAGED across 4 repos, never compiled. Feature request: Kyle's Pixel has a
brightness slider on the QS flashlight tile; can pepito do the same?

**Yes — the hardware and kernel already support it; only three userspace gaps existed.**

| Layer | Before | Work |
|---|---|---|
| PMI8950 `led:torch_0` | current-driven, `qcom,max-current = <200>` mA | none |
| kernel `msm_flash_low()` | already takes a per-source current in `flash_current[]` | none |
| `QCameraFlash` (our HAL) | hardcoded one current | levels added |
| legacy `camera_module_t` | `set_torch_mode(id, bool)` — no strength in the ABI | vendor bridge |
| Lineage AIDL `CameraDevice` | `turnOnTorchWithStrengthLevel`/`getTorchStrengthLevel` → `OPERATION_NOT_SUPPORTED` stubs | implemented |
| HAL static metadata | no `ANDROID_FLASH_INFO_STRENGTH_*` | 2 tags added |
| `CameraManager` / CameraService | fully supports it | none |
| SystemUI | `FlashlightTileWithLevel.kt` **already exists upstream** behind aconfig `com.android.systemui/flashlight_strength` | flag enabled |

**⭐ Bug found on the way: the torch has been running at 120 mA, not 200.**
`QCAMERA_TORCH_CURRENT_VALUE` was 200, but `msm_flash_low()` honours a requested
current only when `req >= 0 && req < max_current` — **strictly** less than. With
`qcom,max-current = <200>`, `200 < 200` is false, so every torch-on silently fell back
to `qcom,current` = 120 mA. That matches the `brightness=120` reading recorded in
[[torch-tile-flash-dev-name]]. The new top level asks for **199**, so max torch is now
~66% brighter than any build we have ever shipped.

**Level map** (`QCameraFlash.cpp`, `kTorchCurrentMa`): 1→40, 2→80, **3→120 (default)**,
4→160, 5→199 mA. Level 3 reproduces the historical current exactly, so an untouched
slider behaves like the old build.

**Changes:**

1. `device/xiaomi/Mi8937/camera/…/util/QCameraFlash.{h,cpp}` — per-camera level state,
   `setTorchLevel()`/`getTorchLevel()`, and a shared `applyFlashState()` that issues
   `CFG_FLASH_LOW` at the level's current. Setting a level while the torch is lit
   re-issues immediately, so a slider drag tracks live. The mA table lives in the .cpp,
   not the header — the header is pulled into 4 TUs, 2 of which build `-Werror`.
2. `…/QCamera2Factory.{h,cpp}` — `setTorchStrength()`/`getTorchStrength()` mirroring
   `setTorchMode()` (incl. the `torch_mode_status_change` callback and the `-EALREADY`
   → success mapping a slider drag depends on), plus a shared `parseCameraId()` helper,
   plus the two `extern "C"` bridge symbols.
3. `…/HAL3/QCamera3HWI.cpp` — publish `ANDROID_FLASH_INFO_STRENGTH_MAXIMUM_LEVEL` and
   `_DEFAULT_LEVEL`, gated on `flashAvailable`. This is what makes the framework expose
   `turnOnTorchWithStrengthLevel()` at all.
4. `hardware/lineage/interfaces/camera/aidl/device/CameraDevice.cpp` — implement the two
   stubs. ⭐ **The bridge:** the legacy module ABI has no strength entry point, so the
   wrapper `dlsym()`s `qcamera_torch_set_strength` / `qcamera_torch_get_strength` out of
   the already-loaded HAL via `CameraModule::getDso()` (`mModule->common.dso`). A HAL
   that doesn't export them behaves exactly as before — dlsym returns null,
   `OPERATION_NOT_SUPPORTED`. **Nothing in this file is pepito-specific, so it is
   upstreamable to LineageOS** and helps any legacy-HAL device.
5. `vendor/lineage/release/aconfig/bp4a/com.android.systemui/flashlight_strength_flag_values.textproto`
   — `ENABLED`. The sibling `Android.bp` globs `*_flag_values.textproto`, so no bp edit.

**Not yet compiled** — no soong on the netbook. Expect the usual first-build friction.

**Validate after flash:**
- QS flashlight tile long-press / dialog → slider present, 5 steps.
- Slider drag changes output live (compare against a wall at fixed distance).
- `adb shell dumpsys media.camera | grep -i strength`, or
  `adb logcat -s CAM_FLASH` → `flash 0 -> 1 at level N (X mA)`.
- Level 5 should be visibly brighter than any previous build (120 → 199 mA).
- **Regressions:** plain tile tap on/off still works (`d9dab112` path); torch during
  camera open still arbitrates; capture flash unaffected (that is `CFG_FLASH_HIGH`,
  a different current entirely).

### §10 addendum — slider showed but did nothing: ROOT-CAUSED 2026-08-01, fix staged

First flash validated most of the chain and falsified my implementation of one step.

**What worked on-device:** HAL publishes `strengthMaximumLevel = 5` / `defaultLevel = 3`;
SystemUI shows the slider; `CameraService: turnOnTorchWithStrengthLevel: Torch strength
for camera id 0 changed to 1..5` logged success for every level; both bridge symbols
exported (`llvm-nm -D` → `T qcamera_torch_set_strength`) and present in
`camera.device-impl.lineage.so`; strace confirmed the `VIDIOC_MSM_FLASH_CFG` ioctl
reaching `/dev/v4l-subdev8` and **returning 0**. So dlsym, the AIDL wrapper, the factory
and the ioctl all worked.

**What didn't:** the LED never moved (`/sys/class/leds/led:torch_0/brightness` = 0).

**⭐ Root cause — `CFG_FLASH_LOW` is only legal from `MSM_CAMERA_FLASH_OFF` or `_INIT`**
(`msm_flash.c:767`). Changing strength means re-issuing LOW while the torch is already
lit, i.e. from state LOW — which lands in the else branch and is **dropped**. My
`setTorchLevel()` did exactly that, so the level could never change once lit. Matches
Kyle's report verbatim: "turns on after a minimum threshold and doesn't get brighter or
dimmer" — the *first* LOW (from INIT) lit at whatever level was current, and every
subsequent one was discarded.

**⭐⭐ Why it took so long: the rejection is invisible.** That branch is `CDBG`-only and
`msm_flash_config()` leaves `rc` at 0, so the ioctl "succeeds" all the way back up to
CameraService, which logs a successful strength change. Nothing in logcat, dmesg or
strace showed a failure. It only became visible with:

```bash
mount -t debugfs none /sys/kernel/debug        # if not mounted
echo "file msm_flash.c +p" > /sys/kernel/debug/dynamic_debug/control
dmesg -c >/dev/null; # take a torch action
dmesg | grep -i flash                          # -> "Invalid state : 2"
```

`2 == MSM_CAMERA_FLASH_LOW` (`msm_flash.h:30`: INIT, OFF, LOW, HIGH, RELEASE).

**Secondary damage:** the silent drop desyncs HAL from driver — `m_flashOn` gets set
while `flash_state` stays LOW — and the torch then stays dark, because
`setFlashMode(false)` short-circuits on `-EALREADY` and never sends the `CFG_FLASH_OFF`
that would clear it. Recovery without a reboot: kill the camera provider; the fresh HAL
has `m_flashFds = -1`, so the next torch action re-issues `CFG_FLASH_INIT`, which resets
`flash_state` to INIT.

**Fix (staged):** `applyFlashState()` now issues `CFG_FLASH_OFF` before `CFG_FLASH_LOW`
whenever turning on. From LOW that is a real transition; from OFF/RELEASE it is a
harmless no-op leaving the state where LOW needs it. Idempotent, and it re-syncs the
driver whenever `m_flashOn` has drifted. Also promoted the level log from LOGD to LOGI
so the requested level is visible without debug props.

⚠️ **Self-inflicted detour:** I drove `/sys/class/leds/led:torch_*/brightness` directly
to characterise the PMIC. That bypasses msm_flash's state machine and desynced it,
which is what killed the torch mid-session and sent me chasing a latched `open_fault`
that was never latched. **Drive the torch through the HAL, or expect to desync the
driver.** Direct LED writes are fine only for reading `reg_dump`.

**Confirmed good along the way** (keep, these are real):
- kernel scales torch current correctly: 40 mA → `REG_0xd342 = 0x03`, 199 mA → `0x0e`
  (`val = mA * 15 / 200`, `FLASH_TORCH_MAX_LEVEL = 0x0F`, 4-bit register).
- the torch current register is written **only** by the switch node's work item
  (`leds-qpnp-flash.c:1373`, `flash_node->id == FLASH_LED_SWITCH`) — so without the
  §9 `qcom,switch-source` restore, variable torch brightness could never have worked
  at all, whatever the HAL sent.
- USB drops on this bench every time the LED switches — read-only polling is stable,
  LED writes are not. Related: [[usb-adb-auth-prompt-storm]].

## 11. "Use SIM" toggle trap — ROOT-CAUSED in QCRIL, mitigation STAGED 2026-09-12

**Symptom:** Settings → SIMs → "Use SIM" off then on leaves `gsm.sim.state=NOT_READY`; the
framework re-sends `ENABLE_UICC_APPLICATIONS` 4× (5 s apart) and qcril answers
`GENERIC_FAILURE` every time. (The July "qcril's getter always answers true" story in
`PLAN-qmux.md` is FALSIFIED — the framework and AOSP are correct at both layers.)

**Severity (measured on `9c2e6b00`, build 20260913, US Mobile/Verizon-profile SIM):**
- The wedge **survives a reboot**. The disable persisted `USER_PREF=0` in
  `qcril.db:qcril_manual_prov_table`; at boot the modem auto-provisions the USIM, then
  qcril reads `USER_PREF=0` and deactivates it — through exactly the buggy path — and
  every later ENABLE fails the same way. A user has no recovery (no root, no qcrild restart).
- `setprop ctl.restart qmux_qcrild` heals in ~6 s: the fresh process finds the modem
  *already* deprovisioned, its boot-time deactivate is a harmless no-op (both responses
  err 0, session cache stays clean), and the framework's ENABLE then activates
  (try 1: CDMA ok / GW err 38, writes `USER_PREF=1`; try 2: mode-pref 1, GW ok → LOADED).

**Root cause (prebuilt `libril-qc-hal-qmi.so`, verbose `persist.vendor.radio.adb_log_on=1`):**
- Because the card carries a **CSIM** app next to the USIM, `qcril_qmi_prov_get_sub_mode_pref_*`
  computes mode-pref **3 (GW+1X)** even though only the GW session is ever provisioned
  (1X primary is `0xFFFF` on the modem — `nas-probe uim`).
- Deactivate with mode-pref 3: GW session → state 3 (DEACTIVATION_IN_PROGRESS), 1X "ignored"
  (already 0); the QMI callback then calls `qcril_uim_update_prov_session_type
  session_type:1 state:0` — it clears the **1X** slot instead of GW. GW_PRI is stuck at 3
  for the life of the process.
- Activate: `qcril_uim_find_prov_session_type` sees `GW_PRI:3` → "Cannot Activate
  RIL_sub_type: 0" (GW never sent, `gw_err_code 26` NO_EFFECT synthesized); the 1X/CSIM
  activate is sent and the modem answers 0x3 INTERNAL (`cdma_err_code 38`); 2 expected
  responses both fail → GENERIC_FAILURE.
- USIM-only cards (mode-pref 1) cannot hit the clobber; every Verizon-profile SIM can.
- `ril.subscription.types=RUIM` (`mithorium-common/system.prop:18`, EMPTY on stock) is NOT
  the mechanism — the string does not occur in the blob. Still a stock divergence; unrelated.
- Stock A8.1 has no toggle / IRadio 1.5, so there is no stock witness for this bug.

**Mitigation (staged, unbuilt):** make the sequence unreachable — one carried AOSP patch.
- `frameworks/opt/telephony` `GsmCdmaPhone.canDisablePhysicalSubscription()` returns false
  when `ro.telephony.uicc_apps_toggle=false` (default true; new fork — add to `TAG_REPOS`
  + the changelog repo set + a personal remote at release time).
- `device/xiaomi/Mi8937/device.mk` sets the prop under `TARGET_DEVICE_PEPITO`.
- Every Settings entry point (`SimsSection`, `MobileNetworkMainSwitchPreference`,
  `ToggleSubscriptionDialogActivity`, `SimOnboarding*`, `ChooseSimActivity`) keys off
  `SubscriptionManager.canDisablePhysicalSubscription()`, so the switch disappears for
  physical SIMs; eSIM profiles (`isEmbedded`) keep theirs. Boot-time re-apply is driven by
  the modem's `areUiccApplicationsEnabled`, not this check, so nothing else changes.
- Validation on flash: Settings → SIMs shows no "Use SIM" switch; `service call isub 45`
  → `0` (was `1`); `service call isub 46 i32 0 i32 1` — the ISub call is still honoured
  by the service (the patch hides UI, it is not a server-side guard), so do NOT run it on
  a unit you care about.
- Not chosen: an auto-heal (restart `qmux_qcrild` when ENABLE fails) — needs sepolicy for
  a `ctl.` prop from `system_server`/radio and leaves the persisted `USER_PREF=0` race at
  boot; hiding the switch is strictly safer.

**Standing defects noticed on the way:**
- `/data/vendor/radio/iccid_0` is `null,null,null` (mtime = first boot + 60 s, never
  rewritten) vs stock `<iccid>,mcc,mnc`. RESOLVED as non-defect: it is written by
  `qcril_qmi_pdc_set_sim_info`, the PDC/MBN carrier-config loader's SIM-info file, and only
  gets real values once an MBN db is loaded (`persist.vendor.radio.{sw,hw}_mbn_loaded` are
  0 here — the parked MCFG lane, `PLAN-mcfg.md`). Nothing to fix on its own.

### §9 addendum 3 — 2026-10-22 bench measurement on 24.0 `20261017` (new2): the strobe DOES land in the frame; the no-strobe case is still unreproduced

Trigger: a user reported the flash "out of sync with the shutter again" with a video. The video
was not on disk anywhere (Downloads/Videos/repo/tmp searched) — still needed. The 08-01 DT fix
(`6b6afaf52bd4`) has shipped in every release since 23.2 `20260802`, so the report is on a build
that carries it.

**Instrument that works:** kernel dynamic debug on the flash subdev, NOT the sysfs poller —
`flash-sample.sh` polls at ~80 ms and MISSED every one of the ~100 ms strobes (it reported
"torch only" for shots whose photos were strobe-lit). Recipe (root):
```
mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo "file msm_flash.c +p" > /sys/kernel/debug/dynamic_debug/control
dmesg -c >/dev/null; <take photos>; dmesg | grep msm_flash_config   # types: 0 INIT 1 RELEASE 2 OFF 3 LOW 4 HIGH
```
Kernel printk time ≠ logcat `-v monotonic` time: measure the offset with `log -t MARK a; echo MARK > /dev/kmsg`
(new2: logcat = dmesg + 1.277 s). `/proc/uptime` = monotonic + suspended time (new2: +85125 s).
HAL frame timeline: `setprop persist.vendor.camera.hal.debug 4` (numeric) → `handleMetadataWithLock:
valid frame_number = N, capture_time = <SOF ns>` and `processCaptureRequest ... stream format = 33` = the BLOB
request. Aperture's CameraX runs on the camera2-pipe backend (logcat tag `CXCP`, enable with `log.tag.CXCP DEBUG`).
⚠️ `adb shell 'pkill -f foo.sh; dmesg'` kills itself (the pattern matches the wrapper shell) — run dmesg separately.

**Measured sequence, AUTO flash, dark room, 3 kernel-traced shots (all identical):**
| event | t rel. to snapshot SOF |
|---|---|
| key press / takePicture | −0.9 s |
| precapture trigger → AE_STATE PRECAPTURE | −0.65 s |
| `CFG_FLASH_LOW` (torch 120 mA preflash) | −0.60 s, lasts ~0.40 s |
| `CFG_FLASH_OFF` (preflash end, AE back to FLASH_REQUIRED) | −0.20 s |
| CameraX submits the still request | −0.19 s |
| `CFG_FLASH_HIGH` (1000 mA, not clamped) | **−30 ms** |
| snapshot SOF (`capture_time`), exposure 21–33 ms, readout skew 33–40 ms | 0 |
| `CFG_FLASH_OFF` | **+68 ms** |
| shutter notify → CameraX `onCaptureStarted` → Aperture plays the click | +70 ms (+ audio latency) |
| JPEG encode starts | +0.2 s |

So the strobe window (−30…+68 ms) covers the whole rolling-shutter frame (−21…+61 ms) with only
~9 ms / ~7 ms of margin on either side. All six test photos: EXIF flash=25 (fired), strobe-lit, no band.
What a bystander sees: a long dim preflash, a dark gap (70–170 ms), a 100 ms strobe, then the
click ~100–150 ms after the strobe. Whether stock looks different is UNKNOWN — no stock witness on the bench.

**No-strobe candidates (the case Kyle wants chased), none reproduced on new2 at 100 %:**
1. **PMIC VPH droop** — `qcom,vph-pwr-droop-enabled` at 3000 mV (pmi8950.dtsi): hardware cuts the strobe
   when the 1 A pulse sags an aged/cold/low cell below 3.0 V. No log, no IRQ. Battery-dependent, stock has
   the same node. Test = dut1 (72 % SoH) at low SoC with the kernel trace on: HIGH issued, photo dark.
2. **Timing margin** — the daemon's window has <10 ms slack each side; the qpnp strobe runs from a
   workqueue (`schedule_work`, no debug hook), so scheduling latency under load could push the light
   out of the frame while the LED visibly fires. Instrument = the photo itself: a uniform white sheet
   at 30 cm, flash ON, row-brightness profile shows where the strobe fell relative to readout.
3. **AUTO skips HIGH after preflash metering** (close bright subject) — would look like "flash fired,
   shot taken without it". Needs a close subject in front of the lens to test.
4. Ruled out: `qcom,power-detect-enabled` / die-temp derate are OFF (`max_allowed_current` reads 0 =
   no derate), so `flash_current_max=0` on the battery psy is harmless; the `open_fault` latch tests a
   variable that is still 0 on the torch-off path, so it can never trip; msm_flash re-INITs its state on
   every camera open, so a stale LOW state cannot drop HIGH.

Side finding: `/sys/class/power_supply/battery/flash_active` stays 1 after the camera closes (the
charger keeps its 1 MHz flash switching frequency) — leak in the qpnp turn-off path, harmless but note.
Bench gotchas: a face-down unit refuses to wake (proximity); `svc power stayon usb` + swipe + unlock;
Aperture starts over the keyguard as the secure camera. Aperture's live prefs are NOT the legacy
`shared_prefs` XML (editing `photo_flash_mode` there did nothing).

### §9 addendum 4 — 2026-10-22 PM: the user's video deconstructed; ON mode traced; no-strobe = battery/PMIC droop (most likely)

**Reporter's facts (via Kyle):** battery **44 %**, flash **ON**, preflash visible, **no strobe, picture dark.**

**Video = a screen recording of Aperture's own preview** (11.8 fps, audio track is digital silence, so no click
to place). Frame brightness (first 13 s): shutter tapped at ~6.8 s → preview lit by the preflash torch for
**~1.1 s** (two overexposed frames, then the preview AE settles) → preview dark at ~8.0 s → one fully black
frame at ~8.3–8.45 s (the capture freeze) → dark preview. A 100 ms strobe would never show in a stalled
preview, so the video cannot separate "HIGH never issued" from "HIGH issued, hardware cut"; the dark photo
says no light reached the exposure. Their preflash is ~1.1 s vs 0.4 s on new2.

**ON mode traced on new2 (100 %, two shots):** identical to AUTO — LOW 120 mA 0.40 s → OFF → HIGH 1000 mA at
SOF −29 ms → OFF at +69 ms. CameraX `flashMode = 1, flashType = 0`. Photos strobe-lit. So the daemon's ON
sequence is correct on a healthy cell; the reporter's unit differs in *state*, not in sequence.

**Why 44 % can kill the strobe and not the preflash:** the PMI8950 flash block has `qcom,vph-pwr-droop-enabled`
at **3000 mV** (register 0xd35a = 0xd1 confirms it is armed on new2). The 1 A strobe on an aged cell (ESR 0.3–0.5 Ω
plus the system load) sags VPH below 3.0 V → the PMIC cuts the flash in hardware, no log, no IRQ. The 120 mA torch
preflash never sags that far. **Stock parity confirmed from the Palm GPL 3.18 source**
(`Pepito_GPL_SourceCode/.../msm-pmi8950.dtsi:536-606`): same droop 3000/10, thermal derate 100, self-check,
charger-support, and — like ours — **no `qcom,power-detect-enabled`**, so neither stock nor we derate the
strobe to what the battery can supply; both just let the PMIC cut it. ⇒ not a ROM regression by config;
our heavier A17/4.19 system load during capture could make the sag deeper than stock (unmeasured).

**Mitigation candidate (unbuilt):** enable `qcom,power-detect-enabled` so `msm_flash_query_current` →
`qpnp_flash_led_get_max_avail_current` → charger `FLASH_CURRENT_MAX` derates the pulse instead of
hard-cutting it. Blocker: `flash_current_max` reads **0** on new2 at 100 % because
`smbchg_calc_max_flash_current()` bails on the legacy BCL current read (`CONFIG_MSM_BCL_PERIPHERAL_CTL_LEGACY`);
OCV and resistance ARE available from `qpnp-fg.c`. With power-detect on and that 0, every strobe would be
refused ("battery too low for flash") — fix the calc (fall back to FG `current_now`) before flipping the flag.

**To confirm before touching anything:** (1) ask the reporter whether the strobe works at ≥80 % and how old
the battery is (cycle count / `charge_full`); (2) bench: dut1 (72 % SoH) discharged to ~45 %, flash ON,
`msm_flash.c` dyndbg — expect HIGH issued, photo dark, `voltage_now` sag; (3) optional: the preflash length
on a weak cell (1.1 s vs 0.4 s) hints AEC convergence suffers too.

### §9 addendum 5 — 2026-10-22 PM2: reporter says 100 % + charging ALSO fails ⇒ droop dead; fleet sweep; one bench reproduction

**New tool: `diag-tools/flash-probe/flash-trace.sh [-s SERIAL] [--auto SECS]`** — arms `msm_flash.c` dyndbg +
HAL debug (closes Aperture first so the HAL re-reads its level), records logcat, measures the kernel↔logcat
clock offset with a marker, then prints the LOW/OFF/HIGH/OFF ioctls relative to the snapshot frame's SOF,
grades the photo (EXIF fired bit + mean luminance) and gives a verdict. Reporter instructions in the header.
⚠️ two copies running against one unit interleave their reports (happened once on gold).

**Fleet sweep, flash ON, dark room, all 24.0 `20261017`:**
| unit | cell | shots | HIGH vs SOF | photo |
|---|---|---|---|---|
| new2 | 276 mΩ, 100 % | 2 (ON) + 6 (AUTO) | −30…+68 ms | all FIRED, lit |
| dut1 | 697 mΩ, 522 mAh, charging | 1 idle + 2 under 4× `yes` load | −93…+13 ms | all FIRED, lit |
| gold | 161–419 mΩ, 3.7–4.1 V | 1 + 2 idle + 3 under load | −115…−5 … −88…+19 ms | **shot 1 NOT FIRED, dark**; rest lit |
| silver | stock A8, unrooted | — | not traceable | (ask Kyle for a visual ON shot) |

**The one reproduction (gold shot 1, 11 min after boot, −835 mA system draw at 3.70 V, 37 °C):** kernel saw
LOW 178 ms → OFF → **406 ms gap** → HIGH 74 ms → OFF — HIGH was commanded, but EXIF `flash=24` (daemon's
`CAM_FLASH_STATE` for the captured frame = not fired, see `mm_jpeg_exif.c:334`) and the photo is dark
(meanY 41 vs 120–150). So the strobe was applied to a *different frame* than the one the JPEG came from:
the daemon's flash sequencing slipped relative to the capture — "flash after the shutter", literally.
Not the PMIC (EXIF is the daemon's own belief; it cannot see a hardware cut). Could not re-trigger it with
CPU load (gold reached 54 °C / health=Overheat under the loops; strobes still landed).

**Status:** mechanism = daemon frame-slip, trigger unknown (first-launch / startup load is the only hint;
the reporter's 1.1 s preflash vs our 0.4 s points the same way: slow AEC on their unit). Next = the
reporter runs `flash-trace.sh` (deterministic on their unit) — the HIGH-vs-SOF line and the EXIF bit will
say whether HIGH is issued at all, and where it lands. Bench: retry gold cold-boot + immediate shot.

**Addendum 5, reboot retry (Kyle asked):** warm-rebooted gold from adb, first shot at uptime ~118 s, then two
more, then a secure-camera instance started over the keyguard and shot after unlock (`--keep`): **4/4 FIRED and
lit** (HIGH at SOF −118…−152 ms, OFF −12…−46 ms; post-boot gap preflash→HIGH 487 ms, made of ~240 ms
framework→HAL latency on the still request). The one failing shot (3.70 V, −835 mA, Kyle's cold boot) stays
unreproduced on the bench; the reporter's unit is the deterministic one — ship them `flash-trace.sh`.

### §9 addendum 6 — 2026-10-22 evening: REPRODUCED on gold, two distinct mechanisms (VPH-droop clamp = the natural one; daemon frame slip)

**New instruments (all live, no rebuild):**
- `file leds-qpnp-flash.c +p` dyndbg logs every PMIC flash register write with a timestamp. A normal HIGH writes
  `0x4F`→0xD342 (1000 mA) and `0x80`→0xD347 (strobe on) within 4 ms of the ioctl; OFF clears 0xD347 within 0.1 ms.
  So the ioctl times ARE the LED times (minus the PMIC ramp), and the driver always programmed 1000 mA, including
  in every failing shot below.
- `echo 1 > /sys/kernel/debug/flashLED/enable_debug` makes the driver clear and arm the flash INT latch before each
  strobe; afterwards read it via `cd /sys/kernel/debug/regmap/spmi0-03; echo 0xd318 > address; echo 1 > count; cat data`
  (regmap debugfs is read-only, so no threshold experiments). **Every lit strobe latched `0x0c`; every
  uniformly-dim strobe latched `0x1c`** — bit 0x10 is the VPH-droop event.
- VPH ADC: `/sys/bus/iio/devices/iio:device1/in_voltage7_input` (PM8937 vadc), ~3.5 ms per read from a shell loop
  that echoes into /dev/kmsg — catches the sag shape, not the µs transients the 10 µs droop comparator sees.
- Stall injector: a shell loop on `/dev/kmsg` that `kill -STOP`s a camera process the moment a given `msm_flash_config
  type N` line appears, then `-CONT`s it after D seconds.
- ⚠️ `diag-tools/flash-probe/flash-trace.sh` now arms that latch and prints `flash INT latched (0xd318)`, a
  **VPH DROOP CLAMP** verdict when bit 0x10 is set, and any `Skipping sof`/`Remap pending request`/`reporting error
  frame` line within −400…+150 ms of the snapshot SOF as **FRAME SLIP**.
- Bench fact: gold's USB is SDP, `usb/current_max` = 500 mA. With the camera running, the battery covers the rest even
  while status says "Charging" (that is why the 12:17 failure read "Charging, −835 mA").

**Attempts (gold, 24.0 `20261017`, flash ON, dark room unless noted; dim = meanY ≤ 52 vs 117–124 lit):**
| # | condition | shots | failures |
|---|---|---|---|
| 1 | warm, Full/charging, relaunch each shot (incl. 2 after flash-mode cycling) | 12 | 0 |
| 2 | first shot after 40 min asleep, 24.5 °C, Full, −438 mA, GMS phenotype storm in logcat (`b0`) | 1 | **1** (EXIF 25, uniform Y 51) |
| 3 | battery only (`charging_enabled`=0), 97→87 %, 26–36 °C | 10 | 0 (VPH min 3.26–3.38 V) |
| 4 | battery only + 4× `yes` nice 0, 85→79 % | 3 | 0 (VPH min 3.11–3.14 V) |
| 5 | battery only + 8× `yes` nice −10, 81→73 % | 3 | **2** (EXIF 25, uniform Y 45–46, latch 1c) |
| 6 | 500 mA USB + 8× `yes` nice 19 (current only, no starvation), 71 % | 3 | **3** latch 1c (Y 45, 46, 91), VPH min 3.05–3.34 V |
| 7 | late still request: SIGSTOP provider or cameraserver 300 ms at preflash end (gap 402–443 ms, like the 12:17 shot) | 2 | 0 |
| 8 | SIGSTOP mm-qcamera-daemon 300 ms at preflash end | 1 | 0 |
| 9 | SIGSTOP mm-qcamera-daemon right after HIGH for 40 / 60 / 80 ×3 / 150 ms | 6 | **6** (EXIF 24 Y 86 banded / EXIF 24 Y 75 banded / EXIF 16 Y 24–40, a third of the frame black / no photo) |
| 10 | SIGSTOP provider right after HIGH, 100 / 150 ms | 2 | 0 |
| 11 | ion system-heap pool drained before the shot | 4 | 0 (snapshot alloc stayed 8 ms) |
| 12 | `adb reboot`, unlock, shoot from uptime ~60 s: shots 1–2 of each boot (×3 boots) | 6 | **6** (rb1_1 Y 85; rb1_2 no photo + SOF skip + error frame, latch 1c; rb2_1 no photo, latch 1c; rb2_2 Y 47, latch 1c; rb3_1 Y 52, latch 1c, VPH 3.11; rb3_2 Y 48, latch 1c, VPH 3.07) |
| 13 | same boots, shots 3+ (uptime ≥ ~105 s) | 10 | 0 (latch 0c) |
(Kyle's addendum-5 reboot retry shot first at uptime ~118 s, which is why it was 4/4 lit.)

**Mechanism 1 (the natural one, reproduced 5× + b0): PMIC VPH-droop clamp.** When the 1 A strobe plus a heavy
system load comes out of the battery (boot/GMS storm, CPU load, a 500 mA USB port), VPH dips below the
`qcom,vph-pwr-droop-threshold` 3000 mV for >10 µs and the PMI8950 drops the LED to `qcom,clamp-curr` = 200 mA for the
rest of the pulse. Signature: kernel sequence normal (LOW→OFF→HIGH 1000 mA→OFF, strobe register written on time),
HIGH lands at SOF −92…−150 ms like lit shots, EXIF **25 (FIRED)** (the daemon cannot see the clamp), photo
**uniformly** dim (no rolling-shutter band: 200/1000 mA ≈ 20 % light, meanY 45–52 vs 120), latch 0xd318 = **1c**.
Example `rb3_2` (2nd shot, uptime 95 s, 66 %, 3.77 V, −701 mA, 41 °C), SOF-relative: takePicture −930, precapture
trigger −919, LOW −857, AE 4→5 −828, OFF −664, AE 5→4 −590, PRE_CAPTURE completed −273 (CameraX slow under boot
load), still request submitted −270, BLOB request in HAL −126, HIGH −99 (strobe reg on −95), set_parms −57, OFF +7,
BLOB SOF 0, onCaptureStarted +74. VPH 3.72 V before, 3.07 V sampled during the strobe; lit shots on the same boot
3.92 → 3.23 V. b0 (100 %, Full, on USB) fits the same class: a full battery does not protect gold when the battery is
the one supplying the load.

**Mechanism 2 (induced; seen naturally once): camera-daemon frame slip.** If mm-qcamera-daemon misses a SOF in the
~100 ms between booking the BLOB request and its frame, MCT logs `Skipping sof (current_frame, kernel_frame)`,
`Remap pending request by N`, `Delay all frame by N`, and the BLOB moves to a later sensor frame while the strobe
(already ON) does not. Signature: kernel sequence normal, EXIF **24 / 16 (not fired)** = the daemon's own flash state
for the frame it actually captured, photo dark and **banded** (rolling-shutter edge of the strobe). Example
`stD40high`: LOW −483, OFF −284, still request −230, HIGH −123, daemon stopped ~4 ms later for 64 ms, set_parms −112,
OFF −15, `Skipping sof`/`Remap by 1` −4, SOF 0 → EXIF 24, meanY 86 with columns 40…125. **This is the 12:17 failure's
signature** (EXIF 24, meanY 41). Natural instance: `rb1_2` (2nd shot after boot), SOF skip at −6 ms, the daemon cut
the strobe to 25 ms (HIGH −148, OFF −123), AXI OUTPUT_ERROR on the BLOB frame, HAL "reporting error frame", no
photo saved. Merely delaying the still request (rows 7, 10) does NOT break the shot: the 406 ms gap of the 12:17 shot
is a symptom of load, not the cause.

**Correlate:** in every natural failure the HAL's picture-channel buffer allocation (`request: 3657` → `set_parms`)
took 60–135 ms instead of 8–13 ms, and HIGH fired 56–98 ms before the BLOB's set_parms instead of 15–41 ms: the
system was under memory/CPU pressure. Draining the ion pool alone did not recreate it (row 11).

**What this means for the reporter (100 % + charging, deterministic):** most likely Mechanism 1 on a worn cell
(higher ESR ⇒ the sag crosses 3.0 V at any SoC, and a charger cannot follow a 10 µs edge). Stock has the same
droop/clamp config (addendum 4), so it would clamp too. Our A17 system draws more current during capture, which
deepens the sag (unmeasured on stock). The updated `flash-trace.sh` now separates the two classes: latch `1c` +
EXIF FIRED + uniform dim = droop; FRAME SLIP line + EXIF not fired + banded = daemon.

**Mitigation candidates (none built, need Kyle):** (a) raise `qcom,clamp-curr` 200 → ~500 mA, so a clamped strobe is
still half power (watch for a brown-out if the sag gets deeper); (b) lower `qcom,current` 1000 → ~750 mA for the main
flash (less sag, −0.4 EV); (c) `qcom,power-detect-enabled` after fixing smbchg `flash_current_max` (addendum 4);
(d) for Mechanism 2, give mm-qcamera-daemon a camera task profile / higher priority (it runs nice 0 in the root
cgroup; stock does the same).

Bench gotchas: with `charging_enabled`=0 the unit counts as unplugged, so `svc power stayon` stops working;
right after boot a photo whose save is still pending can be lost when the next `flash-trace.sh` run force-stops
Aperture (rb1_2/rb2_1 "no photo"); `pepito-unlock` failed on gold over USB because the uiautomator dump runs before
the bouncer is up (fixed copy: wake, swipe 360,1000→360,300, then draw on the known grid 73,465–647,1039).
Raw data: `/tmp/flashsync/soak-agent/` (every shot's .txt/.dmesg/.logcat/.jpg) and `/tmp/flashsync/agent/`
(drivers: shot.sh, rebootsoak.sh, vph.sh, stall.sh, summ.py, timeline.py).

### §9 addendum 7 — 2026-10-22: "Flash power" tweak STAGED (unbuilt) — `staging/flash-power/`

Kyle's call: don't clamp everyone; give users the choice. Three patches (kernel `msm_flash.c`
module param `flash_cap_ma` applied in `msm_flash_high()`; `init.gotweaks.rc` trigger on
`persist.gotweak.flash_ma`; LineageParts ListPreference "Flash power" Full/Reduced/Low =
0/700/400 mA under a new Camera category, default Full). Applies live, preflash/torch untouched,
no new sepolicy grant (vendor_init already writes sysfs_type). README has the apply + validate
steps; gold's first-two-shots-after-boot droop is the acceptance test.

### §9 addendum 8 — 2026-10-22 night: "Flash power" VALIDATED on gold (local build, nothing pushed)

**Build.** Builder tree = the pushed fork heads (= release 20261017: kernel `253a9ff4e4d1`,
mithorium-common `4dc209b`, LineageParts `174b80df`; checked with `git fetch`, every manifest project +0), so
`SKIP_SYNC=1 build-lineage24-remotely.sh --gapps` gave 20261017 + the three patches → `24.0-20261023-SNAPSHOT-
Mi8937_gapps` (UTC date). Warm out/, incremental: update-api 1:41 + bacon 3:55 (rebuild 1:39 + 3:07). Patch drift:
kernel + mithorium-common applied as-is; LineageParts' 3 hunks (arrays/strings/GoTweaksSettings imports) failed on
24.0 context (MGLRU row, ewd arrays, GMS-doze category), ported by hand with the same semantics.
**Bug found in the staged kernel patch:** the kernel compiles THREE `msm_flash.c` (drivers/media/.../camera_v2,
techpack/camera-legacy, techpack/camera-legacy-m, all `CONFIG_MSMB_CAMERA`), and `camera_legacy_init()` enables the
legacy stack on every Xiaomi msm8937 mach, so pepito's flash ioctls go through **techpack/camera-legacy**. The patch
hit camera_v2: `/sys/module/msm_flash/parameters/flash_cap_ma` appeared and took 400, but dmesg still said
`msm_flash_high:653 high_flash_current[0] = 1000` (camera-legacy's line numbers) and gold still drooped (rows
low72 below). Moved both hunks to techpack/camera-legacy and dropped them from camera_v2. Keep ONE definition:
all three share KBUILD_MODNAME `msm_flash`, so a second `module_param` would collide in sysfs. Rebuilt, reflashed
(dirty, no wipe; kernel #23 18:25). `staging/flash-power/*.patch` now hold the exact 24.0 `git diff`s that were
validated. The builder trees are reverted to clean HEAD, so nothing unpushed can ride into a release.

**Flash:** `flash-staging.sh gold --no-unlock` ×2, data kept. Step 1 OK: the PVG100 System Tweaks → Camera → "Flash
power" row reads "Full (1000 mA, stock). Lower this if…"; prop empty, node 0, no AVC. Picking "Low (400 mA)" in the
UI sets prop 400 and the node reads 400 within 200 ms (live, no reboot, no denial); picking Full sets 0 again.

**Gold at 97–100 % (4.15 V) did NOT droop** (2 boots × 2 shots, latch 04/0c, lit). The first-shots-after-boot
droop needs a lower SoC (addendum 6's boots were at 66 %). Discharged to 72 % (charging off + 6× `yes`, ~830 mA,
≤ 42 °C), then charging back on (500 mA SDP) for all rows below. Shots via `flash-trace.sh --auto 4` (+ qpnp dyndbg)
right after reboot+unlock; dim = clamped. `cur` = PMIC 0xD342 code written for the strobe.

| shot | build | uptime s | SoC/temp | cap | high_flash_current | cur | latch | EXIF | meanY |
|---|---|---|---|---|---|---|---|---|---|
| full72_1 | 1 | 62 | 73 % 41 °C | 0 | 1000 | 0x4F | **1c** | 25 FIRED | **45** |
| full72_2 | 1 | 88 | 72 % 42 °C | 0 | 1000 | 0x4F | **1c** | — (no photo: frame slip + error frame) | — |
| low72_1 | 1 (cap in wrong copy) | 63 | 71 % 43 °C | 400 | **1000** | 0x4F | **1c** | 25 | **45** |
| low72_2 | 1 (cap in wrong copy) | 87 | 70 % 44 °C | 400 | **1000** | 0x4F | **1c** | 25 | **45** |
| lowfix_1 | 2 | 63 | 74 % 34 °C | 400 | 1000 capped to **400** | 0x1F | **0c** | 25 FIRED | 79 |
| lowfix_2 | 2 | 88 | 73 % 35 °C | 400 | 1000 capped to **400** | 0x1F | **0c** | 25 FIRED | 82 |
| fullfix_1 | 2 | 63 | 72 % 37 °C | 0 | 1000 | 0x4F | **1c** | 25 FIRED | **44** |
| fullfix_2 | 2 | 88 | 71 % 39 °C | 0 | 1000 | 0x4F | **1c** | — (no photo, error frame) | — |
| lowwarm_1 | 2 | 119 | 70 % 39 °C | 400 | capped to 400 | 0x1F | 0c | 25 | 78 |
| fullwarm_1 | 2 | 142 | 70 % 40 °C | 0 | 1000 | 0x4F | 0c | 25 | 119 |
| red700_1 | 2 | 63 | 70 % 41 °C | 700 | capped to **700** | 0x37 | **0c** | — (photo lost: 3A lock ran 7 s past the window) | — |
| red700_2 | 2 | 84 | 69 % 42 °C | 700 | capped to **700** | 0x37 | **0c** | — (captured, lost in MediaStore insert) | — |
| red700warm_1 | 2 | 157 | 69 % 42 °C | 700 | capped to 700 | 0x37 | 0c | 25 | 106 |

**Verdict.** On the same build, SoC and boot window, Full droops on every early shot (4/4 latch 1c, meanY 44–45 =
the 200 mA clamp). Low never droops (4/4 0c, early and warm), and its photo is lit but darker (meanY ~80 vs ~119 for
a lit 1000 mA strobe, about −0.6 EV). Reduced 700 mA also held 0c on both early shots (no early photo saved; warm
meanY 106, about −0.15 EV). Torch/preflash unchanged (LOW = 120 mA in every trace). The lost photos are the
known early-boot save loss (addendum 6), not the flash.

**For Kyle:** (1) commit + push the three `staging/flash-power` patches (kernel now camera-legacy) if the tweak
ships. (2) Pick the default and labels: 700 mA looks like the better "worn battery" setting (no droop at 70 % in
n=2 early shots, near-full brightness). It is n=2 at one SoC; 400 is the safe floor. (3) At 97–100 % gold did not
droop at all, so the reporter's "100 % + charging" failure means a worse cell than gold's.
Raw data: `/tmp/flashsync/validate/` (per-shot .txt/.dmesg/.logcat/.jpg, vshot.sh/vboot.sh/discharge.sh,
settings screenshots).
