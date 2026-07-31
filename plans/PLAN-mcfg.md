# PLAN — MCFG / vendor modem_config: carrier MBN refresh + OOS-recovery tuning

**Goal:** ship the stock `/vendor/modem_config` carrier-MBN delivery path (or prove it's moot), with
one concrete hoped-for payoff: shorten the **~95–97 s out-of-service recovery** Gold shows at cell
edge on the road, and generally run the modem on the carrier config Palm intended rather than
whatever is baked into modem firmware.

**Status: Phase 0 recon DONE 2026-07-30 (DUT1/USB) — decision gate hit: SAME VERSIONS EVERYWHERE
→ delivery/activation work (Phases 2–3) PARKED.** The modem already stores + selects the stock
v1.4 set (loaded in stock days, EFS-persistent), and our A16 qcril's own MBN pipeline is alive
(`ro.vendor.ril.mbn_copy_completed=1`, copies from `/vendor/firmware_mnt/image/modem_pr/mcfg/`,
per-ICCID selection proven: Verizon SIM → CDMAless-Verizon 07-09, Roamless → ROW_Generic_3GPP
07-30). No `/vendor/modem_config` staging needed. Remaining thread = narrowed Phase 1: decode
CDMAless-Verizon v0x7010214 — does it carry OOS/scan-timer items at all? Full evidence:
`diag-tools/mcfg-lane/NOTES.md`. TODO: confirm CDMAless-Verizon active on Gold (USB only —
BHy/TCP-adb guardrail).

---

## Motivation (why reopened after the 07-09 exoneration)

- Two captured `!`/emergency-only episodes (2026-07-24 bench, 2026-07-30 road drive) show the same
  deterministic signature: serving cell lost at rsrp −108…−117 → emergency-camp on loudest foreign
  carrier (cause-13 denial = the `!`) → re-registered Verizon after **95 s / 97 s**. RF path is
  proven fine (side-by-side vs Pixel 9: 1–3 dB delta, 2026-07-30). The residual lever is the
  modem's **OOS re-scan cadence and band-scan priorities — classic MCFG (NAS/System-Selection)
  territory.** Memory: `statusbar-bang-tmobile`.
- Stock A8.1 ships `/vendor/modem_config/` (mbn_ota v1.4: verizon/cdmaless, tmo/commerci,
  att/volte, common/row) and its RIL **actually loads one** (`persist.vendor.radio.sw_mbn_loaded=1`).
  Our A16 build stages nothing — the modem runs on its **firmware-baked** config set instead.

## What is already known (do not re-derive)

From `PLAN-mbn-loader.md` (2026-07-09, tool retained in `diag-tools/pdc-mbn-loader/`):

- Modem EFS already contains 4 firmware-baked carrier MCFGs; **CDMAless-Verizon (v0x7010214) is
  selected + active**. So the 07-09 question ("is any config active?") is answered YES — the MBN
  lane was exonerated *for the attach blocker*. **This lane's question is different: is the active
  config the RIGHT/CURRENT one, and does the stock-shipped MBN differ in ways that matter
  (OOS timers, band scan, acq priorities)?**
- Working PDC QMI client exists: `diag-tools/pdc-mbn-loader/` (`list` read-only proven on-device;
  `load/select/activate` M2 write path built, compile-clean, **never run**). Run recipe:
  `LD_PRELOAD=libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64 ./pdc-mbn-loader list` as root.
  ⚠️ Tool's SW/HW config-type enum is inverted vs this blob — carrier configs enumerate under
  config_type=1 ("HW" label).
- `mcfg` partition (mmcblk0p41) is blank/unused; delivery is filesystem (`/vendor/modem_config`) →
  qcril copies to `/data/vendor/modem_config` → PDC load. Our `init.qcom.rc:258` already creates
  the /data staging dir.
- Stock source for the MBNs: pull off Silver (stock 8.1, TCP 10.0.2.106) or
  `backup-stock-android-8.1-AML0/`.

## Phases

### Phase 0 — Recon (read-only, bench-safe, no Kyle needed) — ✅ DONE 2026-07-30
- [x] Pull stock `/vendor/modem_config/` (from the 8.1 backup tree — Silver no longer stock) into
      `diag-tools/mcfg-lane/stock-modem_config/`; `mbn_version.txt`=1.4, `mbn_ota.txt`= the 4 NA
      MBNs.
- [x] Parse version/metadata out of stock `verizon/cdmaless/mcfg_sw.mbn` — MCFG_TRL trailer says
      **v0x7010214 "CDMAless-Verizon"** = exactly the version stored in the modem (and the same
      for all four: TMO 0x7010558, ATT 0x7010373, ROW 0x701084c). Modem-stored sizes match the
      STOCK files byte-count-exact (49700/40932/39384/34012) — the stored set IS stock's v1.4,
      loaded via the OTA path in stock days. Firmware_mnt copies are 3–4.3 KB smaller (different
      signing segment?) but same versions.
- [x] Witness check — replaced by direct PDC evidence on DUT1 (Silver is no longer a stock
      witness). Bonus finding: our A16 qcril runs the full mbn_ota pipeline itself
      (`ro.vendor.ril.mbn_copy_completed=1`, copies firmware_mnt→/data, per-ICCID select works:
      ROW_Generic_3GPP active with Roamless in, CDMAless-Verizon was active 07-09 with Verizon).
- **Decision gate:** if stock loads the SAME version the firmware already has active → lane is
  cosmetic; park (ship `/vendor/modem_config` for completeness only, skip activation work).
  If stock's is newer/different → Phase 1.

### Phase 1 — Diff the configs (still read-only)
- [ ] Decode both MBNs (stock-shipped vs firmware-baked; the baked one may be extractable from the
      modem firmware images in `fsg`/NON-HLOS or via PDC read if supported) and diff the NV/EFS
      item sets. Items of interest: NAS OOS scan timers (`wcdma/lte oos scan` NV items, BSR/service
      search timers), LTE band preference/priority, acquisition-DB behavior.
- [ ] Answer: **does the config even carry OOS-timer deltas?** If neither config touches scan
      cadence, the 95 s is hard-coded modem behavior → this lane cannot fix it (say so in
      `statusbar-bang-tmobile` and downgrade the lane to "ship for parity only").

### Phase 2 — Activation experiment (modem-EFS mutating — **Kyle drives**, per
[[feedback-user-does-build-flash]] no unattended writes)
- [ ] `dd`-backup modemst1/modemst2/fsg/fsc first (07-09 flow did this; diff after).
- [ ] pdc-mbn-loader `load` stock mcfg_sw.mbn → `select` → `activate` (expect modem SSR — bench
      only, ⚠️ repeated modem restarts wedge MSS, memory `radio-rmts-buffer-rootcause`; recovery
      `ctl.restart qmux_qcrild`, and never QRTR-send to the modem node).
- [ ] Validate: attach + VoLTE + data all still work across a cold boot (the full
      [[qmux-bridge-lane]] chain must stay green); confirm new config id active via `list`.
- [ ] Measure: force an OOS episode on the bench (faraday bag / antenna attenuation or drive
      test) and time recovery vs the 95 s baseline.

### Phase 3 — Productization (only if Phase 2 shows benefit, or "parity-ship" if benign)
- [ ] Stage `/vendor/modem_config/**` into the pepito vendor tree (pepito-gated —
      `TARGET_DEVICE_PEPITO` or device-prop rc gate; sibling variants have their own configs).
- [ ] Decide the activation mechanism: (a) rely on qcril's own MBN path if the nightly blob does
      it (check `sw_mbn_loaded` on our build after staging — the A15 qcril may NOT have the A8
      stub problem), else (b) productize pdc-mbn-loader as a boot oneshot (SIM-ready + IIN match +
      version mismatch → load/select/activate; enforcing-ready sepolicy like `ims_enabler`).
- [ ] Release-notes entry + fold into `PLAN-release.md` commit sweep.

## Guardrails
- All PDC writes are Kyle-attended, bench-only, with EFS partition backups taken first.
- Modem SSR budget: keep activations rare; MSS wedges after repeated restarts.
- Never regen extract-utils on mithorium-common (IMS add-on guardrail) — MBN staging is
  hand-authored packaging, not extractor-driven.
- If the car/AA or telephony regresses after activation, revert = re-activate the old config id
  (PDC `select`+`activate` of v0x7010214) or restore the EFS dd backups (EDL-safe device).

## Success criteria
- Primary: road OOS recovery measurably < 95 s (or fewer `!` episodes per drive).
- Secondary: `sw_mbn_loaded=1`-equivalent parity with stock; config version matches stock's intent.
- Even a null result closes the last open thread in `statusbar-bang-tmobile` with evidence.
