First release of **LineageOS 24.0 (Android 17)** for the Palm PVG100 / PVG100E.

Everything that worked on 23.2 carries over: calls, VoLTE, Wi-Fi calling, mobile data, GPS, both cameras, all sensors, face unlock, wired Android Auto, tethering, encryption. SELinux is Enforcing. Android 17 itself looks almost the same as 16 on a screen this small; the changes are under the hood.

## New in this release

- **One download per flavor.** The zip is both the update package and the first-install kit. For a first install over EDL, extract it and run the bundled `ota2raw` converter (Linux, macOS, Windows) to rebuild the flashable images, then flash with `qdl`. The zip's `README.md` has the steps.
- **Bluetooth tethering** now works, alongside Wi-Fi hotspot and USB.
- **Pepito Tweaks** descriptions rewritten in plain language. New on the GApps build: "Let Play services sleep" (off by default).
- **"Auto-recover Emergency calls only"** stays available in Pepito Tweaks, off by default.

## Removed

- **eSIM manager (OpenEUICC).** The modem firmware refuses profile switching, so the app could never work.

## Upgrading from 23.2

- Your data is kept. Stay on the same flavor: vanilla to vanilla, GApps to GApps.
- Install with `adb sideload` from recovery. The 23.2 Updater does not offer 24.0 yet; a final 23.2 update will turn that on.
- Take an EDL backup first if you don't have one.

Coming from stock Android 8.1 is a first install over EDL and wipes `/data`.

## Known issues

- Bluetooth tethering is IPv4 only.
- "Enable low-RAM mode" in Pepito Tweaks makes Android Auto report the phone as incompatible. Leave it off if you use Android Auto.
- "Emergency calls only" can still stick after a weak-signal spell. Toggle airplane mode, or turn on the auto-recover option above.
- Carried over from 23.2: single SIM only, and the VoLTE switch in Settings is cosmetic (VoLTE itself works).
