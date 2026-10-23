# Changelog — LineageOS 24.0 for pepito (Palm PVG100)

## 20261017 (2026-10-17)

### device/Mi8937 (since pepito-24.0-20261011)
- WfcBridge: receive CARRIER_CONFIG_CHANGED (RECEIVER_EXPORTED)
- Mi8937: Wi-Fi preferred — gate on validated Wi-Fi, fix prime length, TH2 cache
- modem_b12: no restart prompt when the modem is back where it booted
- modem_b12: wait for the modem to serve NV before judging the unit
- Mi8937: honour Wi-Fi calling "Wi-Fi preferred" while LTE is up
- Mi8937: LTE Band 12 switch (modem_b12)
- Mi8937: every OTA writes the boot logo
- WfcBridge: call the app PVG100 WFC Bridge
- Mi8937: boot animation that continues from the PALM splash logo
- qmux: publish the WLAN feeder status to a public prop for Modem tweaks
- qmux: ims_enabler probes IDL minors up to 512 so the NAS phase can connect
- qmux: run the VoWiFi feeder for the whole boot so stale WLAN always clears
- qmux: ims_enabler asserts NAS usage_preference from the Modem tweaks switch

### device/mithorium-common (since pepito-24.0-20261011)
- mithorium-common: show the Wi-Fi calling preference row on Verizon
- mithorium-common: persist.gotweak.mglru kill switch for the multi-gen LRU
- mithorium-common: lmkd swap accounting for zram and no watermark-only cached kills

### kernel (msm8937) (since pepito-24.0-20261011)
- BACKPORT: mm: multi-gen LRU: retry pages written back while isolated
- BACKPORT: Multi-gen LRU: fix workingset accounting
- BACKPORT: Multi-gen LRU: fix per-zone reclaim, skip ineligible CMA pages
- BACKPORT: mm: multi-gen LRU: fix crash during cgroup migration
- BACKPORT: mm/mglru: don't sync disk for each aging cycle
- mm: multi-gen LRU: use xa_load() for the swap-cache shadow lookup
- mm: multi-gen LRU: drop the lru_gen_use_mm() list_empty warning
- proc: process_reclaim: skip unevictable pages before isolating them
- mm: multi-gen LRU: xa_is_value() for the swap-cache shadow in do_swap_page()
- mi8937_defconfig: enable the multi-gen LRU
- mm: multi-gen LRU: use shrink_page_list()'s force_reclaim for the reference check
- FROMLIST: mm: multi-gen LRU: design doc
- FROMLIST: mm: multi-gen LRU: admin guide
- FROMLIST: mm: multi-gen LRU: debugfs interface
- FROMLIST: mm: multi-gen LRU: thrashing prevention
- FROMLIST: mm: multi-gen LRU: kill switch
- FROMLIST: mm: multi-gen LRU: optimize multiple memcgs
- FROMLIST: mm: multi-gen LRU: support page table walks
- FROMLIST: mm: multi-gen LRU: exploit locality in rmap
- FROMLIST: mm: multi-gen LRU: minimal implementation
- FROMLIST: mm: multi-gen LRU: groundwork
- BACKPORT: mm/swapcache: support to handle the shadow entries
- mm: Convert delete_from_swap_cache to XArray
- mm: Convert add_to_swap_cache to XArray
- UPSTREAM: arm64: cpufeature: introduce helper cpu_has_hw_af()
- BACKPORT: mm/lru: introduce TestClearPageLRU()
- FROMLIST: mm: x86: add CONFIG_ARCH_HAS_NONLEAF_PMD_YOUNG
- FROMLIST: mm: x86, arm64: add arch_has_hw_pte_young()
- BACKPORT: include/linux/mm_inline.h: fold page_lru_base_type() into its sole caller
- UPSTREAM: mm: VM_BUG_ON lru page flags
- BACKPORT: mm: add __clear_page_lru_flags() to replace page_off_lru()
- BACKPORT: mm/swap.c: don't pass "enum lru_list" to del_page_from_lru_list()
- BACKPORT: mm: don't pass "enum lru_list" to lru list addition functions
- BACKPORT: include/linux/mm_inline.h: shuffle lru list addition and deletion functions
- BACKPORT: mm/vmscan.c: use add_page_to_lru_list()
- BACKPORT: mm: use self-explanatory macros rather than "2"
- UPSTREAM: mm/vmscan.c: use update_lru_size() in update_lru_sizes()
- msm: mdss: idle-wait in the DSI event and display threads
- bpf: do not kmem-charge pages that are mmap()ed to user space (4.19)
- mm: userfaultfd: commit the memcg charge before the page goes on the LRU

### lineage-sdk (since pepito-24.0-20261011)
- profiles: tag Bluetooth calls so A17 system_server accepts them

### LineageParts (since pepito-24.0-20261011)
- LineageParts: shorter Band 12 summary; escape the quotes in its dialog
- LineageParts: LTE Band 12 switch in PVG100 Modem Tweaks
- LineageParts: credit Palm in the Life Mode summary
- LineageParts: plainer PVG100 Modem Tweaks summary
- LineageParts: pin Life Mode ahead of the PVG100 tweaks pages
- LineageParts: GoTweaks row for the multi-generation LRU (persist.gotweak.mglru)
- LineageParts: name the tweaks pages PVG100 and keep them together
- LineageParts: add live modem status rows to Modem tweaks
- Modem tweaks: a settings section for the modem levers the port asserts
- Pepito Tweaks: emergency-only watchdog recovery toggles

### Updater (since pepito-24.0-20261011)
- Updater: don't nest a scroller in the action dialog's text

### landing (docs/scripts) (since pepito-24.0-20261011)
- plans: WFC Wi-Fi preferred re-run on the 16:18 build; screen-off Wi-Fi does not reconnect (no PNO)
- tests/integration: pytest suite against a bench unit, starting with Wi-Fi calling
- PLAN-android17: matched dut1/Gold A17 power cells — no regression on the wired cells
- plans: WFC Wi-Fi preferred full pass on new2 with the boot-mirror fix
- plans: WFC re-validation on 55a9fbf6; boot-mirror bug fixed in b82254d8
- PLAN-android17: WFC Wi-Fi preferred review fixes pushed; WAN-pull added to validation
- PLAN-android17: A17 power regression check, CT-3 wired cells on dut1
- plans: WFC Wi-Fi preferred validated on new2 (hold + walk-away)
- PLAN-android17: B12 switch toggle test through Settings; boot-race and restart-prompt fixes
- plans: WFC Wi-Fi preferred committed (Mi8937 6bc3da68, mithorium-common 4dc209b)
- PLAN-android17: B12 Modem Tweaks switch built and pushed (Mi8937 db3b9f85, LineageParts be6269cd)
- PLAN-android17: B12 data result void — dut1's SIM is not activated; control plane works
- PLAN-android17: B12 camp test — attaches on EARFCN 5035 but no user data; dut1 reverted
- PLAN-android17: B12 enabled on dut1 from the seven-band unit's tunning cal items
- build-lineage24-remotely: fetch splash.bin with the other staged images
- PLAN-android17: boot logo plumbing pushed, check list for the next build
- Ship the boot logo with every install: OTA, EDL kit and web flasher
- tools/splash: render-bootanimation.py; PLAN-android17: boot logo design
- plans: 10-15 bench results — Modem tweaks data-centric switch, B12 parked, WFC Wi-Fi preference
- tools/splash: make-bootanimation.py, a boot animation that continues from the logo
- prepare-flash: a foreign /data boot-loops, it is not auto-formatted
- remotely scripts: rsync -z with --partial-dir, never a truncated image
- MGLRU lane: plan, bench harness and results through the 20261016 release
- esim: MCFG/PDC write path tested on dut1 -> CLOSED (mcfg_sw sig enforced)
- esim: reopen lane on the MCFG/PDC write path; add mcfg_sw.mbn patcher
- tools/splash: read the splash partition and replace the boot logo
- flash-staging: target units from the roster, pin adb/EDL to the serial
- flasher: advanced Back up / Flash tabs and a Partitions reference
- flasher: Back up / Flash / Restore tabs, partial restore, .img images
- AGENTS: bench phones can be unlocked at will with android-unlock-<nick>
- PLAN-android17: next-release gate = emergency-only fix; 23.2 closed at 20261013
- plans: list_del panic lane — root cause, fix, close (10-12 → 10-14)
- release-all: point at the 24.0 XDA thread and remind to update it
## 20261011 (2026-10-12)

### device/Mi8937
- (first tagged in 20261011 — no prior anchor)

### device/mithorium-common
- (first tagged in 20261011 — no prior anchor)

### kernel (msm8937)
- (first tagged in 20261011 — no prior anchor)

### frameworks/base
- (first tagged in 20261011 — no prior anchor)

### frameworks/native
- (first tagged in 20261011 — no prior anchor)

### frameworks/opt/telephony
- (first tagged in 20261011 — no prior anchor)

### vendor/lineage
- (first tagged in 20261011 — no prior anchor)

### lineage-sdk
- (first tagged in 20261011 — no prior anchor)

### LineageParts
- (first tagged in 20261011 — no prior anchor)

### Launcher3
- (first tagged in 20261011 — no prior anchor)

### recovery
- (first tagged in 20261011 — no prior anchor)

### Updater
- (first tagged in 20261011 — no prior anchor)

### hardware/interfaces
- (first tagged in 20261011 — no prior anchor)

### hardware/lineage/interfaces
- (first tagged in 20261011 — no prior anchor)

### system/bpfprogs
- (first tagged in 20261011 — no prior anchor)

### build/make
- (first tagged in 20261011 — no prior anchor)

### system/sepolicy
- (first tagged in 20261011 — no prior anchor)

### system/fs/fs_mgr
- (first tagged in 20261011 — no prior anchor)

### hardware/qcom-caf/bt
- (first tagged in 20261011 — no prior anchor)

### vendor/xiaomi (blobs)
- (first tagged in 20261011 — no prior anchor)

### PepitoLauncher2
- (first tagged in 20261011 — no prior anchor)

### landing (docs/scripts)
- (first tagged in 20261011 — no prior anchor)
## 20260921 (2026-09-21)

### kernel (msm8937) (since pepito-23.2-20260915)
- misc: bhy: stop the MCU monitor from racing system suspend

### device/Mi8937 (since pepito-23.2-20260915)
- Mi8937: bhy-wrapper: Q14 quaternion resolution; note the dead hals.conf
- Mi8937: wrap the BHy HAL to fix its advertised range/resolution
- Mi8937: create the BHy calibration dir from a system_ext rc
- Mi8937: point the Updater's "Show changelog" at the pepito changelog

### device/mithorium-common (since pepito-23.2-20260915)
- XiaomiParts: add emergency-only recovery watchdog (experimental, off)
- mithorium-common: load the BHy HAL through its pepito wrapper
- mithorium-common: drop the BHy calibration mkdir from init.target.rc
- thermal: pepito skin config - SEVERE at 60 C, not the Xiaomi 50 C
- thermal: arm trip_point_0 when a zone has no trip_point_1

### LineageParts (since pepito-23.2-20260915)
- GoTweaks: add emergency-only recovery toggle (experimental, off)

### Updater
- (first tagged in 20260921 — no prior anchor)

### landing (docs/scripts) (since pepito-23.2-20260915)
- changelog: 20260921
- ota: 20260921 vanilla
- changelog: 20260921
- plans/docs: emergency-only + watchdog + BHy poll-mode lanes, microG add-on
- fh_dump.py: Apache-2.0, drop the contributor note
- docs: backup + flashing on Linux, macOS and Windows; bundle fh_dump.py
- docs: flashing from Windows, and the boot-loop way into recovery
- ota: embed each release's changelog in pepito.json for the Updater
## 20260915 (2026-09-15)

### kernel (msm8937) (since pepito-23.2-20260910)
- misc: bhy: detect a param-ack wedge and keep the reset monitor armed

### device/Mi8937 (since pepito-23.2-20260910)
- Mi8937: hide the "Use SIM" switch on pepito
- Mi8937: reconcile the IMS MSISDN with the network, not just its shape

### device/mithorium-common (since pepito-23.2-20260910)
- mithorium-common: move the battery wear profile into Settings > Battery
- XiaomiParts: open Life Mode settings on a tile long-press

### frameworks/opt/telephony
- (first tagged in 20260915 — no prior anchor)

### LineageParts (since pepito-23.2-20260910)
- LineageParts: draw Pepito Tweaks a custom icon
- LineageParts: give Life Mode its own settings section

### landing (docs/scripts) (since pepito-23.2-20260910)
- changelog: 20260915
- SIM toggle trap: root cause, hidden-switch mitigation, new opt/telephony fork
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
