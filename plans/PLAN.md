# Palm PVG-100 (pepito) — LineageOS 23.2 Bring-up Plan

**Target:** LineageOS 23.2 (Android 16) on Palm PVG-100 — MSM8940 (Snapdragon 435) + Adreno 505 + PM8937 + PMI8950.
**Strategy:** pepito as a runtime-detected variant of `device/xiaomi/Mi8937` (Lineage / Mi-Thorium unified MSM8917/8937/8940 tree). Source-built HALs sidestep the stock-A8-blob ABI gap that killed the old A11/4.9 attempt.
**Kernel:** `android_kernel_xiaomi_msm8937`, base `342a6915cdaa…` (Linux 4.19.325). Working branches: `pepito-rmnet` (stacked on `pepito-qmux`) across kernel + both device repos.
**Build target:** `lunch lineage_Mi8937 bp4a userdebug`.

This file is the **map**: current status, the cross-cutting model, and pointers. Detail lives in the per-subsystem `PLAN-*.md` files indexed below — update those, not this.

**Where we are (2026-08-22): THE PHONE IS A DAILY DRIVER.** The entire telephony chain closed in July (modem 07-07, SIM/LTE/data 07-09, VoLTE/IMS + in-call audio 07-10), SELinux went Enforcing 07-11, and the two months since have been quality + reliability lanes: **Wi-Fi calling SOLVED end-to-end 2026-08-09 incl. the fresh-unit fix 2026-08-21** (one modem-NV field, `ps_sys_data_configurations.txt` field4=1 — productize = write it at boot; `PLAN-vowifi.md`), modem diag on A16 (`diagchar.modem_socket_diag` gate, `dec80a40f8fd`), perf lane (interaction/launch boosts, GPU-floor toggle, zram default **reversed to lz4** 08-22 after the zstd-lmkd-kills finding), hw-accel audit (Widevine L1, MDP overlays), PVG100E variant support. What remains is **release productization** (`PLAN-release.md`: commit sweeps, personal remotes + push, signing, FRP `config` zeroing, BUILD.md/release notes), essentially just that. (NAS slow re-attach — the "emergency calls only" root — was **root-caused + fixed + flash-validated 2026-08-23**, committed `18771530`; WFC field4 productization done + validated 08-22 via `wfc_efswrite`, `a534b4aa`; tethering bench-validated ships-as-is 08-22; wired Android Auto confirmed fully working.)

---

## The multi-device methodology — core operating philosophy

⚠️ Bench roles have churned since bring-up — **always verify `ro.serialno` first** (memory `dut-tcp-adb`). State as of 2026-08-23:

| Device | What it is | Role |
|---|---|---|
| DUT1 `c39a6acf` (`android16-adb`, 10.0.2.157) | Our LineageOS 23.2 build (4.19.325, source-built HALs). Root-adb; persistent root init hook. | **The target (DUT)** — also the proven-WFC unit (accumulated modem NV). |
| Gold `81eed371` | Second PVG100, our A16 gapps build. | **Fresh-unit / daily-driver witness** — catches "works on DUT via accumulated state" gaps (e.g. the WFC field4 find). ⚠️ Hardware quirks: aged battery + flaky USB (magnetic-tip pogo pins) — not ROM bugs. |
| Silver `4373dd0f` | Stock kernel + vendor, A11 GSI on top (since 2026-08-04). Root-adb. | **Kernel/hardware ground truth + modem-diag capture rig** (`diag-tools/HOWTO-modem-diag-capture.md`). ⚠️ The live stock 8.1 witness is **gone** — Silver was reflashed; stock EFS banked. |
| `2103dc19` (gifted 4th unit) | US PVG100, 2018 factory firmware. | Spare / potential future stock witness (2018 tz/keymaster unvalidated); pre-wipe backup banked 2026-08-18. |

**The rule:** when a subsystem fails on A16, the question is never "how should this work?" — it is **"how does it already work on stock?"** During bring-up that meant querying the live stock 8.1 device; today stock answers come from Silver's stock kernel+vendor, the banked stock backups/EFS, and the archived captures — not by guessing from Mi8937 source or archived kernels. This philosophy closed the modem saga: the winning move was backporting the stock legacy IPC stack wholesale (black-box convergence), not deeper RE.

**Reference sources:**
- Stock Palm GPL kernel source: `/home/kyle/Projects/Pepito_GPL_SourceCode` (`kernel/msm-3.18/`; incomplete — BHy driver source withheld).
- Stock DTB decompiled in-repo: [`dts-3.19-pepito/pepito.dts`](dts-3.19-pepito/pepito.dts) (authority for "how is this node wired"); [`dts-4.9-pepito/`](dts-4.9-pepito) (archived porting attempt, secondary); our tree at [`kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito.dts`](kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito.dts).
- Stock 8.1 vendor is pullable off Silver's stock partitions (fingerprint `Palm/PVG100/Pepito:8.1.0/…/v1AML-0`); full stock backup tree at `backup-stock-android-8.1-AML0/`.

---

## Status snapshot (bring-up era, 2026-07; all rows since held or improved — see index + memory for post-July lanes)

Boot, display, touch, hardware keymaster, and the full UI have been solid since 2026-06. Current per-subsystem state:

| Subsystem | State | Detail |
|---|---|---|
| Boot → UI, rooted ADB, `sys.boot_completed` | ✅ | Historical narrative: `PLAN-userspace.md`, `PLAN-surfaceflinger.md` |
| Display / touch / backlight | ✅ | `PLAN-touchscreen.md`, `PLAN-surfaceflinger.md` |
| Keymaster / gatekeeper / TEE keygen / FBE | ✅ 2026-07-08 | ALL hardware-backed and validated: Brillo 17/17 hw-enforced, HW gatekeeper live, `/data` FBE (aes-256-xts, fscrypt v2) proven across reboot. Root causes: spurious Auto-CMD12 on RPMB writes + RPMB empty-slot bug (kernel `057578098068`, `9d51b9a359b3`) + fstab FBE (`7dd66f51`). Production-prep done (mirror retired, sepolicy committed incl `8820ac75`). Parked: SIM-PIN auto-verify (-29 TA buffer limit). Dropped per Kyle: metadata encryption, attestation. `PLAN-gatekeeper.md` |
| Wi-Fi | ✅ | `PLAN-wifi.md` |
| Bluetooth | ✅ 2026-07-08 | All-source-built stack; binary BDADDR seeded from `/mnt/vendor/persist/param/btaddr`. Remaining: profile matrix pass + Enforcing re-check. `PLAN-bluetooth.md` (body stale) |
| Sensors — all 20 h/w sensors, live data | ✅ SSC regression CLOSED 2026-07-11 — autonomous cold boot 20/20 under Enforcing | RPR0521 ×4 via SSC/SMGR + 16 Bosch via BHy. ⭐ 7/05 cleanup had removed the load-bearing stock registry daemon (Palm's ADSP SMGR reads its registry from AP-hosted QMI services); daemon + real-`/persist`/bind-mount restored and flash-validated. Fixes UNCOMMITTED — fold into release sweep. `PLAN-sensors.md`, `PLAN-bmi160b.md` |
| Camera — both cams, preview + JPEG | ✅ 2026-07-03 | Source-built `camera.pepito` HAL. FD 640×480-subst staged (`persist.vendor.camera.analysis.subst=0` disables), needs face test. `PLAN-camera.md` |
| Audio — speaker | ✅ 2026-07-07; ACDB ✅ 2026-07-11 | Full NXP TFA9896 smart-amp bring-up (kernel `e6daf888` + device `14cffd49`). MBHC false-"Wired headphones" fix valid. ACDB solved: loader was never shipped (format theory false) — nightly libacdbloader closure staged, Palm's stock cal engages, live-validated. `PLAN-audio.md`; offload disabled per `PLAN-audio-offload.md` |
| **Modem transport** (the multi-year `rmts_get_buffer` fatal) | ✅ **SOLVED 2026-07-07** | Root cause was the **AP transport stack**: modem needs the legacy IPC router, not QRTR. Backported stock stack wholesale (msm_ipc_router + rpmsg xprt + msm_qmi_interface + RFSA/memshare + A8 rmt_storage, branch `pepito-qmux`) → fatal gone, 36 modem QMI services up. `PLAN-qmux.md`; evidence `diag-tools/captures/qmux-WIN-20260707/` |
| **Telephony — SIM/LTE registration** | ✅ 2026-07-07, cold-boot 2026-07-08, productionized 2026-07-10 | No bridge daemon needed: A15 `libqmi_cci` has a native ipcr backend; the ~10-line `libqmi_force_ipcr.so` LD_PRELOAD fails its QRTR probe → qcrild on ipc_router → **SIM LOADED, Verizon, LTE**. Now default-on statically (kernel xprt auto-enable + libinit `ro.vendor.qmux.enable`; flip script retired — awaiting validation flash). `PLAN-qmux-bridge.md` |
| **LTE attach** | ✅ holding stable 2026-07-09 | Two stacked gates, both addressed: voice-centric domain selection vetoing VoLTE-only 311480 (→ NAS `usage_preference=2` written to modem NV via `diag-tools/nas-probe/`; **restore usage=1 after IMS registers**) + the IPA modem-crash loop (fixed in `pepito-rmnet`). Memory: `attach-domain-selection`. |
| **Mobile data** | ✅ 2026-07-09, clean-boot validated | Attach + `DataConnectionState=CONNECTED` + ping over Verizon LTE, fully autonomous from cold boot. IPA QMI reverted to msm-qmi (`670dc321` donor) + resp-EI offset fix `a7fe9caab692`; nightly netmgrd as `qmux_netmgrd`; librmnetctl source-built; shim `unsetenv`s LD_PRELOAD. Remaining: sepolicy pass; ipacm only for tethering; cosmetic early-boot rmts blip. `PLAN-rmnet.md` |
| GPS | ✅ 2026-07-08 | gnss HAL preloads force-ipcr → QMI_LOC (svc 16) on ipc_router; satellites found indoors. `PLAN-gps.md` |
| **VoLTE / IMS** | ✅ **SOLVED + PRODUCTIONIZED 2026-07-10** | **Calls connect BOTH WAYS + SMS both ways on Verizon.** Root cause: 2017 modem speaks only v01 IMSS (A15 qcril is v02-only — enable could never arrive) + modem NV `ims_test_mode=1`. Fixed with two live v01 QMI writes. Productionized: NV proven reboot-persistent, usage=1 voice-centric restored + holds through radiocycle, `ims_enabler` self-heal oneshot staged (enforcing-ready sepolicy) + bench-validated incl. virgin-unit heal — awaiting validation flash. **In-call AUDIO dead → the audio lane's top item** (`PLAN-audio.md`). GUARDRAIL: never run extract-utils regen on mithorium-common. `PLAN-volte.md` |
| SELinux | ✅ **ENFORCING** 2026-07-11 | Cold-boot validated with full matrix green; skip-list-only denials. LD_PRELOAD→DT_NEEDED shim redesign was the load-bearing fallout (`PLAN-release.md` Phase 5, memory `selinux-enforcing-prep`). |
| Face unlock | ✅ 2026-07-12 | Paranoid Sense port (Megvii RGB engine, WEAK class) — real enrollment + keyguard unlock validated on DUT. Remaining: commit sweep + release-notes caveats. `PLAN-face-unlock.md` |

---

## Holistic model — retrospective (three clusters, all resolved or reduced)

(2026-06-26 analysis; kept because it was the map and its post-mortem is instructive.)

- **Cluster A — QMI platform-services layer: SOLVED.** The residual "modem `rmts_get_buffer` fatal" turned out to be AP-side after all — but one level below every hypothesis tested: the **transport protocol engine itself** (QRTR vs legacy msm_ipc_router). All the "falsified AP hypotheses" (`PLAN-radio.md`, `PLAN-tz.md`, `PLAN-sharedmem_qmi.md`, `PLAN-qrtr.md`, `PLAN-diag.md`) compared *content presented over QRTR*; the qmux backport (`PLAN-qmux.md`) swapped the engine and the modem came up. Lesson recorded in [`feedback-blackbox-before-re`]: don't declare a hypothesis space closed on static evidence alone.
- **Cluster B — pepito as second-class variant; per-variant assets never populated.** Systematically swept: sensors conf, GPS `izat.conf`, radio manifest, BDADDR, ACDB (partially — format issue remains), `/vendor/modem_config` MBNs (staged from stock A8). The sweep rule stands for stragglers: for every `=<sibling>` branch/asset, ask "does pepito have the equivalent?"
- **Cluster C — stock A8 blobs on the 4.19 kernel (ABI gap): retired by source-building.** Camera, Bluetooth, and audio all went source-built; the RPMB/keymaster chain was fixed in-kernel. No remaining subsystem depends on an A8 vendor blob against a mismatched ABI. (The telephony/data lane uses **nightly** A15 blobs + the force-ipcr shim instead — provenance rules in memory `build-and-vendor-notes`.)

---

## PLAN file index

**Active:**
- [`PLAN-android17.md`](PLAN-android17.md) — 🆕 **LineageOS 24.0 / Android 17 upgrade plan (drafted 2026-09-10, nothing synced yet).** Upstream already carries Mi8937 on `lineage-24.0` (7 commits, kernel identical); gaps = `hardware/qcom-caf/bt` dropped from the 24.0 manifest, NikGapps has no A17 pack, two-tree strategy + rebase inventory in file.
- [`PLAN-androidauto.md`](PLAN-androidauto.md) — 🚗 wired Android Auto — ✅ **FULLY WORKING (confirmed in-car 2026-08-23).** App layer solved + baked in (preinstalled stub → error 22 gone, no cert/GSF needed, nearby-perm, typec HAL reverted to basic); the accessory-mode USB-suspend flap no longer blocks. Remaining: assistant-role fix is STAGED (`aa-voice-assistant-role`); AA stub baked into pepito-gapps per release sweep.
- [`PLAN-integrity.md`](PLAN-integrity.md) — ✅ **RESOLVED 2026-07-27 — unfixable from the ROM.** The long-standing `-12` is **not an integrity failure**: DroidGuard and hw attestation both succeed, then `fdfe/integrity` returns **HTTP 500** server-side — we have never been graded. TEE RootOfTrust binds to the boot chain, so no ROM-side change can alter the verdict. Lane closed; kept as evidence.
- [`PLAN-perf-battery.md`](PLAN-perf-battery.md) — CPU/GPU/IO/thermal/battery tuning. ⭐⭐ Responsiveness lane 2026-08-02: QTI perf HAL was never packaged — interaction/launch/camera boosts all dead since bring-up; fixed+committed (Enforcing leg re-validated 08-22), plus 0.5× animation defaults. ⭐⭐ zram default **reversed zstd→lz4 2026-08-22** (zstd made lmkd kill apps lz4 rides out — root of the "laggier than A11" feel; committed `0b5f29a`/`2add886`). GPU-floor perf toggle built+committed (`73b5952`/`c921c91c`); CPU-floor/cpuidle candidates rejected on bench.
- [`PLAN-hw-accel.md`](PLAN-hw-accel.md) — acceleration audit, **~DONE — all flash-validated 2026-08-03**: Widevine **L1**, MDP5 overlay composition, idle-storm fix, OpenCL 2.0, offload re-enable (⭐ libsdmextension needs its dlopen'd libscalar+libhdr_tm or the composer crash-loops black). Offload leg closed 08-22 (direct AudioTrack probe — apps never request offload); ipacm/IPA tether offload downgraded to someday (BPF offload engages, see tethering TODO). Remaining: CT-3 A/B only.
- [`PLAN-blocker.md`](PLAN-blocker.md) — new lane (2026-08-03), not blocking: ship Blocker (per-component activity/service/receiver/provider control) working **without root or Shizuku**, by rebuilding it platform-signed in the system UID. ⭐ Upstream's root paths are a pure transport wrapper — the command bodies are already in-process framework/file calls — so the app patch is a 6-file transport swap. ⚠️ `/data/system/ifw` needs its **own** sepolicy type: `app.te`'s `neverallow appdomain system_data_file:… { create write }` has no exemption list, so no app domain can ever be granted the default label. ✅ **FLASH-VALIDATED 2026-08-03** — rules written under `ifw_data_file`, enforcement proven (`am start` → 102 `START_ABORTED`), no denials. PM backend proven too (VLC → `enabled=3`, Launcher drops the icon). ⚠️ `IntentFirewall Read new rules (A:0 B:0 S:0)` counts intent filters only and is NOT a failure. Remaining: rule-assets rebuild (staged, unflashed).
- [`PLAN-battery-health.md`](PLAN-battery-health.md) — new lane (2026-07-17), not blocking: kernel nodes to populate the Android 16 Battery Health surface (state-of-health %, cycle count, design capacity) the health HAL reports null today. Kernel-only (HAL auto-detects); Surface A charge-limits already work, chargingPolicy is a dead end.
- [`PLAN-sunlight.md`](PLAN-sunlight.md) — sunlight readability (stock SVI → LiveDisplay "Automatic outdoor mode"): ✅ **FLASH-VALIDATED 2026-07-28.** Kernel `fb0/sre` node programs a gamma-0.62 curve into the DSPP hist-LUT (the block stock's mm-pp-dpps drove); `enable_se` in Mi8937/device.mk; the fb0/hbm `chmod 0000` is doubly load-bearing — it steers the HAL probe past the dead fb0/hbm to `sre` (probe race, memory `sunlight-sre-lane`). Remaining: outdoor acceptance pass + commit sweep.
- [`PLAN-esim-lpa.md`](PLAN-esim-lpa.md) — new lane (2026-07-30), not blocking: live on-device profile switching for the removable eSIM adapter card in the tray. ⭐ Direct QMI-UIM APDU is **refused by the modem** (ACCESS_DENIED 82, all encodings — new `nas-probe isdr`); the route is a **platform-signed privileged LPA** driving the telephony APDU path through qcrild. 🔴 **CLOSED 2026-07-30: blocked in modem firmware.** PrivilegedOpenEUICC now ships (in-tree source build, platform-signed, pepito-gated) and works end-to-end up to the card — but the modem refuses logical-channel opens to the **ISD-R AID specifically** (RIL 54 `OPERATION_NOT_ALLOWED` = QMI `ACCESS_DENIED` 82), even from qcrild, while opening ARA-M fine. 2017 MPSS predates SGP.22; no ROM-side fix exists. ⭐ Practical alternative: drive the USB-CCID reader from the phone over OTG (untested).
- [`PLAN-mcfg.md`](PLAN-mcfg.md) — **Phase 0 done 2026-07-30, delivery work PARKED** (modem already runs stock's v1.4 MBN set; our qcril's own MBN pipeline works, per-ICCID). Residual question: does CDMAless-Verizon carry OOS-scan-timer items at all. Band analysis (`diag-tools/mcfg-lane/BANDS-ANALYSIS.md`) already exonerates band capability: Verizon uses 5/5 of our LTE bands. ⭐⭐ **2026-08-12 REOPENS this as an important reliability lane (memory `nas-slow-reattach`):** the ~95 s cell-edge recovery is NOT hard-coded modem behavior — it's REPRODUCED on the DUT as a **slow AP-side NAS re-attach** (airplane/RF-drop → ~40-90 s stuck `NOT_REG_SEARCHING` / "Emergency calls only", **`rejectCause=0`** = network not rejecting), and **stock A8 on the SAME modem recovers in seconds** ⇒ our NAS/OOS-scan-timer, fixable. This is the root of Gold's frequent "emergency only" sessions (long dismissed as low signal). Kyle rates it above VoWiFi. ⭐ **DIAG capture now works on A16** (`diag-tools/diag-a16-shim/`); F3 decode blocked on the QSR4-GUID handshake. Next: fix the decode or capture stock A8's fast recovery on Silver + diff.
- [`PLAN-vowifi.md`](PLAN-vowifi.md) — 🎉 **SOLVED 2026-08-09 (part 40): a real Wi-Fi call CONNECTED on the A16 ROM.** Telecom `callProperties:[wifi]` + `SET_ACTIVE`, bidirectional ePDG IPsec tunnel to Verizon (`141.207.209.233`), ~1,450 RTP pkts through `r_rmnet_data0` (UP; was DOWN), IWLAN registered HOME, carrier = "Verizon Wi-Fi Calling". The winning combo: **real A16 ROM** (full IMS + VZW carrier config) + **legacy-IWLAN RRO live** (`config_qualified_networks_service_package` empty + `iwlan_operation_mode=legacy`) + **gate armed** IMSS `0x53 0x15=1`→`0x16=1` (EFS-persistent, survived the flash) + **WFC on** (WIFI_PREFERRED) + DSD `0x13=1`/`0x20` (probes need `LD_PRELOAD=…/libqmi_force_ipcr.so`) + Wi-Fi connected. The entire circular-dependency framing that defined parts 9–33 was mooted once `0x15=1` opened the gate (part 34) and the pivot to the real ROM (part 39→40) supplied the reverse-rmnet path. 🎉 **Fresh-unit gap CLOSED 2026-08-21 (part 46):** Gold's failure was ONE modem-NV field — `ps_sys_data_configurations.txt` field4=1 (the DUT had accumulated it; fresh units ship 0); writing it gave Gold IMS-SMS over IWLAN under airplane. ⚠️ airplane-cycling wedges this modem (reboot recovers) — NEVER-airplane-cycle rule in memory `wifi-calling-lane`. ⭐ **DIAG on A16 works** via `diag-tools/diag-a16-shim/`. ✅ field4 productized 08-22 (`wfc_efswrite` oneshot, part 47, committed `a534b4aa`) — lane DONE.
- [`PLAN-wifi-calling.md`](PLAN-wifi-calling.md) — the VoWiFi **evidence archive** (parts 1–18): every hypothesis and how it was killed, tooling ground truth, captures index. Read it to learn *why* something is ruled out; do not plan from it.
- [`PLAN-release.md`](PLAN-release.md) — ⛳ the release tracker: qmux productization (committed `qcrild.rc`, qmux default-on, cold-boot ordering), Enforcing, clean/pushed branches, signing keys, BUILD.md. Update checkboxes there.
- [`PLAN-aboot.md`](PLAN-aboot.md) — bootloader security posture (old/frozen LK aboot, VB1.0, ships unlocked; integrity enforced above aboot by dm-verity/FBE). Open: secure-boot fuse state, MDTP state. RE lane (`~/Projects/aboot-re/`) parked — assessment only.
- [`PLAN-rmnet.md`](PLAN-rmnet.md) — data ✅; remaining: sepolicy pass, ipacm (tethering only), early-boot rmts blip.
- [`PLAN-audio.md`](PLAN-audio.md) — speaker ✅; ACDB ✅ 2026-07-11 (loader was missing, not a format issue; staged, uncommitted).
- [`PLAN-camera.md`](PLAN-camera.md) — ✅ works; finish-line: face-detect subst validation. Archive: `PLAN-cameras.old.md`.
- [`PLAN-kernel.md`](PLAN-kernel.md) — kernel-tree change audit: what to commit, revert (incl. the now-safe SSR-panic downgrade), or relocate.
- [`PLAN-misc.md`](PLAN-misc.md) — papercuts (SIM-slot UI, nav buttons, ramoops, scrcpy, volume tile, removable-storage filesystems).
- [`PLAN-pvg100isms.md`](PLAN-pvg100isms.md) — feature wishlist (Life Mode, face unlock, launcher, volume slider); [`PLAN-lifemode.md`](PLAN-lifemode.md) — Life Mode QS tile; [`PLAN-face-unlock.md`](PLAN-face-unlock.md) — ✅ 2026-07-12 working on DUT (Paranoid Sense/Megvii); remaining: commit sweep + release-notes caveats.

**Solved lanes (kept as evidence — the telephony endgame reads in this order):**
- [`PLAN-volte.md`](PLAN-volte.md) — ✅ SOLVED + PRODUCTIONIZED 2026-07-10 (v01 QMI writes, EFS-persistent; see status table).
- [`PLAN-qmux.md`](PLAN-qmux.md) — ⭐ the legacy IPC-stack backport that killed the `rmts_get_buffer` fatal (2026-07-07). Formally reversed the "do NOT port msm_ipc_router" guardrail.
- [`PLAN-qmux-bridge.md`](PLAN-qmux-bridge.md) — ⭐ SOLVED with no bridge: `libqmi_force_ipcr` transport-probe override → live telephony + cold-boot flip design.
- [`PLAN-gps.md`](PLAN-gps.md) — ✅ 2026-07-08 via the same preload.
- [`PLAN-gatekeeper.md`](PLAN-gatekeeper.md) — ✅ full RPMB/HW-gatekeeper/TEE/FBE chain, production-prepped.
- [`PLAN-radio.md`](PLAN-radio.md) — the radio1–14 fatal chronicle, superseded by qmux. Archives: `PLAN-radio.old.md`, `PLAN-radio.old2.md`. Satellites, all superseded the same way: [`PLAN-radio-rfsa-qrtr.md`](PLAN-radio-rfsa-qrtr.md) (the last root-cause lane), [`PLAN-radio-config-leads.md`](PLAN-radio-config-leads.md) (untested brainstorm), [`PLAN-modem-disasm.md`](PLAN-modem-disasm.md) (Ghidra Hexagon setup survives for future RE), [`PLAN-radio-compat.md`](PLAN-radio-compat.md) (HIDL→AIDL shim — moot, telephony works end-to-end without it).
- [`PLAN-mbn-loader.md`](PLAN-mbn-loader.md) — PDC MBN-activation tool; mooted (modem EFS already carried CDMAless-Verizon; the attach gate was domain selection + the IPA crash loop).
- [`PLAN-sensors.md`](PLAN-sensors.md) ✅ (+ `PLAN-bmi160b.md` BHy hub, `PLAN-sensors.old.md`).
- [`PLAN-wifi.md`](PLAN-wifi.md) ✅, [`PLAN-bluetooth.md`](PLAN-bluetooth.md) ✅ (body stale), [`PLAN-touchscreen.md`](PLAN-touchscreen.md) ✅, [`PLAN-surfaceflinger.md`](PLAN-surfaceflinger.md) ✅, [`PLAN-audio-offload.md`](PLAN-audio-offload.md) (offload disabled, workaround confirmed).
- [`PLAN-tz.md`](PLAN-tz.md) — TZ/`hyp_assign` **falsified**; [`PLAN-sharedmem_qmi.md`](PLAN-sharedmem_qmi.md) — in-kernel RFSA port (part of the radio evidence chain); [`PLAN-qrtr.md`](PLAN-qrtr.md) — QRTR enumerator tooling; [`PLAN-diag.md`](PLAN-diag.md) — DIAG-to-modem dead on the DUT (use the A11 capture runbook instead); [`PLAN-modem-ramdump-capture.md`](PLAN-modem-ramdump-capture.md) — not viable (XPU).
- [`PLAN-props.md`](PLAN-props.md) — A16-vs-A11 property diff (2026-06-29 snapshot); [`PLAN-userspace.md`](PLAN-userspace.md), [`PLAN-recovery.md`](PLAN-recovery.md) — early boot-issue trackers, historical.

**Reference:**
- [`PLAN-vendor-extract.md`](PLAN-vendor-extract.md) — how to extract blobs from a nightly vendor.img (DT_NEEDED closure walk, extractor modes, packaging conflicts).
- [`PLAN-postmarketos-redmi4x.md`](PLAN-postmarketos-redmi4x.md) — pmOS msm89x7 links; sources + findings in `postmarketos-redmi4x/`.

---

## Architecture — multi-variant + layering

Runtime selection: DTS root `compatible = "xiaomi,pepito"` → `techpack/xiaomi-msm8937/mach/mach_detect.c` → `/sys/xiaomi-msm8937-mach/codename` → `device/xiaomi/Mi8937/libinit/init_xiaomi_mi8937.cpp::determine_device()` → `ro.product.*` props. Pepito lands under `lunch lineage_Mi8937` (MSM8937/8940 + Adreno 505: ugg, land, santoni, prada, pepito); Mi8917 is the other target.

**Layering rule: push every change as deep as possible without breaking sibling variants.**

| Scope | Affects | Rule |
|---|---|---|
| AOSP (`system/`, `frameworks/`, …) | everyone | Don't edit; `repo sync` clobbers. |
| `device/xiaomi/mithorium-common/` | whole family | Only if true for every variant. |
| `device/xiaomi/Mi8937/` | the 5 Adreno-505 variants | Only if shared across them. |
| Pepito-only | PVG100 | No dedicated dir: use `pepito.dts`, `on property:ro.vendor.xiaomi.device=pepito` rc triggers, libinit branch, or `TARGET_DEVICE_PEPITO` mk gates (**exists and is in use** — see the pepito block in `Mi8937/device.mk`). |

**Bring-up debt (landed one scope too shallow; will conflict on repo sync / break sibling builds):** Palm branding in `lineage_Mi8937.mk`; static-partition layout forced in `BoardConfig.mk`/`device.mk`/`fstab.qcom`. (The qmux staging is no longer debt: as of 2026-07-10 it is pepito-gated at runtime — kernel machine-compat auto-enable + libinit `ro.vendor.qmux.enable` — and inert on siblings.) The old software-gatekeeper debt items are resolved (HW gatekeeper landed with committed device sepolicy — `PLAN-gatekeeper.md`). Fix the rest by moving them under the **existing** `TARGET_DEVICE_PEPITO` gate (the gate itself is done — PepitoLauncher2/PepitoWallpapers/VolumeTile/OpenEUICC already ship behind it; what remains is re-scoping the branding + partition items into it). Kernel-side debt is audited in `PLAN-kernel.md`; repo/branch/push state in `PLAN-release.md`.

---

## Confirmed pepito-specific DTS overrides

`pepito.dts` + `xiaomi-msm8937/pepito/*`. Authority for any "is this node right?" question: diff against the stock DTB [`dts-3.19-pepito/pepito.dts`](dts-3.19-pepito/pepito.dts).

| Override | Reason |
|---|---|
| include `msm8940-pmi8950.dtsi` (not pmi8937); root compatible `qcom,msm8940-pmi8950 … xiaomi,pepito` | Companion PMIC is PMI8950 (pmic-id 0x20011); pmi8950 fragment wires LAB/IBB for FT8613. |
| `&i2c_2 { status = "disabled" }` | Vestigial bus; i2c-msm-v2 hangs in BAM/AXI voting if probed with zero children. |
| `&other_ext_mem reg = <0x0 0x84A00000 0x0 0x1E00000>` | **§A, flash-verified.** Palm's stock TZ xPU-protects the full 30 MiB; the Mi8937 13 MiB default let `populate_rootfs` write into protected DRAM → silent PS_HOLD reset. |
| `pepito/touchscreen.dtsi`: `focaltech,fts_ts @ i2c_3 0x38` | Real controller is FocalTech FTS (prior Atmel decl was copy-paste). |
| `pepito/display.dtsi` + `pepito/panel/dsi-panel-ft8613-720p-video{,-v2}.dtsi` | FT8613 power table, DSI PHY LDO mode, single-DSI; panel timings ported from 4.9 (bootloader selects the `_1280p` v2). |
| `pepito/battery_usb.dtsi` | Palm charger/FG/JEITA tuning, WLED 17.8 V 3-string, batterydata (itech 3000 + ascent 3450 + BYD-default-pepito). |
| `pepito/pinctrl.dtsi`, `pepito/gpio-keys.dtsi` | Vol-up key + touch pinctrl. |
| Audio: i2c_6 + quat-mi2s pinctrl, TFA9896 nodes | Smart-amp bring-up (kernel `e6daf888`). See `PLAN-audio.md`. |

Non-DTS half: `CONFIG_MACH_XIAOMI_PEPITO=y` (`mi8937.config`), mach_detect table entry, libinit `pepito_info` branch — all in place.

Resolved boot-era history (keep for archaeology, all ✅): **§A** `other_ext_mem` (above); **§B** `clock_late_init` PS_HOLD — fixed by `CONFIG_USE_COMMON_CLK_MSM` (downstream MSM clock framework); **§C** vendor-blob closure bring-up (qseecomd lib closure → keymaster; Adreno shader-compiler blobs → SurfaceFlinger; ~70 blobs staged — method in `PLAN-vendor-extract.md`); RPMB char→block node + legacy ioctl regression (`PLAN-gatekeeper.md`); GPU CP-microcode downgrade regression (`PLAN-surfaceflinger.md`).

---

## Outstanding TODOs

**Critical path (calls, then ship):**
- [x] **VoLTE/IMS registration** — ✅ SOLVED+VALIDATED+PRODUCTIONIZED 2026-07-10 (v01 `ims_test_mode=0` + qipcall writes; calls+SMS both ways). Reboot persistence proven (NV is EFS-backed, IMS re-registers autonomously); `ims_enabler` self-heal boot oneshot staged with enforcing-ready sepolicy and bench-validated incl. the virgin-unit heal path — awaiting validation flash (`PLAN-volte.md`).
- [x] **In-call audio** — ✅ WORKING, validated live 2026-07-10: voice mixer paths → QUAT/TFA9896, earpiece via reconstructed `TFA9896 Rec GPIO` kcontrol, and the decisive `audio_platform_info_intcodec.xml` rename (HAL never read the base filename → wrong voice PCM id 44 vs 34). Staged, uncommitted. Quality follow-ups in `PLAN-audio.md`.
- [x] Restore NAS `usage_preference=1` (voice-centric) — ✅ DONE 2026-07-10: restored via nas-probe and validated through a radiocycle (clean PLMN selection + attach) → attach + IMS + SMS/VoIP all hold voice-centric. usage=2 workaround retired (memory `attach-domain-selection`).
- [ ] **Release productization** — work `PLAN-release.md` phase by phase: qmux path ships committed + default-on, cold-boot ordering hardened, signing keys, personal remotes + push (hard gate), BUILD.md + release notes.
- [x] **SELinux Permissive → Enforcing** — ✅ VALIDATED 2026-07-11, cold-boot with full matrix green (status table). Residuals folded into release sweep: hands-on matrix pass, rmnet/netmgrd sepolicy tidy, Bluetooth Enforcing re-check.
- [x] **WFC fresh-unit productization** — ✅ DONE + FLASH-VALIDATED 2026-08-22 (`PLAN-vowifi.md` part 47): `wfc_efswrite` oneshot (committed `a534b4aa`) writes `ps_sys_data_configurations.txt` field4=1 on first WFC enable, idempotent (live on Gold, status `ok`).
- [x] **Tethering** — ⭐ **bench-tested 2026-08-22 (DUT1): Wi-Fi hotspot AND USB tethering both WORK end-to-end OUT OF THE BOX, under Enforcing, zero denials, no ipacm.** Wi-Fi: STA+AP concurrency works on this wcnss driver (wlan0 client stayed up, wlan2 AP, hostapd+dnsmasq, client got DHCP+ping+DNS). USB: `svc usb setFunctions ncm` → host cdc_ncm `usb0`, DHCP+ping+DNS 0% loss, **adb survived the composition switch**. Forwarding is netd/BPF (offload HAL absent — fine; IPA hw offload stays parked in `PLAN-hw-accel.md`). **Cellular upstream ✅ same day (Gold, US Mobile LTE):** hotspot on Gold, STA dropped → upstream switched to `rmnet_data2`, DUT client got DHCP+ping+DNS over LTE, and **BPF offload ENGAGED** (IPv4 NAT forwarding rules live in the kernel maps, stats counting) — the tether fast path works on 4.19 with no IPA. Gotcha: Gold's radio was airplane-off'd from WFC bench work; single airplane-OFF transition recovered cleanly (no wedge). Remaining: BT PAN untested (minor); `provisioningApp=[]` → no entitlement blocker. **Verdict: tethering ships as-is; ipacm/IPA offload stays parked as optional perf** (`PLAN-hw-accel.md` Lane D).
- [x] **NAS slow re-attach** — ⭐⭐⭐ **ROOT-CAUSED + KILLED ON BENCH 2026-08-23** (memory `nas-slow-reattach` part 9): stale WLAN-available in the modem's DSD makes IMS go IWLAN-first on cold radio power-up (~45 s timeout before LTE fallback); `dsd-probe wlandown` took Gold's cold recovery **50 s → 4 s (n=2)**. Bug: the `wfc_wlan_bridge` feeder arms WLAN-available on Wi-Fi assoc but never sends WLAN_NOT_AVAILABLE on Wi-Fi loss. **✅ FIX FLASH-VALIDATED 2026-08-23** (feeder down-edge + boot-clear + `qmux_wfc_down` oneshot on WFC-off; `Mi8937/qmux/wfc_wlan_bridge.c` + `init.qmux.rc`, no sepolicy change): armed cold cycle on the fixed build = **voice 4 s** (was 50 s); down-edge and WFC-toggle-off legs both proven. ✅ COMMITTED `18771530`. Remaining: the Wi-Fi-connected cold-cycle follow-up (minor).

**Cleanup / hardening:**
- [ ] Re-scope the bring-up-debt items (branding, static partitions, qmux flip gating) under `TARGET_DEVICE_PEPITO` — ⚠️ the gate itself is already wired and in use (this item used to read "wire `TARGET_DEVICE_PEPITO`"; that half is done).
- [ ] Kernel-tree triage per `PLAN-kernel.md` — commit the finished work, revert `[TEMP]` (the SSR-panic downgrade is now safe to revert: the fatal is gone).
- [ ] Trim `mithorium-common/proprietary-files-qc-*.txt` to blobs on disk; migrate off legacy extractor (`PLAN-vendor-extract.md` §9). Respect the IMS add-on guardrail (no extract-utils regen on mithorium-common).

**Subsystem finish-lines (non-blocking):**
- [x] Audio: ACDB — ✅ SOLVED 2026-07-11: format theory was false; `libacdbloader.so` was never shipped. Nightly loader closure (6 libs) staged in `vendor/xiaomi/mithorium-common`, Palm's stock cal parses + engages, live-validated under Enforcing. Commit with release sweep. `PLAN-audio.md`.
- [ ] Camera: face-test the FD 640×480 substitution build. `PLAN-camera.md`.
- [ ] Bluetooth: profile matrix pass.
- [ ] `TARGET_SCREEN_DENSITY` 320 override; `TARGET_OTA_ASSERT_DEVICE` += pepito; other papercuts in `PLAN-misc.md`.
- Parked / known-issues: SIM-PIN auto-verify (-29 TA buffer limit); cosmetic early-boot rmts blip (crash_count 2, self-recovers); **never use the SIM enable/disable toggle** (wedges UICC apps — recovery `ctl.restart qmux_qcrild`; memory `sim-uicc-toggle-trap`); battery-profile selection (BYD vs itech/ascent) unverified; `mdss` gdsc/clk warnings benign but unexplained; Gold-unit black-screen PS_HOLD deaths + late USB-unplug detection attributed to that unit's hardware (aged battery + flaky magnetic-tip USB pogo pins) — not a ROM lane (memory `blackscreen-pshold-death`).

## TEMP commits / bring-up debt (revert before upstream)

Search `[TEMP]` in commit messages. Kernel-side items are fully audited in `PLAN-kernel.md`; the load-bearing ones:

| Where | Change | Status |
|---|---|---|
| `subsystem_restart.c` | SSR panic → `pr_err` downgrade | Was for surviving the modem ERR_FATAL loop. **Fatal is fixed — revert now** (kernel triage). |
| `mi8937_defconfig` | `CONFIG_RMNET_IPA` off | Superseded: the rmnet lane reverted IPA QMI to msm-qmi and brought data up — confirm the config end-state while triaging `pepito-rmnet`. |
| `mithorium-common/manifest.xml` | radio slot2 instances removed | Single-SIM hw. Re-scope pepito-only on cleanup. |
| `init.xiaomi.rc` / `init.class_main.sh` | `vendor.qcrild` gated behind `persist.vendor.radio.autostart=1` | Being retired by `PLAN-release.md` Phase 1 (qmux default-on for pepito, escape hatch documented). |
| `drivers/base/dd.c`, `i2c-msm-v2.c`, `initramfs.c`, `clock.c` | probe/clk/ramoops diagnostics | Bring-up instrumentation; safe to drop (verified). |

---

## Build & flash workflow

```bash
cd ~/Personal-Projects/lineage-23 && ./scripts/build-lineage23.sh   # → out/target/product/Mi8937/{system,vendor,boot}.img
cd ~/Personal-Projects/android-pepito-pvg100-kernel-upgrade && ./scripts/flash-staging.sh   # EDL; always zero userdata; keep TWRP
```

Remote build server: Stellaris16 (10.0.2.43), `build-lineage23-remotely.sh`. EDL recovery lives in SoC mask ROM — unbrickable. Details: `BUILD.md`. Gotcha: `generated_kernel_headers` is an UNTRACKED symlink farm at `vendor/lineage/build/soong/kernel/include/` — recreate on a fresh checkout (memory `build-and-vendor-notes`).

### Verifying SELinux policy changes — ⚠️ run after EVERY `.te` edit, before handing off a build

The build's `sepolicy_neverallows` check (system/sepolicy global neverallow/neverallowxperm
assertions) fails LATE (~75% in, on the remote builder) — verify locally first. There is no
soong on this machine, but the previous build left a fully m4-expanded policy conf that
`checkpolicy` can re-run in seconds; new rules can be injected into it in their expanded form:

```bash
CONF=out/soong/.intermediates/system/sepolicy/sepolicy_neverallows.checkpolicy.conf/android_common/sepolicy_neverallows.checkpolicy.conf
# 1. Hand-expand your new/changed rules (macros: system/sepolicy/public/te_macros +
#    global_macros; ioctl allowlists: device/qcom/sepolicy*/…/ioctl_macros + ioctl_defines).
# 2. Inject them (plus `type <domain>, domain;` for a new domain) into a COPY of $CONF,
#    anywhere inside the type/rule section — e.g. right after an existing `type …;` line.
# 3. Re-run the exact build-time check; exit 0 = neverallow assertions pass:
out/host/linux-x86/bin/checkpolicy -M -c 30 -o /dev/null <patched-copy>
```

Worked example (the `ims_enabler` fix, 2026-07-10): inject
`type ims_enabler, domain;` + the expanded `allow …:socket { create ioctl … };` →
reproduces the build failure verbatim; add
`allowxperm ims_enabler ims_enabler:socket ioctl { 0xc300 0xc301 0xc302 0xc303 0xc304 0xc305 };`
→ exit 0. Session transcript technique; conf anchor was the `type rild_debug_socket…` line.

Caveats:
- $CONF is a snapshot of the last local build — it does NOT contain uncommitted-but-unbuilt
  policy, and this check only covers neverallow assertions, not m4/syntax errors in your .te
  (a typo'd macro still fails on the builder, but that failure is fast and cheap).
- ⭐ The gotcha that motivated this: any `allow X …:socket ioctl` (including via
  `create_socket_perms`) MUST be paired with an `allowxperm … ioctl <allowlist>` or the
  global `neverallowxperm * *:… ioctl { 0 }` (domain.te ~644) kills the build. For
  ipc_router QMI clients the right allowlist is the legacy-um macro `msm_sock_ipc_ioctls`
  (see `Mi8937/sepolicy/vendor/qmux.te` for the pattern).

## Tree layout

```
~/android/lineage-23/                          # this tree (~188 GB)
  device/xiaomi/{Mi8937,mithorium-common}/     # device + source-built HALs (pepito variant added)
  kernel/xiaomi/msm8937/                       # pepito DTS + mach config
  vendor/xiaomi/                               # extracted blobs (+ mithorium-common/ims/ add-on)
  diag-tools/                                  # on-device diagnostics (qrtr-list, nas-probe, force-ipcr shim, diag capture)
  dts-3.19-pepito/ dts-4.9-pepito/             # symlinks: stock DTB ground truth / 4.9 archive
  backup-stock-android-8.1-AML0/               # symlink: stock 8.1 backup tree
~/Personal-Projects/android-pepito-pvg100-kernel-upgrade/  # A11/4.9 archive + EDL flash scripts
```

Upstream: https://github.com/Mi-Thorium/ (Lineage imports their Mi8937 work; we build the official Lineage branch). Note: remotes currently point at LineageOS read-only — personal remotes + push are a release gate (`PLAN-release.md` Gate 0).

---

## What we are NOT doing (and why)

- **Not evolving the A11/msm-4.9 fork** — archived; Mi8937 source-built HALs already solved its ABI fights.
- **Not guessing "how did this ever work" from source** — query the live stock devices first (methodology above).
- **Not forking `device/palm/pepito`** — one more Mi8937 variant means less code + automatic Lineage updates.
- **Not switching to dynamic partitions** — Palm shipped static (2018); override per-pepito.
- **Not extracting blobs from Adreno-308 devices** (Redmi 4A/5A) — wrong GPU; only Adreno-505 siblings match.
- **Not resuming the modem RE lane** — parked; the modem is healthy on legacy ipc_router, nothing RE-shaped is on the critical path. (The old "not porting msm_ipc_router / QRTR is correct" guardrail was **reversed 2026-07-07** — the port is exactly what fixed the modem. QRTR remains for adsp/wcnss edges.)
- **Not dragging over the A8 radio userspace** — the A15 stack's native ipcr backend + force-ipcr shim made that unnecessary.
- **Not mainline Linux + freedreno (yet)** — credible follow-on once the release ships.

## Memory references

Cross-session context lives in `~/.claude/projects/-home-kyle-android-lineage-23/memory/` (see its `MEMORY.md` index) — the holistic model, per-subsystem status, working agreements, and diag-capture runbooks.
