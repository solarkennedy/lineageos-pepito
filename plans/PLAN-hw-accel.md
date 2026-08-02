# PLAN-hw-accel: Hardware-Acceleration Bring-up — every block the MSM8940 has

**Opened 2026-08-02** after the perf-HAL lane exposed how much fixed-function
hardware was silently unused. Scope: enumerate EVERY acceleration block on
MSM8940 (SD435), confirm or bring up each one, and track the deliberately-parked
ones so nothing is forgotten again. Kyle: "I want a plan file for every possible
hardware acceleration we can do on the hardware."

Companion lanes: `PLAN-perf-battery.md` (perf HAL / boosts — DONE there),
`PLAN-audio-offload.md` (the original offload failure analysis),
`PLAN-rmnet.md` Phase 4 (ipacm), `PLAN-camera.md`.

---

## Block inventory — status at a glance (audited live on DUT1, 2026-08-02)

| # | Block | What it accelerates | Status |
|---|---|---|---|
| 1 | Adreno 505 (GL) | All UI/app rendering | ✅ in use (`ro.hardware.egl=adreno`) |
| 2 | Venus decode | Video playback | ✅ in use — `OMX.qcom.video.decoder.avc` confirmed via media.metrics |
| 3 | Venus encode | Recording | ✅ solved 2026-07-10 (libC2D2 closure) |
| 4 | VFE/ISP + CPP | Camera pipeline | ✅ in use (mm-camera) |
| 5 | HW JPEG (`/dev/jpeg0`) | Still capture encode | ✅ in use (mm-jpeg blobs, 2026-07-03 fix) |
| 6 | mp-ctl / perf boosts | Scroll/launch/camera QoS | ✅ brought up 2026-08-02 (`PLAN-perf-battery.md`) |
| 7 | ADSP: sensors (SSC) | Prox/ALS | ✅ (sensors lane) |
| 8 | IPA | Mobile-data fast path | ✅ (rmnet lane) |
| 9 | WCNSS | Wi-Fi/BT | ✅ |
| 10 | ARMv8 CE | FBE/crypto | ✅ (CPU crypto instructions — this IS the hw path; no ICE on this SoC) |
| 11 | **MDP5 overlay composition** | Display composition w/o GPU | 🔴 **GAP — Lane A below** |
| 12 | **Widevine (TEE DRM)** | Protected streaming | 🔴 **GAP — Lane B below** |
| 13 | ADSP compress-offload | Music decode off-CPU | 🟡 deferred — Lane C |
| 14 | IPA tethering offload | Hotspot NAT off-CPU | 🟡 parked — Lane D |
| 15 | MDSS rotator | Rotated video scanout | part of Lane A |
| 16 | Hexagon FastRPC (adsprpcd) | App DSP compute | ✅ ships; app-driven, nothing to do |
| 17 | Vulkan | — | ⛔ impossible: no driver exists in the 8937 blob generation (nightly checked) |
| 18 | A2DP offload / storage ICE / VPP | — | ⛔ not present on this SoC generation |

---

## Lane A — MDP5 overlay composition (the big one) 🔴

**Finding (2026-08-02):** SDM hwc2 (msm8953 display-caf branch — identified by the
`compositon:` typo in `dumpsys SurfaceFlinger`) marks EVERY layer `Client/Client`.
The Adreno GPU composites every frame of every screen-on second; MDP5's overlay
pipes (VIG/RGB/DMA), which blend layers in scanout hardware for free, sit idle.

**Why it matters:** continuous GPU power + memory-bandwidth tax. Prime suspect
for the open **"+59% screen-on idle @ brightness 255"** cell in the battery
campaign (`PLAN-perf-battery.md`). Also the biggest smoothness headroom left:
video playback via a VIG pipe (NV12 UBWC direct scanout) skips the GPU entirely.

**Evidence so far:**
- All buffers `RGBA_8888_UBWC`; working theory: 8937 MDP rejects UBWC RGB
  scanout → SDM validates every layer to Client. NOT yet proven.
- `debug.gralloc.gfx_ubwc_disable=1` + allocator+SF restart did NOT change
  allocated formats — either the *prebuilt* `gralloc.msm8937.so` is what's in
  use (different vintage/prop set?) or the prop must be set before boot.
  (Prop reset to 0 afterwards; device left clean.)

**Investigation plan (order matters):**
1. Identify the actual gralloc + hwc modules loaded: `lsof`/maps of the
   allocator and composer services; do we load prebuilt `gralloc.msm8937.so` /
   `hwcomposer.qcom.so` or the source-built msm8953 SDM stack? (Both exist.)
2. Two-device methodology: `dumpsys SurfaceFlinger` composition types on the
   stock A8 witness — confirm stock uses DEVICE/overlay composition and note
   its layer formats (almost certainly non-UBWC RGB or UBWC handled by mdss).
3. Make SDM say WHY it falls back: sdm verbose logging props
   (`hardware/qcom-caf/msm8953/display/sdm/libs/utils/debug.cpp` enumerates
   them) → look at validate/prepare cycle per layer.
4. Test UBWC theory properly: set `debug.gralloc.gfx_ubwc_disable=1` via
   `adb shell setprop` + **reboot** (prop persists? if not, temporary
   build.prop edit on /vendor) → recheck composition types. If layers go
   DEVICE: decide ship-config (UBWC off costs GPU render bandwidth but buys
   MDP composition — measure both with CT-3 screen-on idle).
5. If not UBWC: check mdss DT/kernel side — pipe counts, `qcom,mdss-mdp`
   caps vs stock DTB (`dts-3.19-pepito`), SMP/BW client votes; check whether
   SDM's fb-device probe (`/dev/graphics/fb0` ioctls) reports overlay caps.
6. Video-layer check once basic overlays work: YouTube/local playback should
   show the video layer as DEVICE (VIG pipe) — big battery win for video.

**Risk:** display is the one subsystem everyone stares at; regressions are
instantly visible (artifacts, color, tearing). All experiments are prop-gated
and bench-first; the current all-GPU path remains the known-good fallback.
⚠️ Reminder from memory: never `ctl.restart vendor.hwcomposer-2-1` live.

**Success metric:** StatusBar/NavBar/app layers show DEVICE in dumpsys; CT-3
screen-on idle delta vs today's all-GPU baseline; no visual regressions
(color-transform lane retest — libsdm-color interaction!).

---

## Lane B — Widevine DRM (known recipe, do first) 🔴

**Finding:** only `clearkey` ships (`/vendor/lib*/mediadrm/`,
`drm-service.clearkey`). **The Mi8937 nightly vendor.img contains
`android.hardware.drm@1.3-service.widevine`** — never extracted into our vendor
repo. Same packaging-gap class as the perf HAL / libacdbloader / libsdm-color.
Consequence today: ANY Widevine app (Netflix, Prime, Disney+…) fails to play
protected content at all.

**Plan (the perf-HAL recipe verbatim):**
1. Extract from nightly: `/bin/hw/android.hardware.drm@1.3-service.widevine`,
   its rc in `/etc/init/`, plus DT_NEEDED closure (expect `liboemcrypto.so` —
   check whether it lives in /vendor/lib64 or is linked static — and
   `libwvhidl`-era libs; walk the closure like we did for perf).
2. Check VINTF: does our `/vendor/etc/vintf/manifest.xml` already declare
   drm@1.3 widevine (it declared perf while unshipped — likely yes)? If not,
   add a manifest fragment.
3. Sepolicy: expect `hal_drm_widevine`/`mediadrm` policy in qc sepolicy same
   as hal_perf; verify binary auto-labels via file_contexts before staging.
4. Live-validate on DUT1 exactly like perf HAL: push + manual start + check
   registration, then `DrmInfo`/app probe. Validation: an L3 check app or
   `KeyRequest` smoke test; expect **L3** (software crypto inside the CDM) —
   L1 would need Palm's TEE widevine keybox; check whether stock A8 was L1
   (witness: `getprop`/DrmInfo on stock) and whether the widevine TA exists in
   our firmware partition. L3 is the ship target; L1 is stretch.
5. Stage into `vendor/xiaomi/Mi8937` (bp prebuilts + vendor.mk + rc), commit.

**Effort:** ~1 session. **Risk:** low — additive, nothing depends on it today.

---

## Lane C — ADSP compressed audio offload (deferred 2026-07-06) 🟡

Background (`PLAN-audio-offload.md`): compress offload crashed DSP-side —
`ASM_STREAM_CMD_OPEN_WRITE_V3 → ADSP_EFAILED`; conclusion was the stock A8.1
ADSP image lacks the compressed-decode topology for the modern usecase, and
`audio.offload.disable=1` was baked in (pepito block, device.mk). Music decodes
on CPU since.

**Reality check before reopening:** the win is modest (a few mA during
screen-off music) and the crash analysis was solid. Reopen ONLY as a
low-priority lane after A+B, with new angles:
1. Retest plain compress offload post-ACDB-fix era (ACDB now engages real cal;
   the old analysis predates some audio landings) — one setprop flip on bench.
2. If still EFAILED: compare stock A8's offload usecase parameters (bitrate,
   format caps in `audio_policy_configuration.xml` vs stock) — stock A8 DID
   offload MP3/AAC; match its exact stream/topology IDs.
3. Consider PCM (non-compressed) deep-buffer offload as the fallback win —
   different ASM opcode family, may not hit the missing topology.
4. Success metric: CT-3/coulomb screen-off music playback mA, ours vs stock.

**Do not** chase the "fix ACDB → offload free" theory — falsified 2026-07-06.

---

## Lane D — IPA tethering offload (parked) 🟡

`PLAN-rmnet.md` Phase 4: data path uses IPA, but hotspot/tethering NAT runs on
CPU because `ipacm` (IPA control manager, programs the NAT/routing rules into
the IPA) was never staged. Matters only under active tethering load (CPU wakes
+ throughput ceiling).

**Plan:** stage nightly `ipacm` + config (`IPACM_cfg.xml`), its rc + sepolicy;
validate: hotspot on, iperf through the phone, confirm offload stats in
`/d/ipa/` and lower CPU load vs baseline. Also gates the Android
`ITetheringOffload` HAL question (config_tether offload flags). Effort: 1-2
sessions. Priority: lowest of the four unless Kyle starts using hotspot in the
car.

---

## Sequencing recommendation

1. **Lane B (Widevine)** — known recipe, unlocks an app category, low risk.
2. **Lane A (MDP overlays)** — biggest payoff (battery + smoothness), needs
   real investigation; run its CT-3 measurements against the same baselines as
   the perf-battery lane so numbers compose.
3. **Lane C (audio offload)** — one cheap retest, then decide.
4. **Lane D (ipacm)** — when tethering matters.

Cross-cutting rule (from the perf-HAL lane): whenever a QTI feature is dead,
FIRST check whether the consumer blob/service was simply never packaged —
`proprietary-files*.txt` listings are aspirations, not facts. Verify against
the nightly vendor.img (`sdat2img` + `debugfs rdump` recipe, memory
`build-and-vendor-notes`).
