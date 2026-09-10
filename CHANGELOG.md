# Changelog — LineageOS 23.2 for pepito (Palm PVG100)

## 20260910 (2026-09-10)

### kernel (msm8937) (since pepito-23.2-20260906)
- misc: bhy: drain FIFO in 256-byte chunks and make recovery actually run

### device/Mi8937 (since pepito-23.2-20260906)
- Mi8937: pre-approve Android Auto notification listener (gapps)
- Mi8937: publish the GSF ID after storage unlocks, not at boot_completed

### LineageParts (since pepito-23.2-20260906)
- LineageParts: let the Play certification row re-fetch the device ID

### landing (docs/scripts) (since pepito-23.2-20260906)
- release: track system/sepolicy as a pepito fork
- plans: draft the Android 17 / LineageOS 24.0 upgrade lane
- PLAN-androidauto: record staged default notification-listener approval
- pepito-spec.sh: surface IMEI + SKU as labelled, Luhn-checked identity
## 20260906 (2026-09-06)

### device/Mi8937 (since pepito-23.2-20260903)
- Mi8937: publish the GSF device ID for the Play certification row

### LineageParts (since pepito-23.2-20260903)
- LineageParts: add a Google Play certification section to Pepito Tweaks
## 20260903 (2026-09-04)

### landing (docs/scripts) (since pepito-23.2-20260902)
- ota: 20260903 gapps
- ota: 20260903 vanilla
- changelog: 20260903
- changelog: 20260903
- PLAN: status refresh — device roster, NAS/WFC/tethering/AA/integrity lanes closed
- changelog: 20260903
- make-magisk-boot: bake PREINITDEVICE=oem so module sepolicy rules apply
- scripts: ship a pre-patched Magisk boot image in the EDL bundle
## 20260902 (2026-09-02)

### device/Mi8937 (since pepito-23.2-20260823)
- Mi8937: pepito — fix three defects that broke flash-and-go Wi-Fi calling
- Mi8937: pepito — opt-in persistent adb root across reboots
- Mi8937: gapps — speech-to-text out of the box (default recognizer overlay)
- qmux: ims_enabler — provision the IMS MSISDN + re-run on SIM load (virgin-unit VoWiFi)

### device/mithorium-common (since pepito-23.2-20260823)
- sepolicy: document vendor.qmux.ims_msisdn (ims_enabler MSISDN phase status prop)

### landing (docs/scripts) (since pepito-23.2-20260823)
- scripts: add pepito-spec.sh — offline "what did this unit ship with" report
- extract-nikgapps: add APK override mechanism with safety rails
- PLAN-vowifi: parts 49-52 — virgin-unit WFC root cause (per-sub IMSS store + empty IMS MSISDN), fix staged in Mi8937 95051da4
## 20260823 (2026-08-24)

### kernel (msm8937) (since pepito-23.2-20260822)
- power: qpnp-fg: allow resetting wear history via cycle_counts write

### device/Mi8937 (since pepito-23.2-20260822)
- qmux: ims_enabler: wifi_call must be 1, not 2 — 2 registers IMS-over-IWLAN SMS-only
- Mi8937: pepito — clear modem WLAN availability on Wi-Fi loss (fixes the ~50 s "Emergency calls only" cold re-attach)

### device/mithorium-common (since pepito-23.2-20260822)
- mithorium-common: battery wear profile — add confirmed Reset wear data button
- gotweaks: GPU performance floor on by default
- gotweaks: add GPU performance floor toggle (min_pwrlevel 375MHz)
- gotweaks: default zram to lz4, make zstd opt-in

### LineageParts (since pepito-23.2-20260822)
- GoTweaks: GPU performance floor switch defaults on
- GoTweaks: GPU performance floor switch
- GoTweaks: zram zstd toggle defaults off, document lmkd-kill cost

### landing (docs/scripts) (since pepito-23.2-20260822)
- changelog: 20260823
- changelog: 20260823
- Switch to modern linux-msm qdl; add qdl-dump.sh EDL backup script
- plans: refresh PLAN.md to 2026-08-22; tethering validated end-to-end
## 20260822 (2026-08-22)

### kernel (msm8937) (since pepito-23.2-20260803)
- diag: keep the modem on the rpmsg transport on pepito

### device/Mi8937 (since pepito-23.2-20260803)
- Mi8937: pepito — Wi-Fi calling productization (feeder, toggle gate, fresh-unit arming)
- Mi8937: add pepito modem power coefficients for mobile-radio attribution

### device/mithorium-common (since pepito-23.2-20260803)
- mithorium-common: pepito — Wi-Fi calling carrier config + qmux status props

### vendor/lineage (since pepito-23.2-20260803)
- version: honor an externally injected LINEAGE_BUILD_DATE

### PepitoLauncher2 (since pepito-23.2-20260803)
- Reserve top scroll headroom so the first row can reach the lens center
- Redraw the manage-mode brackets while icons animate
- Keep a manage-mode drag anchored to the finger across the divider

### landing (docs/scripts) (since pepito-23.2-20260803)
- plans: Wi-Fi calling / VoWiFi bring-up notes
- release: single authoritative date threaded through build+release
## 20260803 (2026-08-04)

### device/Mi8937 (since pepito-23.2-20260802)
- Mi8937: pepito — ship Blocker, running as a system-UID app (no root, no Shizuku)
- Mi8937: pepito — re-enable compressed audio offload; the ADSP EFAILED is gone
- Mi8937: pepito — full-AOT (speed) dexpreopt for Aperture + PepitoLauncher2
- Mi8937: pepito defaults all three animation scales to 0.5x

### device/mithorium-common (since pepito-23.2-20260802)
- usb: uvc: advertise only what the webcam pipeline delivers
- mithorium: Neuter SDM MDP-idle fallback timer — its refresh loop taxed screen-on ~45 mW and the fallback never worked
- mithorium-common: default zram to zstd

### vendor/xiaomi (blobs) (since pepito-23.2-20260802)
- mithorium-common: Ship libOpenCL + public.libraries.txt — apps saw no GPU compute
- mithorium-common: Ship libsdmextension + libscalar + libhdr_tm — MDP overlay composition was dead, every frame GPU-composited
- Mi8937: Ship Widevine DRM (L1!) — was never packaged, only clearkey shipped
- Mi8937: Ship the QTI perf HAL — interaction/launch/camera boosts were all dead

### frameworks/base (since pepito-23.2-20260802)
- SettingsProvider: seed animator_duration_scale like the other two scales

### LineageParts (since pepito-23.2-20260802)
- GoTweaksSettings: zram-zstd toggle defaults ON

### landing (docs/scripts) (since pepito-23.2-20260802)
- ota: 20260803 vanilla
- changelog: 20260803
- changelog: 20260803
- changelog: 20260803
- changelog: 20260803
- PLAN-hw-accel: OpenCL app-namespace tick done; Lane E webcam-MJPEG notes
- PLAN-blocker: new lane — Blocker as a system-UID app, flash-validated
- PLAN-hw-accel: OpenCL + offload flash-validated on baked images
- PLAN-hw-accel: 08-03 sweep — OpenCL solved+staged, Vulkan already worked, Lane C offload EFAILED gone (enable staged), video-to-VIG functional check done
- PLAN-hw-accel: Lanes A+B solved/validated/committed; idle-storm root cause + fix; CT-3 A/B results; nightly-diff sweep artifact
- plans: perf-battery — dexpreopt audit result + post-flash check
- plans: perf-battery — queue schedtune top-app boost A/B (stune all-zero finding)
- plans: new PLAN-hw-accel lane — full accel-block inventory + 4 sub-lanes
- plans: perf-battery — responsiveness lane (perf HAL bring-up, zstd/animation defaults)
## 20260802 (2026-08-02)

### kernel (msm8937) (since pepito-23.2-20260801)
- arm64: dts: pepito: restore the camera flash switch source and enable pin
- arm64: configs: mi8937: enable exFAT, UDF and ISO9660
- power: qpnp-smbcharger: support qcom,hvdcp-not-supported; disable HVDCP on pepito
- i2c-msm-v2, clk: keep console clock votes on serial-debug boots
- clk: msm: defer the TZ uart handoff-vote drop to first suspend
- i2c-msm-v2: restore probe-end clock disable

### device/Mi8937 (since pepito-23.2-20260801)
- Mi8937: camera: add torch strength for the flashlight slider
- Mi8937: ship exfatprogs so vold can mount exFAT media

### frameworks/base (since pepito-23.2-20260801)
- BatteryService: report FULL when the charging limit holds the charge

### frameworks/native
- (first tagged in 20260802 — no prior anchor)

### system/bpfprogs
- (first tagged in 20260802 — no prior anchor)

### vendor/lineage (since pepito-23.2-20260801)
- aconfig: bp4a: enable the SystemUI flashlight strength slider

### landing (docs/scripts) (since pepito-23.2-20260801)
- release: PVG100E variant support — per-variant firehose loaders + rawprogram XMLs
- manifest: pin frameworks/native + system/bpfprogs forks (timeInState fix)
- plans: exFAT, camera flash sync, torch brightness slider
- release: add frameworks/native + system/bpfprogs forks (timeInState fix)
## 20260801 (2026-08-01)

### device/Mi8937 (since pepito-23.2-20260729)
- Mi8937: ship pepito's real /persist dir via BOARD_ROOT_EXTRA_FOLDERS
- Mi8937: bake the Google app into the gapps build as default assistant
- Mi8937: ship OpenEUICC on pepito for the removable eUICC card
- Mi8937: measure pepito radio idle and scanning power

### device/mithorium-common (since pepito-23.2-20260729)
- boot: set BOARD_CUSTOM_BOOTIMG so the OTA uses the grafted prebuilt
- custom_bootimg: re-add the boot->kernel dependency dropped by the hook
- BoardConfigCommon: correct the stale BOARD_ROOT_EXTRA_SYMLINKS comment
- boot-signing: drop the cryptography dependency (stdlib only)
- Make sign-boot-graft.py use fully python path
- boot: graft the fail-open signature onto boot.img + recovery.img at build time

### landing (docs/scripts) (since pepito-23.2-20260729)
- changelog: 20260801
- ota: drop bad 20260731 feed entries (unsigned-boot brick)
- ota: stamp the feed with the build's real timestamp, not midnight
- ota: 20260731 gapps
- changelog: 20260731
- release: retry per-asset uploads (survive 'tls: bad record MAC')
- changelog: 20260731
- changelog: 20260731
- ota: 20260731 vanilla
- changelog: 20260731
- ota: empty pepito.json — 20260729/20260731 OTAs shipped unsigned boot
- changelog: 20260731
- plans: sensors — /persist image regression root-caused, BoardConfig fix
- boot-signing: move the graft signer in-tree; prepare-flash uses it
- build-remotely: forward PEPITO_SERIAL_CONSOLE for serial debug builds
- ota: 20260731 gapps
- ota: 20260731 vanilla
- changelog: 20260731
- changelog: 20260731
- changelog: 20260731
- changelog: 20260731
- plans: add eSIM-LPA, IPv6-DNS, and MCFG lanes; update index + misc
- release.sh: hardcode REPO_ROOT to the landing repo (symlink bug)
- ota: populate pepito.json with the real 20260729 feed (both channels)
- ota: seed empty pepito.json so the Updater feed resolves
## 20260731 (2026-07-31)

### device/Mi8937 (since pepito-23.2-20260729)
- Mi8937: ship pepito's real /persist dir via BOARD_ROOT_EXTRA_FOLDERS
- Mi8937: bake the Google app into the gapps build as default assistant
- Mi8937: ship OpenEUICC on pepito for the removable eUICC card
- Mi8937: measure pepito radio idle and scanning power

### device/mithorium-common (since pepito-23.2-20260729)
- custom_bootimg: re-add the boot->kernel dependency dropped by the hook
- BoardConfigCommon: correct the stale BOARD_ROOT_EXTRA_SYMLINKS comment
- boot-signing: drop the cryptography dependency (stdlib only)
- Make sign-boot-graft.py use fully python path
- boot: graft the fail-open signature onto boot.img + recovery.img at build time

### landing (docs/scripts) (since pepito-23.2-20260729)
- release: retry per-asset uploads (survive 'tls: bad record MAC')
- changelog: 20260731
- changelog: 20260731
- ota: 20260731 vanilla
- changelog: 20260731
- ota: empty pepito.json — 20260729/20260731 OTAs shipped unsigned boot
- changelog: 20260731
- plans: sensors — /persist image regression root-caused, BoardConfig fix
- boot-signing: move the graft signer in-tree; prepare-flash uses it
- build-remotely: forward PEPITO_SERIAL_CONSOLE for serial debug builds
- ota: 20260731 gapps
- ota: 20260731 vanilla
- changelog: 20260731
- changelog: 20260731
- changelog: 20260731
- changelog: 20260731
- plans: add eSIM-LPA, IPv6-DNS, and MCFG lanes; update index + misc
- release.sh: hardcode REPO_ROOT to the landing repo (symlink bug)
- ota: populate pepito.json with the real 20260729 feed (both channels)
- ota: seed empty pepito.json so the Updater feed resolves
## 20260729 (2026-07-29)

### kernel (msm8937) (since pepito-23.2-20260728)
- msm: mdss: add sunlight readability enhancement (SRE) via DSPP hist-LUT

### device/Mi8937 (since pepito-23.2-20260728)
- Mi8937: add pepito power_profile so battery attribution works
- Mi8937: camera: recover the torch flash node when the backend lies
- Mi8937: enable LiveDisplay Sunlight Enhancement on the kernel sre node

### landing (docs/scripts) (since pepito-23.2-20260728)
- release: bring back OTA upgrades (Updater feed) alongside EDL
- plans: sunlight readability lane — implemented + flash-validated
## 20260728 (2026-07-28)

### device/Mi8937 (since pepito-23.2-r1)
- Mi8937: present honest Palm PVG100 identity in the fingerprint
- Mi8937: drop the Play Integrity fingerprint experiment
- sepolicy: label BHy calibration profiles at /data/misc/sensor
- Mi8937: pepito: export the partner marker receiver
- Mi8937: pepito: take the wallpaper partner slot from Backgrounds
- Mi8937: pepito: add a wallpaper partner customization APK

### device/mithorium-common (since pepito-23.2-r1)
- init: create /data/misc/sensor for BHy calibration profiles

### frameworks/base (since pepito-23.2-r1)
- SystemUI: show battery state on the lock screen indication

### LineageParts (since pepito-23.2-r1)
- GoTweaks: PepitoLauncher2 out of preview + add release-page link

### PepitoLauncher2 (since pepito-23.2-r1)
- Let the back button exit manage mode
- Warm the icon cache off the main thread after reload
- Keep the aux drawer's last row clear of the navigation bar
- Glide displaced icons to their new cell during manage-mode drags
- Animate the manage-mode transition
- Always leave empty drop slots in the frequent tray during manage mode
- Fix cross-section drags landing one slot short

### landing (docs/scripts)
- (first tagged in 20260728 — no prior anchor)
