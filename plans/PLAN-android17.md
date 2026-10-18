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

- [x] **Released `20261017` (2026-10-17, vanilla only, tag `pepito-24.0-20261017`)**: first 24.0
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
