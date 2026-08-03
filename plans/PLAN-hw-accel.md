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
| 11 | **MDP5 overlay composition** | Display composition w/o GPU | ✅ **VALIDATED+COMMITTED `13be436` 2026-08-02** — Lane A below |
| 12 | **Widevine (TEE DRM)** | Protected streaming | ✅ **L1! VALIDATED+COMMITTED `4d6f3e6` 2026-08-02** — Lane B below |
| 13 | ADSP compress-offload | Music decode off-CPU | ✅ **WORKS 2026-08-03 — the old EFAILED no longer reproduces; enable staged** — Lane C |
| 14 | IPA tethering offload | Hotspot NAT off-CPU | 🟡 parked — Lane D |
| 15 | MDSS rotator | Rotated video scanout | part of Lane A |
| 16 | Hexagon FastRPC (adsprpcd) | App DSP compute | ✅ ships; app-driven, nothing to do |
| 17 | Vulkan | — | ✅ **ALREADY WORKING — probed 2026-08-03, nothing to do.** The "not in hw/" premise was wrong: the loader uses the sphal namespace, whose search path includes `/vendor/lib64` root, so `vulkan.adreno.so` loads fine where it sits. `cmd gpu vkjson` on DUT1 → full caps dump, deviceName "Adreno (TM) 505", device apiVersion 1.1.128, and the build already advertises `android.hardware.vulkan.version=1.1` + compute + deqp-level features (`pm list features`). Caveat: enumeration/vkjson-proven, no sustained app-render stress test — if a Vulkan app misbehaves someday, that's new information, not a packaging gap |
| 19 | OpenCL (GPU compute) | App GPGPU (photo apps, RS replacement) | ✅ **SOLVED+FLASH-VALIDATED 2026-08-03** (committed `fc47e08`; baked build re-proves compute + same_process_hal_file labels under Enforcing) — freestanding probe (`clprobe.c`: -nostdlib + raw syscalls, linked straight against the blob, no NDK needed) reports **OpenCL 2.0 / Adreno 505 (1 CU, 1401 MiB)** and a vadd kernel compiles+dispatches+reads back correctly → full libCB/llvm/KGSL path proven. Staged in mithorium-common: lib+lib64 `libOpenCL.so` + trimmed `/vendor/etc/public.libraries.txt` (perfd-client, adsprpc `64`-tagged — no 32-bit copy in our build, OpenCL). sepolicy already covers it (`legacy-um file_contexts:698` → same_process_hal_file). Closure clean: dlopens only libCB/libgsl (shipped); nightly's top-level `libq3dtools_adreno.so` is just a symlink into egl/ (we ship the real one). App-level visibility ✅ 2026-08-03: purpose-built probe APK (targetSdk 34, untrusted_app) loads libOpenCL from the app namespace — ⭐ apps targeting SDK 31+ MUST declare `<uses-native-library android:name="libOpenCL.so">` or dlopen fails "not found" (that is per-app manifest opt-in, not a ROM gap). Probe source: scratchpad clapp/ (aapt2+d8+debug-keystore recipe, no SDK project needed) |
| 18 | A2DP offload / storage ICE / VPP | — | ⛔ not present on this SoC generation |
| 20 | HW JPEG for USB Webcam mode (MJPEG) | UVC gadget frame encode | 🟡 parked someday-note — Lane E below. Webcam mode itself ✅ works (VLC-validated 2026-08-03, memory `usb-webcam-mode-works`); encode is **software** |

---

## Lane A — MDP5 overlay composition ✅ SOLVED+VALIDATED+COMMITTED `13be436` 2026-08-02

**OUTCOME:** DEVICE (MDP overlay) composition live on DUT1 under Enforcing —
NotificationShade / StatusBar / Wallpaper all DEVICE in `dumpsys SurfaceFlinger`,
no SDM errors, clean boot. Ship set = **three** blobs in mithorium-common:
`libsdmextension.so` + `libscalar.so` + `libhdr_tm.so`.

⭐⭐ **The trap that black-screened the first validation boot:** shipping
libsdmextension ALONE is worse than not shipping it. It dlopens `libscalar.so`
(QSEED scaler) and `libhdr_tm.so` — invisible to DT_NEEDED (libC2D2 lesson
again; found via `strings | grep '\.so$'`). With those absent the extension
loads but its init fails → `CoreImpl::Init` hard-fails (`HWCSession::Init:
Display core initialization failed. Error = 2`) → composer crash-loop → black
screen right where the boot animation starts (Palm logo is bootloader-drawn).
Missing lib = graceful GPU fallback; half-satisfied lib = dead display.

**CT-3 screen-on idle A/B — DONE 2026-08-03, verdict inverted the hypothesis:**
Same unit (DUT1), same build, composition toggled by renaming libsdmextension
(graceful GPU fallback) + reboot. Protocol hardening that the first attempts
forced: (1) battery must be **status Full** before every leg — each reboot
burns ~25 mAh and the charger tops up for ~10 min, adding ~400-500 mW to the
reading; (2) dismiss the keyguard — lockscreen imposes a 10 s WM user-activity
timeout that DIMS the screen mid-leg (`wm dismiss-keyguard`, then verify
`Display Brightness=1.0` pre AND post capture — one leg silently measured a
dimmed panel at 688 mW).

| Leg (Full, launcher, brightness 255, bright-verified) | Power (median) |
|---|---|
| MDP overlay composition (4 DEVICE layers) | 1181–1212 mW |
| All-GPU composition (Client) | 1136–1148 mW |

**MDP costs ~50 mW MORE at *static* screen-on idle** — with a static screen,
GPU composition produces zero recompositions (one cached FB scans out), while
MDP fetches 4 layers per 60 Hz frame forever. Root cause of "forever":
**SDM's idle fallback is NOT engaging** — still 4 DEVICE layers after 95 s
hands-off, despite `IDLE_TIMEOUT_DEFAULT_MS=70` and kernel `fb0/idle_time=100`
armed. The +59% cell was already explained as real brightness (and the 0.73
backlight cap now ships); MDP was never the culprit. MDP's actual win is
ACTIVE content: scroll/animation GPU offload and video-to-VIG. Ship config
stays MDP.

**✅ Idle-fallback investigation CLOSED 2026-08-03 — root cause was a
self-sustaining refresh STORM, fixed + committed `6ed9b10` (mithorium.mk):**
The chain is intact end-to-end (kernel `idle_notify` fires, SDM_EventThread
polls it, ProcessIdleTimeout runs) — but under modern SF the design
livelocks: SF's response frame re-arms the kernel idle timer → ~10-14 Hz
notify/refresh/commit loop for every screen-on second, and composition never
actually drops to cached-GPU. In MDP mode each cycle is a full 4-pipe
kickoff, which is where the "+50 mW" came from:

| Leg (Full, launcher, 255, bright-verified, median) | mW |
|---|---|
| MDP, storm active | 1181–1199 |
| GPU, storm active | 1136–1139 |
| **MDP, timer neutered** | **1140 — GPU parity** |

Fix = `vendor.display.idle_time{,_inactive}=4000000` in mithorium.mk
(⭐ **0 does NOT disable** — SDM then leaves the kernel default 100 ms armed;
a huge value = one benign cycle per ~66 min). Props flow SDM→`fb0/idle_time`
at composer init only (live setprop is ineffective; DUT1 carries them via a
hand-edited /vendor/build.prop until next flash). Debug tools:
`scratchpad pollpri.c` (static-musl sysfs POLLPRI watcher) + strace of
SDM_EventThread; ⚠️ every "storm quiet" reading with the display asleep is an
artifact — the loop only runs while the screen is on.

**Remaining follow-ups:**
- [x] Video-to-VIG functional check ✅ 2026-08-03: bear-1280x720.mp4 via
      Glimpse (⚠️ needs a `content://media/...` URI — Glimpse rejects
      `file://` with "Cannot get media type"; index via MEDIA_SCANNER_SCAN_FILE
      broadcast + `content query --projection _id:_display_name`). Venus HW
      decode (`OMX.qcom.video.decoder.avc`), video SurfaceView DEVICE at z=0
      with a 1280→720 downscale (QSEED ⇒ VIG pipe by construction — RGB/DMA
      can't scale), usesClientComposition=false, 0 underruns in
      /sys/kernel/debug/mdp/stat. ⚠️ VIG0 play-count activity alone proves
      NOTHING (VIG pipes carry RGB UI layers too — first attempt false-positive).
- [ ] Active-content CT-3 power A/B (where MDP should win): scroll loop +
      video-loop legs, MDP vs GPU (rename-libsdmextension toggle), Full-battery
      protocol. Needs a long clip: loop-extend a bear clip with ffmpeg
      (`-stream_loop`) or install VLC (apk was NOT in ~/Downloads — only the
      bear clips landed).
- [x] Rebuild + flash — ✅ FLASH-VALIDATED 2026-08-03 (both lanes re-verified
      on the built images: Enforcing, widevine registered + L1 probe green,
      0 SDM errors, DEVICE composition). Build gotcha folded into the
      widevine commit: VINTF fragments must ship via `vintf_fragments` on the
      module — build/make hard-rejects them in PRODUCT_COPY_FILES.

**ROOT CAUSE FOUND (2026-08-02 session): `libsdmextension.so` was never
packaged.** SDM's real composition strategies (MDP overlay assignment) live in
that proprietary extension lib; `CoreImpl::Init()` (`sdm/libs/core/core_impl.cpp:53`)
dlopens it, logs a DLOGW on failure, and silently falls back to the default
strategy — which marks **every layer GPU**. Same packaging-gap class as perf
HAL / libacdbloader / libsdm-color / Widevine. The UBWC theory is moot (and the
07-02 prop experiment used the WRONG prop name anyway — this SDM branch reads
`vendor.gralloc.disable_ubwc`, not `debug.gralloc.gfx_ubwc_disable`; the code
comment is stale).

Supporting evidence, all gathered live on DUT1:
- Composer (pid of composer@2.1-service) loads source-built SDM stack
  (`hwcomposer.qcom.so` + libsdmcore/libsdmutils) and gralloc.msm8937.so —
  NOT prebuilts; both from `hardware/qcom-caf/msm8953/display` (repo clean,
  upstream Lineage branch).
- Kernel is fully capable: `/sys/class/graphics/fb0/mdp/caps` → mdp_version=5,
  1×VIG + 2×RGB + 1×DMA + cursor pipes, blending_stages=4, features include
  `ubwc` — so even UBWC layers are scanout-able.
- Nightly ships `lib64/libsdmextension.so` (64-bit only, matching the 64-bit
  composer); deps = libsdmutils + bionic only. Extension ABI tag v1.0 matches
  our headers. ⚠️ Note: a *version-mismatched* extension makes CoreImpl::Init
  FAIL (composer dead, no display) unlike the graceful missing-lib fallback —
  low risk since the nightly runs this exact blob against this exact branch,
  but watch the first boot.

**State:** pushed to DUT1 `/vendor/lib64` (validates on next reboot, same
reboot as Widevine) + staged in `vendor/xiaomi/mithorium-common` (blob +
mithorium-common-vendor.mk line), uncommitted.

**Validation on reboot:** `dumpsys SurfaceFlinger` composition types should
show DEVICE for at least some layers (StatusBar/NavBar/wallpaper); check
logcat for sdm strategy init; then CT-3 screen-on idle A/B vs the all-GPU
baseline (perf-battery lane numbers), video-layer VIG check, and the
color-transform retest (libsdm-color interaction!).

### Original investigation notes (kept for context)

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

## Lane B — Widevine DRM ✅ SOLVED+VALIDATED+COMMITTED `4d6f3e6` 2026-08-02 — **hardware L1, not just L3!**

**OUTCOME:** boot-validated on DUT1 under Enforcing — init-starts, all 8
factory interfaces registered, zero avc denials, and the MediaDrm probe
(app_process dex, `scratchpad drmprobe` technique: Looper.prepare +
ActivityThread.systemMain shim) reports **vendor=Google version=16.0.0
securityLevel=L1 systemId=9745 maxHdcpLevel=HDCP-2.2**. Palm's stock TZ
firmware carries a live Widevine TA + keybox — oemcrypto reached it over the
same QSEECom path as keymaster/gatekeeper. The "L3 is the ship target, L1 is
stretch" guess was beaten by the hardware.

Remaining (non-blocking): a networked license round-trip (Netflix/Shaka on
Gold) to prove end-to-end playback; RKPD already queued widevine provisioning
on first boot.

**Finding:** only `clearkey` shipped. The nightly vendor.img had the full
widevine set, never extracted — same packaging-gap class as perf HAL /
libacdbloader / libsdm-color.

**Done 2026-08-02 (this session):**
1. **Extraction + closure (complete):** from nightly `/vendor`:
   `bin/hw/android.hardware.drm@1.3-service.widevine`, its rc,
   `etc/vintf/manifest/manifest_android.hardware.drm@1.3-service.widevine.xml`,
   `lib64/libwvhidl.so` (the CDM — it **dlopens** `liboemcrypto.so`, with an
   explicit "Falling Back to L3" string on version mismatch), `lib64/liboemcrypto.so`,
   plus liboemcrypto's two missing deps `libhdcpsrm.so` + `libcpion.so`, and
   `lib64/mediadrm/libwvdrmengine.so`. Everything else in the DT_NEEDED closure
   is already in our build (checked vs `installed-files-vendor.txt`); liblog is
   LLNDK. 64-bit only, matching the nightly.
2. **VINTF:** nightly declares it as a manifest **fragment** (staged verbatim).
   Framework FCM 7 accepts hidl drm `1.3-4` with `regex-instance .*` — no
   compatibility obstacle.
3. **Sepolicy: nothing to add.** `hal_drm_widevine.te` + file_contexts already
   in `sepolicy-legacy-um` and present in the flashed build — pushed binary
   auto-labeled `hal_drm_widevine_exec` on DUT1.
4. **rc trimmed:** dropped the `vendor.move_data_sh` legacy-migration service
   (`/system/bin/move_widevine_data.sh` doesn't exist in our system build);
   kept the `mkdir /data/vendor/mediadrm 0770 media mediadrm` trigger.
5. **Live push done; manual start hit the expected VINTF wall:** service links,
   CDM initializes, then aborts at `registerAsService` because hwservicemanager
   only reads manifest fragments at boot. All files are on DUT1's live /vendor →
   **next reboot IS the validation** (init-start under Enforcing + lshal +
   DrmInfo/L3 probe).
6. **Staged into `vendor/xiaomi/Mi8937`** (Android.bp prebuilts + Mi8937-vendor.mk
   PRODUCT_PACKAGES/COPY_FILES), uncommitted — commit after reboot validation.

**Remaining:**
- [ ] Kyle: reboot DUT1 → validate: `lshal | grep widevine`, no avc denials,
      DrmInfo/app shows Widevine L3 (`securityLevel` prop = L3 expected).
- [ ] Commit vendor/xiaomi/Mi8937.
- [ ] Stretch (separate, optional): L1 — needs widevine TA in firmware
      partition + Palm keybox; check stock A8 witness level first. L3 ships.

---

## Lane C — ADSP compressed audio offload ✅ RETESTED GREEN + FLASH-VALIDATED 2026-08-03 (committed `3a3841eb`; baked build: prop unset by default, compress-offload-playback opens + decodes under Enforcing, 0 denials)

**Retest result (the "one cheap setprop flip" — item 1 below — executed):**
`setprop audio.offload.disable 0` + audioserver restart on DUT1, then a direct
**offloaded AudioTrack** fed raw MP3 (probe `scratchpad AOff.java`, app_process
dex — MediaPlayer from app_process fails prepare with 0x80000000, attribution
issue, don't bother; AudioTrack.Builder.setOffloadedPlayback needs no Context
and `AudioManager.isOffloadedPlaybackSupported` is static):
- Policy reports mp3/44.1k offload supported (mono+stereo) once the prop flips.
- HAL opens `compress-offload-playback`, routes to speaker (acdb 14),
  `offload_visualizer` attaches, playback head advances ~16 s of decoded audio.
- **Zero ADSP_EFAILED, no ADSP SSR** (dmesg: adsp untouched since boot).

The 2026-07-06 "stock A8.1 ADSP image lacks the topology" conclusion is
FALSIFIED in the current build era — most plausibly the ACDB fix (real cal now
engages, 2026-07-11) changed what the ASM open sends. Staged: the
`audio.offload.disable=1` block REMOVED from Mi8937/device.mk (comment
documents history + revert path). DUT1 left with offload live-enabled
(setprop, reverts on reboot) for music smoke-testing.

**Remaining validation (post-flash, non-blocking):**
- [ ] Real music app (Twelve — it defaults enableOffload=true) — play, pause,
      seek, track-switch, A2DP routing mid-stream.
- [ ] The lane's original success metric: CT-3/coulomb screen-off music mA,
      offload vs PCM (and vs stock if a witness ever returns to the bench).

### Original deferral analysis (kept for context — deferred 2026-07-06) 🟡

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

## Lane E — HW JPEG for USB Webcam mode (parked someday-note) 🟡

**Context (2026-08-03):** USB "Webcam" mode works end-to-end out of the box —
kernel `f_uvc` gadget (`uvc,adb` composition, 18d1:4eee), `DeviceAsWebcam`
priv-app services the gadget V4L2 node, host negotiated 1920×1080 MJPEG @60,
VLC-validated on DUT1. Lane closed with no ROM work (memory
`usb-webcam-mode-works`; cheese failing is a host-side GStreamer issue).

**The acceleration gap:** DeviceAsWebcam encodes every frame in software —
libyuv YUV→I420 + libjpeg-turbo, in its private JNI lib
(`packages/services/DeviceAsWebcam/interface/jni/Encoder.cpp`). AOSP provides
no HAL hook for JPEG here. Meanwhile block #5, the msm_jpeg HW core
(`/dev/jpeg0`), sits proven-working on the very same frames' sibling path
(camera snapshot via mm-jpeg blobs). Real delivered fps at 1080p on the A53s
will be well under the advertised 60.

**Steps 1+2 DONE 2026-08-03 — lane effectively CLOSED unless 60 fps is ever wanted:**
1. [x] **Measured:** SW encode KEEPS UP — host-side ffmpeg counts a real
   29–30 fps at **1080p30** (300 frames/10 s at 720p and 360p too). Only the
   60 fps claim was fiction; no HW encode needed for 30 fps operation.
2. [x] **Formats trimmed** — staged in the existing mithorium-common
   `init.xiaomi.rc` uvc hook (which already ran at sys.boot_completed and
   already dropped YUYV — note it used to rmdir the 720p frame, now restored):
   MJPEG 360p/720p/1080p at 30/15/10/2 fps (166666 removed),
   `bDefaultFrameIndex 2` → 720p30 default. Live-validated on DUT1 (lsusb
   descriptor dump + ffmpeg captures). The 1440p/4K + h264 groups in
   `init.qcom.usb.rc` ride only the SS header — never enumerated on this
   HS-only UDC (`msm_hsusb`), left alone.
   ⭐ Live-edit recipe (attrs are EBUSY otherwise): unbind UDC (`echo "" >
   g1/UDC`) → rm configs/b.1/function0 + class/{fs,hs}/h1 + header/h1/m1
   links → edit frames → relink → rebind. A stale `function0 → uvc.0` config
   link SURVIVES leaving webcam mode and pins everything. `svc usb
   setFunctions uvc` is rejected — webcam mode only enters via Settings UI.
   ⚠️ Linux clients (ffmpeg/uvcvideo) ignore bDefaultFrameIndex and take the
   FIRST frame (360p); Windows honors it. Apps requesting sizes get them.
3. **Actual HW encode** (only if 60 fps ever matters) — patch the JNI lib (or a small vendor-side helper) to
   drive `/dev/jpeg0` via `libmmjpeg_interface`/mm-still. Crosses the Treble
   boundary (system app → vendor blob API), needs sepolicy + hand-rolled
   integration against an undocumented API. A few sessions; only worth it if
   step 1 measures badly AND webcam mode sees real use.

**Debug note that will save an hour:** `DeviceAsWebcam: onEncoded Encoding was
unsuccessful` logged right after STREAMOFF is the encoder-thread drain path
(pending buffers returned success=false, `Encoder.cpp` threadLoop exit), NOT a
real encode failure.

---

## Sequencing recommendation

1. **Lane B (Widevine)** — known recipe, unlocks an app category, low risk.
2. **Lane A (MDP overlays)** — biggest payoff (battery + smoothness), needs
   real investigation; run its CT-3 measurements against the same baselines as
   the perf-battery lane so numbers compose.
3. **Lane C (audio offload)** — one cheap retest, then decide.
4. **Lane D (ipacm)** — when tethering matters.

## Nightly-diff sweep (2026-08-02) — the systematic version of the cross-cutting rule

Full file-list diff of nightly vendor.img vs our `installed-files-vendor.txt`:
[`nightly-vendor-only-files-20260526.txt`](nightly-vendor-only-files-20260526.txt)
(322 entries, most deliberate: source-built BT/keymaster stacks, IMS add-on
handled separately, CNE/dpm/qti-services debloated). Triage-worthy leftovers:
- `libsdmextension.so` — **the Lane A root cause**, staged this session.
- `libOpenCL.so` (+ `etc/public.libraries.txt`) — block 19 above.
- `msm_irqbalance` — we never ship an IRQ balancer; possibly relevant to the
  open "DUT1 churns 3× more wakes" cell in the XO-shutdown lane
  (`PLAN-perf-battery.md`).
- `mm-pp-dpps`, `vendor.display.color@1.0-service`, `libdisp-aba.so`,
  `libhdr_tm.so` — stock DSPP/color daemon path; we deliberately use
  LiveDisplay + the sunlight-SRE kernel node instead. No action unless the
  color lanes regress.
- `lowi-server`, `xtwifi-*` — WLAN-assisted location; GPS works without; note only.

Cross-cutting rule (from the perf-HAL lane): whenever a QTI feature is dead,
FIRST check whether the consumer blob/service was simply never packaged —
`proprietary-files*.txt` listings are aspirations, not facts. Verify against
the nightly vendor.img (`sdat2img` + `debugfs rdump` recipe, memory
`build-and-vendor-notes`).
