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

**This table is the single source of truth** for every repo carrying pepito
work — the tree path it lives at, the branch, what's in it, and (as they are
created) the fork each will be pushed to. The linked LineageOS repos are the
bases the local branches sit on. Last surveyed 2026-07-12.

| Tree path | Base repo | Branch | Pepito work | Fork |
|---|---|---|---|---|
| `kernel/xiaomi/msm8937` | [android_kernel_xiaomi_msm8937](https://github.com/LineageOS/android_kernel_xiaomi_msm8937) | `pepito-rmnet` | 67 commits: pepito DTs, legacy-IPC backport (the modem fix), TFA9896, BHy hub, RPMB/sdhci fixes | _TBD_ |
| `device/xiaomi/Mi8937` | [android_device_xiaomi_Mi8937](https://github.com/LineageOS/android_device_xiaomi_Mi8937) | `pepito-rmnet` | 51 commits: pepito variant — qmux radio path, audio, camera HAL, ims_enabler, sepolicy | _TBD_ |
| `device/xiaomi/mithorium-common` | [android_device_xiaomi_mithorium-common](https://github.com/LineageOS/android_device_xiaomi_mithorium-common) | `pepito-rmnet` | 64 commits: shared family tree — shims, init, manifest, sepolicy | _TBD_ |
| `bootable/recovery` | [android_bootable_recovery](https://github.com/LineageOS/android_bootable_recovery) | `lineage23-pepito` | 12 commits: power-key-only menu navigation, EDL reboot. ⚠️ carries `adbd as root` — **strip before release** | _TBD_ |
| `frameworks/base` | [android_frameworks_base](https://github.com/LineageOS/android_frameworks_base) | `pepito-qs-volume-slider` | QS volume slider (SystemUI, Compose QS) | _TBD_ |
| `lineage-sdk` | [android_lineage-sdk](https://github.com/LineageOS/android_lineage-sdk) | `pepito-qs-volume-slider` | `qs_show_volume_slider` setting + settings-DB upgrade | _TBD_ |
| `packages/apps/LineageParts` | [android_packages_apps_LineageParts](https://github.com/LineageOS/android_packages_apps_LineageParts) | `pepito-lineageparts` | 11 commits: volume-slider toggle UI | _TBD_ |
| `hardware/interfaces` | [android_hardware_interfaces](https://github.com/LineageOS/android_hardware_interfaces) | `pepito` (ref; HEAD detached) | BT binary-BDADDR support, sensors HAL input group | _TBD_ |
| `hardware/qcom-caf/bt` | [android_hardware_qcom_bt](https://github.com/LineageOS/android_hardware_qcom_bt) | `pepito` (ref; HEAD detached) | Pronto/SMD libbt-vendor bring-up | _TBD_ |
| `system/core` | [android_system_core](https://github.com/LineageOS/android_system_core) | `pepito` (ref; HEAD detached) | 1 commit: silence f2fs recovery log — candidate to just drop | _TBD / drop_ |
| `vendor/lineage` | [android_vendor_lineage](https://github.com/LineageOS/android_vendor_lineage) | `pepito` (ref; HEAD detached) | 1 commit: static kernel-headers export (load-bearing for the build) | _TBD_ |
| `packages/apps/PepitoLauncher2` | local `~/Projects/PepitoLauncher2` | `master` | stock-Palm-style launcher reimplementation (whole app; needs a manifest entry) | _TBD_ |
| — (this repo) | — | `lineageos23.2` | landing/index: README, BUILD, manifest, plans/, scripts/ incl. boot-signing | _TBD — create first_ |
| `vendor/xiaomi` | — | not a git repo | proprietary blobs — packaging model being finalized (Phase 6) | _TBD — `proprietary_vendor_xiaomi`_ |
| `diag-tools/` | — | not a git repo | bench diagnostics — must not ship in the image | _TBD — optional tools repo_ |

Bench-local, intentionally never pushed: `build/make` (envsetup.sh guard
against building on the netbook) and an untracked header-export artifact in
`hardware/qcom-caf/common`.

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
