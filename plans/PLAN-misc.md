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
