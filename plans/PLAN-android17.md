# PLAN-android17.md — Upgrade pepito to LineageOS 24.0 (Android 17)

**Goal:** move the shipped PVG100 ROM from LineageOS 23.2 (Android 16, `bp4a`, `android-16.0.0_r4`)
to LineageOS 24.0 (Android 17, `cp2a`, `android-17.0.0_r1`) without losing any of the July–September
work, and keep 23.2 shippable until 24.0 is validated on the bench.

**Status:** 2026-10-05 — Phase 1 under way: builder tree `~/android/lineage-24` synced as a pure-upstream baseline (see §2). Nothing built yet. Facts below were
checked against GitHub/upstream on 2026-09-10; re-verify anything dated before acting.

---

## Re-scan 2026-10-04 — blocker status

| Blocker (09-10) | Now | Evidence |
|---|---|---|
| "No release before official Mi8937 24.0 nightlies" (§1 gate) | **Gate is dead.** Yumi Yukimura **dropped OFFICIAL support for Mi8917/Mi8937/Mi439 on 2026-08-21** (hudson `3c395bed2`); last Mi8937 nightly 23.2 2026-08-18. There will be no official 24.0 nightlies. The maintainer still pushed the `lineage-24.0` device commit on 09-10 and keeps `Mi-Thorium/…mithorium-common` `a17/master` alive. Separately, hudson has **zero** `lineage-24.0` targets for any device, so 24.0 has not shipped anywhere yet. | `gh api LineageOS/hudson` |
| Upstream port status | Unchanged since 09-10. Mi8937 +1, mithorium-common +6/−1 (still missing `compat-vdso.config`), kernel 24.0 == 23.2. **New:** Mi-Thorium `a17/master` has `TARGET_COMPILE_WITH_MSM_KERNEL := true` (09-07, "now unset from lineage side, however our stuff still needs it"), and LineageOS `lineage-24.0` does **not**. Take it, or the build likely breaks. | compare APIs |
| `hardware/qcom-caf/bt` dropped | Still dropped; no 24.0 branch. Open Q1 answered: upstream mithorium.mk uses the **prebuilt** path (`android.hardware.bluetooth@1.0.vendor`, qti btconfigstore/bt-audio), which is why they don't need caf/bt. We do, because we source-build libbt-vendor, so the plan stays: carry our fork via the local manifest. | 24.0 `mithorium.mk` |
| `bluetooth/1.0/default`, `radio/compat` on A17 (Q2) | **Both present** on `lineage-24.0` hardware/interfaces. Not a blocker. | contents API |
| NikGapps A17 | **Still none** (SF `Releases/Android-17` = 404). **New option: MindTheGapps `cinnamonbun` (A17) branch is active** (last commit 09-15). Possible bridge for the gapps variant, but it means re-validating the pepito-gapps packaging (AA stub, GoogleTTS, DeskClock exclusion). | SF, GitHub |
| crDroid 17.0 (Sense re-port source) | `17.0` branch exists. Unblocked. | |
| microG | v0.3.17 released 09-29. Retest on A17 only. | |
| Builder disk (Q4) | **Resolved:** builder reachable, 540 GB free, which is enough for a second tree. Local only has 145 GB free (was 173), so a local second tree still needs `--reference`, and the builder is the better home. | ssh/df |
| Freeze-23.2 uncommitted items | Launcher3 `TaskbarManagerImpl.java` **still uncommitted**. `build/make` audit answered: envsetup = bench-only, but **the 4 product-mk edits SHIP**. They add `TARGET_EXCLUDES_{SECURE_ELEMENT,WAPPUSH,ONS}` guards, and `lineage_Mi8937.mk:14-16` sets all three. These are load-bearing debloat changes, **uncommitted, in an unforked repo**. They need a `build/make` fork and a commit before the rebase. | git status |
| Patch inventory drift | device/Mi8937 102 (was 92), mithorium-common 111 (was 90), kernel 97, LineageParts 25. More to rebase, still mechanical. | `rev-list m/lineage-23.2..HEAD` |

**Net:** no hard technical blocker on the device side. The real blockers are now (1) **policy**: the "wait for official nightlies" gate can't fire, so Kyle needs a new go signal (proposal: upstream 24.0 general release, or just "our matrix is green"); (2) **gapps**: NikGapps A17 is absent, and MindTheGapps A17 is the alternative; (3) **freeze hygiene**: Launcher3 plus the build/make debloat guards must become commits; (4) **blob source**: no 24.0 Mi8937 nightly will ever exist to pull blobs from (Q6), so we build A17 on the current A15/A16 blob set and validate. That was already the fallback, and now it's the only path.

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

- [~] (2026-10-06: Launcher3 → `solarkennedy/android_packages_apps_Launcher3` `pepito-taskbar` `f3967a3bd7`; build/make → `solarkennedy/android_build` `pepito-debloat` `a597dfac73` (4 product-mk guards; envsetup.sh netbook4 guard left uncommitted = bench-only); both added to `manifests/pepito.xml`, `TAG_REPOS`, changelog `REPOS`. PIF graft DROPPED (Kyle 10-06). Left: `pepito-23.2-pre24` tags.) **Freeze 23.2 first.** Commit the uncommitted load-bearing bits so they exist as commits to carry:
      `packages/apps/Launcher3` TaskbarManagerImpl patch (branch `pepito-taskbar`, fork needed),
      audit `build/make` 5 dirty files (envsetup guard = bench-only; the 4 `target/product/*.mk`
      edits — what are they, do they ship?), PIF graft (memory says staged/uncommitted — find and commit
      or drop). Tag every pepito branch `pepito-23.2-pre24` so the rebase has a fixed origin. Run
      `/release-sweep` to confirm clean + pushed.
- [x] (2026-10-05: builder up, 540 GB → 346 GB free after sync; tree lives on the builder only) **Wake the builder**, record free disk on both machines, decide placement (§1).
- [x] (2026-10-05, baseline variant: local manifest = upstream device/kernel `lineage-24.0` + TheMuppets blobs `lineage-23.2`; our caf/bt fork deferred to Phase 2; sync needs `-j6 --retry-fetches=5`, AOSP 429s at -j16) `repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --reference=/home/kyle/android/lineage-23`
      into `~/android/lineage-24/`; local manifest = the three Mi8937 repos on **upstream**
      `lineage-24.0` plus `hardware/qcom-caf/bt` from **our fork** (`pepito`, base `lineage-23.2-caf`)
      because upstream dropped it. `repo sync`.
- [ ] (2026-10-05 build #1: 1h02m, 130626/236607 done, ONE failure = XiaomiParts javac — upstream devicesettings `01e1033` (same day) deleted `doze_settings_help_{title,text}` still used by mithorium-common parts. Pinned devicesettings to parent `b3556d4` via `extend-project` in the builder's local manifest. Durable fix = carry the 2 strings in our mithorium-common `parts/res`.) **Build stock `lineage_Mi8937 cp2a userdebug` with zero pepito changes.** Purpose: separate
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

**2026-10-06 progress:** `pepito-24` pushed for kernel (97/97 clean, 1172 upstream commits caught up, same clang r563880c as 23.2), Mi8937 (clean + `d5b345cb` camera.pepito displayservice), mithorium-common (5 sepolicy/mk unions + `855c9b7` doze strings). Builder `lineage-24` manifest switched to these + qcom-caf/bt `pepito` + vendor/xiaomi + PepitoLauncher2. AOSP-repo forks not rebased yet.

**✅ 2026-10-06: first pepito A17 build GREEN** on the builder (`lineage-24.0-20261006-UNOFFICIAL-Mi8937.zip`, Palm/PVG100, release-keys, static partitions). Along the way: signing keys (`vendor/lineage-priv` + PepitoLauncher2 cert) copied builder-locally; FaceUnlock from crDroid `17.0`; OpenEUICC DROPPED (Mi8937 `6c1fb8f1`); `system/sepolicy` fork cherry-picked (`312f75078`, pepito_gsfid). Not flashed.

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

- [x] **DONE 2026-10-09 (fork `android_system_fs_fs_mgr` `pepito-24` `46951e8`, in the manifest; unbuilt — needs a recovery rebuild + flash to confirm): silence the recovery `libfs_mgr` f2fs `linear_lookup` error on 24.0.** It was
      silenced on 23.2 by `system/core` `b85c87a728` (PERROR → PLOG(DEBUG): 4.19 has no
      /sys/fs/f2fs/features/linear_lookup, the fallback is normal). On A17 fs_mgr moved to its own project
      `system/fs/fs_mgr` (`LineageOS/android_system_fs_fs_mgr`), so this needs a new fork + one-line port + a
      manifest entry. Cosmetic; Kyle saw it on the recovery screen.

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
- [ ] **Tethering — all three must work, NEEDS A SIM** (Kyle, 2026-10-07): **Wi-Fi hotspot**, **Bluetooth
      tethering (PAN)** and **USB tethering (NCM)**, each passing real traffic from a client over mobile data
      (not just "enabled"), plus BPF tether offload active. 23.2 validated hotspot + USB NCM (Wi-Fi upstream) and a
      hotspot over LTE with BPF offload (Gold, 08-22); Bluetooth PAN was never tested (memory: tethering-works-oob).
      **A17 2026-10-07: ✅ USB NCM over LTE** (netbook client via a policy-routed NM profile: carrier IPv4
      174.231.x + native VZW IPv6, 10 MB @ ~335 KB/s at RSRP −105, BPF offload forwarding 10.4 MB on rmnet_data1).
      **✅ Wi-Fi hotspot over LTE** (new2 client, 2.4 GHz: DHCP + DNS + its own app TCP/QUIC NATed via BPF on
      rmnet_data1; ⚠️ ping loss 40% then 7% with up to ~1 s RTT vs 0% on USB — weak LTE (−105) vs 2.4 GHz vs
      hotspot unknown, follow-up). **✅ Bluetooth PAN over LTE, IPv4** (netbook client, first-ever PAN test: carrier
      IPv4, 0% ping loss, 2 MB @ ~48 KB/s). **❌ BT PAN IPv6:** prefix advertised but DUT1's ND for the client's
      global address FAILS on bt-pan ⇒ no BPF IPv6 downstream rule ⇒ no replies (USB IPv6 fine) — likely multicast
      ND not crossing BNEP (BlueZ filter?) rather than A17; follow-up. Also ✅ BT pairing (netbook ↔ DUT1).
- [ ] USB webcam; OTG; wired Android Auto in-car.
- [ ] Perf: zram lz4 default, interaction boost live, GPU floor toggle; idle floor ~3.3 mA airplane.
- [ ] **Dirty-flash upgrade 23.2 → 24.0** (sideload OTA, no wipe): boots, FBE keys intact, settings kept,
      no FRP `config` desync prompt. Then a **clean flash + wipe** on a second unit.
- [ ] SELinux Enforcing, denial harvest = skip-list only.

## 6. Phase 5 — Productize 24.0

- [x] **Decide the emergency-only watchdog before the 24.0 release** — **DECIDED 2026-10-11 (Kyle): keep it,
      off by default** (already the case: `go_tweaks_settings.xml` `defaultValue="false"`; no code change).
      Original item (Kyle, 2026-10-07): revert it from
      23.2 + 24 if the root cause is found first. Pieces: mithorium-common `143e994`, LineageParts
      `69219ab8`, the notification code carried in beacon commit `c0624c2`, and XiaomiParts'
      POST_NOTIFICATIONS (verify no other XiaomiParts notifications first).

**Upgrade path decision (Kyle, 2026-10-06): in-place OTA via a FINAL 23.2 release**, cut only
once 24.0 is stable and has gapps. That 23.2 release sets `lineage.updater.allow_major_upgrades=true`
and moves `lineage.updater.uri` to the `lineageos24.0` branch.
- ONE feed, v2 only (Kyle chose option 3, 2026-10-06): the 24.0 (A17) Updater parses LineageOS
  API-v2 (top-level array, `files[]` with `os_sdk_level`/`os_patch_level`); the 23.2 Updater fork
  now ALSO reads v2 (`packages/apps/Updater` `pepito-ota-changelog` `6dd23de`; host-harness-tested
  on the live legacy feed + a v2 sample). So 24.0 publishes only `lineageos24.0/pepito.json` (v2,
  `os_sdk_level: 37`), and the final 23.2 release points straight at it. Before shipping that
  release: put a v2 test entry in a scratch feed and confirm a 23.2 phone offers + installs it.
- (Corrected 2026-10-06: the A17 Updater's `NetworkUpdate` is `@JsonIgnoreUnknownKeys`, so extra
  keys like `changelog` are safe even for a stock 24.0 Updater.) Our 24.0 Updater fork
  (`pepito-24` `153249c`) shows them as "What's new" via a side `ChangelogStore` (no Room schema
  change, so no collision with upstream's next migration).
- romtype channels must carry over (vanilla UNOFFICIAL, gapps SNAPSHOT) so each variant is offered
  its own 24.0 build.
- Gate: a dirty-flash 23.2 → 24.0 (gapps over gapps) must pass on a bench unit first.
- pepito-24 `device.mk` must point `lineage.updater.uri` at `lineageos24.0/pepito.json`.

- [x] **Released `20261017` (2026-10-17 vanilla, tag `pepito-24.0-20261017`; gapps added to the same release 2026-10-18 via `release-all.sh --version 20261017 --gapps` — that resume run blanked the 20261017 changelog section and the gapps feed entry's changelog, restored by hand in `ea72487`)**: first 24.0
      release dated after the final 23.2, so 23.2 phones are offered it. Ships the emergency-only fix
      below, the list_del panic + userfaultfd kernel fixes, MGLRU, WFC Wi-Fi preferred (Mi8937
      `b82254d8`), the B12 switch, the PALM splash/boot animation, and the Updater nested-scroll fix
      (`ea2d74d`). 24.0 phones on `20261011` still have the crashing Updater dialog: they must
      sideload this one.
- [x] **Gate for the next 24.0 release (Kyle, 2026-10-14): fix the emergency-calls-only stick first**
      (`PLAN-emergency-only.md`) and ship it in that release. **STAGED 2026-10-15**: data-centric
      `usage_preference=2` asserted by `ims_enabler` at boot from a new Settings > System > "Modem
      tweaks" switch (default on, restart to apply, readback row); the watchdog toggles moved there
      out of Pepito Tweaks. Pushed (LineageParts `34cd6354`, Mi8937 `442f1a54`); validated on new2 10-15 (probe-cap bug fixed, `d08e4c86`); boot readback correct from the next build. The release must also be dated after the
      final 23.2 (`20261013`) or the 23.2 Updater will not offer it; kernel `pepito-24` `50c36c782d89`
      (list_del panic fix, `PLAN-list-del-panic.md`) rides along.
- [x] 23.2's fate: **final release `20261013` cut 2026-10-13**, points its Updater at the 24.0 feed with
      `allow_major_upgrades`. No further 23.2 releases; the tree stays for reference.
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

## Bench results 2026-10-08

- **✅ Customer dirty flash (Gold, 23.2 `20260828` gapps + real account → 24.0 `20261007` gapps, userdata kept).**
  Boot ~97 s, 0 crashes, account kept, all Play-updated Google apps kept their versions, Assistant + speech
  roles held, face enrolment kept, GPU-floor default applied. Second-unit sweep on Gold: 20/20 sensors, 2
  cameras, Enforcing with only the known denial set, verified boot green, FBE, zram lz4, CPU-attribution BPF
  maps present, GNSS HAL + gps provider up, Widevine service running. Flash Gold with
  `gold-adb reboot edl` + `flash-staging.sh --no-adb` (the script's own trigger is hard-wired to DUT1).
- **✅ 23.2 Updater reads the v2 feed (Silver, Updater `6dd23de` installed as an app update, then removed).**
  A v2 array feed parses; an older entry is filtered; the 24.0 entry lists; "What's new" shows the feed
  changelog + Full changelog link. With defaults the button is **INFO** (major upgrade blocked); with
  `lineage.updater.allow_major_upgrades=true` it becomes **DOWNLOAD**. ⇒ the final 23.2 release must ship
  that prop AND the 24.0 feed URL. Tested by seeding the Updater's cached `updates.json` (cleartext HTTP is
  blocked for the app, so a local test server cannot be used). **Not yet tested:** the real HTTPS fetch of
  the 24.0 feed, and the actual recovery install of a 24.0 zip over 23.2.
- **⚠️ Gold's replacement battery: ~0.52 Ω** by an active load step (62 mA @ 4.264 V vs 867 mA @ 3.844 V, full
  charge, 26–30 °C) — not the 0.10–0.20 Ω hoped for, and no better than the old worn cell's 0.45 Ω.
  Repeat at ~50 % charge before selling Gold.
- **Deferred:** Bluetooth-tether IPv6 with a phone client — needs a cellular-upstream phone; Silver and new2
  were running the stick-lane captures and DUT1 was off the bench.

## Bench result 2026-10-15 — B12 band toggle lane (Modem tweaks candidate row)

- **Which band:** B12 (B13 is already on). FCC-certified, hidden by per-unit modem NV; only buys
  T-Mobile/regional 700 MHz A-block. Verizon never uses it.
- **Lever FOUND (read-only so far, dut1):** legacy NV **6828 `LTE_BC_CONFIG_I`** reads
  `1a 10 01 00 00 00 08 00` = `0x000800000001101a` (B2 B4 B5 B13 B17 + bit 51 ≙ B66), **bit 11 (B12)
  clear**; NV 1877 `RF_BC_CONFIG_I` = `0x06e80180`, byte-for-byte the DMS 0x45 legacy mask. The
  seven-band unit (6210972a) reported `0x1181a`, i.e. the same mask with bit 11 set. Legacy numbered
  NV **is readable over diag DCI** (`/nvm` is only denied via EFS2) — new tool
  `~/android/lineage-23/diag-tools/nv-probe/` (`read`/`bands`/`spc`/`write`, uncommitted; on dut1 at
  `/data/local/tmp/nv-probe`). ✅ **Write path (diag 0x27) WORKS** — Kyle ran it 10-15 ~14:55: status DONE,
  no SPC needed, readback shows bit 11 set. Reboot + capability re-probe pending.
- **Next (Kyle, dut1 c39a6acf; reversible, old value above, stock dump banked):**
  ```
  dut1-adb shell 'cd /data/local/tmp && ./nv-probe write 6828 1a18010000000800 --yes-write'
  # if it answers DIAG_BAD_SPC_MODE_F:  ./nv-probe spc 000000   then retry the write
  # wait ≥3 min for the EFS flush, then:  dut1-adb reboot
  dut1-adb shell 'cd /data/local/tmp && timeout 20 env LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so ./nas-probe bands'
  # revert:  ./nv-probe write 6828 1a10010000000800 --yes-write   (+ flush wait + reboot)
  ```
  **Result 15:08: NV persisted, still SIX bands.** Second gate found: B12's TX-linearizer cal item
  `RFNV_LTE_B12_TX_MULTI_LIN_V3_DATA_I` (rfnv 24237) is absent on dut1 while 24227/24229/24230/24238/24240
  (B2/B4/B5/B13/B17) exist — the only per-band family missing B12; mcfg identical across units (not MCFG).
  Candidate item built from B17 (channels −670 EARFCN), `diag-tools/nv-probe/b12/` (lineage-23 tree) and
  staged on dut1 `/data/local/tmp/00024237-b12-candidate.bin`. Next (Kyle):
  ```
  dut1-adb shell 'cd /data/local/tmp && ./efs2-probe put 00024237-b12-candidate.bin /nv/item_files/rfnv/00024237 --yes-write --allow-critical'
  # watch sha256 of /dev/block/by-name/modemst2 until it moves (~4 min), then: dut1-adb reboot
  dut1-adb root; dut1-adb shell 'cd /data/local/tmp && timeout 20 env LD_LIBRARY_PATH=/vendor/lib64 LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so ./nas-probe bands'
  ```
  ✅ **Write ACCEPTED 10-15 15:40** (item created, 528 B, verify OK) ⇒ diag-EFS2 can create rfnv items; the
  earlier "/nv/** denied" verdict was UIM-module-only. **Reboot ~15:55: STILL six bands.**
  Mechanism (from new2's eSIM-lane restart capture): RF card has B12; `rflte_nv_update_data_valid_flag` says
  "NVs are invalid for the band 11" → "band is not supported 11" → mask 0x1a01101a. The per-band cal loads
  are not logged, so which B12 items are still missing is unknown. **Next: the same F3 capture on dut1**
  (`diag-tools/nv-probe/b12/capture-rf-init.sh`, Kyle runs it; it cycles the modem via per_mgr) and diff the
  B12 lines against new2's.
  **Capture runs 10-15 19:51 and 21:23 (dut1):** modem restart works (per_mgr cycle, crash=0) but the LTE RF NV
  init walk is never in the log — it runs in the first second of modem boot, before the AP can apply a message
  mask (logger attached at ~1-2 s into boot, 106k later messages captured, zero RF-init lines). The kernel does
  re-push masks after the feature-mask handshake, just too late. new2's eSIM-lane capture got the walk only
  because its logger happened to be attached before RF init. **LANE PARKED 2026-10-15:** two per-unit gates
  found (NV 6828 bit 11 — writable; per-band TX-linearizer cal validity — item created, still judged invalid),
  no further visibility without a boot-time modem log, payoff is T-Mobile A-block only. dut1 state: NV 6828 has
  bit 11 set and rfnv item 24237 exists — both harmless (band still hidden); revert bit 11 with
  `./nv-probe write 6828 1a10010000000800 --yes-write` if a stock-identical bench unit is wanted.
  Seven bands incl. B12 ⇒ a Settings row is feasible only as a one-shot "calibrate B12 from B17" action
  (EFS item create + NV 6828 bit) with the NV bit as the on/off toggle; a vendor helper doing this diag write on
  `persist.gotweak.modem_b12` + restart, readback from DMS 0x45 (NV persists, no boot assert).
  Write refused ⇒ lane closes like eSIM (no write primitive). Priority: below the emergency-only
  gate and WFC Wi-Fi preference.

## Bench result 2026-10-16 — B12 ENABLED on dut1 (lane unparked and answered)
- **Witness found without decryption:** the `tunning` partition is a plain GNU tar of factory RF/XO cal
  (`nv/`, `nvm/`); only `modemst1/2` and `fsg` are encrypted `IMGEFS`. The seven-band unit 6210972a's
  tunning has 78 entries, the six-band units (5ab497bd, dut1, new2) 74. The four extras are all B12 by the
  per-band index: rfnv **22169, 22170, 24237, 27790**. dut1's live EFS had none of them (only our
  synthesized 24237), which is why bit 11 + 24237 alone stayed at six bands.
- **Test 10-16 17:57:** `efs2-probe put` of 6210972a's four items (24237 overwrites the candidate), all
  VERIFY OK; ~3 min flush; reboot. **DMS 0x45: LTE cap `0x1181a`, seven bands B2 B4 B5 B12 B13 B17 B66.**
  Radio back in service on LTE (US Mobile, B66) after boot.
- ⇒ B12 needs NV 6828 bit 11 **and** the B12 rfnv cal set. Items banked at
  `~/Projects/android-pepito-backups/6210972a/tunning-b12-items/` (not in git: another unit's calibration).
- Not done: B12 actually camped / TX power sanity (needs a T-Mobile or regional A-block B12 cell), and
  whether a foreign unit's cal is acceptable to ship. A Settings row would write these four items +
  bit 11; the shipping question is the calibration, not the mechanism. Revert on dut1 = clear bit 11.
- **Camp test 10-16 ~19:00 — control plane WORKS on B12; data test VOID (SIM not activated).** New
  `nas-probe lteband 0x800 --no-ext --yes-touch-nas` (NAS 0x33 TLV 0x15, power-cycle duration; this modem
  rejects the ext-mask TLV 0x24) locked LTE to B12 on US Mobile/T-Mobile: camped EARFCN 5035, RSRP −91 dBm,
  SNR 7–9, registered, internet PDN up with an IPv6 prefix. `ping6` over that PDN got 0/10 — but dut1's SIM
  is **not activated**, and a re-run of the control on B66 with the interface verified (rmnet_data1 = clat
  base of `fast.t-mobile.com`) also got 0/5. (A first B66 "control" at 10/10 was not verified against the
  PDN and is discarded.) So B12 with borrowed cal attaches and registers; user-plane quality is untested.
  dut1 reverted to six bands (NV 6828 bit 11 cleared; the four items stay, harmless).
  Next: repeat the B12 lock with an ACTIVE T-Mobile-network SIM (Verizon/Warp never uses B12), ping6 +
  a download/upload, and NAS GET_TX_RX_INFO (0x5A) TX power B12 vs B66. Settings switch only after that.
- **Switch BUILT 10-16 for community testing (Kyle: publish the calibration, let users try it).**
  Mi8937 `db3b9f85` (`qmux/modem_b12.c`, `init.modem_b12.rc`, `qmux/b12/` items, `modem_b12.te`,
  `persist.gotweak.modem_b12=0` default) + LineageParts `be6269cd` ("Bands" category in PVG100 Modem
  Tweaks: experimental switch + status row). Both pushed to `pepito-24`; module build (gapps lunch) passes
  incl. neverallows; not yet in a full build. Status prop `vendor.pepito.modem.b12` = active | inactive |
  saving | restart | factory | unsupported | failed | off. Never overwrites calibration; factory-B12 units
  (incl. 6210972a itself, via an EFS marker `/data/pepito_modem_b12`) are left alone.
  Bench-run of the binary on dut1: off → `inactive`, on → marker + bit 11 → `saving` → `restart`.
  Calibration is per unit: every comparable item family (TX lin, 2777x, the 32/16 B pairs) is distinct on
  all eight dumped units, by small amounts, so borrowed B12 cal is close, never exact.
  ⚠️ dut1 is left with the switch ON (bit 11 set, marker present): seven bands on its next boot.
  Next, after a full build: Settings flow on dut1 (status rows, dialog, factory greying), then the
  active-SIM B12 data test.
- **Toggle test 10-17 on dut1 (build 20261017), all through Settings:** off → dialog → row `saving` →
  "Saved. Restart to apply." → restart → `inactive`, six bands; on → same → `active`, seven bands, voice in
  service; on-then-off inside one save window → the run's re-check clears the bit again (bit CLEAR, matches
  the switch). Two bugs found and fixed (pushed, need the next build): **boot race** — init starts the service
  ~14 s into boot, the first NV read is not DONE yet and it published `unsupported` for the whole boot, greying
  the switch (`775c1223`: wait for NV 6828 to read DONE with base bands); **needless restart prompt** after
  flipping back to the boot state (`b1d5f93e`). Also open: switch summary is cut at 10 lines ("…Saving to the").
  Next build: cold boot should read `active` with no manual `ctl.start`.

## Bench result 2026-10-15 — WFC "Wi-Fi preferred" at home (SHIPPED in 20261017, VALIDATED on new2 10-17)
Memory: `wfc-wifi-preference-lane`. Evidence `diag-tools/captures/wfc-pref-20261015/` (lineage-23 tree).
- **Mechanism (modem F3, new2 A17):** the in-call IWLAN→LTE move is `qpDplHandOver.c:4291 In Audio call
  [wifi pref], Wifi < D and LTE>LTE2` fired at `InCall 0→1`, with Wi-Fi quality −1 (nothing on our stack arms
  the modem's WQE profile; ANDSF logs `wqe profile type is inactive` and discards the feeder's RSSI). The only
  live term is `LTE > LTE2 (−115)`. Lever = IMSS SET_HANDOVER_CONFIG 0x5d TLV 0x16 (LTE threshold 2; GET 0x5e
  TLV 0x17). Modem rejects values above ≈−70 silently; −80 accepted.
- **Static TH2=−80:** call stays on Wi-Fi ✅ but Wi-Fi loss mid-call ⇒ `WIFI_LOST` drop after 20 s ❌ (TH2 also
  gates `None→LTE`). **Dynamic:** Wi-Fi off → TH2 back to −115 one second later → `callSessionHandover 18→14`
  5.4 s after the write, call survives ✅. Feeding Wi-Fi quality (option B) is blocked at the modem's WQE arming
  step — same wall as PLAN-wifi-calling parts 12–13.
- **Committed + pushed 2026-10-16: Mi8937 `6bc3da68`, mithorium-common `4dc209b` (pepito-24), not yet built or flashed:**
  `qmux/wfc_wlan_bridge.c` steers TH2 (−80 while WFC on ∧ Calling preference = Wi-Fi preferred/only ∧ wlan0
  associated ∧ RSSI ≥ −75, hysteresis release < −82; stock −115 otherwise, asserted at boot/WFC-off/disassoc;
  2 s wlan0 poll while sticky; status `vendor.qmux.wfc_th2` = stock|sticky|error); `WfcBridge` mirrors the
  per-sub `wfc_ims_mode` (siminfo, READ_PRIVILEGED_PHONE_STATE + privapp allowlist) into
  `persist.sys.pepito.wfc_mode`; `init.qmux.rc` copies it to `vendor.qmux.wfc_mode`; property_contexts entry;
  `vendor.xml` 311/480 gets `editable_wfc_mode_bool=true` so the Settings row shows. Default (row untouched)
  = cellular preferred = stock behaviour.
- ✅ **VALIDATED on new2 2026-10-17 (24.0-20261017, Verizon-network SIM, RSRP −106, driven from adb, MO calls to the test number):**
  Settings mode 2 → `vendor.qmux.wfc_mode=2`, `wfc_th2=sticky` within 3 s (wlan0 −64 dBm, readback −80). **Hold:** 45 s call
  stayed `rat=0`, RTP on `r_rmnet_data1`, zero handovers. **Walk-away** (on-device script, `svc wifi disable` 20 s in):
  supplicant disconnect 12:39:07.16 → feeder TH2 −115 at 08.08 → modem `callSessionHandover 18→14` at 10.17 → call
  continued on LTE until the remote hung up normally (510 USER_TERMINATED_BY_REMOTE; the test line ends ~47 s).
  Gap ≈3 s from link loss. ⚠️ adb over Wi-Fi dies with the Wi-Fi leg, so run walk-aways on-device.
- **Review fixes 2026-10-17 (Mi8937 `pepito-24`, on top of `6bc3da68`, unbuilt):** sticky TH2 also needs the
  framework's Wi-Fi VALIDATED verdict (WfcBridge → `sys.pepito.wfc_wifi_ok` → `vendor.qmux.wfc_wifi_ok`), so an
  AP with a dead uplink cannot hold the LTE rescue off; the 2 s sticky poll no longer shortens the 75 s prime;
  the TH2 cache is dropped on DSD transport error and every re-prime period; known-value edges skip the pre-GET;
  WfcBridge derives the mode like `ImsManager.getWfcMode` (carrier default when non-editable/unset, re-sync on
  carrier-config change) instead of hard-coding cellular.
- 🔴→✅ **2026-10-17 re-run on `55a9fbf6` (validated-Wi-Fi gate, prime length, TH2 cache):** calls PASS (hold 45 s at
  RSRP −112 stayed `rat=0`; walk-away: disconnect → `wfc_wifi_ok=0` +1.1 s → TH2 −115 +1.3 s → handover +2.2 s,
  call survived). **BUG found:** after boot `persist.sys.pepito.wfc_mode` stayed 1 with siminfo mode 2 — boot
  syncMode() runs before the sub is valid, and the CARRIER_CONFIG_CHANGED re-sync was SKIPPED (`Exported Denial`:
  sender com.android.phone uid 1001, receiver RECEIVER_NOT_EXPORTED). Fixed in Mi8937 `b82254d8` (RECEIVER_EXPORTED;
  protected broadcast). ⚠️ Not yet built: after flashing, check `wfc_mode=2` right after a REBOOT, no app restart.
- ✅ **2026-10-17 15:00, build with `b82254d8` (14:45) — FULL PASS on new2:** after a plain reboot (no app restart)
  mode=2/wifi_ok=1/TH2 sticky within 6 s of WfcBridge start; CARRIER_CONFIG_CHANGED now DELIVERED to the boot
  process (receiver exported=true). Hold 45 s at RSRP −107..−111: `rat=0`, no handover. Walk-away: disconnect
  14:58:10.14 → wifi_ok=0 +1.1 s → TH2 −115 +1.8 s → handover +5.2 s → call survived on LTE to the remote's
  normal hang-up (510). Handover latency after the write varies 0.9–3.4 s across runs; all well inside 20 s.
- ✅ **2026-10-17 16:33, re-flashed build `24.0-20261017` (16:18, same tips: Mi8937 `b82254d8`) — PASS on new2:**
  2 min after boot mode=2/wifi_ok=1/TH2 sticky. Hold (`hold4`): 36 s active, `rat=0` at RSRP −109/−110, no
  handover, remote hang-up 510. Walk-away (`walk4`): disconnect 16:35:36.37 → bridge TH2 −115 + WfcBridge
  wifi_ok=0 +0.9–1.2 s → IWLAN→LTE handover 16:35:42.41 (+6.0 s after disconnect, +5.1 s after the write) →
  call survived on LTE to the remote's hang-up (510). Captures in `/data/local/tmp/wfc/{hold4,walk4}.*` on new2.
  Mid-call AP WAN pull still NOT run (needs a hand on the router).
- ⚠️ **Found during walk4 — Wi-Fi does not reconnect with the screen off:** after `svc wifi enable` at 16:36:22
  the unit stayed DISCONNECTED for 8 min (IMS on LTE, TH2 stock — correct for that state). `WifiScanningService:
  PNO is not available` → `Failed to successfully start PNO scan for 5 times`; with the screen off the framework
  schedules no other scans. Screen on → wlan0 IP in 1 s, TH2 sticky +4 s, IMS back on IWLAN +7 s. The same
  "PNO is not available" is in walk2/walk3; those runs reconnected only because the screen was on. Not a WFC
  regression, but in real use: come home with the phone in a pocket → it stays on LTE until the screen wakes.
  Lever candidates: wcnss/pronto PNO in the Wi-Fi HAL, or the framework's screen-off periodic scan fallback.
- 🔎 **2026-10-22 PNO root-caused + A/B'd on new2 (24.0 `20261017`, runtime overrides only, restored after):**
  - **Why "PNO is not available":** HW PNO is gated only by `config_wifi_background_scan_support`
    (`WificondScannerImpl.isHwPnoSupported`). mithorium-common's `WifiOverlay` sets it `true`, but **no overlay
    reaches `com.android.wifi.resources`**: `WifiOverlay` and Mi8937's `WifiOverlay_prada` both use
    `theme: "WifiOverlay"`, so both install into `/vendor/overlay/WifiOverlay/`. PackageManager reads a subdir as
    one package cluster → two package names → the dir is skipped (neither package exists in `pm`/OMS). Same
    layout since the initial Mi8937 tree ⇒ the whole mithorium Wi-Fi overlay (FT, link probing, TCP buffers,
    SoftAP ACS/11ac off, reg-change event) has never applied on Mi8937 builds either.
  - Test = screen off, `svc wifi disable/enable`, poll 180 s for wlan0 IPv4 (AP on ch 6 the whole time):
    | config | result |
    |---|---|
    | shipped | NOT connected in 180 s (`PNO is not available`) |
    | `force-overlay-config-value bool config_wifi_background_scan_support enabled true` | HW PNO **starts** (`NL80211_CMD_START_SCHED_SCAN`, freqs 2412/2437/2462) but the driver never reports a match (`iw event` silent 75 s) → NOT connected |
    | background_scan off + `config_wifiSwPnoEnabled` true + `device_config put wifi software_pno_enabled true` | **CONNECTED +7 s, screen off** (SwPnoScanState) |
  - Prima advertises `start_sched_scan` (16 match sets, 10 plans); its plan conversion is right for 4.19 and the
    found-indication path is plain. Why Pronto firmware never indicates is open (needs `iwpriv setwlandbg` for
    SME/WDA traces — no iwpriv on the image). Upstream nit seen on the way: `pmcSetPreferredNetworkList` appends
    supplicant IEs to `&p24GProbeTemplate` (the pointer's address); unused here (wificond sends no IEs).
  - **STAGED + PUSHED 2026-10-22, unbuilt:** Mi8937 `9f192ab7` (prada overlay loses `theme:`; new static
    `WifiOverlay_Mi8937` prio 1: `config_wifi_background_scan_support=false`, `config_wifiSwPnoEnabled=true`) +
    LineageParts `fe578954` (Tweaks → Wi-Fi → "Reconnect to Wi-Fi with screen off", **default OFF**:
    `persist.gotweak.wifi_sw_pno` + DeviceConfig `wifi/software_pno_enabled`, live; BootReceiver re-asserts once
    set; category hidden unless the overlaid `config_wifiSwPnoEnabled` is true). Stock SW PNO timers
    (2 mobility, 3×5 min, 10×20 min, stop). SimpleDeviceConfig route dropped (it re-applies at boot, would
    override the user).
  - **After flash, check:** `cmd overlay list com.android.wifi.resources` shows `xiaomi_mithorium` +
    `xiaomi_msm8937` enabled (prada absent on pepito); `cmd wifi get-overlay-config-values` →
    background_scan false, SwPno true; switch ON → `device_config get wifi software_pno_enabled` true, the
    screen-off reconnect test passes; switch OFF → stays disconnected. Re-check what the newly-live mithorium
    values change: hotspot (ACS + 11ac now off), FT roaming, link probing, TCP buffers. Then CT-3 power A/B:
    screen-off standby, Wi-Fi out of range, switch on vs off; choose final timers from that.
  - ✅ **2026-10-23 dut1 on `24.0-20261023` (carries `9f192ab7` + `fe578954`):** both `xiaomi_mithorium` and
    `xiaomi_msm8937` overlays enabled (prada installed, correctly skipped); background_scan false, SwPno true,
    softap ACS false, link probing true, Wi-Fi TcpBufferSizes now 524288,2097152,4194304,262144,524288,1048576.
    Switch flipped through the UI: ON → prop 1 + DeviceConfig true (LineageParts write accepted, no error) →
    screen-off reconnect **+4 s** via SwPnoScanState; OFF → prop 0 + DeviceConfig false → NOT connected in 180 s,
    `PNO is not available`. ✅ Reboot persistence: switch ON, flag forced `false` by hand (simulated server flip),
    reboot → flag `true` 10 s after boot (BootReceiver delivered), screen-off reconnect +4 s via SwPnoScanState.
    Still to do: hotspot with a client
    (ACS + 11ac now off), CT-3 power A/B.
  - ⚡ **2026-10-23 per-scan energy, dut1 on the CT-3 (charging off, `battery unplug`, screen dozing, Wi-Fi on +
    disconnected, switch off):** 10 × `cmd wifi start-nl80211-scan wlan0 -t low_latency` 15 s apart (the driver
    scan SW PNO issues; framework/scan-only triggers were refused for shell/root callers). Baseline 0.327 W
    (σ 14 mW); each scan = ~1 s bump to ~0.6 W; excess **median 0.22 J** (mean 0.25, one 0.57 J outlier; control
    windows ≈0). ≈ **0.016 mAh per scan** at 3.8 V. Wired ⇒ the SoC never suspends (78db000.usb), so the
    resume-from-suspend + alarm handling cost is NOT in this number; budget it at a few × the scan.
    Stock schedule ≈ 15 scans per disconnected stretch ⇒ well under 1 mAh per stretch (~0.1 % of the cell) —
    keep the stock timers. A 60 s timer would be ~60 wakes/h ⇒ order of a few mA average — not worth it.
    Open for a true number: unplugged battery-gauge arm with dut1 away from Wi-Fi.
  - ⚠️ **Side effect of the overlay fix, caught 2026-10-23:** mithorium's `config_wifi_diagnostics_bugreport_enabled=true`
    went live (dut1 `20261023` reads true; AOSP default false). On userdebug that lets WifiDiagnostics start a full
    bug report on its own (≤1/h) on Pronto SSR, HAL errors, last-resort watchdog. Overridden back to false in
    `WifiOverlay_Mi8937` — Mi8937 `475d43d4`, pushed, unbuilt. Hotspot ACS/11ac: AOSP defaults are already false ⇒
    no hotspot change, client test not needed. Net user-visible changes from the now-live overlay: 802.11r FT on,
    larger Wi-Fi TCP buffers, link probing on, SoftAP max clients 16→32, WPA2→WPA3 auto-upgrade off.
- **Validation after flash (new2 or dut1, Verizon-network SIM):** Settings → Wi-Fi calling → Calling preference
  visible; pick Wi-Fi preferred → `getprop vendor.qmux.wfc_mode` = 2, `vendor.qmux.wfc_wifi_ok` = 1 on home
  Wi-Fi, `vendor.qmux.wfc_th2` = sticky while on Wi-Fi; `diag-tools/nas-probe/wfc-call-run.sh` call stays
  `rat=0`; `wfc-walkaway.sh` (without the manual rescue) hands over to LTE instead of dropping; set Cellular
  preferred → `wfc_th2` = stock, call hands over at answer as before. **New:** mid-call pull the AP's WAN (AP
  up, internet dead) → `wfc_wifi_ok` should fall to 0 when the framework re-validates, `wfc_th2` → stock, call
  moves to LTE; note how long the framework takes to notice (the 2 s wlan0 poll does not cover this edge).
  Also check `logcat -s wfc_wlan_bridge WfcBridge` for "wlan0 reports no dBm RSSI" (would mean the
  SIOCGIWSTATS path needs a /proc/net/wireless fallback) and for the "validated" transitions.

## Bench result 2026-10-15 — custom boot logo (`splash` partition) boots on dut1
Memory: `splash-boot-logo`. Tools in `tools/splash/` (README has the format).
- `splash` (22528 sectors, both GPT layouts) holds the five screens aboot draws: `SPLASH!!` + 720x1280
  header, frame table at 0x200, five zlib-9 BGR24 frames (0 = PALM logo). 0x20000+ is leftover from an
  older image. All 7 backed-up units are identical apart from the 0x00/0xff filler before 0x20000.
- `splash.py replace-logo` re-encodes frame 0 only (new logo ≤ 18,457 B compressed). A re-encoded logo
  **boots and shows** on dut1 ✅, so aboot doesn't checksum frame 0; the unexplained header words (216,
  0xffffff06, 0x79) are not a check on it.
- **Design (2026-10-16, on dut1):** splash = stock PALM in place, footer dropped; the boot animation
  (`device/xiaomi/Mi8937/bootanimation/`, `TARGET_BOOTANIMATION`, built by `make-bootanimation.py`)
  starts on that exact screen, fades PALM out over 0.5 s, then plays LineageOS's parts unchanged
  (trim.txt on a 720x1280 canvas). Each part runs at stock speed on dut1. Continuous splash keeps the
  logo up until bootanim starts (15–31 s into boot). `render-bootanimation.py` renders any zip to
  mp4/webm/gif.
- **Shipping (2026-10-16, pushed, not yet built):** device tree `85c7e499` carries the logo as
  `splash/splash.img` (first 128 KiB of the partition) and `releasetools.py` writes it in every OTA
  (`firmware-update/splash.img`); landing `c797d05` stages it in prepare-flash, puts it in the EDL
  kit's manifest (ota2raw rebuilds it) and has the web flasher write it when present. Check on the
  next build: `out/.../Mi8937/splash.img` exists, the OTA zip has `firmware-update/splash.img` and
  the updater-script line, and release.sh's ota2raw round trip passes.

## Bench result 2026-10-17 — power regression check, CT-3 wired cells (dut1)
dut1 `c39a6acf`, `24.0-20261017-SNAPSHOT-Mi8937_gapps`, kernel #20 (Oct 16), no serial console, US Mobile
SIM on LTE + Wi-Fi, ~20–60 min after boot. CT-3 in-line on USB to the netbook, charging off
(`battery_charging_enabled=0`, battery current ≈ 0) so the meter reads system power only. A
38 h stopwatch was running (its status-bar chip redraws at 1 Hz). Same-rig A16 references are in
`PLAN-perf-battery.md` §CT-3.

| Cell | A17 (mW) | A16 reference (mW) |
|---|---|---|
| Screen on, Trebuchet, 255 | floor ~1340, settled mean 1346–1453 | dut1 Aug: 1136–1212 |
| Screen on, Trebuchet, 128 | 1167 (floor ~1095) | Gold: 931 (other unit) |
| Screen off, natural, USB | 441 mean / 389 median, floor ~335 | Gold: 410 |
| Screen off, forced deep idle, USB | 409 / 380, floor ~330 | Gold: 348–351, no spikes |
| Same, framework told unplugged | 402 / 364, floor ~330 | — |

- Screen-off floor (~330 mW) is at or below A16's. The excess is periodic, not floor:
  1. **Telephony keeps signal-strength reports on while "charging".** USB attached ⇒
     `DeviceStateMonitor mIsCharging=true` ⇒ `currentSignalStrength` every 2–5 s with the screen
     off, each one waking `com.android.phone` (SatelliteController re-checks its config every
     time, ~20 log lines). AOSP behaviour, rig-only; `dumpsys battery unplug` stops it.
  2. **f2fs background GC on /data every ~29 s** (`f2fs_gc-259:21`, ~1.1 MB/min,
     `gc_min_sleep_time=30000`): spike + ~10 s at +60–80 mW. `dirty_segments` stayed at 215 across
     ~10 min, so GC is not making progress. Rig-only in effect (the thread freezes in suspend),
     but worth a look.
- GPU floor (`min_pwrlevel` 3 vs 5) A/B at 255: no measurable difference (±noise, ~4 arms).
- Screen-on 255 is +150–250 mW over dut1's A16 cell. Not attributed: stopwatch chip ticking,
  LTE + charging-mode signal reports, f2fs GC and the post-boot drift (1453 → 1346 over 10 min) all
  overlap. Re-run with the stopwatch paused and the framework unplugged before calling it.
- Wired cells never suspend (`78db000.usb` wakeup source, suspend_stats 0/0). The decisive
  check is the unplugged airplane bracket vs dut1's A16 9.1 mA — not yet run.

### Matched pair 2026-10-17 pm — dut1 vs Gold, same A17 build, same script
Both `24.0-20261017-SNAPSHOT-Mi8937_gapps`, no SIM, Wi-Fi on, no serial console, ≥60 min uptime, no
stopwatch, CT-3 inline to the netbook, charging off (Gold charge counter moved 21 µAh in 14 min ⇒
battery out of the reading; `current_now` is a stale value on both, ignore it), framework told
unplugged (`dumpsys battery unplug`), Trebuchet, 45 s settle + 180 s per screen-on cell. Script and
CSVs: netbook4 `~/scratch/pwr-a17-1017/` (`run-cells2.sh`).

| Cell (median mW) | dut1 A17 | Gold A17 | A16 reference |
|---|---|---|---|
| Screen on, 255 (wled 2987) | 1324 | 1171 | dut1 Aug, idle-storm fixed: 1140 |
| Screen on, 128 (wled 1510) | 1072 | 902 | — (July Gold 931 was before the 0.73 cap) |
| Screen on, 40 | 910 → 786 (step at 13:58:30) | 741 | — |
| Screen on, backlight 0 | not run | 667 | — |
| Screen off, natural | 334 | 324 | Gold: 410 |
| Screen off, deep idle forced | 331 | 321 | Gold: 348–351 |

- **Screen off: no regression on either phone**; both sit at or below A16's same-rig readings.
- **Screen on: no regression on Gold.** dut1 carried a flat ~125 mW extra load that stopped at
  13:58:30, partway through its 40 cell (SIM pulled ~13:45; cause not captured). Without it dut1
  reads ~1200 / ~950 at 255 / 128, within ~35–50 mW of Gold and ~60 mW of its own A16 1140.
  The earlier "+190 mW screen-on" was that load, not A17.
- Gold's backlight costs ~0.18 mW per wled step (1171−902 over 1477 steps), the same as dut1's
  0.17. Screen on with backlight 0 = 667 mW, i.e. ~345 mW over screen-off for SoC awake +
  panel + composition.
- Writing 0 to `wled/brightness` detaches `bkl-trigger`; restore with
  `echo bkl-trigger > /sys/class/leds/wled/trigger`.
- Gold's /data has 2200 f2fs dirty segments (dut1 215); no periodic GC bursts showed on Gold.
- Still open: the unplugged airplane standby bracket against dut1's A16 9.1 mA (real suspend).

## Upstream rebase 2026-10-23 — first run of REBASE.md

First monthly rebase (`scripts/upstream.py`, runbook `REBASE.md`). 12 forks rebased onto upstream
`lineage-24.0`, all clean, every one of our patches replayed unchanged (range-diff identical):
frameworks/base 17 upstream, Launcher3 14, vendor/lineage 7, LineageParts 3, build/make 3,
hardware/lineage/interfaces 3, lineage-sdk 2, Updater 2, system/sepolicy 2, telephony 1,
hardware/interfaces 1, fs_mgr 1. Device trees, kernel, native, recovery, bpfprogs: 0 behind (device
upstream is dead since 08-21). Backup tag on every fork: `pepito-24-pre-20261023`. Then
`SYNC_ALL=1` build `20261023`: first full sync since 10-05, 93 projects moved vs the 20261017
snapshot, incl. upstream's switch of conscrypt / ca-certificates / selinux / system/usb /
frameworks/hardware/interfaces / hardware/google/interfaces to Lineage forks.

- Security patch level unchanged at 2026-10-01 (= upstream). Upstream Google-authored fixes not in
  the tree before the sync: 2, neither security (Bluetooth cleanup, ApiDemos). 20261017 was already
  current on the bulletin.
- emSign roots: conscrypt cacerts 4 → 1 (Lineage removed G3 / ECC C3 / C1; Root CA - G1 stays).
- dut1 (`c39a6acf`) smoke, 10:41–10:47: boots; 3-button nav with Trebuchet: no crash loop
  (launcher/systemui PIDs stable, bar drawn); QS volume slider + torch tile present; aconfig
  `flashlight_strength` enabled; Updater opens (Security update Oct 2026, build date Oct 23); PVG100
  System Tweaks + Modem Tweaks pages open. No crash from our code. avc denials (18) all seen on
  20261017 too.
- Not a regression: GMS / Play Store crash at start on dut1 (missing `INTERACT_ACROSS_USERS`, DPM
  denial). They live only in /data/app (left from an earlier gapps install) on a vanilla build, so
  no privileged grants. Same crashes before this boot.
- Still to do before a release: `tests/integration` on this build (release gate), face unlock,
  the gapps build.

## Bench result 2026-10-23 — white notification LED (PMI8950 MPP2)

The white light below the screen is a current sink on PMI8950 MPP2. Stock
(silver, 8.1) registers it as `button-backlight` and lights it at 10 mA
whenever the screen is on; our tree left the node empty. Now it's the
notification LED:

- kernel `4ad403e75036`: `pepito/leds.dtsi` registers MPP2 as `white`
  (manual mode, `pm8937_l11` at 3.3 V like stock, capped at 10 mA) and drops
  `qcom,chg-led-support` so the unwired charger `red` LED goes away and the
  lights HAL picks `white`.
- Mi8937 `45107873`: genfscon `sysfs_graphics` (hal_light can write that, not
  `sysfs_leds`); `config_deviceLightCapabilities` 0 (plain white, solid, no
  battery light).
- mithorium-common `ef662b2`: XiaomiParts turns "Blink light" off once on
  pepito (fresh installs and OTA upgrades); after that it's the user's setting.

Brightness: on silver, 5/10/20/40 mA showed no visible gain past 10 mA
(probably 3.3 V headroom vs. the LED's forward voltage), so 10 mA is the cap.
Cost while lit ≈ 10 mA vs. a ~3.3 mA airplane floor, hence default off.

Hardware blink: NOT possible. Test kernel with writable regmap debugfs on
dut1: MPP2 lights from a constant source, and from an inverted DTEST input
(the line sits low), but the PMI8950 PWM channel's DTEST outputs (lines 1-2,
output selects 1-3) never toggle it. HAL PWM path reverted (`883e617`); test
branch `pepito-24-ledblink-test` abandoned. MPP MODE_CTL low nibble is
function<<1 | value (`0x61` on, `0x64`/`0x65` DTEST1, `0x68` DTEST3).

Verified on dut1, production build 20261024 gapps: `white` present (max 10,
`sysfs_graphics`, owner system), no `red`, `notification_light_pulse`=0 after
first boot, HAL `setLightState(NOTIFICATIONS, white)` → brightness 10, LED lit
(Kyle). Not yet seen: a real notification lighting it (dut1's SIM isn't
active; missed-call/SMS channels have lights on).

## Bug 2026-10-30 — face unlock idle lockout shows "Something went wrong"

Reported and traced by Scott on `20261023`. Paranoid Sense (`SenseService.kt`)
locks face unlock 4 h after the last successful face match
(`LOCKOUT_TYPE_IDLE`); authenticate then errors in ≤13 ms without opening the
camera until the screen lock is entered. Timed and permanent lockouts map to
`FACE_ERROR_LOCKOUT{,_PERMANENT}`; the idle one maps to `FACE_ERROR_VENDOR`
with vendorCode 0, and AOSP's `face_error_vendor` array is empty, so keyguard
showed `face_error_vendor_unknown`. The lockout itself is intended (WEAK-class
biometric); only the message is wrong.

Why Sense's timer fired at all: the framework already enforces the same rule
(`LockSettingsStrongAuth`, 4 h, re-armed by keyguard every time it shows; when
it fires keyguard stops requesting face auth and prompts for the screen lock).
Sense's own timer is armed once at screen-off and can expire first.

First fix, Mi8937 `46b12fc1` (`face_error_vendor[0]` string in
`xiaomi_pepito_overlay`), is superseded and gets reverted once the fork lands.

Fix: FaceUnlock is now our fork, `solarkennedy/android_packages_apps_FaceUnlock`
`pepito-24` (crDroid `17.0` + 2):
- `71d4d55` drop Sense's duplicate idle lockout; the framework owns it.
- `27049dc` report Megvii per-frame results to keyguard as `FACE_ACQUIRED_*`
  hints (dark, bright, closer/farther, look at phone, motion, covered, no face).
  Nobody upstream does this (GitHub code search 10-30; AxionAOSP's rewrite
  sends only NOT_DETECTED).

Unbuilt, uncompiled. Verify: (1) 4 h after a face unlock, wake: keyguard asks
for the pattern with no "Something went wrong"; (2) face unlock in the dark,
too close, half covered: a hint shows under the clock.

## Bug 2026-10-30 — T-Mobile VoLTE calls crash the ADSP + modem (user report, unit c3ad6a80)

Two user bugreports (20261023 gapps, modem C1-162128, US Mobile on T-Mobile). VoLTE
calls drop 3–6 s after alerting; the previous-boot kernel log shows `Fatal error on
adsp! … Excep :0:Exception detected` → ~2 s later `modem subsystem failure reason:
qpaudio_svs.c:4475:Assertion 0 failed` (once followed by an `ipa_qmi_client.c:750`
crash loop and a `vold` reboot). After each crash IMS stays down, so later calls go CS
→ no 2G/3G on T-Mobile → cause 36. The one crashed call with a codec logged was
EVS-SWB (audioQuality 19).

Findings:
- The `na/tmo/commerci` MCFG profile sets `qipcall_audio_codec_list =
  EVS;AMR_WB_BE;AMR_WB_OA;AMR_BE;AMR_OA`; the Verizon profiles have no EVS (empty
  list, AMR 12.2 / AMR-WB 12.65 only). new2 → Pixel on Verizon is AMR-WB, so our
  Verizon VoLTE validation never exercised EVS.
- The TMO profile and `dsp.bin` are byte-identical in C1-162128 and C1-214411.
- dut1 on C1-214411 + a T-Mobile SIM (US Mobile, activated 10-30; IMS only came up
  after a reboot post-activation): 6/6 EVS-SWB calls to the Pixel, answered and
  ringing-only, no crash. The `voice_get_cal: No cal data for cal 6` / ADSP_EFAILED
  dmesg lines appear on clean calls too: noise.
- 21:14 dut1 modem dd'd to C1-162128 (`acb81d93`, baseband `…1.160315.0.162128.1`
  = the user's); boots, IMS registers, TMO codec config live. No calls placed yet.

10-31: dut1 on 162128 (2019-02 image, WS241): 13 h clean overnight, then 6/6 EVS-SWB
calls clean. Correction: the ADSP firmware is `image/adsp.*` inside the modem partition
(the `dsp` partition is only `/vendor/dsp` fastRPC libs), so this tested the user's
2019-02 modem AND ADSP. A second, different 162128 binary exists (2018-11, build host
WS228, own ADSP); the user can tell which they have without root:
`adb shell cat /sys/devices/soc0/images` → entries 11/12 `Version: :WS228` or `:WS241`.
Staged `modem-swap-dut1/modem-162128-2018-11.bin` (gifted's prewipe dump, 952ddf08).

Previously planned (10-31): repeat the six-call set on dut1/162128 with `logcat -f` + dmesg checks.
Crash ⇒ modem build is the cause ⇒ fix = move users to the 214411 modem (EDL/dd);
no crash ⇒ look at the user's radio conditions / unit. Restore dut1: dd or EDL with
`~/android/lineage-24/modem-swap-dut1/` (`modem-214411-dut1.bin`). Tools:
`diag-tools/ims-codec/` (`call-codec.py`, `mbn-codec.py`).

10-31 REPRODUCED on dut1, on both 162128 and its own 214411 ⇒ every PVG100 on T-Mobile:
the ADSP crashes when an EVS-SWB voice session starts (or is <~1 s old) while the voice
device is, or is switching to, the speaker. The user's calls all switch to speaker within
0.7 s of HD. Speaker 4 s after EVS start: no crash (n=1); AMR + speaker: no crash (n=1).
After one ADSP crash every later VoLTE call crashes until reboot. Table and logs:
`diag-tools/ims-codec/captures/dut1-214411-speaker-crash-20261031/`. Open: stock A8 parity
on T-Mobile; mitigation (drop EVS from the TMO codec list in EFS, or hold voice device
switches until the vocoder is up). dut1 restored to its own 214411 modem.

10-31 isolated on dut1/214411 (`diag-tools/ims-codec/captures/dut1-214411-isolation-20261031/`):
not the modem build, not the mic (single-mic crashes too), not the HAL's TMUS branch (the
non-TMUS branch crashes even on the earpiece; mapping TMUS to ACDB 7/41 doesn't help). With
EVS removed from `/nv/item_files/ims/qipcall_audio_codec_list` the calls go AMR-WB and all
recipes are clean (5/5). Model: the ADSP dies when voice calibration lands on an EVS-SWB
session that is starting or < ~3 s old; T-Mobile earpiece calls only survived because the
HAL's TMUS devices look up ACDB 88/89, which the Palm ACDB lacks, so no cal is sent.
Fix candidate: a Modem Tweaks "EVS" lever (default off) that writes the EVS-free codec list,
using the B12 switch's EFS write path; stock A8 parity on T-Mobile still unchecked.

10-31 codec dimension on new2 (Verizon): with EVS added to its codec list the Verizon network
negotiates EVS-WB, and every recipe that crashes EVS-SWB on dut1 is clean (speaker switches
1.3–1.5 s after EVS start, end-on-speaker → earpiece, earpiece with valid cal). Verizon AMR-WB
is clean on the same recipes. So the crash is EVS super-wideband specific; T-Mobile is the
only carrier that negotiates SWB. new2 restored. Gentler fix than dropping EVS: cap the EVS
bandwidth at WB (`qipcall_evs_codec_config`, layout still unknown).

10-31 fix proven on dut1: keep T-Mobile's EVS-first codec list but write Verizon's
`qipcall_evs_codec_config` bytes (`00 00 10 00 00 00 6d 00 03 02 …` vs T-Mobile's
`… 00 00 02 03 …`) ⇒ T-Mobile negotiates EVS-WB and every crash recipe is clean, including
a speaker switch 0.27 s after EVS start (`diag-tools/ims-codec/captures/dut1-tmo-evs-wb-cap-20261031/`).
Next: decide which bytes matter (byte 6 vs 8–9), then ship as a boot-time EFS write on
T-Mobile profiles (B12 switch path), with a Modem Tweaks row to turn super-wideband back on.

10-31 after review (Fable): the timings above used UNSOL_MODEM_RESTART (3–4 s late). Re-timed on
the HAL's `SSR/PDR occurred`, every crash is 70–272 ms after EVS-SWB starts: the trigger is a
voice cal being registered when an EVS-SWB session STARTS (a valid ACDB pair, or the kernel's
cached speaker cal from the previous call). Switching onto a running SWB session is safe from
0.4 s on (5 cases). Byte isolation: byte 9 of `qipcall_evs_codec_config` is the EVS max
bandwidth (`03` SWB, `02` WB); a one-byte change `03`→`02` on T-Mobile gives EVS-WB and every
cal-at-start recipe is clean; the item survives SSR and reboot. dut1 left on it.
(`diag-tools/ims-codec/captures/dut1-evs-byte9-isolation-20261031/`). Still untested with the
fix: MT calls, VoWiFi. Ship: boot-time read-compare-write of byte 9 on T-Mobile profiles.
10-31 pm: MT call with the fix clean (EVS-WB). Forcing SWB on Verizon (new2 byte 9 → 03)
makes Verizon negotiate EVS-SWB and the first earpiece call crashes the same way ⇒ the bug is
EVS-SWB + voice cal at session start on any network; T-Mobile is just the carrier that asks
for SWB. Stock parity impossible on the bench (silver is Verizon-locked; stock on Verizon
negotiates EVS-WB). new2 restored.

10-31 fix PUSHED, unbuilt: Mi8937 `fd7d17c1` (modem_evs oneshot: caps byte 9 of
`qipcall_evs_codec_config` at 02 at boot / switch flip / SIM LOADED unless
persist.gotweak.modem_evs_swb=1; only touches profiles above WB; original byte + item saved
in modem-EFS marker /data/pepito_evs_bw, restore only if the item still matches) and
LineageParts `38e940b3` ("Super-wideband call audio" row in PVG100 Modem Tweaks, default off).
Bench-tested as a cross-compiled binary on dut1: cap 03→02, boot run read-only ("capped"),
allow-SWB restores 03 and clears the marker, a flip during the flush re-caps; host unit tests
cover the SIM-swap/stale-marker case. Verify on the build: status row reads "capped" on a
T-Mobile SIM and "none" on Verizon; one T-Mobile call negotiates EVS-WB; SELinux denials for
modem_evs (none expected; same rules as modem_b12).

10-31 17:2x–17:42 VERIFIED on build 20261031 (dut1 + new2): with dut1 reset to T-Mobile's byte 9
`03` and the marker invalidated, the shipped modem_evs capped it at boot (saving 180 s →
restart → "capped" after the next boot, read-only run 0.2 s). Six T-Mobile calls, all EVS-WB, no
crash, including speaker cal before EVS, cached speaker cal, valid handset cal 7. Settings row:
dut1 "Off: calls use wideband HD voice." (switch enabled), new2 greyed with "Your carrier does
not use super-wideband audio"; tapping the switch on restores byte 9 = 03 with the save dialog,
off re-caps and settles at "capped" with no restart. new2 Verizon call AMR-WB, speaker, clean.
No SELinux denials. Not covered: Wi-Fi calling.

## Bench result 2026-10-31 — WFC on a T-Mobile-network SIM never leaves LTE (dut1)

First time WFC was tried on a T-Mobile-network SIM (US Mobile, PLMN 310260,
carrier_id 1). Not a regression: every earlier WFC pass was the same MVNO on
Verizon. Found by the release gate run (test_call_hold/test_call_walkaway
skipped "IMS voice not on WLAN after 90 s"; dut1 had also booted with Wi-Fi
off, so that run never had a chance).

State with Wi-Fi up and validated, bridge `up`/`feeding`, Settings "Call over
Wi-Fi" (wfc_mode 2, TH2 sticky), LTE RSRP -109: IMSA voip_service_rat stays 1,
WLAN NetworkRegistrationInfo UNKNOWN, no ePDG PDN (r_rmnet_data1 DOWN). Gates
already open: IMSS 0x16=1, ps_sys field 4 = 1 (main + Subscription01), DSD
available systems = 3 entries (WLAN present).

Two separate causes:

1. **IMS MSISDN never learned.** T-Mobile's registration URI list has no
   `tel:` entry, only `sip:<digits>@msg.pc...`, `sip:+<E.164>@ims.mnc...`,
   `sip:<IMSI>@ims.mnc...` and `sip:+<E.164>@msg.pc...`. ims_enabler's
   msisdn_phase only takes `tel:`, so it times out (`vendor.qmux.ims_msisdn
   = pending`) and IMSS 0x54 TLV 0x19 stays empty. Fix: accept the
   `sip:+<digits>@` user part as well; never a bare-digit sip user (one of
   them is the IMSI). Writing the number by hand (`imss-probe setstr 0x53
   0x18 ...`) was accepted but on its own did not move IMS, unlike Verizon
   (part 52).
2. **The T-Mobile handover algorithm needs a CnE Wi-Fi quality report.** F3
   (dut1, C1-214411, Diag-wfc.cfg, Wi-Fi off->on): `calling _Ex flavor of
   wifi for ee/tmo algo` -> `qpDplWiFiMeasurementsSetParamEx: START`, then
   `qpDplMetricReport: TRAT Quality 0` -> `IsHandOverPossible: TRAT is BAD:
   HandOver is NOT POSSIBLE`. The Verizon path tolerates permanently-INVALID
   Wi-Fi quality (wfc_wlan_bridge.c header); the _Ex path waits for
   `DplHandOverProcessCNEReport` (iWiFiQual GOOD / medium-low / BAD), i.e.
   the WQE report stock CnE sends. Stock A8 (part 29 trace) sent DSD 0x43
   `01:<profile 4/5/6/7/9> 10:1 11:2` when Wi-Fi was good and `10:0 11:0` on
   stop. Replaying that from dsd-probe (one-shot client) was accepted
   (result 0) and changed nothing in 60 s.

Next:
- ims_enabler: sip:+E.164 MSISDN fallback (small, needed either way).
- One reboot of dut1, then an F3 capture with the DS/ANDSF SSIDs in the mask
  (ds_qmi_dsd, ds_andsf, DplHandOverSetCNEProfileForMetrics) to see which WQE
  profile the T-Mobile path arms and why the 0x43 reports are ignored
  (client lifetime vs "Wifi measurements not started" vs wrong profile).
- Then send the 0x43 quality report from wfc_wlan_bridge's own long-lived
  DSD client, for the armed profile(s), from wlan0 RSSI.
- Capture + DSD dump: `~/android/lineage-24/field-logs/dut1-tmo-wfc-f3-20261031/`
  (private: holds IMSI/MSISDN; decode with a qdb built from dut1's
  /firmware/image/qdsp6m.qdb via lineage-23 diag-tools/build_qdb.py).

### Update 2026-10-31 evening — WQE answered: first T-Mobile Wi-Fi call; fixes pushed

- The modem asks for the quality report itself, but only to a DSD client
  registered for indications (0x38): on Wi-Fi up, IND 0x45 per requested WQE
  profile (4..7 on T-Mobile, no RSSI thresholds) + IND 0x3f mask. Reply DSD
  0x43 {01 profile, 10 status, 11 cause}: **status 0 = met** (sweep: IND 0x40
  met mask gains the profile only for 0; 1..3 clear it). Stock Verizon CnE
  was asked for 4..9 with -65/-80 thresholds.
- Answering 4..7 with status 0 from a held client: IMS voice + SMS on WLAN,
  `test_call_hold` PASS (60 s call on Wi-Fi, LTE -105..-111). The modem kept
  the state after that client exited.
- `0x53` SET_WIFI_SERVICE_CAP returns error 57 on this modem; not needed.
- Pushed (Mi8937 pepito-24): `1669d0fe` modem_evs SIM trigger to system_ext,
  `64a77a16` ims_enabler MSISDN from sip:+E.164, `43869e78` wfc_wlan_bridge
  WQE replies (bench build of the same source: IMS on WLAN 16 s after Wi-Fi
  up, unaided).
- **Open:** at 19:21:21 the serving LTE cell changed (EARFCN 66736 B66 ->
  975 B2) and IMS deregistered from IWLAN, re-registered on LTE, and stayed
  there: through the modem's fresh 0x45 requests (answered met), a re-prime
  and a Wi-Fi bounce. LTE -106, so not the -80 TH2. T-Mobile's handover
  config reads TH_1/TH_3 = 0 (Verizon -112/-100). Needs F3 (diag is wedged
  on dut1 until a reboot): mask SSID 5000/5032 + IMS, then a Wi-Fi bounce on
  the B2 cell, read qpDplHandOver / IsHandOverPossible_ex / ds_andsf_wqe.
- After flashing a build with these: re-run the gate on dut1; also check
  new2 (Verizon) still holds a call on Wi-Fi, since its modem now gets
  quality reports too (stock behaviour, but a change for our build).

### Bench 2026-10-31 night — build with 1669d0fe/64a77a16/43869e78 on dut1 + new2

- dut1 (T-Mobile): gate run 24/25 PASS incl. test_call_hold + test_call_walkaway
  and test_selinux_no_new_denials (modem_evs trigger fixed). Idle IMS on WLAN
  from boot (bridge: profiles 4..7 met), held 20+ min on B66.
- MSISDN: blanked the store (`pepito-wfc-virginize msisdn`), re-ran the
  enabler -> "set from registration URI (11 digits, verified)" off T-Mobile's
  sip:+ URI.
- new2 (Verizon): the modem asks for profiles 4..9 with thresholds (4 = -65,
  reported not met at -72; 5..9 = -80, met) — matches stock CnE.
  test_call_hold PASS. test_call_walkaway: run 1 = call setup SIP timeout over
  IWLAN (VZW_TIMER) then IMS re-registration, before Wi-Fi was touched; run 2 =
  call came up on WLAN, moved to LTE, survived; failed only the 5 s TH2-release
  budget at 7 s because wlan0 stayed associated ~6 s after `svc wifi disable`
  (bridge released TH2 12 ms after it saw the drop). Watch both on reruns.
- **New bug, fixed in frameworks/opt/telephony `59b0ccf7` (unbuilt):** dut1's
  only gate failure, test_cell_service. With IMS on WLAN the RIL reports the
  WWAN PS RAT as IWLAN (legacy mode); T-Mobile's fast.t-mobile.com bitmask has
  no IWLAN bit (Verizon's does), so DataNetworkController tore cellular
  internet down with RAT_NOT_ALLOWED each time (3x in 9 min). Fix: in legacy
  IWLAN mode, judge WWAN data by the CS-domain RAT.
- Still open: IMS leaving WLAN after the B66 -> B2 cell change (not the IMS
  APN bitmask: T-Mobile IMS includes IWLAN, no IMS PDN teardown seen).

### Bench 2026-10-31 late — build with 59b0ccf7 (telephony RAT fix)

- dut1: test_cell_service now PASS (no more RAT_NOT_ALLOWED teardowns). Gate run
  21:13: 23 pass, 2 skip — both call tests skipped "IMS voice not on WLAN after
  90 s": after the previous run's walk-away handed IMS to LTE (cell 975, B2) it
  never came back, same as the 19:21 cell-change case.
- new2 (Verizon): test_wfc.py (all 9) + test_cell_service + selinux: 11/11 PASS.
- Test changes (landing 697f0a7, 9e18d6a, 24b7f01): calls at minimum call volume
  (restored after); walk-away TH2 release timed from the Wi-Fi loss (Pronto
  teardown is 5-6 s after `svc wifi disable`); driver wakes the phone before
  re-enabling Wi-Fi (screen-off Wi-Fi does not rejoin). Earlier failures were
  486 Busy from the test line and the dozed-phone Wi-Fi wait.
- **"IMS won't return to WLAN" F3 (dut1, B2, field-logs/dut1-tmo-wfc-b2-20261031):**
  WQE met, IMS: `TRAT is GOOD and TRAT is Preferred`, `pref_rat 19`,
  `Initiate HO to sys 2` (repeated; `qpDplIsSetPrefSysDuplicate` 2 == 2) — but DSD
  `set_best_system new 1 old 1` and no ePDG attempt; MPPM:
  `ds_mppm_run_pref_rat_per_pdn_calc_algo: Found apn_api_override info for
  pref_sys 0x1` — an AP-set (API) per-APN preferred-system override pins the
  PDN to WWAN. Next: find who sets it (qcril-data in legacy mode when the
  framework sets up the IMS data network on WWAN? DSD/WDS "set APN preferred
  system"); capture QMI (strace qcrild / qmi log) across a walk-away. The F3
  stream died at Wi-Fi off again, so capture the reconnect separately.

### Bench 2026-11-01 early — "IMS never returns to WLAN" is a modem-internal gate; AP levers exhausted

Re-read of the 10-31 B2 capture: the `apn_api_override` line is at the Wi-Fi-OFF edge
(expected there) and is the ANDSF `IsAPIOverride=1` on T-Mobile's `ims` rule
(`diag-tools/mcfg-lane/andsf/tmo-andsf.xml` in the 23.2 tree: ims = LTE pri 1, WLAN pri 2,
API override on). Not an AP write: the only AP code that knows DSD 0x29 is
libril-qc-hal-qmi's AP-assisted IWLAN path, which legacy mode never runs; wfc_wlan_bridge
never sends it. The real stuck signature in that capture is IMS-side:
`qpDcmHOAPNToPrefSys` -> `qpDplIsSetPrefSysDuplicate: passed 2 stored 2` -> IMS skips
its own "prefer WLAN" request, and no MPPM `apn_pref_sys_change` ever follows.

History of this boot (20:55 reflash): run 21:00 call_hold PASS on WLAN, walk-away #1 ->
IMS came BACK to WLAN (run 21:05 call_hold ran at rat=0); walk-away #2 at ~21:08 -> never
back since (21:13 run skipped, still on LTE at 01:00 on B66 and B2 alike).

AP-side state while stuck (dut1, Wi-Fi -74, bridge: WLAN_AVAILABLE + WQE 4..7 met):
DSD 0x24 per-APN table lists `ims` with LTE only (new2/Verizon on WLAN lists IWLAN
first); `tcpdump` on wlan0 and on r_rmnet_data0 shows ZERO modem packets (no ePDG DNS,
no IKE) across a Wi-Fi bounce — the modem never attempts S2B. WDS 0x6C PDN-throttle
(new `diag-tools/nas-probe/wds-probe.c`) is empty for 3GPP/3GPP2 and rejects any other
net type, so IWLAN throttle is not visible over QMI.

Levers tried, none moved IMS off LTE: DSD 0x29 SET_APN_PREFERRED_SYSTEM ims->WLAN(1) and
->IWLAN(2); IMSS 0x53 WFC preference 1->2->1; IMSS WFC on/off (TLV 0x14 1->0->1);
reg_mgr test_mode 1->0 (IMS deregistered and then sat NOT_REGISTERED 6 min waiting on
IWLAN — the DSD table briefly showed ims preferring a null-bearer S2B system — until a
Wi-Fi bounce put it back on LTE); Wi-Fi bounce with re-prime (+WAKEUP; screen-off Wi-Fi
does not rejoin). All settings restored (0x54 TLV 0x15/0x16 = 1, test_mode 0).

Working hypothesis: modem S2B PDN throttle, keyed per SSID
(`ds_iwlan_s2b_pdn_throttle_*`, has an "infinite timer" branch, and it pushes a
PDN_THROTTLE_INFO event to MPPM, which would drop IWLAN from the ims APN's system list —
exactly the table we see). Two abrupt tunnel losses on the same SSID -> throttled.
Only F3 can confirm (diag is wedged on dut1 until the next reboot): run
`diag-tools/wfc-tmo/capture-return-to-wlan.sh dut1` on a fresh boot; it arms diag,
waits for WLAN, does two abrupt losses with marks, decodes. Then grep
`s2b_pdn_throttle|epdg_addr|ikev2|s2b_pdn_sm|apn_pref_sys_change`. Cheap cross-check
if confirmed: a different SSID (per-SSID table) should return to WLAN immediately.
Fix candidates once confirmed: orderly loss (bridge reports WQE not-met before
WLAN_NOT_AVAILABLE so IMS hands over itself instead of the tunnel dying), or clearing the
throttle via whatever stock CnE does on Wi-Fi reconnect.

### Bench 2026-11-01 02:00 — fresh-boot F3: the "never returns" is NOT reproducible; the return takes ~120 s (MPPM t_minonwwan)

`capture-return-to-wlan.sh dut1` on a fresh boot (capture in
field-logs/dut1-tmo-wfc-return-20261101-0141, diag_mdlog still running on dut1 — leave it,
one session per boot; it holds a wake lock). Every loss today came back to WLAN:
idle loss #1 and #2 (118 s each), a second bounce inside the window (still 118 s from the
first fallback), and an in-call walk-away via wfc-call.sh (return 120 s after Wi-Fi on).
F3: after the fallback to LTE MPPM runs a per-PDN `t_minonwwan` timer; on expiry
`ds_mppm_unblock_rat_for_pdn: UnBlocking RAT 0 ... override_cause_mask 0x100` ->
`apn_api_override pref_sys 0x2000001` -> S2B PDN up (`ds_iwlan_s2b_pdn_sm_enter_net_up_state`,
throttle table empty). So the DSD "ims = LTE only" table is just this block, and the test's
90 s wait (`test_wfc.py` on_wlan) is shorter than the modem's 120 s minimum — raise it to
~180 s. Yesterday's hours-long stuck state (after the 21:08 in-call walk-away, and after the
19:21 B66->B2 cell change) did not reproduce in four tries; what differed is unknown
(candidates: the cell change itself, the B2 cell, many back-to-back test runs). Next time it
happens: do NOT reboot — the stuck state is the thing to capture (diag must be fresh that
boot), and dump DSD 0x24 + imsa first.

### Bench 2026-11-01 10:30 — ROOT CAUSE + FIX: the modem keeps the bridge's last WQE verdict

Reproduced under live diag with the in-call walk-away loop (`wret-loop.sh`, 6/6 returned
on B66 in 95–110 s; on B2 the 3rd never returned in 240 s, came back ~5 min later).
In the stuck cycle the modem's IMS *itself* requested the handover to LTE (quality
verdict "not met" processed just before WLAN_NOT_AVAILABLE) instead of the tunnel dying.
Decisive quiet experiment: sending DSD 0x43 "not met" for profiles 4..7 with Wi-Fi up
moved IMS to LTE in 10 s and it never came back (8 min, table still listing IWLAN);
re-sending "met" brought it back in 10 s. The modem keeps the LAST verdict and never
asks again; the bridge only spoke on change or on a fresh 0x45, and on the down edge it
sent "not met" ms before WLAN_NOT_AVAILABLE — that race is the stuck entry. Stock CnE
re-sends its verdict every ~10 s.

Fix: Mi8937 `63914f26` (pushed, pepito-24, unbuilt): repeat the verdict every 10 s,
no "not met" on the down edge, remember the profile set in vendor.qmux.wfc_wqe_prof and
seed it after a restart. Bench-binary proof on dut1: injected "not met" = 3 s on LTE then
back; Wi-Fi bounce returns in ~20 s; restart seeds 0xf0. Also landing `2ffd4c3`: the
gate's on-WLAN wait 90 -> 180 s (plain fallback still takes the modem's 120 s
t_minonwwan). dut1 runs the OLD service bridge again (diag_mdlog still live on this boot).
Next: build, re-run the gate on dut1 (T-Mobile) and new2 (Verizon: it now gets
repeated verdicts too — watch test_call_hold/walkaway).

### Bench 2026-11-01 12:00 — build 20261101 with 63914f26 VALIDATED on both carriers

test_wfc.py with calls: dut1 (T-Mobile) 9/9, new2 (Verizon) 9/9 — hold + walk-away +
return within the 180 s window. Rest of the suite without calls: new2 25 pass; dut1 24
pass + one kernel-health hit (one-off rpm-smd WARNING at the first deep sleep, 64 s
after boot, cpuidle path; not from this build's only change — watch the next boot).
Bench notes: dut1's Office AP sits at -77..-86 from its bench spot (below the -75 sticky
TH2 arm), which failed its first call run; it is now on yelppub (-70). new2 must be
unlocked first (android-unlock-new2) or the call tests skip.

## Bug 2026-11-01 — GPS slow / "not working" (user report): no XTRA at all, assisted GPS off by default

**Report:** the US Mobile user (see "Bug 2026-10-30") says GPS doesn't work; Wi-Fi off, Verizon data flaky.

**What the build actually does (dut1 + new2, `20261101`):**
- Lineage's Settings → Location → "Use assisted GPS" (`Settings.Global.assisted_gps_enabled`) defaults
  **off** (vendor/lineage overlay). Off ⇒ `GnssLocationProvider.getSuplMode(false)` = STANDALONE: no SUPL
  either, pure cold starts. dut1 = 0, new2 = 1 (set by hand).
- No XTRA: `loc_launcher` is `disabled` (mithorium-common `de3e7b4`). Started by hand on dut1, the Nokia-A11
  `xtra-daemon` blob fails to link `vendor.qti.hardware.qccsyshal@1.0.so` (a whole HAL service we don't ship).
  The HAL's `getExtensionXtra()` returned nullptr ⇒ `mSupportsPsds=false`, and no `LONGTERM_PSDS_SERVER` is set.
- dut1's modem still held an XTRA file from its A11 days (2026-08-09, 168 h), long expired.

**Stock reference (silver, A8, same MPSS C1-214411):** `loc_launcher` + xtra-daemon, lowi-server, xtwifi-*,
slim_daemon. `xtra.sqlite`: modem-supplied URLs `http://xtrapath{1,2,3}.izatcloud.net/xtra3grc.bin`, last
download 2026-11-01 09:22.

**Bench, dut1, raw QMI LOC (`diag-tools/xtra-probe/`):** modem source list (0x36) = the izatcloud URLs.
`INJECT_XTRA_DATA` 0xA7 ⇒ QMI err 94 (not supported); `QUERY_XTRA_INFO` 0xB0 ⇒ err 57. Deprecated
`INJECT_PREDICTED_ORBITS_DATA` 0x35, 1 KiB parts:
- `https://path1.xtracloud.net/xtra3grc.bin` (33 KB) ⇒ every part SUCCESS, validity 2026-11-01 22:00 UTC, 168 h.
- izatcloud `xtra3grc.bin` (27.6 KB) ⇒ last part INVALID_PARAMETER, with or without a UTC-time injection (0x38).

**Change (PUSHED 2026-11-01, unbuilt):** mithorium-common `e6262b9`, Mi8937 `f084c362`, LineageParts `adfee737`.
- mithorium-common: `gps/android/2.1/GnssXtra.{h,cpp}` = `IGnssXtra` that injects the framework's PSDS
  download with 0x35 over a private raw QMI LOC client (libqmi_cci dlopen'd, like the qmux tools; one client
  kept for the process lifetime because QCCI holds a pointer to its os_params), and calls
  `downloadRequestCb()` 24 h after a good injection (6 h after a failed one); A17 only downloads once per boot
  otherwise. `/vendor/etc/gps_debug.conf` sets `LONGTERM_PSDS_SERVER_{1,2,3}` = xtracloud.net; `hal_gnss_qti`
  may read `gotweak_prop`.
- Switch `persist.gotweak.gnss_xtra`; unset, it follows `ro.vendor.qmux.enable` (pepito only), so the Xiaomi
  siblings are unchanged. Off at boot ⇒ `getExtensionXtra()` returns nullptr (old behaviour); turned off later ⇒
  nothing more is injected or requested.
- LineageParts: Modem Tweaks → Location → "Download satellite orbit data" (restart to apply).
- Mi8937: pepito RRO `xiaomi_pepito_overlay_settingsprovider` sets `assisted_gps_enabled` default **on**, as on
  stock (silver: `default:1`). Only applies when the settings DB is created (fresh install/wipe). Existing
  installs keep their stored 0 unless someone wrote it: new2 shows `pkg:com.google.android.gms value:1`
  (Google Play services turned it on). Open: migrate untouched existing installs (`pkg:android value:0`).
- Code review (Fable) before commit: fixed a stack-lifetime bug (os_params), longer QMI/indication timeouts
  (8 s / 10 s, as on the bench), pepito-only default.

**Still to measure:** time-to-first-fix A/B on dut1 with sky view (delete_aiding_data vs delete + time + XTRA);
GPSTest installed on dut1 for it.

## Bug 2026-11-02 — Play services crash loop: "Missing local network permission" (user report, gapps)

The T-Mobile user's unit (c3ad6a80, 20261023 gapps): 78 dropbox `system_app_crash` from `com.google.android.gms`
26.42.31, all `SecurityException: Missing local network permission` in `NsdManager.registerService`
(Nearby / Quick Share advertising from a background service). Its `ACCESS_LOCAL_NETWORK` read
`granted=false, flags=[GRANTED_BY_DEFAULT]`.

- **Cause.** A17 `platform.xml` splits `INTERNET` → `ACCESS_LOCAL_NETWORK` for targetSdk < 37. Our
  gapps system-image GmsCore (NikGapps 25.34.34) targets 36, so it holds the permission as an implicit
  compat grant (`IMPLICIT_GRANTED`). Default grants then add only `PREGRANT`: `DefaultPermissionGrantPolicy`
  skips `grantPermission` because the permission already reads granted, and its flag update clears
  `IMPLICIT`. Internal state before the update: `PREGRANT|IMPLICIT_GRANTED`, no `RUNTIME_GRANTED` (seen on
  dut1 for app ID 1000 in `dumpsys permissionmgr`). A Play update to a targetSdk-37 GmsCore stops the
  compat grant (`AppIdPermissionPolicy.kt` ~:1247 clears `IMPLICIT_GRANTED`), nothing is left, and it ends
  `[PREGRANT]`, denied. Default grants re-run only when `ro.build.version.incremental` changes, so every
  new build heals an affected phone durably (the grant is explicit by then). Fresh state (new flash,
  factory reset, new user) on a build whose system GmsCore targets 36 re-breaks after the first Play
  update. Stock escapes because its factory GmsCore already targets 37.
- **Reproduced on dut1 2026-11-02** (symptom and final flags; the intermediate state was not captured):
  `cmd package uninstall-system-updates com.google.android.gms` (→ target 36), `pm create-user`,
  `adb install-multiple` the 26.43.30 splits (→ target 37) ⇒ the new user ends
  `granted=false, flags=[GRANTED_BY_DEFAULT]`. Splits backed up at netbook4
  `~/android/lineage-24/gms-backup-dut1/gms-26.43.30/` and dut1 `/data/local/tmp/gms-26.43.30/`.
- **First fix was wrong**: frameworks/base `4592c9f566ca` patched the `hasImplicitFlag` branch, which
  this state never reaches (independent review). Reverted in `f0610526e72a`.
- **Fix STAGED on the builder, unbuilt**: system GmsCore replaced by `PrebuiltGmsCoreVic.apk` 26.11.36
  (261136035, targetSdk 37, explicitly requests `ACCESS_LOCAL_NETWORK`, same V3 signer `5f239127…5402`,
  sha256 `35f23040…c1c2`), taken from `com.google.android.gmssystem.prodvic.apex` in MindTheGapps
  `17.0.0-arm64-20261022_132445` (zip sha256 `a6844eeb…ca4d`, matches the release's `.sha256sum`). Dropped
  in as `vendor/pepito-gapps/overrides/PrebuiltGmsCoreVic.apk`; `extract-nikgapps.py` re-run (signer regex
  fixed for v3-only APKs). Tree diff vs before: the APK plus the three XMLs with a gms block; the 6 new
  signature|privileged perms (ACCESS_CELL_BROADCAST, DRAW_MOTION_CUES, LOG_COMPAT_CHANGE,
  PACKET_KEEPALIVE_OFFLOAD, PERFORM_GESTURE_EXCHANGE, READ_COMPAT_CHANGE_CONFIG) are allowlisted. Pre-change
  tree: builder `~/gms-apex-check/pepito-gapps-pre-gmscore-override/`.
- **System partition space**: the new APK is 24.7 MiB larger. dut1 on 20261101 gapps has `/` with
  36.1 MiB free (used + avail = the whole fs, so no ext4 root reserve), leaving ≈11 MiB after the swap.
  The 40 MiB `WITH_GMS` reserve in `device/xiaomi/Mi8937/BoardConfig.mk` is NOT enforced: with
  `BOARD_SYSTEMIMAGE_PARTITION_SIZE` set, `build_image.py` builds a fixed-size image and only the dynamic
  path reads `partition_reserved_size` (20261101 shipped with less free than the reserve). Real limit =
  content fits the fixed fs (3096336 KiB). Future gapps growth over ≈11 MiB needs an app dropped.
- **dut1 left in the broken state** (user 0 `granted=false`), test user removed.
- **Build-verify on dut1**: (1) after flashing, user 0 granted=true (any new build does this);
  (2) the fix: `cmd package uninstall-system-updates com.google.android.gms` ⇒ system copy reports
  targetSdk 37; `pm create-user t2`; in `dumpsys permissionmgr` t2's GmsCore ACCESS_LOCAL_NETWORK must be
  `RUNTIME_GRANTED|PREGRANT` (explicit, not IMPLICIT_GRANTED); `adb install-multiple` the backup ⇒ still
  granted; `pm remove-user`. (3) Run `scripts/audit-privapp-permissions.py` on the built tree first.

## Bug 2026-11-02 — release `20261101` gapps does not boot (WITHDRAWN)

User reports: Scott (`620a962c`, gapps) and Neil ("last update hangs phone").
system_server crash-loops every ~15 s on the boot animation:
`AbstractMethodError: INetworkStatsService.registerUsageCallback(...)` on
`NetworkStatsService`, thrown from `NetworkPolicyManagerService.initService`.

**Pulled 2026-11-02:** both 20261101 entries removed from `pepito.json`
(`ad013f0`); GitHub release marked pre-release with a "withdrawn" banner;
20261023 is Latest again. Zips kept for forensics.

**What is wrong (FACT, builder `~/cmp1101/`):**
- The *released* gapps zip (built 12:52 PST) is not the build benched on
  dut1/new2 (10:45 PST). The two system images differ only in
  `com.android.tethering.capex` (+ its oat files and build-manifest).
- Inside the capex only `service-connectivity.jar` differs.
  `framework-connectivity-t.jar` (the caller side) is byte-identical.
- The released `service-connectivity` has R8 strip 13 `NetworkStatsService`
  methods: `registerUsageCallback` and the newer AIDL overrides `getIfaceStats`,
  `getTotalStats`, `getUidStats` and `getRateLimitCacheConfig` (+ helpers).
- The **vanilla** release (12:21) has a `service-connectivity.jar` identical to
  the bench build, so vanilla 20261101 is good on this point. It was pulled
  from the feed anyway.
- Connectivity source is unchanged since 10-05. The R8 step reran at 12:53
  only because the `framework` turbine header jar was dirty. The only library
  jars that define `INetworkStatsService` date from 10-23/10-05. Same inputs for
  the interface, different R8 output: root cause of the nondeterminism is still
  OPEN (the bad intermediates are gone; `out/` has been rebuilt since). Today's
  20261102 gapps `out/` has the methods.

**Process gap:** `test-gate.py` keys on the *source* ID, but release-all
rebuilds each flavor, so the published bits were never booted. Fix candidates:
gate on the artifact (boot the exact released zip), and/or a packaging check
that every `INetworkStatsService` / AIDL Stub method is still implemented in
the APEX `service-connectivity.jar` (dexdump).

Rollback side effect (Scott, unexplained): after EDL back to 20261023, VoLTE
MO calls to modern handsets drop with ImsReasonInfo 1502 "sdp parse failed"
until `modemst1/2` are restored from a pre-20261101 dump. EDL never writes
modemst. Also: `fh_dump.py`'s `rawprogram_restore.xml` does not parse with
qdl 2.8 (missing `file_sector_offset`, `partofsingleimage`,
`readbackverify`, `size_in_KB`, `sparse`, `start_byte_hex`).

### 2026-11-02 — Scott's post-rollback VoLTE failure: likely `modem_evs` (in 20261101, both flavors)

`fd7d17c1` (new in 20261101) adds `modem_evs`, a vendor oneshot that runs at
boot (independent of system_server, so it also ran during the boot loop). It
caps byte 9 of modem EFS `/nv/item_files/ims/qipcall_evs_codec_config` to 02
whenever byte 9 is 03 or 04. The only layout check is `len == 32 && byte9 <= 4`.
Byte 9 = max EVS bandwidth was isolated on the **T-Mobile** layout only.

FACT, carrier profiles in modem C1-222870 (v3C3M-0), `mbn-codec.py --grep qipcall_evs`:

| profile | bytes 0-9 (+) |
|---|---|
| tmo/commerci | `00 00 10 00 00 00 00 00 02 03` |
| verizon/cdmaless | `00 00 10 00 00 00 00 00 00 02` |
| verizon/hvolte | `01 00 10 00 00 00 6d 00 02 04` `00 … 6d` |

new2's Verizon item (`… 6d 00 03 02`, byte 9 = 02) is left alone, which is why
the 11-01 Verizon bench calls passed. A unit on **hvolte** gets byte 9 04 → 02
in a layout we never decoded. Scott's symptoms fit: Verizon, failures to
EVS-capable phones only ("sdp parse failed", ImsReasonInfo 1502), survived the
EDL rollback (EDL never writes modemst; 20261023 has no modem_evs to undo it),
cured by restoring modemst1/2. HYPOTHESIS until his 20261101 getprop shows
`vendor.pepito.modem.evs=capped` (it is in his attachment
`20261101-getprop.txt`).

Consequences: vanilla 20261101 must stay out of the feed even though it boots;
every build since fd7d17c1 (incl. 20261102) carries this. Fix candidates:
touch only the exact T-Mobile layout (bytes 0-8 `00 00 10 00 00 00 00 00 02`),
everything else "unsupported"; and when the marker (`/data/pepito_evs_bw` in
modem EFS) exists but the item is not that layout, write the saved byte back.

### 2026-11-02 — why R8 stripped NetworkStatsService (root-cause pass, builder `~/cmp1101/exp/`)

- FACT (reproduced): the service-connectivity R8 command has
  `android.net.INetworkStatsService` on its `--lib` line **twice**: the jarjar'd
  `framework-connectivity-t.impl` turbine jar (lib #28) and the
  `framework-connectivity-t-pre-jarjar` turbine jar (lib #92). They differ only
  in 5 descriptors (jarjar-renamed `netstats/{StatsResult,
  TrafficStatsRateLimitCacheConfig,IUsageCallback}`). R8 keeps a duplicate
  library class silently, first arrival wins (`LibraryClassCollection.
  resolveClassConflict` returns the first). If the pre-jarjar copy wins, exactly
  those 5 overrides stop matching and are shaken with their 8 helpers = the
  13. Moving the pre-jarjar lib first reproduces the strip; removing it gives
  a correct jar.
- HYPOTHESIS (0/179 reruns reproduced it): which copy arrives first is a race in
  R8's parallel library force-load. The 12:53 command was byte-identical to
  today's (same siso cmdhash, same `--lib` order, same r8.jar), and only this
  one duplicate flipped (a lib-order change strips more, e.g. NsdService).
- Why R8 reran at all: the product switch vanilla→gapps plus `update-api`
  rebuilt the framework turbine jar, which dirties every R8/d8 consumer. Every
  fresh R8 run rolls the dice.
- Same shape elsewhere: **service-wifi** (framework-wifi.impl vs
  framework-wifi-pre-jarjar; 9 `IWifiManager` descriptors use a jarjar'd
  `ParceledListSlice`) would crash-loop system_server the same way; also
  service-uwb (not shipped), telephony-common (no known override hazard).
- Prevention: (1) release the artifact that was benched: gate `release.sh`
  on a green integration run whose `ro.build.date.utc` matches the zip's
  `post-timestamp`, and stop `release-all.sh` rebuilding after the bench;
  (2) `check-abstract-impls.py` in `release.sh` (done, 8ff43b1; catches the
  service-wifi shape too: interface and implementation are in different jars);
  (3) optional fork keep rule `-keepclassmembers class * extends
  android.os.Binder { public <methods>; }` in Connectivity/Wifi proguard
  flags. Not worth it: clean release builds (still a fresh R8 roll), R8
  `--threads 1` (unproven).
