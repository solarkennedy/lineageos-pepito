# microG on the PVG100 (optional add-on)

[microG](https://microg.org) is an open-source re-implementation of Google Play
services. It is the middle ground between the two builds we publish:

| | Vanilla | Vanilla + microG add-on | GApps |
|---|---|---|---|
| Google account, push notifications (FCM) | – | ✅ | ✅ |
| Network (Wi-Fi/cell) location | – | ✅ | ✅ |
| Play Store | – | ✅ free apps; **no in-app/paid billing** | ✅ |
| Android Auto, RCS chat | – | – (expected; they need real Play services) | ✅ |
| Play Integrity / banking-app checks | – | – | – (fails on every build of this ROM) |
| Survives OTA updates | n/a | **No — re-flash after every update** | ✅ |

microG is **not part of the ROM**. It is a one-time, separately published
recovery zip that you flash on top of the **vanilla** build:

**Download:** [`MinMicroG-Standard-2.12.0-pepito1.zip`](https://github.com/solarkennedy/lineageos-pepito/releases/tag/microg-addon-1)
(one fixed release — it is *not* re-attached to each ROM release)

What is in it: microG GmsCore 0.3.15.250932, microG GsfProxy, the Play Store
(Phonesky 30.4 — it updates itself), AuroraDroid (an F-Droid client), the Maps
v1 shim, and the privileged-permission / sysconfig XML they need. The ROM needs
no patch: LineageOS 23 already spoofs the Google signature for apps signed
with microG's own key.

## Install

1. **Flash the vanilla build** ([README → Installation](../README.md#installation))
   and let it factory-reset. It must be **vanilla** — the zip refuses to install
   on a GApps build, because real Play services and microG cannot coexist. If
   the phone ever ran the GApps build, *Factory reset → Format data* is
   mandatory, not optional.
2. Boot to **recovery** (`adb reboot recovery`, or hold Power through three boot
   cycles). Choose **Apply update → Apply from ADB**.
3. From the computer:
   ```sh
   adb sideload MinMicroG-Standard-2.12.0-pepito1.zip
   ```
   The zip is unsigned, so recovery says signature verification failed —
   choose **Yes / install anyway**. It ends with `Done!`.
4. Reboot. Open **microG Settings → Self-Check**; everything should be ticked.
   In *Location*, enable the Wi-Fi and mobile-network modules. Add your Google
   account from *microG Settings → Account* **before** opening the Play Store.

### If something goes wrong

- **Play Store shows `DF-DFERH-01`.** It was opened before the account finished
  checking in. *Settings → Apps → Google Play Store → Storage → Clear storage*
  (or `adb shell pm clear com.android.vending`), then open it again. A one-off
  "isn't compatible" dialog while the Store updates itself is harmless.
- **SafetyNet shows "Failed" in Self-Check.** Google retired that API; it is not
  a verdict on your phone.
- **The installer aborts.** Recovery's screen may stop responding afterwards —
  hold Power ~15 s to hard-reset. To see the real error, run the installer by
  hand instead of sideloading (recovery's adb is root):
  ```sh
  adb push MinMicroG-Standard-2.12.0-pepito1.zip /tmp/m.zip
  adb shell 'cd /tmp && unzip -o m.zip META-INF/com/google/android/update-binary && sh META-INF/com/google/android/update-binary 3 1 /tmp/m.zip'
  ```
  Run that way, the installer prints its full log to your terminal.

## ROM updates wipe it — re-flash every time

Our OTA updates rewrite the whole `system` partition, and microG lives there.
**No add-on survives that**, and the zip deliberately installs no `addon.d`
script that would pretend otherwise. After every ROM update, microG is gone
until you flash the zip again. Stay on the **vanilla** (`UNOFFICIAL`) update
channel; never cross to GApps.

There are two ways to update, and they differ in what you lose:

- **Keeps your microG account and app registrations — update by hand.**
  Download the vanilla OTA zip from the releases page, boot to recovery, then
  in the *same* recovery session sideload the OTA, **then sideload the microG
  zip again, and only then reboot**. Android never boots without microG
  present, so its data is kept.
- **Simple, but microG starts from scratch — the built-in Updater.** The
  Updater reboots straight into the new system. Android sees that the microG
  system apps have vanished and **deletes their data**: the Google account,
  push registrations and location settings. Apps you installed stay, but they
  lose push and sign-in until you boot to recovery, flash the zip again, and
  redo step 4 above.

## Uninstall

Rename the zip so its name contains `uninstall` (e.g.
`MinMicroG-uninstall.zip`) and sideload it the same way — or just take any ROM
update, which removes it anyway.

## What this zip is

[MinMicroG](https://github.com/FriendlyNeighborhoodShane/MinMicroG) "Standard"
2.12.0 (GPL-3.0; its scripts are the source and ship inside the zip), rebuilt
for this phone because the upstream release cannot run here:

- **Installer mount fix.** Upstream mounts `/system` over the recovery
  ramdisk's own `/system/bin` on a system-as-root image, hiding every tool and
  dying with `No chcon available`. Fixed upstream in source in 2024 but never
  released.
- **GmsCore 0.2.28 (2023) → 0.3.15.250932**, the unmodified APK from
  [microG's GitHub releases](https://github.com/microg/GmsCore/releases),
  signed with microG's own key.
- **Privileged-permission list extended** from 10 to 14 entries for that
  GmsCore. LineageOS enforces the list (`ro.control_privapp_permissions=enforce`);
  a missing entry is a boot loop, not a warning.
- **Refuses GApps builds**; drops the package cache after installing so the new
  system APKs are re-parsed on the next boot.
- **Removed:** the Android 4.4–13 sync-adapter / backup-transport variants
  (none match Android 16, so upstream skipped them anyway) and the `addon.d` /
  `init.d` scripts.

SHA-256: `50d22c5d9844d254ce40a552210a8811716d2290e6e6748167b081f754ac2f1d`
