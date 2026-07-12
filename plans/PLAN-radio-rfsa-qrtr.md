# PLAN — RFSA-over-QRTR (pepito/PVG100): the modem doesn't RETAIN svc 0x1C in its own service table

> **Created 2026-07-07 (radio14).** Dedicated focus file for the *one* surviving root-cause lane of
> the modem-fatal saga. Parent: `PLAN-radio.md` (full history, radio1–14). Modem disasm detail:
> `PLAN-modem-disasm.md`. Memory: [[radio-rmts-buffer-rootcause]], [[modem-disasm-ghidra]].
> This file is scoped to ONE question and should stay short.

---

## The problem in one paragraph

The Palm modem boots, opens its EFS partitions over RMTFS (svc 14 / 0xE), then in `rmts_get_buffer`
tries to acquire the EFS transfer buffer via **RFSA (svc 0x1C, instance 1) over QMI**. Its
`qmi_client_init_instance(0x1C, inst 1)` reads the **modem's own local QMI service table**, finds no
RFSA entry, times out (−3), retries ×10, and **ERR_FATALs** (`fs_device_efs_rmts.c:161 …
rmts_get_buffer api failed`). On the healthy stock A11 (same modem binary, 3.18 kernel,
`msm_ipc_router` transport) the identical client finds RFSA and boots every time. **The modem is
identical; only the AP transport differs (stock = msm_ipc_router/SMD, pepito = QRTR).** The sibling
RMTFS client works fine over the same QRTR — so QRTR is not broken; something about **RFSA-over-QRTR
specifically** fails to land in the modem's service table.

## What is PROVEN (do not re-litigate)

Both radio13 sub-tracks (static Ghidra + on-device ipc_logging) converged with no contradiction:

1. **AP delivery is perfect and symmetric.** On A16, every modem boot the AP kernel HELLO-replay
   broadcasts 38 `NEW_SERVER` to the modem node in one <1 ms burst containing **both**
   `SVC[0xe:0x1]→port 0x4033` (RMTFS) and `SVC[0x1c:0x101]→port 0x404c` (RFSA), 135 µs apart,
   **~50–135 ms BEFORE the fatal**. Same announcer (kernel, no comm — not a qrtr-ns vs replay split),
   same node, ports == local ns DB. (`qrtr_0` ipc_logging, 6 cycles.)
2. **The modem receives the burst and uses RMTFS from it, but never touches RFSA.** Zero
   `NEW_LOOKUP` from anyone; zero DATA to the RFSA port `0x404c`; yet 5 RMTFS transactions to
   `0x4033` from the same burst → then fatal. No `DEL_SERVER` of 0x1c (not torn down early).
3. **The RFSA announcement tuple is byte-identical to stock.** A16 qrtr-list: RFSA = `svc 0x1C,
   inst 0x101, node 1` == stock A11 `dump_servers`. RMTFS = `svc 0xE, inst 0x1, node 1`. So it is
   NOT an announce-tuple / instance-encoding bug (falsified on the wire).
4. **The modem's service-cache code has NO bug and NO service filter (static-proven).** Full trace:
   - `rmts_get_buffer` (`FUN_87602d40`) → RFSA svc obj via `thunk_FUN_87e2d1d0(1,1,5)` (svc 0x1C) →
     **`qmi_client_init_instance`** = `FUN_87560db0(obj, instance=1, …, &handle)`.
   - → **`get_service_list`** = `FUN_87560bd0`: reads the list into **20-byte (0x14) entries**,
     compares **`entry[+2] == requested_instance` (=1)**; on match copies the entry out.
   - list built by **`FUN_8755fb40`**: locks `DAT_88e5ca00`, iterates the runtime **CCI source
     registry** `DAT_88e5ca1c` (count `DAT_88e5ca10`), calling each source's **vtable+0xc**
     enumerate-callback.
   - QRTR/IPC-router CCI xport `ops` vtable = **`0x887523e8`** (`qmi_cci_xport_ipc.c`). Enumerate =
     **`FUN_87e8dd60`**: queries the router (`FUN_8755a2c0`) and packs each entry with
     **`entry[+1]=instance&0xff` (version), `entry[+2]=(instance>>8)&0xff` (the matcher byte)** →
     RFSA `0x101`→byte[+2]=1 (MATCHES), RMTFS `0x001`→0. Packing is provably correct and
     service-agnostic (structural invariant of the shipping binary).
   - Server table = **32-bucket hash `DAT_88e5c760`** (bucket = `service & 0x1f`, lock
     `DAT_88e5c740`). **Insert = `FUN_8755af70`** (← `FUN_8755a010` ← `FUN_87559fdc` ← notify op
     `FUN_87e8d1ec`; async NEW_SERVER handler installed by reg/open `FUN_87e8dcb8` = `FUN_87e8de50`):
     stores `{service,instance,addr,port}` **VERBATIM, no service-id filter/range check**. Lookup =
     `FUN_8755b800` (generic: `node[0]==service` + version mask `0xff & (qver^nver)==0`). Del =
     `FUN_8755abd0`.
   - ⇒ RFSA yields zero servers **only because bucket 0x1C of `DAT_88e5c760` has no node at query
     time** — the NEW_SERVER(0x1C) was **never RETAINED**, not filtered.
5. **Modem swap to escape RFSA is IMPOSSIBLE (radio14).** Flashed santoni `NON-HLOS.bin` (an
   ALLOC_BUFF modem) → **PIL rejected it** (`PBL returned unexpected status -284557301` → `MBA boot
   failed`); PVG100 enforces OEM-signed firmware, and every Palm build uses RFSA. So RFSA-over-QRTR
   MUST be made to work — there is no bypass. [[radio-rmts-buffer-rootcause]] radio14 note.

## The root-cause statement (working vs broken)

> The modem **receives** NEW_SERVER(0x1C) on the QRTR wire (proven) but does **not retain** it in its
> own server table `DAT_88e5c760`, while the sibling 0xE from the *identical burst* lands and is used.
> Since the modem takes **no NEW_LOOKUP** yet retains 0xE unsolicited, it *does* accept unsolicited
> NEW_SERVER in general — so the failure is a **data-dependent accept/drop in the modem's NEW_SERVER
> receive→insert path, specific to the 0x1C announcement**, OR a **timing/retention-window** effect
> where 0x1C arrives but is dropped/evicted before the lazily-inited RFSA client queries.

Two hypothesis families remain (not yet split):

- **H-parse:** the QSR4-obscured receive/parse (`FUN_8755acf0` field decode → `FUN_8755af70`) rejects
  or mis-files the 0x1C NEW_SERVER on some field (instance high-byte `0x101` vs `0x001`, addr/port,
  or a dedup/collision). Static-visible if `FUN_8755acf0` can be decoded past the register-arg loss.
- **H-window:** insertion is fine but happens/decays outside the window in which the RFSA client
  (lazy-inited *inside* `rmts_get_buffer`, ~tens of ms before fatal) reads the table. Our one-shot
  <1 ms 38-message replay burst may violate a dialogue property (ordering, pacing, ctrl-queue depth,
  arrival-vs-client-init timing) that the stock msm_ipc_router table-sync satisfies. Consistent with:
  Ghidra proved insert is filterless-once-reached, and the client **retries ~10× (−3)** before
  fatal — so a re-announce landing mid-retry-window should be picked up on a later retry.

## Next steps (ranked) — black-box levers FIRST (radio14 posture: RE lane parked)

### N1 — Replay-shaping experiment — ✅ STAGED (radio14; == `PLAN-radio.md` P2), awaiting build+flash
Directly attacks **H-window**, the most testable and most likely lever. Kyle staged it as ONE kernel
build with debugfs knobs so variants run via SSR with **no reflash between**. Staged commits on
kernel branch `pepito-bringup-lineage-23.2` (compile-verified `net/qrtr/qrtr.o`):
- `206a5ff44239` — reapply "synchronous HELLO reply + local-server replay" (HEAD had it reverted by
  radio12's `e50d43f2caf2`, but the radio13 *flashed* build clearly replays 38 NEW_SERVER → local
  HEAD ≠ flashed build; **sync this HEAD to Stellaris16 before building** — the standing
  local-vs-build-server divergence gotcha).
- `c3c02d85c64d` — the knobs, defaults = pre-knob behavior (cold boot unaffected). Re-announce runs
  on its own ordered workqueue; **kernel-context sends only** (userspace→modem-node sendmsg D-states,
  standing gotcha); stops on the duration deadline.

Knobs under `/sys/kernel/debug/qrtr_replay/`: `delay_us` (inter-msg pacing), `allowlist` (comma svc
ids, hex ok, empty=all), `first_svc` (ordering), `reann_svc`/`reann_inst`(=0x101)/
`reann_interval_ms`(=10)/`reann_duration_ms`(=5000) (periodic re-announce to the last-HELLO node,
armed per-HELLO/SSR), `stats` (replay_last_sent/skipped, reann_sent, cache_cnt).

Run recipe (per variant: set knobs → SSR → read observables; **mount debugfs manually first**):
```sh
mount -t debugfs debugfs /sys/kernel/debug
cd /sys/kernel/debug/qrtr_replay
# V1 — re-announce alone (SHARPEST: tests the retention window directly):
echo 0x1c > reann_svc                 # 0 disables
echo restart > /d/msm_subsys/modem
cat stats /d/rmt_storage/info         # expect reann_sent ~40+/window; win = Request count ≥ 1
# V2 — stock-shaped table (+ optional pacing):
echo 0 > reann_svc; echo "0xe,0x1c" > allowlist; echo 2000 > delay_us
# V3 — ordering only:
echo "" > allowlist; echo 0 > delay_us; echo 0x1c > first_svc
```
Observables per SSR: `stats` (did shaping apply), qrtr_0 ipc_logging / kprobe `qrtr_endpoint_post`
(wire truth), `/d/rmt_storage/info` **Request count** (the win condition), fatal via smem-id-421 SFR.
Run order: **V1 → V2 → V3.** Any variant that ticks `rfsa_req` names the cause → minimize to the
single sufficient deviation and keep it as the permanent fix.

### N2 — Healthy-dialogue capture (stock A11; zero builds) — the converge-target for N1
Capture the stock 3.18 control-plane conversation (who sends what, order, count, pacing at modem
HELLO) and diff against pepito's decoded qrtr_0 burst. This tells N1 what "stock-shaped" means.
- **AP view:** 3.18 legacy debugfs — `/d/ipc_logging/*` (ipc_router, `*_smd_xprt`), `/d/ipc_router*`
  across a per_mgr cycle (`ctl.stop per_mgr; ctl.restart per_proxy; ctl.restart per_mgr`).
- **Modem view (off the wire):** `qdsp6m.qdb` has F3 for `ipc_router_core.c` **ssid 500** incl.
  receive-drop errors ("illegible message received", "control message too short", "register server
  %u:%u failure", "Xport cannot receive"). Re-run `HOWTO-modem-diag-capture.md` with the verbose
  mask (`Diag.cfg`), widen `decode_rmts.py` beyond rmts_api.c to ssid 500. If stock logs a
  register-server drop for 0x1C, that *is* H-parse, on the modem's own terms.

### N3 — (static, RE lane — PARKED unless N1/N2 dead) decode `FUN_8755acf0`
The NEW_SERVER field parse the QSR4 register-arg loss obscured. Only path that can statically NAME
an H-parse accept/drop condition. Resume in the surviving Ghidra project (below).

### N4 — (decisive but BLOCKED) read `DAT_88e5c760` bucket 0x1C on a live modem
Walk 32 bucket heads `(&DAT_88e5c760)[i*3]`, follow `node[+0x18]`=next, read `node[0]`=service
(lock `DAT_88e5c740`). A 0x1C node present on stock / absent on pepito proves the retention gap
outright — but needs modem memory (XPU ramdump = zeros, diag build-masked). Standing wall.

## Ruled out / do NOT re-propose
- Announce-tuple / instance-encoding fix (proven byte-identical to stock; radio5/radio13).
- `param_1[0x2d]` gate (proven ==1: modem opens all 6 EFS partitions; radio13).
- Userspace-vs-kernel RFSA *hosting* (radio10: userspace-hosted RFSA also ignored).
- Modem/NON-HLOS swap to an ALLOC_BUFF (Xiaomi) modem (radio14: PIL rejects non-Palm firmware).
- "Announce RFSA at inst 0x1" (radio5): CONFOUNDED — matcher needs byte[+2]==1, so inst 0 can't
  match regardless; tells us nothing about retention.
- pmOS ALLOC_BUFF userspace stack (radio13): Palm modem never sends ALLOC_BUFF even when healthy.

## Tooling
- **On-device (A16 `c39a6acf`):** `qrtr_0` ipc_logging = `mount -t debugfs debugfs /sys/kernel/debug`
  then `cat /d/ipc_logging/qrtr_0/log` (modem node; decodes NEW_SERVER/DATA with `SVC[svc:inst]`).
  `/data/local/tmp/qrtr-list` (source `diag-tools/qrtr-list.c`) dumps the local ns table. SSR via
  `echo restart > /d/msm_subsys/modem`. SFR auto-log via `qcom,smem-id=421` in dmesg.
  **Never send QRTR to modem node 0 from userspace (D-state wedge).**
- **Stock (A11 `81eed371`):** `adb root` after each reboot; per_mgr SSR cycle; `diag_mdlog -f
  Diag.cfg` verbose capture (`HOWTO-modem-diag-capture.md`); decoder `decode_rmts.py` + `qdb.dec`.
- **Ghidra (RE, parked):** project `/tmp/claude-1000/-home-kyle-android-lineage-23/7d648fc4-…/
  scratchpad/ghidra/proj` (program `mpss`, `modem.elf`; 916M fully analyzed; GP=0x8856a000 set).
  Ghidra 12.1.2 at `/home/kyle/Projects/ghidra_12.1.2_PUBLIC`. Scripts in `…/ghidra/scripts/`:
  `decomp_at.java` (hex[,hex] → callers+C), `refsdump.java` (refs to addrs). Invoke:
  `analyzeHeadless <proj> mpss -process modem.elf -noanalysis -scriptPath <dir> -postScript
  <s>.java <args>`. Regenerate `modem.elf` per `PLAN-modem-disasm.md` if scratch is cleared.

## Key addresses (quick ref)
`rmts_get_buffer` FUN_87602d40 · RFSA svc-obj thunk_FUN_87e2d1d0(1,1,5) · qmi_client_init_instance
FUN_87560db0 · get_service_list FUN_87560bd0 (byte[+2]==inst) · list-core FUN_8755fb40 (registry
DAT_88e5ca1c/count DAT_88e5ca10/lock DAT_88e5ca00) · CCI ipc xport ops vtable 0x887523e8 · enumerate
FUN_87e8dd60 · reg/open FUN_87e8dcb8 · async NEW_SERVER notify FUN_87e8de50 · **server table
DAT_88e5c760 (lock DAT_88e5c740)** · insert FUN_8755af70 ← FUN_8755a010 ← FUN_87559fdc ←
FUN_87e8d1ec · **NEW_SERVER parse FUN_8755acf0 (N3 target)** · lookup FUN_8755b800 · del FUN_8755abd0.
Kernel AP side: `sharedmem_qmi.c` `qmi_add_server(0x1C, ver=1, inst=1)`; `net/qrtr/qrtr.c` replay
cache `qrtr_local_server_track` (`qrtr_local_nid==1`).
