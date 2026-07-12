# PLAN-props.md — Property diff: A16 (ours) vs A11 (stock-vendor ground truth)

**Date:** 2026-06-29
**Method:** `getprop` dumped from both bench devices, normalized to sorted `key=value`,
diffed for (a) keys only on stock, (b) keys with differing values.

- `android11-adb` (`81eed371`) — **stock Palm 8.1 vendor + phh A11 GSI**. 510 props.
- `android16-adb` (`c39a6acf`) — our LineageOS 23.2 build. 1156 props.

> Raw working files (scratchpad, regenerable): `a11.kv`, `a16.kv`, `diffvals.txt`.
> No changes were made — this is findings-only.

---

## ⚠️ Read this first — the ground-truth caveat

**`android11-adb` runs a phh A11 GSI on top of the stock 8.1 vendor partition.** That splits
its props into two very different authority classes:

- **VENDOR-side props = real Palm ground truth.** `ro.vendor.*`, `persist.vendor.*`,
  `persist.sys.ssr.*`, `vendor.audio.*`, `ro.usb.qcproduct`, `init.svc.<vendor daemon>`,
  and anything the stock 8.1 `/vendor` init sets. These came off the partition the SoC
  shipped with — trust them.
- **SYSTEM/framework props = phh GSI defaults, NOT pepito.** `ro.product.system.*`,
  `dalvik.vm.*`, `ro.config.{ringtone,alarm,notification}`, `persist.sys.phh.*`, `tct.*`,
  `oplus/oppo/realme`, `ro.build.*`, locales, theme, dexopt — these are the GSI's, not
  Palm's original 8.1 userspace. Diffs here are mostly noise (us-vs-phh, not us-vs-Palm).

So: **value diffs in vendor-scoped props are signal; diffs in framework props are usually
not.** Where a SIM-loaded radio prop appears on A11 (e.g. `gsm.sim.operator.alpha=Verizon`)
that's the A11 *framework* reading a live SIM — useful as proof the radio stack reached the
SIM, not as a config to copy.

Also note A11 has a SIM inserted and a live network; A16 does not (radio still blocked), so
the entire `gsm.sim.*` / `gsm.operator.*` family being A11-only is expected, not a config gap.

---

## TIER 1 — functional diffs worth investigating

### 1. Display density mismatch — and it's internally inconsistent on A16
| prop | A11 (stock) | A16 (ours) |
|---|---|---|
| `ro.sf.lcd_density` | **320** | **264** |
| `vendor.display.lcd_density` | (n/a) | **320** |

Stock Palm runs the framework at **320 dpi**. Our build runs SurfaceFlinger at **264** while
its *own* `vendor.display.lcd_density` says **320** — the framework density and the vendor
density disagree on A16. 264 is a Mi8937-family default leaking through. This is almost
certainly the source of "UI elements are the wrong size." Matches the open TODO
("`TARGET_SCREEN_DENSITY` — Mi8937 default 280; Palm 720x1280 is 320"). Fix target: 320.

### 2. `persist.sys.ssr.restart_level` is missing — relevant to the modem-crash work
| prop | A11 | A16 |
|---|---|---|
| `persist.sys.ssr.restart_level` | **`wcnss modem`** | *absent* |

Stock explicitly sets the subsystem-restart level for **wcnss and modem**. Our build never
sets it. Given the active investigation into the modem fataling on every boot and the
panic-survive patch, this is worth understanding before more modem work: stock's SSR policy
for the modem is not the kernel default. Not necessarily *the* fix, but it's a real
vendor-policy prop we're missing on the exact subsystem under investigation.

### 3. `persist.vendor.radio.rat_on` — value differs
| prop | A11 | A16 |
|---|---|---|
| `persist.vendor.radio.rat_on` | **combine** | **other** |

Stock combines RAT reporting; we inherit Mi8937's `other`. Controls how the RIL reports
radio access technology. Cheap to test against the radio bring-up.

### 4. CDMA-flavored telephony props inherited from Mi8937 — verify they fit Palm/Verizon
A16-only (not set on stock vendor):
- `telephony.lteOnCdmaDevice=1`
- `ril.subscription.types=RUIM`
- `ro.telephony.default_network=33`

These come from the Mi8937 tree. Pepito on Verizon (A11 shows `gsm.sim.operator.numeric=311480`
= Verizon) *is* an LTE/CDMA-adjacent carrier, so RUIM/lteOnCdma may be correct — but they were
never chosen for pepito, they're Xiaomi defaults. Worth confirming they don't steer the RIL
toward a CDMA path the AML0 modem doesn't want, especially since radio is still blocked.

### 5. Radio props stock sets that we don't
Stock vendor sets, A16 missing:
- `persist.vendor.radio.sw_mbn_loaded=1`
- `persist.vendor.radio.start_ota_daemon=1`
- `persist.vendor.radio.sglte_target=0`
- `persist.vendor.radio.eons.enabled=false`
- `persist.radio.atfwd.start=true` (we have `vendor.radio.atfwd.start=false` — atfwd
  intentionally disabled per PLAN TEMP note; consistent, just flagging the divergence)

`sw_mbn_loaded` / `start_ota_daemon` relate to modem MBN config-blob loading — relevant to
getting the modem healthy. Low cost to align.

### 6. `persist.sys.gps.lpp` missing
| prop | A11 | A16 |
|---|---|---|
| `persist.sys.gps.lpp` | **2** | *absent* |

LPP (LTE Positioning Protocol) profile select. Stock sets it; we don't. Stage it with the GPS
bring-up — pull alongside the GPS configs the GPS TODO already calls for.

### 7. `persist.sys.xtra-daemon.enabled` is `true` on A16 — PLAN expects this to break GPS
| prop | A16 live |
|---|---|
| `persist.sys.xtra-daemon.enabled` | **true** |

PLAN §C records that `=true` caused a GPS crash loop until set false, and the tree now stops
`loc_launcher` on this trigger. The live value is back to `true`. `loc_launcher` is indeed
`stopped` (mitigation held), but the prop being `true` again is worth reconciling — either the
mitigation is masking it or something re-sets it at boot.

### 8. Audio config diffs
| prop | A11 | A16 |
|---|---|---|
| `vendor.audio_hal.period_size` | **192** | **240** |
| `vendor.voice.path.for.pcm.voip` | **false** | **true** |

Stock uses a 192-frame period; we inherit Mi8937's 240. Period size affects latency and
underrun behavior — align to 192 when audio bring-up starts. The VoIP PCM path also differs.

**ACDB update (good news, PLAN is stale here):** A16 *does* now ship
`/vendor/etc/acdbdata/pepito/MTP_*_cal.acdb` (7 files) and `persist.vendor.audio.calfileN`
point at them — so "pepito ACDB absent" in PLAN/memory is **out of date**. Open question:
A16's set is the **MTP** variant; stock Palm ships **both `MTP/` and `QRD/`** under
`/vendor/etc/acdbdata/`. Confirm pepito is genuinely an MTP-type board and that our MTP
calibration matches stock Palm's MTP set (diff the files), rather than an MTP set borrowed
from a sibling.

---

## TIER 2 — corroborates existing PLAN clusters (no new action)

- **Sensors (Cluster B / wrong-HAL).** A16 sets `ro.qcom.svi.sensortype=2` +
  `vendor.fastrpc.disable.adsprpcd_sensorspd.daemon=1` and runs `vendor.sensors.qti` (SSC
  path). Stock runs the legacy SMGR daemon (`init.svc.sensors=running`,
  `init.svc.sensors-hal-1-0=running`) with no SSC props. Confirms the plan's "we're on the
  wrong sensor HAL" finding from the prop side too.
- **Modem not healthy.** Stock has `gsm.version.baseband=953_GEN_PACK-1.213350.3.214411.1`;
  A16 has no baseband-version prop at all → the modem never reported its build. Consistent
  with the "post-fatal zombie" modem story.
- **Console UART.** `ro.boot.console`: stock `ttyHSL0` (3.18 HSL driver) vs A16 `ttyMSM0`
  (4.19 msm_serial). Expected kernel-generation difference, not a bug.

---

## TIER 3 — cosmetic / identity (low priority, but a couple are worth a glance)

- **Stale build identity.** `ro.build.fingerprint`, `ro.build.description`, and
  `ro.vendor.build.fingerprint` on A16 are all the **stock Android-8.1 string**
  (`Palm/PVG100/Pepito:8.1.0/OPM1.171019.019/v1AML-0`), while `ro.build.id` / version / sdk
  are correctly Android 16 (`BP4A.251205.006`, sdk 36). The 8.1 fingerprint is being used as
  the system build fingerprint. Harmless functionally but will confuse SafetyNet/attestation
  and any fingerprint-keyed logic; decide if that's intentional (vendor-freeze compat) or a
  leftover override.
- `ro.vendor.build.security_patch=2017-04-01` on A16 — vendor patch level frozen at the 8.1
  vendor (VTS/security-patch reporting only).
- `ro.product.first_api_level`: A11=27, A16=25 (`ro.vendor.api_level=25`). Mi8937 default;
  affects Treble/VTS expectations only.
- `ro.usb.qcproduct=Pepito Palm` on stock; A16 uses `vendor.usb.product_string=PVG100`.
  Cosmetic USB descriptor.
- Missing `ro.vendor.product.{brand,device,manufacturer,model,name}=Palm/Pepito/…` set on
  A16 vendor (we set `ro.product.*` instead). Some Qualcomm vendor code keys off
  `ro.vendor.product.*`; low risk but trivial to add if anything complains.
- `ro.product.locales` on stock = `en_US,es_MX,ko_KR,vi_VN,zh_CN,zh_TW,pt_BR` (Palm's set).
  Framework-side; only matters if you want to match Palm's shipped locale list.
- Framework noise (ignore): `dalvik.vm.heap*` smaller on A16 (low-RAM config),
  `ro.config.{ringtone,alarm,notification}`, `persist.sys.theme`, dexopt knobs,
  `ro.build.*` host/user/date — all GSI-vs-Lineage, not Palm-vs-us.

---

## Suggested next actions (when you decide to act)

1. **Density → 320** (Tier 1.1) — highest user-visible payoff, and the internal 264/320
   inconsistency on A16 makes this clearly a bug, not a preference.
2. While doing radio: try `persist.vendor.radio.rat_on=combine`, add
   `persist.sys.ssr.restart_level="wcnss modem"`, and the `sw_mbn_loaded`/`start_ota_daemon`
   pair; re-evaluate the inherited CDMA props (`lteOnCdmaDevice`, `subscription.types=RUIM`,
   `default_network=33`) against the AML0 modem.
3. While doing GPS: stage `persist.sys.gps.lpp=2`; reconcile `xtra-daemon.enabled`.
4. While doing audio: `period_size=192`, and diff our MTP ACDB against stock Palm's MTP set.
5. Decide whether the stock-8.1 `ro.build.fingerprint` is intentional or should become a
   Lineage 23 fingerprint.

None of these are confirmed fixes — they're stock-vs-ours divergences on subsystems that are
either actively blocked or visibly wrong, surfaced for targeted testing.
