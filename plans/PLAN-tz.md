# LineageOS 23.2 — TrustZone (TZ) / SCM Interaction — pepito/PVG100

**Created 2026-06-29, resolved 2026-07-02** — investigation into whether a fundamental
DT/kernel gap in TZ interaction underlies the keymaster/gatekeeper/radio/modem/GPS
bring-up failures. **Answer: no.** The TZ "failures" that motivated this plan are
present and benign on stock too. This file now records the settled facts, the
evidence, and the one action item that survives (disable CQHCI/ICE inline crypto).

---

## Settled conclusions

1. **Palm TZ rejects `MEM_PROT_ASSIGN` (`hyp_assign_phys`) for everyone, always —
   including stock — and nothing depends on it succeeding.** Proven 2026-07-02 on
   `android11-adb` (stock 3.18, fully working modem) by re-running the
   `msm_sharedmem` probe via sysfs driver unbind/rebind:

   ```
   scm_call failed: func id 0x42000c16, ret: -1, syscall returns: 0x0, 0x0, 0x0
   hyp_assign_table: Failed to assign memory protection, ret = -5
   msm_sharedmem: setup_shared_ram_perms: hyp_assign_phys failed IPA=0x0160x00000000f7800000 size=1572864 err=-5
   msm_sharedmem: msm_sharedmem_probe: Device created for client 'rmtfs'
   ```

   Stock issues the same SMC64 function ID (`0x42000c16`), gets the same TZ rejection
   (`ret: -1`), warns, and continues — and its modem works, using a dynamically
   allocated AP buffer (`0xf7800000`, same class of address as our `0xf7300000`) with
   **no XPU/VMID grant at all**. QTI shipped `msm_sharedmem.c` with a dedicated
   warn-and-continue path for exactly this. The `hyp_assign_phys` failures on A16
   (memshare clients 1/3, rmtfs) are cosmetically identical to stock and **not a
   bug to fix**.

2. **SMC calling convention was never the issue.** Stock detects and uses SMC64
   (proven by the `0x4...`-prefixed function ID above). Separately, the 2026-06-26
   global-SMC32-first experiment (`PLAN-radio.md`) showed the call failing
   identically under SMC32. Both conventions rejected, on both kernels →
   convention is fully ruled out. **Do not build any SMC32-forcing patch.**

3. **The "-95 EOPNOTSUPP" that anchored the whole "TZ says unsupported" theory was
   an error-remap artifact.** TZ returns the *generic* error `-1` (SCM_ERROR). Our
   4.19 `drivers/soc/qcom/scm.c::scm_remap_error` maps `-1 → -EOPNOTSUPP (-95)`;
   stock 3.18 maps the same `-1 → -EIO (-5)`. Same TZ behavior, different errno
   spelling. (msm8937 has no Qualcomm hypervisor; a VMID-assignment call having no
   handler and returning a generic error is unremarkable.)

4. **Therefore the modem `rmts_get_buffer` ERR_FATAL is not TZ/SMC/hyp_assign** —
   and it is also not RFSA (`PLAN-sharedmem_qmi.md`, falsified 2026-06-29). The
   live suspect is the **RMTFS QMI (svc 14) ALLOC_BUFF exchange with `rmt_storage`
   itself**: the modem queries RMTFS right after powerup, and `rmts_get_buffer` on
   the modem is the client end of that exchange. Our `rmt_storage` is the nightly
   QRTR-native blob; stock runs a different, legacy-router build. Ownership of this
   thread: `PLAN-radio.md`.

5. **A16 SELinux is Permissive** (verified live 2026-07-02), so the
   `avc: denied ... rmt_storage ... uio/uio0/name` lines are audit-only noise, not
   a blocker. Do fix the genfs label before going Enforcing:
   `/sys/devices/platform/0.qcom,rmtfs_sharedmem/uio/...` needs a
   `genfs_contexts`/label so `rmt_storage` can read uio names under enforcement.

6. **The only TZ-adjacent real regression is 4.19-only: CQHCI/ICE inline crypto.**
   Our tree added `cqhci-crypto-qti.c` + `crypto-qti-tz.c` (stock 3.18 has neither —
   it never initializes inline crypto and its RPMB works without it). On A16 the init
   fails — `cqhci_crypto_qti_init_crypto: Error initiating crypto capabilities,
   err -19` → `mmc0: CQHCI version 5.10 Crypto init failed err -19` — leaving CQHCI
   half-initialized, the suspected upstream of the RPMB `-84 EILSEQ` CRC errors on
   the keymaster/gatekeeper path. **Fix = match stock: don't build/enable the crypto
   path.** This is the one surviving action item — see below.
   *(Decode correction 2026-07-02: the 16× `scm_call failed: func id 0x72000206`
   pstore lines this plan originally attributed to ICE are actually
   `TZ_OS_REGISTER_LISTENER_SMCINVOKE_ID` — qseecomd's smcinvoke-listener probe,
   which has a benign fallback to the legacy listener ID and appears on working
   boots too (`PLAN-gatekeeper.md` 2026-06-14). The ICE invalidate ID would be
   `0x42001006` (SIP, `TZ_SVC_ES`=16, cmd 6). So there is no direct pstore evidence
   of TZ rejecting an ICE call — only the `-19` capabilities failure above; the
   disable-to-match-stock action is unchanged.)*

---

## Action item: disable CQHCI/ICE inline crypto (keymaster/RPMB path)

Either mechanism works; pick one:

1. Remove `"cqhci_ice"` from the `sdhc_1` `reg-names` in
   `vendor-legacy/qcom/msm8937.dtsi` — `platform_get_resource_byname` returns NULL
   → "ICE not supported" → crypto init skipped, returns 0. Least invasive,
   pepito-scopable via DTS override.
2. Or build-level: exclude `cqhci-crypto-qti.c` (`CONFIG_MMC_CQHCI_CRYPTO=n` or
   equivalent).

Verify after: `cqhci_crypto_qti_init_crypto` no longer errors; RPMB `-84 EILSEQ`
cleared; `vdc keymaster earlyBootEnded` / gatekeeper enroll behavior per
`PLAN-gatekeeper.md`.

---

## Reference facts established by this investigation (still true, still useful)

- **Reserved-memory geometry is byte-identical to stock** (verified via
  `/proc/device-tree` + `/proc/iomem` on both devices): `other_ext_region`
  `0x84a00000/0x1e00000`, `modem_region` `0x86800000/0x6a00000`, `adsp_fw_region`
  `0x8d200000/0x1100000`, `wcnss_fw_region` `0x8e300000/0x700000`, all
  `removed-dma-pool; no-map` — static, TZ-owned from boot, independent of runtime
  `hyp_assign`. Not a missing-DT-entry problem.
- **Memshare DT is identical to stock** (client_1 GPS 2MB boot-time, client_2 FTM
  3MB, client_3 DIAG 5MB), and both kernels call `hyp_assign_phys` at the same call
  sites — all fail benignly (see conclusion 1).
- **QSEE itself is healthy on A16**: `qseecom.qsee_version = 0x1000000`,
  `vendor.qseecomd` runs, keymaster-3-0 registers. TZ interaction fails only for
  call families Palm TZ doesn't implement (`MEM_PROT_ASSIGN`, ICE key ops).
- **SMC function-ID decode** (for reading future pstore): `0x42000c16` = SMC64 |
  SIP | SVC_MP(0x0C) | MEM_PROT_ASSIGN(0x16) — benign, see conclusion 1.
  `0x72000206` = SMC64 | TZ_OWNER_QSEE_OS(0x32) | TZ_SVC_LISTENER(2) | cmd 6 =
  `TZ_OS_REGISTER_LISTENER_SMCINVOKE_ID` — qseecomd's smcinvoke-listener probe,
  benign (falls back to the legacy listener ID; fires on working boots too).
  `0x42001006` = SMC64 | SIP | TZ_SVC_ES(0x10) | cmd 6 = ICE key invalidate
  (`crypto-qti-tz.h`).

## Method lesson (reusable)

**Platform-driver sysfs unbind/rebind on the stock device re-runs any probe-time
SCM/hardware interaction with fresh dmesg — zero kernel builds.** This is what
settled a question two sessions of log archaeology couldn't (stock's boot logs
were unrecoverable: 256KB pstore, wrapped dmesg). Reboot the stock device
afterward — the rebind reallocates live buffers (e.g. the rmtfs buffer under a
running modem).

```bash
android11-adb shell 'echo -n "0.qcom,rmtfs_sharedmem" > /sys/bus/platform/drivers/msm_sharedmem/unbind'
android11-adb shell 'echo -n "0.qcom,rmtfs_sharedmem" > /sys/bus/platform/drivers/msm_sharedmem/bind; dmesg | tail'
android11-adb reboot   # restore clean state
```

## Related plans

- `PLAN-radio.md` — owns the modem `rmts_get_buffer` fatal; next test = strace
  `rmt_storage` across a modem SSR to capture the RMTFS ALLOC_BUFF exchange
- `PLAN-gatekeeper.md` — consumer of the CQHCI/ICE-disable action item
- `PLAN-sharedmem_qmi.md` — RFSA port (kept in tree; hypothesis falsified 2026-06-29)
- `PLAN-gps.md` — downstream of the modem fatal

## Devices

- `android11-adb` (`81eed371`) — stock 3.18, working modem/GPS/keymaster
- `android16-adb` (`c39a6acf`) — our 4.19 bringup
