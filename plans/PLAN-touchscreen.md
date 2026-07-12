# Touchscreen Bring-up Plan — Pepito (FocalTech FT8613 @ i2c_3)

> **2026-06-23 boot status:** device boot was restored after two regressions
> (RPMB device-node type — kernel; GPU CP microcode — vendor blob); `sys.boot_completed=1`
> again, so this subsystem is testable again. SELinux is still Permissive (bring-up
> diagnostic). Details: `PLAN.md`, `PLAN-gatekeeper.md`, `PLAN-surfaceflinger.md`,
> `PLAN-userspace.md`.

## Hardware

- **Device:** Palm PVG100 (pepito), MSM8940 + PMI8950
- **Controller:** FocalTech FT8613 (in-cell/IDC), I2C address 0x38, BLSP1 QUP3 (i2c_3, 0x78b7000)
- **Chip confirmed:** FT8613 — registers 0xA3=0x86, 0x9F=0x13 read via `i2c-tools` in recovery
- **Reset GPIO:** 64 (TLMM GPIO 64 = kernel GPIO 1210), **IRQ GPIO:** 65
- **VDD:** pm8937_l10 (2.8V–3.0V), **VCC_I2C:** pm8937_l6 (1.8V fixed)

### FT8613 Characteristics

- `_FT8613 = 0x8613080C`: IC_SERIALS=0x0C, FLAG_IDC_BIT=1 (in-cell), FLAG_HID_BIT=0
- In-cell means the touch controller is integrated with the display panel (FT8613 panel)
- Runs its I2C interface off VCC_I2C (L6, 1.8V) alone — responds at 0x38 even without VDD
- Boot ID read uses `FTS_CMD_READ_ID_LEN_INCELL = 1` (1-byte format), not 4-byte standard

## DTS

`arch/arm64/boot/dts/xiaomi-msm8937/pepito/touchscreen.dtsi`

```dts
focaltech_ts@38 {
    compatible = "focaltech,fts_ts-mi8937";
    reg = <0x38>;
    interrupt-parent = <&tlmm>;
    interrupts = <65 0x2>;
    vdd-supply = <&pm8937_l10>;
    vcc_i2c-supply = <&pm8937_l6>;
    pinctrl-names = "pmx_ts_active", "pmx_ts_suspend", "pmx_ts_release";
    pinctrl-0 = <&ts_int_active &ts_reset_active>;
    pinctrl-1 = <&ts_int_suspend &ts_reset_suspend>;
    pinctrl-2 = <&ts_release>;
    focaltech,reset-gpio = <&tlmm 64 0x0>;
    focaltech,irq-gpio = <&tlmm 65 0x2>;
    focaltech,max-touch-number = <5>;
    focaltech,display-coords = <0 0 720 1280>;
    focaltech,ic-type = <0x8613080C>;
    focaltech,ignore-id-check;
};
```

- `focaltech,ic-type = <0x8613080C>`: tells driver this is an IDC chip (uses 1-byte boot ID read, sets is_incell=true, no HID mode)
- `focaltech,ignore-id-check`: skips `FTS_CHIP_TYPE_MAPPING` table lookup; accepts whatever 0xA3/0x9F return
- `pmx_ts_release` (`ts_release` node): defined in `vendor-legacy/qcom/msm8937-pinctrl.dtsi`, GPIO64+65 pulled low; needed by techpack driver to avoid "Pin state[release] not found" error

Pinctrl base states in `vendor-legacy/qcom/msm8937-pinctrl.dtsi` (GPIO64/65).
Pepito overrides in `pepito/pinctrl.dtsi` add `output-high` / `bias-disable` to reset_active.

## Driver Selection

Two copies of the FocalTech driver exist in tree:

| | `drivers/input/touchscreen/focaltech_touch/` | `techpack/xiaomi-msm8937/touchscreen/focaltech_touch/` |
|---|---|---|
| **Kconfig** | `CONFIG_TOUCHSCREEN_FTS` | `CONFIG_TOUCHSCREEN_FTS_MI8937` |
| **Compatible** | `"focaltech,fts_ts"` | `"focaltech,fts_ts-mi8937"` |
| **Chip type** | `_FT3518` (hardcoded) | `focaltech,ic-type` from DTS |
| **FT8613 support** | No (FT3518 only, wrong boot ID format) | Yes (`_FT8613 = 0x8613080C`) |
| **ignore-id-check** | No | Yes (`focaltech,ignore-id-check`) |
| **On probe failure** | Asserts reset GPIO (GPIO64=LOW) | Does NOT assert reset on exit |
| **Status** | **Disabled** | **Active** |

**Resolution:**
- `# CONFIG_TOUCHSCREEN_FTS is not set` (defconfig line 2060)
- `CONFIG_TOUCHSCREEN_FTS_MI8937=y` (defconfig line 5730)

## Build Fixes Applied

### 1. `fts_ts_check_dt` — `of_drm_find_panel` implicit declaration
`fts_ts_check_dt()` in `drivers/` version used `of_drm_find_panel()` which requires `CONFIG_DRM=y`.
Pepito uses legacy MDSS/DSI.

**Fix:** Wrapped function body in `#if defined(CONFIG_DRM) ... #else return 0; #endif`
(`feea29509f59`) — driver is now disabled but guard stays harmless.

The techpack driver already guards its DRM paths correctly with `#if defined(CONFIG_DRM)`.

### 2. Duplicate symbol link errors
Both drivers were linking because `CONFIG_TOUCHSCREEN_FTS_MI8937` was still `y`.

**Fix (initial):** Disabled `CONFIG_TOUCHSCREEN_FTS_MI8937` (`244fdf4e80e4`)
**Fix (current):** Disabled `CONFIG_TOUCHSCREEN_FTS` instead, re-enabled `CONFIG_TOUCHSCREEN_FTS_MI8937`

### 3. FT8613 missing from `FTS_CHIP_TYPE_MAPPING`

The techpack `focaltech_common.h` table only went to IC_SERIALS=0x0A (10 entries).
FT8613 has IC_SERIALS=0x0C — entry was absent.

**Fix:** Added entry to `techpack/.../focaltech_common.h`:
```c
{0x0C, 0x86, 0x13, 0x86, 0x13, 0x86, 0xB3, 0x00, 0x00},
```
This is a fallback for the case where `ignore_id_check` isn't set or the normal-mode read times out and the driver falls back to bootloader detection.

## Probe Failure Root Cause (Resolved)

### What was failing

Driver was compiled for `FTS_CHIP_TYPE = _FT3518`. When the chip (FT8613) was probed:

1. `fts_get_ic_information` succeeded in reading 0xA3/0x9F... wait no — all reads returned 0 (bus errors)
2. Fell through to `fts_read_bootid` which sent 0x55/0xAA then read 4 bytes (non-INCELL format)
3. FT8613 as IDC chip requires 1-byte bootloader read format → bus error → `read:0x0000`
4. Probe aborted with -EIO

### Why i2cdetect showed nothing initially

After probe fails, `drivers/` version calls `fts_power_source_ctrl(DISABLE)` which:
- Sets GPIO64 = LOW (reset asserted) — chip held in reset
- Disables L10

When `i2cdetect -y 3` ran, the chip was in reset → nothing at 0x38.

### Confirming chip is alive

After manually toggling GPIO1210 (TLMM GPIO 64) high:
```sh
echo 1210 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio1210/direction
echo 1 > /sys/class/gpio/gpio1210/value
```

`i2cdetect -y 3` showed 0x38 present. Chip responds to I2C with only VCC_I2C (L6) enabled,
without VDD (L10). This confirms the in-cell controller runs its I2C interface off L6 alone.

Register reads confirmed chip identity:
```sh
i2cget -y 3 0x38 0xA3  # → 0x86
i2cget -y 3 0x38 0x9F  # → 0x13
# → FT8613 confirmed
```

### VDD (L10) timing hypothesis

Enabling L10 during probe powers the display panel's analog supply. The in-cell FT8613
(integrated with the display panel) may then go through an internal power-on reset sequence
longer than 200ms, causing the probe's chip-ID polling window (1 second) to miss it.

This is unconfirmed — the `focaltech,ignore-id-check` path in the techpack driver retries
for 1 second. If L10 causes >1s startup delay, the driver will still fail and we would need
to either: (a) increase `TIMEOUT_READ_REG`, or (b) remove `vdd-supply` and patch the driver
to tolerate a missing VDD for IDC chips.

## Current Status

**WORKING** — confirmed functional in TWRP recovery (2026-06-05).

Techpack driver (`CONFIG_TOUCHSCREEN_FTS_MI8937=y`) probes successfully with:
- `focaltech,ic-type = <0x8613080C>` — IDC chip, correct boot ID format
- `focaltech,ignore-id-check` — accepts whatever chip ID is read
- FT8613 entry added to `FTS_CHIP_TYPE_MAPPING` as fallback
- `pmx_ts_release` pinctrl state added — eliminates "Pin state[release] not found"

Touch events delivered correctly. Multi-touch protocol B in use; per-touch IRQ rate is clean.

## Notes

- `FTS_INFO("no touch point information")` in `focaltech_core.c:2061` downgraded to `FTS_DEBUG` — this fires on every finger-lift (IC sends a 0-touch IRQ after all fingers up, which is normal), and was flooding dmesg. `FTS_DEBUG` is a no-op unless `FTS_DEBUG_EN=1`.

## Commits

| SHA | Description |
|-----|-------------|
| `aa8fd9f6` | arm64: configs: mi8937_defconfig: enable FocalTech FTS touchscreen |
| `feea2950` | input: focaltech_touch: guard DRM panel check behind CONFIG_DRM |
| `244fdf4e` | arm64: configs: mi8937_defconfig: disable techpack FTS duplicate |
| `103960d6` | arm64: dts: pepito: switch touchscreen to FT8613/techpack driver |
| `b69e9463` | input: focaltech_touch/mi8937: add FT8613 to chip type mapping |
| `5034aae1` | arm64: configs: mi8937_defconfig: switch to techpack FocalTech driver |
