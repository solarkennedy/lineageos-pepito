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

> ⏸️ **PAUSED 2026-11-04 (Kyle).** State when paused: graded `[]` on every cell below (8 PIF
> cells + 2 prop builds). Mi8937 `c59a377c` + `7f6afdc5` (system-wide stock 8.1 identity)
> REVERTED 2026-11-04 (`8570516a`, `506530ba`; re-apply with `git revert` of those to retry). Still in the tree: frameworks/base
> `3f0cda8daad6` + `f3eb992bb125` (PIF hooks, inert unless `spoof_pif_config` set — safe to
> keep). Unrun next steps, in order: our 23.2/A16 release on dut1; ask Zach his exact recipe +
> build type; attestation hide in Play Store too; fresh GSF ID (wipe). Native-prop hook judged
> low value (only `security_patch` still differs natively). PlayIntegrityFork's A17 JNI
> `SetStaticObjectField` route would `LOG(FATAL)` on our ART with GMS targetSdk=37 (by source
> reading, untested); our Unsafe path works.
>
> **Zach's Key2 recipe, read from source 2026-11-04** (github.com/Lineage-BBKey2): LOS 22.2
> (A15, branch `lineage-22.2-kernel-4.19`) and 23.2; **userdebug** (release notes tell users to
> `adb root`); device-tree `PRODUCT_BUILD_PROP_OVERRIDES` BuildFingerprint/BuildDesc = stock
> 8.1 ("need to keep old FPs from oreo for play certification") + DeviceProduct/DeviceName;
> `PRODUCT_SHIPPING_API_LEVEL := 27`. frameworks/base fork = keyboard/backlight/IME/SystemUI
> only, **no integrity spoof** (23.2 branch is 0 commits ahead of upstream). ⇒ userdebug +
> root-adb + 8.1 fingerprint gets BASIC on A15/A16. Every one of those we matched → `[]`. The
> difference left is the Android version (A17 vs A15/16) or the device/hardware → test our
> final 23.2 (A16) release on dut1 next.
>
> **⭐ Boot-signing lead (2026-11-04):** Zach's Key2 users UNLOCK the bootloader (`kibo unlock`,
> MODE PRODUCT→FACTORY; relock optional per the guide) and flash unsigned boot — the TEE
> honestly attests unlocked/unverified, and he gets BASIC. Ours graft the stock signature:
> new2 `verifiedbootstate=green`, `flash.locked=1`, and the July attestation = GREEN + locked +
> Palm's own verifiedBootKey + osVersion 8.1/2020-09 — a "sealed stock" cert on an A17 OS,
> which may read as tampering. Fits every row of the July table (stock untouched → full; stock
> rooted / all our builds → empty). Cells C–H did NOT test it: Play Store does its own key
> attestation, unhidden. Next (on dut1, not new2): (1) boot signed with our OWN RSA-2048 key →
> honest YELLOW (Gold-style; July only ever saw -12 on it) — ⚠️ ROT change may invalidate
> keymaster keys (memory `boot-signing-own-key`); (2) attestation hide in Play Store too.
>
> **(1) STAGED 2026-11-04, unflashed:** `~/android/lineage-24/flash-staging/held-yellow-ownkey-20261102-gapps/`
> = release-20261102-gapps with only boot.bin re-signed by our July boot key
> (`~/Projects/aboot-re-e3/sign-boot-with-key.py`, fp `0A:BA:BC:AE:…:5C:77`; emulator → YELLOW).
> Zach's builds have no attestation hiding either (no keystore/security/ActivityThread changes
> in his frameworks/base; no system/security fork). Flash: `FLASH_DIR=… flash-staging.sh dut1 --wipe`.
>
> **🎉 RESULT 2026-11-04 10:10 + 10:12: dut1 (`c39a6acf`), held-yellow-ownkey-20261102-gapps,
> `--wipe`, fresh account, stock GMS 26.11.36 → `Labels: [MEETS_BASIC_INTEGRITY]` (twice).**
> `ro.boot.verifiedbootstate=yellow`, `ro.boot.flash.locked` EMPTY (graft reports 1). Honest
> fingerprint, no PIF, no prop spoof. ⚠️ Confounded with: different unit (dut1 vs new2), fresh
> wipe → new GSF ID, old bundled GMS. Control needed: same dut1 back on the grafted
> release-20261102-gapps + `--wipe` + same account → if `[]`, the boot signature is the cause.
>
> **❌ CONTROL 2026-11-04 11:44: the boot signature is NOT the cause.** dut1, gapps 20261104
> (frameworks/base `585e149dd567` hooks inert, no `spoof_pif_config`, honest fingerprint),
> grafted GREEN boot, `--wipe`, same account, bundled GMS 26.11.36 / Play Store 47.9.30 →
> **`[MEETS_BASIC_INTEGRITY]`**. (Correction: `ro.boot.flash.locked` is empty on GREEN too —
> new2's `1` came from the reverted libinit spoof.) Graft and own-key both pass on a fresh dut1.
> What new2 (`[]`) has that dut1 doesn't: updated GMS 26.43.30 + Play Store 53.8.11, a long-lived
> device record (not wiped since Sept, months of -12), different unit. Next: re-check dut1 after
> GMS/Play Store self-update (→ `[]` = version-driven; stays BASIC = new2's record/unit).
>
> **new2 2026-11-04 12:24–12:25, reflashed to the same 20261104 build dut1 passed on (no wipe):**
> control (nothing set) → `[]`; cell I (honest identity + attestation hidden in DroidGuard AND
> Play Store — `Finsky: Integrity key attestation record generation failed`) → `[]`. ⇒ the
> build and the attestation are not it; new2's `/data` side is: GMS 26.43.30 / Play Store
> 53.8.11 vs dut1's bundled 26.11.36 / 47.9.30, or new2's device record (unwiped since Sept),
> or the unit.
>
> **new2 12:30, rooted debugging fully OFF** (`persist.vendor.xiaomi.adbroot` 0 — the opt-in
> root-at-boot switch in `init.xiaomi.device.rc` — `/data/adbroot/enabled` 0, rebooted, adbd
> uid 2000, `adb root` refused) → still `[]`. Rooted debugging is not the new2/dut1 difference.
>
> **dut1 2026-11-05 05:23, after GMS/Play Store self-updated to new2's exact versions (26.43.30 /
> 53.8.11), alt account, green graft, no config → still `[MEETS_BASIC_INTEGRITY]`.** ⇒ GMS
> version is NOT it. A fresh install of the current build passes on current GMS. What's left on
> new2: its device record / GSF ID and GMS state (not reset since Sept; months of -12), or the unit.
> Non-destructive-ish next: clear Google Services Framework data on new2 (new GSF android_id →
> new device record) — side effects on a daily phone (push re-registration), ask first.
>
> **new2 2026-11-05, each still `[]`:** `pm clear com.google.android.gsf` (fresh GSF ID; checkin
> SUCCESS) → `[]`; no root leftovers (`/data/adb` empty, no su, no Magisk/KSU/APatch/LSPosed
> packages, only our own overlay mounts); `pm clear com.google.android.gms` → `[]`. User apps:
> 31 ordinary daily apps on new2, none root/hooking tools. Ruled out on new2 so far: build,
> identity, boot signature, attestation, rooted debugging, GMS/Play Store version, GSF ID, GMS
> state, root leftovers. Left: the unit's hardware identity (serial/IMEI/attestation key — Google
> may have flagged it during the -12 months), other /data state, or the second account.
>
> ⚠️ Correction: the GSF/GMS-clear and rooted-debugging-off runs had attestation VISIBLE (pif
> config is cleared after each sweep cell). The combination was then run explicitly — cell I
> (attestation hidden in DroidGuard + Play Store, `Integrity key attestation record generation
> failed`) on the post-GSF/GMS-clear new2, 2026-11-05 05:59 → still `[]`. (05:57 attempt was a
> `-3` network error from a Wi-Fi reconnect; the check script now reports error dialogs.)
>
> **DroidGuard path trace, 2026-11-05** (`diag-tools/play-integrity/dg-pathtrace.sh`: kretprobe on
> `getname_flags`, raw-word fetch of `struct filename` iname — the kernel's `:string` fetch faults;
> no ptrace, so DroidGuard can't see it: dut1 still **BASIC under trace**). Fresh DroidGuard on
> both units: 145 (dut1) vs 154 (new2) probe-like paths, the same root sweep (`/sbin/su`,
> `/system/xbin/su`, `/data/local/tmp/su`, `/proc/self/{maps,mounts,status}`, selinux, …).
> new2-only lookups all benign: `/sys/class/net/` (no VPN up; same interfaces), `/system/etc/hosts`
> (identical sha), `cacerts-removed/*` (empty dir — conscrypt's per-cert check), cpufreq/cpuinfo.
> ⇒ DroidGuard's file-level view of the two phones is equivalent. Property reads (mmap of
> `/dev/__properties__`) and in-memory checks are invisible to this. Remaining suspect: something
> server-side keyed on new2's hardware identity (serial / IMEI / attestation key).

> **dut1 spoof matrix 2026-11-05 16:38–16:44 UTC** (every earlier spoof cell ran on new2 only,
> so they were never tested on a unit that can pass). dut1 `c39a6acf`, gapps 20261104, grafted
> GREEN (TEE cert = stock-identical GREEN/locked/Palm key/8.1.0/2020-09), alt account, GMS
> 26.43.30: control → BASIC; **J** (new: stock 8.1 identity in DroidGuard + Play Store SDK 32,
> attestation VISIBLE) → BASIC; A, B, G → BASIC. All spoofs confirmed live (`PIF/Java:DG` fields,
> `PIF/Java:PS: [SDK_INT]: 37 -> 32`, attestation record generated). ⇒ Java-level spoofs neither
> hurt nor buy DEVICE on a passing unit. Untried on dut1: the system-wide libinit 8.1 identity
> (revert `8570516a` + `506530ba`; needs a build) under J, and native props in DroidGuard
> (`ro.build.version.*` still 17/37/2026-10 natively; PlayIntegrityFork says DEVICE needs
> spoofProps).
>
> **Result 2026-11-05 17:27–17:30 UTC, dut1 gapps 20261105 (Mi8937 `76e7ba5a`, system-wide stock
> 8.1 fingerprint/device/build id/type, `Device: Pepito`), grafted GREEN, no wipe:** control →
> BASIC; J (+ DroidGuard Java 8.1 fields, Play Store SDK 32 confirmed, attestation visible) →
> BASIC; B → BASIC. ⇒ the 8.1 identity (props + Java) is inert on a passing unit too. Left:
> native `ro.build.version.*` in DroidGuard (lever 2).
>
> **Lever 2 built 2026-11-05: native prop spoofing in DroidGuard, the SELinux-clean way.**
> ShadowHook (PIF's inline hook of `__system_property_read_callback`) is a dead end for us:
> DroidGuard runs in the `gmscore_app` app domain, enforcing, and an inline hook needs
> `execmod` (patch libc .text in place), which has a CTS neverallow and no grant — PIF only
> gets away with it from Magisk's privileged context. (`execmem` for trampolines IS granted to
> app domains, so that part was a red herring.) ShadowHook 2.0.1 itself works on A17; the A17
> breakage reports are Zygisk-injection problems, which we sidestep by injecting from the
> framework. But the execmod wall is real. Chose instead a **process-local override in bionic**:
> no inline hook, no execmod, no `mprotect`, libc-on-disk == libc-in-memory.
>  - **bionic fork** `solarkennedy/android_bionic` `pepito-24` (`27c7bb28c5`, in manifest): a
>    per-process table in libc, empty until populated via `__system_property_override_add`
>    (LIBC_PLATFORM); `SystemProperties::Read`/`ReadCallback` return the override for a matching
>    name. Nothing hits the shared `__properties__` area (invisible to other processes and to
>    getprop; keystore OS patch level untouched). bionic IS built from source here, so it takes
>    effect. (Note: bionic already has an unrelated appcompat override — `EnableOverrides`,
>    prefix-based, global-area — not reused; ours is truly process-local.)
>  - **libpifprop** (`frameworks/base/pif/jni`, shipped via Mi8937 `e2572517`): JNI bridge to
>    those setters, `System.loadLibrary` from the ActivityThread bind hook in DroidGuard only.
>  - **frameworks/base** `3a928828747d`: wires the inert `spoofProps` key — dotted config keys
>    (`ro.build.version.*`) become native overrides in DroidGuard; `spoofProps(processName)` is
>    gated on `isDroidGuard` + `spoofProps=1`.
>  - **config K** (`k-stock81-nativeprops.json`) = J + the 5 native props still real on the
>    libinit-8.1 build: `ro.build.version.{release,release_or_codename,sdk,security_patch,incremental}`
>    → 8.1. Symbol export verified in the apex libc (`__system_property_override_add@@LIBC_PLATFORM`).
> Test = gapps build (picks up all four forks) → dut1 → control, then `pif.sh dut1 cell configs/k-…`.
> ⚠️ Expected payoff is DEVICE on top of BASIC, and may still fail without a keybox (out of scope);
> may also perturb DroidGuard (it reads sdk=27 of itself). Test-only stack; revert `844118a7`,
> `76e7ba5a` (identity) before release; the bionic/libpifprop/spoofProps plumbing is inert when
> unconfigured and safe to keep.
>
> **Staged 2026-11-05: lever 1 on dut1.** Mi8937 `844118a7` + `76e7ba5a` (pushed, unbuilt) re-apply
> the system-wide stock 8.1 identity (`c59a377c` + `7f6afdc5`). **Test-only: revert both before a
> release.** Test = gapps build → dut1 (no wipe) → control, then `pif.sh dut1 cell configs/j-…`.
>
> 🆕 **2026-11-03: `-12` IS GONE — we are now GRADED (empty verdict).** new2 (`9c2e6b00`,
> 24.0 gapps `20261102`, primary account), Play Store → Settings → General → Developer
> options → Check integrity: **`Labels: []`** with a TestId, log shows a clean
> `requestIntegrityToken() finished` (no Volley 500 / `DF-DFERH-01`). Nothing changed on
> our side. Independent report the same week (XDA, zjays/Zach, BlackBerry Key2/Key2LE on
> LOS 22.2/23.2 with an 8.1 fingerprint spoof): `-12` stopped by 2026-10-31 and he now gets
> **BASIC**. So the 500 was a Google backend fault that Google fixed, and it hit more than
> (PVG100 × A16) — the "backend gap for our identity" read below was partly right
> (backend-side) but the trigger wasn't unique to us. **New open question:** why do we get
> `[]`, not even BASIC, when the Key2 builds get BASIC? (He spoofs the stock 8.1
> fingerprint, we ship the honest `Palm/PVG100/pepito:17/…`; he is also on A15/A16, not
> A17.) BASIC is now a real, measurable target again.
>
> **Staged 2026-11-03: fingerprint A/B.** Mi8937 `c59a377c` (pushed, unbuilt): pepito
> libinit reports the stock `Palm/PVG100/Pepito:8.1.0/OPM1.171019.019/v1AML-0:user/release-keys`
> (+ stock `Pepito-user …` description) on every `ro.*build.fingerprint`, after the honest
> identity rewrite; `ro.build.version.*` stay real. Test = gapps build →
> `check-integrity.py <unit>`; compare with the `[]` baseline. **Test-only: revert before a
> release.**
>
> **Result 2026-11-03 17:35 (new2, gapps 20261104 + `c59a377c`): still `Labels: []`.** All
> fingerprint props read the stock v1AML-0 string, SDK still 37; re-run after a forced
> checkin broadcast, also `[]`. Not yet ruled out: a slow server-side refresh of the
> device record (re-check after ~24 h), and `ro.product.device` — ours is `pepito`, stock is
> `Pepito` (the dialog shows `Device: pepito`).
>
> **Staged 2026-11-03: full stock identity.** Mi8937 `7f6afdc5` (on top of `c59a377c`) also
> sets, from a silver-vs-new2 getprop diff: `ro.*build.id` OPM1.171019.019, `ro.*build.type`
> user, `ro.product.*device` + `ro.build.product` `Pepito`, `ro.product.board`
> QC_Reference_Phone, `ro.product.first_api_level` 27 (ours was 25 from the siblings),
> `ro.bootloader` unknown, `ro.boot.flash.locked` 1 (absent on ours), `ro.com.google.gmsversion`
> 8.1_201812. Left real: `ro.build.version.*`, `display.id`, `characteristics`, clientidbase.
>
> **Result 2026-11-03 19:03 (new2, gapps 20261104 + `7f6afdc5`): still `Labels: []`.** All
> props applied (dialog now shows `Device: Pepito`) except `ro.bootloader`, which init
> re-derives from `ro.boot.bootloader` after libinit. ⇒ Build-prop identity is NOT what
> separates us from the Key2's BASIC. Remaining differences: Android 17 vs 15/16 (the real
> `ro.build.version.*`), and whatever DroidGuard measures beyond props. Re-check in ~24 h for
> a slow device-record refresh, then revert `7f6afdc5` + `c59a377c`.
>
> **2026-11-03 19:15: adbd non-root (`adb unroot`, `service.adb.root=0`, no su binary) → still
> `[]`.** A live root adb session is not the flag.
>
> **Staged 2026-11-03: the September PIF graft, ported to 24.0.** frameworks/base
> `3f0cda8daad6` (pushed): `android.security.pif.PlayIntegritySpoofService` +
> `PifKeyStoreProvider` (recovered from the builder's 23.2 tree, untracked) and the
> `ActivityThread.handleBindApplication` hook. Inert unless `Settings.Secure spoof_pif_config`
> is set. In 23.2 (Sept, memory `evolution-x-pif-graft`) four cells — Pixel identity,
> attestation-hide, signature, global Pixel fingerprint — all fired and all hit `-12`, so they
> were never *graded*. Now they can be. Bench: `diag-tools/play-integrity/pif.sh <unit>
> {apply|clear|status|cell|sweep}`, configs in `diag-tools/play-integrity/configs/`:
> A stock-8.1 identity in DroidGuard (incl. RELEASE 8.1.0, patch 2020-09-01, initial SDK 27),
> B = A + SDK_INT 27, C = A + hide attestation, D = B + C. Note the Mi8937 system-wide prop
> experiment (`c59a377c`, `7f6afdc5`) is still in the build underneath.
>
> **⚠️ A17 ART blocks reflective writes to `static final` fields** for apps targeting > B
> (`art/runtime/art_field-inl.h` `IsUnmodifiable`; GMS targets 37) — the first flash logged
> `Cannot set public static final field … Build$VERSION.SECURITY_PATCH`, i.e. PIF-style spoofs
> silently do nothing on A17. Fixed in frameworks/base `f3eb992bb125`: fall back to
> `jdk.internal.misc.Unsafe` (staticFieldBase/Offset + put*Volatile), read back to confirm.
>
> **Cells 2026-11-04 02:03–02:10, new2 (gapps 20261103-20:52 = `f3eb992` + `7f6afdc5`), every
> spoof confirmed live in the DroidGuard log — ALL `Labels: []`:**
>
> | Cell | DroidGuard sees | Result |
> |---|---|---|
> | A | stock 8.1 identity, RELEASE 8.1.0, patch 2020-09-01, initial SDK 27 | `[]` |
> | B | A + SDK_INT 37→27 | `[]` |
> | C | A + HW attestation chain hidden (`Hiding hardware attestation chain for alias 'unstable.…'`) | `[]` |
> | D | B + C | `[]` |
> | E | Sept Pixel 10 Pro XL canary identity + attestation hidden (+ Play Store fingerprint) | `[]` |
> | F | E + Google platform signature for "android" | `[]` |
> | G | C + Play Store SDK_INT 37→32 (`spoofVendingSdk`, PIF's switch to the <A13 verdict rules) | `[]` |
> | H | E + Play Store SDK_INT 32 | `[]` |
>
> Gaps left by these cells: **Play Store (com.android.vending) does its OWN key attestation**
> (`Finsky: Integrity key attestation record generated successfully`, pid = vending) and the
> hook only hides attestation in DroidGuard → needs a vending-side provider hide (code
> change). Java-field spoofs don't reach DroidGuard's native property reads
> (`ro.build.version.*` stay 37 / 2026-10 natively). PlayIntegrityFork does this with a libc hook
> (`spoofProps`, ShadowHook) in DroidGuard only, and its README says DEVICE "requires at least
> spoofProps"; we have no equivalent. (Don't do it system-wide: keystore2 takes the OS patch
> level from `ro.build.version.security_patch`, so a system-wide change risks key upgrades /
> rollback on the lockscreen + FBE keys.) Still untested: fresh device record
> (wipe → new GSF ID), our 23.2/A16 build (Zach gets BASIC on LOS 23.2), Zach's exact recipe.

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

- ⭐ **One command:** `diag-tools/play-integrity/check-integrity.py <unit>` drives the Play
  Store's Check integrity over adb (unlocks, enables Play Store dev options if hidden),
  prints the dialog + GRADED/ERROR verdict, saves screenshot/logcat/result.txt to
  `~/android/lineage-24/integrity-checks/` (off-repo: the dialog has a TestId). Exit 0 = graded.

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
