# PLAN-integrity — Google Play Integrity on pepito

**Goal:** `MEETS_BASIC_INTEGRITY`, nothing more. Explicitly **not** chasing STRONG, and
**not** touching keyboxes / TrickyStore / attestation forgery.

**Status 2026-07-23: CLOSED — server-side, model-specific, unfixable from the ROM.**
The `-12` is a Google-backend HTTP 500, and the **A11 GSI got it too** — so it is
independent of our entire software stack (attestation, props, keys, HALs all ruled out
experimentally). On this hardware, ONLY the exact factory A8.1 software passes; every
non-factory OS (GSI, our A16, GREEN or YELLOW attestation) 500s. Since ordinary uncertified
custom ROMs get *graded* (empty verdict, not a 500), the coherent read is that Google's
integrity backend has no graceful path for the obscure Palm PVG100 model when it isn't
running its one certified factory config, and 500s instead. Untestable and unfixable — the
thing that would need to change is in Google's infrastructure, not on the device. **Do not
reopen without a genuinely new idea; there is no experiment left on our side.**

### ⭐ The decisive experiment (why we can be confident it's not our build)

| Config on this hardware | Software stack | Result |
|---|---|---|
| Silver `4373dd0f` | **factory A8.1** (the certified config) | `[BASIC, DEVICE, STRONG]` |
| A11 GSI (historical) | stock vendor + AOSP GSI | **-12** |
| DUT `c39a6acf` A16 | LineageOS, GREEN attestation | **-12** |
| Gold `81eed371` A16 | LineageOS, YELLOW attestation | **-12** |

The GSI shares almost nothing with our build yet fails identically → the fault is NOT in our
ROM. The GREEN-vs-YELLOW rows → NOT the attestation content. Only factory-vs-non-factory
separates pass from fail, and that separation lives server-side.

### On the TEE osVersion (corrected — it is NOT a distinctive suspect)

Earlier this was floated as the last surviving hypothesis (TEE attests `osVersion=8.1.0 /
2020-09` while running A16). **Retracted.** On this hardware those values are supplied by the
bootloader/TZ and latched (anti-rollback), NOT sourced from `ro.build.version.*` — proven
two ways: (a) the DUT's live `security_patch` prop is 2026-05 while the TEE attests 202009,
so they already diverge; (b) the **A11 GSI also reported 8.1** in attestation — same frozen
value across a totally different OS. Version skew is therefore common (any device whose
bootloader doesn't feed current values), and such devices still get *graded*, so skew cannot
be what triggers the 500. It failed the same "not actually distinctive" test as every other
suspect.

---

## The symptom

Every build, both devices, both instruments returns Play Integrity error
**`-12` = `GOOGLE_SERVER_UNAVAILABLE`**
(official table: https://developer.android.com/google/play/integrity/error-codes —
documented as *transient, retryable*; ours is 100% reproducible).

**`-12` is NOT a failing verdict.** A device that fails integrity still gets a successful
token with an empty `deviceRecognitionVerdict`. `-12` means no token was minted. **We have
never been graded.** Underneath it is a literal HTTP 500 from Google:

```
E Volley : Unexpected response code 500 for https://play-fe.googleapis.com/fdfe/integrity
E Finsky : requestIntegrityToken() failed for com.android.vending.
E Finsky : Caused by: DisplayErrorMessage[Error retrieving information from server. DF-DFERH-01]
```

The client side is **completely healthy** every single run: DroidGuard executes and returns
15–37 KB payloads, `Integrity key attestation record generated successfully`, checkin
`SentRequest` → `ReceivedResponse` clean.

## The witness: stock returns full marks, TODAY

Silver (`4373dd0f`, factory 8.1, same silicon, same TEE, same attestation batch keys),
tested **2026-07-23**:

```
[MEETS_BASIC_INTEGRITY, MEETS_DEVICE_INTEGRITY, MEETS_STRONG_INTEGRITY]
```

Screenshot: `attestations/silver-integrity-20260723-1431.png`.

So the hardware, the TEE, the attestation chain, Google's backend, and the Play Store's
built-in checker **all work on this silicon**. The entire delta is our software/device
state.

Two assumptions this killed:
- STRONG does **not** require a security patch within ~12 months (this TEE reports 2020-09).
- The Play Store's built-in developer-options check is a **valid instrument** — it works fine
  on a certified device.

## Eliminated hypotheses — 2026-07-23 session

Every one of these was tested, not argued:

| # | Hypothesis | How it died |
|---|---|---|
| 1 | DroidGuard broken / not executing | Runs fine, returns 15–37 KB payloads |
| 2 | Attestation generation failing | "generated successfully" on every run |
| 3 | Checkin broken | Clean `SentRequest` → `ReceivedResponse` |
| 4 | Device-descriptor incoherence (8.1 fingerprint vs SDK 36) | **Flashed a coherent build** → byte-identical 500 |
| 5 | RootOfTrust / verified boot state | `-12` on **GREEN** (DUT) *and* **YELLOW** (Gold) |
| 6 | Broken instrument (Play Store self-test path) | Third-party checker with a real cloud project number **also** `-12`; and the self-test works on Silver |
| 7 | Poisoned server-side device record | DUT1 is wiped multiple times a day, regenerating the GSF ID — survives every wipe |
| 8 | Expired Google attestation root (`notAfter = 2026-05-24`, 2 months ago) | Silver shares the **same root** and returns STRONG today → validator pins the key, ignores expiry |

## Attestation ground truth (`attestations/`, `parse-attestation.py`)

| Device | Build | verifiedBootState | verifiedBootKey | osVersion | osPatchLevel |
|---|---|---|---|---|---|
| Silver `4373dd0f` | stock 8.1 | GREEN Verified | `029424f8…` | 8.1.0 | 2020-09 |
| DUT `c39a6acf` | our A16 | GREEN Verified | `029424f8…` (= stock!) | 8.1.0 | 2020-09 |
| Gold `81eed371` | our A16 | YELLOW SelfSigned | `5e925481…` | 8.1.0 | 2020-09 |

All: `attestationVersion=2`, `keymasterVersion=3`, `securityLevel=TrustedEnvironment`,
root `f92009e853b6b045`.

Two durable facts here:

- ⭐ **`osVersion`/`osPatchLevel` are NOT taken from Android props.** They read 8.1.0 /
  2020-09 on *every* device including our A16 builds. On this KM3 TA they come from the
  bootloader / are latched in the TA — the frozen LK aboot supplies stock values and no ROM
  change moves them. (The earlier belief that keystore fills these from
  `ro.build.version.release` / `security_patch` is **wrong on this device**, and it was the
  false premise behind experiment #4.)
- ⭐ **The two DUTs disagree on RootOfTrust despite running the same build**: `c39a6acf`
  presents the *stock Palm OEM key hash* + GREEN + locked (indistinguishable from factory),
  while `81eed371` presents an honest self-signed YELLOW. Worth understanding on its own
  merits — see [[boot-signing-own-key]] — but it is **not** the integrity blocker (both
  `-12`).

⚠️ The header comment in `parse-attestation.py` is **wrong** on two counts (claims a custom
ROM can only reach YELLOW; claims Google "rejects/errors on yellow"). Fix it when convenient.

## What is left, and why the lane is closed

The only variable that has tracked the outcome perfectly is **Play Protect certification**:

- Silver — certified → full verdicts.
- DUT + Gold — uncertified → 500 / `-12`, under every configuration tested.

And certification is unattainable here, for a structural reason no amount of work fixes:
it is an exact-match lookup against an OEM-submitted CTS record, and **there will never be
an Android 16 PVG100 record**. See the four-identities section below.

This is a correlation, not a proven mechanism — and after eight falsified hypotheses in one
session it deserves no more confidence than that. But it is untestable *by construction*
(we cannot make the device certified), so there is no experiment left to run. **Recommend
closing the lane.** BASIC appears unreachable on this device.

## The device declares FOUR incompatible identities

Checkin sends far more than the fingerprint: `sdkVersion`, `securityPatch`, the full
`availableFeatures[]` (108) and `sharedLibraries[]` (27), GMS version, GL version, density.
They tell four different stories at once:

| Claim | Evidence |
|---|---|
| 2017 Palm PVG100 on Android 8.1 | the (now-disabled) `BuildFingerprint` override |
| Android 16 device | `sdkVersion=36`, `mainline.patchlevel.2`, `android.software.{credentials,device_lock,ipsec_tunnel_migration}` |
| A LineageOS build | `org.lineageos.{android,health,hardware,livedisplay,profiles,settings,trust,globalactions}` |
| A Google Pixel | `PIXEL_2017_EXPERIENCE`, `PIXEL_EXPERIENCE`, `GOOGLE_BUILD`, `ADAPTIVE_CHARGING`, `QUICK_TAP`, `DREAMLINER` |

The Pixel row is **NikGapps**: `/product/etc/sysconfig/pixel_experience_2017.xml` +
`adaptivecharging.xml`, `quick_tap.xml`, `dreamliner.xml`, `nexus.xml`, `google_build.xml`.

This is why fingerprint editing can never buy certification: matching a certified record
means making the *whole* declaration identical to a real certified build — i.e. shipping
that build. ⚠️ Do **not** blame the Pixel features for the 500 either; every NikGapps ROM
declares them and still gets graded.

## Open decision: the staged `.mk` change

`device/xiaomi/Mi8937/lineage_Mi8937.mk` — the `BuildDesc`/`BuildFingerprint` override is
currently **commented out** (flashed and validated as build H1). Result: **neutral**. No
integrity gain (still `-12`), no certification loss (`gservices.db` →
`uncertified_status | 1` both ways).

Decide on non-integrity grounds:
- **Keep disabled** — honest fingerprint, and it no longer misrepresents the OS version.
- **Revert** — uncomment the two lines; restores the previous behaviour exactly.

⚠️ **Verify Android Auto on the car before deciding.** Kyle's stated priority is
**working AA > BASIC integrity**. Per `PLAN.md` the AA fix was the preinstalled
Google-signed stub ("no cert/GSF needed"), so this should be inert — but confirm.

## If the lane is ever reopened

Only with a genuinely new idea. Things that would qualify:
- Evidence from another frozen-bootloader device family (TEE attesting an OS version many
  releases behind the running one) showing the same `-12` — would promote the last
  untested structural difference to a real hypothesis.
- A way to make the KM3 TA report a current `osVersion`/`osPatchLevel`.

Things that would **not** qualify: more prop spoofing, more fingerprint permutations, or
keybox forgery (out of scope by Kyle's instruction, needs root, and gets revoked).

## Signals already in good shape (verified on DUT)

`ro.debuggable=0`, `ro.secure=1`, `ro.adb.secure=1`, SELinux **Enforcing**, no `su` /
Magisk / Zygisk, `veritymode=enforcing`, `verifiedbootstate=green`,
`ro.build.tags=release-keys`. Nothing here needs fixing.

Note `ro.debuggable=0` on a userdebug build is LineageOS behaviour: root-adb is gated on
`adbroot_service`, whose `isSupported()` is `ANDROID_DEBUGGABLE || __android_log_is_debuggable()`
(`packages/modules/adb/root/adbroot_service.cpp:109`) — a **compile-time** flag. Hence the
"Rooted debugging" toggle.

## The `user`-build lever — NOT worth it

Was proposed as a way to remove the `ro.build.type=userdebug` signal. Since we never reach a
verdict at all, it cannot help. Costs, for the record:
- **Rooted debugging disappears permanently** (`ANDROID_DEBUGGABLE=0`).
- **debugfs is not mounted on user builds** → loses `/d/ipc_logging/kqmi_req_resp` (the modem
  debug goldmine) and `/d/msm_subsys`.
- **Three `userdebug_or_eng()` sepolicy blocks drop out**:
  `mithorium-common/sepolicy/vendor/{rmt_storage,logd,incidentd}.te` — `rmt_storage` sits in
  the telephony chain.

Do not fake it via `ro.build.type=user` on a userdebug build: `ro.build.flavor` would still
say userdebug, debugfs would still be mounted, debug binaries would still ship.

## Method notes worth keeping

- Capture with `adb logcat -b all -v threadtime`; clear with **`adb logcat -b all -c`** —
  plain `logcat -c` leaves the `events` buffer full of stale entries.
- `adb root` / any adbd restart **kills an in-flight logcat capture**. Do root toggles first.
- `pm clear com.android.vending` does **not** log you out of Play — the account lives in
  GMS/AccountManager. It does correctly drop the cached device profile.
- Certification status, with root:
  `sqlite3 /data/data/com.google.android.gms/databases/gservices.db "select name,value from main where name like '%certif%';"`
  → `uncertified_status | 1`. It is a ~24 h cached flag refreshed at checkin.
- That scary list of `/system/xbin/.suv`-style paths in `gservices.db` is Google's
  known-malware path list pushed to all devices — **not** findings on the phone.
