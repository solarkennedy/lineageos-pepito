# PLAN — IPv6-only PDN comes up with NO DNS (dnses=[]) → data dead despite connected bearer

> **STATUS 2026-07-30: ✅ RESOLVED-IN-PRACTICE / root-cause reframed.** Roamless data now fully
> works on A16 (validated: bearer+DNS+VALIDATED+re-attach+browser ipinfo.io via Belgacom).
> The "v6-only no-DNS bearer" was AT&T's default-APN local-breakout PDN, reached when the OTA
> request carries no/HSS-unknown APN — not a DNS bug at any layer of our stack. See the
> 2026-07-30 sections at the bottom; ship-decision list in "Endgame".

**Discovered 2026-07-29** (session: Roamless SIM test on DUT1 `c39a6acf`). A cheap global-roaming
SIM (Roamless, Belgian Proximus IMSI `20601`) roaming on AT&T 310-410 gets an **IPv6-only** LTE
PDN. The bearer connects — address, gateway, P-CSCF, MTU all present — but **`dnses=[]`**. No DNS
→ network never VALIDATEs, nothing resolves, user sees "no data". US Mobile Warp (Verizon,
IPv4 PDN) is unaffected: v4 DNS arrives fine on our daily builds.

We would never have caught this without an IPv6-only SIM: **every v6-only PDN our ROM encounters
will have dead data.** This matters for roaming/travel eSIMs generally (they are increasingly
v6-only) and possibly for future carrier v6 rollouts.

---

## Reproduction environment (as left on DUT1, 2026-07-29)

- DUT1 `c39a6acf` (USB), Roamless SIM in, **adb root works** on this unit.
- APN row added by hand (was missing — see "Bug 1" below): carriers db `_id=3639`,
  name=`Roamless`, apn=`roamless`, mcc=206 mnc=01, type=`default,supl`,
  protocol=`IPV4V6`, roaming_protocol=`IPV4V6`.
- qcril verbose logging persist props are **still set** (survive reboot):
  `persist.vendor.radio.adb_log_on=1`, `persist.vendor.radio.ril_payload_on=1`.
  They only take effect after a qcrild restart:
  `adb shell "stop vendor.qcrild; setprop ctl.restart qmux_qcrild"` (⚠ `ctl.restart` is a
  property, not a command). Wait ~20 s; service re-registers on its own.
- Bounce the data call cheaply with `svc data disable; sleep 3; svc data enable`.
- Repro is 100% deterministic — every single setup on AT&T returns `dnses=[]`.

## Two stacked bugs (first one already fixed on-device, needs productizing)

### Bug 1 (root cause of "NO data at all", fixed on DUT1, needs a ROM-side decision)

Our `apns-conf.xml` has no Roamless entry for numeric `20601`. The framework cycled its five
known 20601 APNs (Proximus, Scarlet, Telenet, Eastlink, Iusacell — all `protocol=IP`), and AT&T
rejected **every one** with `ONLY_IPV6_ALLOWED(0x33)`; after exhausting them the framework
parked on `NO_SUITABLE_DATA_PROFILE` forever. Adding the correct APN (values above, per
https://help.roamless.com/en/articles/12299991-roamless-apn-settings) makes the bearer connect
reliably. Optional ROM improvement: ship a Roamless APN in our apns-conf overlay — low value
(users can add APNs), skip unless trivial.

### Bug 2 (the real lane): connected v6-only bearer has no DNS

## Evidence chain — where the DNS is lost (all captured live, deterministic)

Layer by layer, top down:

1. **Framework sees empty dnses.** `logcat -b radio`:
   `SETUP_DATA_CALL DataCallResponse: { cause=NONE(0x0) ... ifname=rmnet_data0
   addresses=[2600:380:.../64] dnses=[] gateways=[/fe80::...]
   pcscf=[/2001:1890:1f8:2060::1:4, /2001:1890:1f8:202f::1:4] mtu=1430 mtuV6=1430 }`
   Note the asymmetry: **pcscf populated, dnses empty** — this is the load-bearing clue.

2. **The framework parser is NOT eating them.** `RILUtils.convertHalDataCallResult`
   (`frameworks/opt/telephony/.../RILUtils.java:3376-3390`) would silently drop a
   space-joined `"dns1 dns2"` element, logging `Unknown dns:`. That fingerprint is **absent**
   from logcat (`grep -c 'Unknown dns'` = 0 across radio+main). Ruled out.

3. **The AIDL↔HIDL compat shim is NOT eating them.** Explore-verified: the qcril blob is
   IRadio **@1.5** (`device/xiaomi/mithorium-common/manifest.xml:45-50`), response lands in
   `hardware/interfaces/radio/aidl/compat/libradiocompat/data/RadioResponse-data.cpp:151-156`
   (`setupDataCallResponse_1_5`), struct conversion in
   `libradiocompat/data/structs.cpp:150-165`: `dnses`, `gateways`, `pcscf` are all
   `vec<string>` → `String[]` through the **identical** generic
   `toAidl(hidl_vec<hidl_string>)` (collections.h:32-39). No delimiter logic, no v4 filter,
   no per-field code. Structurally cannot lose dnses while pcscf survives. Ruled out.

4. **qcril itself never had them.** With verbose payload logging (props above), the DSI
   wrapper logs at call-up:
   ```
   [DsiWrapper] dsiGetAddresses
   [DsiWrapper]: dsi_get_ip_addr_count = 1
   [DsiWrapper]: ip address = 2600:0380:...        ✓
   [DsiWrapper]: gateway address = fe80::...        ✓
   [DsiWrapper]: dns address =                      ← EMPTY, right here
   [DsiWrapper] dsiGetPcscfAddresses
   [DsiWrapper]: pcscf address = 2001:1890:1f8:2060::1:4 2001:...   ✓
   ```
   So the loss is **at or below dsi_netctrl** (vendor blob): the QMI
   `WDS_GET_RUNTIME_SETTINGS` answer either lacks the IPv6 DNS TLVs (0x27 primary / 0x28
   secondary) or dsi fails to extract them. P-CSCF TLVs, which sit at *higher* TLV IDs in the
   same response, DO come through — which argues against transport truncation in our qmux
   path and toward **the modem genuinely not having/authoring v6 DNS**.

5. **The network's RA offers no rescue.** tcpdump during call setup
   (`tcpdump -i any 'icmp6 and ip6[40] == 134'` while bouncing `svc data`):
   AT&T RAs carry prefix (SLAAC works — kernel addr is flagged `dynamic`), MTU 1430, and
   **`Flags [other stateful]` (O-flag) with NO RDNSS option**. O-flag = "get other config
   (DNS) via stateless DHCPv6" — **which Android does not implement**. On normal phones DNS
   for such PDNs arrives via **PCO** (Protocol Configuration Options) through the modem →
   consistent with layer 4: the modem is the component that should be supplying DNS and isn't.

## Hypotheses, ranked

**H1 — Active Verizon MCFG mishandles v6 DNS PCO on foreign/roaming PDNs.**
The modem's carrier config governs what the UE requests in the PCO of the PDN Connectivity
Request (DNS-over-NAS: containers 0x0003 IPv6 DNS / 0x000D IPv4 DNS) and how the reply is
parsed. Our modem EFS has 4 firmware-baked MCFGs — **CDMAless-Verizon (ACTIVE)**,
Commercial-TMO, VoLTE-ATT, ROW_Generic_3GPP — see PLAN-mbn-loader.md RESULT section: MBN lane
was exonerated for *attach* (config present+active), but the *active config is
Verizon-tuned* while this PDN is AT&T roaming, v6-only. Verizon does not run v6-only PDNs the
way AT&T does; a Verizon MCFG failing to request/parse v6 DNS PCO here is very plausible.
**Directly testable — the tool already exists** (see Experiments E2).

**H2 — dsi_netctrl / qmux transport drops the DNS TLVs.**
Our qmux/legacy-IPC backport had a real response-decode offset bug class before
(resp-EI offset fix, see PLAN-rmnet / memory `rmnet-data-plane`). Argues against: P-CSCF TLVs
in the *same* WDS response survive. Testable with a raw capture (E1).

**H3 — modem fw simply never supplies v6 DNS (hardware/firmware ceiling).**
If E1 shows the modem's WDS response truly lacks 0x27/0x28 even under a matching MCFG, only
the framework fallback (Fix B) helps.

## Experiments for the fixing agent

**E1 — ground truth: capture the raw QMI WDS runtime-settings response.**
DIAG is dead on the DUT (memory `diag-rides-qrtr`), but we don't need it: strace the QMI
socket traffic of the data path. As root, attach strace to the qcrild process (or qmuxd),
filter sendmsg/recvmsg around a `svc data` bounce, and locate the
`WDS_GET_RUNTIME_SETTINGS` (msg 0x2D on WDS svc 0x01) response; check for TLVs 0x25 (v6
addr — known present), 0x27/0x28 (v6 DNS). The early-boot strace hook technique is in
`diag-tools/pepito-diagcap.rc` / memory `diag-capture-hook`, but a live `strace -p` is enough
here since the call can be bounced at will. Outcome: TLVs absent → H1/H3 (modem side);
TLVs present → H2 (our stack), go hunting in dsi/qmux with the resp-EI precedent.

**E2 — swap the active MCFG (H1 test). ⚠ MUTATES MODEM EFS — Kyle drives, per
[[feedback-user-does-build-flash]]; agent prepares commands only.**
`diag-tools/pdc-mbn-loader/` is a working PDC client (M1 `list` validated on this exact
modem 2026-07-09; note its SW/HW config-type labels are inverted vs this blob — carrier
configs enumerate under config_type=1). Sequence: `list` (record current state) →
select+activate **ROW_Generic_3GPP** (or VoLTE-ATT) → modem SSRs → re-test the Roamless
call → check `dnses`. Revert by re-activating CDMAless-Verizon (it is the baked-in selected
config — record its id from `list` first). Guardrails: run with
`LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so`; never QRTR-send to the modem node directly
(D-state wedge); repeated modem SSRs can wedge MSS — space them out.
⚠ If ROW/ATT config fixes DNS, do NOT ship "activate ROW for everyone" without checking the
Verizon daily-driver lanes (attach, VoLTE ims_test_mode NV, ACDB…) still hold — the whole
telephony stack was validated *under the Verizon MCFG*.

**E3 — cheap sanity cells (no risk):**
- Manual-select **Verizon** with the (now existing) Roamless APN: does Verizon hand this SIM
  an IPv4 or IPV4V6 PDN, and does v4 DNS arrive? (Earlier "Verizon worked" reports predate
  the APN fix — data was never actually up on Verizon either; only registration was.)
- Confirm Warp/Verizon IPv4 PDN still delivers DNS after any change (regression canary).

## Fix options

**Fix A (if H1 confirms): carrier-config-aware MCFG activation.** Productize per
PLAN-mbn-loader "Productization" sketch but keyed the other way: on non-Verizon-family SIM,
activate ROW_Generic_3GPP. Needs E2 proof + Verizon-lane regression pass first.

**Fix B (robust, ship regardless): framework DNS fallback for DNS-less v6-only cellular.**
Small patch in `frameworks/opt/telephony` — `DataNetwork.java`, where the
`DataCallResponse` becomes `LinkProperties` (search for where `response.getDnsAddresses()`
feeds `linkProperties.addDnsServer`): if the resulting DNS list is empty AND the network is
v6-only cellular, inject Google **DNS64** resolvers `2001:4860:4860::64` and
`2001:4860:4860::6464`. DNS64 (not plain 8888) matters: it lets the resolver's
`ipv4only.arpa` discovery kick in → clat/464xlat comes up → IPv4-literal apps work too.
Gate it (device overlay bool or sysprop, default on for pepito) and log when it fires.
This is the only viable runtime story — `ndc resolver setnetdns` is gone on A16, so there is
no adb-side workaround to offer users.

**Non-fix:** RILUtils space-split hardening (RILUtils.java:3376) is a real AOSP wart but NOT
our bug (fingerprint absent) — don't bother unless upstreaming for sport.

## Validation recipe (end-to-end)

1. Roamless SIM, AT&T (auto or manual): bearer up, `dumpsys connectivity` shows
   `DnsAddresses` non-empty and the cellular nc gains `VALIDATED`.
2. On-device `curl`-equivalent: open ipinfo.io/json in a browser → must load (Kyle's
   original acceptance test). If Fix B: also verify an IPv4-literal app path works (clat up:
   `ip addr | grep v4-rmnet` shows the 464xlat interface).
3. Warp/Verizon SIM regression: data + DNS + VoLTE unchanged.
4. `logcat -b radio | grep dnses=` shows either real (modem) DNS [Fix A] or the injected
   DNS64 pair [Fix B].

## Techniques bank (validated this session)

- ⭐ **DsiWrapper layer-splitter**: `persist.vendor.radio.adb_log_on=1` +
  `persist.vendor.radio.ril_payload_on=1` + qcrild restart → qcril logs exactly what
  dsi_netctrl handed it (ip/gw/dns/pcscf per call). Unambiguously splits "our stack ate it"
  from "modem never sent it" at the qcril boundary.
- qcrild restart syntax: `stop vendor.qcrild; setprop ctl.restart qmux_qcrild`.
- RA capture on cellular: `tcpdump -i any 'icmp6 and ip6[40] == 134'` while bouncing
  `svc data disable/enable` (RAs arrive within ~3 s of call-up, then periodically).
- Registry denial archaeology: `dumpsys telephony.registry` retains DENIED records with
  `rejectCause` + hashed-but-MCC/MNC-readable cell identity — survives logcat rotation.

## Session log 2026-07-29 (late) — A11 stock-witness OTA capture DONE, major twist

Kyle reflashed **DUT1 (`c39a6acf`) to the A11 diag rig** (SIM stays seated — no SIM gymnastics;
Gold keeps A16). Capture completed and validated; **phone powered down, analysis pending.**

**Headline finding: the stock stack gets a completely different PDN.** Same SIM, same AT&T
network, same modem fw+MCFG: A11 comes up with an **IPv4 PDN home-routed via Roamless's core**
— CGNAT addr `100.x/29-30`, **DNS 8.8.8.8/8.8.4.4 delivered by the network (PCO)**, MTU 1500,
VALIDATED, data fully working. A16 gets an AT&T-prefixed (`2600:380::`) **v6-only** bearer with
AT&T P-CSCFs and `dnses=[]`. Different address family, different PGW, different DNS outcome →
**new H4: the A16 stack's PDN request (attach-time APN / requested PDN type / PCO) differs from
stock's** — the capture can show exactly how. Also spotted in the smoke decode: a plaintext
`PDN connectivity reject (Requested service option not subscribed)` mid-session.

Other facts from the session:
- Roamless **auto-registered on AT&T** — no manual selection needed anymore (earlier manual
  attach evidently scrubbed the FPLMN entry, per 3GPP 23.122). Manual-scan UI quirk: the
  registered PLMN shows "connected" and tapping it errors "can't connect" — cosmetic, ignore.
- APN had to be added on A11 too (GSI apns-conf also lacks 20601/roamless): inserted via
  `content insert --uri content://telephony/carriers` + `preferapn`, `_id=3485`.
- Capture: **6 qmdl, ~520 MB** → `diag-tools/captures/a11-roamless-att-20260729/`.
  Timeline by file start time: 22:43 logger start (pre-registration) … registration ~22:55:38
  (file 3, `_2254…`), two `svc data` bounces ~22:56–22:58 (files 4–5).
- New toolchain (all in `diag-tools/`): `Diag-lte-ota.cfg` (stock F3 mask + LOG_CONFIG 0x73
  enabling all LTE log items 0xB000-0xBFFF — the stock Diag.cfg captures NO OTA log packets),
  generator `make_diag_lte_ota_cfg.py` (CRC/HDLC self-tested), decoder = fgsect/scat in
  `diag-tools/.scat-venv` (install from GitHub — PyPI "scat" is an unrelated joke pkg):
  `.scat-venv/bin/scat -t qc -d <files.qmdl> -F out.pcap` → `tshark -Y nas-eps -V`.

### 2026-07-30 — Full OTA decode DONE. The A16 bug is (almost certainly) APN loss, not DNS loss.

Decode: `full.pcap` in the capture dir (`.scat-venv/bin/scat -t qc -d *.qmdl -F full.pcap`,
then `tshark -Y nas-eps`). Ground truth from stock, per message:

- **Attach** (frames 8-35): PDN type **IPv4**, APN via ESM info transfer =
  **`internet.proximus.be`** (framework's initial-attach APN from the GSI apns-conf,
  protocol=IP). Granted: `internet.proximus.be.mnc001.mcc206.gprs`, **home-routed to the
  Proximus/Roamless PGW**, v4 CGNAT `100.80.x`, **DNS 8.8.8.8/8.8.4.4 via IPCP + 0x000D**,
  MTU 1500.
- **roamless PDN** (frames 41-48): requested PDN type **IPv4v6**, PCO asks DNS three ways
  (IPCP, 0x000D v4, **0x0003 v6 — stock DOES request v6 DNS**). Granted:
  `roamless.mnc001.mcc206.gprs` (home PGW again), **IPv4 + ESM cause 50 "PDN type IPv4 only
  allowed"** — **Roamless's PGW is v4-only; there is NO v6-only PDN on the stock path at all.**
- The recurring `PDN connectivity reject (service option not subscribed)` = APN `sos`
  (emergency) and `ims` — modem-initiated, benign.

**Implication for A16:** its `2600:380::` v6-only bearer with AT&T P-CSCFs and no DNS never
went home to Belgium — it terminated on an **AT&T local PGW** (wildcard/default-APN routing;
the P-CSCF+noDNS combo smells like AT&T's IMS-flavored default). Stock proves the same
SIM+APNs home-route and get v4+DNS. So the A16 defect is **upstream of DNS entirely: the APN
is not reaching the network**. New unified hypothesis **H4 (now primary; H1/H3 demoted)**:

> On A16 the modem attaches with an empty/default profile (attach-APN plumbing or timing —
> qcrild comes up late / is restarted in the qmux choreography, so `setInitialAttachApn` may
> land after attach), gets AT&T's wildcard v6-only PGW, and qcril then serves later
> setup requests from that attach bearer: v4-profile requests bounce locally with cause 51
> (= the observed `ONLY_IPV6_ALLOWED 0x33` cycle), the IPV4V6 roamless request "connects" by
> reusing it. One defect explains every observation, incl. why Verizon/Warp is fine (home
> subscriber → HSS default APN is correct regardless).

Shim audit (host-side): `libradiocompat/data/RadioData.cpp:125-130` + `structs.cpp:29-50`
pass `.apn` through faithfully for both `setInitialAttachApn_1_5` and `setupDataCall_1_6`
— the AIDL→HIDL layer is clean. Loss/timing must be qcril-blob ↔ dsi ↔ WDS-over-qmux, or
attach ordering.

**Next (needs DUT1 reflashed to A16):**
1. Bounce data with the (already-persisted) qcril verbose props; in `logcat -b radio` find
   `SET_INITIAL_ATTACH_APN` timing vs attach, and what APN qcril passes to dsi.
2. `strace -f -p <qcrild> -e trace=sendmsg,recvmsg -s 2000 -xx` during a bounce: the APN is
   ASCII-visible in WDS TLVs — confirm whether `roamless`/`internet.proximus.be` ever goes
   down the wire, and whether WDS profile writes succeed.
3. Radio-cycle (airplane toggle) after framework is fully up: if the attach APN then goes
   out correctly and DNS appears, the timing theory is proven and the fix is ordering
   (re-send initial attach APN / detach-reattach after qcril connects), not protocol.
4. Fix B (DNS64 fallback) stays as belt-and-braces for genuinely DNS-less carriers, but a
   proper H4 fix should make Roamless work with real (home) v4+DNS — no fallback needed.

## Related context (same session, separate finding — already closed)

Roamless SIM auto-selection initially parked emergency-only: repeated **EMM cause 11 "PLMN
not allowed"** (7× T-Mobile, 2× Verizon during provisioning lag) → each denial FPLMN-lists
that network on the SIM → auto-selection starves. Manual selection legally overrides FPLMN
and a successful attach scrubs the entry (3GPP 23.122). Not a ROM bug; documented in memory
`statusbar-bang-tmobile`. T-Mobile denials persisted → Roamless likely has no T-Mobile
agreement; AT&T + Verizon both register fine post-provisioning.

## Session log 2026-07-30 (part 2) — A16 re-test: WORKS. Lane resolved-in-practice.

DUT1 reflashed to our A16 build (`20260729`, userdata wiped). Findings, in order:

1. **Boot attach beats the framework.** Modem was IN_SERVICE/ROAMING on AT&T at
   06:32:00.169; `SET_INITIAL_ATTACH_APN` went out at 06:32:05.822 — **5 s too late** — and
   carried **Eastlink** (`wisp.mobi.eastlink.ca`, the framework's pick from the five 20601
   candidates; response took 77 s). So the boot attach bearer is the APN-less AT&T breakout
   PDN. Both halves of H4 observed directly.
2. **With the Roamless APN row added + preferred** (same `content insert` recipe, `_id=3639`),
   the very first `SETUP_DATA_CALL` raised an additional PDN with APN `roamless` and got the
   **home-routed IPv4 bearer WITH DNS**: `100.127.6.61/30, dnses=[8.8.8.8, 8.8.4.4]`,
   MTU 1500 — identical to stock. Network VALIDATED, ping 128 ms.
3. **Airplane-cycle re-attach: still good** (new bearer `100.109.157.102`, DNS present).
4. **Acceptance test passed**: browser loads ipinfo.io/json over LTE-R — egress
   `102.176.129.54`, org `AS6774 Belgacom International Carrier Services` (Proximus intl
   arm, US breakout in Ashburn VA → the ~128 ms RTT).

**Honest caveat — 07-29's "100% deterministic dnses=[]" did NOT reproduce today** and its
exact mechanism can't be reconstructed (that userdata is gone). Candidate explanations, not
mutually exclusive: (a) qcril bound the default request to the APN-less attach bearer in
yesterday's state (manual-selection attach history, APN possibly not preferred);
(b) **Roamless HSS provisioning lag** — the SIM was brand-new 07-29 (we saw cause-11 denials
from provisioning lag the same day); if `roamless` wasn't active in the subscriber profile
yet, AT&T serves the default-APN breakout PDN even for a correct request, and that PDN
carries no DNS. Both are consistent with every observation; neither is a defect in our
DNS path.

## Endgame — ship decisions

- [x] **Ship the Roamless APN + full latest community APN DB** — ✅ STAGED 2026-07-30 in
      `vendor/apn` branch `pepito-apn` = upstream `main` @ `3169b43` (2026-05-22, the entire
      community-maintained per-country DB; the `apns-conf` genrule globs all country XMLs
      into `apns-conf.xml` at build time, installed via `vendor/lineage/config/telephony.mk`)
      + our commit `425d4f7` "BE: Add Roamless APN" (SPN-matched `mvno_type=spn` "Roamless"
      so Proximus proper is untouched; IPV4V6 both ways, `default,supl`). Mechanism notes:
      vendor/apn tracks upstream main via repo sync (m/lineage-23.2 → main), so every future
      sync refreshes the whole DB; there is NO runtime APN-fetch in AOSP (Pixel carrier
      settings OTA is Google-proprietary) — DB updates ship with ROM builds.
      Follow-up: submit `425d4f7` to LineageOS Gerrit so it merges upstream and the local
      branch can be dropped; needs validation on next build (APN row should appear
      automatically for the Roamless SIM, preferred selection may still need one manual tap).
- [ ] **Initial-attach ordering (framework race, cosmetic-ish):** IA APN arrives ~5 s after
      the modem's boot attach. Consequence is only that the *attach* bearer is APN-less;
      framework raises proper additional PDNs afterward, so data works. No fix needed for
      Roamless. Park unless some carrier requires the attach APN itself to be correct
      (would then need a detach/reattach after IA APN lands, or qcril-side deferral).
- [ ] **Fix B (DNS64/8888 fallback for DNS-less bearers): now OPTIONAL hardening**, not the
      fix. The trap (attach-bearer reuse / HSS fallback PDN without DNS) is real — we lived
      it for a day — so a gated fallback still converts "dead data" into "mostly working"
      for the long tail. Decide at release-sweep time. If pursued: check `64:ff9b::` routes
      on the target network before choosing DNS64 vs plain 8888.
- [x] ~~E2 MCFG swap~~ — **CANCELLED, unnecessary**: no modem EFS mutation needed; H1/H3 dead.
- [ ] Release notes: Roamless/travel-eSIM users must add the APN (until the apns-conf entry
      ships) and may need one manual network selection on a virgin SIM (FPLMN starvation,
      self-heals; see memory `statusbar-bang-tmobile`).
- Regression canary whenever touching this: Warp/Verizon data+DNS+VoLTE unchanged.
