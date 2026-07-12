# Pepito Sensor Bring-up Plan

> **2026-06-23 boot status:** device boot was restored after two regressions
> (RPMB device-node type — kernel; GPU CP microcode — vendor blob); `sys.boot_completed=1`
> again, so this subsystem is testable again. SELinux is still Permissive (bring-up
> diagnostic). Details: `PLAN.md`, `PLAN-gatekeeper.md`, `PLAN-surfaceflinger.md`,
> `PLAN-userspace.md`.

**Status as of 2026-06-10:** keep `hals.conf` empty for boot stability. The flashed image
contains the Palm stock sensor blobs, and rooted ADB tests confirmed the HAL can be driven manually,
but loading `sensors.ssc.so` still blocks `android.hardware.sensors@1.0-service` before HIDL
registration. The failure is now narrowed to QRTR/QMI service discovery: `libsensor1` sends
`QRTR_TYPE_NEW_LOOKUP` requests to `QRTR_PORT_CTRL` for QMI service `0` and service `256` (`0x100`,
the SMGR/sensor service family), then waits forever in `qrtr_recvmsg`. No ADSP-side
`NEW_SERVER` advertisement arrives. The first-layer `/persist` registry issue is fixed in tree by
removing the common `/persist -> /mnt/vendor/persist` symlink for pepito and bind-mounting
`/mnt/vendor/persist` onto a real `/persist` directory before starting `sensors.qti`.

---

## Architecture — how MSM8940 sensors work

MSM8940 (SOC ID 313) uses the **DSPS / SSC path**: sensor drivers run on the Hexagon DSP
(ADSP), not as Linux kernel drivers. The kernel side is a thin IPC relay.

```
Physical sensors (I2C/SPI on ADSP)
        ↓
ADSP firmware (sensors.ssc image loaded by PIL)
        ↓  QMI over SMD/IPC router
sensors-ssc kernel driver  →  /dev/sensors char device
        ↓
sensors.qti  (DSPS daemon, pid 976)   reads /dev/sensors, manages registry
        ↓  IPC socket
sensors.ssc.so  (legacy HAL, dlopen'd by multihal)
        ↓
android.hardware.sensors@1.0-impl.so  (multihal aggregator)
        ↓  HIDL
android.hardware.sensors@1.0-service
        ↓
sensorservice  →  apps
```

Key confirmed facts on device right now:
- `sensors-ssc` kernel driver **bound** to `soc:qcom,msm-ssc-sensors` ✓
- `/dev/sensors` exists as char device major 498 and is opened by `sensors.qti` ✓
- ADSP subsystem **ONLINE** (`/sys/bus/msm_subsys/devices/subsys1/state`) ✓
- ADSP firmware present (`/firmware/image/adsp.b00…adsp.mdt`) ✓
- `sensors.qti` running and blocked in `qrtr_recvmsg` waiting for SMGR/QMI traffic ✓
- `android.hardware.sensors@1.0-service` running and registered in `lshal` ✓
- `sns.reg` is present, but moving it aside and forcing regeneration did not change behavior ✓
- Current live `/vendor/bin/sensors.qti` is not Palm stock; stock has `sensors.qcom` instead ✓
- Current live `sensors.ssc.so`, `libsensor1.so`, and `libsensor_reg.so` hashes differ from Palm stock ✓
- Stock Palm `hals.conf` lists both `sensors.ssc.so` and `sensors.native.so`; current live only lists `sensors.ssc.so` ✓
- `vendor.fastrpc.disable.adsprpcd_sensorspd.daemon=1` — correct for MSM8940; sensors use
  the legacy DSPS path, not FastRPC

**`adsprpcd_sensorspd` being disabled is intentional** (`init.qcom.early_boot.sh` sets this
for all SOC IDs 294–313 / MSM8937 + MSM8940). Do not re-enable it.

---

## Dependency closure — all satisfied

`sensors.ssc.so` needs:

| Library | Present |
|---|---|
| `libsensor1.so` | ✓ `/vendor/lib64/` |
| `libsensor_reg.so` | ✓ `/vendor/lib64/` |
| `libdiag.so` | ✓ `/vendor/lib64/` |
| `libqmi_encdec.so` | ✓ `/vendor/lib64/` (added in §C session) |
| `libqmi_cci.so` | ✓ `/vendor/lib64/` |
| `libqmi_common_so.so` | ✓ `/vendor/lib64/` |
| `libutils`, `libcutils`, `liblog`, `libhardware`, `libpower` | ✓ system |

No missing deps. The original boot-blocking crash was `libqmi_encdec.so` missing — that fix
is already in the vendor tree.

---

## Step 1 — Keep HAL list empty for boot stability

Palm stock `vendor/etc/sensors/hals.conf` contains two modules:

```
sensors.ssc.so
sensors.native.so
```

That stock list was tested in a new build on 2026-06-08. Result: `sensors.qti` starts, but
`android.hardware.sensors@1.0-service` blocks in `__skb_wait_for_more_packets` before registering
with hwservicemanager. Framework code then waits forever for
`android.hardware.sensors@1.0::ISensors/default`, and `sensorservice` is absent.

Live mitigation on the same boot:

```bash
adb remount
adb shell ': > /vendor/etc/sensors/hals.conf; stop vendor.sensors-hal-1-0; start vendor.sensors-hal-1-0'
```

After that, `lshal` shows `android.hardware.sensors@1.0::ISensors/default` registered and
`dumpsys sensorservice` reports `No Sensors on the device`. That is the desired build default until
the QRTR/ADSP side is fixed.

Current tree state:
- `device/xiaomi/mithorium-common/configs/sensors/hals.conf` is empty by design.
- Stock Palm sensor blobs are staged and were verified on-device by hash.
- `sensors.native.so` remains packaged, but no module is loaded by default.
- Pepito no longer gets the common root `/persist` symlink; `init.qcom.sensors.sh` bind-mounts
  `/mnt/vendor/persist` onto a real `/persist` mountpoint before starting `sensors.qti`.

To retest the stock Palm stack later, temporarily put this back in `hals.conf` and reboot or restart
the HAL:

```bash
sensors.ssc.so
sensors.native.so
```

---

## Step 2 — If sensors.ssc.so loads but reports zero sensors

`sensors.qti` + `sns.reg` bridge between `sensors.ssc.so` and the ADSP. Failure modes:

### 2a — DSPS not responding (QMI timeout)

`sensors.qti` talks to the ADSP sensor framework via `/dev/sensors` (IPC-router SMD channel).
If the ADSP isn't running sensor firmware, `libsensor1` QMI calls time out.

Diagnose:
```bash
adb shell dmesg | grep -i "smd\|ipc_router\|sensors"
adb shell cat /proc/976/status   # check State — D = blocked on IPC
```

If ADSP isn't loading its sensor image, check whether `sensors.b00…sensors.mdt` exist in
`/firmware/image/` (they may not — ADSP firmware is split into `adsp.*` for core DSP and
potentially separate sensor images on some variants).

**Current device evidence:** `sensors.qti` is alive, `sensors.qti` logs reference SMGR waits,
and kernel logs show ADSP coming up cleanly before the sensor services start. The remaining
question is whether the sensor manager is never advertising a usable SMGR endpoint or whether
the HAL is misinterpreting the response path.

### 2b — Registry mismatch

`sns.reg` was written by Palm's stock Android 8.1 sensor daemon. The sensor IDs, calibration
offsets, and hardware config inside it apply to Palm's specific sensor chips. If the registry
entry for a sensor specifies an I2C address or driver UUID that doesn't match the actual
hardware, `sensors.qti` will initialise that sensor but get no data.

The registry is self-healing to some extent: if `sensors.qti` can't init a sensor it marks it
disabled in the registry and continues. Worst case: delete `sns.reg` and let it regenerate
from scratch on first boot (loses calibration, all sensors come up at factory defaults).

```bash
adb shell mv /mnt/vendor/persist/sensors/sns.reg /mnt/vendor/persist/sensors/sns.reg.bak
# reboot — sensors.qti regenerates sns.reg from scratch
```

### 2c — `sensors.ssc.so` needs to be in `hw/` subdir

`hw_get_module()` (the legacy HAL loader path) searches `/vendor/lib64/hw/` for modules
named `sensors.<variant>.so`. The multihal path uses `dlopen()` directly with the path from
`hals.conf`, so this should **not** be an issue if the absolute path is in `hals.conf`.

If for any reason the HAL impl falls back to `hw_get_module` rather than multihal, add
`sensors.ssc.so` to `/vendor/lib64/hw/` as well:

```makefile
# in vendor/xiaomi/mithorium-common/mithorium-common-vendor.mk
$(LOCAL_PATH)/vendor/lib64/sensors.ssc.so:$(TARGET_COPY_OUT_VENDOR)/lib64/hw/sensors.ssc.so \
```

Or in `Android.bp` for `sensors.ssc`:
```
relative_install_path: "hw",
```

### 2d — Stock-vs-current sensor blob mismatch

This is the current best lead. The live device was running:
- `/vendor/bin/sensors.qti` from the Mi8937/PAN blob set
- `sensors.ssc.so`, `libsensor1.so`, and `libsensor_reg.so` with hashes/sizes different from
  Palm stock
- no `sensors.native.so` in `hals.conf`

Palm stock Android 8.1 has:
- `/vendor/bin/sensors.qcom` (229832 bytes), now staged as `/vendor/bin/sensors.qti` to preserve
  current init/sepolicy service naming
- `/vendor/lib64/sensors.ssc.so` (302528 bytes)
- `/vendor/lib64/libsensor1.so` (80976 bytes)
- `/vendor/lib64/libsensor_reg.so` (15104 bytes)
- `/vendor/lib64/sensors.native.so` (110032 bytes)
- `hals.conf` with `sensors.ssc.so` and `sensors.native.so`

Live test results, 2026-06-08:
- Replaced live `/vendor/bin/sensors.qti` with stock Palm `sensors.qcom` under the same filename.
- Replaced live `sensors.ssc.so`, `libsensor1.so`, and `libsensor_reg.so` with Palm stock.
- Added live `sensors.native.so` and stock `hals.conf` order.
- Stock daemon initially failed registry open with `sns_fsa_la.c(89):invalid directory path 24`
  because Android 16 exposes `/persist` as a symlink to `/mnt/vendor/persist`.
- Bind-mounting `/mnt/vendor/persist` over `/persist` fixed the registry error; strace then showed
  `/persist/sensors/sns.reg` opening successfully.
- After that, `sensors.qti` sends AF_QIPCRTR lookup packets and waits; no SMGR/service response is
  observed, and `dumpsys sensorservice` still reports no sensors.
- Native-only and native-first `hals.conf` tests also return zero sensors. `sensors.native.so` loads
  and logs `BST BHy HAL version: 1.3.20.0`, but exposes no sensor list.
- New-build test with stock `sensors.ssc.so` first regressed boot behavior: the HAL service process
  stays alive but never registers `android.hardware.sensors@1.0::ISensors/default`, so
  `sensorservice` is missing. Emptying `hals.conf` live restores registration and leaves a stable
  no-sensors state.

Additional live tests, 2026-06-10:
- Flashed vendor contains Palm stock `sensors.qti`, `sensors.ssc.so`, `libsensor1.so`,
  `libsensor_reg.so`, and `sensors.native.so`; hashes match the staged vendor tree.
- Restarting `sensors.qti` while `/persist` is the common symlink reproduces
  `sns_fsa_la.c(89):invalid directory path 24` and `sns_reg_la.c(305):Error opening registry file`.
- Replacing `/persist` live with a real bind mount removes the registry errors; `sensors.qti` then
  waits in `qrtr_recvmsg`.
- `sensors.native.so` only registers HIDL but reports no sensors. Logs show it is Bosch BHy HAL
  `1.3.20.0`, looks for `/sys/class/i2c-dev/i2c-2/device/2-0028/`, and fails with
  `Device not found`; this is not the Palm SSC path.
- `sensors.ssc.so` only logs `Init the smgr_sensor1_cb for SMGR sensor1 connection`, then blocks
  before HIDL registration. Kernel stacks show both the HAL and `sensors.qti` sleeping in
  `qrtr_recvmsg`.
- Startup strace shows `libsensor1` sends QRTR name-service lookups for service `0` and service
  `256` (`0x100`) to `QRTR_PORT_CTRL`; the service-256 lookup never receives a server
  advertisement. This is the current narrow blocker.

Tree changes staged from this finding:
- Stock Palm sensor blobs are staged in `vendor/xiaomi/Mi8937/proprietary/vendor/`.
- `sensors.native` is packaged in `vendor/xiaomi/Mi8937/Android.bp` and `Mi8937-vendor.mk`.
- Pepito omits the common `/persist -> /mnt/vendor/persist` root symlink and
  `init.qcom.sensors.sh` bind-mounts `/mnt/vendor/persist` onto the real `/persist` directory before
  starting the daemon.

This is more plausible than a missing Linux sensor driver because `/dev/sensors` only supplies
a timer ioctl plus SLPI boot sysfs; SMGR enumeration is handled by the daemon/HAL/QMI blob stack.
The remaining failure is now lower than the registry and HAL-load layers: ADSP/QRTR is not
advertising or responding for the sensor QMI services.

### 2e — Current narrow blocker: QRTR service 256 is not advertised

With the filesystem and blob mismatch issues removed, the remaining failure is service discovery for
Qualcomm's sensor QMI service:

```text
socket(AF_QIPCRTR, SOCK_DGRAM|SOCK_CLOEXEC, 0)
sendto(... QRTR_TYPE_NEW_LOOKUP, service=0, instance=0, QRTR_PORT_CTRL)
sendto(... QRTR_TYPE_NEW_LOOKUP, service=256, instance=0, QRTR_PORT_CTRL)
recvfrom(...)  # waits forever
```

Service `256` maps to the SMGR/sensor service family exposed by `libsensor1` strings
(`SNS_SMGR_SVC_qmi_idl_service_object_v01`, `SNS_SMGR_RESTRICTED_SVC`, etc.). The next useful work
is kernel/ADSP transport validation, not HAL packaging:
- compare stock kernel IPC-router/QRTR/SMD service advertisements for sensor service 256
- check whether this 4.19 kernel has the correct SMD edge/channel for ADSP sensor services
- verify whether Palm stock ADSP firmware advertises SMGR over legacy SMD IPC-router rather than
  the QRTR path used by this `libqmi_cci` stack
- inspect `qmi_fw.conf` expectations; strace shows `/vendor/etc/qmi_fw.conf` is absent, so the QMI
  client uses its compiled default transport mapping

### 2f — Reserved memory / device tree check

`/dev/sensors` itself is DT/kernel-created by the `qcom,msm-ssc-sensors` node, and that node is
present in both stock Palm DTB and the current tree. Reserved memory is mostly not the sensor
mismatch: `vendor-legacy/qcom/msm8940.dtsi` already overrides `modem_mem`, `adsp_fw_mem`, and
`wcnss_fw_mem` to the same fixed regions as stock Palm. Pepito already has the required
`other_ext_mem` override to stock Palm's 30 MiB TZ-protected region. No additional reserved-memory
DTS change is currently indicated for sensors.

### 2g — HAL version mismatch warning

`android.hardware.sensors@1.0-service` currently logs:

```
HAL specifies version 1.4, but does not implement set_operation_mode()
```

`lshal` still shows the service as `android.hardware.sensors@1.0::ISensors/default`, so the
warning is not a registration failure by itself. The current hypothesis is:
- the wrapper or its underlying implementation is compiled against a newer sensors HAL ABI
- the service advertises capabilities that the implementation does not fully support
- that mismatch may be benign for boot, but it may also cause the wrapper to expose zero sensors

Track this separately from SMGR/QMI until we have evidence it changes enumeration.

---

## Step 3 — Identify the actual sensor hardware

Palm PVG-100 sensor suite (from stock 8.1 teardowns and sns.reg):
- **Accelerometer + Gyroscope**: likely Bosch BMI160 (common on MSM8940 designs of this era)
- **Proximity + ALS**: likely APDS-9930 or STK3x1x (i2c_6 or similar)
- **Magnetometer**: likely AKM AK09915 or Yamaha YAS537

These are **ADSP-side** — they are not on any Linux I2C bus (only i2c-3 @ 0x38 is the FT8613
touchscreen). They live on i2c buses wired directly to the ADSP Hexagon core, which is why
`lsmod` and `/sys/bus/i2c/devices/` show nothing for sensors.

To confirm chip identities once `sensors.ssc.so` is loading:
```bash
adb shell dumpsys sensorservice
# Lists sensor names and vendors reported by the DSPS firmware
```

---

## Step 4 — SELinux (deferred until sensors work)

The live device currently reports `Enforcing`, but no sensor-specific AVCs have shown up in the
logs inspected so far. If the stock Palm blob stack still reports zero sensors, recheck denials
before assuming a QMI/firmware failure:

```bash
adb shell dmesg | grep "avc: denied" | grep -i sensor
```

Common pepito-specific labels needed:
- `vendor.sensors-hal-1-0` process label
- `sensors_persist_file` for `/mnt/vendor/persist/sensors/`

Add to `device/xiaomi/Mi8937/sepolicy/vendor/` (not AOSP source).

---

## Summary checklist

- [x] **Step 1:** Restore `hals.conf` to Palm stock `sensors.ssc.so` + `sensors.native.so`
- [x] **Step 2d:** Identify and stage Palm stock sensor daemon/HAL support blob set
- [x] **Live test:** Stock Palm blobs load; `/persist` bind workaround fixes registry open
- [ ] **Current blocker:** ADSP/QRTR sensor QMI lookup gets no response after registry succeeds
- [ ] **Next build:** Flash vendor with stock Palm sensor blobs once QRTR/ADSP lead is addressed
- [ ] **If still zero sensors:** Delete and regenerate `sns.reg` if registry is blocking init
- [ ] **Step 2f (investigation):** resolve whether the `1.4` warning is a harmless ABI mismatch
      or part of the zero-sensor failure
- [ ] **Step 3:** Confirm sensor identities via `dumpsys sensorservice` output
- [ ] **Step 4:** SELinux audit once sensors work in permissive mode
- [ ] Update `PLAN.md` sensors row from 🔧 to ✅ when `dumpsys sensorservice` shows sensors
      and a test app can read accelerometer data
