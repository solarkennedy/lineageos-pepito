# PLAN-bmi160b.md — Accelerometer/Gyro bring-up (Bosch BHI160B hub), pepito/PVG100

**Scope:** get pepito's **accelerometer + gyroscope** working under LineageOS 23.2.
This is a *separate subsystem* from the SSC prox/ALS work — see `PLAN-sensors.md`
for that (RPR0521 prox/light over SSC/SMGR is **DONE**, committed, flash-verified).
This doc is only about the Bosch **BHI160B sensor hub** on the AP Linux I²C bus.

> **Naming note:** the part is the **BHI160B** (a fuser-core hub containing a
> BMI160 IMU die). The file is named `PLAN-bmi160b.md` for grep-findability —
> both names refer to the same chip. §1.5 explains why this distinction matters.

> **Status: ✅ COMPLETE — LIVE DATA VERIFIED 2026-07-05.** 20/20 sensors running with
> events flowing to apps. After the 2026-07-02 registration milestone, data delivery
> required three stacked kernel fixes (full analysis in `PLAN-sensors.md` "Accel/gyro/mag
> — BHy"): `438e117` frame ABI is `{u16 handle; u8 data[20]}` (u8 theory falsified by
> disassembling `sensors.native.so`); `946cdd2` req_fw upload must not wait for a
> post-reset IRQ (BHI160B asserts INT only once firmware runs); `3ff1a97` Palm's firmware
> emits the INITIALIZED meta event on the wake-up channel (0xF8), which the
> Samsung-derived driver didn't match — leaving it stuck in READY, never injecting
> TIMESTAMP_SYNC frames, so the HAL timestamp gate discarded every event.
>
> **Milestone (2026-07-02):** BHy registration operational on `android16-adb`.
> `dumpsys sensorservice` = **20 h/w sensors running**: 4 RPR0521 (prox/ALS via SSC)
> + **16 Bosch sensors via BHy** (accel, gyro, mag, orientation, pressure, gravity,
> linear accel, rotation vector, game RV, significant motion, step detector, step
> counter, geomagnetic RV, PDR, PDR wakeup, activity recognition). The three
> non-obvious fixes required: (1) `input` group added to sensors HAL `.rc` so HAL can
> open `/dev/input/event*`; (2) ueventd rules updated from legacy `soc.0/78b6000.i2c`
> to the 4.19 kernel path `platform/soc/78b6000.i2c`; (3) `sysfs_create_group` +
> `sysfs_create_bin_file(fifo_frame)` added on `data_bus.dev->kobj` in probe — the BST
> HAL looks for attrs at the i2c-dev sysfs path, not the input-device path. SELinux
> policy staged: `sysfs_bhy` type + genfscon + `hal_sensors_default.te`.

---

## 1. What the hardware is (ground-truthed on the live stock device, 2026-06-30)

| Fact | Evidence |
|---|---|
| Accel+gyro = Bosch **BHI160B fuser-core hub**, **not** an SSC/SMGR sensor and **not** a bare BMI160 | Live `android11-adb` (stock 3.18 kernel): `/sys/bus/i2c/devices/2-0028` bound to driver `bhy`, compatible `bst,bhy`, `rom_id`=11693 (0x2DAD) |
| Lives on **AP Linux bus i2c-2, address 0x28** | Stock `init.target.rc` chowns `/sys/.../2-0028/bmi160_foc_*`, `bma2x2_foc_*`, `sensor_conf`, `sensor_sel`; live sysfs confirms the BHy host interface at 2-0028 |
| The hub needs a **RAM-patch firmware** uploaded at runtime before it emits any data | Live stock loads `/vendor/firmware/bhi160b_ram_patch.fw` (24 388 bytes); hub sysfs exposes `req_fw`, `ram_id`, `rom_id` |
| Stock driver compatible = **`bst,bhy`**, IRQ on **TLMM GPIO 61** (rising), 3 supplies | Stock DTB `dts-3.19-pepito/pepito.dts`, node `bhy@28` under `i2c@78b6000` (= i2c-2) |
| Android HAL = **`sensors.native.so`** (BST BHy native HAL `1.3.x`) + a `/vendor/etc/bhy` config dir | Stock driver_version `1.3.18.0`; live stock has `/vendor/etc/bhy`; blob staged (see §6) |
| The same bus also carries **`wusb3801x@60`** = discrete USB-C CC controller | Stock DTB + live `2-0060`; disabling i2c_2 also breaks USB-C orientation (separate latent bug) |

**Stock `bhy@28` node (verbatim, phandles resolved):**
```dts
/* under i2c@78b6000 == &i2c_2 */
bhy@28 {
    compatible       = "bst,bhy";
    reg              = <0x28>;
    interrupt-parent = <&tlmm>;          /* 0xa7 = pinctrl@1000000 (TLMM) */
    interrupts       = <61 0x1>;          /* GPIO 61, IRQ_TYPE_EDGE_RISING */
    bhy,gpio_irq     = <&tlmm 61 0>;
    bhy,vdd_i2c-supply  = <&pm8937_l5>;   /* 0xb6 = regulator-l5  */
    bhy,vdd_1p8-supply  = <&pm8937_l6>;   /* 0xc9 = regulator-l6  */
    bhy,vdd_2p85-supply = <&pm8937_l10>;  /* 0xca = regulator-l10 */
};
```
(`pm8937_l5/l6/l10` all exist as labels in our 4.19 tree — confirmed in
`vendor-legacy/qcom/msm8937-cdp.dtsi`. `&tlmm` is the msm8937 TLMM label.)

> **Interrupt encoding caveat:** `interrupts = <61 0x1>` uses the stock 3.18
> TLMM interrupt-controller cell layout. The 4.19 `qcom,tlmm`
> `#interrupt-cells` binding may differ — verify against the actual 4.19 TLMM
> driver before flashing. (The raw decompiled stock DTB at line 6064 shows
> `<0x3d 0x01>`, i.e. GPIO 0x3d=61, flag 0x1.)

### 1.5 Why "BHI160B hub" (not "BMI160") matters

The address is the tell: a **bare BMI160 sits at 0x68/0x69**; **0x28 is the BHI160
host interface**. The chip at 0x28 is a *programmable fuser core* — it boots a ROM,
accepts a **RAM-patch firmware** over I²C, then runs Bosch's BSX fusion and exposes
*virtual* sensors (accel, gyro, orientation, etc.) through a FIFO. The `bmi160_foc_*`
and `bma2x2_foc_*` sysfs entries are the IMU **sub-sensors inside the hub**, configured
by hub firmware — not a directly-addressable BMI160 register map.

Implication: **the mainline IIO `bosch,bmi160` driver cannot drive this part.** That
driver speaks the raw BMI160 register map (reads `CHIP_ID == 0xD1` at register 0x00) and
has no firmware loader and no FIFO/virtual-sensor support. Pointed at the BHI160 at 0x28
it fails the chip-ID probe and produces nothing. This is why the old "Milestone 0 / IIO
de-risk" idea has been removed — see §3.

---

## 2. Why it's broken on our build

1. **`&i2c_2` is disabled** in `kernel/.../xiaomi-msm8937/pepito.dts`. The disable was
   based on the incomplete msm-4.9 *fork* DTS which had no kept children on this bus; the
   real stock 3.18 bus has `bhy@28` + `wusb3801x@60`. Disabling it killed the accel/gyro bus.
   - Caveat: the bus was disabled because with **zero children** the 4.19 `i2c-msm-v2`
     driver hung at probe (~7.28 s boot stall). **This concern is real but de-risked by
     ground truth:** `i2c_3` (FTS touch) is already `okay` on our 4.19 and works, so
     `i2c-msm-v2` probes fine *with a child present*, and stock runs i2c-2 with two
     children with no trouble. Re-enabling **with the `bhy@28` child present** is therefore
     the plausible fix — but it is **not proven** and must be boot-tested on a recoverable
     boot. Note the existing i2c-msm-v2 BLSP1_AHB clock TEMP workaround (PLAN.md TEMP table).
2. **No driver, and the source is not available locally.** The Bosch **`bst,bhy`**
   (BHI160) driver is built into the stock 3.18 kernel (confirmed: `strings zImage |
   grep bhy`), but its source was **withheld from the Palm GPL release**: the GPL
   tree at `/home/kyle/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/` has no `bhy`
   source anywhere (`drivers/sensors/` contains only `sensors_class.c` +
   `sensors_ssc.c`) — a GPL gap. It is also absent from the 4.9 fork and from our
   4.19 tree. The 4.19 tree has only the mainline IIO `bmi160` driver
   (`drivers/iio/imu/bmi160/`, `CONFIG_BMI160_I2C` not set), which is the **wrong
   stack** for a BHI160 hub (§1.5). So a driver must be **sourced externally** — this
   is the gating task (§3, step 1).
3. **HAL not wired.** Our `hals.conf` lists only the SSC HAL; `sensors.native.so` (the BST
   BHy native HAL) is staged but not added, and the hub config / firmware aren't placed.

---

## 3. Recommended sequencing

There is **one viable path** (the stock `bst,bhy` driver + `bhi160b_ram_patch.fw` +
`sensors.native.so`). The former "Milestone 0 / mainline-IIO de-risk" and "Path B / IIO+shim"
have been **deleted** — the part is a BHI160 hub, the IIO `bosch,bmi160` driver cannot probe
it, and that step would only produce a misleading "bus/power is broken" false negative (§1.5).

### Step 1 — Source a BHI160(B) `bst,bhy` driver (GATING TASK, do this first)

The driver is the project risk. Before touching DTS or defconfig, find a portable copy:
- The Palm GPL tree at `/home/kyle/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/`
  was checked and does **NOT** contain the driver — Palm withheld the source (a GPL
  gap; confirmed: `drivers/sensors/` has only `sensors_class.c` + `sensors_ssc.c`).
- Bosch's published **`bhi160`/`bhy`** Android sensor-hub driver (BMM/BHI vendor
  releases).
- Another LineageOS/CAF device kernel that ships `bst,bhy` for a BHI160 (search
  msm8937 / msm8953 family device kernels — these hubs were common on 2017–2018
  Qualcomm phones).
- Match the host-interface generation to `rom_id` 0x2DAD / firmware
  `bhi160b_ram_patch.fw`.

If no portable driver exists, the effort changes shape (e.g. writing a minimal hub
driver from the Bosch BHI160 datasheet + host-interface spec) — decide that here,
not after a flash.

### Step 2 — Forward-port the driver to 4.19

- Adapt to the 4.19 i2c/regulator/gpio/irq APIs.
- Add Kconfig + Makefile; enable in `arch/arm64/configs/mi8937_defconfig`.
- Keep the firmware-request name aligned with the staged asset (`bhi160b_ram_patch.fw`).

### Step 3 — Re-enable the bus + add the node, boot-test on a recoverable boot

Switch `&i2c_2` to `okay` and add the stock `bhy@28` node (verbatim form in §1):
```dts
&i2c_2 {
    status = "okay";
    bhy@28 {
        compatible       = "bst,bhy";
        reg              = <0x28>;
        interrupt-parent = <&tlmm>;
        interrupts       = <61 0x1>;
        bhy,gpio_irq     = <&tlmm 61 0>;
        bhy,vdd_i2c-supply  = <&pm8937_l5>;
        bhy,vdd_1p8-supply  = <&pm8937_l6>;
        bhy,vdd_2p85-supply = <&pm8937_l10>;
    };
};
```
**Accept this stage when:** device boots past ~7.28 s (no i2c_2 hang); `2-0028` appears
and is bound to driver `bhy`; the driver requests `bhi160b_ram_patch.fw` (watch dmesg /
`/sys/.../firmware`). If the bus still hangs → it's a controller/clock issue, fix it here
before the HAL.

### Step 4 — Add SELinux labels + sysfs permissions

The stock `init.target.rc` chowns ~35 sysfs nodes under
`/sys/class/i2c-dev/i2c-2/device/2-0028/` (e.g. `bmi160_foc_*`, `bma2x2_foc_*`,
`sensor_conf`, `sensor_sel`, `fifo_frame`, `op_mode`, `working_mode`, `ram_id`, …).
Without matching SELinux labels and `.rc` chown lines, the HAL cannot read/write
these nodes under Android 16 enforcing mode.

- Add `sysfs_bhy` type + `file_contexts` entries for `/sys/class/i2c-dev/i2c-2/device/2-0028(/.*)?`
  in **`device/xiaomi/Mi8937/sepolicy/vendor/`** (per the project scoping rule —
  do NOT edit AOSP `system/sepolicy/`).
- Grant `sensorsnative` (or the multihal sub-HAL context) `rw_file_perms` to `sysfs_bhy`.
- Port the stock `chown system system /sys/.../2-0028/*` lines into
  `device/xiaomi/Mi8937/rootdir/etc/init.xiaomi.device.rc`.

### Step 5 — Stage firmware + config + HAL

- Place `bhi160b_ram_patch.fw` in `/vendor/firmware/` and the `/vendor/etc/bhy` config dir
  (both staged in the stock backup — §6).
- Add `sensors.native.so` to the multihal `hals.conf` alongside the SSC HAL.
- **ABI risk (Cluster C):** `sensors.native.so` is a stock Palm **8.1** native HAL blob
  running under Android 16 on the 4.19 kernel. It loads via the legacy `hw_get_module`
  multihal sub-HAL path; verify it links and that the multihal wrapper accepts it. If the
  blob is unusable, fall back to driving the hub from the kernel sysfs FIFO via a thin
  custom sub-HAL (real work — scope only if the blob fails).

**Accept the subsystem when:** `dumpsys sensorservice` lists accelerometer + gyroscope and
values change with orientation (§7).

---

## 4. Test procedure / safety

- **Re-enabling `&i2c_2` can hang boot** (the documented zero-child `i2c-msm-v2` stall;
  de-risked but unproven — §2.1). Always flash to a boot you can recover: capture
  `pstore`/`ramoops` (`/sys/fs/pstore/`, recovery-root `pmsg-ramoops`) and have EDL ready.
  Do NOT flash blind onto a device in use.
- Verify boot reaches `sys.boot_completed=1` and check the i2c_2 probe in dmesg
  (`i2c-msm-v2 78b6000`) and that `bhy` bound at `2-0028` before assuming success.
- Accel acceptance: `dumpsys sensorservice` lists an accelerometer (+ gyro), and a test app
  shows values changing with orientation.

---

## 5. Open questions / side effects

- **`android8-adb` is the authoritative runtime witness (confirmed 2026-07-02).** On
  true stock 8.1, the BHy hub is **fully operational**: `dumpsys sensorservice` lists
  **22 h/w sensors running** — 6 RPR0521 prox/ALS via SSC + **16 Bosch sensors** via
  BHy (accelerometer, magnetometer, gyroscope, pressure, orientation, gravity, linear
  accel, rotation vector, game rotation vector, significant motion, step detector,
  step counter, geomagnetic rotation vector, PDR ×2, activity recognition). The kernel
  `bhy` driver's workqueue `[bhy_wq]` is live (pid 258). Use `android8-adb` for all
  runtime behavior questions (daemon topology, HAL load order, sensor list, configs).
- **`android11-adb` is NOT a runtime witness for sensors.** Its A11 GSI never loads
  the BHy hub firmware (`ram_id` = 0, `dumpsys sensorservice` = 0 sensors,
  `sensors.qcom` crash-loops with SELinux denials). It confirms the *hardware layer*
  only: bus enabled, chip at 0x28, driver `bhy` bound, `rom_id`=0x2DAD. Earlier
  drafts of this plan assumed `android11-adb` showed correct runtime behavior — that
  was wrong, and the "no positive evidence the accel/gyro has ever worked" caution
  is now **retracted**: the subsystem works end-to-end on true stock.
- **Magnetometer: CONFIRMED present (2026-07-02).** `android8-adb` lists a `BOSCH
  Magnetometer Sensor` (android.sensor.magnetic_field, maxRate=25 Hz) and a `BOSCH
  Pressure Sensor` (android.sensor.pressure, maxRate=12.5 Hz). The BHI160B hub
  provides full 9-DoF fusion (accel + gyro + mag) plus barometer — more capable than
  the earlier "accel+gyro only" assessment.
- **USB-C CC controller (`wusb3801x@60`):** also on i2c_2 → also dead while the bus is
  disabled. Re-enabling i2c_2 is a prerequisite for fixing USB-C orientation/role too
  (track separately; the `wusb3801` driver state in 4.19 is unverified).

---

## 6. File/reference map

| What | Where |
|---|---|
| i2c_2 disable (to flip) + corrected comment | `kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito.dts` (`&i2c_2`) |
| Stock `bhy@28` + `wusb3801x@60` (authority) | `dts-3.19-pepito/pepito.dts`, node `i2c@78b6000` (`bhy@28` at line ~6060). **Dir is named `3.19` but contains the decompiled stock 3.18 DTB** — the directory name is historical, not a kernel-version claim. |
| Mainline IIO bmi160 driver (WRONG stack — do not use) | `kernel/xiaomi/msm8937/drivers/iio/imu/bmi160/` |
| `bst,bhy` driver source | **NOT in Palm GPL tree** (`/home/kyle/Projects/Pepito_GPL_SourceCode` — withheld, a GPL gap), NOT in 4.9 fork, NOT in 4.19 tree — must be sourced externally (§3 step 1) |
| Kernel config | `kernel/xiaomi/msm8937/arch/arm64/configs/mi8937_defconfig` |
| hals.conf (base, committed) | `device/xiaomi/mithorium-common/configs/sensors/hals.conf` |
| Hub RAM-patch firmware (staged) | `backup-stock-android-8.1-AML0/vendor.bin.extracted/firmware/bhi160b_ram_patch.fw` |
| Hub config dir (staged) | `backup-stock-android-8.1-AML0/vendor.bin.extracted/etc/bhy` |
| `sensors.native.so` (BST HAL blob, staged) | `backup-stock-android-8.1-AML0/vendor.bin.extracted/lib{,64}/sensors.native.so`; also `vendor/xiaomi/Mi8937/proprietary/vendor/lib64/sensors.native.so` |
| Stock FOC/sysfs init refs | `backup-stock-android-8.1-AML0/vendor.bin.extracted/etc/init/hw/init.target.rc` |
| Runtime reference (true stock) | `android8-adb` — `dumpsys sensorservice` (22 sensors), `ps \| grep bhy` (`[bhy_wq]` thread) |
| Hardware reference (A11 GSI, root) | `android11-adb` — `/sys/bus/i2c/devices/2-0028/` (sysfs, `rom_id`, `driver_version`) |
| Prox/ALS (done) context | `PLAN-sensors.md` |

## 7. Acceptance criteria
- [x] A portable `bst,bhy` (BHI160B) driver is sourced externally and integrated:
      `drivers/misc/bhy/{bhy_core.c,bhy_i2c.c,bstclass.c,bhy_core.h,...}`,
      `CONFIG_SENSORS_BHY=y`, parent `drivers/misc/` hooked in.
      Samsung `sensors_register`/`sensors_unregister` stubs added (`bhy_core.c:7304`).
- [x] `&i2c_2` re-enabled with `bhy@28` child in `pepito.dts`.
- [x] `bhi160b_ram_patch.fw` staged at `vendor/xiaomi/Mi8937/proprietary/vendor/firmware/`
      + PRODUCT_COPY_FILES in `Mi8937-vendor.mk`.
- [x] `/vendor/etc/bhy/{config.ini,pdr_temp.ini}` staged + PRODUCT_COPY_FILES.
- [x] `sensors.native.so` (64-bit + 32-bit) staged in vendor tree; Android.bp `compile_multilib: "both"`.
- [x] Pepito-specific `device/xiaomi/Mi8937/configs/sensors/hals.conf` = ssc+native, overrides mithorium base via PRODUCT_COPY_FILES in `device.mk`.
- [x] **Build + flash**: kernel compiles, boots cleanly (no ~7.28 s i2c_2 hang), `2-0028` appears + bound to driver `bhy`. **DONE 2026-07-02**
- [x] Driver loads `bhi160b_ram_patch.fw`; `ram_id` non-zero (`ram_id = 11696`). **DONE 2026-07-02**
- [x] SELinux `sysfs_bhy` labels staged: `file.te` type + `genfs_contexts` + `hal_sensors_default.te`; device remains Permissive. **STAGED 2026-07-02**
- [x] `sensors.native.so` links + initializes under Android 15 (multihal loads sub-HAL, open_sensors() succeeds). **DONE 2026-07-02**
- [x] `dumpsys sensorservice` shows 20 h/w sensors: 4 RPR0521 + 16 Bosch (accel, gyro, mag, pressure, orientation, gravity, linear accel, rotation vector, game RV, geomagnetic RV, significant motion, step detector, step counter, PDR ×2, activity recognition). **DONE 2026-07-02**
- [x] `PLAN-sensors.md` + `MEMORY.md` updated; PLAN.md sensors row flipped. **DONE 2026-07-02**
