# Battery Health (Surface B) — kernel-exposed numbers for computed state-of-health

**Target:** Populate the Android 16 native **Battery Health** data (state-of-health %, cycle count, design capacity) that the health HAL currently reports as null/0 on pepito, so Settings' Battery Health surface has real numbers.
**Strategy:** **Kernel-only.** The stock AOSP `Health` HAL already implements `getBatteryHealthData()` and `BatteryMonitor` **auto-detects** the sysfs nodes by name on the `type=Battery` supply. If the kernel exposes the right file names on `/sys/class/power_supply/battery/`, the numbers flow through with **zero HAL/framework edits**.
**Scope:** kernel driver + power_supply core only. No vendor blob, no HAL, no sepolicy expected (verify).
**Status (2026-07-17): ✅ FLASH-VALIDATED (kernel side).** Phase 1 + Phase 2 (Option B1) built, flashed, and validated live on DUT `c39a6acf`. HAL now reports `batteryCycleCount: 20`, `batteryFullChargeDesignCapacityUah: 796000`, `batteryHealthData.batteryStateOfHealth: 73` (was 0/0/null) — with **zero HAL/framework edits**, auto-detected. Enum/attr positional insertion caused no node-name shift; Enforcing, no avc denials. **Phase 3 source-verified** (Battery information page): Maximum capacity + Design capacity rows auto-render now; cycle-count row un-gated via a staged family-wide Settings overlay (needs rebuild). **Remaining: visual eyeball once DUT unlocked + commit kernel & overlay as keepable (non-`[TEMP]`).** See memory [[battery-health-charging-control]].

**Staged changes (2026-07-17):**
- `qpnp-smbcharger.c`: 3 new static helpers after `get_prop_batt_full_charge()` — `get_prop_batt_cycle_count()`, `get_prop_batt_charge_full_design()`, `get_prop_batt_state_of_health()` (SoH = `DIV_ROUND_CLOSEST(charge_full*100, charge_full_design)`, clamped 0–100, explicit not `clamp()`); + 3 entries in `smbchg_battery_properties[]`; + 3 `get_property` switch cases (all forward from `bms` via existing `get_property_from_fg()`).
- `include/linux/power_supply.h`: `POWER_SUPPLY_PROP_STATE_OF_HEALTH` appended right after `POWER_SUPPLY_PROP_SOH`.
- `power_supply_sysfs.c`: `POWER_SUPPLY_ATTR(state_of_health)` appended right after `POWER_SUPPLY_ATTR(soh)` — **verified in-sync with the enum edit** (positional array).
- `cycle_count` + `charge_full_design` needed no core change (standard props, names already in the attr table).
- `qpnp-fg.c` (cycle-count aggregation): the FG tracks cycles in **8 per-12.5%-SoC buckets** and historically reported only the selector's bucket (default bucket 1 = deep-discharge band = **20** on our pack — misleadingly low; live buckets were `20 19 30 37 31 31 48 72`). Changed `fg_get_cycle_count()` so `cycle_count_id == 0` returns the **max bucket** (72 = near-full charge count), default the selector to 0 at probe, and allow writing 0 (per-bucket read via id 1..8 preserved for introspection). Makes `bms/cycle_count` + `battery/cycle_count` + HAL report **72** instead of 20. (Avg=36 would be the more literal "equivalent full cycles" — one-line swap if preferred.) Needs the same rebuild as the overlay.

> This is **Surface B** from the 2026-07-17 battery-health investigation. **Surface A** (LineageOS `IChargingControl` charge limits) is already live and needs no work; **chargingPolicy** (LONGLIFE/adaptive) is a dead-end Pixel-only path (setter hardcoded `UNSUPPORTED` in AOSP). Only Surface B is actionable, and only at the kernel.

---

## Why it's broken today

`dumpsys android.hardware.health.IHealth/default` on the DUT:

```
batteryCycleCount: 0
batteryFullChargeDesignCapacityUah: 0
batteryHealthData: (null)          # → batteryStateOfHealth never set
```

Root cause: AOSP `BatteryMonitor` reads battery-health nodes **only from the supply whose `type == Battery`**. On pepito that is the **smbcharger** `battery` supply (`qcom,qpnp-smbcharger` @ PMI8950), which does **not** expose `cycle_count`, `charge_full_design`, or `state_of_health`. The real numbers live on the **fuel gauge** `bms` supply (`type=BMS`, ignored by BatteryMonitor):

| Value | On `battery` (type=Battery, HAL reads this) | On `bms` (type=BMS, HAL ignores) |
|---|---|---|
| `charge_full` | ✅ 581000 (already forwarded) | ✅ 581000 |
| `charge_full_design` | ❌ absent | ✅ 796000 |
| `cycle_count` | ❌ absent | ✅ 20 |
| `state_of_health` | ❌ absent (no such node anywhere) | ❌ absent |

So SoH = `charge_full / charge_full_design` = 581000/796000 ≈ **73%** is computable but nothing exposes it, and design-cap/cycle-count are on the wrong supply.

---

## The HAL contract (what to expose, exactly)

`system/core/healthd/BatteryMonitor.cpp` `init()` runs these `access()` probes **inside the `type==Battery` branch** — the file names are literal and case-sensitive, under `/sys/class/power_supply/battery/`:

| Sysfs file (must be on `battery/`) | BatteryMonitor.cpp | Feeds HAL field | In scope? |
|---|---|---|---|
| `cycle_count` | L944 | `batteryCycleCount` | ✅ Phase 1 |
| `charge_full_design` | L967 | `batteryFullChargeDesignCapacityUah` | ✅ Phase 1 |
| `state_of_health` | L1007 | `batteryHealthData.batteryStateOfHealth` | ✅ Phase 2 |
| `manufacturing_date` | L1028 | `batteryHealthData.batteryManufacturingDateSeconds` | ⛔ no data source — parked |
| `first_usage_date` | L1035 | `batteryHealthData.batteryFirstUsageSeconds` | ⛔ no data source — parked |

Key facts (verified in source):
- `Health::getBatteryHealthData()` (`hardware/interfaces/health/aidl/default/Health.cpp:137`) reads **`state_of_health` as a raw node** — it does **not** compute SoH from charge_full/design. The **kernel** must compute the percentage.
- The QTI HAL (`vendor/qcom/opensource/healthd-ext/aidl/main.cpp`) instantiates the stock `Health` class verbatim, so no HAL fork is needed — detection + `getBatteryHealthData()` are already present.
- Detection is at HAL init; kernel nodes exist at driver probe (far earlier) → ordering is fine.

---

## Design

Add the three missing nodes to the **smbcharger `battery` psy** by forwarding from the fuel gauge, which the driver is already wired to do:

- `qpnp-smbcharger.c` already holds `chip->bms_psy` and has `get_property_from_fg(chip, prop, &val)` (~L988) — it already forwards `POWER_SUPPLY_PROP_CHARGE_FULL` (`smbchg_battery_properties[]` L5642 / switch case L5862).
- `cycle_count` and `charge_full_design` are **standard** props whose power_supply-core sysfs names already match (`power_supply_sysfs.c` L297, L312) → adding them to the battery psy is pure forwarding, no core change.
- `state_of_health` has **no** matching core prop/attr → needs a small `power_supply` core addition (or a bespoke attribute), plus in-driver computation.

---

## Phases

### Phase 1 — `cycle_count` + `charge_full_design` (low risk, high value) — [x] ✅ VALIDATED 2026-07-17
> Flash-validated: `battery/cycle_count=20`, `battery/charge_full_design=796000`; HAL `batteryCycleCount: 20`, `batteryFullChargeDesignCapacityUah: 796000`.
Pure forwarding in `qpnp-smbcharger.c`. No core changes.

1. Add to `smbchg_battery_properties[]` (~L5642):
   ```c
   POWER_SUPPLY_PROP_CYCLE_COUNT,
   POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
   ```
2. Add cases in `smbchg_battery_get_property()` switch (near the `POWER_SUPPLY_PROP_CHARGE_FULL` case ~L5862):
   ```c
   case POWER_SUPPLY_PROP_CYCLE_COUNT:
       if (get_property_from_fg(chip, POWER_SUPPLY_PROP_CYCLE_COUNT, &val->intval))
           val->intval = 0;
       break;
   case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
       if (get_property_from_fg(chip, POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN, &val->intval))
           val->intval = 0;
       break;
   ```
   (Verify the fg — `qpnp-fg.c`, the gen1/2 FG for PMI8950 — answers both props; the live `bms/cycle_count` & `bms/charge_full_design` nodes prove it does.)

**Expected after flash:** `battery/cycle_count`=20, `battery/charge_full_design`=796000 appear; HAL reports `batteryCycleCount: 20`, `batteryFullChargeDesignCapacityUah: 796000`. (cycle_count alone is already a user-visible win via `BatteryManager.BATTERY_PROPERTY_CYCLE_COUNT`.)

### Phase 2 — computed `state_of_health` node — [x] ✅ node+HAL VALIDATED 2026-07-17 (Option B1); Settings render = Phase 3
> Flash-validated: `battery/state_of_health=73` (= `DIV_ROUND_CLOSEST(581000×100, 796000)`); HAL `batteryHealthData.batteryStateOfHealth: 73`.
Compute `soh = clamp(charge_full * 100 / charge_full_design, 0, 100)` in the driver and expose it as a `state_of_health` file.

**Option B1 (recommended — produces the exact node the HAL wants):** add a real power_supply property.
- `include/linux/power_supply.h`: append `POWER_SUPPLY_PROP_STATE_OF_HEALTH` to the enum (int region — e.g. right after `POWER_SUPPLY_PROP_SOH` ~L332). **Do NOT insert it among the string props (below `MODEL_NAME`).**
- `drivers/power/supply/power_supply_sysfs.c`: the `power_supply_attrs[]` table is **POSITIONAL** (parallel to the enum). Insert `POWER_SUPPLY_ATTR(state_of_health),` at the **same relative index** — i.e. right after `POWER_SUPPLY_ATTR(soh),` (~L456) to mirror the enum edit. ⚠️ **If the two arrays drift out of sync, every sysfs attribute past the insertion point gets the wrong name** — this is the one real correctness trap; keep the enum and attr edits at matching positions and eyeball a few nodes after flashing.
- `qpnp-smbcharger.c`: add `POWER_SUPPLY_PROP_STATE_OF_HEALTH` to `smbchg_battery_properties[]` and a switch case:
  ```c
  case POWER_SUPPLY_PROP_STATE_OF_HEALTH: {
      int full = 0, design = 0;
      if (get_property_from_fg(chip, POWER_SUPPLY_PROP_CHARGE_FULL, &full) ||
          get_property_from_fg(chip, POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN, &design) ||
          design <= 0) {
          val->intval = 0;            /* unknown */
          break;
      }
      val->intval = clamp(full * 100 / design, 0, 100);
      break;
  }
  ```

**Option B2 (lighter — avoids core enum/attr churn):** add a standalone `state_of_health` `device_attribute` (via an `attribute_group`) on the battery psy device, computing the same value. Avoids the positional-array trap, but is a bespoke node outside the property machinery and a bit more boilerplate. Use if the core edit feels too invasive.

**Expected after flash:** `battery/state_of_health`≈73; HAL `batteryHealthData` becomes non-null with `batteryStateOfHealth: 73`.

### Phase 3 — framework / Settings surface — [~] SOURCE-VERIFIED 2026-07-17; visual confirm pending device unlock
The surface is the Paranoid-Android **"Battery information"** page (`Settings ▸ Battery ▸ Battery information` → `deviceinfo/batteryinfo/BatteryInfoFragment`), NOT a standalone "Battery health" screen. Data path traced end-to-end in source:
`HAL HealthInfo` → `BatteryService.java:1054/1057/1059` puts `EXTRA_CYCLE_COUNT`/`EXTRA_MAXIMUM_CAPACITY`/`EXTRA_DESIGN_CAPACITY` (= `batteryCycleCount`/`batteryFullChargeUah`/`batteryFullChargeDesignCapacityUah`) → the row controllers read those extras.

Row-by-row outcome of our kernel change:
- **Maximum capacity** (`BatteryMaximumCapacityPreferenceController`, always AVAILABLE): computes its OWN `% = maxCap/designCap` = 581000/796000 → **"581 mAh (72%)"**. Was "not available" pre-change (design was 0). ⚠️ Note this is 72% (integer floor in Settings) vs the HAL's `batteryStateOfHealth: 73` (our rounded `state_of_health` node) — this page derives its own %, it does NOT read `state_of_health`. Both populated; cosmetic 1-pt difference.
- **Design capacity** (always AVAILABLE): **"796 mAh"**. Was "not available" pre-change.
- **Cycle count** (`BatteryCycleCountPreferenceController`): gated on `R.bool.config_show_battery_cycle_count`, which LineageOS defaults **false** (`packages/apps/Settings/res/values/lineage_config.xml`). The value (20) reaches `EXTRA_CYCLE_COUNT` but the row is suppressed. **✅ Overlay staged** (Kyle-approved, family-wide): `bool config_show_battery_cycle_count=true` in `device/xiaomi/mithorium-common/overlay/packages/apps/Settings/res/values/config.xml` (dir is wired via `mithorium.mk:17 DEVICE_PACKAGE_OVERLAYS`). Needs a **rebuild+reflash** (Settings resource overlay) — the 2 capacity rows already work on the current kernel-only flash.

**Remaining:** eyeball the page once the DUT is unlocked (confirm the 2 capacity rows on current build; cycle-count row after the next build). No further code expected.

### Phase 4 — parked / out-of-scope — [ ]
- `manufacturing_date`, `first_usage_date`: no data source on this pack/FG. HAL logs a warning and reports 0; Settings handles the absence. A synthetic `first_usage_date` (persist first-boot epoch) is possible but is a userspace/persist concern, low value — skip unless the Battery Health page demands it.
- `part_status`, `serial_number`, `battery_health_status`: HAL degrades to UNSUPPORTED gracefully — leave alone.

### Phase 5 — "Battery wear profile" screen (XiaomiParts) — [x] ✅ FLASH-VALIDATED 2026-07-17
> Live on DUT: **Settings ▸ System ▸ Battery wear profile** (injected tile, bottom of System list). Renders 8 bars from `bms/cycle_counts`; sepolicy passed the neverallow check, zero avc denials under Enforcing. `bms/cycle_counts`=`20 19 30 37 31 31 48 82` (top band grew 72→82 from maintenance charging at high SoC while plugged in — live counting confirmed). Aggregate `cycle_count`=82 (id=0=max) flows to the Battery information cycle-count row too.
Power-user surface for the per-SoC-bucket cycle histogram (which AOSP's single-scalar cycle count throws away). Under **Settings ▸ System ▸ Battery wear profile**: 8 horizontal bars, one per 12.5% band, bar ∝ count (max-normalized). On our pack: `20 19 30 37 31 31 48 72` — visibly top-weighted = shallow/gentle cycling.

Data path (Treble-clean, no selector mutation): kernel exposes a read-only **all-buckets** node → the app reads it directly (system UID).
- **Kernel** (`qpnp-fg.c`): implemented `POWER_SUPPLY_PROP_CYCLE_COUNTS` (a *string* prop — core prints strval for `[MODEL_NAME..SERIAL_NUMBER]`, enum 382 sits in range; attr `cycle_counts` pre-existed at the aligned index, so no core edit) → `bms/cycle_counts` = `"20 19 30 37 31 31 48 72"`. Added a `char str[80]` scratch buffer to `fg_cyc_ctr_data`, formatted under `cyc_ctr.lock`.
- **Sepolicy** (`mithorium-common/sepolicy/vendor/system_app.te`): `allow system_app sysfs_battery_supply:{dir file} r_*_perms`. ⚠️ **the one build-risk** — a coredomain reading a device sysfs type. Analysis favorable (no matching neverallow; `sysfs_battery_supply` ≠ generic `sysfs` that the untrusted-app neverallow guards; `incidentd`/`shell` already read battery-sysfs types) but couldn't run the local `checkpolicy` neverallow check (remote-only build, no `out/`). Verify on the builder / watch the `sepolicy_neverallows` stage.
- **App** (`device/xiaomi/mithorium-common/parts/`, pkg `org.lineageos.settings`): `batterywear/BatteryWearActivity` (CollapsingToolbar) + `BatteryWearFragment` (reads NODE, builds screen dynamically) + `BucketBarPreference` (ProgressBar row) + `res/layout/battery_wear_bucket.xml` + 7 strings + manifest `<activity>` injected via `IA_SETTINGS` into `category.ia.system`. No `Android.bp` change (srcs/res globbed).

Validate after rebuild: `adb shell cat /sys/class/power_supply/bms/cycle_counts` → the 8 numbers; Settings ▸ System ▸ Battery wear profile shows 8 bars; `dmesg | grep 'avc.*system_app.*sysfs_battery_supply'` empty under Enforcing.

---

## Verification (black-box, per two-device methodology)

On DUT after each phase (nodes first, then the HAL sees them):
```bash
# sysfs nodes exist + sane values
adb shell 'for n in cycle_count charge_full_design state_of_health charge_full; do \
  printf "%s=" $n; cat /sys/class/power_supply/battery/$n 2>/dev/null || echo MISSING; done'
# HAL picks them up (no HAL restart needed on cold boot; detection is at HAL init)
adb shell dumpsys android.hardware.health.IHealth/default | \
  grep -iE "cycleCount|StateOfHealth|DesignCapacity|batteryHealthData"
```
Sanity: `state_of_health` should ≈ `charge_full*100/charge_full_design` (≈73 today). Cross-check against `bms/cycle_count` and `bms/charge_full_design` (ground-truth source).

---

## Risks & gotchas

- ⚠️ **Positional `power_supply_attrs[]` (Option B1):** enum and attr table must be edited at matching indices or all downstream sysfs names shift. Highest-signal check after flash: read a couple of *unrelated* battery nodes (e.g. `voltage_now`, `temp`) and confirm they still return the right kind of value.
- **SoH accuracy depends on FG capacity learning:** `charge_full` is the FG's *learned* full capacity; it can be stale until a full charge/discharge updates it (cycle_count=20 vs 73% SoH looks aggressive — likely calendar aging on a 2018 pack, but confirm `charge_full` is live, not a default). SoH may step as learning converges. Document as an estimate, not a lab metric.
- **Divide-by-zero / early boot:** guard `design <= 0` (returns 0/unknown) — the FG can report 0 before its first profile load.
- **sepolicy:** new nodes live in `/sys/class/power_supply/battery/`, already labeled and readable by the health HAL domain (it reads `capacity`/`status`/etc. there under Enforcing today). New files inherit the same genfscon label → **no sepolicy change expected**, but re-verify under Enforcing (watch for avc denials on the new node names).
- **Wrong FG driver:** three FG sources exist in-tree (`qpnp-fg.c`, `qpnp-fg-gen3.c`, `qpnp-fg-gen4.c`); PMI8950/8937 uses the gen1/2 `qpnp-fg.c`. The live `bms` attrs (`battery_info_id`, `cycle_count_id`, `resistance_id`) confirm gen1/2. Forwarding goes through the psy interface, so the exact driver is immaterial as long as `bms` answers the props (it does).
- **Kernel `[TEMP]` hygiene:** land as a proper, keepable commit (not `[TEMP]`) — this is a real feature, unlike the bring-up shims in `PLAN-kernel.md`.

---

## File map

| File | Phase | Change |
|---|---|---|
| `kernel/.../drivers/power/supply/qcom/qpnp-smbcharger.c` | 1,2 | props array + get_property cases (forward cycle_count/design; compute SoH) |
| `kernel/.../include/linux/power_supply.h` | 2 (B1) | append `POWER_SUPPLY_PROP_STATE_OF_HEALTH` |
| `kernel/.../drivers/power/supply/power_supply_sysfs.c` | 2 (B1) | append `POWER_SUPPLY_ATTR(state_of_health)` at matching index |

No changes to: `vendor/qcom/opensource/healthd-ext` (HAL), Settings/frameworks (unless Phase 3 finds gating), sepolicy (verify only).

## References
- Memory: [[battery-health-charging-control]] (investigation), [[perf-battery-bench]] (battery lane), [[two-device-methodology]].
- HAL contract: `hardware/interfaces/health/aidl/default/Health.cpp:137`; `system/core/healthd/BatteryMonitor.cpp` L944/967/1007 + init detection loop.
- Driver anchors: `qpnp-smbcharger.c` `get_property_from_fg()` ~L988, `smbchg_battery_properties[]` L5642, get_property switch L5862.
