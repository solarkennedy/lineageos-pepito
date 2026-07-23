# Release notes — pepito-23.2-r1

First public release of LineageOS 23.2 (Android 16) for the Palm PVG100 (pepito).

Source is pinned at tag **`pepito-23.2-r1`** across every repo; the build tree is
described by [`manifests/pepito.xml`](../manifests/pepito.xml).

## What works

Telephony (SIM, LTE, VoLTE, calls, SMS), mobile data, in-call audio, Wi-Fi,
Bluetooth (incl. hands-free calling), GPS, both cameras, all sensors, hardware
video encode/decode, wired Android Auto, FBE encryption, hardware Gatekeeper,
TEE-backed keys. SELinux is **Enforcing**.

See the [README](../README.md) for the full table and the pepito extras
(Face Unlock, Life Mode, PepitoLauncher2, QS volume slider, power-key recovery).

## Known limitations

- **Single-SIM.**
- **The Enhanced 4G / VoLTE toggle is cosmetic.** VoLTE itself works; the 2017
  modem speaks an older IMS interface (v01) than the Android 16 framework drives
  (v02), so the Settings switch doesn't move it.
- **Audio DSP calibration (ACDB) is not fully tuned** — audio works on all paths,
  quality isn't final.
- **Metadata encryption is not enabled** (file-based encryption is).
- **Occasional carrier re-registration drop.** Data/voice can silently drop
  registration and camp on a roaming partner instead of your home network,
  showing a `!` on the status bar even though it was working moments earlier.
  Seen both right after a fresh flash and spontaneously during normal use. One
  Airplane Mode toggle forces re-registration and fixes it every time. Not yet
  fully root-caused.

## Flashing notes

- **No Fastboot.** First install is over Qualcomm EDL; later updates are a normal
  `adb sideload` in recovery. **Take a full EDL backup first** — see the
  [README](../README.md#installation).
- **Coming from stock wipes `/data`** (the switch to file-based encryption). An
  in-place update over this build keeps `/data`.
- **First flash from a Google-signed-in stock phone:** this release ships the
  `config` (FRP) partition zeroed, so you land in setup cleanly instead of a
  bogus "factory reset" prompt on every boot.
- **One-time factory-reset prompt when upgrading from an early test build.** If
  you flash this over a pepito build from before 2026-07-22, the boot Root-of-Trust
  changes once and Android will ask to factory reset (it can't unwrap the old
  `/data` keys). Wipe and set up again; every flash after that is stable and never
  re-wipes. Fresh installs from stock are unaffected.

## For tinkerers

- **qmux escape hatch:** the modem runs on the legacy IPC-Router path by default
  on pepito. Override with `persist.vendor.qmux.enable` (`1`/`0`) if you need to
  force it on or off; unset falls back to the per-variant default.
- **Boot verification:** the device is Verified Boot 1.0. Boot images ship green
  via a keyless fail-open graft (no signing key, fixed Root-of-Trust across
  builds); see `scripts/boot-signing/`.
- **Recovery adb runs as root** (physical-access + advanced-menu gated; `/data`
  stays encrypted regardless).

## Source

All 13 repos, branches, and forks are listed in the
[README source table](../README.md#source-repos). Vendor blobs are extracted from
your own device with `device/xiaomi/Mi8937/extract-files.py`.
