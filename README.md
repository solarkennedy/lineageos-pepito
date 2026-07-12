# LineageOS 23.2 for the Palm PVG100 (“pepito”)

A full LineageOS 23.2 (Android 16) bring-up for the **Palm PVG100** — the tiny
3.3″ credit-card phone from 2018 — built as a runtime-detected variant of the
LineageOS / Mi-Thorium unified `Mi8937` tree (MSM8917/8937/8940 family).

> **Status: pre-release.** Everything below works on the bench device; signed
> release images and pushed source branches are in progress. This repo is the
> index — it links to every source repo carrying pepito changes, and will host
> build instructions, screenshots, and release notes.

## Hardware

| | |
|---|---|
| SoC | Qualcomm MSM8940 (Snapdragon 435) + Adreno 505 |
| RAM / storage | 3 GB / 32 GB |
| Display | 3.3″ 720×1280 |
| Kernel | Linux 4.19.x (mainline-aligned; stock shipped 3.18) |
| Stock OS | Android 8.1 (`v1AML-0`) |

## What works

| Subsystem | Status |
|---|---|
| Telephony (SIM, LTE, calls, SMS) | ✅ incl. VoLTE — the multi-year modem blocker is solved |
| Mobile data | ✅ |
| In-call audio (earpiece / speaker) | ✅ |
| Wi-Fi / Bluetooth | ✅ |
| GPS | ✅ |
| Cameras (both, preview + JPEG) | ✅ |
| Sensors (all 20, incl. the BHy hub) | ✅ |
| HW video encode/decode | ✅ |
| FBE encryption, HW gatekeeper, TEE keys | ✅ |
| SELinux | ✅ Enforcing |
| Extras | QS volume slider (no hardware volume keys), PepitoLauncher2 |

Known limitations are tracked for the release notes (audio DSP calibration
quality, single-SIM, cosmetic Enhanced-4G toggle, no metadata encryption).

## The story (short version)

The PVG100 never had a custom-ROM ecosystem: its 2017-era modem firmware
refuses to boot against a modern AP software stack. The root cause turned out
to be the **AP-side IPC transport**: the modem speaks the legacy Qualcomm
IPC Router (`AF_MSM_IPC`), not the modern QRTR the 4.19 kernel offers. The fix
was backporting the legacy IPC stack wholesale (ipc_router core, rpmsg
transport, msm QMI, RFSA/memshare, the stock A8 `rmt_storage`) and forcing the
userspace QMI clients onto it — after which the modem, and everything riding
on it (SIM, LTE, data, IMS/VoLTE, GPS), came alive. A longer write-up is
planned.

## Source repos

The build spans the repos below on top of a stock LineageOS 23.2 manifest.
“New remote” columns are being populated as the forks are created; until
then the linked LineageOS repos are the bases the local branches sit on.

| Repo | Branch | What's in it | Fork |
|---|---|---|---|
| [android_kernel_xiaomi_msm8937](https://github.com/LineageOS/android_kernel_xiaomi_msm8937) | `pepito-rmnet` | pepito DTs, legacy-IPC backport, TFA9896, BHy hub, RPMB/sdhci fixes | _TBD_ |
| [android_device_xiaomi_Mi8937](https://github.com/LineageOS/android_device_xiaomi_Mi8937) | `pepito-rmnet` | pepito variant: qmux radio path, audio, camera HAL, sepolicy | _TBD_ |
| [android_device_xiaomi_mithorium-common](https://github.com/LineageOS/android_device_xiaomi_mithorium-common) | `pepito-rmnet` | shared family tree: shims, init, manifest, sepolicy | _TBD_ |
| [android_bootable_recovery](https://github.com/LineageOS/android_bootable_recovery) | `lineage23-pepito` | power-key-only menu navigation, EDL reboot | _TBD_ |
| [android_frameworks_base](https://github.com/LineageOS/android_frameworks_base) | `pepito-qs-volume-slider` | QS volume slider (SystemUI) | _TBD_ |
| [android_lineage-sdk](https://github.com/LineageOS/android_lineage-sdk) | `pepito-qs-volume-slider` | `qs_show_volume_slider` setting | _TBD_ |
| [android_packages_apps_LineageParts](https://github.com/LineageOS/android_packages_apps_LineageParts) | `pepito-lineageparts` | volume-slider toggle UI | _TBD_ |
| [android_hardware_interfaces](https://github.com/LineageOS/android_hardware_interfaces) | `pepito` | BT binary-BDADDR support, sensors HAL tweak | _TBD_ |
| [android_hardware_qcom_bt](https://github.com/LineageOS/android_hardware_qcom_bt) | `pepito` | Pronto/SMD libbt-vendor bring-up | _TBD_ |
| [android_system_core](https://github.com/LineageOS/android_system_core) | `pepito` | minor recovery log fix | _TBD_ |
| [android_vendor_lineage](https://github.com/LineageOS/android_vendor_lineage) | `pepito` | static kernel-headers export | _TBD_ |
| PepitoLauncher2 | `master` | stock-Palm-style launcher reimplementation | _TBD_ |
| proprietary vendor blobs | — | packaging model being finalized | _TBD_ |

The [manifest](manifests/pepito.xml) in this repo pins the whole tree once the
forks are up — see [BUILD.md](BUILD.md).

## Building

See [BUILD.md](BUILD.md). Short form: standard LineageOS 23.2 `repo init`,
drop `manifests/pepito.xml` into `.repo/local_manifests/`, sync, and
`lunch lineage_Mi8937-bp4a-userdebug`.

## The full record

The complete working notes — every subsystem's bring-up plan, investigation
log, and dead end — live in [plans/](plans/), included verbatim for the
record. [plans/PLAN.md](plans/PLAN.md) is the map.

The bench build/flash tooling is in [scripts/](scripts/), including
[scripts/boot-signing/](scripts/boot-signing/) — the AVBv1 signing tool that
makes a boot image the PVG100 bootloader will actually boot.

## Screenshots

Coming to [screenshots/](screenshots/) — the phone, the QS volume slider,
PepitoLauncher2.

## Credits

- **LineageOS** and the **Mi-Thorium** team — the unified MSM8937 device/kernel
  trees this build stands on.
- The postmarketOS msm89x7 work, which informed the modem bring-up.
- Palm's GPL kernel drop (incomplete, but useful).

## Disclaimer

Flashing custom firmware voids warranties and can brick devices. Nothing here
ships Palm/TCL proprietary software; vendor blobs are extracted from a device
you own. Use at your own risk.
