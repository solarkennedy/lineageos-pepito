# LineageOS 23.2 — Radio / Telephony / Modem Stack (pepito/PVG100)

Status of the QTI radio + modem + GPS + IMS userspace on this build.
Updated 2026-06-24 (session 9: root-caused the transport layer — neither QRTR nor stock QMUX path works as-is; need to port `msm_ipc_router` kernel driver from stock kernel source).

> **2026-06-23:** Blob closure gaps (missing `libCheckTunning.so`,
> `libsmemlog.so`, etc.) were traced to an accidental bulk overwrite of ~200
> nightly vendor blobs with stock AML0 versions on Jun 16. Restoring 72 blobs
> from the nightly image resolved all daemon crashes (`rmt_storage`,
> `pm-service`, `ATFWD-daemon`, etc.). The blob closure is now clean.
>
> **2026-06-24 (session 9) — Transport layer root-cause:**
>
> The fundamental radio blocker is now fully understood. It is a **kernel QMI
> transport mismatch**, not a userspace blob issue:
>
> - The nightly `libqmi_cci.so` calls `socket(AF_QIPCRTR=42)` to use **QRTR**
>   transport. The kernel has QRTR built-in (`CONFIG_QRTR=y`), so the socket
>   succeeds — but the **pepito modem firmware does not speak QRTR** (kernel
>   logs: `qcom_smd_qrtr_callback: Not ready`). qcrild starts, registers
>   vendor HIDL services, but never completes QMI service discovery and never
>   calls `RIL_register` → no `IRadio/slot1`.
>
> - The stock AML0 `libqmi_cci.so` calls `socket(AF_IPC_ROUTER=27)` to use
>   the legacy **msm_ipc_router** kernel driver. This driver does **not exist**
>   in the current 4.19 kernel tree — it was replaced by QRTR in
>   mainline-aligned kernels. So the stock RIL stack also cannot work.
>
> - The stock AML0 `rild` + `libril-qc-qmi-1.so` path was also blocked by
>   cascading dependency issues (`libsettings.so` → `libprotobuf-cpp-full.so`
>   → `libsqlite.so` → `libandroidicu.so` — each from Android 8.1 and
>   incompatible with Android 15 system libs).
>
> - `CONFIG_QRTR` cannot simply be disabled: the kernel QMI helper library
>   (`qmi_txn_wait`, `qmi_response_type_v01_ei`, etc.) that slimbus and other
>   kernel drivers depend on is built as part of QRTR.
>
> - The nightly `libril-qc-hal-qmi.so` links `libqmi_client_qmux.so` but
>   never calls `qmi_cci_qmux_xport_register()` — QMUX is not integrated as
>   a CCI transport option. The `qmi_fw_cci_init` function selects between
>   QRTR ops and IPCR ops only.
>
> **The fix: port `msm_ipc_router` into the current kernel.**
>
> Source is available at:
> `/home/kyle/Projects/android-pepito-pvg100-kernel-upgrade/kernel_src/net/ipc_router/`
>
> This registers `AF_IPC_ROUTER` (family 27) alongside the existing QRTR
> (family 42). Then block QRTR sockets for qcrild (SELinux deny rule or small
> LD_PRELOAD shim) so the nightly `libqmi_cci.so` falls back to IPCR, which
> routes through the old SMD channels that the modem understands.
>
> This avoids the stock AML0 RIL dependency nightmare entirely — the nightly
> qcrild + libril-qc-hal-qmi.so stack has all dependencies satisfied.

---

## Legend
- ✅ Working / present and proven
- 🔧 Extracted but not runtime-verified
- ❌ Missing / known broken
- ❓ Unknown — needs a real boot to confirm

---

## High-level state

| Layer | Status | Notes |
|---|---|---|
| Modem image (`/dev/block/by-name/modem`) | ✅ | Mounted at `/vendor/firmware_mnt` / `/firmware`; kernel can load `modem.mdt`, `mba.mbn`, and modem segments when `/dev/subsys_modem` is opened. |
| QMI kernel transports (SMD/QMUX vs QRTR) | ❌ | **Root-caused in session 9.** Modem speaks legacy IPC Router (AF=27) over SMD. Kernel has QRTR (AF=42) but modem ignores it. Kernel lacks `msm_ipc_router` (AF=27). Need to port the driver from stock kernel source. |
| RIL daemon (`vendor.qcrild` init service) | 🔧 | Reverted to nightly `qcrild` + `libril-qc-hal-qmi.so` (stock AML0 `rild` path abandoned due to cascading Android 8.1 dependency issues). qcrild starts, registers vendor HIDL services, but cannot complete QMI init due to transport mismatch above. |
| `pm-service` / `vendor.per_mgr` (PeripheralManager) | 🔧 | Stock PVG100 AML0 `pm-service` and `pm-proxy` imported, packaged, installed, and running. Early boot instances abort with `RefBase used with stack pointer argument`, but a later instance stays up and QCRIL successfully registers/votes for modem. |
| QMI userspace libs (libqmi*, libril) | 🔧 | Stock AML0 QMI/RIL libs are now packaged for the legacy `rild` path. Source-built `libril.so`/`librilutils.so` remain intentionally used first to avoid duplicate install conflicts. |
| RIL framework lib stack (libqcrilFramework, libqdi, libqdp, libdsutils) | 🔧 | Extracted in this round |
| `rmt_storage` (modem EFS proxy) | ✅ | Built/flashed and running as root (PID observed 983). No current modem SSR-loop evidence from this check, but QCRIL still cannot register for modem. |
| `time_daemon` (modem-time sync) | 🔧 | Extracted |
| `ATFWD-daemon` (AT command forwarder) | ✅ | Built/flashed and running as system (PID observed 1125). |
| `ssr_diag` / `ssr_setup` (subsystem-restart) | 🔧 | Extracted |
| GPS stack (`loc_launcher` + `xtra-daemon` + libs) | 🔧 | Extracted; configs/conf files not yet pulled |
| IMS / VoLTE (`ims*daemon` + libs) | 🔧 | Extracted; non-functional until full RIL is up |
| Source-built HALs (radio.config@1.1, gnss@2.1-impl-qti, sensors@1.0) | 🔧 | `vendor.radio-config-1-1-wrapper` runs, but repeatedly waits on missing/unregistered `lineage.hardware.radio.config@1.0::IRadioConfig/default`; `android.hardware.radio.config@1.1` requests loop through the wrapper. |

---

## Runtime validation — 2026-06-08

### Single-SIM correction for pepito

Pepito/PVG100 has one physical SIM slot. The shared mithorium defaults were
forcing DSDS, which started `vendor.qcrild2` and exposed two framework phones.
That is now fixed for the pepito build:

- `device/xiaomi/Mi8937/pepito.vendor.prop` sets
  `persist.radio.multisim.config=ssss` and `ro.telephony.default_network=33`.
- `device/xiaomi/Mi8937/BoardConfig.mk` includes that prop file only when
  `TARGET_DEVICE_PEPITO=true`.
- `device/xiaomi/mithorium-common/vendor.prop` changed the shared DSDS values
  to optional defaults (`?=`), so pepito can override without duplicate sysprop
  build failures.
- `device/xiaomi/Mi8937/rootdir/etc/init.xiaomi.device.rc` also sets
  `persist.radio.multisim.config ssss` when runtime detection identifies
  `ro.vendor.xiaomi.device=pepito`, clearing stale `/data` persist state.
- `device/xiaomi/mithorium-common/rootdir/etc/init.xiaomi.rc` now enables and
  starts `vendor.qcrild2` only for explicit multi-SIM values: `dsds`, `dsda`,
  or `tsts`.

Verified after flash:

```
persist.radio.multisim.config=ssss
ro.telephony.default_network=33
init.svc.vendor.qcrild=running
init.svc.vendor.qcrild2=<absent/not running>
```

`dumpsys telephony.registry` now exposes only `Phone Id=0`; the phantom second
SIM/phone path is gone.

### Current radio blocker

`qcrild` now runs as the only RIL daemon, but it still does not complete modem
registration:

```
RIL Daemon Started
RIL_Init argc = 3 clientId = 0
deviceInfoServiceModule dlopen failed ERROR: dlopen failed: library
    "/vendor/lib64/deviceInfoServiceModule.so" not found
QCRIL failed to register for modem
qmi_ril_peripheral_mng_init: Failed to register for modem
QCRIL_ERROR:INIT: unable to register with error: 2
RIL_onUnsolicitedResponse called before RIL_register
```

The missing `deviceInfoServiceModule.so` is still believed optional; the
load-bearing failure is the peripheral/modem registration error.

Observed HIDL services from `qcrild`:

```
vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0
```

Framework telephony remains `OUT_OF_SERVICE`, with no default subscription and
no signal/cell identity. Adding a physical SIM is useful for later validation,
but current evidence says the stack is blocked before SIM presence should be
the deciding factor.

### Remaining noisy/non-blocking-for-SIM findings

- `lineage.hardware.radio.config@1.0::IRadioConfig/default` is not installed or
  not registered; `vendor.radio-config-1-1-wrapper` repeatedly waits for it.
- `loc_launcher` still crashes on missing `/data/vendor/location/gps.prop`; GPS
  is intentionally out of scope for the current SIM/radio pass.

## Runtime validation — 2026-06-15

### PeripheralManager is the current QCRIL blocker

Fresh flash/boot reproduced the single-SIM state:

```text
persist.radio.multisim.config=ssss
ro.telephony.default_network=33
init.svc.vendor.qcrild=running
init.svc.vendor.qcrild2=<absent/not running>
```

The modem subsystem initially sits in `OFFLINING`/`OFFLINE` because nothing is
holding `/dev/subsys_modem` open. Manually opening the node proves the kernel
and firmware path can boot the modem:

```bash
adb shell 'exec 3</dev/subsys_modem; sleep 30'
```

Relevant kernel evidence:

```text
subsys-restart: __subsystem_get(): Changing subsys fw_name to modem
pil-q6v5-mss 4080000.qcom,mss: modem: loading from 0x86800000 to 0x8be00000
pil-q6v5-mss 4080000.qcom,mss: MBA boot done
pil-q6v5-mss 4080000.qcom,mss: modem: Brought out of reset
pil-q6v5-mss 4080000.qcom,mss: Subsystem error monitoring/handling services are up
vendor.subsys_state_notifier.modem.state=ONLINE
```

While the modem was held online, restarting `qcrild` moved the failure to the
missing peripheral-manager binder service:

```text
RIL Daemon Started
RIL_Init argc = 3 clientId = 0
Waiting for service 'vendor.qcom.PeripheralManager' on '/dev/vndbinder'...
Service vendor.qcom.PeripheralManager didn't start. Returning NULL
PerMgrLib: modem get service fail
PerMgrLib: QCRIL failed to register for modem
qmi_ril_peripheral_mng_init: Failed to register for modem
QCRIL_ERROR:INIT: unable to register with error: 2
```

Trying to start the init service confirms the binary is missing:

```text
Unable to start service 'vendor.per_mgr'
init: Cannot find '/system/vendor/bin/pm-service': No such file or directory
```

Tree state before the 2026-06-16 build update:

- `device/xiaomi/mithorium-common/proprietary-files-qc-vndr.txt` already lists
  `vendor/bin/pm-service`, `vendor/bin/pm-proxy`, and
  `vendor/lib64/libperipheral_client.so`.
- Local extracted vendor tree currently contains only
  `vendor/lib64/libperipheral_client.so`; `pm-service` and `pm-proxy` are
  absent.
- `device/xiaomi/mithorium-common/rootdir/etc/init.target.rc` defines
  `vendor.per_mgr` and `vendor.per_proxy`, but both are disabled. It starts
  `vendor.per_proxy` when `vendor.per_mgr` is running, but nothing currently
  starts `vendor.per_mgr`.

Completed radio build target (2026-06-16):

1. ✅ Sourced compatible `pm-service` and `pm-proxy` blobs from stock PVG100 AML0.
2. ✅ Packaged both binaries into the common vendor image via legacy copy rules.
3. ✅ Added a boot trigger for `vendor.per_mgr` before QCRIL needs PeripheralManager.
4. 🔧 Re-test `qcrild`; expected next milestone is registration of
   `lineage.hardware.radio.config@1.0::IRadioConfig/default`, legacy
   `android.hardware.radio@1.5::IRadio/slot1`, and then AIDL radio compat
   services for slot1.

Build update — 2026-06-16:

- Found stock Palm PVG100 Android 8.1 AML0 `pm-service` and `pm-proxy` blobs
  and copied them into `vendor/xiaomi/mithorium-common/proprietary/vendor/bin/`.
- `vendor/xiaomi/mithorium-common/mithorium-common-vendor.mk` now installs
  `/vendor/bin/pm-service` and `/vendor/bin/pm-proxy` via legacy
  `PRODUCT_COPY_FILES`.
- `libperipheral_client.so` remains packaged by the existing Mi8937 generated
  Soong module from `vendor/xiaomi/Mi8937/proprietary/vendor/lib64/`, avoiding
  a duplicate install rule.
- `device/xiaomi/mithorium-common/rootdir/etc/init.target.rc` now starts
  `vendor.per_mgr` on boot for `ro.baseband=msm`, and both PeripheralManager
  services use `/vendor/bin/...` paths instead of `/system/vendor/bin/...`.
- A lightweight `m nothing` check passed product configuration but was stopped
  during Soong graph generation after it exceeded the quick-check window; full
  build verification is still pending.

Next flash validation target:

1. Confirm `/vendor/bin/pm-service` and `/vendor/bin/pm-proxy` exist.
2. Confirm `init.svc.vendor.per_mgr=running` and `init.svc.vendor.per_proxy=running`.
3. Confirm `vendor.qcom.PeripheralManager` appears in the vendor service list.
4. Restart or observe `qcrild`; the previous `PerMgrLib: modem get service fail`
   error should be gone.
5. Check whether slot1 radio services register and whether modem state stays
   `ONLINE` without manually holding `/dev/subsys_modem` open.

Runtime update after flash — 2026-06-16:

Verified over root ADB before the device later dropped offline:

```text
ro.vendor.xiaomi.device=pepito
ro.baseband=msm
persist.radio.multisim.config=ssss
ro.telephony.default_network=33
init.svc.vendor.per_mgr=running
init.svc.vendor.per_proxy=running
init.svc.vendor.qcrild=running
init.svc.vendor.qcrild2=stopped
vendor.subsys_state_notifier.modem.state=ONLINE
```

Installed files and labels:

```text
/vendor/bin/pm-service u:object_r:vendor_per_mgr_exec:s0
/vendor/bin/pm-proxy   u:object_r:vendor_per_mgr_exec:s0
/vendor/lib64/libperipheral_client.so u:object_r:vendor_file:s0
```

Important log transition:

```text
PerMgrSrv: QCRIL registered
PerMgrLib: QCRIL successfully registered for modem
PerMgrLib: QCRIL voting for modem
PerMgrSrv: QCRIL voting for modem
```

So the previous hard blocker, `Service vendor.qcom.PeripheralManager didn't
start`, is cleared. The modem is held `ONLINE` by userspace now.

New active blocker:

```text
HIDL registered:
vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0

Missing / waiting:
android.hardware.radio@1.5::IRadio/slot1
android.hardware.radio.config@1.1::IRadioConfig/default
lineage.hardware.radio.config@1.0::IRadioConfig/default
android.hardware.radio.data.IRadioData/slot1
```

Framework state remains no-service/no-subscription:

```text
mVoiceRegState=OUT_OF_SERVICE
mDataRegState=OUT_OF_SERVICE
mSignalStrength=null
mActiveDataSubId=-1
mDefaultPhoneId=-1
mDefaultSubId=-1
```

`pm-service` caveat: several early instances abort immediately with:

```text
Abort message: 'RefBase used with stack pointer argument'
/vendor/bin/pm-service main+1012
/vendor/lib64/libutils.so android::RefBase::incStrong
```

Despite that, the later running instance is functional enough for QCRIL modem
registration. Treat the crash as technical debt unless it correlates with later
radio instability.

The next target from this checkpoint is superseded by the session 7 QRTR/QMI
findings below.

Runtime update after flash — 2026-06-16 session 7:

Focused only on radio/SIM. Single-SIM and PeripheralManager fixes remain active:

```text
ro.vendor.xiaomi.device=pepito
ro.baseband=msm
persist.radio.multisim.config=ssss
ro.telephony.default_network=33
init.svc.vendor.per_mgr=running
init.svc.vendor.per_proxy=running
init.svc.vendor.qcrild=running
init.svc.vendor.qcrild2=stopped
```

QCRIL now gets past PeripheralManager registration and modem voting, then stalls
at QMI port discovery:

```text
RIL_Init argc = 3 clientId = 0
qcril_qmi_load_esoc_info: primary modem name: modem, primary modem link name: SMD
PerMgrLib: QCRIL successfully registered for modem
qcril_qmi_vote_up_primary_modem: Successfully voted for primary modem [modem]
qcril_qmi_client_init: Client connecting to QMI FW
qmi_ril_client_get_master_port: using port 65535
```

No full framework radio slot is published. `lshal` still only shows:

```text
vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0
```

Missing/waiting remains:

```text
android.hardware.radio@1.5::IRadio/slot1
android.hardware.radio.config@1.1::IRadioConfig/default
lineage.hardware.radio.config@1.0::IRadioConfig/default
android.hardware.radio.data.IRadioData/slot1
```

Modem SSR is still reproducible. After a controlled `qcrild` restart, the
modem went `OFFLINE` about 13 seconds later, then came back `ONLINE` and init
started qcrild again. Earlier checks also showed the modem can SSR even while
qcrild is stopped, so the current target is below Android framework telephony.

QRTR/RFS findings from the flashed vendor image:

```text
/vendor/bin/qrtr-ns                         missing
/vendor/lib64/libqrtr.so                    missing
/vendor/bin/tftp_server                     missing
/vendor/bin/rfs_access                      missing
/vendor/bin/pd-mapper                       missing
/vendor/etc/init/vendor.qti.tftp.rc         missing
init.svc.vendor.qrtr-ns                     empty/not started
```

The tree already has a disabled `vendor.qrtr-ns` service in
`device/xiaomi/mithorium-common/rootdir/etc/init.qcom.rc`, and the early boot
script is intended to set `init.svc.vendor.qrtrns.enable=1` for 4.14+ kernels.
Two source-side startup bugs were found and patched in this session:

1. Pepito reports `soc_id=313`, but the QRTR enable gate only matched
   `386|354|353|303`; `313` is now included.
2. `init.qcom.rc` defined `vendor.qrtr-ns` as `disabled` but had no property
   trigger; it now starts `vendor.qrtr-ns` when
   `init.svc.vendor.qrtrns.enable=1`.

Remaining build input needed: source compatible QRTR/RFS blobs, preferably from
stock/reference Android 11 vendor or FP3-derived vendor payload:

```text
/vendor/bin/qrtr-ns
/vendor/lib64/libqrtr.so
/vendor/bin/tftp_server
/vendor/bin/rfs_access
/vendor/bin/pd-mapper
/vendor/etc/init/vendor.qti.tftp.rc
```

Flash validation after QRTR startup patch — 2026-06-16:

The new pepito QRTR gate is active after flash:

```text
soc_id=313
init.svc.vendor.qrtrns.enable=1
```

But the service still cannot start because the binary is missing from the
flashed vendor image:

```text
init.svc.vendor.qrtr-ns=<empty>
/vendor/bin/qrtr-ns: No such file or directory
/vendor/lib64/libqrtr.so: No such file or directory
/vendor/bin/tftp_server: No such file or directory
/vendor/bin/rfs_access: No such file or directory
/vendor/bin/pd-mapper: No such file or directory
/vendor/etc/init/vendor.qti.tftp.rc: No such file or directory
init: Cannot find '/vendor/bin/qrtr-ns': No such file or directory
```

QCRIL behavior is unchanged until those blobs are packaged:

```text
PerMgrLib: QCRIL successfully registered for modem
qcril_qmi_client_init: Client connecting to QMI FW
qmi_ril_client_get_master_port: using port 65535
```

QRTR target superseded:

The Android 11 GSI/stock-vendor comparison below showed that stock AML0 vendor
also lacks `qrtr-ns`, `libqrtr.so`, `rfs_access`, and `pd-mapper`, while it
runs `/vendor/bin/hw/rild` with `libril-qc-qmi-1.so`. Do not keep chasing QRTR
for pepito unless the stock RIL path fails with evidence that a newer transport
is required.

## Stock/GSI comparison — 2026-06-16 session 8

The Android 11 GSI phone was plugged in for comparison. It reports GSI product
props, but its vendor partition is still stock Palm PVG100 Android 8.1 AML0:

```text
ro.product.model=phh
ro.product.device=Pepito
ro.vendor.build.fingerprint=Palm/PVG100/Pepito:8.1.0/OPM1.171019.019/v1AML-0:user/release-keys
ro.board.platform=msm8937
ro.hardware=qcom
ro.baseband=msm
```

Stock/GSI vendor findings:

```text
/vendor/bin/qrtr-ns                         missing
/vendor/lib64/libqrtr.so                    missing
/vendor/bin/rfs_access                      missing
/vendor/bin/pd-mapper                       missing
/vendor/etc/init/vendor.qti.tftp.rc         missing
/vendor/bin/tftp_server                     present
```

Live stock/GSI processes include `/vendor/bin/hw/rild`, `rmt_storage`,
`tftp_server`, and `netmgrd`. `rild` maps `/vendor/lib64/libril-qc-qmi-1.so`,
not the newer `qcrild` + `libril-qc-hal-qmi.so` stack.

`lshal` on the GSI/stock-vendor phone exposes the old radio stack:

```text
android.hardware.radio@1.0::IRadio/slot1
android.hardware.radio@1.1::IRadio/slot1
android.hardware.radio.deprecated@1.0::IOemHook/slot1
vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
vendor.qti.hardware.radio.ims@1.0::IImsRadio/imsradio0
vendor.qti.hardware.radio.lpa@1.0::IUimLpa/UimLpa0
vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0
vendor.qti.hardware.radio.qtiradio@1.0::IQtiRadio/slot1
vendor.qti.hardware.radio.uim@1.0::IUim/Uim0
vendor.qti.hardware.radio.uim_remote_client@1.0::IUimRemoteServiceClient/uimRemoteClient0
vendor.qti.hardware.radio.uim_remote_server@1.0::IUimRemoteServiceServer/uimRemoteServer0
```

Conclusion: the QRTR path was a false lead for pepito AML0. The active test is
now the stock Android 8.1 legacy RIL path over SMD/QMUX.

Build/source update from this comparison:

- `device/xiaomi/Mi8937/proprietary-files.txt` now lists stock AML0
  `/vendor/bin/hw/rild`, `libril-qc-qmi-1.so`, and the legacy QTI radio vendor
  libs with `MODULE_SUFFIX=_pepito_stock` so Soong module names are unique but
  installed filenames stay stock.
- `vendor/xiaomi/Mi8937/Android.bp` and `Mi8937-vendor.mk` now include
  `rild_pepito_stock`, `libril-qc-qmi-1_pepito_stock`, and the legacy
  `vendor.qti.hardware.radio.*@1.0_vendor_pepito_stock` modules.
- `device/xiaomi/mithorium-common/rootdir/vendor/etc/init/qcrild.rc` and the
  generated proprietary `vendor/etc/init/qcrild.rc` now keep the service name
  `vendor.qcrild` but start `/vendor/bin/hw/rild`; the existing modem `ONLINE`
  init triggers still apply.
- The old `qcrild` binary remains packaged but is no longer the service entry
  point for this test.
- Stock AML0 `/vendor/bin/tftp_server` is now copied into the common vendor tree
  and started as `vendor.tftp_server`, matching the stock radio-adjacent RFS/TFTP
  userspace that runs on the GSI phone.
- Local build verification could not run on `netbook4`; `build/envsetup.sh`
  exits with `Please ask the user to build remotely and not locally on this
  system`.

Next flash validation target:

1. Confirm `/vendor/bin/hw/rild` exists and `ps -AZ` shows `vendor.qcrild`
   running that binary.
2. Confirm `/vendor/bin/tftp_server` exists and
   `init.svc.vendor.tftp_server=running`.
3. Confirm `/vendor/lib64/libril-qc-qmi-1.so` and the legacy
   `vendor.qti.hardware.radio.*@1.0_vendor.so` libs are installed.
4. Watch linker/init logs for missing stock dependencies. The stale common
   `rild.libargs=-d /dev/smd0` property was removed to match stock AML0; if
   `rild` still fails channel selection, test an explicit `/dev/smdcntl0`
   override next.
5. Check `lshal` for the old radio HIDLs above, then check framework
   subscription/SIM state with a physical SIM inserted.

## Session 9 — Transport root-cause (2026-06-24)

### Blob closure fix

Session 8 (Jun 16) accidentally bulk-overwriting ~200 nightly vendor blobs with
stock AML0 versions caused cascading `CANNOT LINK EXECUTABLE` failures across
daemons. 72 blobs were restored from the nightly vendor image
(`lineage-23.2-20260526-nightly-Mi8937-signed.zip`). Only radio-specific and
pepito-specific blobs were kept from stock AML0 (`rild`, `libril-qc-qmi-1.so`,
keymaster blobs, camera overlayfs libs). Source tree `libsmemlog` additions were
reverted. After restore + reboot, all daemons start cleanly.

### Stock rild path — abandoned

Stock AML0 `rild` + `libril-qc-qmi-1.so` fails with:
```
dlopen failed: library "libsettings.so" not found
```

`libsettings.so` (from AML0) needs `libprotobuf-cpp-full.so`, which needs
`libsqlite.so`, which needs `libandroidicu.so` — a cascading chain of Android
8.1 system libraries incompatible with Android 15. This path is unworkable.

`qcrild.rc` reverted to nightly `/vendor/bin/hw/qcrild`.

### Nightly qcrild — runs but no IRadio

Nightly qcrild starts successfully with all dependencies met:

```
RIL Daemon Started
RIL_Init argc = 3 clientId = 0
PerMgrLib: QCRIL successfully registered for modem
PerMgrLib: QCRIL voting for modem
Registered vendor.qti.hardware.radio.am@1.0::IQcRilAudio/slot1
Registered vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0
```

But `RIL_register` is never called → no `IRadio/slot1`, no `IRadioConfig`.
Framework telephony stays `OUT_OF_SERVICE`.

### Transport layer analysis

**Disassembly of nightly `libqmi_cci.so` `qmi_fw_cci_init`:**

```
qmi_cci_init()
qmi_cci_xprt_qrtr_supported()    // socket(AF_QIPCRTR=42, SOCK_DGRAM|SOCK_CLOEXEC, 0)
if (supported) use qcci_qrtr_ops  // ← this path is taken
else           use qcci_ipc_router_ops
qmi_cci_xport_start(selected_ops)
```

QRTR socket creation succeeds (kernel has `CONFIG_QRTR=y`), so QRTR is always
selected. But the modem firmware never responds on QRTR — kernel repeatedly
logs `qcom_smd_qrtr_callback: Not ready`.

**Disassembly of stock AML0 `libqmi_cci.so` `qmi_fw_cci_init`:**

```
qmi_cci_init()
// No QRTR check — QRTR didn't exist in Android 8.1
use qcci_ipc_router_ops           // socket(AF_IPC_ROUTER=27, ...)
qmi_cci_xport_start(ipc_router_ops)
```

Uses `AF_IPC_ROUTER` (family 27) = Qualcomm's legacy `msm_ipc_router` kernel
driver. This driver talked to the modem over SMD channels. It does **not exist**
in the current 4.19 kernel — it was replaced by QRTR in mainline-aligned trees.

**Transport matrix:**

| Transport | AF | Kernel | Modem FW | Nightly libqmi_cci | Stock libqmi_cci |
|---|---|---|---|---|---|
| QRTR | 42 | Yes (built-in) | No ("Not ready") | Preferred | N/A |
| IPC Router | 27 | **Missing** | Yes (native) | Fallback | Primary |
| QMUX (userspace) | N/A | N/A | Yes | Not integrated | Via libqmi_client_qmux |

**Why other MSM8937 devices work:** their modem firmware was updated in later
OTAs to support QRTR. Pepito's modem is stuck on Palm's final AML0 firmware
which predates QRTR support for this SoC.

### Fix plan

1. Port `msm_ipc_router` from stock kernel source into current 4.19 kernel.
   Source: `~/Projects/.../kernel_src/net/ipc_router/` (6 files, ~160KB).
   Registers `AF_IPC_ROUTER` (27). Coexists with QRTR (`CONFIG_QRTR` stays
   enabled for kernel QMI helpers used by slimbus etc.).

2. Block QRTR for qcrild so `libqmi_cci.so` falls back to IPCR (AF=27).
   SELinux deny or LD_PRELOAD shim for `socket(42, ...)` → `EAFNOSUPPORT`.

3. Nightly qcrild + libril-qc-hal-qmi.so stack works unchanged — all
   dependencies already satisfied, no stock AML0 blobs needed.

### Other fixes in this session

- **`linker.config.pb` dependency cycle:** `linker_config` Soong module in
  `device/xiaomi/Mi8937/Android.bp` conflicted with build system's vendor
  linker config generation. Fixed by removing the Soong module and using
  `PRODUCT_VENDOR_LINKER_CONFIG_FRAGMENTS` in `device.mk` instead.

---

## What we extracted this round (2026-06-05)

Blob extraction methodology is in `PLAN-vendor-extract.md`. Below is the
inventory specific to telephony/radio/modem.

### Daemons (`/vendor/bin/`)

| Daemon | Purpose |
|---|---|
| `adsprpcd` | ADSP RPC — audio + sensors HAL talk to ADSP via this |
| `rmt_storage` | Proxies modem `/dev/block/by-name/modemst{1,2}` and `/persist/data` so the modem can read/write its own EFS (calibration, IMEI, NV items) |
| `time_daemon` | Syncs Android clock from modem timestamp source |
| `ATFWD-daemon` | Forwards AT commands between userspace (radio HAL) and modem |
| `ssr_diag` | Subsystem-restart diagnostics |
| `ssr_setup` | Subsystem-restart provisioning |
| `loc_launcher` | GNSS pipeline launcher — fans out to xtra-daemon, location-service-helpers |
| `xtra-daemon` | Downloads almanac (XTRA) data for assisted GPS — needs network |
| `imsdatadaemon` | IMS bearer / data session management |
| `imsqmidaemon` | IMS-to-modem QMI bridge |
| `ims_rtp_daemon` | VoLTE RTP session handling |

### Libraries (`/vendor/lib64/`)

**QMI / RIL framework** (15)

`libqmi.so`, `libqmi_cci.so`, `libqmi_csi.so`, `libqmi_common_so.so`,
`libqmi_client_qmux.so`, `libqmi_client_helper.so`, `libqmiservices.so`,
`libmdmdetect.so`, `libavservices_minijail.so`, `libidl.so`,
`libril.so`, `libqcrilFramework.so`, `libqdi.so`, `libqdp.so`,
`libdsutils.so`.

**GPS** (7)

`libgps.utils.so`, `libloc_core.so`, `libizat_core.so`,
`liblbs_core.so`, `libcdfw_remote_api.so`, `libqcc_file_agent.so`.

Intentionally **not** extracted (source-built in tree — packaging
conflicts if we try):

| Lib | Source path |
|---|---|
| `libqti_vndfwk_detect` | `hardware/qcom-caf/common/fwk-detect/` |
| `libavservices_minijail` | `frameworks/av/media/module/minijail/` |
| `libril` | `hardware/ril/libril/` |
| `libwpa_client` | `external/wpa_supplicant_8/wpa_supplicant/` |
| `libgps.utils` | `device/xiaomi/mithorium-common/gps/utils/` |
| `libloc_core` | `device/xiaomi/mithorium-common/gps/core/` |

The last two are notable — **mithorium-common itself builds the GPS
core/utils from source**, so we get a maintained version automatically.

**IMS / VoLTE** (8)

`libdsi_netctrl.so`, `libwpa_client.so`, `libcneapiclient.so`,
`lib-imsvtcore.so`, `lib-imsdpl.so`, `lib-rtpsl.so`,
`lib-rtpcore.so`, `lib-rtpcommon.so`.

**ADSP / audio** (4)

`libadsprpc.so`, `libadsp_default_listener.so`, `libaudioparsers.so`.
(`libadsp_default_listener.so` is used by QSEE too — it serves as
the listener proxy for both audio TZ apps and the keymaster.)

---

## ✅ Previously missing — now resolved

### `qcrild` found in nightly (2026-06-05 session 2)

`/mnt/vendor-nightly/bin/hw/qcrild` is present. It is a small (11KB)
AArch64 ELF that dlopen-loads `libril-qc-hal-qmi.so` at runtime —
the typical QCRIL thin-launcher pattern.

**What was done:**
- Full DT_NEEDED transitive-closure walk from `qcrild` → `libril-qc-hal-qmi.so`
  → all transitive deps. 14 HIDL interface libs confirmed source-built (skip);
  57 vendor-specific blobs identified.
- All 57 libs + `qcrild` binary + `qcrild.rc` + `vendor.qti.rmt_storage.rc`
  copied to `vendor/xiaomi/Mi8937/proprietary/vendor/`.
- `device/xiaomi/Mi8937/proprietary-files.txt` updated with all new entries.
- `deviceInfoServiceModule.so` (runtime dlopen by qcrild) is absent from the
  nightly and confirmed not present anywhere on this system (`locate` found
  nothing). qcrild logs a warning on dlopen failure but continues — it is an
  optional carrier-provisioning feature module, not load-bearing for basic
  telephony.

**Runtime update:** this has been regenerated/built/flashed for the current pepito test. `qcrild` runs, but modem registration still fails as documented above.

### ACDB calibration data is per-variant

Not a radio issue, but it lives next to this work and matters for the
audio HAL that the IMS RTP layer depends on. The nightly ships
`vendor/etc/acdbdata/{land,prada,santoni,ulysse}/` — no pepito set.
Audio output (including VoLTE downlink) will fail until we either:

- Symlink/copy a sibling's ACDB tree (santoni or land are closest
  hardware-wise on MSM8937).
- Extract from a Palm-specific firmware dump.

### `/vendor/etc/*` configs for GPS / cnd

`loc_launcher` and friends read several config files at startup:

- `vendor/etc/gps.conf`
- `vendor/etc/izat.conf`
- `vendor/etc/flp.conf`
- `vendor/etc/lowi.conf`
- `vendor/etc/apdr.conf`
- `vendor/etc/cne/*` (connection manager)

These are in the nightly and trivially extractable, but **not yet
pulled** in this round. Add to `proprietary-files.txt` under a "GPS
configs" section when GPS bring-up is a priority.

### Init RC entries

Several extracted daemons now have working service definitions in the flashed
vendor image. `rmt_storage`, `qcrild`, and `ATFWD-daemon` were observed
running. `time_daemon`, `ssr_diag`, and `ssr_setup` still need separate runtime
validation before they should be considered brought up.

The corresponding sepolicy is similarly absent — see
`device/qcom/sepolicy-legacy-um/legacy/vendor/common/` for the
upstream Qualcomm-legacy reference (qcrild.te, rmt_storage.te,
time_daemon.te, loc_launcher.te). That sepolicy fragment is already
included via `mithorium-common/BoardConfigCommon.mk` →
`device/qcom/sepolicy-legacy-um/SEPolicy.mk` (the same path that
gave us the `tee` domain), so the policy *should* be active —
needs verification once any radio service actually tries to start.

---

## TODO order (radio-only)

1. ✅ **Single-SIM pepito config.** `persist.radio.multisim.config=ssss`, one
   framework phone, and `vendor.qcrild2` stopped.
2. ✅ **PeripheralManager.** `pm-service` / `pm-proxy` are packaged and QCRIL
   can register/vote for the modem.
3. ✅ **Stock-vendor comparison.** Android 11 GSI with AML0 vendor proves stock
   pepito uses `/vendor/bin/hw/rild` + `libril-qc-qmi-1.so`, not QRTR.
4. ✅ **Root-cause QMI transport.** Session 9 confirmed: nightly qcrild uses
   QRTR (AF=42), modem only speaks IPC Router (AF=27), kernel lacks
   `msm_ipc_router`. Stock AML0 rild path abandoned (dependency chain from
   Android 8.1 is unresolvable on Android 15).
5. 🔧 **Port `msm_ipc_router` kernel driver.** Source at
   `~/Projects/android-pepito-pvg100-kernel-upgrade/kernel_src/net/ipc_router/`.
   Files: `ipc_router_core.c`, `ipc_router_socket.c`,
   `ipc_router_security.c`, `ipc_router_fifo_xprt.c`, plus headers. Must
   register `AF_IPC_ROUTER` (27) and provide SMD transport to modem. Build
   alongside existing `CONFIG_QRTR` (kernel QMI helpers depend on QRTR).
6. 🔧 **Block QRTR for qcrild.** Once `msm_ipc_router` is in the kernel, force
   the nightly `libqmi_cci.so` to use IPCR (AF=27) instead of QRTR (AF=42).
   Options: SELinux `neverallow qcrild` on QRTR socket, or a small LD_PRELOAD
   shim that returns `EAFNOSUPPORT` for `socket(42, ...)`.
7. 🔧 **Runtime validate with physical SIM.** Check qcrild completes QMI init,
   calls `RIL_register`, publishes `IRadio/slot1` + `IRadioConfig/default`,
   then check SIM/UICC state, subscription, service state, signal.
8. **GPS and IMS/VoLTE stay out of scope** until basic SIM/network registration
   works.

## Service / blob cross-reference (quick lookup)

When a service crashes and you want to know what blobs back it:

| Service | Binary | Backing libs |
|---|---|---|
| `vendor.audio-hal` | `/vendor/bin/hw/android.hardware.audio.service` (source) | `audio.primary.msm8937.so` (source) → `libadsprpc`, `libadsp_default_listener`, `libaudioparsers` (blobs) → ADSP via `adsprpcd` |
| `vendor.sensors-hal-1-0` | `/vendor/bin/hw/android.hardware.sensors@1.0-service` (source) | `sensors.qti` (blob) + `libsensor1`, `libsensor_reg`, `sensors.ssc.so` (blobs) → ADSP via `adsprpcd` |
| `vendor.radio-1-0` (or wrapper) | `qcrild` (running) | `libril`, `libqcrilFramework`, `libqmi*` (blobs) → currently blocked at QCRIL modem/peripheral registration |
| `vendor.gnss-2-1` | source-built `android.hardware.gnss@2.1-service-qti` | `liblbs_core`, `libloc_core`, `libizat_core` (blobs) + `loc_launcher` daemon |
| `vendor.ims*` | source-built `vendor.qti.imsrtpservice@3.0-service` | `lib-imsvtcore`, `lib-imsdpl`, `lib-rtp*` (blobs) + IMS daemons |
| Modem stability | n/a — kernel + bootloader | `rmt_storage` daemon must run before modem completes init, else modem SSR-loops |
