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

- [ ] Create personal remotes (fork or fresh repos) — **full worksheet below** (fill the "New
  remote" column as they're created). Full-tree sweep 2026-07-11 found **13 repos carrying pepito
  work**, not 3: also recovery, LineageParts, frameworks/base, lineage-sdk, hardware/interfaces,
  qcom-caf/bt, system/core, vendor/lineage, PepitoLauncher2.

### Repo → remote worksheet (surveyed 2026-07-11)

| Repo path | Branch | Pepito work | Current remote (`fetch`) | New remote (TBD) |
|---|---|---|---|---|
| `kernel/xiaomi/msm8937` | `pepito-rmnet` | 66 commits | `github` → `LineageOS/android_kernel_xiaomi_msm8937` | TBD |
| `device/xiaomi/Mi8937` | `pepito-rmnet` | 50 commits | `github` → `LineageOS/android_device_xiaomi_Mi8937` | TBD |
| `device/xiaomi/mithorium-common` | `pepito-rmnet` | 59 commits | `github` → `LineageOS/android_device_xiaomi_mithorium-common` | TBD |
| `packages/apps/LineageParts` | `pepito-lineageparts` | 8 commits (QS slider toggle) | `github` → `LineageOS/android_packages_apps_LineageParts` | TBD |
| `bootable/recovery` | `lineage23-pepito` | 12 commits (power-key nav, EDL menu, ⚠️ `adbd as root` — must be **stripped**, Phase 3 security item) | `github` → `LineageOS/android_bootable_recovery` | TBD |
| `frameworks/base` | `pepito-qs-volume-slider` | 1 commit (QS slider SystemUI, `f11c17b26043`) | `github` → `LineageOS/android_frameworks_base` | TBD |
| `lineage-sdk` | `pepito-qs-volume-slider` | 1 commit (setting + DB 24→25 upgrade, `742d375c`) | `github` → `LineageOS/android_lineage-sdk` | TBD |
| `hardware/interfaces` | `pepito` (ref; HEAD detached) | 2 commits (BT binary BDADDR, sensors HAL input group) | `github` → `LineageOS/android_hardware_interfaces` | TBD |
| `hardware/qcom-caf/bt` | `pepito` (ref; HEAD detached) | 2 commits (Pronto/SMD libbt-vendor bring-up) | `github` → `LineageOS/android_hardware_qcom_bt` | TBD |
| `system/core` | `pepito` (ref; HEAD detached) | 1 commit (silence f2fs recovery log — candidate to just drop) | `github` → `LineageOS/android_system_core` | TBD / drop |
| `vendor/lineage` | `pepito` (ref; HEAD detached) | 1 commit (kernel-headers symlink farm — load-bearing for build) | `github` → `LineageOS/android_vendor_lineage` | TBD |
| `packages/apps/PepitoLauncher2` | `master` | whole app (manual clone, not in manifest) | `origin` → local `~/Projects/PepitoLauncher2` | TBD — needs its own GitHub repo **+ manifest entry** |
| `~/Projects/lineageos-pepito` | `lineageos23.2` | **landing/index repo** (created 2026-07-11): README + repo index, BUILD.md skeleton, transitional local manifest, `plans/` full record, screenshots/release-notes stubs | none yet | TBD — the public face; create first |
| `vendor/xiaomi` | — | blob tree, **not a git repo** | — | TBD — `proprietary_vendor_xiaomi` (Phase 6 decision) |
| `diag-tools/` | — | not a git repo; must not ship in the image | — | TBD — optional tools repo |
| `scripts/` | — | ✅ moved into the landing repo 2026-07-12 (tree keeps a folder symlink); incl. `boot-signing/` copied from `~/Projects/android-pepito-pvg100-kernel-upgrade` (canonical home; that repo is itself dirty + remote-less — decide its fate) | in landing repo | — (rides with landing repo) |
| `build/make` | dirty (local-only) | `envsetup.sh` netbook4 build guard — do NOT ship; keep local or move to a shell profile | `github` → `LineageOS/android_build` | — (no fork) |
| `hardware/qcom-caf/common` | dirty (artifact) | untracked `kernel/` header-export artifact — do not commit | `github` → `LineageOS/android_hardware_qcom-caf_common` | — (no fork) |

Survey hazards, **both fixed 2026-07-11**: the frameworks/base + lineage-sdk QS-slider work was
uncommitted on detached HEADs (`repo sync` could have eaten it) → committed on
`pepito-qs-volume-slider`; hardware/interfaces, qcom-caf/bt, system/core, vendor/lineage had
local commits on detached HEADs with no branch ref (GC/sync exposure) → `pepito` branch refs
pinned on all four.
- [ ] Decide on **release signing keys**: generate a dedicated `.android-certs` keyset (releasekey,
  platform, shared, media, networkstack) — no root `.android-certs` exists today (test-keys ship
  by default and are unsafe for a real release; also required for a stable OTA update chain).
- [ ] Confirm the flashable form factor: **EDL image set** (current workflow) and/or
  **recovery-sideloadable ZIP** (`adb sideload`) — the latter is expected for a public "release."

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
  manifest removal remains `[TEMP]` all-siblings → re-scope tracked in Phase 3.
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

- [ ] **Re-triage the live `[TEMP][pepito]` commits** (still in history):
  - `subsystem_restart` survive-SSR — likely **still needed** (modem still SSRs ~14 s during the
    flip); keep as a tracked `[TEMP]` unless a healthy cold boot no longer crashes.
  - `disable RMNET_IPA` — **revert** as part of Phase 1 data-path retest.
  - QRTR/SMSM replay + HELLO knobs, `smem` debugfs instrumentation (`206a5ff4`, `c3c02d85`,
    `e2e78488`, `be41aede`, `1e2fe2db`, `587ec212`) — **diagnostic scaffolding from the
    now-superseded AP-side lane; drop for release** (confirm none are load-bearing for the ipc_router
    path first). Some already have paired `Revert` commits — squash/clean the revert pairs.
- [ ] **Verify the qmux/legacy-IPC backport is committed and clean** (msm_ipc_router core + rpmsg
  xprt + msm QMI + RFSA/memshare — the thing that fixed the modem fatal). This is the load-bearing
  radio work; it must be real committed history, not scaffolding. See `qmux-backport-lane` memory.
- [ ] **Drop pure diagnostics** that survived: clock-handoff `pr_info`, `dd.c` whitespace-only commit,
  camera `cci_i2c` per-read logging, `iommu`/`initramfs` ramoops dumper (if no longer needed),
  ftrace defconfig (`FUNCTION_TRACER`/`FUNCTION_GRAPH_TRACER`/`DYNAMIC_FTRACE` — perf cost).
- [ ] **Confirm shared-file edits are sibling-safe or relocate to `pepito.dts`:** `pm8937.dtsi`
  `pmic-wd-bark` IRQ, `msm8937.dtsi` `status="disabled"` node. (`cam_smmu`/`msm_vidc` label adds are
  harmless.)
- [ ] **Delete strays:** `mi8937_defconfig.bak` and any other `*.bak`.
- [x] Gatekeeper/RPMB/FBE kernel diff **confirmed committed** (verified 2026-07-11): sdhci
  Auto-CMD12 fix `057578098068` + RPMB empty-slot fix `9d51b9a359b3` in history.
- [ ] Rebase/curate history into a reviewable sequence: real port work → resolved fixes → any
  remaining labelled `[TEMP]`.

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
- [ ] **Revert the `[TEMP] Mi8937: disable camera HAL packages` commit** (`31ff588d`) — camera works
  (2026-07-03); packages must be re-enabled for release.
- [ ] Re-scope pepito-only bring-up debt (see below).

### `device/xiaomi/mithorium-common` (14 dirty)

- [x] Review & commit — **✅ DONE 2026-07-11** (`4de80f5`..`1446eeb`: gatekeeper
  TARGET_DEVICE_PEPITO gate, camera HAL3 prop, single-SIM manifest + prop overrides, usb adb pin,
  ims file-caps drop, sepolicy dry-run grants, qrtr-tools, ril dep-closure/tftp_server).
- [ ] Ensure `manifest.xml` radio slot2 removal + qcrild autostart gating are **re-scoped
  pepito-only** (`on property:ro.vendor.xiaomi.device=pepito`), not applied to all siblings.
  Slot2 removal is committed as a labelled `[TEMP]` (`3481ae1`) — still all-siblings.

### Cross-cutting re-scoping (both repos) — `PLAN.md` "bring-up debt"

- [ ] **Wire `TARGET_DEVICE_PEPITO`** and gate the shallow bring-up edits behind it: Palm branding in
  `lineage_Mi8937.mk`, static-partition layout in `BoardConfig.mk`/`device.mk`/`fstab.qcom`,
  software-gatekeeper in `mithorium.mk`. Prevents sibling-build breakage / `repo sync` clobber.
- [ ] **Move the gatekeeper `.software` `file_contexts` rule out of AOSP `system/sepolicy`** into
  device sepolicy (Cuttlefish pattern) — AOSP edits get clobbered by `repo sync`.
- [ ] **Remove bring-up ADB root hacks + baked-in keys (security).** Strip the early
  auto-root/insecure-ADB shortcuts added during bring-up across **system and recovery**: any
  committed `adb_keys`/`vendor/adb_keys`, `ro.adb.secure=0`, `ro.secure=0`/`ro.debuggable=1`
  overrides, default-authorized-ADB or `persist.sys.usb.config` root shortcuts, and any
  ADB-root-in-recovery patch. A release build must use normal ADB authorization (prompt on first
  connect) and a signed keyset — no pre-trusted host keys, no auto-granted root.
- [ ] `TARGET_OTA_ASSERT_DEVICE += pepito`; `TARGET_SCREEN_DENSITY = 320` override.
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
- [ ] **`vendor/xiaomi` blobs:** decide the release model — commit into a `proprietary_vendor`
  git repo referenced by the manifest, or regenerate via `extract-files` from a documented stock/
  nightly source. A release must be reproducible; a non-git blob dir is not.
- [ ] **`diag-tools/`:** dev tooling — **must not ship in the image**. Confirm it's excluded from
  `PRODUCT_PACKAGES`/`PRODUCT_COPY_FILES`; keep it in the source repo (or a separate tools repo) but
  out of the flashable build. (`libqmi_force_ipcr` source now lives in the device tree under `qmux/`,
  not `diag-tools/` — verify the shipping copy is the device-tree one.)
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
