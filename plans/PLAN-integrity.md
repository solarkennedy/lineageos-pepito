# PLAN-integrity — Google Play Integrity on pepito

**Goal was:** `MEETS_BASIC_INTEGRITY`, nothing more. Explicitly **not** chasing STRONG, and
**not** touching keyboxes / TrickyStore / attestation forgery.

**Status 2026-07-27: CLOSED / RESOLVED (understood, unfixable from the ROM).**
`-12` is a Google-backend HTTP 500 (never graded) triggered by **our build's own identity —
the (Palm PVG100 × Android 16) combination** — hitting a backend grading gap. It is **not**
the account, **not** the physical device/provisioning, **not** the boot state, **not** the
fingerprint string. A controlled experiment (below) nails this down: holding the device and
account fixed and changing *only* the OS flips the result between graded and `-12`. There is
no ROM-side fix that isn't a dishonest spoof (and the spoofs we tried don't even work).
**Do not reopen without a genuinely new idea.**

> ⚠️ **This supersedes the 2026-07-23 "model-specific / not our build" conclusion.** That
> earlier read ("the A11 GSI got `-12` too, so the fault can't be our software") was
> **wrong** — it rested on a single primary-account GSI observation. When re-tested cleanly
> (below), the A11 GSI **grades** on this exact hardware+account, while our A16 build does
> not. The discriminator *is* our build. Correcting the record honestly.

---

## ⭐ The decisive experiment (2026-07-25 → 27): only the OS matters

Every row below is on the **same physical device (Silver `4373dd0f`, the genuine factory
PVG100)** unless noted, so hardware/TEE/attestation keys are constant:

| OS on the hardware | Google account | Result |
|---|---|---|
| factory Android 8.1 (certified config) | primary | `[BASIC, DEVICE, STRONG]` |
| factory Android 8.1, **rooted** | primary | **graded** — empty verdict (not `-12`) |
| **A11 GSI** (AOSP-generic) | **alt** | **graded** — empty verdict (not `-12`) |
| **our A16 build** | **alt** | **`-12`** |
| our A16 build (DUT `c39a6acf`) | primary **and** alt | `-12` (both) |
| our A16 build (Gold `81eed371`) | primary | `-12` (on GREEN **and** YELLOW boot) |

Read the two controlled comparisons:

- **Same device (Silver) + same account (alt), only the OS changes:** A11 GSI → *graded*;
  our A16 → **`-12`**. ⇒ the discriminator is **the OS/build**, not the device or the account.
- **Our A16 build is `-12` everywhere** — every account, every device, both boot states,
  both fingerprint variants. Robustly, uniquely ours.

So "any non-factory OS 500s" is **false** (the GSI is a non-factory OS and it grades). The
thing that 500s is specifically **our Android-16 build presenting a PVG100 identity** — a
2018 model at an OS version it was never certified for. The most economical mechanism:
Google's integrity backend has grading data for the generic GSI target (`aosp_arm64`-style)
and for the certified factory PVG100, but **no grading path for "PVG100 × Android 16,"** so
it errors (HTTP 500) instead of returning a graded-but-failing verdict.

## Everything else, ruled out by experiment (not argument)

| Suspect | How it died |
|---|---|
| **Account** | Same alt account: *graded* the A11 GSI, `-12` on our A16 (2026-07-26/27). |
| **Physical device / factory provisioning** | Silver is the genuine factory unit and still `-12` with our A16 build (2026-07-27). |
| **Boot state (RootOfTrust)** | `-12` on GREEN (DUT/Silver) *and* YELLOW (Gold) — see attestation table. |
| **Fingerprint string** | Both the stock-8.1 `BuildFingerprint` spoof **and** the honest A16 fingerprint → `-12`. |
| **DroidGuard broken** | Runs every time, returns 15–37 KB payloads. |
| **Attestation generation** | "Integrity key attestation record generated successfully" every run. |
| **Checkin broken** | Clean `SentRequest` → `ReceivedResponse`. |
| **Device-descriptor incoherence** | Flashed a coherent build → byte-identical 500. |
| **Broken instrument** | Third-party checker (real cloud project #) also `-12`; and the Play self-test returns STRONG on Silver. |
| **Poisoned device record** | DUT1 is wiped multiple times a day (regenerates GSF ID) — survives every wipe. |
| **Expired Google attestation root** (`notAfter 2026-05-24`) | Silver shares the same root and returns STRONG today → validator pins the key, ignores expiry. |

## Why it's unfixable from the ROM

The only two things that would move it are both out of reach:

1. **Lower the real Android API level** so the backend has a grading path — but `sdk=27` on
   the API-36 framework **bootloops** (system_server can't run backwards-SDK; hail-mary #1,
   2026-07-24). The *real* version can't be lowered; only lied about, and lying via the
   fingerprint doesn't reach the API level checkin actually reports.
2. **Get the (model × version) certified** — an exact-match OEM CTS submission that will
   never exist for an Android-16 PVG100 (see "four identities" below).

Prop/fingerprint spoofing is proven inert (the 8.1 override still `-12`'d), and keybox
forgery is out of scope (Kyle's instruction), needs root, and gets revoked. **No experiment
remains on our side.**

## The symptom

Play Integrity error **`-12` = `GOOGLE_SERVER_UNAVAILABLE`**
(https://developer.android.com/google/play/integrity/error-codes — documented *transient/
retryable*; ours is 100% reproducible). **It is NOT a failing verdict:** a device that fails
integrity still gets a token with an empty `deviceRecognitionVerdict`. `-12` means no token
was minted — **we are never graded.** Underneath, a literal HTTP 500:

```
E Volley : Unexpected response code 500 for https://play-fe.googleapis.com/fdfe/integrity
E Finsky : requestIntegrityToken() failed for com.android.vending.
E Finsky : Caused by: DisplayErrorMessage[Error retrieving information from server. DF-DFERH-01]
```

Client side is **completely healthy** every run: DroidGuard executes and returns 15–37 KB
payloads, attestation record generates, checkin `SentRequest` → `ReceivedResponse` clean.

## The witness: stock returns full marks

Silver (`4373dd0f`, factory 8.1, same silicon/TEE/attestation batch keys), 2026-07-23:
`[MEETS_BASIC_INTEGRITY, MEETS_DEVICE_INTEGRITY, MEETS_STRONG_INTEGRITY]`
(screenshot `attestations/silver-integrity-20260723-1431.png`). Killed two assumptions:
STRONG does **not** need a recent patch (this TEE reports 2020-09), and the Play Store's
built-in dev-options check is a **valid instrument** (works on a certified device).

## Attestation ground truth (`attestations/`, `parse-attestation.py`)

| Device | Build | verifiedBootState | verifiedBootKey | osVersion | osPatchLevel |
|---|---|---|---|---|---|
| Silver `4373dd0f` | stock 8.1 | GREEN Verified | `029424f8…` | 8.1.0 | 2020-09 |
| DUT `c39a6acf` | our A16 | GREEN Verified | `029424f8…` (= stock!) | 8.1.0 | 2020-09 |
| Gold `81eed371` | our A16 | YELLOW SelfSigned | `5e925481…` | 8.1.0 | 2020-09 |

All: `attestationVersion=2`, `keymasterVersion=3`, `securityLevel=TrustedEnvironment`,
root `f92009e853b6b045`.

⭐ **The TEE certificate binds to the boot chain + hardware, NOT to the OS build.** Two
durable proofs, straight from the parsed certs:

- **Different OS, identical cert:** stock 8.1 and our A16 on `c39a6acf` produce the *same*
  `verifiedBootKey` and both attest `osVersion 8.1.0 / 2020-09`. The TEE never reads
  `/system`, the fingerprint, `ro.build.type`, or apps — so the entire Android OS is
  swappable and invisible to attestation. `osVersion`/`osPatchLevel` are bootloader/TA-latched
  (anti-rollback), **not** from `ro.build.version.*` (the A11 GSI also reported 8.1). This
  killed the last-ditch "version-skew" hypothesis and the false premise behind the coherence
  experiment.
- **Same OS, different cert:** the identical A16 build attests GREEN + stock-OEM key on
  `c39a6acf` but YELLOW + self-signed key on `81eed371`. So the cert binds to *per-device
  verified-boot state* (which key signed boot, lock state), which is exactly the STRONG
  ceiling — a custom key is truthfully reported as self-signed and can't be forged to
  Google's. Relevant to [[boot-signing-own-key]], not to `-12` (both `-12`).

⚠️ `parse-attestation.py`'s header comment is **wrong** on two counts (claims a custom ROM
can only reach YELLOW; claims Google "errors on yellow"). Fix when convenient.

## The device declares FOUR incompatible identities

Checkin sends far more than the fingerprint: `sdkVersion`, `securityPatch`, full
`availableFeatures[]` (108) and `sharedLibraries[]` (27), GMS/GL version, density:

| Claim | Evidence |
|---|---|
| 2017 Palm PVG100 on Android 8.1 | the (now-removed) `BuildFingerprint` override |
| Android 16 device | `sdkVersion=36`, `mainline.patchlevel.2`, `android.software.{credentials,device_lock,…}` |
| A LineageOS build | `org.lineageos.{android,health,hardware,livedisplay,profiles,settings,trust,…}` |
| A Google Pixel | `PIXEL_2017_EXPERIENCE`, `GOOGLE_BUILD`, `ADAPTIVE_CHARGING`, `QUICK_TAP`, `DREAMLINER` (= NikGapps sysconfig) |

This is why fingerprint editing can never buy certification: a certified match means making
the *whole* declaration identical to a real certified build — i.e. shipping that build.
⚠️ Don't blame the Pixel features for the 500 either; every NikGapps ROM declares them and
still gets *graded*.

## Outcome: honest props shipped (the useful thing that came out of this lane)

Two build changes, committed and flash-validated, orthogonal to integrity but worth keeping:

- **Honest A16 fingerprint** — the stock-8.1 `BuildFingerprint`/`BuildDesc` spoof (and the
  hail-mary full-A8 mimic) were **removed** from `device/xiaomi/Mi8937/lineage_Mi8937.mk`.
  Result on integrity: neutral (`-12` either way); on certification: neutral
  (`uncertified_status | 1` either way). Kept on honesty grounds.
- **De-Xiaomi'd device identity** — `libinit/init_xiaomi_mi8937.cpp` now rewrites the pepito
  runtime fingerprint from the *live* one at boot, swapping the build codename tokens
  (`lineage_Mi8937[_gapps]` → `PVG100`, `Mi8937` → `pepito`) and setting `ro.product.name`,
  so all props read `Palm/PVG100/pepito:16/…` instead of leaking the Mi8937-common codename.
  Every dynamic field (version/id/incremental/patch) stays truthful; no `PRODUCT_DEVICE`/
  output-path change. pepito-gated; no-op guard so it can't wedge boot.
- **Real build incremental** — `scripts/build-lineage23.sh` exports `BUILD_NUMBER` (UTC date)
  so the fingerprint reads `…/20260727:userdebug/…` instead of `eng.$USER`.

Flash-validated 2026-07-27 on `c39a6acf`: all 8 partition fingerprints coherent as
`Palm/PVG100/pepito:16/BP4A.251205.006/20260727:userdebug/release-keys`.

## Signals already in good shape (verified on DUT)

`ro.debuggable=0`, `ro.secure=1`, `ro.adb.secure=1`, SELinux **Enforcing**, no `su`/Magisk/
Zygisk, `veritymode=enforcing`, `verifiedbootstate=green`, `ro.build.tags=release-keys`.
Nothing here needs fixing. (`ro.debuggable=0` on a userdebug build is LineageOS behaviour —
root-adb is gated on a compile-time flag via `adbroot_service`, hence the "Rooted debugging"
toggle.)

## The `user`-build lever — NOT worth it

Proposed to drop the `ro.build.type=userdebug` signal; useless since we never reach a verdict.
Costs: rooted debugging gone permanently; **debugfs not mounted on user builds** → loses
`/d/ipc_logging/kqmi_req_resp` (modem goldmine) and `/d/msm_subsys`; three `userdebug_or_eng()`
sepolicy blocks drop out (`mithorium-common/sepolicy/vendor/{rmt_storage,logd,incidentd}.te` —
`rmt_storage` is in the telephony chain). And LineageOS ships `userdebug` officially, so it's
the honest/expected posture anyway. Don't fake it via `ro.build.type=user` either.

## If the lane is ever reopened

Only with a genuinely new idea. Would qualify:
- A way to make checkin report a lower *real* Android version without bootlooping (the one
  untested lever behind the (model × version) theory).
- Evidence of the same `-12` on another obscure/uncertified model running a brand-new OS
  version — would confirm the "backend has no grading path for this (model × version)" read.

Would **not** qualify: more prop/fingerprint spoofing (proven inert), or keybox forgery
(out of scope).

## Method notes worth keeping

- `-12` vs graded is unambiguous in logcat: `-12` = the Volley 500 / `DF-DFERH-01` above; a
  graded-but-failing request is a clean 200 with an empty `deviceRecognitionVerdict`. Don't
  trust the checker UI — read the log.
- Capture `adb logcat -b all -v threadtime`; clear with **`adb logcat -b all -c`** (plain
  `-c` leaves `events` stale). `adb root`/any adbd restart **kills an in-flight logcat** — do
  root toggles first.
- `pm clear com.android.vending` does **not** log you out of Play (account lives in GMS).
- Cert status, with root:
  `sqlite3 /data/data/com.google.android.gms/databases/gservices.db "select name,value from main where name like '%certif%';"`
  → `uncertified_status | 1` (~24 h cached flag, refreshed at checkin).
- ⚠️ Removing the *last* Google account on the A11 GSI **bootloops** it (userspace loop;
  `/data` is FDE so no recovery-side forensics) → factory-reset to recover. For account tests
  use fresh-setup-with-only-that-account, never remove-the-account.
- The scary `/system/xbin/.suv`-style paths in `gservices.db` are Google's known-malware path
  list pushed to all devices — **not** findings on the phone.
