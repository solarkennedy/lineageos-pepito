# PLAN-aboot — Bootloader security posture & findings

**Scope:** Security assessment (NOT reverse-engineering) of the stock Palm PVG-100 (pepito)
bootloader, ahead of a personal LineageOS 23.2 release. Goal: understand what running an old,
frozen aboot costs us, decide lock/verification posture for the release, and capture the
device-state checks that still need doing. RE artifacts live outside the tree in
`~/Projects/aboot-re/` (prior work: boot_verifier / unlock-flow / secure-boot-state traces) —
**that lane is parked; do not extend it** (per [[feedback-blackbox-before-re]]).

**Status (2026-07-16): assessment drafted from binary metadata + prior RE artifacts.
SECURE-BOOT FUSE now CONFIRMED ENABLED (§Verified findings) — the load-bearing conclusion is
evidence-backed. One device-state fact still open (MDTP state).**

---

## What the binary is

- **Qualcomm Little Kernel (LK) "aboot"** (applications bootloader / APPSBL) for MSM8937/8940.
  Source paths in-binary: `app/aboot/aboot.c`, `target/Pepito/init.c`, `platform/msm_shared/boot_verifier.c`.
- **`~/Projects/aboot-re/aboot.bin`** — ELF32 ARM, statically linked, no section headers (the
  extracted APPSBL). **`aboot_ddr_0x8f600000_2M.bin`** — live DDR dump of it running at load
  base `0x8f600000` (matches every `0x8f6xxxxx` address in the decompiled traces).
- **Verified Boot generation: VB1.0** — `boot_verifier.c` + keystore + ROT + `scm_protect_keystore`,
  `androidboot.verifiedbootstate` (orange/yellow/green). **No AVB 2.0** — zero `vbmeta`/`libavb`
  strings. This is the single most consequential fact (see §Release posture).
- **Qualcomm MDTP / SafeSwitch** theft-protection compiled in (DIP, eFuse-gated, TZ-ciphered).
- **TrustZone/QSEE-anchored**: secure-boot fuse read via `scm_call` (the "scm call to check
  secure boot" path in `aboot-re/qsee_check.txt`), RPMB, `keymaster=1`, devinfo r/w.
- **Crypto: legacy LK OpenSSL fork** (full `lib/openssl/crypto/asn1/...` + GOST suite) — NOT
  BoringSSL. Old ASN.1 stack.
- **Age:** LK base ~2017 (8x37 branch), firmware ~2020 (embedded cert stamped `2020-09-21`),
  shipped on Palm Android 8.1.
- **Unlock gating:** ships `oem unlock is not allowed` — unlock behind an `frp-unlock` /
  allow-unlock flag; `dynlock` critical-partition locking present.

---

## Threat model (frames everything below)

**All of aboot's exposed surface is LOCAL and requires physical possession + USB** (fastboot or
EDL). **Zero remote/network surface.** For a personal device the honest threat is "someone has
the phone in their hands and a cable," not an internet attacker. The larger age-driven exposure
on this SoC is the frozen TZ/QSEE/keymaster and the modem — which we already run regardless.
aboot is a small, physically-gated part of that.

---

## Findings — what "old & frozen" actually costs us

1. **No more patches, ever.** MSM8937/8940 fell off Qualcomm security bulletins years ago. This
   is a frozen binary; any LK/aboot bug found after ~2020 is permanently unpatched. Inherent to
   the SoC, not fixable from our side.

2. **Bug classes live in the exposed parsers.** Highest-value targets: the **fastboot USB
   command parser** (`download:` handler, sparse-image parsing, `flash:`/`getvar:`) and
   **boot/MDTP image-header parsing**. This LK generation historically carried integer-overflow /
   OOB bugs there. **Mitigating:** the binary already contains the "…buffer address overlaps with
   aboot addresses" guards throughout — those *are* Qualcomm's fixes for the aboot self-overwrite
   class, so this build post-dates that wave. Not pristine, not pre-mitigation either.

3. **Embedded OpenSSL is ancient.** The in-tree LK OpenSSL fork (signature/keystore ASN.1 path)
   is old enough to carry known ASN.1 CVEs. Reaching it requires feeding a malicious
   keystore/signature — a local flash op — but it's the weakest single component.

4. **Unlocked = verification skipped (expected for LineageOS).** When unlocked, aboot logs
   `Device is unlocked! Skipping verification…`, sets `verifiedbootstate=orange`, and does NOT
   verify our boot image. Because it's **VB1.0 there is also no anti-rollback** — nothing at the
   bootloader stops an older signed image being reflashed. Our integrity story therefore lives
   **above** aboot, in the LineageOS boot image: AVB/vbmeta + dm-verity + FBE (aes-256-xts,
   fscrypt v2) + HW keymaster/gatekeeper — all already validated ([[gatekeeper-rpmb-acmd12]],
   `PLAN-gatekeeper.md`). That's the correct and current layer for it.

---

## Verified findings (independent RE double-check, 2026-07-16)

Re-derived from the binary + DDR dump, NOT trusting prior labels. Method: capstone raw-disasm at
computed file offsets (the ELF has no section headers, so `objdump -d` walks nothing; LOAD maps
fileoff `0x8000`→vaddr `0x8f600000`, so `fileoff = vaddr - 0x8f600000 + 0x8000`).

- **`is_secure_boot_enable()` at `0x8f618384` is accurate as prior-RE'd** (`qsee_check.txt`). It
  issues the TZ `GET_SECURE_STATE` SCM (`SCM_SVC_INFO`, cmd word `0x2000604` on the new ABI /
  `svc 6, cmd 4` legacy) into a 0x40-byte buffer, then sets the cached flag **`DAT_8f696000 = 1`
  iff** secure-state bits {0,1,2,5} are clear **and** bit `0x40` is set (the "secured" fuse
  pattern). Accessor at `0x8f6185a4` returns the flag; consumer at `0x8f618840` treats non-zero
  as secure. **The ONLY writer of `1` to `0x8f696000` is that fuse-gated branch** — no
  debug/backdoor path — and `.bss` inits to 0, so a runtime `1` can only originate from the
  secured fuse state.
- **SECURE BOOT IS ENABLED (confirmed).** In the live DDR dump `DAT_8f696000` reads
  **`0x00000001`** (vs `0x0` in the ELF's zero-init `.bss`). Therefore **aboot is
  signature-anchored by SBL** — a physical-access attacker cannot substitute a modified aboot
  without a valid signature. This upgrades the former OPEN item to CONFIRMED and is the
  foundation the whole posture rests on.
- Caveat / residual doubt: (a) polarity "1 = secured" is inferred from the setter's fuse-bit
  gate + the getter/consumer structure + Qualcomm convention, not from a decoded TZ bit spec;
  (b) it's assumed the dump is from a pepito unit — secure-boot fuses are factory-blown across
  production units, so this holds for our DUT too, but a one-line on-device secure-state read
  would make it zero-doubt for THIS specific unit.
- Byte-level gotcha worth remembering: the hexdump right after `0x8f696000` looks like a
  mutex/wait-queue (self-pointers + `mutx`/`wait` strings). It is a **separate adjacent global**;
  `0x8f696000` is a genuine standalone `int`. Disassembling the store settled it — eyeballing the
  hexdump would have raised a false mislabel worry.

## Verified boot — LIVE-DEVICE + disasm findings (2026-07-16) ⭐ CORRECTS earlier draft

Read off a live pepito unit (serial `81eed371`, running our A16 build, rooted) + confirmed in
the binary. **Earlier draft assumed "ships unlocked / orange / verification skipped." That is
WRONG — the build actually runs LOCKED with verified boot ENFORCED.**

- **Device is LOCKED.** `devinfo` partition (`mmcblk0p31`) after the 13-byte `ANDROID-BOOT!`
  magic: `is_unlocked=0, is_tampered=0, is_unlock_critical=0`. The RAM copy is `DAT_8f6810bc`
  (=`is_unlocked`), used as the verify gate.
- **Live state: `ro.boot.verifiedbootstate=yellow`, `ro.boot.veritymode=enforcing`.** Locked +
  custom key + dm-verity enforcing.
- **Verification runs (not bypassed).** Boot gate in `boot_linux_from_flash` (`FUN_8f628554`):
  `if (target_use_signed_kernel()==0 || is_unlocked!=0) <no-verify> else <verify>`.
  `target_use_signed_kernel()` (`FUN_8f623724`) is `mov r0,#1` → **always 1**; `is_unlocked=0`
  → the **verify** branch (`FUN_8f625fd0`) executes.
- **Verification is REAL but runs in aboot's OpenSSL, NOT TrustZone** (corrected 2026-07-16).
  `verify_image_with_sig`→`bv_signature_decrypt` does `RSA_public_decrypt` locally (bignum, no
  QSEEcom) + exact `memcmp` of the 0x33-byte SHA-256 DigestInfo. The QSEEcom/TZ calls
  (`send_boot_key_to_keystore`) only push the Root-of-Trust/boot-key to the keymaster TZ app for
  attestation/keystore binding — **downstream of and trusting aboot's verdict; the TZ never
  re-verifies the image.** So the ancient LK-OpenSSL is squarely inside the boot TCB. Tries OEM keystore
  `DAT_8f694688` → GREEN; on failure extracts the pubkey from the cert **embedded in the image's
  own signature** (`FUN_8f65417c`→`DAT_8f694680`) and re-verifies → YELLOW; total fail → RED.
- **RED is ENFORCED — it powers the device off, does NOT boot.** `FUN_8f625fd0`: state `3`(RED) →
  show warning, delay `0x7530`=30000 ms, then `FUN_8f600544` = `shutdown()` (loads
  `"Going down for shutdown."`, writes PON reg `0x4a00b000`). String table corroborates:
  `"Your device will poweroff in 30 seconds"`, `"Phone will shutdown"`. State `2`(YELLOW) → warn
  + short delay → **continue booting** (our live path).
- **⚠️ YELLOW trusts the image's SELF-EMBEDDED cert — no chain to a hardware root.** Proven
  empirically: the `keystore` partition (`mmcblk0p33`, 256 KB) is **entirely zero**, so yellow
  cannot come from a flashed user keystore — it comes from the cert inside our signed boot image.
  So yellow proves *integrity + self-consistency* (image signed by whoever holds that embedded
  cert's key), NOT *identity* against a root of trust. The tripwires against a malicious reflash
  are: (a) corrupt/unsigned → RED → shutdown, and (b) a different signer changes the fingerprint
  shown on the yellow warning screen (user-visible, not cryptographically rejected). This is the
  known AVB-1.0 yellow limitation, not a bug in our build.

### Why "no real lock/unlock" and "doesn't remember" (Kyle's observation — explained)
- `oem unlock is not allowed`: Palm disabled the fastboot unlock verb, so `is_unlocked` is stuck
  at 0 — there's no user-facing unlock toggle. **Flashing is done via EDL** (raw eMMC writes,
  `PLAN.md` build/flash flow), which bypasses aboot's lock enforcement entirely. Hence "doesn't
  really have lock and unlock."
- The green/yellow/red color is **recomputed every boot** by re-verifying the current boot
  image's signature; it is **not persisted** (no AVB-2.0-style stored unlock token / rollback
  index). Hence "flash stock → green" (Palm OEM key matches the built-in keystore) and "it
  doesn't remember."

## Release posture — decisions ⭐ UPDATED

- **Ships LOCKED, verifiedbootstate=yellow, dm-verity enforcing — a STRONGER posture than the
  earlier draft assumed** (most custom ROMs ship orange/unlocked with boot verification off). Keep
  it. Release note should state: locked + yellow (custom-key verified boot) + dm-verity enforcing
  + FBE; a corrupt/unsigned boot image is refused (RED → power-off).
- **Honest caveat for the release note:** yellow verifies against the image's own embedded cert,
  so it is not equivalent to OEM green. The meaningful integrity guarantees for a determined
  physical/EDL attacker are the RED-on-corrupt shutdown + the visible key fingerprint, plus
  dm-verity/FBE above the bootloader.
- **Residual risk = physical access + EDL** (raw flash below aboot). No software fix; mitigate
  operationally. Note in release notes.

---

## OPEN — device-state checks that gate the conclusions

- [x] **Is the secure-boot fuse actually blown?** ✅ CONFIRMED YES (§Verified findings) —
  `is_secure_boot_enable()` resolved to `1` in the DDR dump; aboot is signature-anchored by SBL.
  Only remaining nicety: a one-line on-device secure-state read to make it zero-doubt for THIS
  specific DUT (fuses are factory-blown per-unit, so expected `1`).
- [ ] **MDTP / SafeSwitch state** — confirm deactivated so it can't wedge boot.
- [ ] **(Optional, for release notes) Exact Qualcomm bulletin CVE coverage for MSM8937/8940
  bootloader components** — build a concrete "last patch level vs. known-unpatched" list. Needs no
  RE (WebSearch). Deferred until asked.

---

## Route A — signature forgery (e=3 / BERserk): investigated & CLOSED (2026-07-19)

Settled by disassembly + the stock-key extraction. **The green/OEM key really does use a small
exponent, but the forgery is blocked** — verified end to end, not assumed.

- **The OEM (GREEN) key is `e=3`.** Extracted from `boot.stock.bin`'s embedded cert (signer
  `CN=TCLMOBILE`, the TCT/TCL ODM), RSA-2048, `e=3`. Confirmed baked into `aboot.bin` at
  `+0x65ca1`. So the BERserk/Bleichenbacher *precondition (small exponent) IS met* for the key
  that grants green. (Our own `pepito-boot` yellow key is `e=65537`, irrelevant to this.)
- **But the padding check is standard-STRICT.** `RSA_public_decrypt` → method dispatch →
  `RSA_eay_public_decrypt` (`0x8f651a2c`, "Eric Young's PKCS#1 RSA" method `@0x8f68e720`) →
  `RSA_padding_check_PKCS1_type_1` (`0x8f652744`, refs `rsa_pk1.c`). That function:
  - requires `num == flen+1` and block type `== 0x01`;
  - **FF-run loop** (`0x8f6527a0`): every padding byte must be `0xFF`; the first non-FF byte must
    be exactly `0x00` (separator) or it's an error (`0x8f6527e8: cmp #0; bne <err>`) — no
    arbitrary/"don't-care" bytes allowed in the padding;
  - enforces `PS ≥ 8`; returns length = **everything after the separator** (`rsb r6,ip,r3`), so
    trailing garbage inflates the length.
  The LK note "removing rand dependency in rsa_pk1.c" only touched the *type_2 add* (encryption
  padding RNG), not this *type_1 check*.
- **Caller nails it shut.** `bv_signature_decrypt` (`0x8f6100a0`) requires the recovered length to
  be **exactly `0x33` (51)** and does a full 51-byte `memcmp` vs `DigestInfo‖hash`. Strict FF-run
  + exact-length ⇒ all 256 bytes are forced to `00 01 FF×202 00 ‖ DigestInfo ‖ H(image)` — zero
  free bytes. A forge needs `s³ ≡ (fully-fixed value) mod n`, i.e. a modular cube root ⇒ the
  private key (or factoring n). **BERserk's don't-care bytes don't exist here → forgery blocked.**
- **Bottom line: locked+green is cryptographically solid** despite `e=3`; no EDL-cable green
  forgery without TCLMOBILE's private key. Reproduce the whole verify in Python:
  `~/Projects/aboot-re/aboot_verify_emulator.py` (stock→GREEN, our ROM→YELLOW; OEM key hardcoded).

## Route B — pre-authentication ASN.1/X.509 parser attack surface (the realistic "old OpenSSL" risk)

The signature check itself is math-solid (Route A above: strict PKCS#1 padding + exact `0x33`-byte
DigestInfo compare close the e=3/BERserk forgery even though the OEM key is e=3). The realistic exposure from the ancient
OpenSSL is **not breaking the RSA — it's memory corruption in the code that parses the
attacker-controlled signature/cert blob *before* the RSA verdict can reject anything.** Analysis
2026-07-16 (no exploit built; surface-mapping only).

### The load-bearing property: the whole ASN.1 decode is PRE-AUTH
Call-graph BFS from `verify_image_with_sig` (`0x8f610a6c`): **246 functions reachable.** Parse
entry points are direct callees (depth 1) — `d2i_verified_boot_sig` (`0x8f641a90` → template
decoder `0x8f641144` = `ASN1_item_d2i`), `X509_get_pubkey` (`0x8f65417c`), `EVP_PKEY_get_RSA`
(`0x8f64e6c8`), `d2i_X509_ALGOR` (`0x8f61bf00`, depth 2). The only gate that can reject a forged
blob — `RSA_public_decrypt` (`0x8f61be98`) — is depth 2, **after** the full parse. Confirmed
order in decompile: `d2i_verified_boot_sig` → target-name compare → length checks → RSA. So an
attacker-supplied (unsigned, malformed) signature/cert is fully decoded before authentication —
**every parser bug below is reachable by an image that will ultimately be rejected as RED.** The
TZ path (`qseecom_*`, `send_boot_key_to_keystore`) is *unreachable* from the verify — the crypto
and parse are local to aboot; the TZ only receives the ROT downstream and trusts it.

### Attacker input
The verified-boot signature blob appended to the boot/recovery image (target name + embedded
X.509 cert incl. SubjectPublicKeyInfo + v3 extensions + the RSA signature). Fully
attacker-controlled if they can write the partition — i.e. via **EDL** (fastboot flash is
locked/disabled here). Physical-access / evil-maid delivery, not remote.

### Vintage + compiled-in modules (the surface inventory)
**OpenSSL 1.0.0a — CONFIRMED (2026-07-16) via blackbox convergence, no RE.** This is the Qualcomm
**LK `lib/openssl` fork**, shared byte-for-byte across QC platforms (identical `Openssl LK:`
patch markers in `msm8916-mainline/lk2nd`, QCA `lk-af`, QSDK IPQ). Three independent lines:
- **Fork self-declaration:** its `opensslv.h` → `OPENSSL_VERSION_NUMBER 0x1000001f` and
  `openssl.version` → `OPENSSL_VERSION=1.0.0a`. Decode of `0x1000001f`: major1.minor0.fix0
  .patch'a'.status-release (0xf) = **1.0.0a**.
- **Module set:** `rsa_eay.c` + `cryptlib.c` + `rsa_x931.c` + `pmeth_lib.c` all present (every one
  removed/restructured in 1.1.0) → 1.0.x branch; no 1.1.x marker anywhere.
- **OID fingerprint (decisive):** extracted our binary's full OID/algo-name set and diffed against
  the fork's generated `obj_dat.h`. **Every** name in our binary is in the 1.0.0a set; **zero**
  1.0.1/1.0.2/1.1.x-new OIDs present (X25519/X448/ed25519/ChaCha20/poly1305/AES-GCM/AES-CCM/
  id-scrypt/id-*-wrap-pad all ABSENT). NB: the full GOST suite + `id-on-permanentIdentifier` are
  1.0.0-native — they are *not* 1.0.2 markers (common misread) and in fact corroborate 1.0.0.
  Released **2010-06-01**; the 1.0.0 branch's **last release was 1.0.0t (2015-12-03), then EOL** —
  so every CVE fixed only in a 1.0.1+ release was *never* fixed in *any* 1.0.0 build, and 1.0.0a
  further predates the fix releases for the pre-2016 CVEs too.
Modules compiled in and reachable pre-verify:
- ASN.1: `tasn_dec.c` (template decoder — historically the buggiest), `asn1_lib.c`, `a_int.c`,
  `a_bitstr.c`, `a_object.c`, `a_mbstr.c`, `x_name.c`, `x_pubkey.c`, `x_long.c`.
- X.509 / v3 ext: `x509_obj.c`, `v3_ncons.c` (name constraints), `v3_cpols.c` (cert policies),
  `v3_crld.c` (CRL dist points).
- OBJ: `obj_dat.c` (OID lookup). BN: full bignum (`bn_lib/asm/div/exp/mont/...`). RSA:
  `rsa_eay.c`, `rsa_pk1.c` (PKCS1 padding), `rsa_sign.c`, `rsa_x931.c`. BIO: `b_print.c`.

### Representative bug classes for this vintage (ILLUSTRATIVE at module level; version now pinned)
These are the CVE classes that historically lived in exactly the modules above. Version pin to
**1.0.0a** now settles the patched/unpatched question at the *version* level (see verdict below);
remaining open question is per-CVE *reachability* on the live cert path, not patch state:
- **CVE-2016-2108** — ASN.1 encoder negative-zero → OOB *write* (1.0.1/1.0.2 pre-2016-05). The
  archetypal write primitive in this module set; highest concern.
- **CVE-2015-0286** — `ASN1_TYPE_cmp` BOOLEAN type confusion (invalid read).
- **CVE-2016-2176** — `X509_NAME`/`x509_obj` OOB read.
- **CVE-2014-3508** — `OBJ_obj2txt` (`obj_dat.c`) OOB read / info leak.
- **CVE-2021-3712** — non-NUL-terminated `ASN1_STRING` read overrun (`a_bitstr`/`x_name`/`v3_ncons`).
- **CVE-2016-2842** — `BIO_printf`/`doapr_outch` (`b_print.c`).

**Patched/unpatched verdict @ version level (1.0.0a):** every CVE below that touches the 1.0.0
branch is UNPATCHED — either because 1.0.0a predates the fix release, or because the 1.0.0 branch
was already EOL (≤1.0.0t, 2015-12) before the fix shipped:
- CVE-2014-3508 — fixed in 1.0.0i (2014-08); we're 1.0.0a → **UNPATCHED**.
- CVE-2015-0286 — fixed in 1.0.0m (2015-01); 1.0.0a < m → **UNPATCHED**.
- CVE-2016-2108 / CVE-2016-2176 / CVE-2016-2842 — fixed only in 1.0.1t·1.0.2h (2016-05) / 1.0.1s·
  1.0.2g (2016-03); 1.0.0 branch EOL before those → **UNPATCHED** (no 1.0.0 release ever shipped
  the fix).
- CVE-2021-3712 — SM2 ASN.1 path; SM2 was introduced in OpenSSL 1.1.1 and is absent from 1.0.0a
  → **N/A** (not applicable to this build).
So 5/6 are code-present-and-unpatched at the version level. **Caveats (the residual open items):**
(a) Qualcomm *could* have backported a fix despite freezing the base — but the fork shows zero
security-backport markers (only the functional `Openssl LK:` qsort/rand patches); making it
zero-doubt is the optional byte-pattern check below. (b) "unpatched" ≠ "exploitable" — that needs
the per-module xref (is the buggy decoder actually on the cert path, or merely linked?) — which is
the *reachability* open item, separate from the now-resolved patch state.

### Exploitation environment (why aboot is a soft target)
- **No ASLR, fixed load base `0x8f600000`** (single static ELF) — known addresses for ROP/pointer
  targets.
- **Stack canaries ARE present** (`DAT_8f6aa74c` / `stack_chk_fail` in every function) → naive
  stack smashes are detected; the realistic primitives are **heap corruption + function-pointer
  overwrite** (LK `malloc`/`free`, unhardened).
- Runs at **EL1, pre-HLOS, single-threaded**; the parse operates on a RAM buffer read from the
  boot partition. Code-exec in aboot = own the verdict: force GREEN and hand the TZ a GREEN ROT.

### Mitigating factors already in the code
Exact-length DigestInfo compare (closes forgery); explicit bounds checks on cert `n ≤ 0x400` /
`e ≤ 0x10` bytes before bignum use; target-name compare early (does not prevent the parse, but
narrows what a blob must contain). Delivery is physical/EDL only.

### Heap-dump tooling (`/dev/ramboot`) — DEBUG, ⚠️ REMOVE BEFORE RELEASE
To study what the parser leaves on aboot's heap, we dump aboot's DDR from booted Linux. Rebuilt
2026-07-19 (bigger than the original 2 MB): a `no-map` reserved-memory carveout `ramboot_dump`
(**10 MiB @ `0x8f600000`**, `pepito/pepito.dtsi`) + a read-only misc char device
`drivers/misc/ramboot.c` (`CONFIG_RAMBOOT_DUMP=y`, `memremap` WB). 10 MiB (not the requested
32 MiB) because `cont_splash_mem` sits at `0x90000000` — that's also the natural ceiling (aboot's
heap can't cross the framebuffer). Capture: `dd if=/dev/ramboot of=aboot_ddr_..._32→10M.bin`.
⚠️ **This device exposes physical RAM read-only — it MUST NOT ship. Release gate: drop
`CONFIG_RAMBOOT_DUMP`, the `ramboot_dump` DT node, and `ramboot.c` before building a release.**

### Open follow-ups (analysis only — NO exploit)
- [x] **Pin the exact OpenSSL sub-version** ✅ DONE (2026-07-16): **OpenSSL 1.0.0a** (Qualcomm LK
  `lib/openssl` fork) — blackbox convergence from fork self-declaration (`opensslv.h`
  0x1000001f / `openssl.version`) + module set + full-OID-set diff vs the 1.0.0a `obj_dat.h`
  (every name matches; zero 1.0.1/1.0.2/1.1.x-new OIDs present). No RE required. See §Vintage + the
  patched/unpatched verdict block above. **Bonus from the pin:** 1.0.0 branch EOL'd at 1.0.0t
  (2015-12), so the illustrative CVE list is now a concrete version-level verdict (5/6 UNPATCHED,
  CVE-2021-3712 N/A); only per-CVE *reachability* + the optional byte-pattern backport-confirm
  remain.
- [ ] Per-module xref: confirm which specific decoders (`v3_ncons`, `obj_dat`, `x_name`) are
  actually invoked on the cert path vs. merely linked.
- [x] (Route A closure) ✅ DONE 2026-07-19 — OEM key is `e=3` (precondition met) BUT
  `RSA_padding_check_PKCS1_type_1` (`0x8f652744`) is standard-strict + caller requires exactly
  `0x33` bytes ⇒ forgery blocked. See §"Route A" above.

## RE project state (for future sessions)

The Ghidra project `~/Projects/aboot-re/ghidra_proj/aboot.gpr` now carries **human-readable names
+ evidence plate-comments** for the verified functions/globals (applied 2026-07-16 by
`RenameVerifiedFunctions.java`). Named: `resolve_secure_boot_state`, `is_secure_boot_enable`,
`target_use_signed_kernel`, `boot_linux_from_flash`, `verify_bootimg_and_set_state`,
`shutdown_device`, `write_device_info`, `fastboot_publish_vars`, `get_keymaster_status`, and
globals `g_is_secure_boot`, `g_device_info`, `g_dev_is_unlocked`, `g_dev_is_unlock_critical`,
`g_oem_keystore`, `g_embedded_cert_rsa`, etc. (boot_verifier core already named by
`LabelBootVerifier.java`).

⚠️ Gotcha re-running any `.java` here: the `aboot-re/` root has sibling scripts that break the
Ghidra OSGi bundle build, so `-scriptPath ~/Projects/aboot-re` fails to load ANY script. Run from
an **isolated dir** holding only the one script:
```
cp RenameVerifiedFunctions.java /tmp/gh/ && \
~/Projects/ghidra_12.1.2_PUBLIC/support/analyzeHeadless ~/Projects/aboot-re/ghidra_proj aboot \
  -process aboot.bin -noanalysis -scriptPath /tmp/gh -postScript RenameVerifiedFunctions.java
```

## Guardrails

- **Do NOT reverse-engineer aboot further.** The RE lane in `~/Projects/aboot-re/` is parked; this
  file is the *assessment*, not an invitation to resume RE ([[feedback-blackbox-before-re]]).
- **Do NOT modify/reflash aboot.** EDL recovery exists (mask ROM, unbrickable) but aboot is
  signature-anchored if the fuse is blown; touching it risks the chain of trust for no benefit.
- Feeds `PLAN-release.md` (release notes: lock posture + residual-risk statement).
