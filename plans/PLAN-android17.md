# PLAN-android17.md — Upgrade pepito to LineageOS 24.0 (Android 17)

**Goal:** move the shipped PVG100 ROM from LineageOS 23.2 (Android 16, `bp4a`, `android-16.0.0_r4`)
to LineageOS 24.0 (Android 17, `cp2a`, `android-17.0.0_r1`) without losing any of the July–September
work, and keep 23.2 shippable until 24.0 is validated on the bench.

**Status:** drafted 2026-09-10 from research only — nothing synced, nothing built. Facts below were
checked against GitHub/upstream on 2026-09-10; re-verify anything dated before acting.

---

## 0. What is already known (2026-09-10)

| Fact | Evidence | Consequence |
|---|---|---|
| Android 17 shipped 2026-06-16; LineageOS 24.0 branch exists (`lineage-24.0`, AOSP tag `android-17.0.0_r1`, release config **`cp2a`**), latest manifest commit 2026-08-30 "Forks for 2026-09 ASB". **No official 24.0 release/nightlies yet** — download API for Mi8937/Mi8917 still serves 23.2 only (latest 2026-08-18). | `gh api LineageOS/android`, `vendor/lineage/vars/aosp_target_release`, download.lineageos.org API | Lunch becomes `lunch lineage_Mi8937 cp2a userdebug`. Upstream is pre-release; expect churn until the official 24.0 announcement. |
| **All three Mi8937 repos already have `lineage-24.0` branches** and the port is tiny: device/Mi8937 = 1 commit, mithorium-common = 6 commits, **kernel = 0 commits (identical to 23.2)**. | `compare/lineage-23.2...lineage-24.0` on each repo | The msm8937 family is being carried to 24.0 by its maintainers (Nolen Johnson, Bruno Martins, Yumi Yukimura). Our 4.19 kernel + 95-commit `pepito-rmnet` branch carries over with no upstream base change. |
| Upstream's 7-commit port = exactly what A17 forced on this platform: (1) kernel Clang `r563880c`; (2) **legacy libion** (`soong_config_set_bool libion legacy_impl true` + `device/lineage/sepolicy/libion/sepolicy.mk`); (3) drop `disable_configstore` package; (4)+(5) sepolicy kangs/denials (`vendor_hal_vnddisplayconfig_service`, thermal, usb udc, wifi supplicant setuid, location→sensor service, rcsservice); (6) **displayservice HIDL → `lineage.frameworks.displayservice@1.0.vendor`** + `soong_config_set_bool surfaceflinger register_displayservice true` (camera HAL `QCameraDisplay.{cpp,h}` + `Android.bp` in both `camera/land` and `camera/mi8937`). One 23.2 commit is NOT on 24.0: `compat-vdso.config` kernel fragment include (2026-08-16). | scratchpad patches `mithorium-24.patch`, `mi8937-24.patch` | These are the mechanical conflicts we will hit when rebasing our device branches. The camera-HAL one touches a file family we forked (`camera.pepito`). |
| A17 platform notes relevant to us: **ION "no longer supported"** (upstream's answer is the legacy-libion switch — our camera HAL, JPEG, and 4.19 kernel are ION-based: `CONFIG_ION=y`, `mm_jpeg_ionbuf.c`, `QCameraMem.cpp`); **source tree is read-only during builds**; `memfd_class` policy capability required only for devices *launching* on A17 (we upgrade → not required); **Audio-managed SCO rearchitecture** (BT-SCO routing moves from BT stack to audio framework — our HFP in-call audio was validated 07-20 on the old path). HIDL is still deprecated-not-removed: upstream 24.0 Mi8937 still ships the same 43-HIDL vendor manifest. | source.android.com Android 17 release notes; `mithorium-common/manifest.xml` | Retest camera/JPEG/video, BT-SCO calls, and every build-time in-tree write (see §3). |
| **`hardware/qcom-caf/bt` (and `hardware/qcom/bt`, msm8996, msm8998, sdm845 caf trees) are GONE from the 24.0 manifest.** `hardware/qcom-caf/msm8953/{audio,display,media}` (what Mi8937 uses) survive at `lineage-24.0-caf-msm8953`. `LineageOS/android_hardware_qcom_bt` has no `lineage-24.0*` branch. Upstream `mithorium.mk` still lists `hardware/qcom-caf/bt/libbt-vendor` in soong namespaces (harmless if absent). | 24.0 `snippets/lineage.xml` vs 23.2 | Our Bluetooth is a **source-built libbt-vendor (Pronto/SMD on 4.19 + ROME-style BDADDR NVM write) living in our `hardware/qcom-caf/bt` fork** (3 commits on `lineage-23.2-caf`). On 24.0 we must add it to the local manifest ourselves and confirm the A17 `android.hardware.bluetooth@1.0` default service still dlopens `libbt-vendor.so`. Ask upstream how 24.0 Mi8937 does BT before assuming. |
| `hardware/qcom-caf/bt` aside, **every other repo we patch has a `lineage-24.0` branch upstream**: frameworks/base (09-08), frameworks/native, lineage-sdk, LineageParts, bootable/recovery, hardware/interfaces, hardware/lineage/interfaces, system/core, system/sepolicy, Launcher3, vendor/lineage (09-10); `system/bpfprogs` stays AOSP-remote. | `gh api …/branches/lineage-24.0` | Rebase targets exist for everything. |
| Our patch inventory to carry (all committed unless marked): kernel 95, device/Mi8937 92, mithorium-common 90, LineageParts 20, recovery 12, frameworks/base 6 (Sense face provider crDroid-16.0 port ×2, Compose QS volume slider, lock-screen battery indication, BatteryService FULL-at-cap, animator-scale seed), vendor/lineage 5 (**two aconfig overrides live under `aconfig/bp4a/…` — release-config-specific dir**, build-date injection, kernel-headers revert pair), hardware/interfaces 3, hardware/lineage/interfaces 3, qcom-caf/bt 3, bpfprogs 2, frameworks/native 1, lineage-sdk 1, system/core 1, **system/sepolicy 1 (5 neverallow exemptions for Play-cert row)**, **`packages/apps/Launcher3` `TaskbarManagerImpl.java` — UNCOMMITTED, load-bearing (3-button nav fix, needs the aconfig flag too)**, `build/make` 5 dirty (bench-only envsetup guard + 4 product mk edits — audit: are the product-mk edits bench-only or shipped?). Plus non-repo pieces: `vendor/xiaomi` blobs (`pepito-vendor`, nightly A15/A16 blobs + scripted DT_NEEDED fixups), `vendor/pepito-gapps` (NikGapps **Android-16** basic + AA addon + GoogleTTS addon), PepitoLauncher2, MicroG priv-app, Magisk ≥30.7 root image, PIF graft (staged/uncommitted per memory — verify). | `git log m/lineage-23.2..HEAD` per repo; `repo forall` dirty sweep 2026-09-10 | Rebase plan in §2. |
| **NikGapps has no Android-17 packages yet** (latest is 16-2026-09-09 crDroid unofficial). | web 2026-09-10 | Gapps variant is gated on NikGapps; vanilla variant is not. Plan vanilla-first. |
| crDroid has a `17.0` frameworks_base branch. | `gh api crdroidandroid/android_frameworks_base/branches` | Re-port Paranoid Sense (face unlock) from crDroid 17.0 rather than forward-porting our 16.0 patch blind. |
| Disk: local tree is 198 GB (`.repo` 85 GB, `out` 146 MB) with 173 GB free on `/`. Builder Stellaris16 (10.0.2.43) was **unreachable** ("No route to host") at survey time. | `df`, `du`, ssh | A second full tree does not fit locally without `--reference`; builder disk unknown — check when awake (memory `stellaris16-gdm-suspend`). |
| 12 scripts hard-code `lineage-23`/`23.2`/`bp4a`/`/home/kyle/android/lineage-23` (build, remote build, release-all, release, prepare-flash, flash-staging, magisk, changelog, OTA json, nikgapps extractor, backup). Landing repo branch is `lineageos23.2`; manifest `manifests/pepito.xml` pins tag `pepito-23.2-r1`. | grep | Versioning sweep in §5. |

---

## 1. Strategy + decisions to make first

**Recommended shape:** a **second tree** (`~/android/lineage-24/`) beside the 23.2 tree, synced with
`repo init … -b lineage-24.0 --reference=/home/kyle/android/lineage-23` so objects are shared, and a
**`pepito-24` branch family** created by rebasing each `pepito-*` branch onto its `lineage-24.0` base.
23.2 stays the shipping/maintenance tree until §4's matrix is green on 24.0. Reasons: upstream is
pre-release and will churn; gapps is blocked on NikGapps; a broken 24.0 tree must not take the daily
drivers (Gold) with it.

Decisions for Kyle before Phase 1 (defaults in bold):
- [ ] **Two trees (shared objects)** vs in-place `repo init -b lineage-24.0` on the 23.2 tree. In-place
      saves disk but kills the 23.2 fallback — not recommended while 23.2 is what the fleet runs.
- [ ] **Vanilla first**, gapps when NikGapps ships an Android-17 basic pack (or decide to bake the A16
      pack and validate on A17 — risky: privapp-permission/sysconfig drift is why NikGapps is per-version).
- [ ] Track upstream `lineage-24.0` **now** (pre-release, churn) vs wait for the official 24.0 announcement.
      Recommendation: sync + rebase now (cheap: upstream port is 7 commits), but do not cut a 24.0 release
      before official Mi8937 24.0 nightlies exist — that is the signal the family is supported.
- [ ] Keep 23.2 releases flowing meanwhile? If yes, treat every 23.2 fix as "commit on `pepito-rmnet`,
      cherry-pick to `pepito-24`" from day one to avoid a second divergence.
- [ ] Where builds run: builder Stellaris16 needs ~250 GB free for a second tree + out; check when it is
      awake. Alternative: build 24.0 on the builder and keep 23.2 local-only (or vice-versa).

Hard rules carried over from the working agreements: **Kyle builds + flashes** (I stage and describe);
never `repo sync` the 23.2 tree's patched AOSP repos without the `pepito-*` branches checked out
(detached-HEAD survey hazard from 2026-07-11); never airplane-cycle during WFC validation; verify
`ro.serialno` before touching a phone.

---

## 2. Phase 1 — Stand up the 24.0 tree and prove upstream builds

- [ ] **Freeze 23.2 first.** Commit the uncommitted load-bearing bits so they exist as commits to carry:
      `packages/apps/Launcher3` TaskbarManagerImpl patch (branch `pepito-taskbar`, fork needed),
      audit `build/make` 5 dirty files (envsetup guard = bench-only; the 4 `target/product/*.mk`
      edits — what are they, do they ship?), PIF graft (memory says staged/uncommitted — find and commit
      or drop). Tag every pepito branch `pepito-23.2-pre24` so the rebase has a fixed origin. Run
      `/release-sweep` to confirm clean + pushed.
- [ ] **Wake the builder**, record free disk on both machines, decide placement (§1).
- [ ] `repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --reference=/home/kyle/android/lineage-23`
      into `~/android/lineage-24/`; local manifest = the three Mi8937 repos on **upstream**
      `lineage-24.0` plus `hardware/qcom-caf/bt` from **our fork** (`pepito`, base `lineage-23.2-caf`)
      because upstream dropped it. `repo sync`.
- [ ] **Build stock `lineage_Mi8937 cp2a userdebug` with zero pepito changes.** Purpose: separate
      "A17 breaks this family" from "our patches broke it". Expect: kernel headers genrule works,
      legacy libion, displayservice fork. If BT fails to link without `qcom-caf/bt`, we learn how
      upstream intends BT on 24.0 (ask on the Mi-Thorium channel / read their 24.0 device commits).
- [ ] Note the `compat-vdso.config` fragment that 23.2 has and 24.0 lacks — decide whether pepito wants it.
- [ ] Recreate bench-only tree state the build depends on: `generated_kernel_headers` is a genrule now
      (nothing to recreate), but `hardware/qcom-caf/common/kernel/` is an untracked header artifact —
      find what produced it and whether A17's **read-only source tree** rejects it (§3).
- [ ] Scripts: parametrize `LINEAGE_ROOT`/`REMOTE_ROOT`/version (`24.0`, `cp2a`, zip glob
      `lineage-24.0-*`) in `build-lineage23.sh` and `build-lineage23-remotely.sh` (rename or add
      `build-lineage24*.sh` wrappers; keep the 23.2 ones working).

## 3. Phase 2 — Rebase the pepito work onto `lineage-24.0`

Order = least-coupled first, device repos last (they are where the upstream port landed). For each:
`git rebase --onto <upstream lineage-24.0> <tag pepito-23.2-pre24-base> pepito-24`, resolve, build.

| Repo | Carry | Expected friction | Notes |
|---|---|---|---|
| `kernel/xiaomi/msm8937` | 95 commits | **None from base** (24.0 == 23.2). Real risk = **Clang r563880c** (new warnings-as-errors in our backported ipc_router/qmux/rmnet/tfa98xx/BHy code; the load-bearing `[TEMP]` commits in `phase2-loadbearing-disguised-commits`). | Build kernel-only first (`--boot-only`). Keep defconfig delta identical. |
| `system/bpfprogs`, `frameworks/native` | 2 + 1 | Low; re-check that timeInState still needs the CO-RE revert + `-mcpu=v2` on A17 (AOSP may have changed the tracepoint defs again). | Validate with the zero-CPU-attribution check (memory `bpf-timeinstate-core-btf`). |
| `system/core` | 1 | Trivial. | |
| `system/sepolicy` | 1 (5 neverallow exemptions, Play-cert row) | Re-apply on every merge (known). Check A17 added new neverallows that hit `pepito_gsfid`. `memfd_class` not required (upgrade). | Verify with the checkpolicy trick in PLAN.md. |
| `hardware/interfaces` | 3 | radio-compat HIDL wrapper (load-bearing, memory `tombstone-noise-cleanup`), BT HIDL binary-BDADDR, sensors input group. A17 may have moved/removed `radio/compat` or `bluetooth/1.0/default` — confirm they still exist before rebasing. | If `bluetooth/1.0/default` is gone, BT needs a new home (see qcom-caf/bt). |
| `hardware/lineage/interfaces` | 3 | camera AIDL torch strength on legacy HALs, provider fail-safe, radio config wrapper exit. | Torch tile + variable brightness retest. |
| `hardware/qcom-caf/bt` | 3 (+ the whole repo) | **Repo dropped upstream.** Carry our fork in the local manifest; confirm consumer (`android.hardware.bluetooth@1.0-service` / `libbt-vendor` dlopen) still exists on A17. | Retest BDADDR NVM write + HFP (A17 audio-managed SCO). |
| `vendor/lineage` | 5 | **`aconfig/bp4a/` → `aconfig/cp2a/`** for `enable_taskbar_on_phones` (off) and the flashlight-strength slider; kernel-headers pair is a net-zero, drop it; keep `LINEAGE_BUILD_DATE` injection (release scripts depend on it). | Flags may have been renamed/removed in A17 — check `com.android.wm.shell` and SystemUI flag files. |
| `lineage-sdk`, `LineageParts` | 1 + 20 | Settings-DB upgrade step for `QS_SHOW_VOLUME_SLIDER` must bump again if upstream bumped the DB version (memory `qs-volume-slider`). Pepito Tweaks screens are self-contained. | |
| `bootable/recovery` | 12 | Power-key navigation + EDL + adbd-as-root; recovery UI churns each release. | |
| `packages/apps/Launcher3` | 1 (uncommitted today) | `TaskbarManagerImpl.isTaskbarEnabled()` patch; Launcher3 changes every release. | Needs both the patch and the aconfig flag (memory `navbar-taskbar-hosting`). |
| `frameworks/base` | 6 | **Biggest item.** Re-port Paranoid Sense from crDroid **17.0** (don't rebase the 16.0 port); Compose QS volume slider (QS Compose code churns every release); lock-screen battery indication; BatteryService FULL-at-cap; SettingsProvider animator seed. | Face unlock is WEAK-class; A17 biometrics changes may require the null-retriever guard again. |
| `device/xiaomi/mithorium-common` | 90 | Conflicts with upstream's 6 commits: `BoardConfigCommon.mk` (clang ver + libion sepolicy include), `mithorium.mk` (libion soong flag, configstore removal, displayservice fork), 11 sepolicy files. Our qmux/rmnet/ims sepolicy sits beside theirs — mostly additive. `manifest.xml` slot2 removal is a whole-file `[TEMP]` — re-diff against upstream's 24.0 manifest. | Drop our own `disable_configstore` if we had one. |
| `device/xiaomi/Mi8937` | 92 | Conflict on `camera/mi8937/camera/QCamera2/{Android.bp,util/QCameraDisplay.*}` (displayservice fork) — our `camera.pepito` HAL is built from this family, so apply the same displayservice change to the pepito HAL copy. `device.mk`/`BoardConfig.mk` pepito gates should merge clean. | Camera regression history (`camera-chromatix-packaging-regression`) → full camera retest. |
| `vendor/xiaomi` (blobs) | 4 commits + fixups | Blobs must come from a **24.0 Mi8937 nightly** once one exists (A15/A16 nightly blobs on A17 = untested ABI). Until then, build 24.0 against the current blob set and see. `extract-files.py` DT_NEEDED fixups are scripted → re-run. **GUARDRAIL: no extract-utils regen on mithorium-common** (IMS add-on). | Re-run `getcap` on preloaded daemons after re-extract. |
| `vendor/pepito-gapps` | NikGapps A16 payload | **Blocked on NikGapps Android-17.** Options: wait; or run `extract-nikgapps.py` on the A16 pack and validate on A17 (GMS APKs are usually forward-compatible, the risk is privapp-permissions/sysconfig drift + the `EXCLUDED_APP_SETS` DeskClock bootloop class of bug). | Also bake current Carrier Services (RCS lane) while touching it. |
| PepitoLauncher2, MicroG priv-app, Magisk root image, PIF graft, OpenEUICC | in-tree/source | Bump targetSdk where needed; Magisk ≥ 30.7 minimum still applies; PIF graft is evidence-only (Play Integrity is server-500, unfixable) — decide whether to carry it at all. | |

Rebase hygiene: keep `pepito-rmnet` untouched as the 23.2 branch; new branches are `pepito-24`
(device/kernel) and `pepito-24-<topic>` for AOSP repos; push to the same `solarkennedy` forks; regen
`manifests/pepito.xml` as `pepito-24.0-r1` with the extra `hardware/qcom-caf/bt` and Launcher3 overrides.

## 4. Phase 3 — Android 17-specific hazards to check on pepito (beyond rebase conflicts)

- [ ] **ION.** Upstream's `libion legacy_impl` keeps the userspace lib; the 4.19 kernel keeps `/dev/ion`.
      Validate camera preview+JPEG (`mm_jpeg_ionbuf.c`), Venus HW encode (scrcpy), video playback,
      display composition (MDP overlays, libsdmextension dlopen closure), face unlock (RGB frames).
- [ ] **Read-only source tree during build.** Find every in-tree write: `hardware/qcom-caf/common/kernel/`
      untracked artifact, any `extract-files.py`/gapps-extract step that runs inside the build, scripts
      that `ln -s` into `vendor/`. Move outputs to `out/` or run them pre-build.
- [ ] **Audio-managed SCO.** Retest HFP call both directions on a car + a headset; the 07-20 validation
      was on the BT-stack-managed path. Watch `INT_BT_SCO_RX/TX` widgets as before.
- [ ] **SELinux.** New A17 neverallows vs our qmux/rmnet/ims/ifw/pepito_gsfid domains — run the
      checkpolicy pre-check (PLAN.md §Verifying SELinux) before the remote build; collect denials on
      first Enforcing boot (never ship Permissive).
- [ ] **HIDL still tolerated?** Upstream 24.0 Mi8937 ships the 43-HIDL manifest, so yes for now; note
      `radio` HIDL + our compat wrapper. Record the A17 VINTF `target-level` we build with.
- [ ] **aconfig release dir** (`bp4a` → `cp2a`) — build fails silently into defaults if the flag values
      file is in the wrong dir: verify taskbar OFF and flashlight slider ON at runtime, not just at build.
- [ ] **Settings/provider DB versions** (QS slider default, mobile-data seeds, animator scale) — dirty-flash
      from 23.2 must upgrade, not re-create.
- [ ] **16 KB pages:** not applicable (4 KB 4.19 kernel, upgrading device); confirm no A17 build-time
      16 KB ELF alignment check trips on our source-built HALs / patched blobs (`patchelf`ed radio blobs).
- [ ] **Bluetooth stack without `hardware/qcom-caf/bt` upstream** (§0). Prove pairing, A2DP, HFP, BDADDR
      persistence across a wipe-flash (the 07-20 flash wiped bonds — release-note it again).
- [ ] **Play services on A17 with an A16 gapps pack** (if that route is taken): Play Store, sign-in, AA
      stub in `/product/priv-app`, GoogleTTS role grant (`SYSTEM_SPEECH_RECOGNIZER` → RECORD_AUDIO),
      Contacts sync cold-boot race.

## 5. Phase 4 — Bench validation (the release matrix, plus the A17 deltas)

Run `PLAN-release.md` Phase 9 verbatim on DUT1 first, then a **fresh-unit witness** (Gold or 9c2e6b00)
because "works on DUT via accumulated modem NV" is a known trap (WFC field4). Additions for 24.0:

- [ ] Telephony end-to-end incl. **VoLTE + WFC** (no airplane cycling; validate VOICE not the SMS bar),
      NAS cold-cycle re-attach ≤ 5 s, RCS.
- [ ] Sensors 20/20 + BHy recovery path (`0f46503b31ef`), prox/ALS from `/persist`.
- [ ] Camera both cams + JPEG + FD subst; torch tile + strength slider; flash state machine.
- [ ] Face unlock enrol + keyguard unlock (re-ported Sense).
- [ ] QS volume slider, 3-button nav (taskbar OFF), Life Mode tile, Sunlight SRE, colour transforms.
- [ ] Battery: attribution non-zero (timeInState), health screen + ESR row, charging control, FULL-at-cap.
- [ ] Tethering Wi-Fi + USB NCM + BPF offload; USB webcam; OTG; wired Android Auto in-car.
- [ ] Perf: zram lz4 default, interaction boost live, GPU floor toggle; idle floor ~3.3 mA airplane.
- [ ] **Dirty-flash upgrade 23.2 → 24.0** (sideload OTA, no wipe): boots, FBE keys intact, settings kept,
      no FRP `config` desync prompt. Then a **clean flash + wipe** on a second unit.
- [ ] SELinux Enforcing, denial harvest = skip-list only.

## 6. Phase 5 — Productize 24.0

- [ ] Version sweep in the landing repo: `scripts/*` (12 files), `pepito.json` OTA feed (keep a 23.2
      channel and add 24.0, or one channel with the upgrade OTA), `manifests/pepito.xml` →
      `pepito-24.0-r1` tag set, `BUILD.md` lunch line, `CHANGELOG.md`, landing README table (branch
      column), landing repo branch `lineageos24.0`. Release via `release-remotely.sh` (releases run on
      the builder; never rsync big artifacts to netbook4).
- [ ] Re-sign with the existing 5-key `.android-certs` set; confirm the BT mainline sepolicy cert var still
      applies (`signing-keys-bluetooth-seinfo`).
- [ ] Both EDL rawprogram XMLs (PVG100 + PVG100E), Magisk root image, recovery image.
- [ ] Release notes: A17 delta, dirty-flash path, gapps status (vanilla-only if NikGapps is late), BT
      bonds wiped on clean flash, known-issues carried from 23.2 (SIM-PIN auto-verify, SIM toggle trap,
      Play-uncertified grace behaviour, eSIM ISD-R refusal).
- [ ] Decide 23.2's fate after 24.0 r1: security-only until the fleet is moved, then archive the branch
      set (keep tags).

## 7. Open questions / things to find out first

1. How does upstream 24.0 Mi8937 do Bluetooth without `hardware/qcom-caf/bt`? (Read Mi-Thorium's
   `a17/*` or LineageOS `lineage-24.0` device history; ask.)
2. Does A17's `hardware/interfaces` still contain `bluetooth/1.0/default` and `radio/compat`?
3. Are the `enable_taskbar_on_phones` and flashlight-strength flags still present/renamed in `cp2a`?
4. Builder disk + whether both trees can coexist there.
5. NikGapps Android-17 ETA; MicroG 0.3.x on A17.
6. Which 24.0 Mi8937 nightly (when it exists) to pull blobs from — and whether the A15 qcril/IMS blob
   set (+ force-ipcr DT_NEEDED) still loads on A17's bionic/VNDK-less vendor.

## 8. Not doing

- Not moving to dynamic partitions, GKI, or a newer kernel for this upgrade — 24.0 upstream kept the
  4.19 kernel unchanged; nothing in the A17 notes forces it for an upgrading device.
- Not resuming RE lanes or Play Integrity work as part of the upgrade.
- Not upgrading in place on the 23.2 tree (§1 default).

## Cross-references

`PLAN.md` (map), `PLAN-release.md` (Phase 9 matrix + versioning), `PLAN-kernel.md`,
`PLAN-camera.md`, `PLAN-bluetooth.md`, `PLAN-face-unlock.md`, `PLAN-vowifi.md`; memory:
`build-and-vendor-notes`, `builder-tree-divergence`, `releases-on-build-server`,
`navbar-taskbar-hosting`, `phase2-loadbearing-disguised-commits`, `selinux-enforcing-prep`,
`bpf-timeinstate-core-btf`, `nikgapps-deskclock-bootloop`, `bt-bdaddr-controller-fix`.
