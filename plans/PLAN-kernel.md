# Kernel tree — change audit & triage plan (pepito / msm8937)

**Repo:** `kernel/xiaomi/msm8937` (Linux 4.19.325), branch `lineage-23.2`,
base commit `342a6915cdaa` ("fixup! arm64: configs: vendor: Enable CONFIG_RD_LZ4").
**HEAD:** `49ebdd7a7223` — 26 commits on top of base, **plus 534 lines of
uncommitted working-tree changes across 14 files**.
**Audit date:** 2026-06-29.

This doc answers one question: *are the kernel-tree changes accumulated tech debt
that is getting in the way of bringing up keymaster / cameras / radio / GPS /
sensors?* Short answer below, then the per-change ledger and a triage order.

---

## Bottom line

The kernel tree is **not broadly rotten.** The committed history is ~80%
legitimate port work (variant registration, DTS forward-port, FocalTech touch,
MSM clock framework) plus clearly-labelled `[TEMP]` scaffolding. The real
debt is concentrated in **one place: the uncommitted working tree** — a 534-line
blob that mixes keep-forever fixes, throwaway diagnostics, and one *active
behavioral experiment*, all undifferentiated and none committed.

**Which subsystems are actually blocked by kernel debt:**

| Subsystem | Kernel-tree debt blocking it? |
|---|---|
| **keymaster** | **YES.** The uncommitted `qseecom.c` keymaster64-aliasing experiment is live and mutating global TZ app state — it can mask/distort the real behavior. The real *fix* (RPMB legacy block node) is good but sits uncommitted. |
| **cameras** | Partly. The `camera-legacy/` driver fixes are real and worth keeping; the DTS half is already committed (`49ebdd7`). Work is fragmented across committed-DTS + uncommitted-driver — consolidate. |
| **radio** | No. Kernel changes here (panic-survive, `RMNET_IPA=n`, `smem-id`) are scaffolding/diagnostics, not the blocker. Real root cause = **missing in-kernel `sharedmem_qmi`/RFSA service** (new work to *add*, not debt to remove — see `PLAN-radio.md` / MEMORY.md). |
| **GPS** | No. Userspace (qrtr-ns sequel, location configs/libs). Kernel tree is not the obstacle. |
| **sensors** | No. Userspace (missing `/vendor/etc/sensors` overlay for pepito variant). Kernel tree is not the obstacle. |

So the worry that "kernel changes are blocking these five" is **mostly unfounded —
except for keymaster**, where uncommitted kernel code genuinely interferes.

---

## The committed tree (26 commits) — manageable

### Keep — real port work (not debt)

- `41bfc6d1909d` register Palm PVG100 variant in mach-detection
- `4ba38a14c483` add `mi8937_defconfig` for Lineage 23.2 pepito
- `7c0cc5ba095e` add Palm PVG100 (pepito) device tree
- `f5a049e9b11a` pepito DTS: PMIC/panel/touch/charger
- `afeade9bb6f4` forward-port audio + camera DTS
- `622e754b6a8d` pepito USB/i2c_2 comment fixups
- `dc02774ee5bd` switch to MSM clock framework (`USE_COMMON_CLK_MSM`)
- `56f69a66fb35` re-enable `clock_late_init`
- FocalTech FT8613 series: `aa8fd9f`, `feea295`, `244fdf4`, `103960d`,
  `b69e946`, `5034aae`, `0ee5eba`, `6ad770d`, `5aad69e` (driver + DTS + defconfig
  + FTS_INFO log-spam downgrades)
- `49ebdd7a7223` match stock camera probe data (DTS)

These are the actual port. They stay.

### Marked `[TEMP]` scaffolding — revert eventually, but some can go NOW

| Commit / file | What | Disposition |
|---|---|---|
| `6fef8e44` + `b0a4851d` + `7fdda54f` — clock handoff logging | per-clock `pr_info` in `clock_late_init` | **Drop now.** PLAN §B: boot is clean, handoff list is empty. Dead weight. |
| `drivers/base/dd.c` (via `9df7ce0` revert) | committed diff is now **whitespace-only** (the `pr_info` was already reverted) | **Drop now.** Pure noise. |
| `8ad870612ce2` — omnibus `[TEMP]` workarounds | `iommu.c` `BUG_ON`→`WARN_ON_ONCE`; `initramfs.c` ramoops dumper (+117); `clock.c` `gcc_blsp1_uart2_apps_clk` skip | Keep iommu soften + ramoops dumper while bringing up; the uart2 skip **permanently leaks a clock vote** (MEMORY: "leaks votes, no modem logic") — low harm, revert when UART probe ordering is fixed. |
| `126e1a5063b5` — i2c-msm-v2 | probe instrumentation + skip `clk_disable` at probe end | Keep until `msm_serial` probes at `subsys_initcall` (holds its own BLSP1_AHB vote); then revert. |

### Shared-file edits (sibling-build risk) — confirm or relocate

These edit files shared by **all Mi8937 siblings** (ugg/land/santoni/prada):

- `pm8937.dtsi` — adds `pmic-wd-bark` IRQ (`<0x0 0x8 0x6 EDGE_RISING>`). Affects every variant's PMIC PON node.
- `msm8937-camera.dtsi` / `msm8937-vidc.dtsi` — add `cam_smmu:` / `msm_vidc:` labels so pepito can reference them. **Harmless** (labels only).
- `msm8937.dtsi` — `status = "disabled"` on a node (~line 288, before `restart@4ab000`). Affects siblings.

**Action:** confirm the PMIC IRQ + `status="disabled"` are sibling-safe, or move
to `pepito.dts` overrides. (Matches the "Layering — push as deep as possible
without breaking siblings" rule in `PLAN.md`.)

---

## The uncommitted working tree — the actual problem (534 lines, 0 committed)

```
 M arch/arm64/boot/dts/vendor-legacy/qcom/msm8937.dtsi   (+10)  smem-id=421
 M arch/arm64/boot/dts/xiaomi-msm8937/pepito.dts         (+45)  qseecom/ion/rmtfs
 M arch/arm64/configs/mi8937_defconfig                   (+10/-2)
 M drivers/misc/qseecom.c                                (+201/-3)  ⚠ experiment
 M drivers/mmc/core/Kconfig                              (+20)
 M drivers/mmc/core/block.c                              (+148/-15) RPMB — good fix
 M drivers/soc/qcom/subsystem_restart.c                  (+13/-1)  panic-survive TEMP
 M techpack/camera-legacy/...  (7 files)                 (+87/-24) mixed
?? arch/arm64/configs/mi8937_defconfig.bak                         stray — delete
```

### 1. `qseecom.c` (+201/−3) — ⚠ ACTIVE EXPERIMENT, not a fix

Most is diagnostic `pr_warn`/`pr_info` (keymaster/gatekeeper tracing, buffer
hexdumps at hardcoded offsets — strippable). But buried inside is a **behavioral
hack** in `qseecom_load_app()` / `qseecom_query_app_loaded()`:

- aliases userspace `keymaster` requests to a preloaded `keymaster64` app,
- **fabricates** a `registered_app_list` entry for it,
- forces `app_arch = 0`,
- **bypasses the dynamic MDT load entirely** (`-ENOENT` if keymaster64 not resident).

The comments say it outright: *"dynamic keymaster MDT load disabled for this
diagnostic."* This **mutates global TZ app state** and can mask/distort the very
keymaster behavior being debugged. This is the single item most likely to be
"getting in the way." **Revert the aliasing/fake-registration; keep the logging
only if still needed.** Re-baseline keymaster from clean.

(Note: `scm.c` is already clean — the SMC32-first hack was reverted, confirmed
`git status` shows no modification. Don't re-add it; it never fixed keymaster.)

### 2. `block.c` + `Kconfig` RPMB (+148/−15) — the opposite: a good finished fix, uncommitted

`CONFIG_MMC_BLOCK_LEGACY_RPMB` restores the legacy `/dev/block/mmcblkXrpmb` block
node + `MMC_IOC_RPMB_CMD` ioctl + explicit CMD23 framing (dodges sdhci Auto-CMD23
rejection → errno 110) that stock QTI `qseecomd`/`librpmb` need. Clean,
Kconfig-gated, well-commented, ground-truthed against the stock 3.18 block node
(`android11-adb`: `brw------- 179,32`), PLAN-flagged flash-verified as the
keymaster/gatekeeper unblocker. **No reason this is uncommitted — commit it.**

### 3. `subsystem_restart.c` (+13/−1) — panic-survive `[TEMP]`

Downgrades `panic("Subsystem %s crashed during SSR!")` → `pr_err_ratelimited` +
drops the re-crash, so the AML0 modem's repeated ERR_FATAL doesn't boot-loop the
SoC. Necessary scaffolding (masks the modem fatal). **Commit as a tracked `[TEMP]`**
so it stops floating loose. Revert once the modem fatal is root-caused (missing
`sharedmem_qmi` — see `PLAN-radio.md`).

### 4. `camera-legacy/` (7 files, +87/−24) — mixed fixes + diagnostics

**Real fixes (keep):**
- `session_id = camera_id + 1` (camera.c/.h/msm.h/msm_sensor_driver.c) — imglib
  uses 0 as empty-slot sentinel; rear cam at cell-index 0 produced session-id 0 →
  `module_imgbase_start_session: Invalid idx -1` → 0 cameras. Offset matches stock.
- `CFG_SENSOR_OTP_UPDATE` no-op case (msm_sensor.c + uapi header) — Palm camera blob
  sends cfgtype 30 during OTP init; without the case → `-EFAULT` → "otp init error
  -1" → null lib handle → provider SIGSEGV. Mirrors stock 3.18.

**Diagnostics (strip):** `[PEPITO-OTP]` per-i2c-read logging in
`msm_camera_cci_i2c.c` and the `config32`/`config` unhandled-cfgtype `pr_info`.

### 5. defconfig uncommitted (+10/−2)

- `CONFIG_MMC_BLOCK_LEGACY_RPMB=y` — **keep** (pairs with block.c).
- `# CONFIG_RMNET_IPA is not set` — marked `[TEMP]`, keep until IPA-QMI↔modem retest.
- `CONFIG_FUNCTION_TRACER=y` + `FUNCTION_GRAPH_TRACER` + `DYNAMIC_FTRACE=y` —
  **debug-only, drop for production** (perf overhead).

### 6. DTS uncommitted

- `msm8937.dtsi` `qcom,smem-id = <421>` (MPSS_CRASH_REASON_SMEM) — **real fix**,
  surfaces the modem SFR string in dmesg. Commit.
- `pepito.dts` (+45): `rmtfs_sharedmem@0` node (real — UIO sharedmem for modem
  EFS), plus `/delete-node/ qseecom_ta_mem` + ion-heap@19 delete + `qcom_seecom`
  reg override (0x84A00000/25 MiB). The qseecom overrides pair with the keymaster
  investigation — keep the rmtfs node; reconsider the seecom reg override when the
  qseecom experiment is reverted.

### 7. `mi8937_defconfig.bak` — stray untracked backup. **Delete.**

---

## Triage order

1. **Commit the keepers** (stop them being "at risk"):
   RPMB (`block.c` + `Kconfig` + defconfig `=y`), `smem-id=421`,
   `rmtfs_sharedmem` node, camera `session_id`+`CFG_SENSOR_OTP_UPDATE` fixes.
   Discrete, reviewable commits.
2. **Revert the `qseecom.c` keymaster64-aliasing logic** (keep logging only if
   still needed). Re-baseline keymaster from clean. *Show the revert diff before
   applying.*
3. **Commit `subsystem_restart.c` as a tracked `[TEMP]`** (don't leave floating).
4. **Strip pure diagnostics:** camera cci_i2c per-read logging, ftrace defconfig,
   the clock-handoff-logging commit, the dd.c whitespace-only commit.
5. **Confirm shared-file edits sibling-safe** (`pm8937.dtsi` IRQ,
   `msm8937.dtsi status="disabled"`) or move to `pepito.dts`.
6. **Delete** `mi8937_defconfig.bak`.

After this pass: the committed tree = clean port + a small set of labelled,
tracked `[TEMP]` commits; the working tree = empty; keymaster debugging proceeds
from a baseline with no live experiment mutating TZ state.

---

## What is NOT kernel debt (don't go looking for it here)

- **GPS / sensors** blockers are userspace — see `PLAN-gps.md`, `PLAN-sensors.md`.
- **radio** real blocker is *adding* `sharedmem_qmi.c` (RFSA service) to
  `drivers/uio/msm_sharedmem/` — new work, port from stock with the new
  `qmi_handle_init`/`qmi_add_server` API (template: `qcom_sysmon.c`). See
  `PLAN-radio.md` / MEMORY.md "Modem fatals on EVERY boot".
- The `§A other_ext_mem` reservation, `USE_COMMON_CLK_MSM`, and RPMB block node
  are **resolved root-cause fixes**, not debt.

---

## Cross-references

- `PLAN.md` — "Layering — where each kind of change belongs", "TEMP commits / bring-up debt"
- `PLAN-gatekeeper.md` — RPMB / qseecom / keymaster chain
- `PLAN-radio.md` — modem fatal, `sharedmem_qmi`, RMNET_IPA, panic-survive
- `PLAN-camera.md` — imglib session-id, OTP cfgtype
- `MEMORY.md` — holistic three-cluster model
