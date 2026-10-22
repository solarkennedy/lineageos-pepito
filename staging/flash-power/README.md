# "Flash power" tweak — staged 2026-10-22, UNBUILT

User-selectable cap on the camera's main strobe current, as a row in PVG100 System Tweaks
(Camera → Flash power: Full 1000 mA / Reduced 700 mA / Low 400 mA, default Full). Nobody is
clamped unless they pick it. Background: PLAN-misc.md §9 addendum 6 — on a worn cell the
1 A strobe + system load sags VPH below the PMI8950's 3.0 V droop threshold and the PMIC
drops the LED to 200 mA; the flash visibly fires, the photo is dim. Lower strobe = no droop.

Plumbing (same shape as the other gotweaks rows):
- `persist.gotweak.flash_ma` (0 = no cap) — written by the Settings row (system_app already
  has set_prop on gotweak_prop).
- `init.gotweaks.rc`: `on property:persist.gotweak.flash_ma=*` writes
  `/sys/module/msm_flash/parameters/flash_cap_ma` (vendor_init may write any sysfs_type file
  per base policy; comment added to gotweaks.te, no new grant).
- kernel `msm_flash.c`: `module_param(flash_cap_ma)`; `msm_flash_high()` caps the current it
  hands to the LED trigger. Preflash/torch (`msm_flash_low`) untouched. Applies live.

Apply on the builder (patches are plain `diff -u` with a/ b/ prefixes, made against the
23.2-era local checkouts; they `git apply --check` cleanly there — on the 24.0 branches
expect at most context drift in GoTweaksSettings.java, the hunks are self-contained):

    cd ~/android/lineage-24/kernel/xiaomi/msm8937          && git apply -3 .../msm8937.patch
    cd ~/android/lineage-24/device/xiaomi/mithorium-common  && git apply -3 .../mithorium-common.patch
    cd ~/android/lineage-24/packages/apps/LineageParts      && git apply -3 .../LineageParts.patch

Validate after flash (gold reproduces the droop on the first 2 shots after every boot):
1. Settings → PVG100 System Tweaks → Camera → Flash power shows "Full (1000 mA, stock)";
   `getprop persist.gotweak.flash_ma` empty or 0; `cat /sys/module/msm_flash/parameters/flash_cap_ma` = 0.
2. Pick "Low (400 mA)" → the sysfs node reads 400 within a second (no reboot).
3. `diag-tools/flash-probe/flash-trace.sh -s 81eed371 --auto 5` right after a reboot: dmesg shows
   `high_flash_current[0] = 400`, photo EXIF FIRED, meanY well above the 45–52 "clamped" band,
   and the 0xd318 latch reads 0c (no droop) where "Full" read 1c.
4. Back to Full → `high_flash_current[0] = 1000` again. Torch tile and preflash unchanged.
