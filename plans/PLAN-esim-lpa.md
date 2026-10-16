# PLAN — On-device eSIM profile switching (removable eUICC in the SIM tray)

**Goal:** switch profiles on the physical eSIM-adapter card **live on the phone**, without
pulling it out to the external CCID reader. Downloading new profiles over the reader stays
fine; the win is `Warp(VZW) ↔ DarkStar(AT&T) ↔ Roamless` switching in the field.

**Status: 🏁 shipped via OTG reader (2026-07-30); 🔎 RE-OPENED 2026-10-16 on a NEW write path — the MCFG/PDC config-apply route, which was never tested. See "MCFG/MBN write path" below; prior static close-outs (10-14/10-15) remain valid for the diag/offline-EFS routes.**
The stated goal (switch profiles *while the card sits in the tray*) is **impossible on this
hardware**: the modem refuses logical channels to the eUICC ISD-R AID, from every client
including qcrild. What we shipped instead, and what Kyle validated, is **OpenEUICC driving the
CCID reader over USB-OTG** — profiles managed on the phone with no PC, which was the practical
point. Committed to the ROM (see "SHIPPED" below). Read that section and the VERDICT first;
the sections after them are the investigation trail, kept for evidence.

## What was measured (2026-07-30, DUT1 over USB, `nas-probe isdr`)

New read-only `isdr` command added to `diag-tools/nas-probe/` — opens a logical channel to
the eUICC ISD-R applet (AID A000000559101 0FFFFFFFF8900000100) and sends ES10b GetEUICCInfo1.

**Every direct QMI-UIM route is refused by the modem with `QMI_ERR_ACCESS_DENIED_V01` (82):**

| Attempt | Result |
|---|---|
| `UIM_OPEN_LOGICAL_CHANNEL` 0x42, AID u8-len-prefixed (libqmi layout) | error 82 ACCESS_DENIED |
| 0x42, AID raw (no length prefix) | error 1 (malformed — encoding wrong, not the blocker) |
| `UIM_LOGICAL_CHANNEL` 0x3F (legacy open-by-AID) | error 82 ACCESS_DENIED |
| `UIM_SEND_APDU` 0x3B, raw `MANAGE CHANNEL open` (00 70 00 00 01) | error 82 ACCESS_DENIED |

Card state is healthy and normal otherwise (`nas-probe uim`: slot 1, USIM app READY) — the
card exposes only the USIM app; ISD-R is reachable solely via logical channel.

**Conclusion:** this is modem-side authorization, not our transport and not the card. Being
root on the AP is irrelevant — the modem refuses channel/APDU ops from our unprivileged QMI
client. (Most likely only the session-owning client — qcrild — may issue restricted APDUs.)
So **lpac-over-QMI-UIM is a dead end on this modem**; do not spend more time there.

## The route that should work: Android telephony APDU path via a privileged app

`TelephonyManager.iccOpenLogicalChannel()` / `iccTransmitApduLogicalChannel()` go through
**qcrild** — the client the modem already trusts. This is the same "Telephony/TMAPI" backend
NekokoLPA uses (its OTBridge exists to reach it on rooted stock ROMs). We build the ROM, so
we can grant it properly instead of bridging.

**Recommended: ship `PrivilegedOpenEUICC`** (github.com/estkme-group/openeuicc) — purpose-built
for AOSP-based ROMs, designed for exactly this:
- install as a **system app**, **platform-signed**, with the upstream
  `privapp_whitelist_im.angry.openeuicc.xml` privapp permission list (needs
  `MODIFY_PHONE_STATE` + `READ_PRIVILEGED_PHONE_STATE`), minSdk 11+ — we are A16.
- no root, no ARA-M rules needed on the card (that's the unprivileged EasyEUICC path).
- ⚠️ upstream disclaims *removable* eUICC support ("inconsistent in practice") — the
  adapter card is exactly that case, so this is an experiment, not a guarantee. First
  build → try list-profiles; if ISD-R answers, switching should follow.

Alternative if OpenEUICC misbehaves with this particular card: keep using **NekokoLPA**
(already Kyle's tool, known to drive this card over the reader) and instead grant *it*
the telephony path — either platform-sign + privapp-whitelist the APK in the ROM, or give
it carrier privileges. Same underlying API, familiar UI. Deciding factor is simply which
one talks to this specific adapter card correctly.

## STAGED 2026-07-30 (uncommitted, awaiting Kyle's build + flash)

Built from source **inside the AOSP tree** — upstream supports this directly and it is far
better than a prebuilt APK: their `Android.bp` already declares `certificate: "platform"`,
`privileged: true`, `system_ext_specific: true`, and pulls the whitelist in via `required:`,
so signing and the privapp allowlist are handled by the build, not by us.

| What | Where | Note |
|---|---|---|
| OpenEUICC source (+ lpac submodules) | `packages/apps/OpenEUICC/` | 6.7 MB; `.git` stripped. Upstream `estkme-group/openeuicc` master. |
| Prebuilt Kotlin/AndroidX deps | `prebuilts/openeuicc-deps/` | 1.7 MB; `gitea.angry.im/PeterCxy/android_prebuilts_openeuicc-deps` — the `OpenEUICC_*` static_libs its `app-deps/Android.bp` references. Build fails without it. |
| `PRODUCT_PACKAGES += OpenEUICC` | `device/xiaomi/Mi8937/device.mk` | inside the existing **`TARGET_DEVICE_PEPITO`** block (that gate exists now — PLAN.md's "wire it" TODO is stale), so siblings are unaffected. |

Installs to `/system_ext/priv-app/OpenEUICC/` + `/system_ext/etc/permissions/privapp_whitelist_im.angry.openeuicc.xml`
(perms: READ_PRIVILEGED_PHONE_STATE, WRITE_EMBEDDED_SUBSCRIPTIONS, MODIFY_PHONE_STATE,
SECURE_ELEMENT_PRIVILEGED_OPERATION, FOREGROUND_SERVICE, POST_NOTIFICATIONS).

**✅ `m OpenEUICC` builds clean on Stellaris16 (2026-07-30, 3m37s) — verified in `out/`:**
`OpenEUICC.apk` (15.7 MB) + the whitelist XML in `system_ext/etc/permissions/` +
`liblpac-jni.so` (arm64, bundled in the APK *and* at `system_ext/lib64/`), and the APK is
signed **`CN=pepito/kyle@cascade.family`** — i.e. our own platform key from
`vendor/lineage-priv/keys`, exactly what the privileged/telephony path requires. So the
build side is proven before the flash; only the runtime card question is open.

⚠️ These two directories are **not repo-managed projects** — a `repo sync` won't touch them,
but a fresh checkout must re-clone both (same class of gotcha as the
`generated_kernel_headers` symlink farm). Add to BUILD.md, or better, to a local manifest
with `sync-s` (submodules) for OpenEUICC.

## FLASH #1 RESULT 2026-07-30 — app runs privileged; blocked on a missing OMAPI service (fix staged)

Boots clean, app installed at `/system_ext/priv-app/OpenEUICC/`, and **all four privileged
permissions are granted** (`MODIFY_PHONE_STATE`, `READ_PRIVILEGED_PHONE_STATE`,
`WRITE_EMBEDDED_SUBSCRIPTIONS`, `SECURE_ELEMENT_PRIVILEGED_OPERATION`) — the platform-signing +
privapp-whitelist half of this lane is **PROVEN**. But the UI sits on a loading spinner forever.

**Root cause (app log):** `OMAPI.SEService: No SecureElementService available from system` →
`bindService failed`. `PrivilegedEuiccChannelFactory.tryOpenEuiccChannel` tries **OMAPI first for
removable cards**, and `connectSEService()` (app-common/util/Utils.kt) suspends on a connection
callback that never fires — `SEService`'s constructor does **not** throw when its bind fails, it
only logs. No timeout ⇒ hangs forever ⇒ it never falls through to the TelephonyManager path.
Our ROM ships no `com.android.se` (confirmed: `pm list features` has no
`android.hardware.se.omapi.uicc`; `service list` has no `secure_element`).

⭐⭐ **The modem/RIL side is NOT the blocker, and the earlier QMI verdict needs qualifying:**
boot logs show the framework opening logical channels through qcrild **successfully** —
`iccOpenLogicalChannel: A00000015141434C00` (ARA-M "ACL") returned OK and transmitted APDUs.
So logical channels *do* work via RIL; only our own unprivileged QMI client was refused. Note
also the framework's own euicc `ApduSender` tried ISD-R at boot and got **OPERATION_NOT_ALLOWED
(54)** — that specific denial is still unexplained and may bite once we reach the open.
Other facts: `UiccSlot: checkIsEuiccSupported : true` but `update: eid is missing. ics.eid=`;
card ATR `3b9f96803f87828031e073fe211f574543753130346525`.

**Fix staged (uncommitted):** local patch to `app-common/.../util/Utils.kt` — `connectSEService`
now checks `PackageManager.FEATURE_SE_OMAPI_UICC` and throws immediately when absent, so callers
treat OMAPI as unavailable and fall through to TelephonyManager instead of hanging. Also set the
app's `removable_telephony_manager` developer preference = true (see below), since the
TelephonyManager branch is gated on `port.card.isEuicc || that pref`.

⚠️ Setting that pref by hand: it lives in a DataStore protobuf at
`/data/data/im.angry.openeuicc/files/datastore/prefs.preferences_pb`. Hand-writing it works, but
**do not `restorecon` the app data dir** — that strips the MLS categories and the app then dies
with `EACCES`. Correct label is the app dir's own: `u:object_r:app_data_file:s0:c512,c768`.
(In-app route: Settings → tap version 7× to unlock developer options → "Force use TelephonyManager API".)

Alternative/complementary ROM fix if OMAPI is ever wanted: ship AOSP `SecureElement`
(`com.android.se`) + the `android.hardware.se.omapi.uicc` feature XML — but that also wants a
`secure_element` HAL, so the app-side patch is the cheaper path.

`adb remount` works on this build (userdebug), so APK iterations can be hot-swapped into
`/system_ext/priv-app/OpenEUICC/` without a full reflash.

## 🔴 VERDICT 2026-07-30: BLOCKED IN MODEM FIRMWARE — the modem refuses the ISD-R AID

After two more patch+reboot cycles the app reaches the card correctly and the **modem says no**:

```
W EuiccChannelManager: OMAPI unavailable for slot 0, falling back to TelephonyManager
I EuiccChannelManager: Trying TelephonyManager for slot 0 port 0
D nativeloader: Load .../liblpac-jni.so ... ok
D UiccProfile [0]: iccOpenLogicalChannel: A0000005591010FFFFFFFF8900000100 , 0 by pid:2020 uid:1001
D RILJ    : [0209]< SIM_OPEN_CHANNEL error 54   → OPERATION_NOT_ALLOWED
```

Every layer we control now works: privileged app ✅, platform signature ✅, OMAPI fallback ✅,
lpac JNI loaded ✅, correct ISD-R AID sent ✅, via **qcrild — the client the modem trusts** ✅.
The refusal is **AID-specific**: the same modem happily opens ARA-M (`A00000015141434C00`) on the
same card in the same boot. `OPERATION_NOT_ALLOWED` (RIL 54) is the RIL mapping of the same
`QMI_ERR_ACCESS_DENIED` (82) our direct QMI probe got — so both routes hit *one* wall, and it is
**not** an AP-side permission problem at all. Read: this 2017-vintage MPSS
(`MPSS.TA.2.3.c1-00684`) predates SGP.22 and blocks logical channels to the ISD-R.

**Consequence: live on-device profile switching is not achievable from the ROM side.** No amount
of app/permission/sepolicy work changes a modem AID restriction.

## ✅ SHIPPED 2026-07-30 — OTG reader works, committed to the ROM

**Kyle confirmed OpenEUICC reads the card with the CCID reader attached in OTG host mode.**
That is the lane's deliverable: profiles are managed on the phone, no PC. Committed:

| Repo | Commit |
|---|---|
| `device/xiaomi/Mi8937` (branch `pepito-rmnet`) | `d044ec19` — `PRODUCT_PACKAGES += OpenEUICC` under `TARGET_DEVICE_PEPITO` |
| `packages/apps/OpenEUICC` (new local repo, branch `pepito`) | `52da20c` upstream import @ `2a85b8da` (2026-07-19, submodules in-place) + `153838d` the two OMAPI fixes |
| `prebuilts/openeuicc-deps` (new local repo, branch `pepito`) | `72654cf` import @ `67a341e9`, unmodified |

⚠️ **Both new directories are tree-local git repos, deliberately NOT in `.repo/local_manifests`**
(that manifest was written earlier and has been **deleted**). Reason: our two fixes live inside
the upstream source, and a repo-managed project would let `repo sync` clobber them. Same class of
fresh-checkout gotcha as the `generated_kernel_headers` symlink farm — a new checkout must copy
these two repos, not re-clone upstream. They still need pushing to personal remotes at
`PLAN-release.md` Gate 0.

⭐ The two fixes are genuine upstream bugs (any ROM without `com.android.se` hits them) — send
them to `estkme-group/openeuicc` rather than carrying them forever.

### (background) The practical win: reader over USB-OTG
OpenEUICC (and NekokoLPA) both support **USB CCID readers**, and USB OTG host works on this
device ([[usb-otg-host-dualrole]]). So Kyle can plug the existing reader into the *phone* and
switch profiles on-device — no PC. That delivers most of the original goal and needs no modem
cooperation. **Next step: try the reader on an OTG cable with the now-installed OpenEUICC.**

### Speculative, only if someone wants to keep digging
- Hunt a modem EFS/NV eUICC-support flag under `/nv/item_files/modem/uim/…` (would need an EFS
  read/write path; entirely unproven that such a flag exists on this MPSS).
- Not worth a lane on its own; the OTG route is cheaper and already works in principle.

**⏳ (superseded) WAITING ON A REBOOT (2026-07-30 20:02).** The patched APK is rebuilt (clean, 2m53s; patch
string verified present in `classes2.dex`) and already hot-swapped to
`/system/system_ext/priv-app/OpenEUICC/OpenEUICC.apk` (stale `oat/` removed, relabelled
`system_file`), and the `removable_telephony_manager` pref is in place. PackageManager only
re-scans `/system` at boot, so **Kyle: reboot the DUT, then re-open OpenEUICC.** Expected: no
more infinite spinner — either the profile list appears, or it fails fast with a *real* error we
can read (watch for `Trying TelephonyManager for slot` + a `SIM_OPEN_CHANNEL` with the ISD-R AID
in `logcat -b radio`).

### Validation plan (after flash)
1. App appears; open it → does it enumerate the removable card's ISD-R and list profiles?
   That single question is the whole experiment.
2. If yes: enable a second profile → confirm new ICCID, then attach + VoLTE + data green
   (per-ICCID MCFG selection auto-picks the carrier config, proven 2026-07-30 in
   `PLAN-mcfg.md` — an AT&T profile should land on VoLTE-ATT).
3. If it can't see the card: fall back to platform-signing **NekokoLPA** (below), which is
   already known to drive this specific card over the reader.
4. sepolicy: watch for denials on the telephony/UICC path under Enforcing; enforce-check
   per PLAN.md's `checkpolicy` recipe before the next build.

## 🏁 RE-OPENED 2026-10-14, CLOSED AGAIN 2026-10-15 — no write path to the modem's AID policy

Static RE of the modem (2026-10-14) showed the ISD-R refusal is an AID-security policy inside
`qmi_uim`/`mmgsdi_csg.c`, with two EFS override items (`/nv/item_files/modem/qmi/uim/
apdu_security_restrictions` and `apdu_security_aid_list`) that do not exist on any fleet unit, so
the modem runs its compiled-in default (restrictions enabled, ISD-R refused by a hardcoded
eUICC-RID recognizer). Whether that recognizer honours `apdu_security_restrictions=0` was never
proven (q6zip opcode table for this build does not match the public decoder). It no longer
matters, because every way of creating the item is closed:

- **Diag EFS2 writes to `/nv/**` are denied** by the modem's path ACL (reads work). Every
  mainstream EFS tool (EfsTools, QPST EFS Explorer, qcom-efs-browser) uses that same channel.
- **The modem code image is secure-boot signed**, so patching the recognizer is out.
- **modemst1/modemst2 are TZ-encrypted RMTS snapshots, not an editable filesystem.** The banked
  dut1 dumps are a 0x40 header (age, payload length, `IMGEFS1n`/`IMGEFS2o` tag) followed by a body
  at 7.9 bits/byte entropy with no plaintext paths; the two ping-pong copies differ in nearly every
  byte while holding the same contents. An offline "EFS item-injection writer" would emit
  plaintext the modem cannot ingest. Whole-partition restore of a dump still works.

**Permanent answer (for the diag + offline-EFS routes): the USB-CCID reader over OTG.**
Those routes stay closed. The MCFG/PDC route below is the "new write primitive" the reopen
clause asked for — it writes EFS from *inside* the modem, not over the diag ACL.

## 🔎 MCFG/MBN write path — RE-OPENED 2026-10-16 (static)

The old close-out said "no write primitive into the modem's EFS." That was true for the two
routes tested (diag EFS2 to `/nv`, offline modemst surgery) but **missed a third: the MCFG
config-apply path.** Carrier configs (`mcfg_sw.mbn`) carry EFS-file items that the modem's own
MCFG processor writes into EFS when a config is loaded/activated via the QMI PDC service — this
never touches the diag `FS_DIAG_VALIDATE_PATH_ACCESS` ACL that blocked us. We already drive PDC
(`diag-tools/pdc-mbn-loader`, [[mcfg-lane]]).

Static work-up (full detail + tooling in `diag-tools/esim-mbn/`):

- **The modem reads the target items from EFS** (gated, not unconditional). The modem binary
  embeds both `/nv/item_files/modem/qmi/uim/apdu_security_restrictions` and `…/apdu_security_aid_list`
  as compiled-in rodata (vaddr 0x883dbe9e / 0x883dbf07). A path string is only compiled in to
  efs_get/efs_put that item. Caveat: the referencing code is q6zip-paged (same wall as 10-15),
  so "reads it" is proven but "the read gates the ISD-R decision" is inferred, not read.
- **MCFG can provision UIM-tree EFS items** — stock configs already carry
  `/nv/item_files/modem/uim/{mmgsdi,gstk,gba}/*`. Target `/modem/qmi/uim/` is a sibling subtree,
  same mechanism.
- **mcfg_sw.mbn format fully reversed** (ELF32-hexagon: ph0 hdr-mirror, ph1 hash-table + RSA sig
  + 13-cert X.509 chain, ph2 MCFG payload). EFS record is value-first:
  `marker=2 | vallen | value | reclen | attr=0x1902 | flags=1 | pathlen | path\0`.
- **Configs are signed** → we can't re-sign (fused root), but hashes are fully repairable. The
  lane hinges on one cheap on-device unknown: **does this modem enforce the SW-config signature
  at PDC load?** The modem has `mcfg_auth_img_verify()`/`mcfg_auth_verify_hash()` *and* a
  `fake_sec_enabled` token (Qualcomm's permissive SW path — why community carrier MBNs load on
  most MSM8937). Enforcement is in paged code; test it empirically.

**Next (on-device, reversible — reload stock after):** `mbn_tool.py` builds the images.
1. Hash-only probe: flip one payload byte, fix hashes, leave RSA sig stale, PDC-load. Loads →
   SW auth NOT enforced (fake-sec) → route open. Rejected → enforced → route dead.
2. If open: inject `apdu_security_restrictions=00`, load, read it back over diag EFS2 (reads
   allowed), re-probe ISD-R OPEN_LOGICAL_CHANNEL. ISD-R opens → reader-free switching.

### Static q6zip RE re-attempt (2026-10-15) — decoder located, not cracked, lane closed

One open thread remained: decompress the modem's q6zip-paged code to read whether the ISD-R
recognizer honours the `apdu_security_restrictions` enable flag (the gated-vs-unconditional
question). Re-attacked with the prior session's surviving artifacts (full resident Hexagon
disassembly, analyzed Ghidra project, the modem ELF) and got further than before:

- The q6zip read-only pool is the ELF LOAD segment at `0x89f41000`, about 9.9 MB.
- The subpage dispatcher is `0x875e9800`–`0x875e9bdc`; it assembles the control words and calls
  out to helpers for the token work.
- The opcode logic is split across trampolined resident helpers (`0x87084d64` is a higher-level
  state machine, `0x875e6368` a recursive buffer manager), none a clean bit-decode loop.

Hand-reading the exact opcode semantics across those trampolines is unreliable because of Hexagon
packet-boundary ambiguity, which is what made the earlier decompiles unusable. The reliable crack
is to run the code, but no usable bare-metal Hexagon emulator exists off the shelf, so that means
building an emulation harness, a large effort. Since all three write paths are closed regardless of
the answer, the result would be academic. **Lane closed.** If reader-free switching is ever worth
funding, resume with a Hexagon emulation harness seeded at the dispatcher address above, not more
hand reverse-engineering.


## Guardrails
- ⚠️ Profile switch = UICC REFRESH with a new ICCID — treat like a SIM swap. **Never** use
  the Settings SIM enable/disable toggle around it ([[sim-uicc-toggle-trap]]); recovery is
  `ctl.restart qmux_qcrild`.
- Keep a working profile loadable from the external reader as the escape hatch — a wedged
  card is recoverable by pulling it, nothing here is unbrickable-adjacent.
- `nas-probe isdr` stays useful as the "did anything change?" probe after ROM changes.
