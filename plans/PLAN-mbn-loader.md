# PLAN — `pdc-mbn-loader`: userspace PDC client to activate the Verizon MBN

**Goal:** make Verizon-family SIMs attach on our ROM by loading + activating the carrier
config (MCFG/MBN) into the modem's EFS over QMI-PDC from userspace — replacing the function
the nightly Mi8937 qcril blob has **stubbed out**
(`qcril_qmi_nas_check_for_hardware_update()` = a 4-instruction no-op, disasm-proven, session
`simdebug1` 2026-07-08; see PLAN-qmux.md "Network attach blocker").

**Why userspace, not a reflash:** Kyle's stock-A11 unit is having TZ trouble, so the
"boot stock once, let its qcril activate the MBN" lane is unattractive. This tool does the
same modem-EFS activation with **zero flashing** — it talks a fully-supported QMI service on
an already-running bus. Nothing touches TZ/aboot/firmware partitions.

---

## Verified facts this is built on (session `simdebug1`, DUT `c39a6acf`)

- **PDC service is live on the modem** over the legacy IPC router:
  `dump_servers` shows `service 0x24 | instance 0x01 | node 0x00 (modem) | port 0x19`.
  (The qmux flip must be active — `persist.vendor.qmux.enable=1`, `qmux_qcrild` running —
  so the modem edge is on ipc_router. It is, by default, post-flash.)
- **The MBN file is already on the device:**
  `/data/vendor/modem_config/mcfg_sw/generic/na/verizon/cdmaless/mcfg_sw.mbn` (45356 bytes,
  mode 0400 radio:root). Staged there by `init.qcom.sh`'s copy step (from
  `/vendor/modem_config`, which we populated from stock A8 this session). The catalog also
  has att/tmo/row variants under `mcfg_sw/generic/na/…`.
- **The QMI client stack is all on-device and usable:**
  `/vendor/lib64/{libqmi_cci, libqmi_encdec, libqmi_common_so, libqmiservices, libqmi}.so`.
  Crucially `libqmiservices.so` **exports the PDC IDL service object**:
  `pdc_get_service_object_internal_v01` (T) and `pdc_qmi_idl_service_object_v01` (D).
  → We can use the standard QCCI API (`qmi_client_init_instance` /
  `qmi_client_send_msg_sync`) with the PDC service object and let the IDL do all wire
  encoding. **No hand-packed TLVs.** We only need the PDC message struct layouts
  (`pdc_service_v01.h` — public CAF header).
- **Transport selection:** libqmi_cci probes `socket(AF_QIPCRTR)` and picks QRTR if present.
  Our modem is on ipc_router, so the tool must preload `libqmi_force_ipcr.so`
  (`diag-tools/qmi-force-ipcr/`) — the same shim qcrild/gnss use — to force the ipcr backend.
- **`ril.subscription.types=RUIM`** on our build = modem in CDMA-era default mode; the
  `cdmaless` VZW config is exactly what flips it to LTE-only attach. Stock A8 with this SIM
  attaches in seconds (IMS + VZWINTERNET PDNs validated) — SIM/account are good.

## PDC message sequence (standard QMI PDC, service 0x24)

Read side (milestone 1, zero risk):
- `QMI_PDC_GET_SELECTED_CONFIG_REQ` (per config type: SW=0, HW=1) → currently-selected config id
- `QMI_PDC_LIST_CONFIGS_REQ` → all configs present in modem EFS (id + description)
- `QMI_PDC_GET_CONFIG_INFO_REQ` → version/description for an id

Write side (milestone 2, modem-EFS mutating):
- `QMI_PDC_LOAD_CONFIG_REQ` — chunked upload of the .mbn; each chunk carries
  `{config_type, total_size, frame offset, data}`; modem replies with an indication as it
  ingests; the config id is the **SHA/hash the modem computes**, surfaced in the load-done
  indication. (Integrity is modem-verified — a corrupt upload is rejected, not stored.)
- `QMI_PDC_SET_SELECTED_CONFIG_REQ` — select the just-loaded id for the SW slot, keyed by the
  subscription (`config_type=0` SW, subscription id 0).
- `QMI_PDC_ACTIVATE_CONFIG_REQ` — activate the selected id. Modem typically self-SSRs to apply;
  our qmux flow already tolerates modem SSR.
- Recovery messages exist and are one-shot each: `QMI_PDC_DEACTIVATE_CONFIG_REQ`,
  `QMI_PDC_DELETE_CONFIG_REQ`.

## Deliverable

`diag-tools/pdc-mbn-loader/` — a C tool (dynamically linked against the device's
`libqmi_cci`/`libqmi_encdec`/`libqmiservices`, run with the force-ipcr preload), following the
`diag-tools/rfsa-userd.c` + `qmi-force-ipcr` house style. CLI:

```
pdc-mbn-loader list                       # milestone 1: list configs + show selected (SW/HW)
pdc-mbn-loader load  <path-to.mbn>        # milestone 2: LOAD only, print returned config id
pdc-mbn-loader select <config-id-hex>     # SET_SELECTED for SW slot
pdc-mbn-loader activate <config-id-hex>   # ACTIVATE (warns: modem SSR)
pdc-mbn-loader deactivate|delete <id>     # recovery
```

## STATUS 2026-07-09 — M1 BUILT + compile-clean, awaiting on-device run

Tool built by subagent in `diag-tools/pdc-mbn-loader/`: `pdc-mbn-loader.c` (18.8K),
generated `pdc_service_v01.h` (from libqmi `qmi-service-pdc.json` + version-frozen `_v01`
convention), `qcci_compat.h`, QCCI headers in `qmi_inc/`, `build.sh`, and device libs pulled
for linking (`libqmi_cci.so`, `libqmiservices.so`, …). **Compiles clean** → aarch64 PIE
dynamic ELF `pdc-mbn-loader` (20.8K). Design as planned: `qmi_client_init_instance` with an
indication callback (`pdc_ind_cb`) since PDC answers via indications; standard QCCI
send-msg-sync; M2 write commands gated behind explicit `--yes-write-modem-efs` flag (safety —
`list` cannot mutate). **Not yet run on-device** — DUT was flapping/offline overnight
(host USB, not a device fault: every boot cycle showed SIM READY + qmux flip + PDC 0x24 on bus
before dropping). Build did NOT run any mutating PDC command.

**Run M1 (read-only) when DUT is stable — from the main session, no reflash:**
```sh
adb -s c39a6acf push diag-tools/pdc-mbn-loader/pdc-mbn-loader /data/local/tmp/
adb -s c39a6acf shell "chmod 755 /data/local/tmp/pdc-mbn-loader; \
  LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64 \
  /data/local/tmp/pdc-mbn-loader list"
```
Expect: selected SW/HW config ids + list of configs in modem EFS. The crux answer =
**is any SW config selected/active?** (suspected none → the RUIM-default attach bug). If the
decode looks shifted (garbage lengths/descriptions), the one constant to spot-check is
`QMI_PDC_CONFIG_ID_SIZE_MAX_V01` in `pdc_service_v01.h` vs the on-device `libqmiservices.so`.

## RESULT 2026-07-09 — MBN lane EXONERATED (config already active)

M1 `list` (SIM out, stable adb) decoded cleanly. Modem EFS already contains 4 carrier MCFGs
baked into the modem firmware: **CDMAless-Verizon** (v0x7010214), Commercial-TMO, VoLTE-ATT,
ROW_Generic_3GPP. Under the carrier config-type dimension (tool labels it "HW"; the tool's
SW/HW enum is inverted vs this blob — the mcfg_sw carrier configs enumerate under config_type=1),
**Verizon is the selected+active config**. `activate` on it returned indication
`ind_error=26 = QMI_ERR_NO_EFFECT_V01` (already active), and a dd diff of modemst1/modemst2/fsg/fsc
before vs after was **byte-for-byte identical** — no EFS change. Conclusion: **the carrier MBN was
never the attach blocker; it's present and active.** The stubbed `qcril_qmi_nas_check_for_hardware_update`
is real but irrelevant to attach (the config the modem needs is already applied). **Do NOT build the
MBN-loader productization** — moot. Tool + probe + parse_idl retained in `diag-tools/pdc-mbn-loader/`
as a working PDC client for any future modem-config inspection.

→ Real attach blocker is in the **AP-side subscription/mode setup** (see PLAN-qmux.md): modem shows
`ril.subscription.types=RUIM`, acquires an LTE cell but never completes attach, no EMM reject.
Same modem+config attaches on stock A8, so the delta is our qcril/telephony driving the subscription.

## Milestones & guardrails

- **M1 — read-only (build first; safe to run on-device unattended).** `list` + selected-config
  query. Proves the QCCI plumbing end-to-end and answers the open question: *does this unit's
  modem EFS have any SW config active?* (suspected none). No modem mutation whatsoever.
- **M2 — load/select/activate (build, compile-verify, push — but do NOT run the mutating
  path without Kyle).** The load→select→activate sequence writes modem EFS and triggers SSR.
  Per [[feedback-user-does-build-flash]], the subagent stages + compiles + runs **M1 only**;
  Kyle drives the first real activation.
- **Never** hand-send to the modem node over QRTR (D-state wedge) — N/A here (QCCI/ipcr), but
  keep the rule.
- Keep everything under `diag-tools/pdc-mbn-loader/`; do not modify the kernel or device mk/rc.

## Build

Cross-compile with the in-tree NDK clang (aarch64), dynamically linked; headers: vendor a
minimal `pdc_service_v01.h` (public CAF) + the QCCI headers (`qmi_client.h`, `qmi_idl_lib.h`)
— pull from the nightly/CAF or the device's `/vendor/include` if present, else vendor minimal
copies into the tool dir. Run recipe on device:
`LD_PRELOAD=libqmi_force_ipcr.so ./pdc-mbn-loader list` (as root; PDC is on the ipcr modem edge).

## Productization (later, after M2 validates)

Wrap as a boot-time oneshot: on SIM ready, if IIN ∈ VZW-family and no SW config active →
load+select+activate from `/data/vendor/modem_config/…/verizon/cdmaless/mcfg_sw.mbn`. Makes
Verizon-family SIMs (Verizon/Visible/US Mobile-VZW/Xfinity) attach automatically — the
permanent fix for the stubbed-qcril gap, no per-unit stock round-trip ever.
