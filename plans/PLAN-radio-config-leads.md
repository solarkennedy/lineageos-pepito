# PLAN — Config / partition / plumbing leads that might change how the modem REGISTERS (pepito/PVG100)

> **Created 2026-07-07 (radio14).** Brainstorm-capture file. Sibling of `PLAN-radio-rfsa-qrtr.md`
> (the root-cause lane) and `PLAN-radio.md` (full history). Premise: the modem's failure to retain
> RFSA (svc 0x1C) in its own service table is **data-dependent on SOMETHING it reads at boot**. This
> file enumerates the config/partition/AP-plumbing inputs that could be that "something," each with a
> cheap test. NONE is yet tested unless marked. Read `PLAN-radio-rfsa-qrtr.md` "What is PROVEN" first
> so you don't re-chase ruled-out lanes.

---

## Framing — what the gate must satisfy

The RFSA-retention failure is (a) **very early** (modem QMI/transport bring-up, BEFORE the EFS
transfer buffer) and (b) **transport-level** (the modem's ipc_router server table `DAT_88e5c760`
never gets a svc-0x1C node, though it retains svc 0xE from the same AP broadcast — see
[[radio-rmts-buffer-rootcause]] radio13). So any "config" that gates it must be **read/applied before
or during modem QMI-transport bring-up.** That ranks the leads below: transport-edge + early-NV
config outrank late config (MCFG-sw) which outranks pure-RF config.

**Transport fact (radio14, live A16 DT):** the modem edge is **SMD**, not glink — DT shows
`qcom,mss@4080000` (`compatible = qcom,pil-q6v55-mss`, `qcom,firmware-name = modem`) + `smd` +
`qcom,rpm-smd` + `qcom,smdpkt`; **no glink/qrtr edge node**. So QRTR binds the SMD **"IPCRTR"**
rpmsg channel, and the RFSA server-add reaches the modem over that SMD edge. How that edge is defined
in the AP device tree is the config closest to "how the modem registers."

**The unifying move (applies to most leads):** pepito is a hand-graft; **official santoni is the
known-good on the SAME 4.19 tree + same modem family.** Santoni sources are on Stellaris16
(`10.0.2.43`): `~/Personal-Projects/android_kernel_xiaomi_msm8937` and
`~/Personal-Projects/android_device_xiaomi_Mi8937`. Most leads below reduce to **diff pepito vs
santoni** for one plumbing surface. Same logic that fixed sensors + audio.

---

## ⚡ RESULTS — all 6 leads investigated (radio14, 2026-07-07, read-only agent sweep)

**Every config/data surface we could check came back equivalent-to-stock/santoni. Nothing here is
the gate. This narrows the problem to two things only: (a) device-local EFS/NV in modemst1/2, which
ONLY P0 (stock-on-DUT) can settle, and (b) the dynamic/timing "H-window" — the replay-burst shape —
which N1/P2 tests. The static/config hunt is exhausted; the answer is behavioral.**

| Lead | Verdict | One-line |
|---|---|---|
| **1 — SMD/QRTR transport DT** | ✅ FALSIFIED | Modem edge byte-equivalent to santoni (IPCRTR, smd-edge 0, remote-pid 1, spinlock bits, smp2p 435/428, SPI 25/26/27, qrtr net-id 1, `net/qrtr/smd.c`); 3 deltas all benign (rmtfs_sharedmem is on the *working* svc-0xE side; smem-id=421 log-only; i2c_6 audio). |
| **2 — EFS/NV** | ⏸ DEFERRED → P0 | Modem opens only modemst1/2, fsc, fsg before fatal (dies before tunning/simlock). EFS2 opaque to host tooling (no NV-item diff possible from backups). Failure *shape* argues against an NV RFSA-disable (client is active, retries 10×). Not favored; P0 is the only test. |
| **3 — persist RFS store + tftp-served files** | ✅ NEGATIVE | rfs/hlos_rfs tree + the 2 populated .txt files byte-identical to stock; SELinux labels identical; tftp_server serves only persist/rfs (RW) + firmware mounts (RO, = modem image, unchanged) + ramdumps. No served config file differs. tftp_server stable (no crash-loop this boot). |
| **4 — devcfg / XPU** | ✅ RULED OUT | md5 differs (2018 vs 2020 Palm signing vintage — only diff is X.509 cert dates) but XPU/memory config functionally identical: every region base addr + all property values match, seg3 byte-identical. devcfg==devcfgbak on each unit. |
| **5 — MCFG** | ✅ CLOSED (premise corrected) | mcfg partition blank on BOTH (unused). pepito's MCFG arrives via firmware_mnt/PDC (mithorium image ships full hw+sw set → copied to /data/vendor/modem_config OK). Only gap = `sw_mbn_loaded` unset, purely downstream of the fatal. Do NOT stage Palm MCFG (hw must match the mithorium modem). |
| **6 — socinfo / HW-ID** | ✅ EXONERATED | SMEM item 137 byte-identical A16(4.19) vs A11(3.18) except per-die serial; all decoded soc0 fields match (soc_id 313, raw_id 107, hw_platform MTP, subtype 170, machine MSM8940, build_id 8937A-FAASANAZA-40000000). Stock read primitive: `/d/smem/build`. |

**Net synthesis:** the modem reads the SAME data and the AP presents the SAME transport on pepito as
on the known-goods. Combined with radio13 (AP delivery of both 0xE and 0x1C to the modem is perfect
and symmetric on the wire), the surviving root-cause space is exactly two items — **P0** (is it
device-local EFS/NV? — one flash) and **N1/P2** (is it the replay-burst SHAPE/timing? — one build,
staged). If both come back dead, only the parked RE lane (N3: decode `FUN_8755acf0`; N4: live-read
`DAT_88e5c760`) remains. See `PLAN-radio-rfsa-qrtr.md`.

---

## Lead 1 — AP-side SMD/QRTR modem-edge device tree  ★ HIGHEST (config we own, closest to registration)
The server-add rides the SMD IPCRTR channel. If pepito.dts defines that edge even slightly
differently from santoni (FIFO size, edge label/id, `qcom,smd`/`qcom,smd-edge` props, rpmsg intents,
the `qcom,smem-states`/mbox wiring on `qcom,mss`), the modem's ipc_router can complete HELLO yet
mishandle specific control messages → drops the 0x1C server-add. This is the H-parse hypothesis's
AP-side root.
- **Test (free, no build):** diff the modem transport nodes pepito vs santoni:
  - Live DT on A16: `find /proc/device-tree -path '*mss*' -o -path '*smd*'` and dump each node.
  - Source: pepito.dts `qcom,mss@4080000` + smd/smsm/smp2p/`apps_smsm`/`modem_smsm` + any
    `qcom,smd-modem`/`smdtty`/qrtr nodes, vs santoni's DTS on Stellaris16.
  - Kernel: which qrtr backend binds (`drivers/net/qrtr/` — `smd.c`/`ns.c`) and the rpmsg/smd
    channel name it expects ("IPCRTR"); confirm the SMD edge (`drivers/soc/qcom/smem.c`/`smsm.c`/
    `smd`/`glink`) matches santoni's config for the modem remote-proc.
- **If a delta is found:** converge pepito's node to santoni's, stage for build+flash.
- Related in-tree: the custom QRTR HELLO-replay hack (`net/qrtr/qrtr.c qrtr_local_server_track`,
  `qrtr_local_nid==1`) exists precisely because normal santoni-style delivery didn't reach the modem
  early — a DT edge deviation is a plausible reason it didn't. Cross-check against P2 replay-shaping.

## Lead 2 — EFS / NV ipc_router & QMI config items  ★ HIGH (modem reads very early; P0 tests health)
The modem's ipc_router/QMI/DSM behavior is NV-configurable (transport flags, DSM pool sizes, service
tables under `/nv/item_files/...` inside EFS). A per-unit or per-build EFS item could make the
4.19-QRTR path branch. `PLAN-radio.md` **P0 (stock-on-DUT)** is the decisive health check: boot Palm
stock on `c39a6acf` (unchanged `mmcblk0p1` + NV/EFS) → if RFSA works, the DUT's EFS is fine and the
gate is AP software; if it fatals, the modem keys on device-local EFS/NV → pivot to EFS diff/repair
vs `pepito-stock-backup-20260706`.
- **Cheap add-ons (no build):** (1) log exactly which EFS files the modem opens over RMTFS before the
  fatal (radio8 saw modem_fs1/fs2/fsg/fsc/rfnvbak) and look for an ipc_router/qmi/dsm config item;
  (2) if P0 shows healthy, the EFS itself is exonerated and this lead closes.
- Partitions: `modemst1` (p13), `modemst2` (p14), `fsg` (p16), `fsc` (p2). Backups exist in
  `pepito-stock-backup-20260706/`.

## Lead 3 — persist remote-filesystem store (`/mnt/vendor/persist/rfs`, `hlos_rfs`)  ★ MEDIUM (early, modem-storage-adjacent)
`persist` (p30) holds the RFS backing tree read early by modem storage: `rfs/mdm/mpss`,
`rfs/{apq,msm,shared}`, `hlos_rfs`, `secnvm`. Same family as RFSA/rmt_storage. A corrupt/empty/
wrong-permission/wrong-SELinux-label `rfs/mdm/mpss` could perturb modem storage bring-up.
- **Test (free):** compare A16 `/mnt/vendor/persist/rfs` contents + perms + `ls -Z` labels against
  stock A11 `81eed371`; check `dmesg`/logcat for rfs/tftp/`hlos_rfs` errors around modem boot.
- Note: `tftp_server` crash-loop is a known parked issue ([[gps-bringup]] / PLAN) that lives in this
  same RFS area — may be related plumbing.

## Lead 4 — devcfg / XPU memory-protection config  ★ MEDIUM-LOW for this symptom (but note XPU is active)
`devcfg` (p10) + `devcfgbak` (p11) configure subsystem memory protection (XPU), loaded by TZ. XPU is
demonstrably active (modem ramdump reads as zeros = XPU-secured). The registration failure is
pre-buffer, so devcfg is unlikely to gate the QMI server-add itself — but it decides what memory the
modem may touch and could gate a *later* stage. Palm-signed (can't hand-edit).
- **Test (free):** `dd` A16 `mmcblk0p10` and compare md5 to `pepito-stock-backup` / an A11 dump to
  confirm it's byte-identical (i.e. rule it out as a per-unit/per-flash deviation).

## Lead 5 — MCFG  ★ CLOSED (investigated radio14) — NOT a gate, NOT even a current gap; do NOT stage Palm MCFG
**CORRECTION to the earlier premise "pepito loads no MCFG at all" — that was WRONG.** The `mcfg`
partition (p41) is blank on **BOTH** pepito AND stock A11 (it's an unused mechanism on this modem
family — red herring). pepito's MCFG actually arrives via the **firmware_mnt/PDC path**: the
mithorium modem image ships a full generic set (`mcfg_hw` + `mcfg_sw`, all regions incl. NA
att/verizon/tmo/sprint + volte/cdmaless variants) at `/vendor/firmware_mnt/image/modem_pr/mcfg/
configs/`, and `init.qcom.sh` copies it to `/data/vendor/modem_config` at boot — **which succeeds**
(`ro.vendor.ril.mbn_copy_completed=1`). Stock Palm A11 instead uses the legacy static
`/vendor/modem_config/` dir with 4 Palm-tuned `mcfg_sw.mbn` (vzw/tmo/att/row).
- **The only gap is downstream of the modem-fatal:** `persist.vendor.radio.sw_mbn_loaded` is unset
  on A16 because qcril activates an sw MBN via **PDC over QMI**, which needs a **live modem** — and
  the modem fatals ~40 ms/boot before telephony init. So MCFG activation is strictly gated behind
  Cluster A; it cannot be the RFSA-retention gate, and cannot even be tested until the modem boots.
- **Do NOT stage Palm MCFG.** `mcfg_hw` must match the *firmware* — pepito runs the mithorium modem,
  so it needs mithorium's `mcfg_hw` (already staged); Palm's `mcfg_hw` is for Palm's A8 modem and
  mixing them is wrong. mithorium's `mcfg_sw` already ships the NA carriers (they differ from Palm's,
  as expected). pepito's firmware_mnt path doesn't even read a static `/vendor/modem_config`, so
  dropping Palm's dir in would be inert.
- **Validation = a tripwire, not an action:** after Cluster A is fixed and a `crash_count=0` boot is
  achieved, check `getprop persist.vendor.radio.sw_mbn_loaded` — `1` = MCFG fully working. Only if it
  stays unset with a live modem is qcril PDC auto-selection worth investigating.
- Palm A11 static `/vendor/modem_config` captured (reference/fallback only, NOT for staging) at
  `…/7c1f2a5b-…/scratchpad/mcfg-lead5/A11-modem_config/` (4 Palm MBNs + manifests).

## Lead 6 — socinfo / hardware-platform ID (SMEM)  ★ LOW (same HW as stock) but a classic modem branch-point
Qualcomm modems frequently branch on the platform/HW ID read from SMEM socinfo. If our 4.19 SBL/
kernel writes a socinfo the modem doesn't recognize, it could take a default path. Believed
SBL-written (identical both phones, radio6) and stock-3.18 on THIS hardware works — but the
**cross-kernel (3.18 vs 4.19) socinfo bytes were never directly diffed**.
- **Test (free):** byte-compare the SMEM socinfo item (id 137) A16 (`/d/smem_raw` / `/d/smem_toc`)
  vs whatever stock read primitive exists; radio6 tooling. One-time close-out.

## Lead 7 — other partitions, for completeness (LOW)
From the full radio14 partition map (A16): `dsp` (p12, ADSP fw), `msadp` (p49, modem debug policy —
dmesg: "Debug policy not present - msadp"), `apdp` (p48, apps debug policy), `sec` (p17, secdata),
`dip` (p38, device-integrity provisioning), `syscfg` (p40), `limits` (p36, thermal), `simlock`
(p20), `tunning` (p18 — RF or audio-TFA tuning), `mdtp` (p39, theft protection). None is an obvious
QMI/transport input; list here so a future session doesn't rediscover them. `tunning` is the only
mildly-interesting one (RF tuning) — irrelevant to registration, possibly relevant to later RF.

---

## Suggested run order for the next session
1. **Lead 1 DT diff (free, highest leverage).** pepito vs santoni modem/SMD/qrtr edge. Pull santoni
   DTS from Stellaris16; diff the `qcom,mss` + smd/smsm/smp2p nodes + qrtr backend binding.
2. **Lead 2 via P0 (one flash round-trip, decisive).** Stock-on-DUT — settles EFS/NV health and
   whether ANY AP-side lead (incl. Lead 1) can matter. If P0 fatals → EFS/NV is the gate, most of
   this file is moot; if P0 healthy → AP software is the gate, Lead 1 becomes prime.
3. **Lead 3 persist/rfs diff + Lead 4 devcfg md5 + Lead 6 socinfo diff (all free close-outs).**
4. **Lead 5 MCFG stage (cheap; do regardless for telephony).**

## Cross-references / tooling
- Root-cause detail + the staged P2 replay-shaping experiment: `PLAN-radio-rfsa-qrtr.md`.
- Full history + P0/P1/P2 posture: `PLAN-radio.md` (radio14 NEXT SESSION block).
- Santoni known-good sources: Stellaris16 `~/Personal-Projects/android_{kernel,device}_xiaomi_*`.
- Partition backups: `pepito-stock-backup-20260706/` (modem, modemst1/2, fsg, fsc). Device
  `mmcblk0p1` (modem) confirmed UNCHANGED (radio14 restore, md5 `1705ef12ecca35937f17e9c8c293481a`).
- Stock ground truth A11 `81eed371` (re-enable root ADB after reboot); DUT A16 `c39a6acf`.
- On-device gotcha: mount debugfs manually (`mount -t debugfs debugfs /sys/kernel/debug`); never
  QRTR-send to modem node 0 from userspace (D-state wedge); modem partition is RO by default
  (`blockdev --setrw` before any `dd`).
