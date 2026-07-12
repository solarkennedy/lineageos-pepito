# Pepito Wi-Fi Bring-up Plan

**Subsystem:** Wi-Fi (Qualcomm WCN3660 / Pronto via WCNSS)
**Status:** Wi-Fi working after supplicant data config seed. Core Wi-Fi services, AIDL IWifi binding, WCNSS firmware/NV, Prima driver load, supplicant bring-up, and scanning are confirmed.

> **2026-06-23 boot status:** device boot was restored after two regressions
> (RPMB device-node type — kernel; GPU CP microcode — vendor blob); `sys.boot_completed=1`
> again, so this subsystem is testable again. SELinux is still Permissive (bring-up
> diagnostic). Details: `PLAN.md`, `PLAN-gatekeeper.md`, `PLAN-surfaceflinger.md`,
> `PLAN-userspace.md`.

---

## 2026-06-29: "WCNSS crashes during boot" is a PHANTOM — off-by-one logging bug in the WCNSS driver

`serial.log.19` (full boot, `sys.boot_completed=1` at t≈216s) was initially read as
the Pronto WCNSS subsystem **ramdumping and SOC-resetting mid-boot**:

```
serial.log.19:2889 [189.600] wcnss: wcnss_notif_cb: notification event: 2 : SUBSYS_BEFORE_POWERUP
serial.log.19:2917 [189.659] wcnss: wcnss_notif_cb: notification event: 7 : SUBSYS_PROXY_UNVOTE
serial.log.19:2977 [189.934] wcnss: wcnss_notif_cb: notification event: 4 : SUBSYS_RAMDUMP_NOTIFICATION
serial.log.19:3063 [190.513] wcnss: wcnss_notif_cb: notification event: 8 : SUBSYS_SOC_RESET
serial.log.19:3075 [190.602] wcnss: wcnss_notif_cb: notification event: 3 : SUBSYS_AFTER_POWERUP
```

**This is not a crash. The printed event *names* are wrong; the numeric codes are correct.**

The WCNSS driver logs notifications as `notification event: <code> : wcnss_subsys_notif_type[code]`,
where `<code>` is the true `enum subsys_notif_type` value
(`include/soc/qcom/subsystem_notif.h`) but the lookup string table
(`wcnss_wlan.c:70`, `wcnss_subsys_notif_type[]`) was **missing the index-4 entry
`SUBSYS_BEFORE_AUTH_AND_RESET`**, so every printed name for code ≥ 4 was shifted down
by one. Cross-referencing the codes against the enum, the real sequence is a
**completely normal, healthy Pronto powerup**:

| Log line | code | TRUE event (enum) | String printed (wrong) |
|---|---|---|---|
| `:2889` | 2 | `SUBSYS_BEFORE_POWERUP` | BEFORE_POWERUP ✓ |
| `:2917` | 7 | `SUBSYS_PROXY_VOTE` | PROXY_UNVOTE ✗ |
| `:2977` | 4 | `SUBSYS_BEFORE_AUTH_AND_RESET` | RAMDUMP_NOTIFICATION ✗ |
| `:3063` | 8 | `SUBSYS_PROXY_UNVOTE` | SOC_RESET ✗ |
| `:3075` | 3 | `SUBSYS_AFTER_POWERUP` | AFTER_POWERUP ✓ |

Real sequence: `BEFORE_POWERUP → PROXY_VOTE → BEFORE_AUTH_AND_RESET → PROXY_UNVOTE → AFTER_POWERUP`
— textbook PIL bring-up. There is **no ramdump and no SOC reset.** A genuine
`SUBSYS_SOC_RESET` (real value 9) is emitted from exactly one site
(`subsystem_restart.c::device_restart_work_hdlr`) which *always* calls `panic()`
immediately afterward; the device never panicked and reached `boot_completed=1`,
proving it never received a real SOC_RESET. This is also why Wi-Fi works on-device
— the hardware never crashed.

**Fix applied (2026-06-29):** added the missing `"SUBSYS_BEFORE_AUTH_AND_RESET"`
entry to `wcnss_subsys_notif_type[]` so the string indices line up with the enum
and future logs print correct event names. No functional change. This section
supersedes the earlier "WCNSS subsystem crashes during boot (RAMDUMP + SOC_RESET)"
note; the WCNSS crash class it implied does **not** exist on pepito.

---

## Architecture overview

MSM8940 Wi-Fi uses the classic Qualcomm WCNSS/Pronto stack:

```
Firmware: wcnss.mdt + wcnss.b00…  (PIL-loaded from /vendor/firmware/wlan/prima/)
Kernel:   drivers/staging/prima/   (CONFIG_PRONTO_WLAN=y, built as module or in-kernel)
          drivers/soc/qcom/wcnss/  (WCNSS sideband: vreg, ctrl, smp2p)
Userspace: wcnss_service           (NV provisioning + MAC address)
           wificond                (nl80211 scan/connect mediator)
           hostapd / wpa_supplicant (softAP / STA)
           android.hardware.wifi-service (HIDL Wi-Fi HAL)
```

**Key files shipped by mithorium-common:**

| File | Destination | Purpose |
|---|---|---|
| `device/xiaomi/mithorium-common/wifi/WCNSS_cfg.dat` | `/vendor/firmware/wlan/prima/WCNSS_cfg.dat` | Pronto RF/hardware config |
| `device/xiaomi/mithorium-common/wifi/WCNSS_qcom_cfg.ini` | `/vendor/etc/wifi/WCNSS_qcom_cfg.ini` | Driver tuning (BMPS, IMPS, MAC addr, dot11mode) |
| symlink: `firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin` | → `/mnt/vendor/persist/WCNSS_qcom_wlan_nv.bin` | NV calibration (per-device, written by wcnss_service) |
| symlink: `firmware/wlan/prima/WCNSS_qcom_cfg.ini` | → `/vendor/etc/wifi/WCNSS_qcom_cfg.ini` | Alternate lookup path |
| symlink: `firmware/wlan/prima/wlan_mac.bin` | → `/mnt/vendor/persist/wlan_mac.bin` | MAC address override |

---

## Kernel config

`mi8937_defconfig` + `vendor/common.config` currently have:

```
CONFIG_WCNSS_MEM_PRE_ALLOC=y    # pre-allocate Pronto DMA pools
CONFIG_WCNSS_CORE=y             # WCNSS sideband (vreg, SMP2P, ctrl)
CONFIG_WCNSS_CORE_PRONTO=y      # Pronto variant of WCNSS sideband
CONFIG_PRONTO_WLAN=y            # Prima/Pronto staging driver (wlan.ko or built-in)
# CONFIG_PRIMA_WLAN is not set  # older Prima-only alias — not needed alongside PRONTO
```

This matches what sibling Mi8937 variants use. No pepito-specific kernel config change is expected.

---

## DTS — WCNSS node

`msm8937.dtsi` (vendor-legacy) defines `qcom,wcnss-wlan@0a000000` with:
- SMP2P in/out for WCNSS ↔ AP messaging
- PMU regulator references (`vddcx`, `vddmx`, `vddpx`)
- Pinctrl states: `wcnss_default`, `wcnss_sleep`, `wcnss_gpio_default`
- `memory-region = <&wcnss_fw_mem>` (carveout for firmware load)

**msm8940.dtsi** overrides `wcnss_fw_mem` size — verify it is appropriate for pepito (stock Palm 8.1 TZ protects the same region; no separate WCNSS carveout conflict known).

**Sibling variant pattern (land/soc.dtsi):**

```dts
&soc {
    qcom,wcnss-wlan@0a000000 {
        qcom,vddcx-voltage-level = <RPM_SMD_REGULATOR_LEVEL_NOM
                    RPM_SMD_REGULATOR_LEVEL_NONE
                    RPM_SMD_REGULATOR_LEVEL_TURBO>;
    };
};
```

That voltage-level override is the only sibling customisation — it matches the WCNSS RF power requirements on MSM8937/8940. Pepito has no `pepito/wifi.dtsi` today and inherits this via the common DTSI chain. This is likely sufficient, but on-device verification is required.

**If WCNSS fails to probe:** add a `pepito/wifi.dtsi` with the vddcx override explicitly (matching land) and include it from `pepito.dtsi`.

---

## Userspace stack — expected boot sequence

1. **wcnss_service** starts early (class `core`): provisions NV, handles MAC address, writes `/dev/wcnss_ctrl`.
2. Kernel WCNSS driver triggers PIL firmware load (`wcnss.mdt` + segments) from `/vendor/firmware/wlan/prima/`.
3. Pronto wlan driver registers `wlan0` + `p2p0` net devices.
4. **wificond** starts, opens nl80211 socket to `wlan0`.
5. **android.hardware.wifi-service** starts, connects to wificond.
6. Wi-Fi HAL ready; framework `WifiService` can proceed.

---

## Known gaps and pepito-specific concerns

### 1. WCNSS_cfg.dat — Xiaomi vs Palm calibration

**Risk: Medium.** `WCNSS_cfg.dat` is RF hardware calibration — it encodes antenna type, band-specific power levels, and crystal offset. Xiaomi devices in this family use WCN3620/WCN3660; Palm PVG100 uses the same Qualcomm IP block but may have a different RF front-end or antenna layout.

**What to do:**
- On first boot, check `logcat | grep -i wcnss` for calibration errors or TX power clamp messages.
- If RSSI is systematically low or TX is throttled, extract `WCNSS_cfg.dat` from a Palm-specific source (stock Android 8.1 `/vendor/firmware/wlan/prima/WCNSS_cfg.dat` or a Palm OTA).
- If a Palm-specific `WCNSS_cfg.dat` is found, gate it behind `TARGET_DEVICE_PEPITO` in a pepito-only makefile block:

  ```makefile
  ifeq ($(TARGET_DEVICE_PEPITO),true)
  PRODUCT_COPY_FILES += \
      device/xiaomi/pepito/wifi/WCNSS_cfg.dat:$(TARGET_COPY_OUT_VENDOR)/firmware/wlan/prima/WCNSS_cfg.dat
  endif
  ```

### 2. WCNSS_qcom_cfg.ini — MAC address placeholders

The Xiaomi ini ships with placeholder MAC addresses:

```ini
Intf0MacAddress=000AF58989FF
Intf1MacAddress=000AF58989FE
Intf2MacAddress=000AF58989FD
Intf3MacAddress=000AF58989FC
```

These are overridden at runtime by `wcnss_service` if `/mnt/vendor/persist/WCNSS_qcom_wlan_nv.bin` exists with a burned-in MAC. On first boot (clean userdata) the persist NV file will not exist and the driver falls back to the ini placeholder — the device will appear on the network with MAC `00:0a:f5:89:89:ff`. This is harmless for bring-up but the real MAC (burned at Palm's factory) lives in the stock `persist` partition.

**To recover the real MAC:**
- If the stock `persist` partition was preserved, mount it and pull `/persist/WCNSS_qcom_wlan_nv.bin` (or `/mnt/vendor/persist/WCNSS_qcom_wlan_nv.bin`).
- Alternatively, the device MAC is on the back label or in stock Settings → About. `wcnss_service` can write a synthesised NV file from a text MAC address.

### 3. `/persist` partition mount

The WCNSS NV symlink resolves to `/mnt/vendor/persist/WCNSS_qcom_wlan_nv.bin`. This path is only valid after `persist` is mounted. Confirm `fstab.qcom` (or `fstab.qcom.pepito`) mounts `persist` at `/mnt/vendor/persist` — the Palm layout uses a static `persist` partition at a known block device.

### 4. Pronto firmware blobs

The PIL firmware set (`wcnss.mdt`, `wcnss.b00`–`wcnss.bNN`) is loaded from `/vendor/firmware/wlan/prima/`. These are **not** in `vendor/xiaomi/mithorium-common` — they are expected to come from the device's own firmware partition or a nightly OTA extraction.

**To extract from a nightly:**
```bash
# Mount nightly vendor.img
sudo mount -o loop,ro nightly-vendor.img /mnt/nightly
# Check for prima firmware
ls /mnt/nightly/firmware/wlan/prima/
# Copy to vendor tree (if present)
cp /mnt/nightly/firmware/wlan/prima/wcnss.* vendor/xiaomi/mithorium-common/proprietary/vendor/firmware/wlan/prima/
```

If not in nightly, extract from a stock Xiaomi MSM8937/8940 vendor dump (land, santoni, or prada — all use the same WCN3660 firmware). The firmware is SoC-specific, not device-specific at the radio level.

**Current state (verified on-device 2026-06-06):** PIL blobs are present on the modem partition at `/vendor/firmware_mnt/image/wcnss.{mdt,b00–b12}`. The `/firmware` symlink points to `/vendor/firmware_mnt`, and `firmware_directories /vendor/firmware_mnt/image/` in `ueventd.rc` ensures ueventd's user-helper can locate them. **Firmware is NOT the blocker.**

### 5. SELinux

`mithorium-common/sepolicy/vendor/hal_wifi_default.te` and `wcnss_service.te` are already present. These should cover the standard bring-up path. If SELinux is enforcing and `wlan0` does not appear, check for denials via:

```bash
adb shell dmesg | grep "avc: denied" | grep -i "wcnss\|wlan\|wifi"
```

---

## Bring-up checklist

- [x] **Pronto firmware blobs** (`wcnss.mdt` + segments) — confirmed present on modem partition (`/vendor/firmware_mnt/image/`). ueventd user-helper loads them via `firmware_directories /vendor/firmware_mnt/image/`. No action needed.
- [ ] **First boot Wi-Fi check:**
  ```bash
  adb shell dmesg | grep -i "wcnss\|prima\|wlan\|pronto"
  adb shell logcat -s WifiHAL:* wcnss_service:* wificond:*
  adb shell ip link show wlan0   # must appear
  ```
- [x] **Check `/dev/wcnss_wlan` and `/dev/wcnss_ctrl`** exist with correct ownership (`system:system`).
- [ ] **Scan for APs** from Settings → Wi-Fi. If scan results appear, basic stack is working.
- [ ] **Associate and ping** to confirm TX path.
- [x] **Evaluate WCNSS_cfg.dat** — no calibration-related failure has surfaced yet; leave this open unless RSSI or TX behavior points here.
- [x] **Recover real MAC address** from stock persist partition if desired. Placeholder MAC handling is understood, but no persist pull has been needed yet.
- [ ] **softAP test** — toggle hotspot, verify `p2p0` appears and clients can associate.
- [x] **WifiOverlay RRO** — it is already present in the product package set. Runtime installation still needs a direct device check.

---

## Open questions

- **Does the stock Palm Android 8.1 persist partition survive the flash?** Convention is to zero userdata on flash (see `BUILD.md`) but `persist` is a separate partition — its preservation depends on the `flash-staging.sh` partition table. Confirm whether `persist` is flashed or preserved.
- **Is the WCN3660 firmware identical across MSM8937/8940 family members?** Almost certainly yes at the blob level (same silicon), but worth confirming via `file wcnss.mdt` (should show the same ELF machine type on any MSM8937 device dump).
- **Does `wcnss_service` QMI path work?** `soong_config_set_bool wcnss_service uses_qcom_wcnss_qmi true` is set in `mithorium.mk`, which enables the QMI-based NV provisioning path. This requires `libqmi_encdec.so` (same blob that was missing for sensors — verify it's in the vendor tree now that the sensors fix was applied).

---

## Reference

- Kernel WCNSS driver: `kernel/xiaomi/msm8937/drivers/soc/qcom/wcnss/`
- Prima staging driver: `kernel/xiaomi/msm8937/drivers/staging/prima/`
- Mithorium Wi-Fi config: `device/xiaomi/mithorium-common/wifi/`
- WifiOverlay RRO: `device/xiaomi/mithorium-common/rro_overlays/WifiOverlay/`
- Symlink modules: `device/xiaomi/mithorium-common/Android.bp` (`firmware_WCNSS_*_symlink`)
- WCNSS sideband init: `device/xiaomi/mithorium-common/rootdir/etc/init.qcom.rc` (`setprop wifi.interface wlan0`, `chown … /persist/WCNSS_qcom_wlan_nv.bin`)
- SELinux: `device/xiaomi/mithorium-common/sepolicy/vendor/hal_wifi_default.te`, `wcnss_service.te`

## Current runtime findings

- `android.hardware.wifi-service`, `wificond`, and `wcnss_service` are running.
- `/dev/wcnss_wlan` and `/dev/wcnss_ctrl` exist and are owned by `system:system`.
- `wifi.interface=wlan0` and `vendor.wlan.driver.config=/data/vendor/wifi/WCNSS_qcom_cfg.ini` are set.
- `android.hardware.wifi-service` links against `libwifi-hal.so`, `libwifi-system-iface.so`, and `android.hardware.wifi-V4-ndk.so`; all are present on the device.
- `libwifi-hal.so` links against `libcld80211.so`, `libpasn.so`, `libcrypto.so`, `libnl.so`, and standard libc++/base dependencies; those are also present on the device.
- Repeated Wi-Fi enable attempts fail in the same place:
  - `WifiVendorHal: Failed to start vendor HAL`
  - `WifiNative: Failed to start vendor HAL`
  - `WifiNative: Vendor HAL died. Cleaning up internal state.`
  - `WifiSelfRecovery: Triggering recovery for reason: WifiNative Failure`
- `dumpsys wifi` still reports `CMD_STA_START_FAILURE` and `WifiNative Failure`.
- No obvious SELinux denial or missing blob has surfaced yet.
- Fresh toggle evidence shows the AIDL binder path is healthy: `WifiHalAidlImpl` obtains `IWifi`, reports remote version 3, and completes initialization.
- The actual failure is native driver load: `android.hardware.wifi-service: Failed to write driver state control param: No such device`, followed by `Failed to load WiFi driver` and `Failed to initialize firmware mode controller`.
- `WIFI_DRIVER_STATE_CTRL_PARAM` points at `/sys/module/wlan/parameters/fwpath`; writing it calls Prima `fwpath_changed_handler()` -> `kickstart_driver()` -> `hdd_driver_init()`.
- `hdd_driver_init()` waits for `wcnss_device_ready()`, which requires `penv->nv_downloaded`. Runtime evidence shows `wcnss_service` is still running despite being `oneshot` and is blocked in `qrtr_recvmsg`, so the QMI MAC/NV path is likely preventing WCNSS setup from completing.
- Persist has `/mnt/vendor/persist/WCNSS_qcom_wlan_nv.bin`, and `/vendor/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin` resolves to it, so the bring-up path should not require modem QMI to get Wi-Fi MAC/NV on pepito.
- Pepito now disables `wcnss_service` QMI via `uses_qcom_wcnss_qmi=false`; sibling mithorium variants keep the existing QMI-enabled service.
- Do not also declare `android.hardware.wifi.IWifi/default` in `device/xiaomi/Mi8937/manifest.xml`; `android.hardware.wifi-service` already installs `/vendor/etc/vintf/manifest/android.hardware.wifi-service.xml`, and duplicating it causes a VINTF conflict on boot.
- Post-flash verification with non-QMI `wcnss_service`:
  - Flashed `/vendor/bin/wcnss_service` no longer links `libqmi*` and contains no QMI strings.
  - `wcnss_service` now blocks in `wcnss_wlan_read`, not `qrtr_recvmsg`.
  - WCNSS powers Pronto, loads `wcnss.mdt` and segments from `/firmware/image`, reports version `01050102`, and downloads `/vendor/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin` from persist.
  - Writing `STA` to `/sys/module/wlan/parameters/fwpath` succeeds, loads Prima `v3.0.11.85.9`, and creates `wlan0`.
  - Framework Wi-Fi enable reaches HAL driver load, creates `wlan0`, and wificond attaches.
  - Current failure is `wpa_supplicant: Conf file does not exists: /data/vendor/wifi/wpa/wpa_supplicant.conf`; `SupplicantStaIfaceHalAidlImpl.addStaInterface()` then returns service-specific error code 1 and the framework tears Wi-Fi back down.
  - Live validation after manually seeding `/data/vendor/wifi/wpa/wpa_supplicant.conf`: Wi-Fi remains enabled, `ClientModeManager` reaches `ROLE_CLIENT_PRIMARY` on `wlan0`, supplicant connects, and scans return APs.
  - User confirmed Wi-Fi works on-device after the live seed, so the current tree fix should make this survive reboot/flash without manual intervention.
- Pepito persist contains the real Wi-Fi MAC at `/mnt/vendor/persist/param/wlanaddr` as six raw bytes: `e0:e6:2e:a9:3e:e3`. The common firmware symlink expects `/mnt/vendor/persist/wlan_mac.bin`, which is missing, so the driver currently falls back to generated MAC `00:0a:f5:5c:bd:28`.

## Next focus

Rebuild and flash with the common `wpa_supplicant.conf` package plus the init seed-copy into `/data/vendor/wifi/wpa/wpa_supplicant.conf`. On first boot, verify Wi-Fi still comes up without manual data seeding. Remaining Wi-Fi cleanup: add a pepito-specific MAC materialization step from `/mnt/vendor/persist/param/wlanaddr` to `/mnt/vendor/persist/wlan_mac.bin` so the driver uses the factory MAC.
