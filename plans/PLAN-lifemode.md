# PLAN — Life Mode (Palm PVG100 feature, reimplemented on LineageOS 23 / Android 16)

Reimplement the Palm's **"Life Mode"** as a modern Quick Settings tile + supporting
system service, in the same baked-into-the-device-tree style as the existing
`VolumeTile`.

Status: **NOT started** (2026-07-03). This doc is the design/plan only.

---

## 1. What Life Mode is (original Palm behavior)

Palm's marketing/UX: *"When you turn off your screen, Life Mode silences your calls
and notifications and stops apps from chattering over data, so you can be present.
Turn the screen back on and everything comes right back — you won't miss a thing."*

Decomposed, Life Mode is a **master toggle** that, while ON, does the following on
every **screen-off**:

1. **Silence** — suppress calls + notification sounds/vibration (Do Not Disturb).
2. **Restrict background data** — stop apps waking the device / syncing over the
   metered radio (Palm's real standby-battery win).

…and on every **screen-on**, restores the pre-Life-Mode state so nothing is missed.

When the master toggle is **OFF**, screen-off behaves completely normally.

**Chosen fidelity for this implementation:** *DND + restrict background data* (silence
+ Data-Saver-style background restriction). We do **not** fully kill the radios / turn
Wi-Fi off — the phone stays reachable for calls/SMS, we just stop app chatter. This is
the closest faithful mapping to Palm's actual standby behavior without the reconnection
fragility of hard radio toggling.

> ⚠️ **No ground-truth available.** Unlike other pepito subsystems, we cannot two-device
> this: `android11-adb` is a stock-kernel **A11 GSI**, and Life Mode was a Palm
> *framework/userspace* feature in the original **8.1** software that the GSI wiped. So
> there is no live reference device. Behavior above is reconstructed from Palm's docs;
> tune to taste.

---

## 2. Template we're copying — `VolumeTile`

Path: `device/xiaomi/Mi8937/VolumeTile/`

```
Android.bp                 # android_app, platform cert, platform_apis, privileged
AndroidManifest.xml        # service + BIND_QUICK_SETTINGS_TILE + QS_TILE intent-filter
res/drawable/ic_volume.xml # vector icon
res/values/strings.xml
src/org/lineageos/pepito/volumetile/VolumeTile.java   # extends TileService
```

Packaged in `device/xiaomi/Mi8937/device.mk:50-54`, under the pepito guard:

```make
ifeq ($(TARGET_DEVICE_PEPITO),true)
PRODUCT_PACKAGES += \
    VolumeTile \
    ...
```

The app is **platform-signed** (`certificate: "platform"`), **privileged**
(`privileged: true`), and built **against the full platform** (`platform_apis: true`),
which means it can call `@hide` framework APIs directly and be granted signature-level
permissions. We inherit all of that.

### Why Life Mode is bigger than VolumeTile

`VolumeTile` is **stateless and reactive** — one `onClick`, bump the volume, done. Its
`TileService` only needs to be alive while the QS panel is open.

Life Mode is **stateful and screen-driven**. The tile itself is just a master switch;
the actual work happens on screen transitions that occur when no UI is visible. See §4.

---

## 3. Components

| Component | Type | Role |
|-----------|------|------|
| `LifeModeTile` | `TileService` | Master on/off switch. Flips a persisted flag, reflects ACTIVE/INACTIVE state, starts/stops the service. |
| `LifeModeService` | `android:persistent` system `Service` | The resident-while-enabled brain. Registers a runtime `SCREEN_ON`/`SCREEN_OFF` receiver; enters/exits Life Mode on transitions. |
| `BootReceiver` | manifest `BroadcastReceiver` (`BOOT_COMPLETED`) | If enabled, (re)start the service after reboot. `BOOT_COMPLETED` **is** allowed as a manifest receiver (unlike screen events). |

**State storage:** `Settings.Secure` key `pepito_life_mode_enabled` (0/1). Survives
reboot, readable/writable by our system app, observable. (SharedPreferences also works;
Settings.Secure is cleaner for a system component and lets `adb` toggle it for testing.)

Package: `org.lineageos.pepito.lifemode` (mirrors `…volumetile`).

---

## 4. Why a resident listener is required (and why it's cheap)

`ACTION_SCREEN_ON` / `ACTION_SCREEN_OFF` are the two broadcasts that **cannot** be
declared in a manifest `<receiver>` (excluded since Android 8). They only reach a
process that registered for them **at runtime**. Life Mode must react to *every*
screen-off/on edge (it's screen-tied, not a schedule), so a process must be resident to
hear them. There is no lighter framework hook — DND `ConditionProviderService`,
JobScheduler, and AlarmManager none of them surface a screen-transition edge.

This is cheap because:

- **Event-driven, not polling** — the receiver is idle (0 CPU, no wakelock) until the
  kernel flips the screen.
- **Only resident while the master toggle is ON** — tile OFF ⇒ `stopSelf()` ⇒ zero
  cost. It is not a permanently-running daemon.
- **`android:persistent` (our recommended host)** — because the app is platform-signed
  and on `/system`, AMS keeps it alive with **no foreground-service notification** and
  no wakelock. Same mechanism system components use.

Alternative host: a **foreground service** (start when enabled, stop when disabled).
More portable, but shows a permanent low-priority notification while active. Rejected as
default for a baked-in device feature; keep as fallback if `android:persistent` gives
trouble.

---

## 5. Behavior spec (the service state machine)

State: `boolean mActive` (currently in the screen-off Life-Mode state), plus a saved
snapshot of what we changed.

**On `SCREEN_OFF`** (and `pepito_life_mode_enabled == 1`, and `!mActive`):
1. Snapshot `savedFilter = NotificationManager.getCurrentInterruptionFilter()`.
2. `setInterruptionFilter(INTERRUPTION_FILTER_PRIORITY)` — **PRIORITY, not NONE**, so
   repeat callers / starred contacts can still break through (emergency safety, matches
   Palm's bypass). Make NONE-vs-PRIORITY a config option later.
3. Snapshot `savedRestrictBackground = NetworkPolicyManager.getRestrictBackground()`;
   `setRestrictBackground(true)` (Data-Saver master — restricts app background data on
   metered networks; fully reversible).
4. `mActive = true`.

**On `SCREEN_ON`** (and `mActive`):
1. `setInterruptionFilter(savedFilter)`.
2. `setRestrictBackground(savedRestrictBackground)`.
3. `mActive = false`.

**On master toggle OFF while `mActive`:** immediately run the restore path, then
`stopSelf()`.

Edge cases to handle:
- Toggle enabled while screen already off → apply the screen-off path immediately.
- Reboot while enabled → `BootReceiver` starts service; if it boots with screen on,
  `mActive=false` and we simply wait for the first screen-off.
- Don't double-snapshot: guard every entry with `mActive` so a spurious repeat
  `SCREEN_OFF` can't overwrite `savedFilter` with our own Life-Mode value.

---

## 6. Permissions & allowlisting

| Permission | Level | For | Notes |
|-----------|-------|-----|-------|
| `ACCESS_NOTIFICATION_POLICY` | policy | DND `setInterruptionFilter` | Auto-granted to system apps; may still need `setNotificationPolicyAccessGranted` self-grant or a default-DND-access entry. |
| `MANAGE_NETWORK_POLICY` | `signature\|privileged` | `NetworkPolicyManager.setRestrictBackground` | **Needs a privapp-permissions allowlist entry** (see below). |
| `RECEIVE_BOOT_COMPLETED` | normal | `BootReceiver` | Ordinary. |
| `WRITE_SECURE_SETTINGS` | `signature\|privileged` | write `Settings.Secure` flag | Platform-signed grants it; add to allowlist to be safe. |

`NetworkPolicyManager` is `@hide`; reachable directly thanks to `platform_apis: true`
(no reflection). `getSystemService(Context.NETWORK_POLICY_SERVICE)`.

**privapp-permissions:** unlike VolumeTile (which uses only the normal
`MODIFY_AUDIO_SETTINGS`), our signature|privileged perms require an allowlist XML for a
privileged app, or boot will `SecurityException`. There is **no** privapp XML in the
device tree yet — add one:

```
device/xiaomi/Mi8937/permissions/privapp-permissions-pepito.xml
```
```xml
<permissions>
    <privapp-permissions package="org.lineageos.pepito.lifemode">
        <permission name="android.permission.MANAGE_NETWORK_POLICY"/>
        <permission name="android.permission.WRITE_SECURE_SETTINGS"/>
    </privapp-permissions>
</permissions>
```
Install via `PRODUCT_COPY_FILES` into the same partition's `etc/permissions/` as the
app (system vs system_ext must match where the privileged APK lands).

**SELinux:** app runs in the `platform_app` domain (platform cert). Watch `logcat`/`dmesg`
for AVC denials calling NetworkPolicy/NotificationManager; add `device/.../sepolicy` rules
if needed. A16 is currently **Permissive** (per memory) so denials will log-not-block
during bring-up — don't let that mask a real rule we'll need once Enforcing.

---

## 7. File layout to create

```
device/xiaomi/Mi8937/LifeMode/
  Android.bp                     # copy VolumeTile's; name "LifeMode"
  AndroidManifest.xml            # tile service + persistent LifeModeService + BootReceiver
  res/drawable/ic_life_mode.xml  # pick an icon (leaf / moon / person)
  res/values/strings.xml         # "Life Mode"
  src/org/lineageos/pepito/lifemode/
      LifeModeTile.java          # TileService — toggle flag, set tile state, start/stop svc
      LifeModeService.java       # persistent svc — screen receiver + state machine (§5)
      BootReceiver.java          # BOOT_COMPLETED → start svc if enabled
```

Plus edits:
- `device/xiaomi/Mi8937/device.mk` — add `LifeMode \` to the `TARGET_DEVICE_PEPITO`
  `PRODUCT_PACKAGES` block, and `PRODUCT_COPY_FILES` for the privapp XML.

---

## 8. Phased implementation

**Phase 1 — Tile + DND core (minimal viable Life Mode).**
- Scaffold the app from VolumeTile.
- `LifeModeTile` toggles `pepito_life_mode_enabled`, updates ACTIVE/INACTIVE, starts/stops service.
- `LifeModeService` persistent, screen receiver, DND enter/exit (steps 1–2 / 1 of §5).
- `BootReceiver`.
- **Verify:** tile toggles; screen-off silences (check `dumpsys notification | grep -i
  interruption`), screen-on restores.

**Phase 2 — Background-data restriction.**
- Add `MANAGE_NETWORK_POLICY` + privapp XML.
- Wire `setRestrictBackground` into the state machine (§5 step 3).
- **Verify:** `adb shell cmd netpolicy get restrict-background` flips with screen state.

**Phase 3 — Polish / fidelity options.**
- NONE-vs-PRIORITY DND config; priority-caller bypass tuning.
- Optional: brief grace delay before entering Life Mode (avoid churn on quick screen
  blips), matching Palm's feel.
- Optional icon state / dual-label (On/Off) on the tile.
- Optional Settings entry to configure behavior (later; the tile alone is enough to ship).

---

## 9. Testing (no reference device — synthetic)

```bash
# Toggle the master flag directly (bypass the tile):
adb shell settings put secure pepito_life_mode_enabled 1

# Drive screen state:
adb shell input keyevent 26          # power (toggle), or:
adb shell svc power stayon false

# Inspect DND:
adb shell dumpsys notification | grep -i "interruption\|zen"

# Inspect background restriction:
adb shell cmd netpolicy get restrict-background

# Watch for AVC / crashes:
adb logcat -b all | grep -iE "lifemode|avc|SecurityException"
```

Remember: `android11-adb` cannot validate expected behavior (GSI wiped Palm's Life Mode).
Validation is behavioral/spec-based on `android16-adb` only.

---

## 10. Open decisions

- **DND strength:** PRIORITY (recommended, emergency bypass) vs NONE (total silence).
- **Persistent service vs foreground service** — plan assumes `android:persistent`; fall
  back to FGS if AMS won't keep the persistent app alive cleanly.
- **Restrict-background scope:** global Data Saver (recommended, simple/reversible) vs a
  per-app doze whitelist (finer, more code).
- Whether to add a real Settings UI now or ship tile-only (recommended: tile-only first).
