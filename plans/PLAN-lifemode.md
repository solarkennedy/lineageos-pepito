# PLAN — Life Mode (Palm PVG100 feature, reimplemented on LineageOS 23 / Android 16)

Reimplementation of the Palm's **"Life Mode"** as a Quick Settings tile + a resident
screen-state listener, with its behavior knobs in the Pepito Tweaks screen in LineageParts.

**Status: ✅ WORKING — flash-validated on the DUT 2026-07-12, Enforcing, zero denials.**
All five levers confirmed engaging together on screen-off and restoring on screen-on, and
the boot-recovery path confirmed by rebooting the device while Life Mode was active.
Remaining: commit sweep (2 repos). Deferred by Kyle: status-bar icon (stock had one);
dropped: snooze.

---

## 1. What Life Mode is (original Palm behavior)

Palm's marketing/UX: *"When you turn off your screen, Life Mode silences your calls
and notifications and stops apps from chattering over data, so you can be present.
Turn the screen back on and everything comes right back — you won't miss a thing."*

Decomposed, Life Mode is a **master toggle** that, while ON, on every **screen-off**
(a) silences via Do Not Disturb and (b) stops apps chattering over the network — and on
every **screen-on** restores the pre-Life-Mode state so nothing is missed. Master toggle
OFF ⇒ screen-off behaves completely normally.

> ⚠️ **No live ground-truth device.** `android11-adb` is a stock-kernel **A11 GSI**, and
> Life Mode was a Palm *framework/userspace* feature of the original **8.1** software that
> the GSI wiped. So there is no runtime reference.

### ⭐ But the stock assets ARE on disk (found 2026-07-12)

`backup-stock-android-8.1-AML0/.../priv-app/SystemUI/SystemUI.apk` still contains Palm's
own Life Mode implementation — icons, layouts and **strings**. Decode with
`out/host/linux-x86/bin/aapt2 dump xmltree <apk> --file <res path>`; `unzip -p ...
resources.arsc | strings` lists the rest. What it tells us about the real feature:

- `"With Life Mode, you won't receive calls or texts when your Palm's screen is off."`
  → **stock genuinely blocked calls** (full silence), where we chose DND *Priority* so
  starred/repeat callers break through. Ours is deliberately the safer read; noting the
  divergence rather than matching it.
- `"This will optimize your devices battery life through display brightness, disabling GPS
  and bluetooth, and limits most background data."` → stock also dimmed the display and
  killed **GPS + Bluetooth**, on top of the background-data limit we implement.
- `dialog_life_mode_delay.xml` + `"Turn Off Life Mode for:"` → stock had a **temporary
  snooze** (turn it off for N minutes), which we don't have.
- `stat_sys_life_mode.png` → stock showed a **status-bar icon** while active.

None of this is implemented; it's the fidelity backlog if we ever want to go closer to the
original. The behavior we ship is the reconstruction in §3.

---

## 2. As-built design (deviates from the 2026-07-03 plan — read this)

Two deliberate departures from the original design, both because the tree moved on:

**① Hosted inside XiaomiParts, not a new standalone app.**
`device/xiaomi/mithorium-common/parts/` (`XiaomiParts`) is *already*
`android:persistent="true"`, already `sharedUserId="android.uid.system"`, already
platform-signed/privileged, and already has a `BootCompletedReceiver` that dynamically
registers a broadcast listener for exactly this class of problem
(`GotweaksBatterySaverReceiver` — `ACTION_POWER_SAVE_MODE_CHANGED` can't be a manifest
receiver either). Reusing it means **no second persistent process** on a 2.87 GB device
and **no new privapp-permissions entry**.

The residency requirement itself is unchanged and unavoidable: `ACTION_SCREEN_ON` /
`ACTION_SCREEN_OFF` are excluded from manifest `<receiver>`s (since O), so *something*
must be resident to hear them. It's cheap — event-driven, no polling, no wakelock.

Cost of the deviation: XiaomiParts is `mithorium-common`, i.e. one scope deeper than
pepito-only. Handled by runtime gating on `ro.vendor.xiaomi.device=pepito` (the same
mechanism the qmux staging uses): on siblings the controller never registers, and the
tile ships `android:enabled="false"` so it never even appears in their QS editor.
`BootCompletedReceiver` flips the component on for pepito.

**② Behavior is configurable from Pepito Tweaks.** The tile is the master switch; *what
Life Mode does* is three `SwitchPreferenceCompat`s in the existing Pepito Tweaks screen
(`GoTweaksSettings`). DND strength is deliberately **not** a knob (see below).

### Permissions — the plan's main worry evaporated

All of them are **`signature`** or **`normal`** protection level, so the platform cert
grants them outright and **no privapp-permissions allowlist entry is needed** (the plan
assumed `MANAGE_NETWORK_POLICY` was `signature|privileged` — it isn't):

| Permission | Level | For |
|---|---|---|
| `MANAGE_NETWORK_POLICY` | signature | `NetworkPolicyManager.setRestrictBackground()` |
| `ACCESS_NOTIFICATION_POLICY` | normal | DND |
| `DEVICE_POWER` | signature\|role | `PowerManager.setPowerSaveModeEnabled()` |
| `ACCESS_WIFI_STATE` / `CHANGE_WIFI_STATE` | normal | `WifiManager.setWifiEnabled()` |

`setWifiEnabled()` additionally needs a *privileged* caller or it silently returns
`false` for target-SDK-Q+ — satisfied by `WifiPermissionsUtil.isSignedWithPlatformKey()`
(verified in `WifiServiceImpl.isPrivileged()`), so the platform cert alone covers it. No
`NETWORK_SETTINGS` needed.

`setPowerSaveModeEnabled()` accepts `DEVICE_POWER` **or** `POWER_SAVER`; we take
`DEVICE_POWER` deliberately, because `POWER_SAVER` is `signature|privileged` and would
drag in the privapp allowlist entry this app otherwise doesn't need.

**DND access is a per-package grant, not a permission** — holding
`ACCESS_NOTIFICATION_POLICY` is not enough and `setInterruptionFilter()` throws without
it. We self-grant with `setNotificationPolicyAccessGranted()`: its
`@RequiresPermission(MANAGE_NOTIFICATIONS)` is short-circuited by
`isCallerSystemOrSystemUiOrShell()` in NotificationManagerService, which our system UID
satisfies. It sticks (first-run cost only) and surfaces as a normal entry under
Settings → Special app access → Do Not Disturb access.

---

## 3. Behavior spec

Everything is a `persist.lifemode.*` property, read **fresh at each screen-off** — so
there is nothing to observe and no state to keep in sync.

| Property | Owner | Default | Meaning |
|---|---|---|---|
| `persist.lifemode.enabled` | QS tile | `0` | master switch |
| `persist.lifemode.restrict_data` | Pepito Tweaks | `1` | Data Saver on while screen off |
| `persist.lifemode.battery_saver` | Pepito Tweaks | `1` | stock Battery Saver on while screen off |
| `persist.lifemode.wifi_off` | Pepito Tweaks | `0` | Wi-Fi off while screen off |
| `persist.lifemode.grayscale` | Pepito Tweaks | `1` | screen greyscale while Life Mode is ON (**not** screen-tied) |
| `persist.lifemode.gps_off` | Pepito Tweaks | `0` | location off while screen off |
| `persist.lifemode.bt_off` | Pepito Tweaks | `0` | Bluetooth off while screen off |
| `persist.lifemode.active` + `saved_filter` / `saved_restrict` / `saved_battery_saver` / `saved_wifi` | controller | — | the persisted undo snapshot |

**On SCREEN_OFF** (master on, not already active): snapshot current DND filter / Data
Saver / Wi-Fi state, persist the snapshot **and mark active *before* mutating anything**,
then apply. **On SCREEN_ON** (or master toggled off): restore the snapshot, clear active.

Three things this shape buys, each guarding a real failure:
- **Never re-snapshot while active** — a repeat `SCREEN_OFF` would otherwise snapshot our
  own Life-Mode values and restore would have nothing to put back.
- **Snapshot persisted, restore runs unconditionally at boot** — DND, Data Saver and Wi-Fi
  are *persistent system state* that outlives our process. A reboot or crash with the
  screen off would otherwise strand the user silenced and offline with the undo record
  gone.
- **Tri-state snapshot fields (`-1` = UNTOUCHED)** — we only restore what we actually
  changed, so we never clobber a Data Saver or DND setting the user chose themselves.

**Battery Saver is on by default and is the cheapest lever here** — one call gets the
whole framework standby package (job/alarm deferral, background restrictions). It also
**composes with the existing Extreme Battery Saver levers for free**:
`GotweaksBatterySaverReceiver` already follows `ACTION_POWER_SAVE_MODE_CHANGED`, so if
the user has the CPU/GPU levers enabled in Pepito Tweaks, a Life Mode screen-off now also
offlines the fast CPU cluster and/or caps the GPU. Nothing to wire up — we flip stock
Battery Saver, the receiver hears it, the levers apply. (This is also why Battery Saver
and restrict-background are separate knobs and not one: Data Saver is a *network* policy,
Battery Saver is a *scheduling* one, and either is useful without the other.)

### Greyscale — the one lever that breaks the pattern (added 2026-07-12)

Every other lever hangs off **screen-off**. Greyscale hangs off the **master switch**:
grey while the Life Mode tile is on, colour when it's off. Applying it on screen-off would
be pointless — nobody's looking. It's the one lever meant to be *seen*: picking the phone
up is deliberately less rewarding. **On by default.**

Not a Palm behavior — the stock APK has no greyscale (confirmed). It's **Digital
Wellbeing's Bedtime Mode**, which is GMS-only and therefore absent from our build, so we
drive the underlying machinery ourselves.

- **API: `ColorDisplayManager.setSaturationLevel(0..100)`**, needs
  `CONTROL_DISPLAY_COLOR_TRANSFORMS` (`signature|privileged` — the system-UID carve-out
  covers it, no privapp entry).
- ⭐ **Deliberately NOT the accessibility daltonizer's Monochromacy mode**, which is the
  other obvious way to grey a screen: that's *colour correction*, and commandeering it
  would stomp on a user who actually needs it. Global saturation is the orthogonal knob.
- **The only lever needing no snapshot.** Saturation is a *runtime* transform with a known
  default (100), not persistent system state — nothing to strand, nothing to put back. A
  reboot resets it to colour by itself, so `register()` simply re-asserts it at boot if the
  tile is still on.
- **The only knob with an apply step.** It's instantly visible, so flipping it while Life
  Mode is already on must land *now*, not at the next screen-off nobody is watching.
  LineageParts applies it directly (same shape as `applyBatterySaverLever`). That
  duplicates the `(enabled && grayscale)` condition in `LifeModeController.applyGrayscale()`
  across two apps — **keep them in sync**.

#### ⭐⭐ Greyscale exposed a pre-existing display bug — ✅ ROOT-CAUSED + FIXED (packaging gap)

**Outcome:** colour transforms now work **in hardware**. Root cause was the never-packaged
`libsdm-color.so` (+ `libtinyxml2_1.so`, `libsdm-diag.so`) — declared in
`proprietary-files-qc-vndr.txt` but never extracted. Fixed by shipping them from the
**Mi8937 nightly** (the A8 copy is the wrong CAF generation and fails). This also fixes
**Night Light and accessibility colour correction**, which were silently dead too. Full
story + the falsified theories: memory `display-color-transform`. The HAL workaround below
(`IsColorTransformSupported() → false`) was written and then **REVERTED** — unnecessary, and
it would force a GPU pass instead of using the DSPP.

<details><summary>Original investigation notes (kept — the reasoning chain is instructive)</summary>

First flash: the tile went on, the framework reported `Global saturation: Activated: true`,
and **the screen stayed in colour**. Our code was blameless — the matrix was being dropped
below the framework:
```
E SDM: HWCDisplay::HandleColorModeTransform: Failed to set Color Transform Matrix
```
`HWCSession::GetCapabilities` advertises `HWC2_CAPABILITY_SKIP_CLIENT_COLOR_TRANSFORM` —
a *promise* to SF that the HWC applies colour matrices in hardware, which makes SF skip its
own GPU transform (`deviceHandlesColorTransform = usesDeviceComposition || getSkipColorTransform()`,
`Output.cpp:1539`). The capability is driven by `CoreImpl::IsColorTransformSupported()`,
which was the heuristic `return !has_ppp` — **true on this family, and a lie**:
`DisplayBase::SetColorTransform` bails with `kErrorNotSupported`.

**This is pre-existing and Life Mode merely exposed it: Night Light and accessibility
colour correction have silently done nothing on this build too** (the daltonizer fails
identically — that's how it was isolated).

Chased the obvious suspect first, because it looked exactly like the `libacdbloader` /
camera-chromatix packaging gaps: `libsdm-color.so` (the colour manager, `color_mgr_`) was
**never packaged** — declared in `proprietary-files-qc-vndr.txt` but absent from the device
*and* from the extracted vendor tree, along with `libsdm-diag`/`libsdm-disp-vndapis`; stock
8.1 ships it. **Falsified by pushing it live** (plus its missing DT_NEEDED dep
`libtinyxml2_1.so`): the composer loaded both, the colour manager instantiated cleanly (the
A8 blob's version tag matched our CAF HAL), and `SetColorTransform` **still failed**. There
is no colour-matrix block in this MDP. Packaging gap is real but separate; not the cause.

**Fix:** `CoreImpl::IsColorTransformSupported()` → `return false`
(`hardware/qcom-caf/msm8953/display`, new repo project — **fork/push is a release gate**).
SF then applies the matrix in RenderEngine, which is ~free here: the display already runs
fully client-composited when idle (verified on a clean boot), and the HWC forces client
composition whenever a transform is set anyway. Fixes greyscale, Night Light and colour
correction together.

⚠️ Bench gotcha: **do not `ctl.restart vendor.hwcomposer-2-1` on a live system** — it wedges
SurfaceFlinger and needs a hard power-off. Push display libs, then reboot.

</details>

**DND is always `INTERRUPTION_FILTER_PRIORITY`, never `_NONE`, and is not a knob.**
Starred contacts and repeat callers still break through, which is what makes it safe to
leave on overnight, and it matches Palm's own bypass behavior.

**Wi-Fi-off, GPS-off and Bluetooth-off are all opt-in and off by default.** Wi-Fi-off is
*safe on this device specifically* because VoLTE works: calls and SMS ride LTE, so
dropping Wi-Fi with the screen off doesn't make the phone unreachable. GPS-off and
Bluetooth-off were both **stock Life Mode behavior** (per the strings in Palm's own
SystemUI.apk, above) — but BT-off has a sharp edge worth knowing about: it cuts audio to
Bluetooth headphones the instant the screen goes off, and disconnects watches/accessories
until you wake the phone. That's why it's opt-in rather than matching stock's default.

These two are also the only levers that can legitimately *refuse* us, and they're reached
from a broadcast receiver — an uncaught `SecurityException` would take the whole
controller down, restore path included. So both are wrapped in guards: if the grant ever
goes away the knob quietly no-ops and logs, instead of killing Life Mode.
`LocationManager.setLocationEnabledForUser()` needs `WRITE_SECURE_SETTINGS`
(`signature|privileged`) and `BluetoothAdapter.disable()` needs `BLUETOOTH_CONNECT` (a
*runtime* permission — declaring it is not holding it). Neither gets a privapp entry;
both ride `sharedUserId="android.uid.system"`, exactly as **LineageParts** already holds
`WRITE_SECURE_SETTINGS` with no allowlist entry of its own (verified in-tree — that's the
difference from VolumeTile, which is platform-signed but *not* system-UID and therefore
did need one).

---

## 4. Files

New, in `device/xiaomi/mithorium-common/parts/`:
```
src/org/lineageos/settings/lifemode/LifeModeController.java  # state machine + screen receiver + boot recovery
src/org/lineageos/settings/lifemode/LifeModeTile.java        # TileService — the master switch
res/drawable/ic_life_mode.xml                                # the stock palm tree
```
The icon is **the real Palm palm tree**, traced (cv2 findContours → evenOdd VectorDrawable,
`scratchpad/palm-icons/trace.py`) from stock SystemUI's `ic_qs_lifemode_on.png` rather than
redrawn. Stock shipped two bitmaps (`ic_qs_lifemode_on/off`, coral + grey, different
drawings); we ship one monochrome vector and let QS tint it per tile state — same on/off
read, and a vector survives this panel's odd 264/280dpi bucket, which would have resampled
a fixed-density bitmap.
Edited: `AndroidManifest.xml` (4 uses-permission + the disabled-by-default tile service),
`BootCompletedReceiver.java` (pepito gate → enable tile component + register controller),
`res/values/strings.xml`, `proguard.flags`.

Sepolicy (`device/xiaomi/mithorium-common/sepolicy/vendor/`): new `lifemode.te`
(`get_prop`/`set_prop` for `system_app` — both writers, the tile and LineageParts, are
system_app/coredomain), plus `lifemode_prop` in `property.te` and `persist.lifemode.` in
`property_contexts`. System-owned rather than vendor-owned for the same reason as
`gotweak_prop`: a coredomain app cannot set `persist.vendor.*`. Unlike gotweaks there are
**no** `vendor_init`/`qti_init_shell` grants and no `on property:` triggers — everything
Life Mode does, it does through framework APIs from inside `system_app`.
✅ Neverallow check run per PLAN.md's `checkpolicy` recipe: **exit 0**.

⭐ **Gotcha caught on the 2026-07-12 validation flash (first Enforcing boot):** the policy
above was *not* the whole surface — the **pepito gate itself** needed a grant.
`isSupported()` reads `ro.vendor.xiaomi.device`, which is labeled `vendor_xiaomi_prop`,
and `system_app` had no read for it:
```
avc: denied { read } name="u:object_r:vendor_xiaomi_prop:s0" scontext=u:r:system_app:s0 permissive=0
```
Under Enforcing the read is denied → `SystemProperties.get()` returns `""` → `isSupported()`
is false → **Life Mode silently switches itself off on the one device it exists for**: no
tile in the QS editor, no screen listener, and no error anywhere except that one avc line.
Fixed with `get_prop(system_app, vendor_xiaomi_prop)` in `lifemode.te`.

Same lesson as `gotweak_prop`'s `vendor_init` grant: **declaring a property type public
does not imply any given domain may read it — every reader needs its own `get_prop`.** Any
future feature that runtime-gates on `ro.vendor.xiaomi.device` from a non-vendor domain
will hit this identically.

`packages/apps/LineageParts`: Life Mode category in `go_tweaks_settings.xml` +
`GoTweaksSettings.java` (no reboot prompt and no apply step — unlike the Battery Saver
levers, the controller re-reads the props at the next screen-off) + strings.

---

## 5. Validation (no reference device — behavioral/spec-based, on `android16-adb` only)

```bash
# Tile appears in the QS editor, toggles, and writes the master prop:
adb shell getprop persist.lifemode.enabled

# Drive screen state (tile can't be reached with the screen off, so use adb):
adb shell input keyevent 26

# While the screen is off, expect: active=1, DND=PRIORITY, Data Saver on.
adb shell getprop persist.lifemode.active
adb shell dumpsys notification | grep -i "interruption\|zen"
adb shell cmd netpolicy get restrict-background
adb shell settings get global wifi_on          # only if the Wi-Fi knob is on

# Screen on → everything back to its pre-Life-Mode value, active=0.
```

### ✅ Validation results (DUT, 2026-07-12, Enforcing)

Every lever engaged simultaneously on screen-off, and each `enter:` line is mirrored
exactly by its `restore:` — the symmetry is the proof:
```
enter:   filter=1 restrict=0 batterySaver=0 wifi=-1 gps=1 bt=1
restore: filter=1 restrict=0 batterySaver=0 wifi=-1 gps=1 bt=1
```
Live during screen-off: `active=1`, `zen=1` (Priority), Data Saver enabled, `low_power=1`,
`location_mode=0`, `bluetooth_on=0`. All back to baseline on screen-on. No avc denials, no
crashes, no `cannot toggle` — **both guarded grants (WRITE_SECURE_SETTINGS,
BLUETOOTH_CONNECT) carried via the system UID**, confirming the sharedUserId reasoning.
The Wi-Fi lever was separately confirmed by the phone going unpingable for the whole
screen-off window (and `wifi=-1` when the knob is off proves it's correctly disarmed —
the Wi-Fi drops still seen with the knob off are this device's Wi-Fi power-save, which
leaves `wifi_on=1`; our lever sets it to 0. That's the tell).

**Boot recovery proven:** rebooted the device *while active* (DND on, Data Saver on,
Battery Saver on, BT off, GPS off). At boot, `restore:` replayed the persisted snapshot and
returned everything to normal; `active` → 0, master switch preserved. Note the restore
lands at `BOOT_COMPLETED`, i.e. **after the user unlocks** on this FBE device — visible as
Battery Saver switching itself off a moment after unlock. Cosmetic, but that's why.

Checklist (all passed):
1. Tile off ⇒ screen-off changes nothing at all.
2. Tile on ⇒ screen-off silences + Data Saver on + Battery Saver on; screen-on restores
   all three (`adb shell dumpsys power | grep -i "mSettingBatterySaverEnabled\|LowPower"`).
3. Pre-existing user state is respected: turn Data Saver (or Battery Saver) on manually,
   run a Life Mode cycle, confirm it is still on afterwards (the UNTOUCHED path).
3b. Composition: enable "Disable fast CPU cluster" in Pepito Tweaks, then run a Life Mode
   cycle — `getprop persist.gotweak.cpu_cluster_saver` should be 1 while the screen is
   off and 0 after, with no extra wiring.
4. Wi-Fi knob on ⇒ Wi-Fi drops on screen-off, returns on screen-on; a **call still rings
   through** with the screen off (VoLTE) — this is the one that justifies the knob.
4b. GPS/BT knobs on ⇒ `settings get secure location_mode` and `cmd bluetooth-manager
   get-state` follow the screen, and **neither throws**: `logcat -s LifeMode` must NOT
   show "cannot toggle location/bluetooth" (that means the system-UID grant didn't carry
   and the knob is silently no-op'ing).
5. **Boot recovery:** enable, screen off, then `adb reboot` while active. On boot, DND and
   Data Saver must come back to their pre-Life-Mode values and `active` must be `0`.
6. Knobs take effect without a reboot (flip in Pepito Tweaks, next screen-off honors it).
7. Enforcing: `dmesg | grep avc` clean around `lifemode_prop`.
8. Sibling regression (build-only): tile absent from QS editor on a non-pepito variant.
