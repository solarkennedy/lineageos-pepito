# LineageOS 23.2 — DIAG modem-visibility side quest (pepito/PVG100)

> ## ✅ AUTHORITATIVE STATUS 2026-08-13 (supersedes everything below)
>
> **Goal restated (current):** get the **MODEM's own DIAG** (F3 log messages + EFS/NV read) working
> on our **A16 build, on the DUT `c39a6acf`** — so we can read *our* modem's live config and watch
> its internal REGISTER/acquisition/ePDG behavior. NOT for the rmts fatal (long fixed) — that
> original purpose is dead. New drivers: the **NAS airplane-reattach** bug (memory `nas-slow-reattach`)
> and **WFC-on-fresh-units** (memory `wifi-calling-lane` part 42) both hit the same wall: we can read
> STOCK modem internals but not OUR build's.
>
> ### What is actually true right now (verified this session)
> - ✅ **Modem is HEALTHY** — qmux backport (2026-07-07) killed the `rmts_get_buffer` fatal. Full
>   telephony/VoLTE/data. **The entire "modem dies before diag registers" premise below is OBSOLETE.**
> - ✅ **APSS + WCNSS + ADSP diag WORK on the A16 DUT** via `diag-tools/diag-a16-shim/` (A8 `diag_mdlog`
>   + `libdiagshim.so`, which fixes the 24-byte `DIAG_IOCTL_SWITCH_LOGGING` struct — Path B's ABI work
>   is effectively DONE). ADSP is QRTR node 5.
> - ✅ **MODEM (MPSS) diag NOW WORKS on the A16 DUT** — see the 🎉 FLASH-VALIDATED section below.
>   (Historical evidence of the broken state, for the record: dmesg `diag: control channel is not
>   open, p: 0` (p:0 = modem); a 49k-frame DUT capture = **1** modem-source F3 line vs 39204 APSS + 1702
>   WCNSS; `efs2-probe` DCI-to-modem hangs; `qrtr-list` shows `0x1001` (diag svc) **only on node 1 = local
>   AP**, never on any modem node.
> - ⚠️ **The 2026-08-09 banner "DIAG works on A16, real modem F3 captured all session" was WRONG** — a
>   device mix-up. **Every** modem-F3 capture in `diag-tools/captures/` (`a11-rig-wfc-f3-20260805`,
>   `qmi/a8-*iwlan*`, `nas-reattach/cap-silver-A8-*`) was taken on a **STOCK-kernel rig** (A11 rig =
>   Silver-as-A11, or stock A8). **None on the A16 DUT.** Do not trust "DIAG works on A16" to mean modem F3.
>
> ## 🎉 FLASH-VALIDATED 2026-08-13 (same day): MODEM DIAG WORKS ON THE A16 DUT
>
> Kyle flashed the fix; all success criteria met on `c39a6acf`:
> - debugfs `diag/status`: `MODEM Feature: f7 3e |FCHBMpQsTuvd|` — mask received, socket bit
>   suppressed (lowercase `s`); NO `control channel is not open, p: 0` in dmesg.
> - `rpmsginfo`: `mpss: DIAG_CNTL` opened/ch_open, ~9 KB read at boot (modem cmd registration);
>   all five mpss channels live.
> - **Modem F3 flows**: 60 s diag-a16-shim capture = 2,583 ext-F3 frames full of modem sources
>   (`lte_ml1_*_stm.c`, `lte_LL1_*`, `dsatutil_ex.c`, `qpDcm.c`, `ds_andsf_*`) vs 1 modem line in
>   49k frames pre-fix. Evidence: `diag-tools/captures/dut-a16-modem-f3-WIN-20260813/`.
> - **EFS DCI path live too**: `efs2-probe hello` + `ls /nv/item_files/ims` work (previously hung).
> - Telephony unharmed: LTE IN_SERVICE both domains, data CONNECTED, Verizon 311480.
>
> **Remaining:** ~~commit~~ ✅ COMMITTED `dec80a40f8fd` on `pepito-rmnet` (2026-08-13); use the
> instrument — step 4 below (nas-slow-reattach capture, Gold IWLAN/ePDG diff, IMS EFS reads).
>
> ### Root cause — ✅ FOUND + FIX VALIDATED 2026-08-13
> **Not a probe race — the modem's own feature mask evicts the working transport.** Verified live on the
> DUT: all five `soc:smd:modem.DIAG*` SMD/rpmsg channels exist AND are **bound to `diagchar`**; the modem's
> CNTL channel over rpmsg **works** — its feature mask arrived (`debugfs .../diag/status`:
> `p: MODEM Feature: f7 3e |FCHBMpQStuvd|`, vs `00 00` pre-qmux). But bit 13 of that mask =
> **`F_DIAG_SOCKETS_ENABLED`** (the uppercase `S`; LPASS/WCNSS advertise lowercase `s`). On receipt,
> `process_incoming_feature_mask` → `process_socket_feature` → `diagfwd_close_transport(TRANSPORT_RPMSG,
> MODEM)` — the driver **closes the working rpmsg backend by design** and hands the modem to
> `diagfwd_socket`, which on 4.19 is **QRTR-only** (`AF_QIPCRTR`). The ipc_router modem never advertises
> diag svc `0x1001` on QRTR (confirmed absent; also absent from
> `/sys/kernel/debug/msm_ipc_router/dump_servers` — the modem waits for the AP to initiate socket diag,
> which the QRTR backend never does on ipc_router). Control channel stays closed forever
> (`diag_send_feature_mask_update ... control channel is not open, p: 0` @16.7s in dmesg).
> LPASS/WCNSS work precisely because their masks *don't* set the socket bit → rpmsg wins for them.
>
> **The fix (kernel, branch `pepito-rmnet`, ✅ committed `dec80a40f8fd`):** pepito-gated override mirroring the
> `ipc_router_rpmsg_xprt.c` idiom — module param `diagchar.modem_socket_diag` (1=allow sockets,
> 0=force rpmsg, **-1 default = auto: force rpmsg on `of_machine_is_compatible("xiaomi,pepito")`**,
> siblings keep QRTR socket diag). Two gates, both `peripheral == PERIPHERAL_MODEM`-scoped:
> - `diagfwd_cntl.c enable_socket_feature()` — don't set `feature[MODEM].sockets_enabled` → the
>   close-transport work closes the **SOCKET** side instead and rpmsg wins (the exact LPASS path).
> - `diag_masks.c diag_send_feature_mask_update()` — don't advertise `F_DIAG_SOCKETS_ENABLED` to the
>   modem, so its diag task stays committed to SMD instead of half-migrating.
> Files: `diagfwd_cntl.c` (+param/helper/gate), `diagfwd_cntl.h` (decl), `diag_masks.c` (gate).
>
> ### Plan (updated 2026-08-13)
> 1. ~~Confirm the contention~~ ✅ done (above — no instrumentation needed, debugfs + dmesg sufficed).
> 2. ~~Write the fix~~ ✅ done, committed `dec80a40f8fd`, flashed.
> 3. ~~Verify on the DUT after flash~~ ✅ ALL PASSED (see 🎉 section). For re-verification after any
>    future kernel change: `debugfs diag/status` shows the MODEM feature mask rcvd with
>    lowercase `s`; dmesg has NO `control channel is not open, p: 0`; a
>    `diag-tools/diag-a16-shim/` `diag_mdlog -f Diag-all.cfg` capture contains **modem-source F3**
>    (`RegisterManager.cpp`, `lte_ml1_*`, `emm_*`, `reg_state_*`) — decode with
>    `diag-tools/decode_f3.py qdb.dec`. Success = nonzero modem F3 hits on `c39a6acf`.
>    (No userspace change; capture tooling unchanged. A/B without reflash is NOT practical — the
>    transport choice happens at feature-mask exchange, i.e. boot or modem SSR, and SSR wedges MSS.)
> 4. **Then it unblocks:** read our A16 modem IMS config (`efs2-probe cat /nv/item_files/ims/*` — needs the
>    EFS DCI path, which also rides the same modem-diag channel), capture the airplane-wedge modem-internal
>    REGISTER/P-CSCF (nas-slow-reattach), and capture Gold's IWLAN/ePDG chain (WFC fresh-unit).
>
> ### Reference / already-solved pieces (reuse, don't redo)
> - `diag-tools/diag-a16-shim/` — the SWITCH_LOGGING ABI shim (Path B, done for APSS; will work for modem
>   the moment the channel binds). `diag-tools/HOWTO-modem-diag-capture.md` — native capture recipe (A11
>   rig). `decode_f3.py` + `qdb.dec` (0x99 QShrink) / `decode_f3_ext.py` (0x79 ext, no qdb).
> - **Healthy-modem F3 references to diff against:** `captures/nas-reattach/cap-silver-A8-COLD-6s-recovery-20260813.qmdl`
>   (stock cold IMS registration), `captures/a11-rig-wfc-f3-20260805/` (stock IWLAN/ePDG). These are the
>   "what our modem SHOULD do" baselines; the whole point of item 4 is to get the *our-build* counterpart.
> - ⚠️ Enforcing sepolicy + permissive `su` already present; nothing ships in the flash.
>
> ### ROI (why this is worth a kernel excursion beyond one bug)
> Removes the standing "can't see OUR modem" limitation that recurs across telephony: WFC-on-fresh-units
> (active, stuck), NAS airplane-reattach (this + `nas-slow-reattach`), future modem crashes/SSR, the eSIM
> ISD-R refusal (`esim-lpa`), RF/band tuning. Highest single payoff = WFC fresh-unit provisioning.
>
> ---
> **Everything below is PRE-QMUX (2026-07-05) archaeology — kept for the RE record (SMEM-writer diff,
> efs-shell, the original rmts-fatal framing). It is NOT current status; the rmts fatal it centers on is
> fixed and the modem is healthy.**

**Purpose (ORIGINAL, obsolete):** stand up a working Qualcomm **DIAG** channel to the modem so we can read the
modem's own **F3 log messages** and **EFS/NV** — the only remaining way to see *why* the modem
skips the RFSA buffer query and ERR_FATALs in `rmts_get_buffer` every boot. Spun out of
`PLAN-radio.md` (session `radio5`, 2026-07-05), which proved that decision is **modem-internal**
and unreachable from the AP side. See also `[[radio-rmts-buffer-rootcause]]` in memory.

## Legend
- ✅ Working / proven on-device
- 🔧 Present but not yet runtime-verified
- ❌ Missing / blocker
- 🧪 Experiment to run

---

## Why this exists — the one-paragraph context

The modem fatals on every boot in `fs_device_efs_rmts.c:161 rmts_get_buffer` because it never
learns the address of its 1.5 MB EFS transfer buffer. On stock 3.18 the modem obtains it by
querying the AP's **RFSA QMI service** (svc 0x1C; stock `Request count: 1` proves it). On our
4.19 build the modem **never sends that query** — proven this session by capturing its complete
egress to the AP (only a HELLO, its own NEW_SERVERs, and 20 RMTFS file-open DATA packets to
`rmt_storage` port `0x4031`; zero traffic to the RFSA port, on any instance encoding). Every
AP-observable variable now matches stock. **The gate is inside the modem**, keyed on some boot /
SMEM / transport input we cannot see from Linux. DIAG is the instrument that lets us see it.

## The working theory this is meant to confirm/refute (shared-memory)

There are two rmtfs buffer-discovery mechanisms in Qualcomm's stack:

1. **RFSA-QMI** (older/downstream — stock 3.18 + this 2018 AML0 modem): the modem asks the AP's
   `sharedmem_qmi` service for the buffer address.
2. **Direct-SMEM**: the AP publishes the buffer address/size in a shared-memory item and the
   modem reads it itself.

On our build the modem **skips the RFSA query** and fatals citing address `~0x890C0000` — which
is inside the *modem* region, **not** the real buffer at `0xf7300000`. Hypothesis: on our
"mainline-aligned" 4.19 environment, an SMEM item/version makes the modem take (or default to)
the **direct-SMEM** path, so it reads a wrong/absent address and dies instead of querying RFSA.
That is a shared-memory-item problem. **What DIAG should reveal:** which branch the modem's rmts
code takes, and what value it reads. `--efs-shell` may additionally expose a modem config/NV
item that selects the mechanism. (Note: a plain EFS-content cause is already largely excluded —
radio4 wiped `modemst1/2` and got a byte-identical fatal — so the selector, if any, is more
likely SMEM/compile-time than an NV file. DIAG efs-shell would still be worth a look.)

---

## How DIAG works (so the pieces are on record)

DIAG (a.k.a. DM / QCDM) is the modem's built-in debug + command + logging protocol. On the
**old (3.18 / stock A11) topology** it is a dedicated SMD/GLINK channel, genuinely separate from
QMI. Path from host to modem:

```
QCSuper / DM tool (host)
  → adb
    → adb_bridge helper (pushed to /data/local/tmp)
      → /dev/diag            (kernel diagchar driver, drivers/char/diag/)
        → [transport]        (see correction below — QRTR on THIS build, not SMD)
          → modem DIAG task
```

`diagchar` multiplexes DIAG between userspace and each peripheral (MODEM / LPASS / WCNSS / …).
To get F3 log messages you generally must: put the driver in a logging mode
(`DIAG_IOCTL_SWITCH_LOGGING` → MEMORY_DEVICE / socket / callback), then enable the peripheral's
**message masks** (otherwise the modem emits nothing). EFS/NV access uses DIAG subsystem commands
and does **not** need the logging-mode switch — which is why `--efs-shell` may work even if F3
logging doesn't.

QCSuper is just an open-source host client for this protocol; any DIAG tool (or a custom
`/dev/diag` reader) would do.

### ⚠️ Transport correction (verified in-tree 2026-07-05): diag rides **QRTR** here, not SMD

The SMD model above is the *stock/3.18* topology and is **wrong for our 4.19 build**. Verified by
reading the driver:

- `drivers/char/diag/Makefile` builds **only** `diagfwd_socket.o` + `diagfwd_rpmsg.o`. **There is
  no `diagfwd_smd.c`** — legacy SMD diag is gone from this kernel entirely.
- `diagfwd_socket.c` opens each modem diag channel as an `AF_QIPCRTR / PF_QIPCRTR` socket
  (`sock_create(AF_QIPCRTR, …)`, line ~463). Diag is a **QRTR service**: `DIAG_SVC_ID 0x1001`
  (line 34), modem instances 0–4 (CNTL=0, CMD=1, DATA=2, DCI_CMD=3, DCI=4; `MODEM_INST_BASE 0`).
- The AP publishes `QRTR_TYPE_NEW_SERVER` for svc `0x1001` and **waits for the modem's diag task
  to advertise its own matching QRTR server** (`socket_open_server`/`socket_open_client`,
  lines 483–535). The driver keeps a parallel rpmsg (GLINK) backend and whichever opens first
  wins (`diagfwd_close_transport`), but both require the modem's diag task to be alive and
  registered.

**Two consequences that reshape this whole plan:**

1. **Diag is a second, independent witness to the same modem halt — not a lever on it.** Diag
   uses the *same QRTR substrate* as IRadio and rmt_storage. We already know that substrate is up
   (HELLO completes, modem emits NEW_SERVERs — `[[radio-rmts-buffer-rootcause]]`). So the MODEM
   diag mask being `00 00` **cannot** be a transport fault; it means the modem never boots far
   enough to register svc `0x1001`. That is the *same* early halt the rmts capture found, seen
   from a second subsystem. Corollary for the side-quest framing: fixing AP-side diag plumbing
   will **not** incidentally fix radio — both are blocked upstream by the `rmts_get_buffer` fatal,
   and only fixing *that* yields both.
2. **The "early-boot F3 window" the plan banks on probably does not exist over QRTR.** The
   40 ms pre-fatal capture idea is inherited from the SMD model, where the modem's diag channel
   streams from reset. Over QRTR **no F3 flows until the modem opens its diag socket and advertises
   svc `0x1001`**. If the modem ERR_FATALs in EFS init *before* diag registration, there is no
   data path at all — not even a pre-fatal window. `--efs-shell` has the identical dependency
   (it needs a live diag endpoint to command). There is also a second way this can be dead: the
   2018 AML0 modem may only expose diag over legacy SMD (which our kernel no longer implements),
   even though it speaks QRTR for QMI. Both failure modes present identically as `00 00`.

---

## Current on-device state (measured 2026-07-05)

| Fact | Value | Meaning |
|---|---|---|
| `/dev/diag` node | ✅ `crw-rw---- 511,0`, `vendor_qti_diag` | diagchar driver loaded |
| diag infra (ADSP/WCNSS) | ✅ `LPASS Feature 63 0e`, `WCNSS 43 08` | DIAG handshake works for other subsystems |
| **MODEM diag feature mask** | ❌ **`00 00`** | modem↔AP diag handshake **never completes** — the modem is a dying zombie |
| Vendor diag capture binary (`diag_mdlog`/`diag_socket_log`) | ❌ not in `/vendor/bin` | no native capture tool to lean on |
| `libdiag.so` | 🔧 in `/vendor/lib{,64}` | present; QCSuper tried to dlopen it |
| QCSuper `--adb --info` | ❌ fails | see blockers below |

**Consequence of the `00 00` modem mask:** realistically we can only capture the modem's
**early-boot F3**, in the ~40 ms window before the EFS fatal — which is exactly when
`rmts_get_buffer` runs, so it may still be enough. `--efs-shell` against a half-dead modem is
uncertain. The diag *infrastructure* is healthy (ADSP/WCNSS prove it); the gap is modem-specific
and is itself a symptom of the same early fatal.

---

## Blockers hit with stock QCSuper (`--adb`)

1. ❌ **`su` assumption.** QCSuper escalates its bridge via `su`; we run `adb root` (adbd is
   already uid 0) but there is **no `su` binary**. Fix: drop a trivial `su` shim on `PATH` that
   just `exec "$@"`, or patch QCSuper's `adb.py` to skip `su` when already root.
2. ❌ **`DIAG_IOCTL_SWITCH_LOGGING … arglen=24 is not supported`.** ABI mismatch between
   QCSuper's `diag_logging_mode_param_t` struct and our downstream diagchar's expected size.
   This is the real work item — the logging-mode struct has had several revisions.
3. ⚠️ `dlopen …/libdiag.so failed (… "/data/local/tmp/libdiag.so" not found)` — QCSuper's bridge
   looked for libdiag in `/data/local/tmp`; likely non-fatal but note it.

---

## Two paths (pick after the scoping pass)

### Path A — get QCSuper working
1. Add a `su` shim (`/data/local/tmp` or a writable PATH dir): `#!/system/bin/sh\nexec "$@"`.
2. Reconcile the logging-mode ioctl: match QCSuper's struct to our diagchar's
   `diag_logging_mode_param_t` (size the driver actually accepts), or use a QCSuper revision
   built for downstream diag.
3. Try **`--efs-shell` first** (avoids the logging-mode switch) → browse modem EFS for a
   storage/buffer-method config item.
4. Then `--pcap-dump` / F3 across a cold boot or SSR.

### Path B — minimal custom `/dev/diag` reader (likely more reliable)
Since we have the exact kernel source, write a tiny on-device tool that uses **our** diagchar
structs directly: `DIAG_IOCTL_SWITCH_LOGGING` to MEMORY_DEVICE/socket mode, enable modem message
masks, read raw F3. No guessing at ABI. More up-front code, no fighting QCSuper's assumptions.
Parse the dump offline (QCSuper `--dlf-read`, or a small QMDL/F3 decoder).

### ❌ GATE RESULT 2026-07-05: `0x1001` ABSENT at the modem → diag is DEAD ON ARRIVAL

Ran on the live build phone (c39a6acf) with the existing `/data/local/tmp/qrtr-services`
enumerator, polled 40 cycles across the modem's SSR loop:

- svc `0x1001` (and `0x1000`) appear **only on node 1 = the local AP node** — ~20 instances,
  which are the *AP diag driver's own* per-peripheral server registrations. **Zero `0x1001` on any
  remote node**, across all 40 cycles.
- The modem's node (node 0, present only while the modem is briefly powered) never registers more
  than a single early service — **no diag, no telephony QMI set** (no WDS/NAS/etc. ever appeared).
- Modem `subsys/crash_count = 23`, restarting every ~2 s; dmesg shows
  `fs_device_efs_rmts.c:161 … rmts_get_buffer api fa` firing **~40 ms after each "Modem has booted
  up"**. Diag/telephony registration happens *after* EFS init in the modem boot order, so the
  modem dies before it ever opens its diag QRTR socket.

**Conclusion:** the `00 00` feature mask is confirmed a pure symptom of the early EFS fatal, not an
AP-side handshake bug. There is **no diag data path on this build** — no pre-fatal F3 window (that
window is pre-diag-registration over QRTR), and no `--efs-shell`. **Paths A and B are dead;** do
not build the custom reader or fix QCSuper. **Abandon criteria met → pivot to the SMEM-writer diff,
and use the stock-A11 reference capture (below) to aim it.** The rest of this file is retained for
the record and for the (now-primary) reference/parallel tracks.

### 🧪 Decisive scoping gate (kept for the record — this is the test that returned RED above)

**Check the modem's captured QRTR NEW_SERVER list for service `0x1001`.** This replaces the old
"read the ioctl structs first" step — it costs nothing (reuse the radio5 kprobe capture
apparatus) and it is dispositive:

- **If `0x1001` is present** → the modem's diag task *is* up over QRTR. Diag is a genuinely
  reachable instrument, the `00 00` is then an AP-side handshake/ABI bug worth chasing, and
  Paths A/B below are worth the effort. (Bonus: it would mean the modem gets further into boot
  than the rmts fatal alone suggests.)
- **If `0x1001` is absent** → diag is dead on arrival on this device (modem either halts before
  diag init, or only speaks SMD diag which this kernel dropped). No F3, no efs-shell, regardless
  of how much QCSuper/ioctl plumbing we fix. **The plan's own abandon criteria fire here** → skip
  Paths A/B entirely and go straight to the SMEM-writer diff (parallel track below), which needs
  no modem cooperation.

Only if the gate is green, the *secondary* scoping pass (for choosing Path A vs B): the
`DIAG_IOCTL_SWITCH_LOGGING` struct is `struct diag_logging_mode_param_t` in `diagchar.h:650` and
is exactly **24 bytes** (3×u32 + 4×u8 + 2×int). QCSuper's `arglen=24 is not supported` means it
is sending a *different revision* of that struct; the driver takes a fixed
`sizeof(mode_param)` copy at `diagchar_core.c:2753` with **no compat shim**, so any size delta
fails. Because we have the exact struct, **Path B (custom reader built against our own headers)
is clearly superior to Path A** — nothing to reverse-engineer, and it sidesteps QCSuper's `su`
assumption and its `/data/local/tmp/libdiag.so` dlopen. Path A is only worth it if you
specifically want QCSuper's offline QMDL/DLF decoder (which you can use on a Path-B dump anyway).

---

## What to capture, and what to look for

- **Modem F3 across a cold boot (or `echo restart > /sys/kernel/debug/msm_subsys/modem`)**, from
  reset through the EFS fatal. Filter for: `rmts`, `rfsa`, `get_buffer`, `efs`, `sharedmem`,
  `buffer`, `RFS`. Goal: see which buffer-discovery branch the modem takes and what address/flag
  it reads.
- **`--efs-shell`**: look for any modem config file that names a storage/buffer/RFS mechanism or
  a "use SMEM/QMI" selector.
- If F3 confirms a **direct-SMEM read of a bad address** → pivot to the SMEM-writer diff (below)
  to find/fix the item. If F3 shows the modem **trying RFSA and failing internally** → the
  problem is in how the AP presents RFSA at the QCCI layer after all (re-open that, but with the
  modem's own error text in hand).

---

## Parallel track (does NOT need DIAG) — SMEM-writer diff

Independently viable and complements this plan: diff the **stock 3.18** vs **our 4.19** kernels
for any **SMEM/SMSM/SMP2P** item written on the rmts/fs bring-up path by a driver **other than**
`drivers/uio/msm_sharedmem/` (a capability/enable/method flag, *not* the buffer address — the
address only flows via RFSA QMI on stock). SMEM *geometry* is already verified byte-identical
(radio4), so this is about the *content/presence* of a specific item. Grep stock for
`qcom_smem_alloc` / SMSM writes on any `fs`/`rmts`/`efs` path. A hit here could explain the
direct-SMEM theory without needing modem F3 at all.

---

## Reference track — reflash *this pepito* to stock Android 11 to capture a HEALTHY modem (offered by Kyle 2026-07-05)

Kyle can reflash the current build phone (c39a6acf, pepito/PVG100) back to **stock rooted A11**.
This is worth doing, but be precise about what it buys and what it does not:

**What it proves / gives us:**
1. **Hardware + radio sanity, on the exact same silicon.** If A11 gets signal, the RF/modem
   hardware is fine and our A16 failure is purely a software/firmware-pairing problem. Strong,
   cheap confirmation that removes "dead hardware" from the differential.
2. **A golden diag reference of a HEALTHY `rmts_get_buffer`.** On stock A11 (3.18) diag is the
   *legacy SMD* topology and QCSuper/QCDM/QPST typically works out-of-the-box with root. If we
   capture the modem's F3 across boot, we see **which buffer-discovery branch a healthy modem
   takes (RFSA-QMI vs direct-SMEM) and what address/flag it reads** — directly testing this
   plan's core hypothesis, with ground-truth values to diff against.
3. A working `--efs-shell` reference on a live modem (browse for any storage/RFS-method config
   item), which we can then look for on our build.

**Important caveats (so we interpret it correctly):**
- **Different transport.** A11 diag = SMD + `msm_ipc_router`; our build = QRTR. So A11 proves the
  modem's *internal* branch decision, **not** that our QRTR-side presentation is right. A11
  cannot validate our AP transport path.
- **Possibly different modem firmware.** A11 stock ships its own NON-HLOS; if it is not the same
  2018 AML0 image our build pairs, then "A11's modem queries RFSA" establishes *family* behavior,
  not proof our specific AML0 blob must. Note the A11 modem build ID when captured.
- **Cost: it takes the A16 test target offline.** Every diag experiment we design for the *build*
  runs on c39a6acf. So treat A11 as a **bounded reference-gathering excursion**: capture the
  healthy F3 + efs-shell, record the modem build ID, then reflash back to A16.

**Sequencing:** the QRTR `0x1001` gate above is on the *current A16 build* and comes first (no
reflash needed). The A11 excursion is the natural next step **if** we need the healthy-modem
reference — most valuable precisely in the `0x1001`-absent branch, where diag on our build is
impossible and the SMEM-writer diff becomes the whole game: an A11 F3 capture would tell us which
SMEM/branch a healthy modem uses, aiming that diff.

## Success / exit criteria

- ✅ **Primary:** modem F3 (or efs-shell) reveals the branch/value behind the RFSA skip → a
  concrete, testable fix (SMEM item to write, or a QCCI-presentation fix), and ultimately
  `grep 'Request count' /sys/kernel/debug/rmt_storage/info` ≥ 1 with no `rmts_get_buffer` fatal.
- 🟡 **Partial win worth banking:** a working DIAG channel on this device — reusable for the GPS
  QMI_LOC dead end and any future modem debugging — even if the first capture is inconclusive.
- ❌ **Abandon criteria:** if the modem's diag task never emits F3 in the pre-fatal window AND
  efs-shell can't reach it (both a consequence of the `00 00` zombie state), DIAG can't help
  here → fall back entirely to the SMEM-writer diff.

---

## Cross-references
- `PLAN-radio.md` — session `radio5` (the egress measurement + why the gate is modem-internal),
  session `radio4` (five prior falsifications, EFS wipe test, the HELLO-reply+replay mechanism
  that keeps the control plane up).
- Memory: `[[radio-rmts-buffer-rootcause]]`, `[[radio-modem-transport]]`, `[[holistic-model]]`
  (Cluster A).
- Reference-source: stock GPL at `/home/kyle/Projects/Pepito_GPL_SourceCode` (`kernel/msm-3.18/`);
  our diag driver at `kernel/xiaomi/msm8937/drivers/char/diag/`.
