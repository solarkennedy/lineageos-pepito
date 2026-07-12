# Palm PVG-100 (pepito) Bluetooth Bring-up Plan

**Target:** LineageOS 23.2 / Android 16 on Palm PVG-100 (`pepito`) under the unified `lineage_Mi8937` target.
**Status:** ✅ **CLOSED — Bluetooth works.** Confirmed by the device owner (adapter ON,
`dumpsys bluetooth_manager` → `enabled: true`, `state: ON`, name `PVG100`, `crashed 0 times`;
`lshal` serves `IBluetoothHci/default`). Closing pass 2026-07-08; all changes committed.

---

## Final working configuration

The stack is entirely **source-built** — none of the proprietary QTI Bluetooth blobs
(`android.hardware.bluetooth@1.0-service-qti`, `-impl-qti.so`, `libbtnv.so`, btconfigstore
impls) turned out to be needed.

| Layer | What ships |
|---|---|
| HCI HAL | AOSP HIDL `android.hardware.bluetooth@1.0-service` + passthrough `@1.0-impl` (source-built, `hardware/interfaces`) |
| Vendor library | Source-built CAF `libbt-vendor` (`hardware/qcom-caf/bt`), `BT_SOC_DEFAULT` path selected by `vendor.qcom.bluetooth.soc=pronto` |
| Transport | Kernel SMD packet channels: `/dev/smd2` (ACL), `/dev/smd3` (CMD/EVT), owned `bluetooth:bluetooth` via `ueventd.qcom.rc` |
| Controller power | WCNSS/Pronto is booted by the kernel + `wcnss-service` (shared with WiFi). `BT_VND_OP_POWER_CTRL` is a bookkeeping no-op: it records the state in `vendor.bluetooth.status` and reports success — no hciattach helper, no rfkill (absence of `rfkill0` is expected on this path) |
| BDADDR | Factory-provisioned **raw 6-byte MAC** at `/mnt/vendor/persist/param/btaddr`, pointed to by `ro.bt.bdaddr_path`; the HIDL HAL's `get_local_address()` was taught to accept the binary format. Instance of the PLAN.md Cluster B per-variant `/persist/param` asset pattern (same family as WiFi MAC, sensor conf) |
| A2DP offload | Disabled (`ro.bluetooth.a2dp_offload.supported=false`, `persist.vendor.qcom.bluetooth.enable.splita2dp=false`) — software A2DP only, matching no BT audio DSP path on Pronto |
| AIDL HCI | Intentionally **not** declared. Android 16 probes AIDL first, logs "Could not find android.hardware.bluetooth.IBluetoothHci/default in the VINTF manifest", then falls back to HIDL. The fallback is the design here, not a fragile accident — verified across multiple boots |

### Commits (all landed 2026-07-07/08)

- `device/xiaomi/mithorium-common` **9021138** — package `@1.0-impl`/`-service`/`libbt-vendor`
  + soong namespace; `ro.bt.bdaddr_path=/mnt/vendor/persist/param/btaddr`; sepolicy:
  `hal_bluetooth_default` may read `mnt_vendor_file` (the btaddr file).
- `hardware/qcom-caf/bt` **2533675** — build fixes (fallback defines for the MSM
  `TIOCPM*` ioctls bionic no longer provides; `property_get()` string defaults).
- `hardware/qcom-caf/bt` **ff4599a** — Pronto/SMD functional port: POWER_CTRL no longer
  forks the (nonexistent) hciattach helper; termios ioctls on SMD nodes downgraded from
  fatal to warnings (`cfmakeraw` applied only when `tcgetattr` works, i.e. real UARTs).
- `hardware/interfaces` **dcc9508** — `bluetooth_address.cc`: accept a raw binary 6-byte
  BDADDR file (exactly-6-bytes-and-nonzero heuristic; string-format devices unaffected).

### Expected log noise (harmless, by design)

- `servicemanager: Could not find android.hardware.bluetooth.IBluetoothHci/default in the
  VINTF manifest` (and `.ranging.IBluetoothChannelSounding`) — AIDL probe before HIDL fallback.
- `[smd_pkt_ioctl]: unrecognized ioctl command 0x540b / 0x5401` — the HAL's tcflush/tcgetattr
  attempts on `/dev/smd3`; now nonfatal in `libbt-vendor` (logged there as warnings).
- The `serial.log.19` "WCNSS SOC_RESET during boot" scare was a **logging bug** (missing
  index-4 entry in `wcnss_subsys_notif_type[]` shifted every event name ≥ 4 by one; the real
  events were a healthy powerup). One-line kernel string fix landed; analysis in `PLAN-wifi.md`.

### Answers to the formerly open questions

- **Palm A8 tree / QTI service blobs?** Not needed — source-built HIDL service + CAF
  `libbt-vendor` is the shipping config. The aspirational QTI blob entries in
  `proprietary-files-qc-vndr.txt` were never satisfiable from the Mi8937 nightly extraction.
- **BDADDR source?** `/mnt/vendor/persist/param/btaddr` (binary). No `libbtnv.so`, no modem-NV
  path required.
- **rfkill0?** Expected absent: Pronto/SMD Bluetooth has no rfkill; only WLAN `rfkill1` exists.

---

## Remaining for production (tracked, not blockers)

1. **Profile validation matrix** — adapter power-on and general use are owner-confirmed;
   run the full matrix once before release:
   pair (headset + phone/computer), A2DP playback, HFP call audio (telephony is now live —
   see `PLAN-radio.md`/qmux lane), BLE GATT scan, on/off ×5, suspend/resume, bond survives
   reboot.
2. **SELinux** — device currently runs Permissive (global bring-up diagnostic). The one
   BT-specific rule (btaddr read) is already in `hal_bluetooth_default.te`; re-verify BT under
   Enforcing during the global sepolicy pass (watch for `vendor.bluetooth.status` property-set
   denials from `hal_bluetooth_default`).
3. **A2DP offload stays disabled** — revisit only if software A2DP proves too costly; see
   `PLAN-audio-offload.md`.

---

## Historical narrative (archived 2026-07-08)

Path to the fix, for the record. Original framing was "Bluetooth cannot turn on."

1. **No HCI HAL in the image.** The framework tried AIDL (`not declared`), fell back to HIDL,
   found `@1.0::IBluetoothHci/default` in the VINTF manifest but no service binary behind it
   (`ctl.interface_start` failed), and aborted after 1000 ms. The vendor extraction never
   produced the proprietary QTI service the blob list expected. Fix: package the source-built
   AOSP HIDL service + passthrough impl + CAF `libbt-vendor` (Phase 1 as planned).
2. **BDADDR abort.** With the HAL registered, `libbt-vendor` aborted for want of an address.
   Stock Palm provisions a binary MAC at `/mnt/vendor/persist/param/btaddr`; taught the HAL to
   read it (Cluster B pattern).
3. **Pronto power-on path.** `BT_SOC_DEFAULT` expected the legacy hciattach helper
   (`hw_config()` + status-property poll) that doesn't exist on this tree; bypassing it
   (initially by hand-forcing `vendor.bluetooth.status=on`) let USERIAL_OPEN proceed, which
   then died on `tcflush(/dev/smd3)` — the 4.19 `smd_pkt` driver rejects termios ioctls.
   Made POWER_CTRL a success no-op and termios nonfatal.
4. **Second flash test (2026-06-11): BT ON.** Later `serial.log.19` review (2026-06-29) raised
   three scares: (a) WCNSS SOC reset — retracted, logging off-by-one; (b) AIDL HCI missing from
   VINTF — expected, HIDL fallback is the design; (c) smd_pkt ioctl rejections — the known,
   now-nonfatal termios calls. Owner re-confirmed working BT on current builds; closed.

Diagnostic snippets, the phase-by-phase debug tables, and the original failure log walk-through
from pre-2026-07-08 revisions of this file were dropped in the closing pass; the substance is
all captured above, and the shipped code changes are self-documenting in the four commits.
