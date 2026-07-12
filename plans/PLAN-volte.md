# VoLTE / IMS bring-up (pepito) — ⭐⭐⭐ SOLVED + PRODUCTIONIZED 2026-07-10 (ims_test_mode; v01-dialect modem)

## ✅ Productization COMPLETE 2026-07-10 (session volte3) — ladder items 2–5 all closed

**Everything below the fix itself is now done; the lane is CLOSED except in-call audio
(audio lane's problem). Awaiting one validation flash of the staged `ims_enabler`.**

1. **Reboot persistence PROVEN**: DUT rebooted (3h uptime), `ims_test_mode` read back 0
   (GET 0x26 TLV 0x13) and all three qipcall bools 1 (GET 0x37 TLVs 0x11–0x13) — the
   writes are modem-EFS-backed. IMS re-registered fully autonomously: REGISTERED, real
   IMPU `sip:+1425…@vzims.com`, SMS+VoIP FULL_SERVICE, no userspace nudge.
2. **NAS `usage_preference=1` (voice-centric) RESTORED** via nas-probe and validated the
   hard way: `radiocycle` (DMS LPM→ONLINE, clean PLMN selection + attach from scratch) →
   PS-ATTACHED home 311480 + IMS REGISTERED + SMS/VoIP FULL_SERVICE, framework voice+data
   IN_SERVICE (CS HOME with VOICE,SMS,VIDEO). The usage=2 NV workaround is RETIRED —
   with IMS registering, voice-centric domain selection no longer vetoes the attach,
   which also derisks the fresh-unit first-boot path ([[attach-domain-selection]] updated).
3. **`ims_enabler` boot oneshot STAGED (production self-heal)** — see section below.
4. Framework callback path: implicitly fine — calls/SMS work, ServiceState correct;
   nothing left to re-check.

### ims_enabler — what shipped (staged, uncommitted)
- `device/xiaomi/Mi8937/qmux/ims_enabler.c` — vendor cc_binary. dlopen()s the nightly
  `libqmi_cci.so`/`libqmiservices.so` (no import libs), force-ipcr preload via its rc
  stanza, self-gates on the qmux props. Read-compare-write of the 4 NV values
  (GET rsp TLV = SET req TLV + 1, ground-truthed from the IDL): steady state = 2
  read-only GETs, 0 NV writes. Retries internally (10s QMI timeout, 150s budget —
  covers modem PIL latency + the early-boot rmts blip SSR). Status prop
  `vendor.qmux.ims_enabler` = ok | applied | failed | off; logcat tag `ims_enabler`.
- `qmux/Android.bp` cc_binary; `device.mk` PRODUCT_PACKAGES (qmux block);
  `init.qmux.rc` service `qmux_ims_enabler` (class main, user radio, oneshot,
  LD_PRELOAD libqmi_force_ipcr.so) + `start` in the `on boot && qmux=1` block.
- **Sepolicy (enforcing-ready)**: `Mi8937/sepolicy/vendor/qmux.te` domain `ims_enabler`
  (init_daemon_domain, self:socket create_socket_perms, get/set_prop vendor_qmux_prop;
  vendor-lib dlopen covered by global non-coredomain vendor_file_type rules) +
  `file_contexts` ims_enabler_exec + mithorium-common `property_contexts`
  `vendor.qmux.` → vendor_qmux_prop.
- **Bench-VALIDATED on the live DUT** (standalone build `diag-tools/nas-probe/ims_enabler-bench`,
  also at DUT /data/local/tmp/): steady state → "already ok (0 NV writes)", prop=ok.
  Then simulated a virgin unit (`imss-probe setmsg 0x21 0x12 1`) → enabler detected,
  wrote 0, verified readback → "applied (1 NV writes)", prop=applied, IMS re-registered
  FULL_SERVICE within 20s. The fresh-flash / EFS-wipe / refurb path works.

### Validate after next flash (Kyle)
1. Cold boot → `getprop vendor.qmux.ims_enabler` → `ok` (steady state; `applied` on a
   fresh unit) and `logcat -s ims_enabler`.
2. IMS registers autonomously (dialer VoLTE path; or
   `LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64
   /data/local/tmp/imsa-probe`).
3. Call + SMS both ways still work (audio still expected dead until the ACDB lane lands).

## 🎉 Status update 2026-07-10 (session volte2) — IMS REGISTERED + SMS delivered + VoIP FULL_SERVICE + incoming call RANG

**Gate A demolished. Root cause was TWO stacked modem-side facts, fixed live in ~1h:**

1. **The 2017 Palm modem's IMSS (svc 0x12) only implements the v01 message dialect** (real
   table ends ~0x64). The v02 `SET/GET_IMS_SERVICE_ENABLE_CONFIG` (0x6B/0x6C) that A15
   qcril-hal exclusively speaks is **simply not implemented** — so enableIms could never work.
   Proven by a read-only `imss-probe get` sweep of msg IDs 0x20–0x90 + error-code calibration:
   **error 57 = QMI_ERR_INVALID_MESSAGE_ID (NOT "MISSING_ARG", which is 17)** — this falsifies
   the earlier "INTERNAL(3) on a well-formed enable-config = modem-STATE refusal" conclusion
   (unknown msgs return 3 or 57 mechanically in that range). Stock A8 qcril carries BOTH
   dialects (`qcril_qmi_imss_*` + `_v02`, selected via `qcril_qmi_imss_get_modem_version`) —
   which is why stock (and A11+volte-fix, which rides stock vendor RIL) could drive this modem.
2. **Modem NV had REG_MGR_CONFIG `ims_test_mode=1`** = IMS registration administratively OFF.
   Perfectly explains the standing signature: NOT_REGISTERED with `reg_failure_error=0`
   (never even attempts SIP). All other VZW provisioning was already correct from the active
   MBN: SIP port 5060, domain `vzims.com`, IMS APN `vzwims` (0x41), SMS-over-IP=1 (0x27),
   client-provisioning volte=1 (0x54). NOTE: `PLAN-mbn-loader.md` had already EXONERATED the
   MBN (Verizon CDMAless baked into fw + selected + active) — the "blank mcfg p41" suspicion
   in older notes was stale.

**The fix (live QMI writes over ipcr via extended `diag-tools/nas-probe/imss-probe`):**
```
imss-probe setmsg 0x21 0x12 0    # SET_REG_MGR_CONFIG ims_test_mode=0
  → IMS REGISTERED in seconds; sms_service_status=FULL_SERVICE; Kyle received a real SMS
imss-probe setmsg 0x36 0x10 1 / 0x11 1 / 0x12 1   # SET_QIPCALL_CONFIG bools (were 0,1,0)
  → voip_service_status=FULL_SERVICE
```
Framework followed on its own: `mVoiceRegState=IN_SERVICE`, CS `registrationState=HOME`,
`availableServices=[VOICE,SMS,VIDEO]`, RAT=LTE.

**✅ VALIDATED live by Kyle (same session): CALLS CONNECT BOTH WAYS + SMS BOTH WAYS on
Verizon. In-call AUDIO does not work — handed off to the AUDIO lane (`PLAN-audio.md` /
memory [[audio-status]]: voice-path ACDB + voice routing; media-to-speaker already works so
the substrate is fine). Telephony/IMS itself is DONE.**

**Method notes (reusable):**
- TLV layouts ground-truthed offline from the on-device IDL:
  `python3 diag-tools/pdc-mbn-loader/parse_idl_any.py libqmiservices.so 0x25318 <msgids>`
  (imss service object vaddr `0x25318` in the vendored libqmiservices.so).
  0x21 SET_REG_MGR_CONFIG req: 0x10 u16 pcscf_port / 0x11 string cscf / **0x12 u8 ims_test_mode**;
  0x26 GET rsp: 0x11/0x12/**0x13**. 0x36/0x37 SET/GET_QIPCALL (three head u8 bools =
  vt/mobile_data/volte in some order). 0x53/0x54 SET/GET_CLIENT_PROVISIONING.
  0x40 GET shows the provisioned IMPU (`sip:310480999990112@vzims.com` — MBN placeholder).
- `imss-probe` gained `setmsg <msgid> <tlvid> <val>` (single u8 TLV, generic).
- Read-only GET sweeps are safe: SET messages with all-optional TLVs no-op on an empty req.

**Remaining ladder (top = next):**
1. ~~Call test~~ ✅ DONE — calls connect both ways; audio → AUDIO lane.
2. **Reboot persistence**: ims_settings writes should be modem-EFS-backed (usage=2 was) —
   verify test_mode stays 0 and IMS re-registers autonomously on cold boot; also across
   airplane cycle + modem SSR.
3. **Restore NAS `usage_preference=1`** (voice-centric end-state) via nas-probe — with IMS
   now registering, the voice-centric attach should hold (A11 witness proved the network
   accepts it). Confirm attach + IMS + SMS all still work, then update
   [[attach-domain-selection]].
4. **Productize**: even if NV persists, ship a belt-and-suspenders boot oneshot
   ("ims-enabler": v01 writes test_mode=0 + qipcall bools, idempotent, force-ipcr preload,
   pepito/qmux-gated in init.qmux.rc) — protects against modem EFS wipe/refurb units and
   makes the fix self-healing. Alternative (heavier, later): source-build/patch qcril-hal ims
   module for v01. The framework Enhanced-4G toggle remains cosmetic (v02 writes still fail) —
   document in release notes.
5. Re-check the framework ImsRegistrationImpl callback path now that the modem genuinely
   registers (expected to just work — ServiceState already reflects it).

## ⭐ Status update 2026-07-09 (telephony session) — DATA_DAEMON_STATUS root cause FOUND + FIXED

**Kyle's symptom:** dialing fails after a few seconds with "Mobile network not available",
`!` over the signal bars during the attempt. Diagnosis: exactly the expected no-IMS failure —
VZW has no CS voice, IMS not registered ⇒ telephony has no domain for the call (the `!` is the
CSFB attempt suspending data; visible as VZWINTERNET SUSPENDED blips at each call attempt).

### Root cause of `DATA_DAEMON_STATUS` never set: file capabilities (pm-service trap #2)
`device/xiaomi/mithorium-common/config.fs` gave `vendor/bin/imsdatadaemon` and
`vendor/bin/ims_rtp_daemon` `caps: NET_BIND_SERVICE` → any file capability sets AT_SECURE=1 →
bionic silently drops LD_PRELOAD → **libqmi_force_ipcr never loads** → the daemon's QMI goes to
QRTR (strace: successful `socket(AF_QIPCRTR)`; 0 ipc_router ports; `grep force_ipcr
/proc/<pid>/maps` = 0) where the modem can't see it. imsdatadaemon isn't just a client — it
**hosts the QMI IMS_DCM service the modem consumes** (libqmi_csi) — so it initialized nothing
and waited forever. `imsqmidaemon` carries no cap, which is why QMI_DAEMON_STATUS=1 always worked.
- **Fixed live on the DUT**: `setcap -r` both binaries → restart → DATA_DAEMON_STATUS=1 in
  seconds, 7 ipcr ports, rtp restarted per rc chain. ⚠️ a vendor reflash restores the caps —
  the staged fix must land in the next build.
- **Staged**: config.fs `caps: 0` for all 4 imsdatadaemon/ims_rtp_daemon stanzas (with comment).

### What happened next (the remaining ladder, top = next lever)
1. **Modem IMS registered on VZW — twice — but does NOT hold.** After the fix (21:02) and after
   an airplane cycle (21:06): qcril NAS ind `IMS registered valid 1, Status 1; VOIP STATUS 1; VT 1`,
   and rmnet_data1 (IMS PDN) came up. Minutes later the direct IMSA query reads NOT_REGISTERED.
   **Next lever: catch the register→drop arc** — poll the new probe across an airplane cycle,
   read `reg_failure_error` at the drop. Tool: `diag-tools/nas-probe/imsa-probe` (QMI IMSA 0x21
   GET_REGISTRATION_STATUS/GET_SERVICE_STATUS over ipcr; `build-imsa.sh`; run with force-ipcr
   preload like nas-probe; on DUT at /data/local/tmp/imsa-probe).
2. **QImsService enableIms is REJECTED by the modem**: REQUEST_IMS_REG_STATE_CHANGE /
   SET_IMS_CONFIG / SET_SERVICE_STATUS all return error 2 ← qcril
   `set_ims_service_enable_config` gets **QMI err 3 (INTERNAL)** from modem IMSS (svc 0x12).
   A15 qcril-hal ims module is v02-only (no v01 fallback, no known toggle). Possibly benign for
   basic VoLTE (registration is autonomous), but compare on the stock A8 witness when attached:
   does its qcril use SET_IMS_SERVICE_ENABLE_CONFIG and does the modem accept it there?
3. **Framework never saw "registered"** (ImsRegistrationImpl callbacks never logged) — but at
   every moment it was queried the modem genuinely read NOT_REGISTERED, so this may resolve
   itself once the modem HOLDS registration. Re-check then; smali notes in memory
   [[volte-ims-status]] (regState 1=REG/2=NOT/3=REGISTERING; the "VOLTE ims registered" log
   line does NOT mean registered).
4. **DUT went USB-unreachable at 21:21** during the 2nd airplane cycle — enumerates as the
   normal ADB gadget but host gets `set config -71`; the identical earlier blip did NOT reboot
   the phone (qcrild pid survived) ⇒ likely alive with a wedged gadget/cable. Bench replug;
   then check /sys/fs/pstore for a panic just in case.

### Second half of the session (2026-07-10, post-reflash with the caps fix baked in)
Fresh build validated the fix: **`getcap` clean on both daemons, DATA_DAEMON_STATUS=1 from
COLD boot** (no live setcap needed). Attach healthy (PS-ATTACHED, 311480, LTE full service).
But across cold boot + airplane cycle + daemon/QImsService restarts, **the modem did not
register IMS this session** (the two transient registrations were the *previous*, pre-caps-fix
session — so autonomous registration is real but not reliable/spontaneous). Narrowed to two
independent gates:

**A) Modem-side: `SET_IMS_SERVICE_ENABLE_CONFIG` is rejected — likely THE modem gate.**
Built `diag-tools/nas-probe/imss-probe` (QMI IMSS svc 0x12 raw GET/SET over ipcr; `build-imss.sh`;
on DUT /data/local/tmp/imss-probe). Findings:
- IMSS is alive (an arbitrary GET msg 0x0020 returns result=0). So the probe path + service work.
- **GET/SET_IMS_SERVICE_ENABLE_CONFIG (0x006C/0x006B) both return `result=1 error=3` (INTERNAL)** —
  matches qcril's runtime `set_ims_service_enable_config_resp_hdlr: ril_err 40, qmi res 3`. This
  is a genuine modem rejection of the enable-config message family, NOT a probe artifact.
  qcril's enableIms (SET_IMS_CONFIG + SET_SERVICE_STATUS + REQUEST_IMS_REG_STATE_CHANGE) all fail
  error 2 downstream of it. Hypothesis: the A15 v02-only qcril-hal ims module speaks a
  SET_IMS_SERVICE_ENABLE_CONFIG shape/TLV set the 2018 Palm modem's IMSS rejects — OR the modem
  needs prior provisioning before it accepts enable.
  **Sharpened (imss-probe experiments):** other IMSS messages work fine (GET 0x20 → result 0;
  GET 0x64 → result 0 + TLV 0x11=`01 00 01 00`), and SET 0x6B with a *wrong* single TLV returns
  error 57 (MISSING_ARG — proves the message parses & is supported). So the modem selectively
  returns **INTERNAL(3) on a WELL-FORMED enable-config** — a modem-STATE refusal (provisioning /
  carrier-config / MBN / NV inside the modem), not message-unsupported or malformed-TLV. **Next:
  compare the stock A8 witness's IMSS enable exchange; investigate modem VoLTE provisioning / MBN
  state (blank mcfg p41 — see `mcfg-carrier-config` memory; stock ships MBNs in
  /vendor/modem_config).**

**B) Framework-side: Verizon requires VoLTE provisioning that our stack lacks.**
Active per-sub carrier config (via `cmd phone cc get-value`): `carrier_config_applied=true`,
`carrier_volte_available=true`, but **`carrier_volte_provisioning_required_bool=true`**. `isub`
dump shows `isEnhanced4GModeEnabled=-1` (VoLTE user toggle never set → carrier default).
The `persist.dbg.{volte,vt,wfc}_avail_ovr=1` overrides ARE all set, but those override
*availability*, not *provisioning*. So the framework consults VoLTE provisioning status
(ProvisioningManager) which on our stack is almost certainly not-provisioned → framework won't
drive VoLTE on. **Candidate fix: ship a pepito/311480 carrier-config overlay setting
`carrier_volte_provisioning_required_bool=false` (and confirm ENHANCED_4G_LTE_ON_BY_DEFAULT),
so the framework stops gating on provisioning** — the phh volte-fix hack bypassed availability
the same spirit but never touched provisioning. NOTE the modem registered autonomously before,
so B may be secondary to A; sequence: fix A (modem accepts enable) first, then B if the framework
still won't reflect it.

Standing: NAS `usage_preference=2` still LEFT SET in modem NV — restore usage=1 only after IMS
holds (memory `attach-domain-selection`). Watch tool left running on DUT:
`/data/local/tmp/imsa-watch.sh` → `imsa-watch.log` (imsa-probe every 3s) + `imsa-radio.log`.

## Status update 2026-07-09 (attach-debug session, DUT c39a6acf)

The staged build is on the device and the stack is substantially ALIVE:
- Validate 1 ✓ `pm path org.codeaurora.ims` present; both JNI symlinks resolve.
- Validate 2 ✓/✗ all three daemons running via init; `vendor.ims.QMI_DAEMON_STATUS=1`;
  but **`vendor.ims.DATA_DAEMON_STATUS` never set** (risk #1 below materialized —
  imsdatadaemon runs but never reports ready; also `service.qti.ims.enabled` and
  `vendor.ims.ENABLE_HELPER` absent vs stock reference).
- Validate 3 ✓ (better than lshal's client count suggests): QImsService is up (own pid)
  and exchanging traffic with IImsRadio — GET_IMS_CONFIG round trips, UNSOL indications
  (onRegistrationChanged_1_6, WFC roaming) received. ImsResolver bound MMTEL+EMERGENCY_MMTEL.
- Validate 4/5 **BLOCKED by the LTE attach blocker** (see memory `attach-domain-selection`
  + `diag-tools/captures/attach-nas-probe-20260709/FINDINGS.md`): no attach → no IMS PDN →
  IMS ends at sendBroadcastForDisconnected / "ImsService not currently available".

**Lane coupling:** the attach investigation's leading theory is that the modem's
domain selection refuses the VoLTE-only home PLMN while it considers voice unavailable —
i.e., this lane and the attach blocker may be two faces of one knot (and stock breaks the
loop somehow at boot: attaches voice-centric BEFORE IMS registration). Discriminators live
in the attach lane: modem F3 capture, nas-probe diff vs stock A11, data-centric experiment.

> **⚡ 2026-07-09 (volte session): the data-centric experiment PROVED the theory.** Writing
> NAS usage_preference=2 (DATA_CENTRIC, SET 0x33 TLV 0x21 via nas-probe) → the modem
> REGISTERED + PS-ATTACHED on home 311480 with LTE FULL SERVICE — reproduced 3×, now attaches
> autonomously — but BOUNCES attach↔detach every ~30–60s. No SetupDataCall activity at all
> (framework never tries) → bounce is likely modem/VZW policy detaching because IMS never
> registers. Full detail: memory `attach-domain-selection`. Consequence for THIS lane:
> **rmnet data plane is the critical path** (Kyle green-lit) — IMS SIP needs it, imsdatadaemon
> readiness needs it, and once IMS registers the voice-centric attach should hold natively
> (then retire the usage=2 NV override, which is currently LEFT SET on the DUT).

> Context: Verizon has no CS voice (3G/CDMA retired) — **without IMS registration the phone
> cannot place/receive calls**, even though SIM/LTE registration already works (qmux lane).
> The old `~/Projects/volte-fix` repo (used on the A11 phone) is a **phh-GSI hack** and is NOT
> ported: on a full device build the right fix is shipping the real QTI IMS stack. Two of its
> three ingredients were already native here (`persist.dbg.*_avail_ovr=1` in system.prop;
> `android.hardware.telephony.ims.xml` + privapp-permissions in mithorium.mk/configs).

## What was missing (root cause)

The framework-side QTI IMS stack was never in the build: `proprietary-files-qc-sys.txt`
lists it (kanged "from FP3"/"from sweet" — not extractable from Mi8937 stock), but
`vendor/xiaomi/mithorium-common/proprietary/` had no `system_ext/` at all (0/170 qc-sys
entries present; the vendor tree is a hand-curated subset — extraction likely ran against
the live device, self-perpetuating the gap). Verified on `c39a6acf`: no `org.codeaurora.ims`
package, no IMS init rc on /vendor, daemons present but never started and **not linkable**
(imsdatadaemon missing the CNE client-API chain, ims_rtp_daemon missing librcc).

Meanwhile the vendor half is ALREADY LIVE: qmux_qcrild registers
`vendor.qti.hardware.radio.ims@1.0–1.7::IImsRadio/imsradio0` (lshal, 0 clients) — the
framework consumer is the only missing piece. manifest.xml already declares radio.ims@1.7,
imsrtpservice, ims.callinfo, ims.factory.

## What is staged (all uncommitted; both device repos also carry other-lane WIP)

**New: `vendor/xiaomi/mithorium-common/ims/`** — self-contained add-on (own `Android.bp` +
`ims-vendor.mk`), deliberately OUTSIDE the generated proprietary tree so an extract-utils
regeneration can't clobber it. Source: the official `lineage-23.2-20260526` nightly OTA on
disk (same apk the official build ships ⇒ known-compatible with the 23.2 framework).
- 4 apks (`ims` = org.codeaurora.ims MMTEL ImsService, `qcrilmsgtunnel` [sharedUid
  android.uid.phone, re-signed platform], `imssettings`, `QtiTelephonyService`)
- 12 framework jars (dex_import: imscmservice V2.0–2.2, vendor.qti.ims.* 8, qcrilhook)
- 5 permission xmls (PRODUCT_COPY_FILES)
- 28 system_ext lib64 .so (9 collide with vendor-partition module names →
  `_system_ext` suffix + `stem:`), 2 install_symlink (priv-app/ims/lib/arm64 JNI links)
- 14 vendor lib64 .so = exact link-closure for the daemons (computed by recursive
  DT_NEEDED walk nightly-vs-phone): librcc + CNE client-API/data.factory/mwqem/slm/
  dynamicdds/data.qmi/latency + rcsconfig@1.0/1.1 vendor copies (`_vendor` suffix + stem)
- `PRODUCT_SOONG_NAMESPACES += vendor/xiaomi/mithorium-common` (repo had no soong modules
  before, namespace was never registered — required or all 60 modules are invisible)

**`device/xiaomi/mithorium-common/mithorium.mk`** — one inherit line for
`vendor/xiaomi/mithorium-common/ims/ims-vendor.mk` (bottom, next to the main vendor inherit).

**`device/xiaomi/Mi8937/qmux/init.qmux.rc`** — stock-shaped service definitions for
`vendor.imsqmidaemon` / `vendor.imsdatadaemon` / `vendor.ims_rtp_daemon` (names, sockets
ims_qmid/ims_datad, groups incl. vendor_qti_diag, and the stock prop chain
QMI_DAEMON_STATUS=1 → imsdatadaemon → DATA_DAEMON_STATUS=1 → rtp restart), each with
`setenv LD_PRELOAD libqmi_force_ipcr.so` (shim self-gates on persist.vendor.qmux.enable),
all `disabled`. The nightly's rc blobs are intentionally NOT shipped (no preload, would
free-run outside qmux). sepolicy domains exist (sepolicy-legacy-um: ims_exec,
hal_imsrtp_exec); device is permissive anyway.

**`device/xiaomi/Mi8937/qmux/bin/qmux-flip-on.sh`** — step 4: `start vendor.imsqmidaemon`
+ `start vendor.ims_rtp_daemon` after qmux_qcrild.

## Build + flash (Kyle)

Normal build (system_ext + vendor images both change) → flash → boot with
`persist.vendor.qmux.enable=1` as usual. Re-push diagcap hook after vendor flash if wanted.

## Validate (in order)

1. `pm path org.codeaurora.ims` → present; `ls /system_ext/priv-app/ims/lib/arm64/` →
   two JNI symlinks resolve.
2. After flip: `ps -A | grep -E "imsqmi|imsdata|ims_rtp"` → all three up (link closure
   proof); `getprop vendor.ims.QMI_DAEMON_STATUS` → 1, `getprop init.svc.vendor.imsdatadaemon`.
3. `lshal | grep IImsRadio` → clients > 0 (ims.apk bound).
4. THE observable: `dumpsys telephony.registry | grep -i ims` /
   `adb shell dumpsys phone | grep -iE "volte|ims.*reg"` → IMS registered; dialer shows
   VoLTE/HD icon; place a call on Verizon.
5. SMS over IMS (Verizon requires it) — send/receive.

## Known risks / follow-ups

- **imsdatadaemon runtime behavior**: link closure is complete, but at runtime it may look
  for the CNE daemon (`cnd`, deliberately not shipped — whole CNE section skipped). If it
  aborts/loops, options: ship the CNE section (qc-vndr+qc-sys "CNE - from FP3") or accept
  degraded (VoLTE usually registers via qcrild path regardless; imsdatadaemon matters for
  WFC/VT more than basic VoLTE).
- **RCS (imsrcsd) skipped** on purpose — not needed for VoLTE; rcsconfig jars/libs ship as
  deps only.
- WFC (WiFi calling) untested; persist.dbg.wfc_avail_ovr=1 is already set globally.
- Enforcing flip later: ims domains come from sepolicy-legacy-um; the LD_PRELOAD setenv on
  ims services may need the same treatment gnss got (see qmux gnss neverallow fix).
- volte-fix repo (`~/Projects/volte-fix`) stays A11-only; do not port.
