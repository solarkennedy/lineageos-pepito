# PLAN-release.md — Production release checklist (pepito / PVG100)

**Goal:** ship LineageOS 23.2 for Palm PVG-100 as a **flashable release** off a **clean, committed,
pushed source tree**. This file is the release tracker; per-item detail lives in the referenced
`PLAN-*.md`. Update the checkboxes here as work lands.

## Scope decisions (locked 2026-07-08)

- **Telephony is IN and must work.** Productize the `qmi_force_ipcr` path (qmux WIN, 2026-07-07);
  **SIM/LTE + a GPS fix are release gates.** The modem-fatal RE lane stays parked — the modem is
  already healthy on legacy ipc_router, so no RE is on the critical path. See `PLAN-qmux-bridge.md`.
- **Commit locally now; push is a hard release gate.** Remotes still point at LineageOS upstream and
  no personal fork is configured. Kyle will create the remotes; **release is blocked until the
  cleaned branches are pushed.**
- **Deliverable = both** a signed, flashable image/OTA **and** a clean source tree.

## Definition of done

- [ ] Clean flash + userdata wipe of the **release build** boots to UI with **all subsystems in the
  Phase 9 matrix green**, telephony (SIM/LTE) and a GPS fix included.
- [ ] **SELinux is Enforcing** (not Permissive) with no matrix-breaking denials — release gate.
- [ ] Working trees empty; history is clean port + a small set of labelled, still-load-bearing
  `[TEMP]` commits (or zero); branches pushed to real remotes; `local_manifest` references those
  pushed branches.
- [ ] A reproducible build recipe (`BUILD.md`) + release notes ship alongside the artifact.

---

## Current state snapshot (2026-07-11, all working trees committed)

| Repo | Branch | Dirty | Notes |
|---|---|---|---|
| `kernel/xiaomi/msm8937` | `pepito-rmnet` | clean | ~25 `[TEMP]` commits in history to re-triage (see Phase 2) |
| `device/xiaomi/Mi8937` | `pepito-rmnet` | clean | staged work committed 2026-07-11 (`f4becbf6`..`7adc1cdc`); `[TEMP] disable camera HAL` (`31ff588d`) still in history — Phase 3 |
| `device/xiaomi/mithorium-common` | `pepito-rmnet` | clean | staged work committed 2026-07-11 (`4de80f5`..`1446eeb`); slot2 manifest removal still `[TEMP]`, not pepito-scoped — Phase 3 |
| `vendor/xiaomi` | — | not a git repo | blob handling — Phase 6 |
| `diag-tools/` | — | not a git repo | dev tooling, must NOT ship — Phase 6 |

All three working trees clean as of 2026-07-11; **one validation flash pending** covering: exactly
one qcrild + MT call rings, `vendor.qmux.ims_enabler` → ok/applied, GPS init-launched fix (sky
view), Venus HW video encode (scrcpy/screenrecord), QS volume-slider default on dirty flash.
`scripts/` (incl. build-lineage23.sh) is versioned in the landing repo as of 2026-07-12
(symlinked from the tree root).

Remotes on all three repos = `github → LineageOS/...` (read-only for us). No upstream tracking set.
`local_manifest` pins the three projects to `revision="lineage-23.2"` but the working branch is
`pepito-rmnet` → **manifest does not currently describe our tree** (Phase 6).

---

## Gate 0 — Prerequisites (Kyle)

- [x] **Create personal remotes — ✅ DONE 2026-07-15.** Worked through the full worksheet in the
  landing repo [README §Source repos](../README.md#source-repos) one repo at a time; Fork column
  now filled in. 13 forks created under `solarkennedy` (all repos below except two): kernel/msm8937,
  device/Mi8937, mithorium-common, bootable/recovery, frameworks/base, lineage-sdk, LineageParts,
  hardware/interfaces, qcom-caf/bt, system/core (kept for completeness though it's a 1-commit
  candidate-to-drop), the landing repo itself (private), `proprietary_vendor_xiaomi` (private, blobs
  — turned out `vendor/xiaomi` was already a git repo with 4 commits, not "not a git repo" as the
  current-state snapshot below said). Two repos needed **no** new remote: `vendor/lineage`'s single
  commit (static kernel-headers export) was reverted and build+flash validated against the stock
  `generated_kernel_includes` genrule — tree is now byte-identical to upstream, so it's dropped from
  the fork list entirely and the manifest will pin plain upstream instead; `PepitoLauncher2` already
  had a working, pushed, current remote. `diag-tools/` deliberately stays local-only/unpushed (bench
  diagnostics, excluded from the release build, and its `qdb.dec`/`captures/` content wasn't in scope
  for the Phase 10 privacy review). All 13 new remotes are wired locally but **not yet pushed** —
  push is still Phase 7, gated on working trees going clean.

### Repo → remote worksheet — MOVED

**Single source of truth is now the landing repo's [README §Source repos](../README.md#source-repos)**
(moved 2026-07-12 to avoid drift). Update branch names, commit counts, and the Fork/TBD column
there. Bench-only notes that stay here rather than the public table:

- `scripts/`: moved into the landing repo 2026-07-12 (tree keeps a folder symlink);
  `boot-signing/` copied from `~/Projects/android-pepito-pvg100-kernel-upgrade` — that predecessor
  repo is itself dirty + remote-less, decide its fate.
- QS-slider framework commits: frameworks/base `f11c17b26043`, lineage-sdk `742d375c`.
- Survey hazards, both fixed 2026-07-11: frameworks/base + lineage-sdk QS work was uncommitted on
  detached HEADs (repo sync could have eaten it) → committed; hardware/interfaces, qcom-caf/bt,
  system/core, vendor/lineage had commits on detached HEADs with no branch ref → `pepito` refs
  pinned.
- [x] **Release signing keys — ✅ DONE 2026-07-15.** Full 5-key `.android-certs` keyset in place
  (releasekey, platform, shared, media, networkstack) — no more test-keys default.
- [x] **Flashable form factor — ✅ DONE 2026-07-15.** Both ready: EDL image set (bench workflow)
  and a recovery-sideloadable ZIP (`adb sideload`).

---

## Phase 1 — Radio / telephony productization  ⛳ RELEASE GATE

Detail: `PLAN-qmux-bridge.md` "Remaining" + "BOOT-STABILITY HAZARD" + **"PRODUCTIONIZED
2026-07-10"** (the section that implements most of this phase; commits kernel `42169bd392bd`,
device `4a2f66cc`, mithorium `95880fc`). The mechanism is proven (`libqmi_force_ipcr` LD_PRELOAD
→ SIM=LOADED, Verizon, LTE); this phase makes it boot reliably from cold and ship cleanly.

- [x] **`qcrild.rc` override actually ships** (staged 2026-07-10): blob rc gone from committed
  `proprietary-files*.txt`; telephony runs as `qmux_qcrild` from init.qmux.rc; the device-tree
  `qcrild.rc` remains only to keep vendor.qcrild* defined-but-disabled.
- [x] **Cold-boot ordering — implemented statically and ✅ VALIDATED 2026-07-10** (two cold
  boots: modem ipcr-native from first PIL boot, crash_count 0 — blip gone; SIM/LTE/data/IMS all
  autonomous). Boot 1 caught `init.target.rc` free-running the nightly rmt_storage → fixed
  mithorium `0ac1b3a`, confirmed boot 2. Results in PLAN-qmux-bridge "PRODUCTIONIZED".
- [x] **Boot-stability safety belt — structurally dissolved on the production path**: the modem
  is ipcr-native before LocationManagerService ever inits the gnss HAL (no SSR window to race).
  The hazard remains only for hand-mixed override states (documented for the bench).
- [x] **qmux is the default** for pepito (libinit `ro.vendor.qmux.enable=1`; persist prop is now
  only an explicit override/escape hatch — document it in the release notes). The
  `persist.vendor.radio.autostart` bring-up gating in init.xiaomi.rc/init.class_main.sh is
  RETIRED (2026-07-10, staged): both stock vendor.qcrild start paths now gate on
  `ro.vendor.qmux.enable=0` instead — required, not just cleanup: the stock
  `on boot: enable vendor.qcrild` in init.xiaomi.rc started a SECOND qcrild beside
  qmux_qcrild once the device-tree qcrild.rc defined the service, which clobbered the IRadio
  registration and sent every INCOMING call straight to voicemail (first enforcing flash).
  Needs one validation flash: exactly one qcrild in `ps`, MT call rings.
- [ ] **GPS fix validation** (`PLAN-qmux-bridge.md` item 2, `PLAN-gps.md`): gnss HAL preload staged
  (`fb1df5c` / `c1bf4a32`); do the real init-launched location fix on the productionized build
  (location request + sky view; can't be validated by manual adb launch).
- [x] **Registration + data path — ✅ DONE 2026-07-09** (`PLAN-rmnet.md`): `CONFIG_RMNET_IPA=y`
  restored (IPA QMI reverted to msm-qmi, `b9d615148356`, + resp-EI offset fix `a7fe9caab692`);
  clean-boot validated — attach + CONNECTED + ping over Verizon LTE, fully autonomous. Slot2
  manifest removal remains `[TEMP]` all-siblings → **closed as accepted in Phase 3 (2026-07-22)**;
  it stays that way by choice, not oversight.
- [x] **VoLTE productization** (2026-07-10, `PLAN-volte.md`): NV fix proven reboot-persistent
  (modem EFS; IMS re-registers autonomously); NAS `usage_preference=1` voice-centric restored
  and holds through a radiocycle (usage=2 workaround retired); **`ims_enabler` self-heal boot
  oneshot staged** (qmux dir cc_binary + init.qmux.rc + enforcing-ready sepolicy incl.
  `vendor.qmux.` prop context; status prop `vendor.qmux.ims_enabler`), bench-validated on the
  live modem incl. the simulated-virgin-unit heal path → fresh flashes/EFS wipes self-recover.
  Needs the next validation flash (`getprop vendor.qmux.ims_enabler` → ok/applied). Release-notes
  item: the framework Enhanced-4G toggle is cosmetic (modem is v01-IMSS; A15 qcril is v02-only).
- [x] **sepolicy for qcrild + gnss LD_PRELOAD** — base rules were committed 2026-07-08; round 2
  (ims/hal_imsrtp prop reads + sockets, `ro.vendor.qmux.` context, `tunning` label, genfs UIO
  spelling) committed 2026-07-10 (`95880fc`/`4a2f66cc`). No flip/su domain needed anymore.
  Validation under `setenforce 1` folds into Phase 5. Guard: file caps on any preloaded binary
  kill LD_PRELOAD (AT_SECURE) — `getcap` qcrild/netmgrd/ims daemons/gnss HAL after every vendor
  re-extract (config.fs `caps: 0` staged for the ims daemons).

---

## Phase 2 — Source cleanup: kernel (`kernel/xiaomi/msm8937`)

Base audit: `PLAN-kernel.md`. **That audit predates the qmux WIN** — re-triage each `[TEMP]` against
"is this still load-bearing now that the modem is healthy on ipc_router?"

- [x] **Re-triage the live `[TEMP][pepito]` commits — ✅ DONE + FLASH-VALIDATED 2026-07-22 (via
  reverts, no rebase).** ⚠️ **Key finding: most `[TEMP]`-labeled commits ARE the port, not
  scaffolding.** Reverting three "diagnostic"-looking commits each bootlooped/killed-console — all
  restored as explicit `keep …` commits: iommu `BUG_ON→WARN` softening (pepito SMMUs DTS-disabled →
  NULL-domain panic), `clock_late_init` denylist (skip `gcc_blsp1_uart2_apps_clk` → TZ PS_HOLD;
  the load-bearing logic was hidden in mislabeled `fixup!` commits), i2c-msm-v2 probe-end clk-disable
  skip (keeps `BLSP1_AHB` console clock alive). QRTR/SMSM (`206a5ff4`, `1e2fe2db`) also KEPT — radio
  port, not diagnostics (RPCINIT SMEM word + HELLO-replay for the rmts-buffer gap); a regression
  there is a silent GATE failure. `subsystem_restart` survive-SSR kept as before. `disable RMNET_IPA`
  was already a net-zero paired revert. See memory `phase2-loadbearing-disguised-commits`.
- [x] **Verify the qmux/legacy-IPC backport is committed and clean — ✅** the `qmux/2a–2d` commits
  (ipc_router core + rpmsg xprt + msm QMI + RFSA/memshare) are real committed history in the log.
- [x] **Drop pure diagnostics — ✅ DONE 2026-07-22 (via reverts).** Net Phase-2 effect vs the
  last-good baseline is ONLY instrumentation removal, zero functional delta: smem debugfs (160 lines),
  `iommu`/`initramfs` ramoops dumper (117 lines), clock-handoff/i2c/prima-wlan `pr_info`, `dd.c`
  whitespace, and the whole `ramboot` DDR-dump tool (+ its DT node, was `=y` in defconfig). ftrace
  defconfig knobs were already unset. (camera `cci_i2c` per-read logging: not present / N/A.)
- [x] **Shared-file edits — AUDITED 2026-07-22, ✅ CLOSED as document-and-accept (Kyle's call).**
  Five files under `arch/arm64/boot/dts/vendor-legacy/qcom/` are touched.
  **Inert for siblings (no action):** `msm8937-camera.dtsi` `cam_smmu:` and `msm8937-vidc.dtsi`
  `msm_vidc:` label-only adds; `msm8937-pinctrl.dtsi` +30 lines of pinctrl states (inert unless a
  node references them); the new `i2c_6` node + its alias in `msm8937.dtsi` (ships
  `status="disabled"`, so no adapter registers); modem PIL `qcom,smem-id = <421>` (correct value for
  all msm8937 — siblings scuba/bengal/khaje set the same — and only gates whether
  `log_modem_sfr()` can print the crash reason).
  **Two DO change sibling behavior, accepted as-is:**
  1. `msm8937.dtsi` rmtfs `status = "disabled"` — kills the rmtfs sharedmem-uio region for every
     msm8937. pepito needs it off because it runs the A8 `qmux_rmt_storage` path instead; a sibling
     on stock rmtfs would lose its remote-FS region (modem-breaking for them).
  2. `pm8937.dtsi` `pmic-wd-bark` IRQ (`<0x0 0x8 0x6 IRQ_TYPE_EDGE_RISING>` + name) added to the
     shared `pon` node — arms the PMIC watchdog bark for every pm8937. `qpnp-power-on` tolerates it;
     lower stakes than the rmtfs one.
  **Rationale for accepting:** siblings (land/santoni/ugg) are not built from this fork and there is
  no intent to reconcile with Xiaomi upstream — same call as the `manifest.xml` slot2 and screen-
  density items. Zero risk to pepito, which is the only shipped target.
  **If ever revisited:** neither node carries a DT label, so `&rmtfs`/`&pon` overrides don't exist.
  The clean fix is the trick already used twice here — add a label in the shared file (inert, exactly
  like `cam_smmu:`/`msm_vidc:`), then set `status`/`interrupts` from `pepito.dts`. Small for rmtfs;
  for `pmic-wd-bark` the override must restate the whole 5-entry `interrupts` + `interrupt-names`
  pair, which is more churn and risks fat-fingering a power-key IRQ. Either way it needs its own
  validation flash. Known cost: these are SoC-shared files, so they are conflict surface on any
  future kernel rebase — a rebase cost, not a release risk.
- [x] **Delete strays:** no `*.bak` present (verified 2026-07-22).
- [x] Gatekeeper/RPMB/FBE kernel diff **confirmed committed** (verified 2026-07-11): sdhci
  Auto-CMD12 fix `057578098068` + RPMB empty-slot fix `9d51b9a359b3` in history.
- [~] Rebase/curate history into a reviewable sequence — **DEFERRED by choice 2026-07-22: Kyle opted
  for reverts, not rebase.** Cleanup landed as forward revert/keep commits; the functional
  `[TEMP][pepito]` commits stay in history labeled-but-load-bearing (relabeling would need the rebase
  that was declined). Acceptable for shipping.

---

## Phase 3 — Source cleanup: device repos

### `device/xiaomi/Mi8937` (12 dirty + 1 TEMP commit)

- [x] Review & commit uncommitted work — **✅ DONE 2026-07-11**, 9 lane-scoped commits
  `f4becbf6`..`7adc1cdc`: audio QUAT/TFA9896 voice paths + platform-info rename; extract-utils
  list registration + legacy-mk blob-casualty restore; libc2d30_bltlib (video encode); keymaster
  qseecom-mirror retirement + version-prop blob fixup; qmux DT_NEEDED shim hardening; ims_enabler;
  single-SIM props; LineageSettings RRO; PepitoLauncher2. (Kernel counterpart: tfa98xx Rec GPIO
  kcontrol `0ad5b822237f`.) The qseecom mirror files were **deleted** (mirror retired, not
  committed — mirror-less boot validated 2026-07-08).
- [x] `PLAN-keymaster.md` + `configs/linker.config.json` deletions confirmed intentional
  (implemented plan; unreferenced camera-overlay remnant) and committed 2026-07-11.
- [x] **Camera `[TEMP]` — MOOT, no revert needed (verified 2026-07-22).** `31ff588d` only disabled
  the *sibling* HALs (ulysse/wingtech/land), which need legacy headers 23.2 dropped and which
  pepito never used. The build ships source-built `camera.pepito` (`device.mk`), added later by
  `3f336b7f` — so the commented-out lines are now correct, not outstanding work. Comment
  clarified + `camera.pepito` scoped behind `TARGET_DEVICE_PEPITO` in `b6e2b198`.
- [x] Re-scope pepito-only bring-up debt — see below; `TARGET_DEVICE_PEPITO` is wired.

### `device/xiaomi/mithorium-common` (14 dirty)

- [x] Review & commit — **✅ DONE 2026-07-11** (`4de80f5`..`1446eeb`: gatekeeper
  TARGET_DEVICE_PEPITO gate, camera HAL3 prop, single-SIM manifest + prop overrides, usb adb pin,
  ims file-caps drop, sepolicy dry-run grants, qrtr-tools, ril dep-closure/tftp_server).
- [x] qcrild autostart gating — **done**, `init.target.rc:239` uses the property-first trigger form
  `on property:ro.vendor.xiaomi.device=pepito && post-fs-data` (⚠ the `on post-fs && property:…`
  form did NOT fire — see the in-file note).
- [x] **`manifest.xml` slot2 removal — ✅ CLOSED as document-and-accept (Kyle's call 2026-07-22).**
  Still all-siblings (`3481ae1`, labelled `[TEMP]`). Unlike the init.rc gating above this **cannot**
  be fixed with a runtime property trigger — `manifest.xml` is a static VINTF file assembled at
  build time, so scoping it would mean selecting a different manifest per device in `mithorium.mk`.
  Accepted because only pepito is built from this fork with no intent to reconcile with Xiaomi
  upstream, and a wrong-manifest mistake costs radio entirely. Revisit only if a DSDS sibling is
  ever built.

### Cross-cutting re-scoping (both repos) — `PLAN.md` "bring-up debt"

- [x] **`TARGET_DEVICE_PEPITO` wired — ✅ DONE (verified 2026-07-22).** Set in
  `lineage_Mi8937.mk:28`; gates in place across `lineage_Mi8937.mk` (×2) and `device.mk` (×6,
  incl. `camera.pepito` as of `b6e2b198`), plus the software-gatekeeper gate in `mithorium.mk`.
  No `TODO(layering)` markers remain.
- [x] **Gatekeeper `file_contexts` — ✅ ALREADY MOVED (verified 2026-07-22).** Now at
  `device/xiaomi/Mi8937/sepolicy/vendor/file_contexts:2`; AOSP `system/sepolicy` has **zero** local
  commits and a clean tree, so nothing is exposed to `repo sync` clobber.
- [x] **Security audit — ✅ DONE 2026-07-22, tree + live DUT (`c39a6acf`).** No bring-up root hacks
  were ever committed. Verified clean: `ro.secure=1`, `ro.adb.secure=1`, **`ro.debuggable=0`**,
  `adb root` refused (gated behind Developer options "Rooted debugging"), SELinux `Enforcing` with
  no `androidboot.selinux=permissive` anywhere, no `su`/Magisk/superuser packages, **no committed
  `adb_keys` or SSH keys**, no adbd/recovery insecurity patches, no staged debug daemons
  (diagcap/strace/tcpdump never entered the tree), kernel `CONFIG_DEVMEM`/`PROC_KCORE`/`KGDB` all
  unset, `release-keys` + certified Palm fingerprint, `verifiedbootstate=green`. `userdebug` with
  `ro.debuggable=0` and gated `adb root` **is** the official LineageOS posture — not a gate.
  - **Fixed (`ab431d1`):** `sysrq_always_enabled=1` and the live serial console + `ignore_loglevel`
    handed anyone reaching the UART test point the full SysRq set (crash/reboot/task dumps) and the
    kernel log. Both now behind `PEPITO_SERIAL_CONSOLE=true` — release builds ship quiet. (This also
    closes the old mithorium `[TEMP]` bring-up-cmdline item; `e481fff` had already dropped
    `initcall_debug`, `deferred_probe_timeout` and the watchdog-disable.)
  - **`persist.sys.usb.config=adb` is NOT a root shortcut — challenged and cleared 2026-07-22.**
    It only seeds the AOSP-side boot default so adbd starts on first boot; it does not pin the
    gadget. File Transfer verified working on hardware (HAL binds `mtp,adb`, `18d1:4ee2`, "GADGET
    pulled up"). The modem-wedge fix is the *separate* `persist.vendor.usb.config` in `vendor.prop`
    — nothing in the vendor USB path reads the `sys` prop. A dead duplicate of the vendor prop in
    `system.prop` was removed in `2984d0f`. ⚠ `sys.usb.config` is **not** a reliable read of the
    live composition (the AIDL gadget HAL drives configfs directly and never writes it).
  - Open, cheap: confirm first-boot composition for a user who never enables USB debugging
    (expected: init briefly starts adbd from the seed, framework then corrects it — stock AOSP).
    Needs only a fresh flash left alone. Kyle to validate on next flash.
- [x] `TARGET_OTA_ASSERT_DEVICE` — **already correct** (`BoardConfig.mk:44`:
  `land,santoni,ugg,pepito,Mi8937` under the `PRODUCT_HARDWARE=Mi8937` branch).
- [x] `TARGET_SCREEN_DENSITY = 320` override — **✅ CLOSED as accepted (Kyle's call 2026-07-22)**,
  same rationale as the manifest/shared-DTSI items: this is our fork, siblings are not built from it
  and will not be reconciled with Xiaomi upstream.
- [ ] Trim `proprietary-files-qc-*.txt` to blobs actually on disk; migrate off the legacy extractor
  (`PLAN-vendor-extract.md` §9).

---

## Phase 4 — Per-subsystem finish-line

- [ ] **Camera:** re-enable HAL packages (Phase 3); validate FD 640×480 substitution build
  (`persist.vendor.camera.analysis.subst`), incl. a face-detect smoke test. `PLAN-camera.md`.
- [ ] **Audio:** land the MBHC "Wired headphones" jack-label fix (build+flash); resolve ACDB A8≠A12
  (DSP uncalibrated — try prada's nightly ACDB set). Offload stays disabled. `PLAN-audio.md`.
- [ ] **Gatekeeper/FBE:** decide metadata-encryption (deferred; needs a wipe — do it as part of the
  release wipe if in scope); retest QTI hw AES to drop the `pepito_km1` software reroute if it now
  works. `PLAN-gatekeeper.md`.
- [ ] **Bluetooth:** refresh the stale `PLAN-bluetooth.md` body to match reality (works). Doc-only.

---

## Phase 5 — SELinux: Permissive → Enforcing  ✅ DONE 2026-07-11

- [x] Denials collected across full boots + exercise matrix (harvests in
  `diag-tools/captures/sepolicy-avc-20260709/`); pepito-targeted policy authored in three batches
  (generic fixes; qmux round-2; simlock/rmt_storage-groups) — no permissive domains. Evidence-based
  skip-list documented in memory `selinux-enforcing-prep`.
- [x] Flipped (BoardConfig permissive cmdline deleted); Enforcing cold boot validated 2026-07-10/11:
  SIM/LTE/IMS + GPS + camera JPEG + 20/20 sensors + FBE, modem crash_count 0, enforced denials =
  known-benign skip-list only.
- **Structural fallout fixed en route:** LD_PRELOAD is unusable for init services on A16
  (`neverallow init *:process noatsecure`, and the failed check is dontaudited = invisible) — all
  shims redesigned to DT_NEEDED (patchelf blob_fixups + `-z,global` on libqmi_force_ipcr +
  DT_RUNPATH for the A8 rmt_storage closure; pm-service refbase shim included).
- [x] Enforcing-lane work committed across the three repos (2026-07-11, folded into the Phase 2/3
  commit batches).
- [ ] Residual (non-gating): optional cosmetic allows (zygote /vendor/lib/hw dir read; dontaudit
  mm-qcamerad /data fishing); shutdown-path denial pass never explicitly harvested.

---

## Phase 6 — Tree / manifest / blob hygiene

- [ ] **`local_manifest/roomservice.xml`:** repoint the three projects from `revision="lineage-23.2"`
  to the pushed pepito branch + Kyle's remotes, so the manifest actually describes a reproducible
  release tree. (Blocked on Gate 0 remotes + Phase 7 push.) The **shippable copy lives in the
  landing repo** (`~/Projects/lineageos-pepito/manifests/pepito.xml`) with commented-out
  fork/override stanzas for ALL worksheet repos (incl. the frameworks/recovery
  `<remove-project>` overrides) ready to activate — keep the two in sync.
- [~] **`vendor/xiaomi` blobs — model DECIDED, commit still pending.** It *is* a git repo (the old
  "not a git repo" note was wrong): branch `pepito-vendor`, remote
  `git@github.com:solarkennedy/proprietary_vendor_xiaomi.git`, confirmed **private**
  (`gh api` → `"private":true`) and **nothing pushed yet** (`size: 0`) → Phase 7.
  Reproducibility is satisfied: the binary blob edits are *scripted*, not hand-hacked —
  `Mi8937/extract-files.py:36-40` applies `blob_fixup().add_needed('libqmi_force_ipcr.so')` to
  qcrild/netmgrd/imsqmidaemon/imsdatadaemon/ims_rtp_daemon (verified in the working copies with
  `readelf -d`). Since the blob repo is private, the public reproducibility path is
  "extract-files.py from documented stock/nightly", not "clone our blob repo" — say so in the
  release notes.
  - **Pending:** 35 uncommitted entries — 8 modified (the 5 patchelf'd radio blobs, `pm-service`,
    `Android.bp`, `Mi8937-vendor.mk`) + **107.7 MB untracked**.
- [ ] ⚠️ **NEW FINDING 2026-07-22 — ~97 MB of *sibling* blobs ship in `vendor.img` and are never
  mounted on pepito.** Of the 107.7 MB untracked, ~97 MB is per-variant overlayfs for
  land/prada/santoni/ugg/ulysse/wt8937/wt8937-n-camera. Confirmed present in the **built image**
  (`simg2img` + `debugfs -R "ls /lib/overlayfs"` on `out/.../vendor.img` → `land pepito santoni ugg
  ulysse wt8937-n-camera`; `/etc/overlayfs` → `common land pepito prada santoni ugg ulysse wt8937`).
  They ship because they're declared in the blob lists (864 refs in `proprietary-files-camera.txt`,
  22 in `-device.txt`). **pepito never mounts them:** `Mi8937/rootdir/etc/init.xiaomi.device.rc:54-56`
  mounts only `overlayfs/pepito/` (+ `overlayfs/common/data`) — the `land` block at :125-129 is under
  a different device trigger. So this is pure dead weight in a 470 MB vendor partition.
  **Recommend deferring the trim to r2** rather than blocking this release: it's the same job as the
  `proprietary-files-qc-*.txt` trim below, and `wt8937-n-camera` holds camera daemons/libs
  (`mm-qcamera-daemon`, `libflash_gpio`, `libflash_pmic`, …) — the mount evidence says pepito
  doesn't use them, but this touches the subsystem with a known packaging-regression history
  ([[camera-chromatix-packaging-regression]]) and needs a flash + camera validation to prove.
- [x] **`diag-tools/` — ✅ VERIFIED EXCLUDED 2026-07-22.** No `Android.bp`/`Android.mk` anywhere
  under `diag-tools/`, so Soong cannot pick it up; the only references from the device tree are two
  source *comments*. Nothing in `PRODUCT_PACKAGES`/`PRODUCT_COPY_FILES` points at it.
  `libqmi_force_ipcr` ships from the device tree
  (`mithorium-common/libshim/qmi_force_ipcr.c` + `libshim/Android.bp` module `libqmi_force_ipcr`);
  the `diag-tools/qmi-force-ipcr/` copy is the 42-line bench prototype (vs 74-line prop-gated
  shipping version) plus a stale hand-built `.so`, referenced by nothing. Added
  `diag-tools/qmi-force-ipcr/README.md` documenting the divergence so the wrong file doesn't get
  edited later.
- [x] Prune obsolete `PLAN-*.old*.md` / falsified-lane docs or clearly mark them archival — done
  2026-07-12: all 44 PLAN files moved into the landing repo `plans/` (kept verbatim for the
  record; `plans/README.md` marks `*.old*` archival), tree root keeps symlinks so in-tree
  references resolve.

---

## Phase 7 — Commit & push  ⛳ RELEASE GATE (blocked on Gate 0 remotes)

- [ ] All working trees empty (`git status` clean) after Phases 2–3 — **for every repo in the
  Gate 0 worksheet**, not just the three device/kernel repos.
- [ ] Per-repo history reviewed (self `/code-review` the diff vs the LineageOS branch base).
- [ ] Add remotes; set upstream tracking; **push** `pepito` branches to Kyle's remotes.
- [ ] Push the blob repo (Phase 6) if that's the chosen model.
- [ ] Tag a release point (e.g. `pepito-23.2-r1`) across the repos + record commit SHAs in the
  release notes.

---

## Phase 8 — Flashable build & release artifact

- [ ] Build a **release-keys** build (Gate 0 keyset), not test-keys.
- [ ] Produce the artifact(s): EDL image set and/or `adb sideload` OTA ZIP (`target-files` →
  `ota_from_target_files`), signed with the release key.
- [ ] Confirm `TARGET_OTA_ASSERT_DEVICE` accepts `pepito` and the ZIP asserts the right device.
- [ ] Sanity: verify the flashable ZIP installs from LineageOS recovery / TWRP and boots.
- [ ] (Optional) Set up the OTA update JSON/server if OTA-over-air updates are in scope.

---

## Phase 9 — On-device release validation matrix (clean flash + userdata wipe)

Flash the **release build**, wipe userdata, first-boot setup wizard, then confirm each is green:

- [ ] Boot → UI, `sys.boot_completed`, rooted/normal ADB
- [ ] Display / touch / backlight / brightness
- [ ] Wi-Fi (scan, connect, throughput)
- [ ] Bluetooth (BDADDR seeded, pair, audio/file)
- [ ] Sensors (all 20; phyphox accel/gyro/mag; prox/ALS auto-brightness)
- [ ] Camera (rear + front, preview + JPEG; face-detect subst)
- [ ] Audio (speaker playback, MBHC headset detect, in-call audio)
- [ ] **Telephony (GATE): SIM = LOADED, registration, LTE data, SMS, a voice call**
- [~] **Bluetooth hands-free calling (GATE): place + receive a call with audio routed over a paired
  BT device (HFP); mic + speaker both directions, no echo** — ✅ **downlink VALIDATED in the car
  2026-07-20**: paired fresh to myChevrolet, placed a call, heard **clear audio** over the car.
  Instrumented capture (self-contained on-phone logger) shows SCO up with **mSBC/WBS**, **both
  `INT_BT_SCO_RX` and `INT_BT_SCO_TX` DSP widgets ON** (two-way audio streaming), clean teardown,
  no flap. The old "bt-sco paths are stubs" note was always false — the path just needed exercising.
  Uplink is instrumentally confirmed (TX widget) but the **far-end-heard-me + no-echo** subjective
  check is still open — mark fully done after one two-way call where the other party confirms clean
  mic + no echo. (BT-SCO transport itself: DONE.)
- [x] **Android Auto: USB projection + a call over the car head unit. ✅ RESOLVED 2026-07-18 —
  wired projection confirmed working at a real head unit (Gold `81eed371`). Fix shipped: the
  `config_systemAutomotiveProjection` override committed to the device tree (see FIX below); after
  rebuild+reflash, `cmd role get-role-holders … SYSTEM_AUTOMOTIVE_PROJECTION` returns gearhead and
  the `:car` CDM crash is gone. First-run note: the car shows "enable notification access / check
  your phone" and gearhead fires a phone-side permission-consent notification — tap through it on
  the phone (it can be slow / the on-car "Continue" appears to do nothing until the phone-side grant
  completes); this is normal AOA first-run consent, not a bug.
  **Voice commands — first-run gotcha (confirmed working 2026-07-18):** AA voice input failed at
  first with the assistant reaching `audioSourceOpeningStatus: 102` / "Mic open logging failure"
  and no `VOICE_RECOGNITION` record ever registering. Root cause was NOT audio routing/BT-SCO (that
  was a red herring — car is `preferred mic for calls`, SCO flaps, and `PLAN-audio.md` bt-sco stubs
  are real but unrelated here). It was a **missing `RECORD_AUDIO` runtime grant on the recognizer
  app `com.google.android.googlequicksearchbox`** (the Google app, uid 10174 — distinct from
  gearhead/GMS, which already had it). AA can't surface a runtime-permission prompt while
  projecting, so it fails silently. **Fix / release note:** open the Google app once on the phone
  (unplugged) and grant the microphone permission; then AA voice works (verified: `VOICE_RECOGNITION`
  capture from uid 10174 succeeds, assistant responds). On a fresh install/wipe this must be done
  once before wired AA voice will work. (Also set the ASSISTANT role holder to the Google app while
  debugging — good hygiene, but it was NOT the fix; the mic grant was.) Separately, **BT-SCO
  hands-free *calling* over the car remains its own open gate** (the "Bluetooth hands-free calling"
  item above) — do not consider it closed by this AA voice result.
  Root cause CORRECTED 2026-07-18 (live debug). NOT a USB-composition problem:
  the earlier `persist.vendor.usb.config` / "accessory is not supported" theory is falsified —
  that prop is empty, the kernel + configfs gadget fully support accessory mode
  (`CONFIG_USB_F_ACC=y`, configfs `accessory.gs2` + `ffs.aoa`), and the phone DOES enter accessory
  mode on every connect (`ACCESSORY=START → CONFIGURED → USB_ACCESSORY_HANDSHAKE` in `dumpsys usb`).
  **The real blocker is one layer up:** gearhead's `:car` process crashes on every connect with
  `IllegalStateException: Failed to register vehicle with CDM` ← `SecurityException: must hold
  android.permission.REQUEST_COMPANION_PROFILE_AUTOMOTIVE_PROJECTION`. That permission is
  `internal|role` — granted ONLY to the holder of role `android.app.role.SYSTEM_AUTOMOTIVE_PROJECTION`,
  which has **no holder** on this build (`cmd role get-role-holders …` returns empty). gearhead is
  already privileged (`UPDATED_SYSTEM_APP PRIVILEGED PRODUCT`) and NikGapps ships its privapp-permissions
  allowlist (`/product/etc/permissions/com.google.android.projection.gearhead.xml`), but a role
  permission is **not** granted by allowlist — the role holder is assigned solely from framework config
  `config_systemAutomotiveProjection`, which AOSP/LineageOS leaves empty. Proof there's no runtime
  workaround: `cmd role add-role-holder … gearhead` is rejected with `RoleControllerServiceImpl:
  Package does not qualify for the role` — the config is the gate.
  **FIX (one line, ROM side):** add a framework/RRO overlay setting
  `config_systemAutomotiveProjection = com.google.android.projection.gearhead`. Then the role
  auto-populates (gearhead qualifies), the `internal|role` permission auto-grants, the CDM vehicle
  association succeeds, and wired projection can proceed. Rebuild/reflash (or push the overlay to
  `/product/overlay`), then re-test wired projection + a call over the head unit. Still an open lane,
  but now a targeted overlay fix, not a USB-composition conflict.**
- [ ] **GPS (GATE): a real location fix (sky view)**
- [ ] Crypto: FBE `/data` encrypted, pattern/PIN enroll via HW gatekeeper, TEE keygen sign/verify
- [ ] SELinux Enforcing with no matrix-breaking denials
- [ ] ADB prompts for host authorization on first connect (no baked-in keys / auto-granted root);
  recovery ADB is not silently rooted
- [ ] Reboot survives (no boot loop; qmux + gnss preload ordering holds cold)

---

## Phase 10 — Docs & release notes

- [ ] Update `PLAN.md` status snapshot to reflect the qmux WIN (modem healthy on ipc_router;
  telephony/GPS no longer "the blocker") — it currently still calls radio the active blocker.
- [ ] Finalize `BUILD.md` into a reproducible recipe (manifest, remotes, lunch target, keys, flash).
  **Skeleton drafted in the landing repo** (`~/Projects/lineageos-pepito/BUILD.md`, TBDs marked);
  finalize there, keep the in-tree BUILD.md as the bench doc or retire it.
- [ ] Write release notes: what works, known limitations (ACDB calibration, metadata encryption if
  deferred, single-SIM), recovery/escape hatch for qmux, commit SHAs/tag. Placeholder with the
  known-limitations list: landing repo `docs/RELEASE-NOTES.md`.
- [ ] Credit upstream (Mi-Thorium / LineageOS) + note the pepito-variant approach — started in the
  landing repo README.
- [ ] Screenshots for the landing repo (shot list in `screenshots/README.md`: launcher, QS volume
  slider, about screen, in-call, camera, hardware scale shot).
- [ ] **Before the landing repo goes public:** one review pass over `plans/` for private info —
  bench IPs/serials, home paths, carrier/account specifics — decide what's fine for the record vs
  worth scrubbing.
- [ ] **Blog post — DRAFT before release.** Write the write-up (the bring-up story: pepito as a
  Mi8937 variant, the three-cluster model, the multi-year modem-fatal saga and the qmux/ipc_router
  WIN, sensors/camera/audio/crypto highlights). Draft it while the work is fresh; hold for publish.

---

## Post-release

- [ ] **Publish the blog post** (Phase 10 draft) once the release is out — link the release
  artifact/tag + source repos.

---

## Cross-references

- Radio/telephony gate: `PLAN-qmux-bridge.md`, `PLAN-qmux.md`, `PLAN-radio.md`, `PLAN-radio-compat.md`
- Kernel triage: `PLAN-kernel.md`
- Per-subsystem finish lines: `PLAN-camera.md`, `PLAN-audio.md`, `PLAN-gps.md`, `PLAN-gatekeeper.md`
- Blobs/manifest: `PLAN-vendor-extract.md`, `BUILD.md`
- Memory index: `~/.claude/projects/-home-kyle-android-lineage-23/memory/MEMORY.md`
