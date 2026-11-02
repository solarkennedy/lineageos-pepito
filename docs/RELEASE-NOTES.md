First release of **LineageOS 24.0 (Android 17)** for the Palm PVG100 / PVG100E.

Everything that worked on 23.2 carries over: calls, VoLTE, Wi-Fi calling, mobile data, GPS, both cameras, all sensors, face unlock, wired Android Auto, tethering, encryption. SELinux is Enforcing. Android 17 itself looks almost the same as 16 on a screen this small; the changes are under the hood.

## New in this release

- **Install from your browser.** The [web flasher](https://solarkennedy.github.io/lineageos-pepito/flasher/) backs up and flashes the phone over USB from Chrome or Edge, with no tools to install. It is now the recommended way to do a first install; `qdl` on the command line still works.
- **One download per flavor.** The zip is both the update package and the first-install kit. For a first install, extract it and run the bundled `ota2raw` converter (Linux, macOS, Windows) to rebuild the flashable images, then flash. The web flasher and the zip's `README.md` both have the steps.
- **Bluetooth tethering** now works, alongside Wi-Fi hotspot and USB.
- **Pepito Tweaks** descriptions rewritten in plain language. New on the GApps build: "Let Play services sleep" (off by default).
- **"Auto-recover Emergency calls only"** stays available in Pepito Tweaks, off by default.
- **Faster GPS fixes.** The phone now downloads satellite orbit data (Qualcomm XTRA, about 33 KB a day), so it finds your location much sooner, even when it has no data connection at that moment. It needs Settings → Location → **Use assisted GPS**, which is now on by default on a fresh install, as on the original Palm software. To switch the orbit data off, use **Download satellite orbit data** in PVG100 Modem Tweaks.

## Removed

- **eSIM manager (OpenEUICC).** The modem firmware refuses profile switching, so the app could never work.

## Upgrading from 23.2

- Your data is kept. Stay on the same flavor: vanilla to vanilla, GApps to GApps.
- Install with `adb sideload` from recovery. The 23.2 Updater does not offer 24.0 yet; a final 23.2 update will turn that on.
- Take an EDL backup first if you don't have one.
- **Turn on Settings → Location → Use assisted GPS** after updating. LineageOS ships it off and an update keeps your existing setting, so without this the GPS gets no help and can take minutes to find you. On GApps, Google Play services can change this setting too, so check it either way.

Coming from stock Android 8.1 is a first install (web flasher or `qdl`) and wipes `/data`.

## Known issues

- Bluetooth tethering is IPv4 only.
- "Enable low-RAM mode" in Pepito Tweaks makes Android Auto report the phone as incompatible. Leave it off if you use Android Auto.
- "Emergency calls only" can still stick after a weak-signal spell. Toggle airplane mode, or turn on the auto-recover option above.
- Carried over from 23.2: single SIM only, and the VoLTE switch in Settings is cosmetic (VoLTE itself works).
