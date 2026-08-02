# LineageOS 23.2 for the Palm PVG100 (pepito)

![The Palm PVG100 running LineageOS 23.2 / Android 16](assets/hero-about-android16.jpg)

<sup>
About-phone on the PVG100: LineageOS 23.2, Android 16, kernel 4.19.325 — on hardware that shipped Android 8.1.
▶ [Watch the Android 16 easter egg running on it](assets/pvg100-android16-easter-egg.webm).
</sup>

**Want the download?**
Grab the ROM and flashing instructions from the [releases page](https://github.com/solarkennedy/lineageos-pepito/releases) — pick the **vanilla** build, or the **GApps** build if you want Google apps baked in.
Or read the full [bring-up write-up](https://kyle.cascade.family/posts/porting-android-16-to-a-palm-pvg100-pepito).

**Questions, or something broken?**
Discussion and support happen in the [XDA thread](https://xdaforums.com/t/rom-unofficial-a16-lineageos-23-2-for-the-palm-pvg100.4795985/); bugs can also go in [issues](https://github.com/solarkennedy/lineageos-pepito/issues).

## Hardware

| | |
|---|---|
| SoC | Qualcomm MSM8940 (Snapdragon 435) + Adreno 505 |
| RAM / storage | 3 GB / 32 GB |
| Display | 3.3″ 720×1280, FocalTech FT8613 in-cell touch |
| Kernel | Linux 4.19.x (mainline-aligned; stock shipped 3.18) |
| Stock OS | Android 8.1 (`v1AML-0`) |

## What works

| Subsystem | Status |
|---|---|
| Telephony (SIM, LTE, VoLTE, calls, SMS) | ✅ |
| Mobile data | ✅ |
| In-call audio (earpiece / speaker / mic) | ✅ |
| Wi-Fi / Bluetooth | ✅ |
| GPS | ✅ |
| Cameras | ✅ |
| Sensors (Compass, IMU, prox, lux, etc) | ✅ |
| HW video encode / decode (Venus) | ✅ |
| FBE encryption, HW Gatekeeper, TEE keys | ✅ |
| SELinux | ✅ Enforcing |

Known limitations, tracked for the [release notes](docs/RELEASE-NOTES.md).

### Pepito extras

This build brings back features the original Palm OS had - and a few quality-of-life additions for a phone with no volume keys:

- **Face Unlock** — the original phone had it, and AOSP/LineageOS ship only a stub matcher.
  This wires in a real RGB recognition engine (a port of Paranoid Android's "Sense"), so you can enroll your face in Settings and unlock by looking at the phone.
  RGB-only hardware, so it's the weak "convenience" tier (still asks for a PIN after reboot / for payments) — the same ceiling the original Palm feature had.
- **Life Mode** — a quick-settings tile reviving Palm's old idea: Do Not Disturb plus aggressive power saving in one tap — kills the radios, drops the screen to greyscale, and enables battery saver.
  On a battery this tiny it meaningfully extends runtime.

  <img src="assets/battery-wear-profile.png" alt="Battery wear profile — charge-cycle count across eight 12.5% battery-level bands" width="280">

  <sup>
  Battery wear profile (Settings → System): the fuel gauge's charge-cycle count split into eight 12.5% battery-level bands — where this pack actually got cycled.
  A pepito addition, kernel-fed from the FG's per-SoC buckets.
  </sup>
- **PepitoLauncher2** — a from-scratch reimplementation of the original PVG100 home screen: a single three-column vertical drawer, no labels, with the macOS-dock-style lens zoom as you scroll.
  Decompiled from the stock app to match the exact lens curve and layout.
  Ships alongside the normal launcher — pick it in Settings.
  ([source](https://github.com/solarkennedy/PepitoLauncher2))
- **QS volume slider** — a horizontal volume slider in Quick Settings, because the PVG100 has no hardware volume buttons.
- **Power-key recovery navigation** — the phone has only a power button (no volume keys), so LineageOS recovery was patched to navigate the way stock did: short-press to cycle, long-press to select.

<img src="assets/pepito-launcher.png" alt="PepitoLauncher2 — the interlocking three-column vertical drawer with lens-zoom icons" width="280">

<sup>
PepitoLauncher2: the interlocking three-column drawer with the lens-zoom effect and the SETTINGS / jump / MANAGE bar, rebuilt from the stock 2018 app.
</sup>

## Installation

> The PVG100 has **no Fastboot**.
> First, take a FULL [EDL backup](https://xdaforums.com/t/guide-using-edl-to-backup-a-palm-pvg-100-pepito-on-linux.4719549/) first!
> There is a risk that your phone is not like mine and has a different partition layout.

DO NOT FLASH UNLESS YOU HAVE A BACKUP FIRST!!!

### Procedure

1. Download the EDL package from the [releases page](https://github.com/solarkennedy/lineageos-pepito/releases) — **vanilla** or **GApps**, not both.
   The `qdl` flasher is bundled inside the archive; follow the `README.md` it contains.
1. Flash the EDL image set (bootloader, boot, recovery, system, vendor) with the phone in EDL mode.
   *(Detailed EDL loader + partition steps: see [BUILD.md](BUILD.md) §5 — TBD at release.)*
1. **Boot to recovery** by holding **Power** through 3 boot cycles.
1. **First boot requires a userdata wipe** coming from stock (the switch to file-based encryption).

## The gory details

See the details in **[bring-up write-up](https://kyle.cascade.family/posts/porting-android-16-to-a-palm-pvg100-pepito)** blog post.

### The full record

The complete working notes — every subsystem's bring-up plan, investigation log, and dead end — live in [plans/](plans/), included verbatim.
[plans/PLAN.md](plans/PLAN.md) is the map.

### Source repos

**This table is the single source of truth** for every repo carrying pepito work — the tree path it lives at, the branch, what's in it, and the fork each is pushed to.
The linked LineageOS repos are the bases the local branches sit on.
Last surveyed 2026-08-01 — Gate 0 remote creation done (`PLAN-release.md`); `frameworks/native` + `system/bpfprogs` forks added for the zero-CPU-attribution (timeInState) fix.

| Tree path | Base repo | Branch | Pepito work | Fork |
|---|---|---|---|---|
| `kernel/xiaomi/msm8937` | [android_kernel_xiaomi_msm8937](https://github.com/LineageOS/android_kernel_xiaomi_msm8937) | `pepito-rmnet` | 67 commits: pepito DTs, legacy-IPC backport (the modem fix), TFA9896, BHy hub, RPMB/sdhci fixes | [solarkennedy/android_kernel_xiaomi_msm8937](https://github.com/solarkennedy/android_kernel_xiaomi_msm8937) |
| `device/xiaomi/Mi8937` | [android_device_xiaomi_Mi8937](https://github.com/LineageOS/android_device_xiaomi_Mi8937) | `pepito-rmnet` | 51 commits: pepito variant — qmux radio path, audio, camera HAL, ims_enabler, sepolicy | [solarkennedy/android_device_xiaomi_Mi8937](https://github.com/solarkennedy/android_device_xiaomi_Mi8937) |
| `device/xiaomi/mithorium-common` | [android_device_xiaomi_mithorium-common](https://github.com/LineageOS/android_device_xiaomi_mithorium-common) | `pepito-rmnet` | 64 commits: shared family tree — shims, init, manifest, sepolicy | [solarkennedy/android_device_xiaomi_mithorium-common](https://github.com/solarkennedy/android_device_xiaomi_mithorium-common) |
| `bootable/recovery` | [android_bootable_recovery](https://github.com/LineageOS/android_bootable_recovery) | `lineage23-pepito` | 12 commits: power-key-only menu navigation, EDL reboot, `adbd as root` (see note below) | [solarkennedy/android_bootable_recovery](https://github.com/solarkennedy/android_bootable_recovery) |
| `frameworks/base` | [android_frameworks_base](https://github.com/LineageOS/android_frameworks_base) | `pepito-qs-volume-slider` | QS volume slider (SystemUI, Compose QS) | [solarkennedy/android_frameworks_base](https://github.com/solarkennedy/android_frameworks_base) |
| `frameworks/native` | [android_frameworks_native](https://github.com/LineageOS/android_frameworks_native) | `pepito-timeinstate` | 1 commit: revert libtimeinstate raw-tracepoint attach for `sched_process_free` — part of the zero-CPU-attribution fix on 4.19 | [solarkennedy/android_frameworks_native](https://github.com/solarkennedy/android_frameworks_native) |
| `lineage-sdk` | [android_lineage-sdk](https://github.com/LineageOS/android_lineage-sdk) | `pepito-qs-volume-slider` | `qs_show_volume_slider` setting + settings-DB upgrade | [solarkennedy/android_lineage-sdk](https://github.com/solarkennedy/android_lineage-sdk) |
| `packages/apps/LineageParts` | [android_packages_apps_LineageParts](https://github.com/LineageOS/android_packages_apps_LineageParts) | `pepito-lineageparts` | 11 commits: volume-slider toggle UI | [solarkennedy/android_packages_apps_LineageParts](https://github.com/solarkennedy/android_packages_apps_LineageParts) |
| `hardware/interfaces` | [android_hardware_interfaces](https://github.com/LineageOS/android_hardware_interfaces) | `pepito` | BT binary-BDADDR support, sensors HAL input group | [solarkennedy/android_hardware_interfaces](https://github.com/solarkennedy/android_hardware_interfaces) |
| `hardware/qcom-caf/bt` | [android_hardware_qcom_bt](https://github.com/LineageOS/android_hardware_qcom_bt) | `pepito` (ref; HEAD detached, matches tip) | Pronto/SMD libbt-vendor bring-up | [solarkennedy/android_hardware_qcom_bt](https://github.com/solarkennedy/android_hardware_qcom_bt) |
| `system/core` | [android_system_core](https://github.com/LineageOS/android_system_core) | `pepito` (ref; HEAD detached, matches tip) | 1 commit: silence f2fs recovery log — kept, forked for completeness | [solarkennedy/android_system_core](https://github.com/solarkennedy/android_system_core) |
| `system/bpfprogs` | [platform/system/bpfprogs](https://android.googlesource.com/platform/system/bpfprogs) (AOSP; no LineageOS mirror) | `pepito-timeinstate` | 2 commits: revert CO-RE/BTF tracepoint-defs support + build timeInState with `-mcpu=v2` for the pre-5.1 kernel BPF verifier — the other half of the zero-CPU-attribution fix | [solarkennedy/android_system_bpfprogs](https://github.com/solarkennedy/android_system_bpfprogs) |
| `vendor/lineage` | [android_vendor_lineage](https://github.com/LineageOS/android_vendor_lineage) | — | 0 commits — the static kernel-headers export (`726a3828`) was reverted 2026-07-15 (`cfb451c6`) and build+flash validated on the stock `generated_kernel_includes` genrule; tree is now byte-identical to upstream `lineage-23.2` | _dropped — not needed; manifest pins plain upstream_ |
| `packages/apps/PepitoLauncher2` | local `~/Projects/PepitoLauncher2` | `master` | stock-Palm-style launcher reimplementation (whole app; needs a manifest entry) | [solarkennedy/PepitoLauncher2](https://github.com/solarkennedy/PepitoLauncher2) (already existed, pushed, current) |
| — (this repo) | — | `lineageos23.2` | landing/index: README, BUILD, manifest, plans/, scripts/ incl. boot-signing | [solarkennedy/lineageos-pepito](https://github.com/solarkennedy/lineageos-pepito) (private) |
| `vendor/xiaomi` | — | `pepito-vendor` | 4 commits: curated blob trees (Mi8937 + mithorium-common), libsdm-color + libacdbloader closures. Dirty (patchelf DT_NEEDED shim edits on qcrild/IMS daemons + untracked `Mi8937/proprietary/odm/`) — not yet pushed | [solarkennedy/proprietary_vendor_xiaomi](https://github.com/solarkennedy/proprietary_vendor_xiaomi) (private) |
| `diag-tools/` | — | not a git repo | bench diagnostics — must not ship in the image | _skipped — local-only, no remote (excluded from release build)_ |

Bench-local, intentionally never pushed: `build/make` (envsetup.sh guard against building on the netbook) and an untracked header-export artifact in `hardware/qcom-caf/common`.

The [manifest](manifests/pepito.xml) in this repo pins the whole tree once the forks are up — see [BUILD.md](BUILD.md).

## Credits

- **LineageOS** and the **Mi-Thorium** team — the unified MSM8937 device/kernel trees this build stands on.
- The postmarketOS msm89x7 work, which informed the modem bring-up.
- Palm's GPL kernel drop (incomplete, but useful).

## Disclaimer

Flashing custom firmware voids warranties and can brick devices.
Nothing here ships Palm/TCL proprietary software; vendor blobs are extracted from a device you own.
Use at your own risk.
