# Gatekeeper / Keymaster Bring-up - Pepito

Updated: 2026-07-07

> **Cross-ref (2026-06-26 holistic session):** keymaster/gatekeeper is **Cluster C** in
> `PLAN.md` "Holistic cross-cutting analysis" — stock-Palm-Android-8 TZ/blobs vs the 4.19
> kernel + Android-16 keystore2. The RPMB saga (chardev→block→ioctl→CQE→Auto-CMD23) and the
> keystore2↔2018-TA version binding are all that ABI gap, not a clock/DTS or QMI/QRTR issue.
> Independent of the radio/GPS/sensors clusters.

## ✅ 2026-07-08 FBE VALIDATED — /data encrypted (fscrypt v2), credential-bound via HW gatekeeper

Flash of the `fileencryption=aes-256-xts:aes-256-cts:v2` fstab (staged 2026-07-07,
`device/xiaomi/Mi8937/rootdir/etc/fstab.qcom`, both userdata lines; shares the
existing "pepito-forced shared fstab" bring-up-debt entry):

- Bonus robustness check: Kyle deliberately booted the FBE build over the OLD
  unencrypted /data first → vold correctly refused and **rebooted into recovery
  prompting a factory reset** (the `--wipe` path). After wipe: clean first boot.
- `ro.crypto.state=encrypted`, `ro.crypto.type=file`;
  `/data/unencrypted/mode` = `aes-256-xts:aes-256-cts:v2`.
- `lsattr`: `E` flag on `/data/user/0`, `/data/media/0`, `/data/system_ce/0`,
  `/data/system_de/0`. Zero `-84`/vold/fscrypt errors.
- Setup wizard enrolled a real **PATTERN** through the whole stack on first boot:
  `dumpsys lock_settings` shows LSKF SP protector + **gatekeeper SID** → HW
  gatekeeper enroll + credential-bound synthetic password on an FBE device, end to
  end. (adb `su` gone post-wipe as expected — use `adb root`.)
- ✅ CE-gating check DONE (2026-07-08): after reboot, pre-unlock, root `ls
  /data/system_ce/0` returned fscrypt ciphertext filenames (user 0 = BOOTING);
  after drawing the pattern the same dir reads plaintext (RUNNING_UNLOCKED).
  Credential-bound at-rest encryption proven end to end.

### 2026-07-08 follow-up audit: Brillo 17/17 PASS hardware-enforced; AES reroute is DEAD CODE; one new bug (-29)

- **Full `brillo-platform-test`: 17/17 PASS** — RSA-2048/3072/4096 Sign+Encrypt,
  ECDSA P-224/256/384/521, AES-128/256 (+GCM), HMAC-SHA256 — with the crypto tags
  **hardware-enforced** (only CREATION_DATETIME/USER_ID software). The June-era
  "AES/HMAC only pass software-enforced" state is gone.
- **The `pepito_km1` software-factory reroute is inactive dead code**: it lives in
  `system/keymaster` (the AOSP KM1-bridge path), but the active HAL is the stock
  QTI wrapper (`keymaster@3.0-service-qti`) → keystore2 km_compat → QTI TA
  directly. AES/HMAC already go to the TA and work. Action: revert the
  `system/keymaster` edits as AOSP-tree-debt cleanup (expect no behavior change;
  verify with a system flash + this Brillo suite).
- **Gatekeeper 100%-sure bundle** (pre-upstream evidence): service maps
  `gatekeeper.msm8937.so` via AOSP @1.0-impl and holds `/dev/qseecom`+`/dev/ion`;
  live unlock trace: GK verify → keystore2 `add_auth_token(authType=0x1)` →
  CredentialEncrypted super key unlocked → vold installs fscrypt v2 CE key. The
  accepted auth token proves the GK/KM HMAC agreement at runtime.
  **Upstream framing caveat (Kyle's point, confirmed in source):** the legacy
  block-RPMB path (`CONFIG_MMC_BLOCK_LEGACY_RPMB`) is a pepito-only addition;
  real Mi-Thorium devices use the mainline RPMB **chardev** with inline sbc →
  **Auto-CMD23**, a different (also historically failing, flash #4/#5) engine that
  the Auto-CMD12 fix does NOT touch. So upstream honestly as "sdhci correctness
  fix, validated on a pepito port" — no claim it changes stock Mi-Thorium
  behavior without a test on such a device.
- **NEW BUG found in live logs:** auth-bound **AES-128-GCM generate fails with
  `-29 INSUFFICIENT_BUFFER_SPACE`** from the QTI TA (params: ENCRYPT/DECRYPT,
  GCM, MIN_MAC 96, USER_SECURE_ID=<SID>, USER_AUTH_TYPE=PASSWORD,
  AUTH_TIMEOUT=MAXINT), fired ~1s after unlock; caller not yet identified
  (something in system_server; unlock itself unaffected — likely
  RecoverableKeyStore-adjacent, degrades silently). NO_AUTH AES-GCM passes, so
  it's specific to the auth-bound variant. `-29` smells like another AP-side
  buffer negotiation issue (QSEECom req/rsp buffer?) rather than a TA capability
  limit. Next: identify caller (keystore2 uid logging / trigger via re-lock),
  strace/instrument the QTI wrapper's send_cmd buffer sizes for that op.
- **Attestation: untestable with on-device tooling** — `keystore_cli_v2` has no
  challenge-passing verb; a real test needs a small binder client (or test APK)
  that calls generateKey with ATTESTATION_CHALLENGE and dumps the cert chain.
  Self-signed cert generation (what keystore_cli_v2 exercises) works. Open
  curiosity: does the 2018 TA have provisioned attestation keys (keybox)?

### 2026-07-08 production-prep pass (Kyle: "prepare for a production ROM release, no above-and-beyond")

Scope decisions: metadata encryption DROPPED (above-and-beyond); attestation
client DROPPED (Lineage devices routinely ship without working attestation);
upstream submission HELD (fix helps pepito's legacy block-RPMB path; stock
Mi-Thorium uses the chardev/Auto-CMD23 path we don't touch).

Done this pass:
1. **All AOSP-tree edits reverted to pristine** (production `repo sync` safety):
   `system/keymaster` (5 files: pepito_km1/km3 experiments + logging — dead code,
   active HAL is the QTI wrapper), `system/security` km_compat (pepito_kmcompat
   log spam), `hardware/interfaces` keymaster 3.0 default (unpackaged:
   TARGET_USES_DEVICE_SPECIFIC_KEYMASTER=true) + gatekeeper rc `stdio_to_kmsg`
   (diagnostic; also silences the hal_gatekeeper_default→kmsg_debug denial).
   `system/sepolicy` was already clean.
2. **Dead diagnostic flag removed**: `TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC`
   block in mithorium.mk (its consumer was the reverted KeymasterDevice.cpp).
3. **Kernel qseecom per-command log spam removed** (commit `d48cefc6ac67`):
   pepito_send_cmd enter/scm/exit (~90 lines/boot + every keystore op). Kept the
   one-time load/query alias messages.
4. **qseecom firmware mirror RETIRED** (was dead weight: the keymaster64 alias
   never opens files; TZ rejects the dynamic load anyway, so the mirror had no
   fallback value; it bind-mounted a tmpfs copy over the modem firmware dir every
   boot). Removed: device.mk packaging (rc/sh + 8 keymaster-firmware
   PRODUCT_COPY_FILES), rootdir/Android.bp modules, rootdir rc+sh files (backup
   in session scratchpad `qseecom-mirror-backup/`), sepolicy
   `init_pepito_qseecom.te` + `hal_keymaster_default.te` (dead domain) +
   file_contexts entries + init.te firmware_file/mnt_vendor_file mounton rules.
   **Validation on next flash: keymaster still registers (alias path), and modem/
   WCNSS firmware still loads from the plain vfat /vendor/firmware_mnt/image.**
5. **SELinux rules written for every observed cluster denial** (device stays
   Permissive; enforcing is a later all-subsystem decision):
   - `ro.keymaster.xxx.*` moved PRODUCT_SYSTEM_PROPERTIES→PRODUCT_VENDOR_PROPERTIES
     (they configure a vendor blob) + new `vendor_pepito_keymaster_prop` label
     (Mi8937 property.te/property_contexts) + `get_prop(hal_keymaster_qti, …)` —
     kills the hal_keymaster_qti→default_prop read/open/getattr/map denials the
     compliant way (vendor domains must not read default_prop).
   - mithorium-common: `fsck.te` + sysfs_mmc_host file read (fsck.f2fs reads
     partition/zoned attrs), new `vdc.te` self:capability kill (vdc watchdog),
     new `init-qti-fbe-sh.te` set_prop(vendor_tee_listener_prop) (the
     sys.listeners.registered bridge; flagged as needed since 2026-06-12).
   - RPMB block node verified properly labeled `rpmb_device` — zero tee/qseecomd
     denials; existing QC policy covers it.
   - Re-collect denials after the next flash boot (the mirror removal and rc
     revert eliminate two domains' worth; watch for new init mounton denials for
     the persist mount in case the removed mnt_vendor_file rule was load-bearing).

**`-29` CALLER IDENTIFIED 2026-07-08 — telephony `PinStorage` (SIM-PIN caching);
documented as known issue, NOT a release blocker.**
Method (worth remembering): ftrace `events/binder/binder_transaction` filtered
`to_proc == <keystore2 pid>`, armed pre-unlock across a reboot — each trace line
carries the calling thread's comm/tid, so the generateKey (`code 0x2` on the
IKeystoreSecurityLevel node) showed up as `telephony.worker-2463` (pid 1871,
uid radio, com.android.phone) 25 ms before the keymaster wrapper's failure
reply landed on the exact keystore2 TID that logged the error.
Source: `frameworks/opt/telephony/.../uicc/PinStorage.java` — long-term
SIM-PIN-cache key: AES (no setKeySize → 128) GCM,
`setUserAuthenticationParameters(Integer.MAX_VALUE, AUTH_DEVICE_CREDENTIAL)`,
created in `onUserUnlocked()`, failure swallowed. Every parameter matches the
failing request. Static-hunt exonerations along the way: SyntheticPasswordCrypto
(15 s validity), UnifiedProfilePasswordCache (AES-256), PlatformKeyManager
(imported, non-auth), WifiDpp (CBC), Seedvault (imported, non-auth),
MediaProvider (restart didn't reproduce).
TA-side root cause: QTI KM3 TA/wrapper returns `INSUFFICIENT_BUFFER_SPACE` for
*auth-bound* AES generate (larger characteristics response than the non-auth
variant, which passes) — a response-buffer sizing limit in the stock A8 stack.
**User impact: only "remember SIM PIN across reboot" auto-verify** — with a
PIN-locked SIM the user types the PIN each boot instead of auto-unlock. Zero
impact without a SIM PIN. Fires once per boot at first unlock; no retry loop.
Possible future fixes (above-and-beyond, parked): binary-patch the wrapper's
response buffer (we already binary-patch this blob for configure), or shim
auth-bound AES to km_compat's soft KeyMint. Under enforcing, nothing new to
allow (the call path is ordinary keystore2 traffic).

Device-repo commit state for this pass: Mi8937 `784787cf` (mirror retirement +
prop labeling) and mithorium-common `a486c33` (denial rules) are committed.
Uncommitted remainders ride with other lanes' WIP and need Kyle's curation:
Mi8937 `sepolicy/vendor/file_contexts` + `init.te` (my mirror-entry removals sit
atop pre-existing qmux/gatekeeper edits), mithorium-common `mithorium.mk` (my
diagnostic-flag removal atop qmux edits).

Deferred items:
- **Metadata encryption** (`metadata_encryption=aes-256-xts` via dm-default-key) —
  kernel-ready, deliberately left out of round 1; adding it requires another wipe.
  Kyle Q&A: this is above-and-beyond for legacy Lineage devices (launch-device
  requirement since A10; retrofits exempt; msm89xx Lineage devices don't ship it).
- **SELinux**: write the real rules for this cluster (keymaster props read via
  `default_prop`, `init_pepito_qseecom` tmpfs copy, qseecomd↔RPMB block node,
  vold FBE) while STAYING permissive — enforcing flip is a later decision.
- `Delete User resp->status: -1` noise: Kyle explicitly doesn't care; ignore.
- Software-gatekeeper mk debt / `TARGET_DEVICE_PEPITO` re-scope.

## ✅ 2026-07-07 VALIDATED ON HARDWARE — flash of the Auto-CMD12 fix: ALL GREEN

Boot-only flash of the two staged fixes (kernel built 22:53). Results:

- dmesg: **zero** `-84` / `data error` / `AUTO CMD err` across boot + all tests.
- `keystore_cli_v2 generate --seclevel=tee` → **`GenerateKey: success`** with
  hardware-enforced ALGORITHM/KEY_SIZE/DIGEST/PADDING/ORIGIN/OS_VERSION/OS_PATCHLEVEL.
  `sign-verify` → `Sign: 256 bytes / Verify: OK`; delete clean. The multi-week `-8`
  is gone — first working TEE keygen on this bring-up.
- `cmd lock_settings set-pin / verify / clear` → all three succeed via the
  **hardware** gatekeeper (`android.hardware.gatekeeper@1.0-service`, not
  `.software`). The `-30` enroll failure is gone; RPMB writes (`rpmb_emmc_write
  blk_cnt: 2`) now complete silently. Lock screen / synthetic-password path works.
- Only residue: `gatekeeper_device: Delete User ... resp->status: -1` during
  `clear` — QTI gatekeeper's optional deleteUser op; AOSP treats it as
  non-fatal (clear still succeeded). Cosmetic.

Hardware keymaster + hardware gatekeeper are now BOTH fully functional. Remaining
in this cluster: FBE enablement (below), then re-scope the software-gatekeeper
bring-up debt out of `mithorium.mk` (tree still defaults some variants oddly — see
PLAN.md bring-up-debt list) and the SELinux-enforcing pass.

FBE note: kernel has the fscrypt **v2** keyring backport (`fs/crypto/keyring.c`,
`FS_IOC_ADD_ENCRYPTION_KEY`), so the modern
`fileencryption=aes-256-xts:aes-256-cts:v2` + `metadata_encryption=aes-256-xts`
(dm-default-key present) config is viable.

## 2026-07-07: `-84` ROOT-CAUSED — spurious Auto-CMD12 on RPMB writes; fix staged (boot-only flash)

**TL;DR: the `-84 EILSEQ` was never a bus/CRC problem. It is a *translated Auto-CMD12
failure*: our 4.19 sdhci-msm force-appends Auto-CMD12 to the RPMB CMD25, the card
rejects CMD12 after a CMD23-predefined transfer (JEDEC violation on RPMB), the
controller raises `AUTO_CMD_ERR`, and `sdhci.c` deliberately rewrites that interrupt
as `SDHCI_INT_DATA_CRC` → `data_err=-84`.** Keymaster's `-8 INCOMPATIBLE_BLOCK_MODE`
and gatekeeper's `-30` are both downstream of this RPMB write failure.

Evidence chain (all live on `c39a6acf`, no flash needed):

1. Live correlation: `keystore_cli_v2 generate --seclevel=tee` → qseecomd
   `rpmb_emmc_write blk_cnt:2` → ioctl errno **84** → `rpmb_emmc_read` errno 84 →
   `KeyMasterHalDevice generate_key resp->status: -8`. The TA error is RPMB fallout.
2. CQHCI-crypto hypothesis (2026-06-29/07-02, below) **falsified on hardware**: the
   running kernel (built 2026-07-07) already has `CONFIG_MMC_CQHCI_CRYPTO_QTI` unset
   and still throws `-84`.
3. Clock-scaling hypothesis **falsified**: `echo 0 > /sys/class/mmc_host/mmc0/clk_scaling/enable`
   → still `-84`. (Errors also occur at both DDR52\@52MHz and HS200\@200MHz.)
4. ftrace `mmc:mmc_request_start/done` during a keygen (capture:
   scratchpad `mmc-trace.txt`, worth re-capturing if needed) shows a **flawless JEDEC
   sequence**: CMD6(CMDQ_EN=0) → CMD6(PARTITION_CONFIG→RPMB) → **CMD23 arg
   0x80000002** (rel-write, count 2) → CMD25 blocks=2 → `data_err=-84,
   bytes_xfered=0`. So the framing/sequence is correct; the failure is injected at
   the host-controller layer.
5. SDHCI register dump during failure: `Trn mode 0x27` = **Auto-CMD12 enabled** on a
   predefined-count transfer. Next command's R1 carries `0x400900`
   (ILLEGAL_COMMAND) — the card complaining about the trailing CMD12.
6. Source delta: our `sdhci-msm.c:5678` sets `SDHCI_QUIRK_MULTIBLOCK_READ_ACMD12`
   (from the kona snapshot's quirk boilerplate) → `SDHCI_AUTO_CMD12` host flag.
   **Stock Palm 3.18 `sdhci-msm.c` never sets that quirk** (verified in
   `Pepito_GPL_SourceCode`), so stock RPMB writes carry no auto command at all.
   `sdhci_auto_cmd12()` only checked `!mrq->sbc`, and the RPMB ioctl path is the one
   place that issues multi-block commands with *neither* sbc *nor* stop.
7. This unifies the flash #4/#5 history: Auto-CMD**23** (inline sbc) failed with
   AUTO CMD err; the explicit-CMD23 fix moved the trailing violation to
   Auto-CMD**12**. Every auto-command variant fails on this eMMC's RPMB; stock uses
   none. CQE traffic never uses ACMD12, which is why only RPMB/ioctl I/O suffered.
   Legacy reads (CMD8) are single-block → no ACMD12 → always worked.

**Fixes staged in `kernel/xiaomi/msm8937` (kernel-only → boot-only build):**

- `drivers/mmc/host/sdhci.c` — `sdhci_auto_cmd12()` now also requires `mrq->stop`:
  Auto-CMD12 is a hardware stand-in for a requested stop command; never emit it for
  requests that didn't ask for one. Surgical: only affects sbc-less+stop-less
  requests, i.e. exactly the RPMB/raw-ioctl path; SD-card and normal eMMC I/O
  (which always set stop or sbc) are untouched. The AUTO_CMD_ERR→data-CRC
  translation site now uses the same helper.
- `drivers/mmc/core/block.c` — second latent bug found while diffing stock:
  `mmc_blk_ioctl_rpmb_cmd()` executed all 3 command slots unconditionally. Stock
  3.18 stops at the first empty slot (`if (!curr_cmd->opcode) break`). librpmb
  reads use 2 slots; the zeroed third slot went out as CMD23(count=0) + raw
  **CMD0 (GO_IDLE)** — resetting the card mid-transaction. Now: peek opcode with
  `get_user`, break on empty, pass the real count as `ioc_count`. (This one never
  got a chance to fire because the write/first CMD25 always died first; it WILL
  fire on 2-slot reads once ACMD12 is fixed, so both fixes must ship together.)

**Validation after boot-only flash** (HW gatekeeper service is already the active
default on the device — `android.hardware.gatekeeper@1.0-service`, pid 915):

```bash
adb shell 'dmesg | grep -cE "data error -84|error: -84"'          # expect 0
adb shell 'keystore_cli_v2 generate --name=tee-test --seclevel=tee'  # expect no -8
adb shell 'keystore_cli_v2 delete --name=tee-test'
adb shell 'cmd lock_settings set-pin 1234'                        # enroll: expect no -30
adb shell 'cmd lock_settings verify --old 1234'                   # expect success
adb shell 'cmd lock_settings clear --old 1234'
adb shell 'logcat -d | grep -iE "rpmb_emmc|gatekeeper_device|KeyMasterHal"'
```

If keygen still returns `-8` with zero RPMB errors in dmesg/logcat, only then does
the old TA-parameter theory (2026-06-23 `pepito_kmcompat` dump) come back into play.
Note: some earlier "failed" RPMB writes may have actually programmed (the fake -84
fired after the data phase), so the TA may resync its write counter on first use —
one-time counter-mismatch messages are expected noise.

**Next phase after RPMB is green — userdata encryption (FBE).** Current state:
`ro.crypto.state=unsupported`; fstab.qcom mounts `/data` plain (no
`fileencryption=`). Kernel is already fully FBE-capable (verified via
`/proc/config.gz`): `CONFIG_FS_ENCRYPTION`, ext4/f2fs encryption,
`CONFIG_DM_DEFAULT_KEY` (metadata encryption), `CONFIG_FS_ENCRYPTION_INLINE_CRYPT`.
CPU has ARMv8-CE (`aes pmull sha2`) so `aes-256-xts:aes-256-cts` is
hardware-accelerated on-CPU; ICE inline crypto is NOT available (qti CQHCI crypto
compiled out, init failed -19 against Palm TZ — do not re-enable). Plan: add
`fileencryption=aes-256-xts:aes-256-cts` (+ decide v1 vs v2 policy per what this
4.19 tree supports, and whether to add `metadata_encryption=` via dm-default-key)
to the userdata line, wipe userdata, verify `ro.crypto.state=encrypted` and
file-name garbling in `/data/user/0` from recovery.

## 2026-06-29: eMMC `-84` (EILSEQ) + CQHCI crypto init failure sit beneath the RPMB errno-22 story

Re-reading `serial.log.19` (full boot, reaches `sys.boot_completed=1` at t≈216s), there is a
layer of errors this plan never accounted for and which is a more likely root cause of the
RPMB read failures than the `MMC_IOC_RPMB_CMD` ioctl-compat gap documented below.

**(a) CQHCI inline crypto never initializes at boot (err -19 = ENODEV):**
```
serial.log.19:588  [158.461861] cqhci_crypto_qti_init_crypto: Error initiating crypto capabilities, err -19
serial.log.19:590  [158.470511] mmc0: CQHCI version 5.10 Crypto init failed err -19
```
Inline eMMC crypto is unavailable for the whole boot. If RPMB frames depend on the crypto
context (key slot / realigned buffer), the errno-22 `rpmb_emmc_read` failures are a downstream
symptom, not the primary fault. **The ioctl-compat fix re-exposed the block node but never
addressed this.**

**(b) `data txfr error: -84` (EILSEQ = CRC failure) fires on the RPMB ioctl path during every
keymaster operation**, clustered exactly around `QSEECOM __qseecom_send_cmd` /
`vdc keymaster earlyBootEnded`:
```
serial.log.19:1469 [172.486] mmc0: data txfr (0x00200000) error: -84 after 0 ms   <- during vdc keymaster earlyBootEnded (pid 571, :1462)
serial.log.19:1538 [172.887] sdhci_msm 7824900.sdhci: __mmc_blk_ioctl_cmd: data error -84
serial.log.19:1819 [175.770] mmc0: data txfr (0x00200000) error: -84 after 0 ms   <- next QSEECOM keymaster cmd (:1817)
serial.log.19:1888 [176.171] __mmc_blk_ioctl_cmd: data error -84
serial.log.19:3508 [207.052] mmc0: data txfr error: -84                           <- post-boot keymaster op (:3498)
serial.log.19:3672 [207.728] __mmc_blk_ioctl_cmd: data error -84
```
`EILSEQ` is a bus-level CRC error — the RPMB data being returned to `librpmb` is corrupt,
which would explain the TZ rejecting the load (`scm_call to load app failed`, errno 22)
independently of the ioctl ABI.

**Implication for the existing analysis below:** the chardev→block→ioctl→CQE→Auto-CMD23 chain
(§C cluster) is necessary but not sufficient. Crypto init `-19` + bus CRC `-84` need to be
investigated *first*.

**ANSWERED (2026-07-02, `PLAN-tz.md`): CQHCI crypto is a 4.19-only path — disable it.**
Stock 3.18 has `CONFIG_MMC_CQ_HCI=y` but no `cqhci-crypto-qti.c`/`crypto-qti-tz.c`; it never
initializes inline crypto and its RPMB works without it. Our tree added that path; its init
fails (`err -19`) against Palm TZ and leaves CQHCI half-initialized. Fix = match stock: remove
`"cqhci_ice"` from the `sdhc_1` `reg-names` (DTS) or compile the qti crypto driver out, then
re-test whether the `-84 EILSEQ` RPMB CRC errors clear. (Note: the repeated
`scm_call failed: func id 0x72000206` lines are NOT this — that's qseecomd's
smcinvoke-listener probe with a benign fallback, see the 2026-06-14 note near the end of
this file.)

## 2026-06-23: Active blocker is the RPMB device-node type (qseecomd), not keymaster

The keymaster/AES/cert work below is no longer the live blocker. A later boot
(`serial.log.17`) crash-loops before `sys.boot_completed`, and the cause is
upstream of keymaster:

- `vendor.qseecomd` crash-loops, **exiting status 255** every ~5s (43 restarts in
  the captured log). With no qseecomd, QSEE listeners never register, so
  `android.hardware.keymaster@3.0::IKeymasterDevice/default` never registers
  (init logs "Could not find ..." 199 times), so `android.security.maintenance`
  (keystore2) can't start, so vold stalls at `late-fs`/`post-fs-data` and boot
  loops. The keymaster "could not find" spam and the earlier camera-HAL
  tombstones in `/data` are downstream symptoms / stale state, not the cause.
- The `batched_hyp_assign: Failed ... ret=-95` / `scm_call failed func id
  0x2000c16` kernel lines are benign: they appear 6x in the known-good
  `serial.log.15` too.

Root cause, recovered from `pmsg-ramoops-0` (the recovery-root pstore dump we
already had; no new tooling needed):

```text
QSEECOMD: Init dlopen(librpmb.so, RTLD_NOW) succeeds
QSEECOMD: Init::Init dlsym(g_FSHandle, rpmb_init_service) succeeds
rpmb_emmc Error finding /dev/block/mmcblk0rpmb (error no: 2)
DrmLibRpmb Error: rpmb_init failed! with ret = 2
QSEECOMD: Init rpmb_init_service ret = 2
QSEECOMD: ERROR: RPMB_INIT failed, shall not start Listener services
```

The stock Android 8 QTI qseecomd / `librpmb.so` (`DrmLibRpmb`) opens the eMMC
RPMB area at the **legacy block-device path `/dev/block/mmcblk0rpmb`**. The 4.19
kernel instead exposes RPMB through the post-4.4 **character-device** framework:
live recovery shows `crw------- 500,0 /dev/mmcblk0rpmb` (kernel: `mmcblk0rpmb:
mmc0:0001 ... chardev (500:0)`, `/proc/devices: 500 rpmb`), and no
`/dev/block/mmcblk0rpmb`. So `rpmb_init` fails with ENOENT and qseecomd refuses
to start. `serial.log.15` (which booted) must have had a working qseecomd/RPMB
path; the regression dropped the block node (user's best guess: an ad-hoc vendor
change overwritten by `make`).

### Fix in tree: Option A - expose RPMB as a legacy block device (kernel)

Implemented in `kernel/xiaomi/msm8937`:

- New Kconfig `CONFIG_MMC_BLOCK_LEGACY_RPMB` (default n) in
  `drivers/mmc/core/Kconfig`; enabled via `CONFIG_MMC_BLOCK_LEGACY_RPMB=y` in
  `arch/arm64/configs/mi8937_defconfig`.
- `drivers/mmc/core/block.c`: when the option is set, `mmc_blk_alloc_parts()`
  allocates the RPMB area as a real block device via `mmc_blk_alloc_part()`
  (so `/dev/block/mmcblk0rpmb` exists) instead of the RPMB chardev. RPMB frames
  still ride `MMC_IOC_*_CMD`; `__mmc_blk_ioctl_cmd()` and the `drv_op` handler now
  treat `md->area_type & MMC_BLK_DATA_AREA_RPMB` as RPMB (partition switch via
  `md->part_type`, reliable-write SBC, busy-poll, and switch-back-to-main), so a
  `rpmb=NULL` block-fop ioctl is routed to the RPMB partition exactly like the
  chardev path. Block-only RPMB is the pre-4.4 layout the stock blobs expect.

This is **kernel-only**, so a `--boot-only` build is enough to test.

**CONFIRMED on hardware (flash + live adb):** `/dev/block/mmcblk0rpmb` now exists
as a block device (`brw- 179:32`); the RPMB chardev `/dev/mmcblk0rpmb` is gone.
`vendor.qseecomd` stays running (no exit-255 loop), and `lshal` shows
`android.hardware.keymaster@3.0::IKeymasterDevice/default` (QTI, pid 735) plus
`android.hardware.gatekeeper@1.0` (pid 1113) and all `android.security.*` AIDL
services registered. The keymaster/keystore/vold cascade is fully unblocked.

Caveats / follow-ups:

- `mi8937_defconfig` is shared by mithorium variants; this currently flips RPMB to
  block-device for all of them. If any non-pepito variant relies on the RPMB
  chardev, scope this to pepito (defconfig fragment) instead.
- SELinux/ueventd: the new `/dev/block/mmcblk0rpmb` block node needs a label and
  perms qseecomd can open. It worked under the current global-permissive
  diagnostic; re-verify there is no avc/open denial before enforcing SELinux.

### Next blocker after RPMB: GPU CP microcode downgrade (FIXED)

With RPMB fixed the device booted far enough for adb root but crash-looped before
`sys.boot_completed`: SurfaceFlinger aborted in
`SkiaGLRenderEngine::chooseEglConfig` with `eglInitialize ... EGL_BAD_ALLOC`,
because the kernel GPU never came up:

```text
kgsl kgsl-3d0: GPU PAGE FAULT addr=FCCC7000 pid=0 (write permission fault)
kgsl kgsl-3d0: CP initialization failed to idle
Adreno-GSL: open(/dev/kgsl-3d0) failed: errno 110 (ETIMEDOUT)
```

Root cause: the Adreno A506 CP microcode `a530_pm4.fw` / `a530_pfp.fw` had been
**downgraded to the stock Android 8 (3.18-era) version**, which the 4.19 LineageOS
kgsl driver cannot init. Evidence:

- Device + `vendor/xiaomi/Mi8937/proprietary/.../a530_pm4.fw` (dated 2026-06-16
  21:17) matched the stock backup
  (`backup-stock-android-8.1-AML0/vendor.bin.extracted/firmware/a530_pm4.fw`,
  sha `6419f3...`); CP version words `PM4=0x5FF063 / PFP=0x5FF087`.
- `out/target/product/Mi8937/vendor/firmware/a530_p*.fw` (dated 2026-06-05) was a
  newer build, `PM4=0x5FF066 / PFP=0x5FF114` (sha `a02c9b...` / `072cbb...`).
- `serial.log.15` (2026-06-16 ~11:56) reached the setup screen with the newer
  `out/` ucode; the proprietary blob was swapped to the stock ucode at 21:17 the
  same day (after that good boot). Same "blob swapped/overwritten" pattern as RPMB.
- Note: zap was a red herring - a5xx loads the zap by name (`.zap_name =
  "a506_zap"`, files present), not via a DT node, so the missing `zap-shader` DT
  node is not the issue.

Fix: restore the newer ucode. Live test (adb push of the `out/` ucode into
`/vendor/firmware`, restorecon, reboot) **booted to `sys.boot_completed=1` at ~30s**
with `AdrenoGLES-0: PFP: 0x005ff114, ME: 0x005ff066`, no CP/PAGE FAULT, SF stable,
`system_server.start_count=1`. Made permanent by copying the `out/` ucode over
`vendor/xiaomi/Mi8937/proprietary/vendor/firmware/a530_p{m4,fp}.fw` (the broken
stock copies are saved as `*.stock-3.18-bak`). These are installed via
`Mi8937-vendor.mk` `PRODUCT_COPY_FILES` (not extract-files), so a normal build
ships them. Do not let an extraction/blob re-pull put the stock 3.18 ucode back.

### State as of 2026-06-23 (both fixes in): device boots fully

`sys.boot_completed=1`, qseecomd/keymaster/gatekeeper/keystore2 healthy, GPU/SF up,
SELinux still **Permissive** (diagnostic). Remaining known issues, none blocking
boot:

- `android.hardware.camera.provider-service_32.lineage` crash-loops with SIGSEGV
  null-deref in `CameraModule::notifyDeviceStateChange()+4` (camera HAL; off the
  boot-critical path).
- Several vendor daemons fail to link (missing libs): `rmt_storage`
  (`libCheckTunning.so`), `pm-service` / `tftp_server` (`libsmemlog.so` via
  `libqmi_csi.so`), `ATFWD-daemon`
  (`vendor.qti.hardware.radio.atcmdfwd@1.0_vendor.so`), `mm-qcamera-daemon`
  (`libmmcamera2_mct.so`). Vendor blob packaging gaps.
- SELinux is still permissive from the bring-up diagnostic; re-verify RPMB node
  access and keymaster property reads before re-enabling enforcing.

### TEE keystore2 validation on the booted device (2026-06-23): new blocker

With the device fully up, ran the disposable TEE key test
(`keystore_cli_v2 generate --name=pepito-tee-test --seclevel=tee`). Result is a
**new, much-later failure** that supersedes the old `-62 KEY_REQUIRES_UPGRADE` /
`export_key` chain:

```text
KeyMasterHalDevice: generate_key_common
KeyMasterHalDevice: ret: 0           # SCM/QSEE call succeeds - whole RPMB->QSEE->KM path works
KeyMasterHalDevice: resp->status: -8 # QTI TA returns KM_ERROR_INCOMPATIBLE_BLOCK_MODE
keystore2: Error::Km(r#INCOMPATIBLE_BLOCK_MODE)  (status -8, rc 248)
```

Interpretation: the stock Pepito QTI keymaster TA now *executes* `generate_key`
over a healthy SCM path and rejects the **Android-16 keystore2 RSA-2048 SIGN
parameter set** with `KM_ERROR_INCOMPATIBLE_BLOCK_MODE` (-8). RSA signing has no
block mode, so this is an Android-16-keystore2 <-> stock-KM-TA parameter
compatibility problem in the QTI KM1/KM3 wrapper, not a QSEE/RPMB/load failure.

Caveats for the next session:
- `keystore_cli_v2` in this build ignores `--algorithm` (all of
  `--algorithm=ec`/`aes` ran the identical default RSA-2048 params), so only RSA
  was exercised. EC/AES/HMAC still unvalidated; need correct CLI flags or the
  VTS/`brillo-platform-test` harness.
- Next lead: capture the exact param set the QTI wrapper hands the TA
  (`pepito_km3`/`pepito_km1` diagnostics) and compare against the Android 11 GSI
  stock-vendor reference generate; suspect a tag the modern keystore2 sends
  (e.g. an unexpected BLOCK_MODE/CALLER_NONCE/attestation tag, or padding/digest
  handling) that the stock KM TA validates incorrectly for asymmetric keys.

### Lock screen confirmed broken on CLEAN /data (2026-06-23) → need hardware gatekeeper

After a full flash + factory reset, set PIN `1234` and verified it (`cmd lock_settings
verify --old 1234`): still fails identically — `SyntheticPasswordCrypto.decryptBlob`
→ `Cipher.init` → `android.security.keystore.UserNotAuthenticatedException`. This
is on freshly-created credential material, so it is **not** stale `/data`; a factory
reset does not fix it. keystore2 logs show software gatekeeper *does* mint auth
tokens (`add_auth_token authType=0x1`), but the QTI keymaster TA rejects them →
the two don't share the auth-token HMAC. (User-visible symptom: Settings crashes
when confirming the PIN to open Developer Options.)

Decision: **go hardware** for both halves. Until fixed, leave the screen lock as
None — any credential bricks the verify path (and risks a synthetic-password boot
crash loop).

### Next debugging round (set up 2026-06-23): HW gatekeeper + keygen param dump

Two changes staged; needs a **full flash** (system + vendor):

1. **Hardware gatekeeper.** The RPMB fix made QSEE healthy, so the earlier
   gatekeeper QSEE-load abort should be gone. Build with
   `TARGET_PEPITO_HARDWARE_GATEKEEPER_DIAGNOSTIC=true` — this swaps software
   gatekeeper for the AOSP `android.hardware.gatekeeper@1.0-service` +
   `gatekeeper.msm8937.so` and adds the gatekeeper VINTF fragment. Both that
   passthrough and the QTI keymaster TA go through the same QSEE gatekeeper/keymaster
   app, so they should now share the auth-token HMAC. If the AOSP service still
   aborts, fall back to packaging the **stock QTI gatekeeper wrapper**
   (`android.hardware.gatekeeper@1.0-service-qti` + `-impl-qti.so` + rc, present in
   the AML0 backup) mirroring the keymaster wrapper — note the gatekeeper impl does
   NOT need the keymaster property-spoof fixup (no version/configure strings in it).

2. **Keygen `-8` instrumentation.** Added `pepito_kmcompat` logging in
   `system/security/keystore2/src/km_compat/km_compat.cpp::KeyMintDevice::generateKey`:
   dumps every *legacy/keymaster* `KeyParameter` (tag + bool/int/long) handed to the
   QTI HAL plus the raw HAL error. This is the keystore2↔keymaster3 bridge
   (`convertKeyParametersToLegacy`), the spot where a bad/extra tag would cause
   `INCOMPATIBLE_BLOCK_MODE`. Diff the dumped tags against a clean RSA-sign set.

Capture after the next boot:

```bash
# gatekeeper now hardware?
adb shell 'lshal | grep -i gatekeeper'          # expect NOT *.software
adb shell 'ps -A | grep gatekeeper'
# lock screen auth path works now?
adb shell 'cmd lock_settings set-pin 1234; cmd lock_settings verify --old 1234'
# keygen param dump
adb shell 'logcat -b all -c'; adb shell 'keystore_cli_v2 generate --name=t --seclevel=tee'
adb shell 'logcat -b all -d | grep -iE "pepito_kmcompat|KeyMasterHalDevice"'
```

### Round results (2026-06-23, flash #2)

- **Gatekeeper flag did NOT apply** — `ps` still showed
  `android.hardware.gatekeeper@1.0-service.software`. The
  `TARGET_PEPITO_HARDWARE_GATEKEEPER_DIAGNOSTIC=true` env var didn't propagate
  through the build. **Fix:** made hardware gatekeeper the *tree default* for
  pepito (`mithorium.mk` + `BoardConfigCommon.mk`); software is now opt-in via
  `TARGET_PEPITO_SOFTWARE_GATEKEEPER=true`. Re-flash to actually test the
  lock-screen fix. The dead `TARGET_PEPITO_HARDWARE_GATEKEEPER_DIAGNOSTIC` flag is
  no longer referenced.

- **Keygen `-8`: param translation is CLEAN — the QTI TA is the culprit.** The
  `pepito_kmcompat` dump shows exactly the legacy params handed to the HAL for an
  RSA-2048 SIGN key:
  `ALGORITHM=RSA, KEY_SIZE=2048, RSA_PUBLIC_EXPONENT=65537, PURPOSE=SIGN+VERIFY,
  DIGEST=SHA-224/256/384/512, PADDING=PKCS1_1.5_SIGN+PSS, NO_AUTH_REQUIRED`.
  No BLOCK_MODE, nothing malformed. The QTI TA returns `resp->status:-8`
  (`KeyMasterHalDevice generate_key_common`), and km_compat logs
  `generateKey HAL raw error=-8`. So `INCOMPATIBLE_BLOCK_MODE` is the **stock QTI
  3.0 TA rejecting a valid modern keygen**, not a bridge/translation bug. The same
  TA generated RSA fine under Android 11 (legacy keystore, no km_compat) — so the
  difference is the A12+ keystore2/KeyMint→km3 path, or TA boot-state/provisioning
  (RoT/configure), not the key params.

Keygen next leads (after gatekeeper is confirmed):
- Bisect the param set the TA accepts (single digest, single padding, single
  purpose; with/without NO_AUTH_REQUIRED) to find the exact rejected element —
  needs a param-controllable path (VTS keymaster test, or a temporary km_compat
  experiment), since `keystore_cli_v2` has no param flags and ignores `--algorithm`.
- Compare against the Android 11 stock-vendor reference generate params
  (`debug/android11-gsi-keymaster-reference/`).
- Check TA boot-state: whether RoT/`configure`/OS-patchlevel provisioning on this
  boot matches what the TA needs to accept asymmetric generate.

### Round results (2026-06-23, flash #3): HW gatekeeper runs; real blocker = RPMB ioctl

Hardware gatekeeper is now the default and **running**
(`android.hardware.gatekeeper@1.0-service` pid 900, not `.software`). But
`cmd lock_settings set-pin` now fails at *enroll*
(`Failed to enroll LSKF for new SP protector`), and the cause is concrete:

```text
gatekeeper_device: Enroll send cmd failed   ret: 0   resp->status: -30
rpmb_emmc: rpmb_emmc_read: Error sending ioctl -1 (error no: 22)   # EINVAL
```

Both keymaster and gatekeeper drive the same preloaded `keymaster` app (id 65537);
the gatekeeper enroll makes a QSEE listener callback (`resp.result=1`) that needs
RPMB, and the **RPMB read ioctl fails with EINVAL**. qseecomd has CAP_SYS_RAWIO
(`CapEff` bit 17 set), so it's not perms. Root cause: our Option-A RPMB **block
device** is openable (so qseecomd starts), but the 4.19 block fop `mmc_blk_ioctl`
only handled `MMC_IOC_CMD`/`MMC_IOC_MULTI_CMD` — the **legacy `MMC_IOC_RPMB_CMD`**
that the stock Android-8 `librpmb` uses (still defined in
`uapi/linux/mmc/ioctl.h`: `struct mmc_ioc_rpmb`, `MMC_IOC_MAX_RPMB_CMD=3`) was
dropped in the RPMB→chardev conversion → hit `default: -EINVAL`. So the keymaster
`-8` / gatekeeper `-30` were RPMB-I/O failures, not param or TA-provisioning bugs.

Fix (kernel-only, in tree): re-added `mmc_blk_ioctl_rpmb_cmd()` and a
`case MMC_IOC_RPMB_CMD:` to `drivers/mmc/core/block.c`, gated by
`CONFIG_MMC_BLOCK_LEGACY_RPMB` (runs the 3 RPMB frames on the RPMB partition; RPMB
routing comes from `md->area_type`). **Boot-only flash** is enough (HW gatekeeper +
km_compat logging are already on the device).

Build gotcha hit here: editing `mi8937_defconfig` forced a `.config` regen that
exposed a pre-existing defconfig/`.config` drift — the defconfig had
`# CONFIG_QRTR is not set` but `CONFIG_QCOM_QMI_HELPERS=y` (which `depends on QRTR`),
so QMI helpers got dropped and slimbus/diag (built-in) failed to link
(`undefined symbol: qmi_handle_init`, `qmi_send_request`, `qmi_response_type_v01_ei`,
…). Earlier builds only linked because they reused a stale `.config` with
`CONFIG_QRTR=y`. Fixed by restoring the `CONFIG_QRTR=y`/`QRTR_SMD=y` block in
`mi8937_defconfig` (matches the known-good `.config`). Unrelated to the MMC change.

Expected next boot: no `rpmb_emmc_read ... ioctl ... error no 22`; gatekeeper
`Enroll` returns 0; `cmd lock_settings set-pin 1234; verify --old 1234` succeeds;
and keymaster generate may also clear `-8` if it too was RPMB-blocked (watch the
`pepito_kmcompat`/`KeyMasterHalDevice` lines). If RPMB I/O now reaches the TA but
returns a protocol error (not ioctl EINVAL), the next suspect is RPMB
authentication-key provisioning.

Capture:
```bash
adb shell 'cmd lock_settings set-pin 1234; cmd lock_settings verify --old 1234; cmd lock_settings clear --old 1234'
adb shell 'dmesg | grep -iE "rpmb|gatekeeper_device"'
adb shell 'logcat -b all -c; keystore_cli_v2 generate --name=t --seclevel=tee; logcat -b all -d | grep -iE "pepito_kmcompat|KeyMasterHalDevice|rpmb"'
```

### Round results (2026-06-24, flash #4): RPMB ioctl now routed; MMC-level timeout

The `MMC_IOC_RPMB_CMD` handler works — the RPMB read errno changed **22 (EINVAL) →
110 (ETIMEDOUT)**, i.e. the ioctl is now accepted/routed but the MMC transaction
times out. dmesg shows the real cause:

```text
sdhci_msm: AUTO CMD err sts 0x00000002          # Auto-CMD timeout
sdhci_msm: __mmc_blk_ioctl_cmd: cmd error -110
mmc0: mmc_blk_part_switch: switch failure, 3 -> 0   # RPMB->main switch stuck after
```

Root cause: a defect in the drv_op handler (`mmc_blk_mq_issue_drv_op`). The switch
disabled the command queue (CQE) only for `MMC_DRV_OP_IOCTL`; `MMC_DRV_OP_IOCTL_RPMB`
reached the body via fallthrough and **never disabled CQE**. This eMMC has CQE
enabled ("Command Queue Engine enabled"), so RPMB frames were issued with the
command queue active → sdhci AUTO CMD timeout → stuck partition switch. (Latent for
the chardev RPMB path too; only exposed now that RPMB I/O actually runs.)

Fix (kernel-only, in tree): merged the `MMC_DRV_OP_IOCTL` / `MMC_DRV_OP_IOCTL_RPMB`
cases so RPMB also `mmc_cmdq_disable()`s before the access and re-enables after.
Boot-only flash. Build gotcha from flash #4 prep: restoring `CONFIG_QRTR=y` in
`mi8937_defconfig` (defconfig/.config drift exposed by the regen; see above).

### Round results (2026-06-24, flash #5): CQE fix worked; now Auto-CMD23 on RPMB

The CQE fix cleared the `AUTO CMD err` — but RPMB still timed out (`-110`), now as:
`sdhci_msm: error -110 requesting status`, `mmc_blk_part_switch: switch failure,
3 -> 0`, `cache flush error -110`, then `mmc_blk_reset(MMC_BLK_PARTSWITCH)
succeeded` (controller recovers via reset). The failure moved one layer deeper.

Root cause: `__mmc_blk_ioctl_cmd()` issued the RPMB `SET_BLOCK_COUNT` as an **inline
`mrq.sbc`**, which on sdhci-msm engages the **Auto-CMD23 hardware engine** that the
eMMC RPMB partition rejects → command/status timeout and stuck partition switch.
The stock 3.18 driver that works with this exact vendor `librpmb`
(`.../kernel_src/drivers/mmc/card/block.c::mmc_blk_ioctl_rpmb_cmd`) instead issues
an **explicit standalone `mmc_set_blockcount()` (CMD23)** per command.

Fix (kernel-only, in tree): in `__mmc_blk_ioctl_cmd()`, for RPMB call
`mmc_set_blockcount(card, data.blocks, write_flag & BIT(31))` explicitly instead of
setting `mrq.sbc` (removed the now-unused `sbc`). Matches the proven 3.18 path and
avoids Auto-CMD23. Boot-only flash.

RPMB layers peeled so far: node missing (chardev→block) → ioctl unhandled
(`MMC_IOC_RPMB_CMD`) → CQE not disabled → Auto-CMD23. Next error (if any) on
`rpmb_emmc_read` that is NOT a transport timeout would point at RPMB
authentication-key provisioning.

## Current conclusion

Keep software gatekeeper as the default flashed image for now, but hardware
keymaster is now proven active on the current 4.19 Lineage kernel. The stock
reference showed Pepito does not dynamically load the partition-derived
`keymaster.mdt` in Linux; APPSBL/TZ already has `keymaster64` loaded. The current
kernel compatibility path aliases userspace `keymaster` to preloaded
`keymaster64`, returns stock-like `app_arch=0`, and QSEE commands from the
registered keymaster HIDL service complete successfully.

`serial.log.11` reached `sys.boot_completed=1`, so the original secure-loader
and service-start failures are no longer the active blocker. The remaining
restart loop is later in framework unlock: locksettings asks keystore2 to use an
AES/GCM synthetic-password key, QTI KM1 returns `KM_ERROR_KEY_REQUIRES_UPGRADE`
(`-62`) from `get_key_characteristics` on a 427-byte key blob, and keystore2
then fails the attempted upgrade with the same error. This happens before the
AOSP wrapper can inspect or rewrap the key, which means existing QTI-owned AES
key blobs in `/data` are not recoverable through the KM1 wrapper.

The AES/HMAC boot fix is now validated on clean data: fresh locksettings and
keystore material no longer crash-loop, normal-mode adb root is available, and
the keymaster HIDL process holds `/dev/qseecom` plus `/dev/ion`. Software
gatekeeper remains the registered gatekeeper service while this is debugged.

The active blocker has moved to asymmetric key export/cert creation. With the
AOSP KM1 bridge, RSA and EC hardware generation both reach QSEE and return
`error=0`; the generated/imported QTI raw blobs are then wrapped in AOSP
integrity-assured blobs with current `OS_VERSION=160000` and
`OS_PATCHLEVEL=202605`. Keystore2 immediately calls HIDL `exportKey(X509, ...)`
to make a self-signed certificate, and QTI KM1 `export_key` returns
`resp->status=-62` / `KEY_REQUIRES_UPGRADE` for both RSA and EC. This is no
longer a QSEE load, SELinux, or firmware-staging failure.

Current source experiment: package Pepito's stock Android 8 QTI keymaster HIDL
wrapper/service (`android.hardware.keymaster@3.0-service-qti`,
`android.hardware.keymaster@3.0-impl-qti.so`, `libkeymasterdeviceutils.so`, and
`libkeymasterutils.so`) plus `android.hardware.keymaster@3.0.vendor` for
`TARGET_DEVICE_PEPITO=true`, and set `TARGET_USES_DEVICE_SPECIFIC_KEYMASTER=true`
so the common AOSP
`android.hardware.keymaster@3.0-service` is omitted. The theory is that the
stock QTI wrapper performs version/configuration handling that the AOSP KM1
bridge does not expose to the vendor KM1/TA path.

## Next Steps

  - `/dev/block/by-name/keymaster` on the live device matches stock
    `keymaster.bin` exactly:
    `76959e5db20f3fce8df3a22befd3bc8cf3799fbda09b229cbdf1fc101dc66e6b`.

  - The split `keymaster.mdt` + `keymaster.b00`...`b06` files in the tree are
    byte-for-byte segment extracts from that same stock partition image. The
    payload bytes being given to QSEECom are not a non-Pepito app.

  - The pepito DTS now matches stock for the QSEE-visible pieces that looked
    suspicious: app window `0x84a00000 / 0x1900000`, no `qseecom_ta_region`, no
    ION heap 19, and no inherited `qcom,commonlib64-loaded-by-uefi`. The latest
    boot confirmed `commonlib64=0` and no early `qseecom_ta_region` reservation.

  - Stock Pepito `libQSEEComAPI.so` + `keystore.msm8937.so` still reach the same
    secure-loader rejection, so blob mismatch is no longer the strongest lead for
    the keymaster load failure. Gatekeeper blob compatibility remains unproven.

  - Stock 3.18 and current 4.19 qseecom send the same high-level
    `QSEOS_APP_START_COMMAND` fields. The first major driver delta tested was
    buffer handoff: stock used `ion_phys()` plus `ION_IOC_CLEAN_INV_CACHES`;
    current uses dma-buf/SG via `sg_dma_address()` and
    `qseecom_dmabuf_cache_operations()`.

  - The keymaster-only coherent-buffer diagnostic still failed with the same
    secure-loader rejection. The kernel logged a copied ELF header in the
    coherent buffer and then received `ret=-22` / `resp.result=-38`. That makes
    dma-buf/SG/cache coherency unlikely as the primary blocker.

  - SMC32-first was tested and produced app-start function id
    `0x32000101`, but TZ still returned `ret=-22` / `resp.result=-38`. That
    rules out SMC64-vs-SMC32 alone as the blocker. The clean retest without the
    coherent-copy override also failed from the normal QSEECom heap, with
    `pa == sg_dma == sg_phys`, so neither the copied coherent buffer nor the
    normal heap buffer is accepted by TZ.

  - The keymaster buffer-window diagnostic confirms QSEEComAPI assembled the
    expected compact `.mdt` plus appended `.b00`/`.b01` metadata and `.b02`
    payload layout. The all-zero `alloc-16` bytes are page-aligned padding beyond
    `img_len`, not corrupted image data. Current source now logs `img-16` and
    `alloc-16` separately so the next boot can confirm the real image tail.

  - A fuller serial window shows the same keymaster load failure being triggered
    during vold/storage setup, while `fsck.f2fs` is starting, before the later
    HIDL restart loop. This makes the failure independent of keymaster service
    restart timing; the common point is QSEE rejecting `QSEOS_APP_START_COMMAND`
    for app name `keymaster` with `resp.result=-38`.

  - Stock and current qseecom use the same packed app-start request layout for
    `QSEOS_APP_START_COMMAND`. The current tree still differs from stock in the
    memory-share implementation (`dma-buf`/SG versus stock `ion_phys()` plus ION
    cache ops), but the normal-heap diagnostic logged `pa == sg_dma == sg_phys`
    and failed the same way as the coherent-copy diagnostic.

  - Stock `modem.bin` is a FAT16 firmware image and contains `cmnlib.*`,
    `dhsecapp.*`, and many other QSEE apps, but no `keymaster.*`. Both stock and
    current keymaster/gatekeeper HALs request app name `keymaster`, so Pepito's
    keymaster app really does appear to be partition-backed rather than a normal
    modem-FAT trustlet file.

  - The `dhsecapp` negative-control diagnostic proved the current 4.19 dynamic
    QSEE loader path can succeed. With stock modem `dhsecapp.*` staged as
    `keymaster.*` and the keymaster-only SCM app name rewritten to `dhsecapp`,
    TZ returned `ret=0`, `resp.result=1` (`QSEOS_RESULT_INCOMPLETE`), and the
    qseecom driver completed listener handling and registered
    `App with id 131074 (keymaster) now loaded`. This rules out the broad
    categories of broken SMC calling convention, impossible dma-buf/SG handoff,
    bad secapp memory window, and bad split-file staging. The failure is specific
    to loading the partition-derived `keymaster` image through this dynamic TA
    path.

  - A rooted Android 11 GSI boot on the stock Pepito vendor/kernel proved stock
    hardware keymaster is not using the software path: `wait_for_keymaster`
    reported QTI Keymaster 3 at `TRUSTED_ENVIRONMENT`, a disposable TEE key
    generated/signed/verified/deleted successfully with hardware-enforced tags,
    and the keymaster/gatekeeper HAL processes held `/dev/qseecom` + `/dev/ion`.
    A direct `QSEECOM_IOCTL_APP_LOADED_QUERY_REQ` probe then showed
    `keymaster64 ret=-17 app_id=65537 app_arch=0`, while `keymaster` and
    `gatekeeper` remained unloaded. In stock 3.18, `ret=-17` is the intentional
    `-EEXIST` already-loaded result. Current lead: Pepito's real keymaster TA is
    APPSBL/TZ-preloaded as `keymaster64`; the Linux dynamic load of
    partition-derived `keymaster.mdt` is the wrong model.

  - Current Lineage 23 strict boot with the preloaded-keymaster alias reached
    `sys.boot_completed=1`. `lshal` shows
    `android.hardware.keymaster@3.0::IKeymasterDevice/default` registered by
    `android.hardware.keymaster@3.0-service` pid 538, and serial/logcat show
    QSEE `send_cmd` calls to app id `65537` returning `ret=0`. This replaces the
    previous dynamic-load failure as the active keymaster state.

  - `serial.log.11` plus recovery pmsg show the post-boot restart loop is
    specifically the locksettings AES synthetic-password key path. QSEE send_cmd
    to preloaded `keymaster64` app id `65537` succeeds, but QTI KM1
    `get_key_characteristics` returns `-62` / `KEY_REQUIRES_UPGRADE` for the
    427-byte AES key blob before AOSP can parse or upgrade it.

  - Current experiment in `system/keymaster`: for KM1 only, AES and HMAC now use
    AOSP software factories (`SerializeIntegrityAssuredBlob`) while RSA/EC stay
    on QTI hardware passthrough. Expected clean-data signal is
    `pepito_km1 forcing AES through software factory` followed by
    `pepito_km1 create_blob ... ALGORITHM=32` instead of QTI
    `Get key charac ... resp->status: -62`.

  - This change is in userspace keymaster code, so the next validation needs a
    full enough flash to update the keymaster libraries/service (`system`/
    `vendor`; boot-only is not enough). To prove the new AES path, use clean
    `/data` or remove the existing locksettings/keystore synthetic-password
    material; old QTI AES blobs cannot be transformed because KM1 exposes no
    usable upgrade hook once QTI rejects characteristics with `-62`.

  - After the AES path boots, run a disposable TEE RSA/EC generate/sign/delete
    test on Lineage 23 to prove the asymmetric hardware path remains active.

  - Recovery currently has userdata mounted read-only at `/mnt/userdata-ro`.
    Targeted stale-state candidates are `/data/misc/keystore/persistent.sqlite`,
    `/data/system/locksettings.db`, and `/data/system_de/0/spblob/`. Clearing
    those is less broad than formatting all of `/data`, but it is still
    destructive to locksettings/keystore state and should be done only for a
    bring-up test.

  - Factory-reset validation boot (`serial.log.12`) worked: normal-mode adb root is
    available, `sys.boot_completed=1`, strict keymaster remains enabled, and
    `lshal` shows `android.hardware.keymaster@3.0::IKeymasterDevice/default`
    registered by pid 541. The keymaster process holds `/dev/qseecom`, `/dev/ion`,
    and a dmabuf fd, and logcat shows userspace `keymaster` aliased to preloaded
    `keymaster64` app id `65537` with successful QSEE send commands. Software
    gatekeeper remains the registered gatekeeper service for now.

  - The AES/HMAC boot fix is validated: fresh boot logs show a generated HMAC key
    with software-enforced `OS_VERSION=160000` and `OS_PATCHLEVEL=202605`, with no
    `SyntheticPasswordCrypto` / `KEY_REQUIRES_UPGRADE` crash loop on clean data.

  - A disposable TEE RSA test exposed the next blocker. QTI KM1 generated a new
    RSA hardware blob successfully (`error=0`, raw blob length 1619, TEE-enforced
    RSA purpose tags), but the immediate characteristics read on that same blob
    returned `resp->status: -62` / `KEY_REQUIRES_UPGRADE`, so keystore2 rejected
    the generated key and no alias was left behind.

  - Current follow-up experiment in `system/keymaster`: KM1 RSA/EC are routed
    directly through the KM1-aware factories, and generated/imported QTI RSA/EC
    blobs are wrapped inside AOSP integrity-assured blobs with current OS version
    metadata. Expected next-test signal is `pepito_km1 rsa_generate wrap_hw_blob`
    followed by `pepito_km1 create_blob` and successful
    `keystore_cli_v2 generate --name=pepito-codex-tee-test --seclevel=tee`.

  - Follow-up flash of that AOSP-wrapper experiment booted cleanly, but disposable
    RSA generation still failed late. `keystore_cli_v2 generate --seclevel=tee`
    logged successful QTI-backed generate (`pepito_km3 generateKey profile=KM1`,
    `error=0`, wrapped blob length about 1.8 KiB) followed by QTI
    `Export cmd failed` with `resp->status: -62`. Focused Brillo tests showed
    the same `KEY_REQUIRES_UPGRADE` on RSA sign/encrypt and ECDSA-P256 sign.
    AES-128/AES-GCM generated through the software-wrapped path; the Brillo
    harness marks that fail/warn because the characteristics are software
    enforced, which is expected for the current boot-stability compromise.

  - New QTI-wrapper experiment started 2026-06-15: copied stock Pepito AML0
    `android.hardware.keymaster@3.0-service-qti`,
    `android.hardware.keymaster@3.0-impl-qti.so`, `libkeymasterdeviceutils.so`,
    `libkeymasterutils.so`, and the stock init rc into
    `vendor/xiaomi/Mi8937/proprietary`. `device.mk` now installs them only for
    `TARGET_DEVICE_PEPITO=true`; `BoardConfig.mk` and `device.mk` set
    `TARGET_USES_DEVICE_SPECIFIC_KEYMASTER=true`;
    `android.hardware.keymaster@3.0.vendor` stays packaged for the QTI blobs'
    `android.hardware.keymaster@3.0.so` dependency; the keymaster VINTF fragment is
    added back explicitly for pepito. Expected next-boot signal: `ps` should show
    `/vendor/bin/hw/android.hardware.keymaster@3.0-service-qti`, and logcat
    should come from the QTI HIDL wrapper rather than the local `pepito_km3` AOSP
    wrapper diagnostics. Then rerun `keystore_cli_v2 generate --name=pepito-codex-tee-test --seclevel=tee`
    plus `brillo-platform-test --prefix='RSA-2048 Sign'` and
    `--prefix='ECDSA-P256 Sign'`.

  - First QTI-wrapper flash result (`/home/kyle/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/serial.log.10`): init parsed `/vendor/etc/init/android.hardware.keymaster@3.0-service-qti.rc`, but `class_start early_hal` could not start `keymaster-3-0` because `/vendor/bin/hw/android.hardware.keymaster@3.0-service-qti` was missing. Hwservicemanager then repeatedly failed to lazy-start `android.hardware.keymaster@3.0::IKeymasterDevice/default`. This did not reach QSEE or the QTI wrapper. Source-side fix: install the prebuilt service under `/vendor/bin/hw` with `relative_install_path: "hw"`, keep the Android 16 lazy-HAL `interface` declaration in the QTI rc, and rely on the legacy QTI sepolicy label/transition `hal_keymaster_qti_exec` -> `hal_keymaster_qti`. Expected next-boot signal is no `Cannot find /vendor/bin/hw/android.hardware.keymaster@3.0-service-qti`; either the QTI wrapper starts or the next failure is a linker/QSEE/runtime error from that process.

  - Second QTI-wrapper flash result: recovery pstore was pulled to
    `debug/qti-keymaster-crash-recovery/pstore/`. `/data` was not mounted in
    recovery, but pmsg contained the tombstones. The service now installs and
    starts, and QSEECom reaches preloaded `keymaster64` app id `65537`, but the
    QTI HIDL wrapper aborts in `KeymasterDevice::KeymasterDevice()` with abort
    message `Configure failed`. Immediately before the abort, stock QTI logs:
    `KeyMasterHalDevice configure`, `ret: 0`, `resp->status: -38`. This is the
    TA rejecting the wrapper's configure payload, not stale `/data` keystore
    state. Backtrace frame #03 is
    `/vendor/lib64/hw/android.hardware.keymaster@3.0-impl-qti.so (...KeymasterDevice()+348)`.

  - Current follow-up experiment: patch Pepito's stock QTI
    `android.hardware.keymaster@3.0-impl-qti.so` property strings from
    `ro.build.version.release` / `ro.build.version.security_patch` to the
    same-length Android 11 GSI reference names `ro.keymaster.xxx.release` /
    `ro.keymaster.xxx.security_patch`, then define those pepito-only system
    properties as `8.1.0` and `2020-09-01`. The copied blob hash changed from
    `74495041378467ff5636063a8ab107f22ca1040de21a0ee935fb70616478d7b9` to
    `e9c0113ba9cd8d76afdb6d79d7f209b4decbeed2877c36ac061e54e8361421e8`.
    `extract-files.py` now has a reproducible `binary_regex_replace` fixup so
    future extraction keeps this patch. Expected next-boot signal: no QTI
    `Configure failed` / `resp->status: -38`; if configure passes, the QTI
    service should stay registered long enough for keystore2 maintenance to
    continue.


  - Third QTI-wrapper flash result: the property-spoof experiment passed the
    previous blocker. Normal-mode adb root is available, `sys.boot_completed=1`,
    `init.svc.keymaster-3-0=running`, and `lshal` registers
    `android.hardware.keymaster@3.0::IKeymasterDevice/default` from the stock QTI
    service pid `535`. There is no QTI `Configure failed` / `resp->status: -38`
    loop. The new blocker happens later at boot-animation completion: system_server
    repeatedly crashes in `SyntheticPasswordCrypto.decryptBlob()` while unlocking
    the unsecured user. Keystore2 reports `Error::Km(INVALID_KEY_BLOB)` from
    `upgrade_keyblob_if_required_with(...)` / begin operation on the existing
    synthetic-password key.

  - Interpretation of the UI crash: this is very likely stale `/data` key material
    from the previous AOSP/KM1 bridge experiment, not proof that the QTI wrapper
    cannot make fresh Android 16 boot keys. The active locksettings files under
    `/data/system_de/0/spblob/`, `/data/system/locksettings.db`, and
    `/data/misc/keystore/persistent.sqlite` are dated `2026-06-13`, while this QTI
    wrapper build is dated `2026-06-15`. Next validation should use a clean
    locksettings/keystore state, either by factory reset or by targeted removal of
    only the locksettings synthetic-password plus keystore2 database state.


  - Clean-state validation (`serial.log.15`): after clearing stale locksettings /
    keystore state, the device reaches the LineageOS initial setup screen with
    normal adb available. `sys.boot_completed=1`, `sys.system_server.start_count=1`,
    `keystore.crash_count=0`, and the stock QTI keymaster service remains running
    as `/vendor/bin/hw/android.hardware.keymaster@3.0-service-qti`. `lshal`
    registers `android.hardware.keymaster@3.0::IKeymasterDevice/default` from pid
    `540`; `ps` shows gatekeeper is still
    `android.hardware.gatekeeper@1.0-service.software`. Serial shows QSEE commands
    to preloaded `keymaster64` app id `65537` succeeding through boot completion,
    with no `Configure failed`, `INVALID_KEY_BLOB`, or `KEY_REQUIRES_UPGRADE`
    crash loop. Remaining hardening item before enforcing SELinux: the QTI
    keymaster domain currently reads the spoofed `ro.keymaster.xxx.*` properties
    through `default_prop`, producing permissive denials for read/open/getattr/map.


## Evidence reset

Observed on the current Lineage 23 tree:

- The first strict diagnostic ran `android.hardware.keymaster@3.0-service` as `nobody:drmrpc` and exited with status 1 before registering HIDL.
- `/vendor/firmware_mnt` is mounted vfat as `uid=1000,gid=1000,dmask=227,fmask=337`, so only `system:system` can traverse/read normal firmware files.
- The keymaster boot log tries to open `/vendor/firmware_mnt/image/keymaster.mdt` and fails with `errno=13` before falling back to software.
- `hardware/interfaces/keymaster/3.0/default/KeymasterDevice.cpp` had a local software fallback on hardware-open errors, so HIDL registration alone does not prove hardware keymaster.
- `rawprogram0.xml` contains `keymaster` and `keymasterbak` partitions, but no `gatekeeper` partition.
- Current Qualcomm blobs contain the expected QSEE path strings: `QSEECom_start_app`, `/vendor/firmware_mnt/image`, `keymaster`, and `sys.listeners.registered` / `vendor.sys.listeners.registered`.

Stock Android 8 comparison:

- Stock vendor path inspected: `/home/kyle/Projects/lineage-23/backup-stock-android-8.1-AML0/vendor.bin.extracted`.
- Stock shipped QTI services: `android.hardware.keymaster@3.0-service-qti` and `android.hardware.gatekeeper@1.0-service-qti`.
- Stock keymaster service rc runs as `user system`, `group system drmrpc`.
- Stock gatekeeper service rc runs as `user system`, `group system`.
- Stock `keystore.msm8937.so` and `gatekeeper.msm8937.so` both load the QSEE app named `keymaster`.
- Stock fstab mounts the modem partition at `/firmware` as vfat with `uid=1000,gid=1000,dmask=227,fmask=337,context=u:object_r:firmware_file:s0`; Lineage mounts the same partition at `/vendor/firmware_mnt` with equivalent ownership/labeling.
- Stock vendor does not contain `keymaster.mdt` / `keymaster.b*`; the relevant source is the stock `keymaster` partition image. `keymaster.bin` and `keymasterbak.bin` match: `sha256=76959e5db20f3fce8df3a22befd3bc8cf3799fbda09b229cbdf1fc101dc66e6b`.
- Stock DTS path inspected: `/home/kyle/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/extracted/dtbs/pepito.dts`.
- Stock qseecom node at `+7395` uses `qseecom@84a00000`, `reg = <0x84a00000 0x1900000>`, and `qcom,appsbl-qseecom-support`.
- Current inherited 4.19 qseecom node used `0x85b00000 / 0x800000`, which points at the tail of Palm's TZ-protected range and does not match stock.

## Changes started in tree

Default boot-stable path:

- `device/xiaomi/mithorium-common/mithorium.mk` now selects `android.hardware.gatekeeper@1.0-service.software` plus `libgatekeeper` for pepito by default.
- Non-pepito mithorium variants keep the hardware gatekeeper service.
- `TARGET_PEPITO_HARDWARE_GATEKEEPER_DIAGNOSTIC=true` opts pepito back into the hardware gatekeeper package and common gatekeeper VINTF fragment.
- `device/xiaomi/mithorium-common/BoardConfigCommon.mk` no longer adds the common hardware gatekeeper manifest for pepito's software default.
- The `.software` exec label moved out of platform sepolicy and into `device/xiaomi/Mi8937/sepolicy/vendor/file_contexts`.

Hardware diagnostics:

- `hardware/interfaces/keymaster/3.0/default/KeymasterDevice.cpp` still allows software fallback by default so boot remains recoverable.
- `TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true` adds `ro.vendor.pepito.keymaster.strict=true`; with that property, keymaster refuses the software fallback and logs the hardware-open failure.
- `kernel/xiaomi/msm8937/arch/arm64/boot/dts/xiaomi-msm8937/pepito.dts` now overrides `&qcom_seecom` to stock's `reg = <0x84A00000 0x1900000>` and adds `qcom,appsbl-qseecom-support`.
- `kernel/xiaomi/msm8937/drivers/misc/qseecom.c` keeps keymaster-only logging for app-load inputs and SCM response fields. The coherent-copy override was removed after it produced the same failure code, so the next boot uses the normal QSEECom heap buffer again.
- `kernel/xiaomi/msm8937/drivers/soc/qcom/scm.c` ~~temporarily prefers SMC32 over SMC64~~
  **DISCARDED 2026-06-26 (`git checkout`) — the SMC32 hack was never committed; the stock vendor
  file is already SMC64-first, so this file needs NO local edits.** The SMC32-first preference
  never fixed keymaster (still failed at the secure-loader `0x32000101` → -38; see "SMC32-first
  diagnostic result"). Note (corrected 2026-07-02, `PLAN-tz.md`): the hack was NOT what broke
  `hyp_assign_phys` — that call fails identically under SMC64, and identically on stock 3.18,
  and is benign everywhere (Palm TZ rejects `MEM_PROT_ASSIGN` for all callers; nothing depends
  on it). The hack was still pure downside (no keymaster benefit, non-stock). Keymaster's
  blocker is the independent QSEE app-load/dma-buf path; do NOT re-introduce SMC32.
- `device/xiaomi/mithorium-common/sepolicy/vendor/property_contexts` keeps the legacy `sys.listeners.registered` label; Qualcomm vendor sepolicy already provides `vendor.sys.listeners.registered`, so duplicating it here breaks `host_init_verifier`.
- The stock `keymaster.bin` partition image has been split into `keymaster.mdt` plus `keymaster.b00`...`keymaster.b06` under `vendor/xiaomi/Mi8937/proprietary/vendor/etc/keymaster-firmware/`. The `.mdt` follows the existing Qualcomm split-firmware convention in this tree: `b00 + b01` metadata, with `b02` onward carrying LOAD payloads.
- The `dhsecapp` negative-control source path is retired. It proved the 4.19 dynamic loader can load a normal modem-FAT QSEE app, but the active lead is now the stock `keymaster64` preload path. `device.mk` again packages the real stock keymaster split files only; the kernel no longer rewrites `keymaster` SCM app names to `dhsecapp`.
- `device/xiaomi/Mi8937/rootdir/etc/init.pepito.qseecom.rc` and `init.pepito.qseecom.sh` are packaged only for `TARGET_DEVICE_PEPITO=true`. At `post-fs`, init mounts a tmpfs under `/mnt/vendor`, restores it to `mnt_vendor_file`, the helper copies the current `/vendor/firmware_mnt/image` contents plus staged `keymaster.*` split files into it, and init bind-mounts that mirror over `/vendor/firmware_mnt/image` before keymaster starts. Keymaster is allowed to read both the real `firmware_file` mount and the mirrored `mnt_vendor_file` path.
- `device/xiaomi/Mi8937/sepolicy/vendor/file_contexts` labels `/vendor/etc/keymaster-firmware(/.*)?` as `firmware_file` and labels the helper as `init_pepito_qseecom_exec`; device SELinux policy gives init the mount points, gives the helper a narrow copy domain for `mnt_vendor_file`, and avoids writable `firmware_file` rules because platform neverallows forbid writing context-mounted firmware labels.

## Post-flash default verification - 2026-06-11

Normal build, no diagnostic variables set:

- `sys.boot_completed=1`; SELinux is Enforcing.
- `android.hardware.gatekeeper@1.0-service.software` is running as `system`; `gatekeeperd` is running.
- `lshal` shows `android.hardware.gatekeeper@1.0::IGatekeeper/default` registered.
- `/vendor/bin/hw/android.hardware.gatekeeper@1.0-service.software` is present and labeled `hal_gatekeeper_default_exec`.
- `/vendor/lib64/libgatekeeper.so` is present.
- `/vendor/firmware_mnt` remains mounted from modem vfat as `system:system`, dirs `0550`, files `0440`; no `/vendor/firmware_mnt/image/keymaster*` split files exist.
- Live DT still names the node `qseecom@85b00000`, but `reg` reads as `0000a084 00009001` from `/proc/device-tree`, i.e. the big-endian cells for `0x84a00000 / 0x01900000`; `qcom,appsbl-qseecom-support` is present.
- Current log buffer has no `software-only implementation` / `refusing software fallback` keymaster diagnostic strings, but this default build still does not prove hardware keymaster because fallback is allowed.

Next proof step is a strict keymaster build with software gatekeeper left enabled and the firmware mirror present.

## Strict keymaster diagnostic result - 2026-06-11

Build used `TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true` with software gatekeeper still default. Serial showed repeated `vendor.keymaster-3-0` starts followed by exit status 1. That is the expected strict-mode failure shape: the local fallback is refused, keymaster HIDL never registers, vold waits for `android.security.maintenance`, and boot stalls before SurfaceFlinger/boot animation and before adb becomes useful.

Follow-up source change after this first failure was to match stock Android 8 keymaster service identity. Stock ran keymaster as `user system`, `group system drmrpc`; the generic AOSP rc ran it as `nobody:drmrpc`, which cannot traverse the vfat firmware mount owned by `system:system` with directory mode `0550`. That rc change is already in tree.

## Recovery pstore from first strict failure - 2026-06-11

Recovery retained `/sys/fs/pstore/console-ramoops-0` and `/sys/fs/pstore/pmsg-ramoops-0`; copies were pulled to `/tmp/pepito-console-ramoops-0` and `/tmp/pepito-pmsg-ramoops-0` before flashing over the failed boot.

Key lines from pmsg confirm the actual hardware-open failure:

```text
android.hardware.keymaster@3.0-impl: Fetching keymaster device name default
QSEECOMAPI: QSEECom_get_handle sb_length = 0xa000
QSEECOMAPI: App is not loaded in QSEE
QSEECOMAPI: Error::Cannot open the file /vendor/firmware_mnt/image/keymaster.mdt errno = 13
keymaster1_device: Loading keymaster app failed
android.hardware.keymaster@3.0-impl: Error -1 opening keystore keymaster1 device
android.hardware.keymaster@3.0-impl: Failed to open keymaster1 device; ro.vendor.pepito.keymaster.strict=true, refusing software fallback.
```

Follow-up source changes for the next strict build:

- Match stock service identity: `user system`, `group system drmrpc`.
- Add device-local `r_dir_file(hal_keymaster_default, firmware_file)` because Qualcomm's `hal_keymaster_qti` domain has firmware read access, but the generic `hal_keymaster_default` domain used by the AOSP service did not.

## Strict keymaster with first firmware overlay packaging - 2026-06-11

Serial and pstore from `/home/kyle/android/lineage-23/serial.log`, `/tmp/pepito-console-ramoops-overlay`, and `/tmp/pepito-pmsg-ramoops-overlay` show the same strict-keymaster failure shape as before:

```text
QSEECOMAPI: Error::Cannot open the file /vendor/firmware_mnt/image/keymaster.mdt errno = 2
android.hardware.keymaster@3.0-impl: Failed to open keymaster1 device; ro.vendor.pepito.keymaster.strict=true, refusing software fallback.
```

The split files were present in `installed-files-vendor.txt`, but serial did not show `Parsing file /vendor/etc/init/hw/init.pepito.qseecom.rc` or a `post-fs` action from that file. The boot only parsed explicitly imported files from `/vendor/etc/init/hw`; Android's normal directory scan covers `/vendor/etc/init/*.rc`. The rc packaging has therefore been moved from `/vendor/etc/init/hw/init.pepito.qseecom.rc` to `/vendor/etc/init/init.pepito.qseecom.rc`.

The next strict boot did show `Parsing file /vendor/etc/init/init.pepito.qseecom.rc` and the `post-fs` action from that file; the remaining failure was the overlay mount itself.

## Strict keymaster with parsed overlay rc - 2026-06-11

Serial from `/home/kyle/android/lineage-23/serial.log.2` confirmed the packaging fix: init parsed `/vendor/etc/init/init.pepito.qseecom.rc` and processed its `post-fs` action before keymaster started. The failure was the overlay mount itself:

```text
overlayfs: filesystem on '/vendor/firmware_mnt/image' not supported
init: Command 'mount overlay overlay /vendor/firmware_mnt/image ro lowerdir=/vendor/etc/keymaster-firmware:/vendor/firmware_mnt/image' action=post-fs (/vendor/etc/init/init.pepito.qseecom.rc:4) took 8ms and failed: mount() failed: Invalid argument
```

Interpretation: `/vendor/firmware_mnt/image` is on the modem vfat mount, and this kernel's overlayfs rejects it as a lower layer. The current source therefore abandons overlayfs for this diagnostic and uses a pepito-only tmpfs mirror plus bind mount instead.

Expected next strict boot: serial should show the same rc parse and `post-fs` action, but no failed `mount overlay` command. If the helper or bind mount fails, inspect serial for `init.pepito.qseecom.sh`, `pepito-qseecom-image`, `tmpfs`, or `mount none ... bind` errors.

## Strict keymaster with stock identity + firmware allow - 2026-06-11

Recovery pstore was pulled from the failed boot to:

- `/tmp/pepito-console-ramoops-latest`
- `/tmp/pepito-pmsg-ramoops-latest`

Use `pmsg-ramoops-0` for the current Android userspace failure; `console-ramoops-0` contains many nested `prev:` records from older boots.

Key result: the QSEECom failure changed from `errno = 13` to `errno = 2`:

```text
android.hardware.keymaster@3.0-impl: Fetching keymaster device name default
QSEECOMAPI: QSEECom_get_handle sb_length = 0xa000
QSEECOMAPI: App is not loaded in QSEE
QSEECOMAPI: Error::Cannot open the file /vendor/firmware_mnt/image/keymaster.mdt errno = 2
keymaster1_device: Loading keymaster app failed
android.hardware.keymaster@3.0-impl: Error -1 opening keystore keymaster1 device
android.hardware.keymaster@3.0-impl: Failed to open keymaster1 device; ro.vendor.pepito.keymaster.strict=true, refusing software fallback.
```

Interpretation:

- The previous `errno = 13` access failure is fixed by running keymaster as `system:system drmrpc` and allowing `hal_keymaster_default` to read `firmware_file`.
- There is no current evidence of a keymaster/firmware SELinux denial in pmsg.
- The blocker has moved to missing split trustlet files at `/vendor/firmware_mnt/image/keymaster.mdt` / `keymaster.b*`.

Next diagnostic state now in tree:

1. A pepito-only post-fs tmpfs mirror now makes split `keymaster.mdt`/`keymaster.b*` files visible at `/vendor/firmware_mnt/image` while preserving the rest of the modem firmware image directory inside the mirror. This re-tests the earlier split-file experiment after the qseecom region, UID, SELinux, and overlayfs issues.
2. The next strict boot should no longer fail with `errno = 2` for `keymaster.mdt` if the helper and bind mount work. A useful failure would move later, for example QSEE/TZ rejecting the image load.
3. If the split partition image is still rejected by TZ, try the stock Android 8 QTI keymaster service/impl blobs instead of AOSP's generic passthrough wrapper, but expect more VNDK/dependency work.
4. Keep software fallback as the stable default until one of the hardware paths proves TEE-backed keymaster.

## Stock-kernel Android 11 GSI keymaster probe - 2026-06-13

A rooted Android 11 GSI was booted with stock Pepito vendor and the original stock
kernel. This was a useful stock-kernel/vendor reference even though `/system` was
a GSI.

Follow-up full reference dump from 2026-06-15 is saved at
`debug/android11-gsi-keymaster-reference/adb-keymaster-reference-20260615-200638.txt`.
The live stock-vendor Android 11 system had `init.svc.keymaster-3-0`,
`init.svc.gatekeeper-1-0`, and `init.svc.qseecomd` all running. Processes were
stock QTI services:

```text
system 813 android.hardware.gatekeeper@1.0-service-qti
system 814 android.hardware.keymaster@3.0-service-qti
system 955 qseecomd
```

The stock service binaries live at `/vendor/bin/hw/...-qti` and are labeled
`hal_keymaster_qti_exec` / `hal_gatekeeper_qti_exec`. The stock init rc files are
minimal Oreo-style `class early_hal` services with no HIDL `interface` line:
keymaster runs as `system` with groups `system drmrpc`; gatekeeper runs as
`system` with group `system`. On Android 16 we should keep the explicit
`interface` line for lazy HAL startup, but the known-good reference confirms the
service name, path, user/group, and `early_hal` class.

Runtime fds confirm both QTI HALs are hardware-backed: keymaster pid 814 and
gatekeeper pid 813 each hold `/dev/qseecom`, `/dev/ion`, and a dmabuf fd. The
keymaster process maps `/vendor/lib64/hw/android.hardware.keymaster@3.0-impl-qti.so`,
`/vendor/lib64/libkeymasterdeviceutils.so`, and `/vendor/lib64/libQSEEComAPI.so`.
Android 11 loads `android.hardware.keymaster@3.0.so` from its VNDK v27 APEX; on
Lineage 23 the experiment packages `android.hardware.keymaster@3.0.vendor` to
satisfy that legacy HIDL dependency from the vendor namespace.

Evidence that stock is using hardware keymaster/gatekeeper plumbing, not a
software-only fallback:

```text
lshal: android.hardware.keymaster@3.0::IKeymasterDevice/default from /vendor/lib64/hw/*-qti
lshal: android.hardware.gatekeeper@1.0::IGatekeeper/default from /vendor/lib64/hw/*-qti
wait_for_keymaster: Keymaster HAL: 3 from QTI SecurityLevel: TRUSTED_ENVIRONMENT
keystore_cli_v2 generate/sign-verify/delete: GenerateKey: 0, Verify: OK
```

The QTI HAL PIDs had `/dev/qseecom` and `/dev/ion` open. A tiny read-only ioctl
probe used stock 3.18's `QSEECOM_IOCTL_APP_LOADED_QUERY_REQ` semantics. The
2026-06-15 user-run probe on the live Android 11 GSI reference reported the same
important shape: plain `keymaster` is not resident by that name, but `keymaster64`
is already loaded as app id `65537`:

```text
keymaster    ret=0   app_id=0     app_arch=0
keymaster64  ret=-17 app_id=65537 app_arch=0
gatekeeper   ret=0   app_id=0     app_arch=0
gatekeeper64 ret=0   app_id=0     app_arch=0
```

In the stock driver, `ret=-17` is `-EEXIST`, the intentional already-loaded
return from the loaded-app query. `app_arch=0` is also consistent with an app
loaded by APPSBL/TZ before Linux and later registered by query, because the
kernel has no local firmware metadata for it.

Follow-up source change: 4.19 qseecom now aliases userspace `keymaster` loaded-app
queries and load-app requests to a preloaded `keymaster64` app id if TZ exposes
one. If `keymaster64` is resident, this bypasses dynamic MDT loading entirely and
registers the app id locally under the userspace-requested name. If neither
`keymaster` nor `keymaster64` is resident, the keymaster dynamic load is disabled
for this diagnostic and the serial log should show that explicitly.

## 4.19 keymaster64 preload alias result - 2026-06-13

Full diagnostic build accidentally flashed vendor as well as boot, which was still
usable: the retired `dhsecapp` packaging path had already been removed, so vendor
contained the real stock keymaster split files again. The important kernel result
from `/home/kyle/android/lineage-23/serial.log.7` is positive:

```text
QSEECOM: qseecom_query_app_loaded: pepito_app_query request: name=keymaster data_type=1 comm=android.hardwar qsee=0x1000000 commonlib=1 commonlib64=0
QSEECOM: qseecom_pepito_lookup_app: pepito_qsee_lookup[query-alias]: app=keymaster64 ret=0 app_id=65537 qsee=0x1000000 commonlib=1 commonlib64=0
QSEECOM: qseecom_query_app_loaded: pepito_app_query: aliasing userspace keymaster to preloaded keymaster64 app_id=65537
QSEECOM: qseecom_query_app_loaded: pepito_app_query loaded: request=keymaster alias_keymaster64=1 app_id=65537 app_arch=2 found_local=0
```

This confirms the stock Android 11 GSI observation on the 4.19 kernel: Palm TZ
does expose a preloaded `keymaster64` app id. The old dynamic `keymaster.mdt`
load is not needed for the first HAL open path.

Remaining issue from this log: `vendor.keymaster-3-0` starts and remains running,
but `hwservicemanager` later asks init to start
`android.hardware.keymaster@3.0::IKeymasterDevice/default` again and init reports
the service is already running. The serial snippet does not show the keymaster
HIDL registration completing. That points to a hang/failure after
`QSEECom_app_load_query`, probably during the first QSEECom command exchange or
inside the userspace HAL wrapper.

Follow-up source change: the alias path now mimics stock's preloaded-app
`app_arch=0` behavior instead of forcing `ELFCLASS64`, because stock
`QSEECOM_IOCTL_APP_LOADED_QUERY_REQ` returned `app_arch=0` for `keymaster64`.
The qseecom send-command path now logs `pepito_send_cmd enter/scm/exit` for
keymaster/gatekeeper app names so the next boot can show whether the HAL blocks
in SCM, listener handling, response parsing, or above QSEECom.

## Dhsecapp negative-control diagnostic result - 2026-06-13

Serial from `/home/kyle/android/lineage-23/serial.log` contains multiple older
boot fragments, but the current diagnostic boot has the important QSEE window at
about 18.6 seconds:

```text
pepito_load_app: dhsecapp diagnostic rewrites SCM app name keymaster->dhsecapp
pepito_load_app name=keymaster scm_name=dhsecapp arch=1 mdt=6940 img=43417 len=45056 qsee=0x1000000 commonlib=1 commonlib64=0
pepito_load_app nents=1 orig_nents=1 pa=0x00000000ff030000 sg_dma=0x00000000ff030000 sg_phys=0x00000000ff030000 sg_len=45056 sg_off=0
pepito_load_app buf[img-16=0xa989]=64600200170000006860020017000000
pepito_load_app scm ret=0 resp.result=1 resp.type=60930 resp.data=8192 cmd_len=84
App with id 131074 (keymaster) now loaded
```

`resp.result=1` is `QSEOS_RESULT_INCOMPLETE`, which qseecom handles by processing
the requested listener callback and continuing the load. The decisive line is the
final registration of an app id. The service then stayed running long enough for
Android to reach `sys.boot_completed=1`; this is expected for the diagnostic but
does not mean hardware keymaster works, because the loaded app bytes are
`dhsecapp`, not the keymaster trustlet.

Interpretation: dynamic loading of a normal modem-FAT QSEE app works on this
4.19 kernel with the current DTS, SMC32-first path, dma-buf/SG handoff, and
tmpfs firmware mirror. The remaining keymaster blocker is therefore specific to
the dedicated-partition `keymaster.bin` image or to the stock boot chain's way of
preloading/authorizing that image.

Next highest-value stock test remains: boot rooted stock Android 8 and query
`QSEECOM_IOCTL_APP_LOADED_QUERY_REQ` for `keymaster` before userspace attempts a
load. A nonzero app id would confirm APPSBL/TZ preload as the stock path.

## Bring-up plan

### 1. Rebuild and verify the stable default

Build a normal pepito image with no diagnostic variables set. The vendor image should contain:

```bash
/vendor/bin/hw/android.hardware.gatekeeper@1.0-service.software
/vendor/lib64/libgatekeeper.so
```

It should not start the hardware gatekeeper wrapper as the active `vendor.gatekeeper-1-0` service. After flashing, verify:

```bash
adb root
adb wait-for-device
adb shell getprop init.svc.vendor.gatekeeper-1-0
adb shell lshal | grep -i gatekeeper
adb shell getprop sys.boot_completed
adb shell su 0 getenforce
```

Expected default result: gatekeeper service running, HIDL `IGatekeeper/default` registered, `sys.boot_completed=1`, SELinux Enforcing.

### 2. Run a strict keymaster diagnostic build with the firmware mirror

Current lead has superseded the old `dhsecapp` packaging test. For the next
flash, prefer a boot-only strict keymaster build with the `keymaster64` preload
alias diagnostics. Keep software gatekeeper unless explicitly testing gatekeeper.

Build guidance for the current lead:

```bash
./scripts/build-lineage23.sh --boot-only
```

Boot-only is enough for the `keymaster64` alias diagnostic because the change is
in the kernel qseecom driver. If the target phone is not already on the strict
keymaster diagnostic userspace/vendor image, do a normal diagnostic build with
`TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true` and keep software gatekeeper.
Do not use the retired `dhsecapp` packaging flag.

The vendor image from the previous firmware-mirror line contained:

```bash
/vendor/etc/init/init.pepito.qseecom.rc
/vendor/bin/init.pepito.qseecom.sh
/vendor/etc/keymaster-firmware/keymaster.mdt
/vendor/etc/keymaster-firmware/keymaster.b00
/vendor/etc/keymaster-firmware/keymaster.b01
/vendor/etc/keymaster-firmware/keymaster.b02
/vendor/etc/keymaster-firmware/keymaster.b03
/vendor/etc/keymaster-firmware/keymaster.b04
/vendor/etc/keymaster-firmware/keymaster.b05
/vendor/etc/keymaster-firmware/keymaster.b06
```

At `post-fs`, init should mount `/mnt/vendor/pepito-qseecom-image` as tmpfs, restore it to the normal `/mnt/vendor` label (`mnt_vendor_file`), run `/vendor/bin/init.pepito.qseecom.sh` to copy the modem firmware image contents plus staged `keymaster.*` files into it, then bind-mount that mirror over `/vendor/firmware_mnt/image`. This is intentionally earlier than `late-fs`, because `class_start early_hal` starts keymaster at `late-fs`.

Expected if the mirror is mounted correctly but TZ rejects the partition-derived trustlet: the failure should move past `Cannot open ... keymaster.mdt errno = 2` and into QSEE/TZ load errors. Capture pstore from recovery again if adb never comes up.

Do not call hardware keymaster fixed until keystore2 reports a hardware/TEE security level without the fallback path.

### 3. Interpret the next strict-keymaster boot

Useful outcomes:

- `errno = 2` for `/vendor/firmware_mnt/image/keymaster.mdt` remains: the tmpfs mirror did not mount/bind early enough, the helper failed, or the staged files were not copied/labeled into vendor.
- `errno = 13` returns: labeling or service identity regressed; check `ls -laZ /vendor/etc/keymaster-firmware /vendor/firmware_mnt/image` and keymaster service user/group.
- QSEECom finds the files but logs a TZ/SCM load rejection: the split image format/path is now accepted by userspace and kernel, but Palm TZ does not accept this partition-derived payload in that loader path.
- Keymaster HIDL registers and keystore2 reports hardware/TEE security level: then proceed to hardware gatekeeper.

### 4. Only then test hardware gatekeeper

After strict keymaster proves a real hardware/TEE keymaster path, build with both diagnostics:

```bash
TARGET_PEPITO_HARDWARE_KEYMASTER_DIAGNOSTIC=true \
TARGET_PEPITO_HARDWARE_GATEKEEPER_DIAGNOSTIC=true \
./scripts/build-lineage23.sh build
```

Expected hardware-gatekeeper success criteria:

- `vendor.gatekeeper-1-0` stays running.
- `lshal` shows `android.hardware.gatekeeper@1.0::IGatekeeper/default` from the hardware service.
- Logcat does not show `Unable to open GateKeeper HAL`.
- QSEECom does not fail loading `keymaster` from firmware or partition-backed app storage.
- Framework locksettings can enroll and verify a credential after a reboot.

If gatekeeper still tries split files under `/vendor/firmware_mnt/image/keymaster.mdt`, compare it against the partition-backed `keymaster` image. Earlier live split-file tests reached QSEECom file parsing but the secure monitor rejected the load with `-22`, so do not assume a split made from the partition is accepted by Palm TZ.

## Early adb note

An early-adb diagnostic build is possible, but do it as a separate explicit diagnostic flag if serial/pstore stop being enough. Starting adbd before the normal keymaster/vold path changes boot ordering and can mask whether strict keymaster is the thing blocking Android from coming up. For the current failure, serial already identified the init mount problem, so this plan keeps early adb out of the next test.

## Dump instructions

Use these when collecting a hardware diagnostic boot. Avoid dumping `userdata`, `metadata`, `persist`, or `/data/system/gatekeeper.*` unless we explicitly need them; those are not required for the current QSEE loader problem.

Create a host directory:

```bash
DUMP_DIR=dumps/gatekeeper-$(date +%Y%m%d-%H%M%S)
mkdir -p "$DUMP_DIR"
cd "$DUMP_DIR"
```

Basic state:

```bash
adb root
adb wait-for-device
adb shell su 0 'getprop | sort' > getprop.txt
adb shell su 0 'mount' > mount.txt
adb shell su 0 'getenforce; id; uptime' > device-state.txt
adb shell su 0 'lshal --debug 2>/dev/null || lshal' > lshal.txt
adb shell su 0 'service list; echo; hwservicemanager list 2>/dev/null' > services.txt
adb logcat -b all -d -v threadtime > logcat-all.txt
adb shell su 0 'dmesg' > dmesg.txt
```

Firmware mount and device-tree qseecom state:

```bash
adb shell su 0 'ls -laZ /vendor/firmware_mnt /vendor/firmware_mnt/image /firmware /firmware/image 2>&1' > firmware-ls.txt
adb shell su 0 'for n in /sys/firmware/devicetree/base/soc/qseecom* /proc/device-tree/soc/qseecom*; do [ -d "$n" ] || continue; echo "== $n =="; [ -f "$n/compatible" ] && tr "\000" "\n" < "$n/compatible"; [ -f "$n/reg" ] && od -An -tx4 "$n/reg"; done' > qseecom-dt.txt
adb shell su 0 'cat /proc/iomem' > proc-iomem.txt
```

Firmware partitions relevant to QSEE/keymaster:

```bash
adb shell su 0 'OUT=/data/local/tmp/gk-dump-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; for p in keymaster keymasterbak tz tzbak cmnlib cmnlib64 hyp hypbak rpm rpmbak devcfg devcfgbak; do if [ -e /dev/block/by-name/$p ]; then dd if=/dev/block/by-name/$p of="$OUT/$p.img" bs=4096 status=none; sha256sum "$OUT/$p.img" >> "$OUT/sha256sums.txt"; fi; done; echo "$OUT"'
```

Then pull the printed directory:

```bash
adb pull /data/local/tmp/gk-dump-YYYYMMDD-HHMMSS ./firmware-partitions
```

For an active strict-keymaster boot, also capture focused logs immediately after boot attempt:

```bash
adb logcat -b all -d -v threadtime | grep -iE 'keymaster|gatekeeper|qsee|qseecom|keystore2|seclevel|firmware_mnt' > focused-keymaster-gatekeeper.txt
adb shell su 0 'getprop init.svc.vendor.keymaster-3-0; getprop init.svc.vendor.gatekeeper-1-0; getprop ro.vendor.pepito.keymaster.strict' > hal-service-props.txt
```

## Targeted permissive diagnostic

The strict keymaster boot with the tmpfs mirror reached `init.pepito.qseecom.sh`, but the helper exited after SELinux denied `cp` access to the newly mounted tmpfs root:

```text
avc: denied { read } for comm="cp" name="/" dev="tmpfs" scontext=u:r:init_pepito_qseecom:s0 tcontext=u:object_r:tmpfs:s0 tclass=dir permissive=0
```

For the next diagnostic build, `init_pepito_qseecom` and `hal_keymaster_default` are permissive on `userdebug`/`eng` builds only. This should tell us whether the remaining `QSEECom` `errno = 2` is just SELinux blocking the staged mirror, or whether the loader still cannot see/accept the staged `keymaster.*` files after policy is out of the way.

## Global permissive diagnostic

`serial.log.4` still showed enforcing SELinux denials during the qseecom staging action, including `vendor_init` denied `relabelfrom` on the tmpfs root with `permissive=0`. The helper domain was permissive and its tmpfs AVCs were non-blocking, but the helper still exited before `keymaster.*` was visible; pmsg continued to report `QSEECom` `errno = 2` for `/vendor/firmware_mnt/image/keymaster.mdt`.

For the next diagnostic build, pepito adds `androidboot.selinux=permissive` to the kernel command line. The staging helper also treats the broad modem firmware mirror as best-effort so an unrelated copy failure cannot skip the mandatory `keymaster.*` copy.

## Strict keymaster with global permissive result

`serial.log.5` changed the failure mode in the useful way we wanted:

- Global SELinux permissive is active. Init logs `Permissive SELinux boot`, and remaining AVCs are `permissive=1`.
- `init.pepito.qseecom.sh` runs from `/vendor/etc/init/init.pepito.qseecom.rc` and exits `0`; the tmpfs mirror/bind path is no longer blocked by policy.
- QSEECom no longer reports `Cannot open the file /vendor/firmware_mnt/image/keymaster.mdt errno = 2`, so the staged trustlet path is now visible enough for the loader.
- The new failure is the secure loader rejecting the image:

```text
QSEECOM: qseecom_load_app: App (keymaster) does'nt exist, loading apps for first time
scm_call failed: func id 0x72000101, ret: -2, syscall returns: 0xffffffffffffffda, 0x0, 0x0
QSEECOM: qseecom_load_app: scm_call to load app failed
QSEECOM: qseecom_ioctl: failed load_app request: -22
```

Pmsg also reports the matching userspace-side failure:

```text
QSEECOMAPI: Error::Load image request failed ret = -1, errno = 22
keymaster1_device: Loading keymaster app failed
```

Interpretation: this is no longer a SELinux or missing-file problem. We are at QSEE/TZ load rejection of the `keymaster` app image.

Payload checks done after `serial.log.5`:

- Staged split files are present under `vendor/xiaomi/Mi8937/proprietary/vendor/etc/keymaster-firmware/`.
- `keymaster.mdt` is ELF32 ARM with 7 program headers; `keymaster.b00` through `keymaster.b06` line up with the segment file sizes expected by those headers.
- The compact `.mdt` size is not by itself suspicious: current Qualcomm firmware blobs such as `a506_zap.mdt` and `venus.mdt` use the same compacted-metadata style.
- Stock Android 8 current/stock QTI keymaster blobs both use app name `keymaster`. The current Lineage blob uses firmware path `/vendor/firmware_mnt/image`; the stock Pepito blob uses `/firmware/image`, which should resolve through the root symlink `/firmware -> /vendor/firmware_mnt`.
- Current `&qcom_seecom` app window has been overridden to stock `0x84a00000 / 0x1900000`, matching the stock DTS `qseecom@84a00000` node.

Most likely next suspects:

- The current 4.19 QSEECom/SCM Linux path may differ from Palm's stock Android 8 driver in app-load mechanics. The original Pepito GPL source is at `/home/kyle/Projects/Pepito_GPL_SourceCode`; the stock kernel tree to compare is `/home/kyle/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18`.
- The stock Android 8 QTI keymaster/gatekeeper HAL/library stack may perform a slightly different QSEECom load sequence than the current Lineage/Xiaomi stack. Stock `libQSEEComAPI.so` and `keystore.msm8937.so` alone did not fix the secure-loader rejection; a fuller stock service/impl test remains possible, but the active kernel lead is now SCM SMC32-vs-SMC64 calling convention rather than userspace blob mismatch.

## Stock Pepito libQSEEComAPI + keystore test - 2026-06-12

Recovery-side vendor patch replaced only:

- `/vendor/lib64/libQSEEComAPI.so`
- `/vendor/lib64/hw/keystore.msm8937.so`

The replacement hashes match stock Pepito Android 8 vendor; previous Lineage blobs were backed up under `/vendor/pepito-stock-test-backup/`. Software gatekeeper remained the active gatekeeper path.

`serial.swapedkeystoreso.log` changed behavior substantially:

- `qseecomd` starts and publishes listener services. The repeated `scm_call failed: func id 0x72000206` lines map to `TZ_OS_REGISTER_LISTENER_SMCINVOKE_ID`; this is qseecom listener registration, not keymaster app loading. Stock and current drivers both try that smcinvoke ID before falling back to the older listener registration ID.
- `init.pepito.qseecom.sh` still runs and exits `0`; the firmware mirror is still being staged.
- `vendor.keymaster-3-0` starts and remains running instead of exiting with the previous `failed load_app request: -22`.
- HIDL registration never completes. `hwservicemanager` repeatedly tries to start `android.hardware.keymaster@3.0::IKeymasterDevice/default`, but init reports the service is already running. Pmsg reaches only `android.hardware.keymaster@3.0-impl: Fetching keymaster device name default`; it does not show the earlier `Loading keymaster app failed` path.

Interpretation: stock Pepito `keystore.msm8937.so` is very likely blocking inside its HAL open path (`HwKmOpen`) before the AOSP keymaster@3.0 wrapper can register HIDL. A strong candidate is listener-property mismatch: current qseecomd sets `vendor.sys.listeners.registered`, while stock Pepito qseecomd/keystore use `sys.listeners.registered`. The legacy property context already exists in device policy.

Follow-up source change: `device/xiaomi/mithorium-common/rootdir/bin/init.qti.qseecomd.sh` now mirrors `vendor.sys.listeners.registered=true` to `sys.listeners.registered=true` after qseecomd listener setup. Next strict stock-blob boot should tell us whether the hang advances to `QSEECom_start_app` / keymaster image load.

## Stock Pepito blobs with listener property bridge - 2026-06-12

`serial.fixqsecomfirmwarepath.log` confirms the listener-property bridge advanced the stock Pepito keymaster blob past the previous hang:

- The bridge attempts `setprop sys.listeners.registered true`; SELinux logs a permissive denial for `init-qti-fbe-sh` setting `vendor_tee_listener_prop`, so this will need a real allow rule before returning to enforcing. In the current global-permissive diagnostic it does not block.
- Stock `keystore.msm8937.so` now reaches `QSEECom_get_handle`, reports `app_arch = 1, total_files = 8`, and calls into the kernel load-app path.
- The load still fails at the same secure monitor boundary as the non-stock blob:

```text
QSEECOM: qseecom_load_app: App (keymaster) does'nt exist, loading apps for first time
scm_call failed: func id 0x72000101, ret: -2, syscall returns: 0xffffffffffffffda, 0x0, 0x0
QSEECOM: qseecom_load_app: scm_call to load app failed
QSEECOM: qseecom_ioctl: failed load_app request: -22
```

Interpretation: pairing stock Pepito `libQSEEComAPI.so` and `keystore.msm8937.so` with the stock keymaster image does not resolve the TZ rejection. At this point the remaining high-value suspect was the current 4.19 qseecom load buffer handoff, especially `qseecom_vaddr_map()` returning `sg_dma_address(new_sgt->sgl)` where stock 3.18 used `ion_phys()`. Later diagnostics below make that less likely.

Follow-up source change: `kernel/xiaomi/msm8937/drivers/misc/qseecom.c` now logs `pepito_load_app` diagnostics for app `keymaster` only: app arch, mdt/img lengths, qsee version, commonlib flags, SG nents, `pa`, `sg_dma`, `sg_phys`, SG length/offset, SCM return, and response fields. This is diagnostic-only; it does not change the address passed to TZ.

The next strict stock-blob boot produced `serial.qsecdtssync.log`: `sg_dma` matched `sg_phys`, the stock split payload matched the live partition image, and TZ still rejected the app load. The current follow-up is the keymaster-only coherent-buffer diagnostic below.

## DTS sync + keymaster image verification - 2026-06-12

`serial.qsecdtssync.log` shows the DTS cleanup took effect:

```text
Reserved memory: created CMA memory pool at 0x00000000ff000000, size 16 MiB
OF: reserved mem: initialized node qseecom_region@0, compatible id shared-dma-pool
Removed memory: created DMA memory pool at 0x0000000084a00000, size 30 MiB
OF: reserved mem: initialized node other_ext_region@0, compatible id removed-dma-pool
pepito_load_app name=keymaster arch=1 mdt=6940 img=263610 len=266240 qsee=0x1000000 commonlib=1 commonlib64=0
pepito_load_app nents=1 orig_nents=1 pa=0x00000000ff100000 sg_dma=0x00000000ff100000 sg_phys=0x00000000ff100000 sg_len=266240 sg_off=0
scm_call failed: func id 0x72000101, ret: -2, syscall returns: 0xffffffffffffffda, 0x0, 0x0
pepito_load_app scm ret=-22 resp.result=4294967258 resp.type=0 resp.data=0 cmd_len=84
```

Interpretation:

- Removing `qseecom_ta_region` and ION heap 19 changed early reserved memory as intended.
- Removing `qcom,commonlib64-loaded-by-uefi` changed the load diagnostic from `commonlib64=1` to `commonlib64=0`, matching stock Pepito DTS.
- The app-load buffer is one contiguous SG entry, and `pa == sg_dma == sg_phys`, so the earlier DMA-address-vs-physical-address suspicion is ruled out for this boot.
- The secure monitor still rejects the load at the same boundary.

Recovery inspection with adb root:

- Live `/dev/block/by-name/keymaster` is `/dev/block/mmcblk0p46`, size 1 MiB.
- Exact live partition dump matches stock `/home/kyle/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/keymaster.bin` with sha256 `76959e5db20f3fce8df3a22befd3bc8cf3799fbda09b229cbdf1fc101dc66e6b`.
- Current split firmware files under `vendor/xiaomi/Mi8937/proprietary/vendor/etc/keymaster-firmware/` match the stock ELF program-header segments byte-for-byte:
  - `b00`: offset `0x00000`, size `0x00114`
  - `b01`: offset `0x01000`, size `0x01a08`
  - `b02`: offset `0x03000`, size `0x3577a`
  - `b03`: offset `0x38780`, size `0x07114`
  - `b04`: offset `0x3ff00`, size `0x00124`
  - `b05`: offset `0x40f00`, size `0x00058`
  - `b06`: offset `0x41f00`, size `0x00578`

## Coherent-buffer diagnostic result - 2026-06-12

Latest strict keymaster serial shows the coherent-copy path ran and still failed at the same TZ boundary:

```text
pepito_load_app name=keymaster arch=1 mdt=6940 img=263610 len=266240 qsee=0x1000000 commonlib=1 commonlib64=0
pepito_load_app nents=1 orig_nents=1 pa=0x00000000ff100000 sg_dma=0x00000000ff100000 sg_phys=0x00000000ff100000 sg_len=266240 sg_off=0
pepito_load_app coherent_copy pa=0x00000000f7280000 len=266240 first16=7f 45 4c 46 01 01 01 00 00 00 00 00 00 00 00 00
scm_call failed: func id 0x72000101, ret: -2, syscall returns: 0xffffffffffffffda, 0x0, 0x0
pepito_load_app scm ret=-22 resp.result=4294967258 resp.type=0 resp.data=0 cmd_len=84
```

Interpretation: the image copy is valid enough to show the ELF header at the coherent physical address, but TZ still rejects the app-load call. This makes the dma-buf/SG/cache-maintenance path unlikely as the primary blocker.

## SMC32-first diagnostic result - 2026-06-12

The next strict keymaster boot used the SMC32 app-start function id but still failed with the same TZ result:

```text
pepito_load_app name=keymaster arch=1 mdt=6940 img=263610 len=266240 qsee=0x1000000 commonlib=1 commonlib64=0
pepito_load_app nents=1 orig_nents=1 pa=0x00000000ff100000 sg_dma=0x00000000ff100000 sg_phys=0x00000000ff100000 sg_len=266240 sg_off=0
pepito_load_app coherent_copy pa=0x00000000f7280000 len=266240 first16=7f 45 4c 46 01 01 01 00 00 00 00 00 00 00 00 00
scm_call failed: func id 0x32000101, ret: -2, syscall returns: 0xffffffda, 0x0, 0x0
pepito_load_app scm ret=-22 resp.result=4294967258 resp.type=0 resp.data=0 cmd_len=84
```

Interpretation: SMC64-vs-SMC32 alone is not the blocker. This boot still used the coherent-copy override, so the follow-up diagnostic below removed that override and retested the stock-like QSEECom heap physical address (`pa == sg_dma == sg_phys`) with only the SCM convention changed.

## Normal-heap + SMC32 diagnostic result - 2026-06-12

The clean boot-only retest removed the coherent-copy override while keeping the SMC32-first SCM detection. It still failed at the same secure-loader boundary:

```text
pepito_load_app name=keymaster arch=1 mdt=6940 img=263610 len=266240 qsee=0x1000000 commonlib=1 commonlib64=0
pepito_load_app nents=1 orig_nents=1 pa=0x00000000ff100000 sg_dma=0x00000000ff100000 sg_phys=0x00000000ff100000 sg_len=266240 sg_off=0
scm_call failed: func id 0x32000101, ret: -2, syscall returns: 0xffffffda, 0x0, 0x0
pepito_load_app scm ret=-22 resp.result=4294967258 resp.type=0 resp.data=0 cmd_len=84
QSEECOM: qseecom_ioctl: failed load_app request: -22
```

Interpretation: the stock-like QSEECom heap path, physical address selection, and SMC32 app-start call still reach TZ and are rejected with `-38`. The follow-up buffer-window diagnostic matched the expected compact `.mdt` plus appended `.b00`... payload layout through the first payload segment. The logged `end-16` value was all zero because it was taken from the page-aligned allocation end (`len=0x41000`), not the QSEE image end (`img_len=0x405ba`). The source now logs `img-16` and `alloc-16` separately to avoid that ambiguity.

## Stock modem image and keymaster source check - 2026-06-13

The latest buffer-window boot showed the expected bytes at the important offsets:

```text
buf[0x0]=7f454c46010101000000000000000000
buf[0x114]=04000000030000000000000028900700
buf[0x1000]=ffffffffffffffffffffffffffffffff
buf[0x1b1c]=7f454c46010101000000000000000000
buf[0x1c30]=04000000030000000000000028900700
buf[0x3638]=020050e30200001a010051e30000001a
buf[mdt-16=0x1b0c]=ffffffffffffffffffffffffffffffff
buf[alloc-16=0x40ff0]=00000000000000000000000000000000
```

`alloc-16` is zero because the ION buffer length is page-aligned (`len=0x41000`) while the image length passed to TZ is `img_len=0x405ba`; those bytes are padding beyond the image. The diagnostic now logs `img-16` separately, whose expected value is `1c610700170000002061070017000000` for the current partition-derived keymaster image.

The full stock `modem.bin` was inspected with 7-Zip. It is a FAT16 firmware image and includes `image/cmnlib.*`, `image/cmnlib64.*`, `image/dhsecapp.*`, and many other QSEE apps, but no `image/keymaster.*` or keymaster-like filename. Stock and current HAL strings both request `QSEECom_start_app(..., "keymaster", ...)`; neither names `dhsecapp`.

Implication: the staged split files are structurally correct, but we may still be using the wrong loading model. Pepito's keymaster appears to be partition-backed, while most modem FAT trustlets are normal dynamic QSEE apps. If TZ rejects the partition-derived image through `QSEOS_APP_START_COMMAND`, the next useful experiment is to determine whether the dynamic loader rejects only the partition-backed keymaster image or rejects all renamed/foreign QSEE apps under this path.

## QSEECom driver history inspection - 2026-06-12

The 4.19 kernel history does not contain a clean local commit that changes the userspace `QSEECOM_IOCTL_LOAD_APP_REQ` path from the stock 3.18 ION API to the current dma-buf API. `drivers/misc/qseecom.c` entered this tree via the Kona snapshot commit `28cfbbcf6e9b` (`qseecom: Add qseecom driver snapshot for kona`), and that initial 4.19 snapshot already used `qseecom_vaddr_map()`, `dma_buf_map_attachment()`, and `sg_dma_address(new_sgt->sgl)` for userspace app loading.

Relevant history checked:

- `c781a92d3789` (`qseecom: Change in buffer sharing mechanism in qseecom`) changes send/modified-command buffers after a TA is loaded; it does not change the failing `qseecom_load_app()` path.
- `3dd92791de57` and `e30e13419cec` switch kernel-client firmware loading to `ION_QSECOM_TA_HEAP_ID` and cached allocations. That affects `__qseecom_allocate_img_data()`, not the userspace `QSEECom_start_app()` path used by keymaster/gatekeeper blobs.
- `921d4989bd71` changes dma-buf cache operations around SCM calls. The coherent-buffer test makes cache maintenance less likely as the primary keymaster app-load blocker, but this remains relevant if later tests show different behavior from the normal QSEECom heap path.

Implication: a full revert of `qseecom.c` to stock 3.18 is likely too broad because the 4.19 driver also changed device init, dma-buf ownership, kthreads, smcinvoke support, and shmbridge plumbing. If the normal-heap + SMC32 boot still fails, the safer direction is a small compatibility path inside current `qseecom_load_app()` that emulates the stock loader behavior as closely as possible, rather than wholesale replacing the driver.

## Clean-data boot result - 2026-06-13

`/home/kyle/android/lineage-23/serial.log.9` is the first clean `/data` boot
after the preloaded-keymaster alias path. Important current-boot lines start
after the noisy `prev:` ramoops records. Key observations:

- `init.pepito.qseecom.sh` ran successfully before keymaster.
- `vendor.keymaster-3-0` and `keystore2` started normally.
- `qseecom_query_app_loaded()` found preloaded `keymaster64` and aliased
  userspace `keymaster` to app id `65537` with `app_arch=0`.
- The logged QSEE send commands from keymaster all returned `ret=0`; the
  `earlyBootEnded` sequence also completed.
- `sys.boot_completed=1` was reached around `[194s]`.
- Serial alone made the `KEY_REQUIRES_UPGRADE` crash look absent, but recovery
  root later mounted `/data` read-only and pulled dropbox/tombstone artifacts.
  Those artifacts show the same system_server crash on fresh post-wipe state:
  `SyntheticPasswordCrypto.decryptBlob()` fails because keystore2 sees
  `Error::Km(KEY_REQUIRES_UPGRADE)` during `begin()`.
- The zygote tombstone is secondary: zygote aborts after repeated system_server
  crashes with `session socket read failed: Connection reset by peer`.

Next proof step is a vendor/full flash with keymaster userspace diagnostics.
The added logs are tagged `pepito_km3`, `pepito_km_core`, and `pepito_km1` and
should reveal whether the fresh synthetic-password key blob was stamped with an
old/current `OS_PATCHLEVEL`, which auth set contains the version tag, and what
`upgradeKey()` returns.

## Recovery artifact correction - 2026-06-13

Recovery root adb was useful after `serial.log.9` because `/sys/fs/pstore` and
`/data` crash artifacts were available. `/data` mounted read-only from
`/dev/block/by-name/userdata`, and the useful files were pulled under
`flash-staging/recovery-pstore/`:

- `dropbox-after-serial9/dropbox/system_server_crash@*.txt`
- `tombstones-after-serial9/tombstones/tombstone_00`
- `pmsg-ramoops-after-serial9`
- `console-ramoops-after-serial9`

The three system_server crash reports are identical in cause:
`SyntheticPasswordCrypto.decryptBlob()` fails while unlocking the unsecured user,
with keystore2 returning `Error::Km(KEY_REQUIRES_UPGRADE)` from
`upgrade_keyblob_if_required_with(...)`. This happened after formatting `/data`,
so the active issue is no longer simply stale Android 8 credential state. The
loader/QSEE send path is alive, but Android 16's KM1/KM3 compatibility layer is
creating or consuming a blob that immediately requires upgrade and then cannot be
upgraded successfully.

A new diagnostics patch logs:

- `pepito_km3`: HIDL method, profile, message version, current OS/patchlevel,
  key blob sizes, selected input tags, and returned keymaster error for
  `generateKey`, `getKeyCharacteristics`, `importKey`, `upgradeKey`, and
  `begin`.
- `pepito_km_core`: exact version-binding failure source from
  `CheckPatchLevel()`, including tag, auth-set source (`tee` or `sw`), stored
  patchlevel, and current patchlevel.
- `pepito_km1`: KM1 passthrough create/upgrade state, including where
  `OS_VERSION` and `OS_PATCHLEVEL` were stored and the final `UpgradeSoftKeyBlob`
  result.

Because these logs are in the vendor keymaster userspace stack, boot-only is not
enough for this experiment. Flash at least `vendor.img`; a full flash is the
least ambiguous.

## Open questions

- Does the next vendor/full flash show fresh `generateKey` stamping
  `OS_PATCHLEVEL` lower than the current Android 16 patchlevel?
- If the stale patchlevel is in the `tee` auth set, do we need a pepito-specific
  KM1 passthrough compatibility fix that makes version tags software-enforced or
  makes `UpgradeKeyBlob()` update the pseudo hardware set?
- Is hardware gatekeeper still needed for Android 16 credential semantics, or can
  this device ship hardware keymaster with software gatekeeper?
- After keymaster blob upgrade/use is fixed, can Lineage 23
  generate/sign/verify/delete a fresh disposable TEE key through
  `keystore_cli_v2` with the current preloaded `keymaster64` alias path?
