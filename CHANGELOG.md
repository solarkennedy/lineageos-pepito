# Changelog — LineageOS 23.2 for pepito (Palm PVG100)

## 20260731 (2026-07-31)

### device/Mi8937 (since pepito-23.2-20260729)
- Mi8937: ship pepito's real /persist dir via BOARD_ROOT_EXTRA_FOLDERS
- Mi8937: bake the Google app into the gapps build as default assistant
- Mi8937: ship OpenEUICC on pepito for the removable eUICC card
- Mi8937: measure pepito radio idle and scanning power

### device/mithorium-common (since pepito-23.2-20260729)
- BoardConfigCommon: correct the stale BOARD_ROOT_EXTRA_SYMLINKS comment
- boot-signing: drop the cryptography dependency (stdlib only)
- Make sign-boot-graft.py use fully python path
- boot: graft the fail-open signature onto boot.img + recovery.img at build time

### landing (docs/scripts) (since pepito-23.2-20260729)
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
