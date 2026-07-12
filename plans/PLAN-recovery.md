# LineageOS 23.2 — Recovery Boot Issues (pepito/PVG100, MSM8940/Snapdragon 435, 4.19 kernel)

Tracking recovery-specific issues separately from userspace boot. Update after each flash.

---

## Legend
- ✅ Working / confirmed
- 🔧 Fixed, not yet confirmed
- ❌ Known issue, not yet fixed
- ❓ Unknown / needs investigation

---

## Diagnostic note (2026-06-23): recovery root adb is the primary boot-loop tool

Both 2026-06-23 boot-loop regressions (RPMB node type, GPU CP microcode) were
root-caused entirely from **recovery with root adb**, no special tooling:

- `/sys/fs/pstore/{console,pmsg}-ramoops-0` survive the failed boot. **`pmsg-ramoops-0`
  contains the previous boot's userspace logcat**, including the decisive
  `QSEECOMD: ... rpmb_init failed` / `Error finding /dev/block/mmcblk0rpmb` lines.
  Pull these first — they often already contain the answer.
- `mount -o ro /dev/block/by-name/userdata /mnt/userdata-ro` gives read-only access
  to `/data` crash artifacts (dropbox, tombstones, spblob, locksettings). **Watch
  out:** these can be *stale* from an earlier boot (a camera-HAL tombstone here was
  a red herring) — cross-check timestamps against the serial log.
- Capture dir convention used: `debug/recovery-capture-<ts>/{pstore,dropbox,tombstones,...}`.

## Recovery Boot Milestones

| Attempt | Status | Notes |
|---------|--------|-------|
| recovery.1 | ✅ | First successful recovery boot — ADB starts, backlight on |

---

## What Works

- ✅ **Recovery binary starts** — "Starting recovery (pid 373)" at t=32.8s
- ✅ **Cache partition mounts** — `fsck` passes, ext4 mounts cleanly
- ✅ **ADB starts** — `service.adb.root=1` set, `adbd` starts (use this to pull tombstones from userspace boots!)
- ✅ **Backlight on** — "Brightness: 127 (50%)" at t=30.37s
- ✅ **SELinux permissive** — denials logged but not enforced in recovery

---

## Issues

### R-1. Display: DSI pixel clock fails to initialize — screen is blank
**Status:** ❌ Not yet fixed

**Symptom:** Recovery runs correctly but the display shows nothing (backlight on, blank screen). Three cascading kernel warnings:

1. `Trying to switch RCG source while it is prepared!` (in `mdss_dsi_on+0x1f8` and `+0x208`)
   — The RCG (Root Clock Generator) for the DSI pixel clock has its parent being changed while it is already prepared/active. The clock driver refuses and fires a WARN.

2. `pclk0_clk_src: rcg didn't update its configuration.` (in `set_rate_pixel → dsi_link_hs_clk_start`)
   — Pixel clock source register never commits the new rate — hardware stays misconfigured.

3. `timeout (0) enabling timegen on ctl=0` (in `mdss_mdp_video_display`)
   — The MDP timing generator never fires because the DSI pixel clock isn't running — then cascading vsync poll timeouts follow.

**Full call path:**
```
fb_mmap → mdss_fb_mmap → mdss_fb_fbmem_ion_mmap → mdss_fb_blank_unblank
  → mdss_mdp_overlay_on → mdss_mdp_overlay_kickoff → mdss_mdp_display_commit
  → mdss_mdp_video_display → mdss_dsi_on
  → rcg_clk_set_parent [WARN: prepared]
  → dsi_link_hs_clk_start → set_rate_pixel → rcg_update_config [WARN: didn't update]
  → [timegen timeout] → [vsync poll timeouts → poll fallback]
```

**Root cause:** The MSM clock driver (`drivers/clk/msm/clock-local2.c:1547`) requires the RCG to be unprepared before switching its clock parent. The DSI driver tries to switch the pixel clock source (likely from the BIST/test source to the DSI PLL) while the RCG is already enabled. This is a sequencing bug — either:
- The kernel DTS or DSI driver doesn't match the panel's expected clock init order for this specific device (PVG100 panel), or
- The DSI PLL (`dsi_pll0_vco_clk` → `dsi_pll0_pixel_clk_src` → `ext_pclk0_clk_src` → `pclk0_clk_src`) isn't locking before `mdss_dsi_on` tries to use it

**Recovery fallback:** After the vsync timeouts the driver says "fallback to poll mode" — recovery binary still runs, but with no display output.

**Possible fixes to investigate:**
1. Check the panel DTS node in the kernel (`arch/arm64/boot/dts/qcom/`) for the PVG100 panel — verify `qcom,mdss-dsi-pll-type`, `qcom,mdss-dsi-pixel-pll-clk`, and panel timing parameters match the actual panel
2. Look for a display clock sequencing fix: the `mdss_dsi_on` path should unprepare `pclk0_clk_src` before calling `clk_set_parent`, not after
3. Compare against stock Android 8.1 kernel DSI init sequence for this device

**Note:** This is a kernel-level issue, not a userspace or HAL issue. Fix lives in the kernel tree.

---

### R-2. Battery sysfs paths missing in healthd
**Status:** ❓ Likely cosmetic / not blocking

**Symptom:** healthd logs many "not found" messages:
```
BatteryCycleCountPath not found
batteryCapacityLevelPath not found
batteryChargeTimeToFullNowPath not found
batteryFullChargeDesignCapacityUahPath not found
batteryStateOfHealthPath not found
... etc
```

**Root cause:** These are extended battery metrics added in newer Android health HAL versions. The PMIC/fuel gauge driver on MSM8940 (PM8950) doesn't expose these sysfs nodes. Core battery level, voltage, temperature, and charge state do work (`battery l=36 v=3674 t=33.5 h=2 st=2 c=-253599 fc=796000`).

**Impact:** None for functionality. healthd gracefully skips missing paths.

---

### R-3. `libprocessgroup: Failed to find NormalIoPriority process profile`
**Status:** ❓ Minor / cosmetic

**Symptom:** Single log line when adbd starts.

**Root cause:** The process profile for `NormalIoPriority` isn't defined in the cgroup config on this device build. Not blocking.

---

---

### R-4. ADB: USB gadget never bound to UDC — device doesn't enumerate
**Status:** 🔧 Fixed, not yet confirmed

**Symptom:** Phone doesn't appear in `lsusb` despite adbd starting and the USB PHY being active. Kernel shows repeated `read descriptors` / `read strings` (adbd writing FunctionFS) and `msm_otg phy_reset` cycles (host retrying enumeration), but no device ever appears.

**Root cause:** Three conditions must all be true to trigger the `init.rc` action that binds the gadget to the UDC:
```
on property:sys.usb.config=adb && property:sys.usb.ffs.ready=1 && property:sys.usb.configfs=1
    symlink /config/usb_gadget/g1/functions/ffs.adb /config/usb_gadget/g1/configs/b.1/f1
    write /config/usb_gadget/g1/UDC ${sys.usb.controller}
```
`sys.usb.configfs=1` ✅ (set by `init.recovery.qcom.rc`), `sys.usb.ffs.ready=1` ✅ (set by adbd after writing descriptors), but `sys.usb.config` was **never set to `adb`** anywhere in the recovery init files. The gadget has FunctionFS descriptors ready but is never attached to the UDC controller — the host sees USB signaling but the device never enumerates.

**Fix:** Added `setprop sys.usb.config adb` to `init.recovery.qcom.rc` immediately after `setprop sys.usb.configfs 1`, in the `on init` block.

---

## Immediate Actions Enabled by ADB

Now that `adbd` is running in recovery, we can:

1. **Pull userspace boot tombstones** (critical for diagnosing SurfaceFlinger crash):
   ```bash
   adb wait-for-recovery
   adb shell ls /data/tombstones/
   adb pull /data/tombstones/
   ```

2. **Pull logcat from last userspace boot** (if persistent logging is enabled):
   ```bash
   adb shell cat /data/misc/logd/logcat
   # or
   adb shell logcat -L   # "last" buffer
   ```

3. **Check if /data is mounted** (vold may have mounted it before crash):
   ```bash
   adb shell mount | grep data
   ```

4. **Pull system logs from previous boot**:
   ```bash
   adb shell ls /data/misc/
   ```

---

## Next Steps

1. **Connect ADB to recovery** and pull tombstones — use them to diagnose the SurfaceFlinger SIGABRT (see PLAN-userspace.md issue #7)
2. **Investigate DSI clock init sequence** in kernel source for PVG100 panel (issue R-1) — this is a kernel fix, not a userspace fix
3. **Test sideload** — verify `adb sideload` works even without a display (blind operation)
4. Confirm whether the recovery UI is actually rendering (might be visible with right panel, or might need display fix first)
