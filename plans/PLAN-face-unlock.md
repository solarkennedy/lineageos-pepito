# Pepito Biometric Face Unlock — Plan

**Goal:** add face unlock to the lock screen on Palm PVG-100 (pepito), LineageOS 23.2.
**Status (2026-07-03):** NOT STARTED — this is a design/scoping plan. Depends on the front
camera (S5K4H8) working, which the camera bring-up just enabled (`PLAN-camera.md`) but is not
yet confirmed streaming.

---

## Read this first — the hardware reality caps the whole feature

Pepito has **no dedicated face-unlock hardware**: no IR camera, no dot projector, no flood
illuminator. There is only the **RGB front camera** (Samsung S5K4H8, 8 MP). Every consequence
below follows from that:

- **It can only ever be "Convenience" class biometric** (`BIOMETRIC_CONVENIENCE`, the weakest
  tier), never Weak or Strong. Android enforces what a sensor may do by its class:
  - ✅ It **can** dismiss the keyguard (unlock the screen).
  - ❌ It **cannot** gate keystore-bound keys, `BiometricPrompt` for payments/apps that require
    Class 3, or clear strong-auth. The device will still demand PIN/pattern after boot, after
    timeouts, for keystore, and periodically.
- **RGB face match is trivially spoofable by a photo of the owner.** There is no practical
  liveness/anti-spoof on a single RGB stream. This is *why* Android classes it Convenience.
- **AOSP/Lineage ships no real camera face-recognition HAL.** The only in-tree implementation is
  the **virtual/simulated** `default` AIDL HAL (canned responses for testing). Real recognition
  is code we would have to build or port.

**So there are two very different deliverables.** Be explicit with the user about which one they
want before investing:
1. **Phase 1 — plumbing with the virtual HAL:** a face-unlock *toggle* and enrollment flow that
   works end-to-end through the framework, but the "matcher" is simulated. Proves the wiring.
   Days of work.
2. **Phase 2 — real recognition:** a custom Face HAL that opens the front camera, detects +
   recognizes a face, and drives the enroll/authenticate state machine. Weeks of work + a
   bundled recognition engine + the spoofability/Convenience-class caveats above. This is the
   actual feature.

If the user's mental model is "unlock like a Pixel / Face ID," set expectations: this hardware
can't do secure face unlock, only the convenience kind.

---

## Hard prerequisite — front camera must stream

The Face HAL opens the **front camera** itself (via Camera2/NDK) to get frames. That path must
work first:
- Front camera (S5K4H8, camera id 1) must open + stream — this is exactly the pending physical
  test in `PLAN-camera.md` ("flip to front camera"). **Do not start Phase 2 until front-camera
  preview is confirmed.**
- Resource contention: the Face HAL and normal camera apps both want the front camera. The HAL
  should hold it only briefly during an auth attempt and release promptly; the AIDL session model
  supports this. Confirm the camera provider tolerates a second in-process client cleanly.

---

## What's already in the tree (the good news)

- **AOSP face AIDL interface + virtual HAL:** `hardware/interfaces/biometrics/face/aidl/` with
  `IFace.aidl`, `ISession.aidl`, `ISessionCallback.aidl`, enrollment types, and a buildable
  `default/` impl (`Face.cpp`, `FaceConfig.cpp`, `face-default.rc`, `face-default.xml`,
  `face.sysprop`, plus a `virtualhal/` variant). This is both the fork template and a runnable
  virtual HAL for Phase 1.
- **Framework side is fully present:** `frameworks/base/.../hardware/face/FaceManager.java`,
  `.../server/biometrics/sensors/face/FaceService.java`, and Settings support
  (`FaceUnlockCategoryPreferenceController.java`). BiometricService → FaceService → Face HAL is
  intact, so no framework porting is needed.
- **Feature declaration file exists:** `frameworks/native/data/etc/android.hardware.biometrics.face.xml`
  (must be copied to the device's `/vendor/etc/permissions` to advertise the feature).
- **Wiring template — the existing fingerprint HAL:** `device/xiaomi/Mi8937/biometrics/hidl-ulysse/`
  (`BiometricsFingerprint.cpp`, `service.cpp`, a `.rc` init service, a `.xml` VINTF fragment,
  `Android.bp`). A Face HAL service is packaged the same way (service + `vintf_fragments` + init
  `.rc` + sepolicy + `PRODUCT_PACKAGES`). Mirror it.

---

## Architecture — where a Face HAL sits

```
Keyguard / BiometricPrompt / Settings(enroll)
      ↓  (system_server)
FaceService  ──AIDL──▶  IFace  → ISession  (our HAL, a vendor service)
                                   ├─ enroll(): capture N frames of the owner, build template,
                                   │            persist to the HAL's private storage (per-user)
                                   ├─ authenticate(): open front camera, grab frame(s), detect +
                                   │            match against template, call back onAuthentication
                                   │            Succeeded/Failed via ISessionCallback
                                   └─ acquire/enumerate/remove/getAuthenticatorId/...
      ↑
front camera (S5K4H8, id 1) via Camera2 NDK  +  a face detect/recognize engine
```

The AIDL `ISession` is a state machine; the hard part of any real HAL is implementing
`enroll`/`authenticate` honestly and persisting templates securely per-user.

### "Can't we just add `config_biometric_sensors` and skip the HAL?" — evidence from this tree

Short answer: the config **declares** a sensor, but it must be **backed by an `IFace` HAL** that
does the actual recognition. The framework contains **no camera-based face matching** anywhere.
Traced in-tree:
- `config_biometric_sensors` format (from its own doc comment,
  `frameworks/base/core/res/res/values/config.xml:6002`): `ID:modality:strength`, e.g.
  `0:2:15 = ID0:Fingerprint:Strong`. **modality:** FINGERPRINT=2, IRIS=4, **FACE=8**.
  **strength** is the `Authenticators` bitmask: **STRONG=15, WEAK=255, CONVENIENCE=4095** — *not*
  `0/1/2`. So a convenience face sensor is `0:8:4095`, **not** `0:8:2` (2 is not a valid value).
  Note: in the AIDL era the strength/props usually come from the HAL's `getSensorProps()`;
  `config_biometric_sensors` is mainly the HIDL/legacy fallback path.
- `FaceService.getDeclaredInstances()`
  (`frameworks/base/.../biometrics/sensors/face/FaceService.java:818`) discovers HALs via
  `ServiceManager.getDeclaredInstances(IFace.DESCRIPTOR)` — i.e. `IFace` instances declared in a
  VINTF manifest.
- `FaceProvider` (`.../face/aidl/FaceProvider.java:95`) is *"Provider for a single instance of the
  `IFace` HAL"*; it holds `IFace mDaemon` and routes **every** `enroll`/`authenticate` to that
  HAL's `ISession`. There is no framework fallback that opens the camera and matches faces.

So the three possible outcomes of "just add the config":
1. **config + no HAL** → sensor is declared but enroll/auth has nothing to call → fails.
2. **config + the built-in virtual HAL** (`FaceService.java:820` always appends a `"virtual"`
   instance; enable via `settings put secure biometric_face_virtual_enabled 1`) → it "works", but
   the match is **simulated/scripted via `cmd face`**, it **never opens the camera**, and it's a
   debug/test facility. Proves the plumbing; does nothing real.
3. **config + a real camera `IFace` HAL** → real face unlock. That HAL is the code that does not
   exist and must be written or ported (Phase 2).

**Empirical check (recommended to settle it):** enable the virtual HAL, enroll via `cmd face`, and
watch the keyguard "unlock" with no camera involved — demonstrating the framework path is complete
but recognition is the HAL's job. Then `dumpsys face` / logcat show the sensor with no real
capture.

---

## Phase 1 — framework plumbing with the virtual/AOSP HAL (scaffolding milestone)

Goal: a "Face Unlock" entry appears in Settings → Security, enrollment completes, and the
keyguard attempts face auth — all driven by the **virtual** HAL (simulated match). This isolates
all the wiring from the recognition problem.

1. **Build + package the AOSP `face` default (virtual) AIDL service** as a device HAL: add its
   module to `PRODUCT_PACKAGES`, ship its `.rc` (init service) and `.xml` (VINTF manifest
   fragment) so `IFace/default` is declared and started.
2. **Advertise the feature:** copy `android.hardware.biometrics.face.xml` to
   `/vendor/etc/permissions` (pepito-gated, like the camera feature files in device.mk).
3. **Sepolicy:** add/allow the `hal_face` domain (AOSP has `hal_face_default` types); label the
   service, its data dir, and grant camera + binder access. Model on the existing
   `hal_fingerprint` rules.
4. **Config overlays:** device may need `config_face*` framework overlays (e.g.
   `config_faceAuthDismissesKeyguard`, sensor properties, strength = convenience). Set the
   sensor's `sysprop`/config to **Convenience** strength.
5. **Verify:** Settings shows Face Unlock, enrollment UI runs (virtual HAL auto-completes),
   `dumpsys face` shows a sensor, keyguard invokes face auth. Real matching is simulated — that's
   expected for Phase 1.

Deliverable: the full framework path proven. No real recognition yet.

---

## Phase 2 — real camera-based recognition HAL (the actual feature)

Replace the virtual matcher with a real one. This is the substantial work.

**2a. Recognition engine (the missing piece).** Nothing in the tree does face recognition. Need a
lightweight on-device pipeline: face **detection** (locate/crop) → **embedding** (a small CNN →
feature vector) → **compare** (cosine distance vs enrolled template). Options:
- Integrate a TFLite/MediaPipe face-embedding model (e.g. a MobileFaceNet-class model) bundled in
  the HAL. Smallest new dependency footprint; runs on CPU on MSM8940.
- Reuse the camera daemon's own face-**detection** output (QTI FD, the `CAM_STREAM_TYPE_ANALYSIS`
  path — see `PLAN-camera.md`) for the *detect/crop* step only; still need an embedding+match
  stage on top. Note FD there is currently disabled (0×0 analysis res) — restoring it (PLAN-camera
  "Restore face-detect") would help but isn't required if the HAL does its own detection.
- Port an existing open-source camera-face-unlock HAL if a maintained one exists for AIDL face on
  A15/A16 (survey first; historically these are device-specific and unmaintained — the old
  `com.android.facelock` is dead and incompatible with the modern FaceManager path).

**2b. Camera capture in the HAL.** Open front camera id 1 via Camera2 NDK, grab a small YUV
stream, feed frames to the engine. Handle open/close cleanly around each auth attempt; respect
camera-in-use by foreground apps.

**2c. Enrollment + template storage.** `enroll()` captures several frames, averages embeddings
into a template, persists per-user under the HAL's data dir (labeled, not world-readable). Wipe on
`remove()`/factory reset. This is *not* keystore-backed (Convenience class) — document that.

**2d. Auth loop + callbacks.** Drive `ISessionCallback` (onAcquired/onAuthenticationSucceeded/
Failed, lockout after N fails). Tune threshold for false-accept vs false-reject on RGB.

**2e. Accept the security posture.** No liveness → spoofable by a photo; Convenience class only.
Ship with the honest caveats; do not let it gate keystore.

---

## Wiring checklist (grounded in the fingerprint template)

- [ ] Face HAL service module + `service.cpp` (fork `hardware/interfaces/biometrics/face/aidl/default`
      or a new `device/xiaomi/Mi8937/biometrics/face/`).
- [ ] `vintf_fragments` XML declaring `android.hardware.biometrics.face` (mirror
      `…fingerprint@2.1-service.xiaomi_ulysse.xml`).
- [ ] init `.rc` starting the service in the right class/user, with camera group access.
- [ ] `PRODUCT_PACKAGES += <face-service>` (pepito-gated once `TARGET_DEVICE_PEPITO` is wired).
- [ ] `android.hardware.biometrics.face.xml` → `/vendor/etc/permissions` (feature flag).
- [ ] sepolicy: `hal_face` service + data-file labels + camera/binder allows.
- [ ] framework config overlays: sensor strength = **convenience**, keyguard behavior.
- [ ] (Phase 2) recognition model asset + its license, HAL data dir for templates.

---

## Security caveats to state plainly to the user

- Convenience biometric only: unlocks the screen, **cannot** authorize keystore/payments; PIN
  still required after boot/timeouts and periodically.
- RGB-only ⇒ **photo-spoofable**, no liveness.
- Enrollment template is HAL-local, not TEE/keystore-backed.
- If the user wants *secure* face auth (Face ID equivalent), pepito hardware cannot provide it —
  don't promise it.

---

## Open questions (resolve before Phase 2)

1. Does the user want the real feature (Phase 2) or is the convenience toggle (Phase 1) enough?
2. Is front-camera streaming confirmed (S5K4H8, id 1)? — gates everything. See `PLAN-camera.md`.
3. Which recognition engine, and is its model license compatible with the build?
4. Camera contention policy: how does the Face HAL share the front camera with apps?
5. Does Lineage 23.2's `FaceService`/Settings expose enrollment for a Convenience-class sensor
   without extra overlay coaxing? (verify in Phase 1).

---

## Cross-references
- `PLAN-camera.md` — front camera bring-up (hard prerequisite); FD/analysis stream context.
- `PLAN-gatekeeper.md` — auth-token/keystore model (why Convenience class can't gate keystore).
- Fingerprint HAL template: `device/xiaomi/Mi8937/biometrics/hidl-ulysse/`.
