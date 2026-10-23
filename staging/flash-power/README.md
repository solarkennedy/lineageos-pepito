# "Flash power" tweak — staged 2026-10-22; VALIDATED on gold 2026-10-22 (local build, unpushed)

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
- kernel `techpack/camera-legacy/sensor/flash/msm_flash.c`: `module_param(flash_cap_ma)`;
  `msm_flash_high()` caps the current it hands to the LED trigger. Preflash/torch
  (`msm_flash_low`) untouched. Applies live.
  ⚠️ The kernel builds THREE copies of msm_flash.c (drivers/media/.../camera_v2, techpack/
  camera-legacy, techpack/camera-legacy-m). `camera_legacy_init()` turns the legacy stack on for
  every Xiaomi msm8937 mach, so on pepito the camera-legacy copy serves the flash ioctls.
  The first cut patched camera_v2: the sysfs param appeared, nothing read it (PLAN-misc §9
  addendum 8). Keep the param in ONE copy only: all three share KBUILD_MODNAME `msm_flash`, so a
  second definition would collide at /sys/module/msm_flash/parameters/flash_cap_ma.

Apply on the builder. The patches are `git diff` output taken from the 24.0 tree that was
validated: kernel `253a9ff4e4d1`, mithorium-common `4dc209b`, LineageParts `174b80df`, i.e. the
20261017 release heads. They `git apply` cleanly there:

    cd ~/android/lineage-24/kernel/xiaomi/msm8937          && git apply .../msm8937.patch
    cd ~/android/lineage-24/device/xiaomi/mithorium-common  && git apply .../mithorium-common.patch
    cd ~/android/lineage-24/packages/apps/LineageParts      && git apply .../LineageParts.patch

Validate after flash (gold reproduces the droop on the first 2 shots after every boot):
1. Settings → PVG100 System Tweaks → Camera → Flash power shows "Full (1000 mA, stock)";
   `getprop persist.gotweak.flash_ma` empty or 0; `cat /sys/module/msm_flash/parameters/flash_cap_ma` = 0.
2. Pick "Low (400 mA)" → the sysfs node reads 400 within a second (no reboot).
3. `diag-tools/flash-probe/flash-trace.sh -s 81eed371 --auto 5` right after a reboot: dmesg shows
   `LED flash_current[0] 1000 capped to 400` + `high_flash_current[0] = 400`, photo EXIF FIRED, meanY well above the 45–52 "clamped" band,
   and the 0xd318 latch reads 0c (no droop) where "Full" read 1c.
4. Back to Full → `high_flash_current[0] = 1000` again. Torch tile and preflash unchanged.
