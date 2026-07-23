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
