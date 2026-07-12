> ⚠️ **ARCHIVED 2026-07-06 (superseded by `PLAN-radio.md`).** This file covers the
> **RFSA / QRTR-bring-up era** (sessions radio1–radio8, ~2026-06-24 → 07-05). Its central
> thesis — that the modem needs the in-kernel RFSA/`sharedmem_qmi` (svc 28) service and the
> gate is a "modem-internal decision" reachable only by Hexagon disassembly — was **falsified
> on 2026-07-06**: the official working `lineage-23.2` Mi8937 kernel (santoni et al., telephony
> works on the same 4.19.325 + same tree + same `8940.gen.prod` modem) has **no RFSA at all**.
> RFSA was re-ported from 3.18 by mistake. Kept for the on-wire evidence and the (still valid)
> control-plane work. The `radio1` file (`PLAN-radio.old.md`) is the even-earlier era.

# LineageOS 23.2 — Radio / Telephony / Modem Stack (pepito/PVG100) — ARCHIVED (RFSA era)

## 2026-07-05 (session `radio6`) — SMEM-writer diff DONE and its one finding (SMSM) FLASHED + FALSIFIED same day. The static SMEM lane is now EXHAUSTED.

**Bottom line: the legacy SMSM handshake was the only modem-visible SMEM difference between
stock 3.18 and our 4.19 — it was implemented, flashed, proven working mechanically, and it is
NOT the gate.** Decisive timeline fact: the modem raises its own SMSM INIT ~30 s after first
powerup — long AFTER the `rmts_get_buffer` fatal at +200 ms. The modem's SMSM client isn't
even running when the RFSA decision is made, so no SMSM state can gate it. On-device
experiments (via the new `smsm_legacy` debugfs poke + on-demand SSR, no reflash needed):
- apps word pre-set to `0x1009` (INIT|SMDINIT|PROC_AWAKE) before modem boot → fatal, Request 0.
- apps cleared to `0x1000` then SSR (stock-faithful fresh-edge handshake) → fatal; modem never
  re-raises SMSM during crash-loops (irq count frozen), confirming its SMSM task starts late.
- `0x801009` (+SMD_LOOPBACK, the ONE apps bit the modem's own intr-mask cell subscribes to,
  `0x00800000`) → fatal, Request 0.

**KEEP the smsm.c patch** — it is stock-faithful, gives first-ever modem-side SMSM visibility
(modem state word `0x08000009`, its intr-mask writes, SIZE_INFO says 5 hosts), and
`/sys/kernel/debug/smsm_legacy` (read = all state words + full matrix; write hex = set apps
word + kick). The falsified part is only the *hypothesis*, not the code.

### The static diff itself (still valid — for the record)

Every SMEM writer in stock msm-3.18 vs our 4.19; SMSM was the only modem-visible difference:

| SMEM state the modem can read | Stock 3.18 at modem-boot | Our 4.19 | Verdict |
|---|---|---|---|
| **SMSM apps state word** (item 85, entry 0) | `SMSM_PROC_AWAKE (0x1000)` set at boot; `SMSM_INIT (0x1)`+`SMSM_SMDINIT (0x8)` mirrored back the instant the modem raises its own INIT (stock `smsm_irq_handler`, smd.c:2553) | **always `0x00000000`** — mainline `smsm.c` never sets any apps bit; no consumer exists | **THE DIFF** |
| **SMSM intr-mask cell [modem entry][apps]** (item 333) | `0x49` (`RESET\|INIT\|SMDINIT` = `LEGACY_MODEM_SMSM_MASK`, smd.c:61) — tells the modem to interrupt apps on its INIT | **`0x0`** — probe explicitly zeroes it (smsm.c:589), nothing subscribes | **THE DIFF** (explains the observed **0 SMSM irq counts** on A16 `/proc/interrupts` hwirq 58/322/176) |
| SMD channel alloc table (item 13) | legacy smd writes | rpmsg qcom_smd writes; IPCRTR channel demonstrably works | ruled out |
| smp2p outbound entries | written | written, functional (subsys notifications flow) | ruled out |
| SMEM header/version array | SBL-written | same (kernel never writes on either side) | ruled out |
| SMSM matrix geometry | 8 entries × 3 hosts default (smd.c:57) | 8 × 3 default — identical; SIZE_INFO (item 419) is modem/SBL-owned on both | ruled out |
| Palm socinfo items (`SMEM_VERSION_GPIO_BOARD_ID`, `SMEM_MDDI_LCD_IDX`, socinfo.c:1177/1674) | **readers, not writers** — legacy `smem_alloc` is find-or-alloc; content is SBL-written, identical on both boots | absent (harmless) | ruled out |

Flash results (same day): probe armed `mask 00000049` at 13.2 s; modem kicked SMSM irq
(hwirq 58 count 2) at **t=43.9 s** raising `0x08000001`→`0x08000009`; mirror set apps to
INIT|SMDINIT correctly. Fatals continued before AND after (crash_count 7→16 across the
experiments above). Mechanism works; hypothesis dead.

### What survives radio6 — next moves, ranked

The "modem-side input diff" family is nearly empty now: kernel SMEM writers exhausted, SBL
identical, userspace can't write SMEM, EFS excluded (radio4), TZ excluded (PLAN-tz). Re-rank:

1. **Disassemble the modem's own decision (NEW TOP LEAD) → dedicated plan `PLAN-modem-disasm.md`.**
   Full workflow proven this session and de-risked: `modem.bin` is the FAT16 modem partition;
   `7z x` its `image/modem.mdt`+`modem.bNN`, reassemble a Hexagon ELF with
   `scripts/mpss-reasm.py`, disassemble with **system `llvm-objdump-15`** (has the Hexagon
   target — the in-tree LLVM-21 clang dropped it). Anchor: the fault string
   `fs_device_efs_rmts.c` is at **vaddr 0x88152d31**; xref it (signed `##-2011357391`) to land
   on `rmts_get_buffer`'s assert, then read the predicate that selects the failing
   buffer-discovery method and the input it reads. Fatal args to decode: `[6, 0x180000,
   0x890C0000]`. Replaces input-guessing with reading the answer. **See PLAN-modem-disasm.md
   for the full method, commands, guardrails, and deliverable.**
2. **Dynamic SMEM content diff — PRESENCE HALF DONE 2026-07-05 (same day, A11 reconnected):
   negative. Only one SMEM item differs and it is a late modem-written symptom. See below.**
3. **DIAG / modem F3 logs** (`PLAN-diag.md` Path B) — unchanged, still gated on building a
   minimal `/dev/diag` reader.

### Dynamic SMEM diff RESULT (2026-07-05, A11 `81eed371` vs A16 `c39a6acf`)

Both instruments live: stock A11 has `/sys/kernel/debug/smem/mem` (stock `smem_debug.c` TOC);
A16 has the flashed `smem_toc` + `smem_raw`. Captured both TOCs and compared all 52/51 items by
id + size.

**Every SMEM item is byte-identical in size between stock and ours, with ONE exception: item
114** (8 bytes) is present on stock, absent on ours. Nothing else differs. Moreover the early
version-block items **107, 108, 109, 111, 113 sit at identical heap offsets on both devices**
(same allocation order = same early boot sequence). Item 110 matches in size, differs only in
offset (allocation-order timing; present on both).

**Item 114 is a symptom of A11's healthy modem, NOT a cause of our fatal — three converging
proofs:**
- **It's the LAST item allocated on stock**, at offset `0x29fa8`, right at the heap end
  (`free_offset` ≈ `0x2a000`). A final, late allocation cannot gate a fatal that fires ~200 ms
  into boot.
- **Only the modem differs in health between the two phones** (adsp/wcnss/venus are healthy on
  both). Since every non-114 item is identical and the kernel doesn't allocate 114 (stock's
  kernel only touches items 62/100/107/111), item 114 must be written by the one differing
  subsystem — the modem — *after* it is fully up.
- **Our modem never writes it across 15 consecutive boot cycles.** On-device tight-loop
  (`/d/smem_toc` polled while `crash_count` went 20→35 in 30 s): item 114 never appeared for a
  single instant. Our modem completes early version negotiation (107–113) every boot but dies
  at/before rmts, which is temporally *before* the 114 write.

**Content half BLOCKED on stock (cannot close it without a stock-kernel rebuild):** A11 has no
`/dev/mem`, no `/proc/kcore`, no `/dev/kmem`, and `CONFIG_MODULE_SIG_FORCE=y` — so no unsigned
dumper `.ko` can load without the vendor's module-signing key. Stock SMEM *content* is
unreachable. (A16 content is readable via `smem_raw`; captured item 107 = the SMD version array,
values `0x0200`/etc in specific slots, and item 110, for the record.) The only way to content-
diff a same-size shared item the modem reads pre-fatal (prime candidate: the item-107 version
array) would be to patch stock `smem_debug.c` to dump content and rebuild the 3.18 kernel —
heavy, and lower value than lead 1 now that presence is proven identical.

**Net:** the SMEM environment we present to the modem is, to the limit of what is measurable,
**identical to stock**. This is another firm negative that pushes the whole question inside the
modem → **lead 1 (Hexagon disassembly, `PLAN-modem-disasm.md`) is now the only open lane.**
Handoff hint for lead 1: item 114 is written *late* by the modem; find its allocation site to
bracket "past rmts", and focus the read on the pre-rmts path that writes items 107–113.

### A11 checklist when reconnected (do these before anything else)

- `cat /d/smem/mem` → stock TOC at steady state (and ideally right after a modem SSR).
- `grep -i smsm /proc/interrupts` + any `/d/smsm*` → stock's apps SMSM word + modem irq
  cadence (closes the loop on how stock's handshake actually times against modem boot).
- `zcat /proc/config.gz | grep -E 'DEVMEM|STRICT_DEVMEM|MODULES'` → pick the SMEM content
  dump vehicle (`/dev/mem` vs custom .ko).

---

## 2026-07-05 (session `radio5`) — earlier same day. Two hypotheses flashed + FALSIFIED; the gate is now PROVEN modem-internal.

**Bottom line after this session:** the modem's skip-RFSA decision is **inside the modem** — not
an AP announcement/matching problem. Two on-device flashes killed both of this session's ideas.
Net gain: the search space is now hard-bounded to modem-side inputs (SMEM/boot env). No AP-side
QRTR/qmi patch can fix this — stop trying them.

### FALSIFIED #2 (flashed): RFSA instance-encoding mismatch

Hypothesis: on our bus RMTFS (svc 14) is announced at wire-instance `0x1` (modem uses it) while
RFSA (svc 28) is at `0x101` (modem ignores it); `qmi_send_new_server` packs `version|instance<<8`
and the legacy-era modem reads it raw, so `0x101`→257≠1. Staged a 2nd `qmi_add_server(...,0)` so
RFSA is ALSO announced at wire-instance `0x1`. **Flashed. No change:** kprobe confirmed the modem
receives `svc=0x1c inst=0x1 node=1`, and `Request count` stayed **0**, fatal every boot. The
modem is not failing to *match* — it never queries. **Reverted** (additive, harmless, but pointless).

### The decisive measurement: the modem's COMPLETE egress to the AP

kprobe on `qrtr_endpoint_post` (all modem→AP packets), across an SSR. The modem (snode=0) sends
**only**:
- `type=2` HELLO (broadcast), `type=4` NEW_SERVER (announcing the modem's *own* services to node 1),
  `type=6` DEL_CLIENT — normal router chatter.
- **20× `type=1` DATA, every one to `dport=0x4031`** — the rmt_storage/RMTFS port. The 4 EFS opens.

**Zero DATA to the RFSA port. Zero NEW_LOOKUP.** The modem consumes our NEW_SERVER(svc 14) to
find RMTFS and opens it, receives our NEW_SERVER(svc 28) for RFSA at both `0x101` and `0x1`, and
**emits no GET_BUFF_ADDR to anything.** So RFSA discovery is not gated by AP announcement, matching,
instance encoding, handshake, or timing — the modem decides not to query, from a modem-internal input.

### FALSIFIED #1 (flashed earlier same day): extended-HELLO version negotiation

Built the `qrtr_fill_ds_hello` patch (legacy `rr_control_msg` checksum 0xE110 + versions V1|V3).
**No effect** — fatal unchanged, `Request count` 0, modem inbound headers stayed `v=0x1`. **This
modem speaks QRTR, not legacy `msm_ipc_router`;** QRTR's HELLO handler reads only the `cmd` word
and ignored the payload. I had conflated two protocol generations. **Reverted** (the radio4
HELLO-reply + server-table replay mechanism stays — it's what brings the control plane up).

### Ruled out this session too
- **Multiple sharedmem regions:** stock generic 8952/8939 dtsi declare `rfsa_dsp`/`rfsa_mdm`/
  `rfsa_sensor` besides `rmtfs`, but the **actual stock pepito DTB** (`dts-3.19-pepito/pepito.dts:5615`)
  has only the single `rmtfs` node, `client-id 1` — identical to ours. Not the difference.
- **Stock SMEM address path:** re-confirmed stock `msm_sharedmem.c` exposes the buffer ONLY via
  `sharedmem_qmi_add_entry` (→ RFSA QMI); its only other action is the (benign, also-fails-on-stock)
  `hyp_assign_phys`. So stock's modem MUST query RFSA — and does (`Request count: 1`).

### The only surviving lead — modem-side input diff (heavy)

Same modem image queries RFSA on the stock **3.18** boot but not on our **4.19** boot, with every
AP-observable now matched. The differing input must be something the modem reads at boot **before**
`rmts_get_buffer`, written by the stock kernel's boot/SMEM/transport path and not by ours. EFS is
already excluded (wipe test, radio4). Candidates, in rough priority:
1. **An SMEM/SMSM/SMP2P item** written by some stock 3.18 driver *other than* `msm_sharedmem.c` on
   the rmts/fs bring-up path (a capability/enable flag, not the address). Diff stock-3.18 vs our-4.19
   SMEM writers; grep stock for `qcom_smem_alloc`/SMSM on any fs/rmts/efs path. SMEM *geometry* is
   already byte-identical (radio4), so this is about *content/presence* of a specific item.
2. **A modem-side PD/task that never comes up** because a QRTR forward rule starves it (note the
   separate radio4 finding: CAF `qrtr_must_forward` blocks ADSP↔modem service visibility — does an
   analogous rule keep a modem sub-PD from running its RFSA client?).

Modem-side visibility would settle it fastest. DIAG (the modem's F3-log/EFS channel) is the
instrument for it — QCSuper `--adb` fails out of the box (`DIAG_IOCTL_SWITCH_LOGGING … not
supported`, wants `su`; and the MODEM diag feature mask is `00 00` = handshake never completes on
the zombie modem), but this is now scoped as its own side quest: **see `PLAN-diag.md`** (blockers,
Path A = fix QCSuper, Path B = minimal custom `/dev/diag` reader, what to capture, and the
parallel SMEM-writer diff that needs no diag at all).

---

### (superseded — kept for the on-wire data) instance-encoding writeup

### What was measured this session (all on-device, reproducible)

1. **The extended-HELLO hypothesis (staged earlier today) was FLASHED and cleanly FALSIFIED.**
   Built + booted (kernel `4.19.325 …Sat Jul 4 22:26`). Result: `rmts_get_buffer` fatal every
   boot unchanged (`crash_count=25`), `Request count: 0`, and a kprobe on `qrtr_endpoint_post`
   showed the modem's inbound headers **stayed `v=0x1`** — my legacy-`rr_control_msg` extended
   payload (checksum/versions) was ignored, because **this modem speaks QRTR, not legacy
   msm_ipc_router**, and QRTR's HELLO handler reads only the `cmd` word. I conflated two
   protocol generations. The extended-HELLO code has been **reverted** (the HELLO reply +
   server-table replay mechanism from `radio4` v2 stays — it is what brings the control plane up).

2. **Then I dumped the actual NEW_SERVER announcements sent to the modem** (kprobe on
   `rpmsg_send`, decoding `cmd/service/instance/node`). The two relevant services:

   | Service | svc id | **instance field on wire** | node | modem behavior |
   |---|---|---|---|---|
   | RMTFS (userspace `rmt_storage`) | `0x0e` (14) | **`0x1`** | 1 | **queried — 4× EFS OPEN every boot** ✅ |
   | RFSA (kernel `sharedmem_qmi`) | `0x1c` (28) | **`0x101`** | 1 | **never queried** (`Request count` 0) ❌ |

   Everything else (node, port path, delivery timing) is identical; the **instance field is the
   sole difference** between the announcement the modem acts on and the one it ignores.

### Root cause (high confidence)

`qmi_send_new_server()` (`drivers/soc/qcom/qmi_interface.c:238`) packs the wire instance as
**`version | (instance << 8)`**. Our kernel RFSA registers `svc 0x1c, version 1, instance 1`
(`sharedmem_qmi.c:346`, `RFSA_SERVICE_VERS_V01=1`, `RFSA_SERVICE_INSTANCE_NUM=1`) → wire
`0x101`. RMTFS (registered by userspace `rmt_storage`/libqrtr) lands on the wire as `0x1`.

The **AML0 (2018) modem was built for the legacy `msm_ipc_router`**, whose in-kernel name
service put the **raw** instance on the wire and did **no version-packing** — that packing is a
QRTR-era convention. So this modem's RFSA client matches a **bare** instance value: it accepts
RMTFS's `0x1` (reads it as instance 1, matches) but does not recognise RFSA's `0x101` (reads it
as 257) → it never sends `GET_BUFF_ADDR` → `rmts_get_buffer` fails → ERR_FATAL every boot.
Sibling variants work at `0x101` because their modems are QRTR-native and understand the
packing — this is a pepito-only, Cluster-C (2018-blob-on-2024-kernel) mismatch.

This is why **five prior hypotheses all failed**: none touched the instance encoding *as a
legacy modem parses it*. The `radio4` "instance-encoding" check only compared our value to the
mainline formula and to stock's `dump_servers` label — it never compared RFSA against how the
**working RMTFS service is announced on our own bus**, which is where the asymmetry is visible.

### FIX STAGED (uncommitted, `drivers/uio/msm_sharedmem/sharedmem_qmi.c`, needs build+flash — Kyle)

Added a **second** `qmi_add_server(... RFSA_SERVICE_VERS_V01, 0)` right after the existing one
(instance arg `0` → wire `version|0<<8 = 0x1`). RFSA is now announced at BOTH `0x101` (unchanged,
for QRTR-native siblings) and `0x1` (the raw "instance 1" the legacy modem expects, same form as
RMTFS). Both registrations share one handle/port, so whichever the modem matches reaches the same
`GET_BUFF_ADDR` handler. Chosen as an additive test so it cannot regress the current state; if it
proves out, collapse to a single pepito-gated registration. Also reverted the falsified
extended-HELLO change in `net/qrtr/qrtr.c`.

**Validation (next flash, in order):**
1. **Headline:** `grep 'Request count' /sys/kernel/debug/rmt_storage/info` → **≥1** = the modem
   sent `GET_BUFF_ADDR` for the first time on this build (stock shows 1/boot). Expect **no**
   `rmts_get_buffer` fatal in `dmesg`, `subsys0/crash_count=0`, modem healthy (not zombie).
2. Confirm the new announcement is on the wire: kprobe `p:tx rpmsg_send s=+8(%x1):x32
   inst=+40(%x1):x32` (offsets: cmd=+32, service=+36, instance=+40) → expect a NEW_SERVER with
   `s=0x1c inst=0x1` alongside the `0x101` one.
3. Healthy modem → SIM/NV should populate; then the real telephony path (UICC → registration)
   and the deferred `radio-compat` AIDL shim retest (old TODO 5) can proceed against a modem
   that actually has EFS.
4. **If `Request count` still 0 with `0x1` announced** → the legacy-instance theory is falsified
   too; next lane is modem-side visibility. Note: **QCSuper `/dev/diag` is a dead end on this
   kernel** — its `adb_bridge` fails with `DIAG_IOCTL_SWITCH_LOGGING … not supported` and wants
   `su`. Would need a different diag front-end or the SMEM/SMSM writer diff (stock 3.18 vs 4.19).

> Device state after this session: A16 running the (now-superseded) extended-HELLO kernel, all
> diagnostic kprobes removed, root adb. modemst NV intact. Next flash = the sharedmem_qmi fix.

## 2026-07-04 (session `radio4`) — earlier context. Summary of a long session:
>
> **WIN (flashed, in tree, uncommitted):** kernel `net/qrtr/qrtr.c` HELLO-reply + local-server
> table replay (`qrtr_hello_reply_and_replay` + `qrtr_local_server_track/replay`). Effect: the
> modem now **stabilizes** (fatals ~17× then stops, was looping forever) and the **radio control
> plane comes up automatically at boot** — `qcrild` + full `IRadio/slot1 v1.0-1.4`+ISap+config
> published; framework shows **"Emergency calls only"**. This is real, keep it. Commit + rescope
> `[TEMP][pepito]` later.
>
> **STILL BROKEN:** the modem-EFS fatal (`rmts_get_buffer`) is NOT fixed — `Request count`
> stays 0, modem is a stable-but-degraded zombie (no EFS/NV/SIM → OUT_OF_SERVICE).
>
> **FIVE hypotheses falsified this session** (evidence in the dated sub-sections below):
> ALLOC_BUFF/rmt_storage, announce-timing race, incomplete HELLO handshake, missing-SMEM-address
> path, and EFS/`modemst` persisted state. Every AP-observable + EFS-persisted variable now
> matches stock or is proven irrelevant.
>
> **RESUME HERE:** two heavier leads only — (1) transport/qmuxd (modem calls RMTFS(14) but never
> RFSA(28)); (2) an SMEM capability flag stock 3.18 writes that our 4.19 path may not. See
> "Surviving leads" sub-section. Not cheap probes; scope as their own investigation.

## 2026-07-04 detail: modem-fatal — RFSA discovery, ALLOC_BUFF falsified, replay-at-HELLO patch (v1→v2)

**TODO items 2–4 of the 2026-07-02 list are resolved by this session. Do not re-run them.**

### What was measured (all on-device, reproducible)

1. **ALLOC_BUFF hypothesis FALSIFIED (TODO 2/3/4 dead).** strace of `rmt_storage` across
   ~20 on-demand modem SSRs (`echo restart > /sys/kernel/debug/msm_subsys/modem`): the
   modem's complete RMTFS (svc 14) conversation per boot cycle is 4× OPEN
   (`modem_fs1/fs2/fsg/fsc`, all SUCCESS, caller_ids returned) + the benign `rfnvbak`
   failure. **Zero `ALLOC_BUFF` (msg 0x0004), zero `RW_IOVEC` (0x0003)** on any socket, ever.
   The modem does not ask `rmt_storage` for its buffer → swapping in mainline `rmtfs`
   (old TODO 4) cannot help. Fatal fires ~50–130 ms after the last OPEN ack.
2. **The RFSA/`sharedmem_qmi` mechanism is CONFIRMED as the stock buffer path — the
   2026-06-29 "falsification" conclusion was wrong.** Stock A11 `/sys/kernel/debug/
   rmt_storage/info` (the 3.18 sharedmem_qmi debugfs): `Client rmtfs, id 1, size 0x180000,
   Address 0xF7100000 (== stock uio0), Request count: 1` — the stock modem queries RFSA
   (svc 28) once per modem boot to learn the buffer address. `request_count: 0` on A16
   means "the modem never queries *our* port", not "the modem doesn't use RFSA".
3. **Discovery delivery verified end-to-end on A16 — and the modem still never queries.**
   - `qrtr-services` enumerator: svc 28 on the bus, inst `0x101`, node 1 — identical
     registration tuple to stock (both use svc 0x1C, vers 1, ins 1; legacy
     `BUILD_INSTANCE_ID` and mainline `version | instance<<8` encode the same 0x101).
   - strace of `qrtr-ns` + kprobes on `qrtr_endpoint_post` (RX) / `qrtr_node_enqueue` (TX):
     on every modem HELLO, qrtr-ns pushes the full ~46-server table to the modem's control
     port — `NEW_SERVER svc=28` is delivered (sendto rc=20) and in good cycles lands at
     **HELLO+1.9–2.5 ms, i.e. 1.2–1.7 ms BEFORE the modem's first EFS OPEN (+3.6 ms)**.
   - kprobe RX across many full cycles: **zero packets to the RFSA port, zero NEW_LOOKUPs
     from the modem.** The modem receives the announcement and never sends the
     `GET_BUFF_ADDR` request (request_count stayed 0 across 90+ modem boots).
4. **Announce-injection race test (freestanding tool `rfsa-announce-spam`,
   `/data/local/tmp/`, source in scratchpad/session log):** flooding NEW_SERVER(28)
   directly at the modem's control port at 5 kpps across SSRs did not induce a query.
   Caveat: kernel drops non-HELLO TX to a node until the kernel HELLO reply (+4.7 ms), so
   injection cannot beat qrtr-ns by much; a sub-2 ms one-shot window on the modem is not
   fully excludable this way.

### New platform-level facts discovered (matter beyond radio)

- **`qcom_smd_qrtr_send` uses blocking `rpmsg_send`** (net/qrtr/smd.c): while the modem is
  dead/dying, ANY sender to node 0 — including `qrtr-ns`'s control socket — parks inside the
  kernel until the FIFO drains, and unblocks 16–140 ms after the *next* HELLO. In crash
  loops this makes table delivery erratic (some cycles get NO table at all). Also: a
  sendto with MSG_DONTWAIT still blocks (flag not honored on this path).
- **The modem caches AP server addresses across its own SSR cycles**: in cycles where no
  announcement landed near HELLO, it still sent OPENs to `rmt_storage`'s
  dynamically-assigned port at +4–7 ms. So modem-side EFS/QCCI state persists across modem
  reboots (fs_rmts bootup state; `fs_rmts_bootup_action.c` etc. confirmed present in the
  MPSS image via strings). Implication: a stale modem-side "RFSA absent" decision may also
  persist — see hypothesis (b) below.
- **CAF `qrtr_must_forward` blocks ADSP(node 5) service announcements toward the modem
  (node 0)** (qrtr-ns sendto rc=0). Modem and ADSP cannot see each other's QMI services on
  this kernel. Irrelevant for the EFS fatal; possibly relevant later for IMS/audio PDs.
- Toybox `chrt` arg order gotcha; `qrtr_tx_wait` never flow-blocks control packets (only
  DATA); kernel gate: non-HELLO TX to a node is dropped (`-ENODEV`) until `hello_sent`.

### Surviving hypotheses (either way, the same fix applies)

(a) **Discovery race**: the modem's rmts client does a one-shot RFSA table lookup in the
    first ~2 ms after link-up. Legacy router syncs the table *synchronously inside the
    HELLO handshake* (in-kernel, µs) → stock always wins; QRTR's userspace ns is ≥1.9 ms
    late → we always lose. (Mainline moved the ns in-kernel in v5.7 for this class of race.)
(b) **Persisted modem-side decision**: the modem recorded "no RFSA" in its EFS bootup
    state during early A16 boots and no longer re-looks-up. A healthy synchronous announce
    at HELLO may let a fresh lookup succeed and rewrite the state (or may require EFS
    surgery — only investigate if the patch below proves insufficient).

### 🧪 EFS-clear experiment (2026-07-04, serial.log.21): modemst/fsc content is IRRELEVANT — option 2 FALSIFIED, cleanly

Wiped `modemst1`+`modemst2` to zero (kept `fsg` golden + `fsc` was already blank), cold-booted.
Result: **byte-identical fatal** — `rmts_get_buffer`, size `0x180000`, same wrong address
`0x890C0000`, 20× then stabilize at `crash_count=16`. A completely blank EFS fails exactly like
a populated one ⇒ **the buffer-discovery decision does not depend on `modemst`/`fsc` content**.
Eliminates the entire "persisted modem-side decision in EFS" hypothesis family (hypothesis (ii)).

Also **confirms the chicken-and-egg** directly: after the boot, `modemst1` was **still all
zeros** — the modem never restored it from `fsg`, because restore needs EFS writes, which need
the buffer, which is the failing step. The modem cannot repair its own EFS while this bug
exists. (Consequence: device was left on blank NV; `modemst1/2` restored from the on-device +
host backups `efs_p13/p14.img`, md5 `fa0edc7c…`/`3221e027…`. `fsg`/p16 never touched.)

**Net after this session's two experiments (instance-encoding + EFS-clear): every AP-observable
variable and every EFS-persisted variable now matches stock or is proven irrelevant.** The
decision to skip the RFSA query is determined by the modem image (== stock) + the boot / SMEM /
transport environment — NOT by anything reachable with a cheap on-device probe.

### Surviving leads (need real work, not a quick flash) — next-session scope

1. **Transport-generation / qmuxd** (device-owner note: stock 8.1 used QMUX/qmuxd, not raw
   IPC-router sockets). The modem resolves & calls RMTFS(14) but never RFSA(28), both AP-hosted
   and announced identically (svc/vers/inst/node all == stock). Hypothesis: RFSA specifically
   was a qmuxd-mediated service and this 2018 AML0 modem doesn't reach it over pure QRTR the way
   it reaches RMTFS. Investigate: how does the modem's RMTS client discover RFSA vs RMTFS
   internally; is there a modem-side control-port/qmuxd expectation. Hard to instrument (modem
   is a black box) — may need comparing QCCI service-discovery behavior or a qmuxd shim.
2. **SMEM capability/TOC item** the stock 3.18 kernel populates to advertise "RFSA buffer
   discovery available" — SEPARATE from the buffer *address* (which we confirmed flows only via
   RFSA QMI, no SMEM address path in `msm_sharedmem.c`). Our mainline-derived SMEM path may not
   write such a flag. Diff stock 3.18 vs our 4.19 for any SMEM item written on the rmts/rfsa
   bring-up path beyond geometry (SMEM geometry itself already verified byte-identical to stock).
   Grep stock kernel for rmts/rfsa/sharedmem writers other than `msm_sharedmem.c`.

### ✅ Patch v2 result (2026-07-04, full flash — serial.log.20): PARTIAL WIN. Modem STABILIZES + control plane comes up at boot; but RFSA still not queried, EFS fatal not fixed. All three AP-side hypotheses now falsified.

**New positive state (never seen before this patch):**
- **Modem stabilizes.** It fatals 17× early (`rmts_get_buffer`, last at t≈424s) then **stops
  and stays `ONLINE`** — `crash_count` frozen at 17 for 7000+ s (was: fatal EVERY cycle
  forever, count → 90+). Not being restarted; genuinely running (degraded/zombie: no EFS
  buffer, so no NV/SIM data).
- **Radio control plane comes up automatically at boot** (persist.vendor.radio.autostart=1):
  `qcrild` running, **full `IRadio/slot1` v1.0–1.4 + `ISap` + `IRadioConfig` published**.
  Framework shows **"Emergency calls only"** (radio HAL alive; `mRadioPowerState=2`,
  OUT_OF_SERVICE — expected without EFS/NV/SIM). Previously the control plane only came up
  on a manual `setprop` against a crash-looping modem.
- **v2 confirmed firing:** kprobes show the `qrtr_rx` kthread sending the HELLO reply + full
  NEW_SERVER table (svc 28 included) to the modem the instant the modem HELLOs. Handshake
  now completes; qcrild's bidirectional QMI discovery against the modem works.

**But the EFS fatal is NOT fixed:** `Request count` still 0 — the modem **never sends a
GET_BUFF_ADDR to RFSA and never sends a NEW_LOOKUP** (kprobe on `qrtr_endpoint_post`: the
modem's only egress to the AP is the 4 RMTFS opens to `rmt_storage` port; zero traffic to the
RFSA port across the whole capture). The modem had the RFSA announcement in hand for ~74–86 ms
before each fatal.

**Three AP-side hypotheses now FALSIFIED with on-device evidence:**
1. Announce-timing race — v1 delivered the table 5.8 ms *before* the modem's HELLO; no change.
2. Incomplete IPC-router handshake — v2 completes it (HELLO reply + table sync); no change.
3. Missing SMEM address path — **there is none.** Stock `msm_sharedmem.c` publishes the
   buffer address ONLY via `sharedmem_qmi_add_entry` (→ RFSA QMI); no SMEM/DT-fixed-addr
   fallback exists. So stock's modem MUST query RFSA (its `Request count: 1` proves it does),
   and there is no non-QMI channel we failed to provide.

**Where that leaves it:** the modem resolves & calls RMTFS(svc 14) but NOT RFSA(svc 28),
though both are AP-hosted and announced identically (inst 0x101 == stock). The decision to
skip the RFSA query is **inside the modem** and is not gated by AP-side discovery, handshake,
or timing. Same MPSS image as stock, so the variable must be some input the modem reads before
`rmts_get_buffer` — candidates not yet excluded: (i) the QRTR *instance-id encoding* the
modem's RMTS client matches against differs from legacy for svc 28 specifically (it works for
svc 14 — why?); (ii) a modem NV/config item selects buffer-discovery method and our EFS
(written by months of A16 crash-boots on `modemst1/2`) carries a different value than a
fresh/stock EFS; (iii) the modem's RFSA client runs on a modem-side PD/task that our QRTR
routing never brings up (note the separate finding: `qrtr_must_forward` blocks ADSP↔modem —
does an analogous forward rule starve a modem sub-PD?).

**Recommended next steps (need modem-side visibility or a state reset, NOT another blind AP
patch):**
- **Cheapest discriminator:** why does the modem call RMTFS(14) but never RFSA(28)? Register a
  throwaway probe: temporarily announce RFSA under **instance 1** (like RMTFS) as well as
  0x101, and watch for a GET_BUFF_ADDR. If it appears → it's an instance-encoding mismatch,
  fixable in `sharedmem_qmi.c`.
- **EFS-state test (hypothesis ii):** back up then clear/reset `modemst1`+`modemst2` (p13/p14)
  to force the modem to re-derive config — does a virgin EFS change the buffer-discovery
  decision? (Risky; back up first; stock A11's working EFS is a different phone's, so this
  asymmetry is real.)
- **Accept degraded control plane?** If EFS-less "emergency calls only" telephony is a useful
  waypoint, the radio-compat AIDL shim retest (old TODO 5) can proceed now against the stable
  modem — decoupled from the EFS fatal.

### ⚠️ Patch v1 result (2026-07-04, full flash): NO CHANGE — but it exposed the real structural difference

v1 (replay at `qrtr_hello_work`) verified running via kallsyms + kprobes: the replay burst
(HELLO + full table incl. svc 28) fired at **channel probe, 5.8 ms BEFORE the modem's own
HELLO** — the earliest physically possible — and `Request count` stayed 0, fatal unchanged.
**Discovery-race hypothesis (a) FALSIFIED**: announce timing is not the gate. Also largely
excluded: flash-persisted modem state (b) — the modem cannot read EFS at decision time
(no buffer = no EFS reads; the decision must come from image config, SMEM/boot env, or the
live wire exchange). Stock's legacy table entry is byte-identical in (svc, inst, node) =
(0x1c, 0x101, 1) per `dump_servers`.

**The structural difference found by re-reading both kernel traces: on our build the modem
NEVER receives a HELLO reply after its own HELLO — in any cycle.** The kernel's only HELLO
goes out once at channel probe (addressed to NID_AUTO/0xffffffff, before the modem router
inits, likely discarded), and qrtr-ns's proper reply is **silently eaten by the
`hello_sent` dup-gate** (`qrtr.c:541`). On stock, the legacy router answers the modem's
HELLO and syncs the table as the reply — handshake completes. A router with an incomplete
handshake can still route data (opens use a cached server address — modem-side caching
proven) while its name-service/QCCI-notifier layer — what `rmts_get_buffer`'s RFSA client
uses — stays gated. Explains every observation to date.

### FIX v2 STAGED (2026-07-04, needs build+flash — Kyle): HELLO-reply + table replay on inbound HELLO

`qrtr_sock_queue_skb()` HELLO branch (first HELLO from a node) now calls
`qrtr_hello_reply_and_replay()`: send a HELLO reply (resetting the `hello_sent` dup-gate —
the probe-time HELLO predates the remote router's init), then replay the local server
table. This is exactly mainline in-kernel ns behavior (HELLO → say_hello back → publish
servers) and the legacy-router handshake semantic. v1's probe-time replay removed (single
trigger point). Caveat: replay/reply only fire if qrtr-ns holds the control port when the
HELLO arrives (cold-boot first HELLO at ~13 s should be fine; note if not).

### FIX v1 (superseded by v2, kept in source): local-server replay at HELLO

`net/qrtr/qrtr.c` (UNCOMMITTED working-tree change): cache every local-service
`NEW_SERVER`/`DEL_SERVER` announcement passing through `qrtr_sendmsg()` (server.node ==
local nid; dedup on service+instance, cap 128) and replay the set to a node immediately
after the kernel HELLO in `qrtr_hello_work()` — restoring the legacy-router semantic of
"server table present the instant the link is up", for ALL AP-hosted services (RFSA,
RMTFS, qcrild's, …). Userspace `qrtr-ns` still owns the table; duplicates are idempotent
upserts on the receiving router. See `qrtr_local_server_track/replay` in the source.

State: remote build 2026-07-04 clean (`LINEAGE_VERSION=23.2-20260704`); `boot.img` dd'd to
A16 `mmcblk0p25`; reboot issued; **first patched boot being watched on serial** (Kyle owns
build/flash from here on — no prior-boot.img backup was taken; any known-good boot.img
re-flashes over it, change is kernel-only).

**Validation (this boot):**
1. `grep 'Request count' /sys/kernel/debug/rmt_storage/info` → **≥1 = modem queried RFSA
   for the first time on this build** (headline metric; stock shows 1 per modem boot).
2. `dmesg`: no `rmts_get_buffer` fatal; `subsys0/crash_count = 0`.
3. Serial: after the four `rmt_storage` Open Requests expect RW/iovec traffic, not the fatal.
4. Healthy modem → resume old TODO 5: radio-compat shim retest
   (`setprop persist.vendor.radio.autostart 1`; `PLAN-radio-compat.md`).

**If `Request count` stays 0 with the replay in place:** hypothesis (a) weakens further →
pivot to (b): the modem's persisted "no RFSA" decision in its EFS bootup state
(`fs_rmts_bootup_action.c` present in MPSS image). That fork means examining/refreshing
modem-side EFS state (modemst/fsg) — higher risk, plan carefully; note stock's modemst
content demonstrably still triggers the RFSA query on the SAME NV (stock A11 boots the same
EFS partitions... **no — different phone, different EFS!** A16's own modemst was written by
months of A16 crash-boots; stock A11's was not. This asymmetry is exactly what could carry
a persisted bad decision on A16 only).

---

## 2026-06-29: `serial.log.19` contradicts three "✅" rows below — PeripheralManager is in a crash loop and `rmt_storage` isn't running this boot

Re-reading `serial.log.19` (full boot, `sys.boot_completed=1` at t≈216s) against the status
table below, three rows are wrong for this boot:

**(a) PeripheralManager (`pm-service`/`per_mgr`/`per_proxy`) is in a continuous crash loop —
NOT "✅ non-blocking."** It fires from t=186.4s through the **very last log line** (t=228.9s,
well after boot), 10+ `SIGABRT`/exit-1 cycles:
```
serial.log.19:2683 [186.440] init: Service 'vendor.per_mgr' (pid 1025) received SIGABRT
serial.log.19:2688 [186.481] init: Untracked process (pid: 1034 name: (pm-service) ... state: Z) exited with status 0
serial.log.19:3144 [192.138] init: Service 'vendor.per_proxy' (pid 1046) exited with status 1
serial.log.19:3150 [192.185] init: Service 'vendor.per_mgr' (pid 1339) received SIGABRT
... (repeats every ~5s) ...
serial.log.19:3962 [227.335] init: Service 'vendor.per_mgr' (pid 2934) received SIGABRT   <- near log end
serial.log.19:3975 [228.835] init: Service 'vendor.per_proxy' (pid 2911) exited with status 1
```
The earlier note (line ~469) dismissed this as "an early-instance RefBase abort; a later
instance stays up." That is **not** what this boot shows — no instance ever stabilizes; it
loops for the entire capture. Since pm-service is the modem registration/voter path QCRIL
depends on, a crashing PeripheralManager undermines the "radio transport works" claim and is
worth re-validating before building further on it.

**(b) Every per_mgr/per_proxy abort sets `sys.init.updatable_crashing=1`** (Android treats the
process as an updatable/APEX component):
```
serial.log.19:3612 [207.657] init: processing action (sys.init.updatable_crashing=1) ...
serial.log.19:3718 [212.298] init: processing action (sys.init.updatable_crashing=1) ...
serial.log.19:3728 [213.188] init: process with updatable components 'vendor.per_proxy' exited 4 times before boot completed
serial.log.19:3893 [218.378] init: process with updatable components 'vendor.per_proxy' exited 4 times in 4 minutes
serial.log.19:3978 [228.850] ... 'vendor.per_proxy' exited 4 times in 4 minutes   <- log end
```
This property can gate boot-completion behaviors, CTS, and any HAL that waits on updatable-
component health. It is **not** harmless noise.

**(c) `rmt_storage` is NOT running — "✅ EFS/NV served" is wrong for this boot.** init can't
even find the service definition, and the QCRIL DB preload fails:
```
serial.log.19:2655 [186.190] init: Command 'start rmt_storage' action=boot (.../init.target.rc:106) took 0ms and failed: service rmt_storage not found
serial.log.19:1914 [176.414] init: Command 'copy /vendor/radio/qcril_database/qcril.db ...' ... failed: Could not read input file '/vendor/radio/qcril_database/qcril.db': No such file or directory
```
This matters for the ERR_FATAL analysis: the buffer-handshake investigation rests on
"rmt_storage is running and serving EFS." In `serial.log.19` it isn't, so per-boot rmt_storage
health must be confirmed before interpreting any given boot's modem behavior. (2026-07-02
check: rmt_storage WAS running that boot, pid 996, `/dev/uio0` "rmtfs" present.)

**Other stale claims now contradicted:** `time_daemon` is also absent this boot
(`serial.log.19:3779` — `service time_daemon not found`); `qcril.db` is missing (above). The
status table below should be re-validated against this specific log before further work.

## 2026-07-02: modem-fatal status — RFSA and TZ/hyp_assign both RULED OUT; live suspect = the RMTFS ALLOC_BUFF exchange with `rmt_storage`

The fatal still reproduces every boot (2026-07-02: fatal at t≈215s, `crash_count=3`):
```
modem subsystem failure reason: fs_device_efs_rmts.c:161:[6 ,1572864, -1996169536] EFS: rmts_get_buffer api fa.
```
`1572864 = 0x180000` (the 1.5MB buffer size); `-1996169536 = 0x890C0000` (an address inside
the modem region — possibly an error cookie rather than "the address the modem used"; don't
over-read it).

**Ruled out — settled, do not revisit:**

1. **RFSA / `sharedmem_qmi` (falsified 2026-06-29).** The in-kernel RFSA QMI service was
   fully ported (svc 28 on the QRTR bus, correct buffer data in debugfs) and the modem
   **never queries it** — `request_count: 0` across many modem boot cycles, fatal unchanged.
   The port stays in tree (harmless, correct). Details: `PLAN-sharedmem_qmi.md`.
2. **TZ / `hyp_assign_phys` / `MEM_PROT_ASSIGN` / SMC convention (falsified 2026-07-02).**
   Proven on stock via the `msm_sharedmem` sysfs unbind/rebind experiment: **stock 3.18
   issues the same SMC64 `0x42000c16` and Palm TZ rejects it the same way (`ret: -1`),
   stock logs `err=-5` and continues — and stock's modem works**, using a dynamic AP buffer
   (`0xf7800000`) with no XPU/VMID grant at all. The "-95 EOPNOTSUPP" on our kernel is a
   remap artifact (our `scm_remap_error` maps TZ's generic `-1` to `-EOPNOTSUPP`; stock maps
   it to `-EIO`). Both SMC conventions were tested and rejected identically (SMC32 via the
   2026-06-26 hack era, SMC64 stock). The `hyp_assign_phys failed` / `batched_hyp_assign`
   dmesg lines on A16 are **cosmetically identical to stock and benign** — never "fix" them.
   Full writeup: `PLAN-tz.md`.
3. **SELinux (for now).** A16 runs **Permissive** (verified live 2026-07-02), so the
   `avc: denied ... rmt_storage ... uio/uio0/name` lines are audit-only noise. Before going
   Enforcing, add a `genfs_contexts` label for the `rmtfs_sharedmem` uio sysfs (same class
   as the existing `debugfs_rmt` rule).

**What remains — the only unexamined link in the chain:** the modem obtains its 1.5MB EFS
transfer buffer via the **RMTFS QMI exchange with userspace `rmt_storage`** (RMTFS svc 14,
hosted by the AP; the modem discovers and queries it immediately after powerup — proven in
the RFSA strace work). `rmts_get_buffer` on the modem is the client end of that exchange
(ALLOC_BUFF). Our `rmt_storage` is the **nightly QRTR-native blob**; stock runs a different,
legacy-`AF_MSM_IPC` build. Everything AP-side *around* the exchange checks out (uio0 "rmtfs"
exists, buffer allocated at `0xf7300000`, rmt_storage running and serving the EFS-partition
opens) — what has never been observed is the **content of the buffer exchange itself**.

### TODO — dependency-ordered (2026-07-02, session `radio3`)

**Blocker chain:** modem fatals every boot (`rmts_get_buffer`) → qcril wedged on the
post-fatal zombie modem → `radio-compat` shim can't publish AIDL → framework has no radio
(`mRadioPowerState=UNAVAILABLE`). Fix upstream (modem) first; the two downstream layers
may unblock for free.

1. ✅ **DONE 2026-07-03 — boots made reproducible.** Two independent defects, both fixed in
   source (need a vendor.img rebuild to bake in; validated live first):
   - **`rmt_storage` "service not found" = a misnamed no-op, NOT a real start failure.** The
     service is `vendor.rmt_storage` (`class core`, auto-starts every boot — confirmed running
     every boot). `init.target.rc:106` said `start rmt_storage` (missing `vendor.` prefix) →
     init logged "service rmt_storage not found" and the intended `on boot` ordering nudge was
     a dead no-op. Fixed: `start rmt_storage` → `start vendor.rmt_storage`.
   - **`per_mgr`/`per_proxy` crash loop root-caused and fixed.** `pm-service` (stock A8 blob)
     does `sp<>` on a **stack-allocated** binder object; modern libutils `RefBase::incStrong`
     aborts that (`'RefBase used with stack pointer argument'`, `main+1012`). An `LD_PRELOAD`
     shim (`libshim_pmservice_refbase.so`, in-tree `libshim/`, redirects `incStrong`→
     `forceIncStrong`) exists to suppress it **but was never loading**: `/vendor/bin/pm-service`
     carried a **file capability `cap_net_bind_service=ep`** (baked by `config.fs`), which forces
     the kernel to set **`AT_SECURE=1`**, and bionic **ignores `LD_PRELOAD` when `AT_SECURE=1`**.
     So the shim never mapped and pm-service survived only by ASLR luck → stochastic crash loop
     that latched `sys.init.updatable_crashing=1`. **Fix: removed `caps: NET_BIND_SERVICE` from
     the 3 `pm-service` blocks in `config.fs`** (pm-service proven not to need it — ran + registered
     `vendor.qcom.PeripheralManager` fine with no cap). Live-validated: cap stripped → `AT_SECURE=0`
     → shim maps (3 segments) → **0 RefBase aborts across 6 consecutive restarts** (was ~random).
     Comment added at the `per_mgr` init block warning not to re-add the file cap.
   > Live device is hand-patched (cap stripped on the running `/vendor`); reverts on reboot until
   > a rebuild+flash bakes the `config.fs`/`init.target.rc` changes. `updatable_crashing=1` stays
   > latched for THIS boot session (set before the fix); a clean boot with the fix won't latch it.
2. ✅ **DONE 2026-07-04 — ALLOC_BUFF exchange captured on A16: THERE IS NO ALLOC_BUFF.**
   strace across ~20 SSRs: modem svc-14 traffic = 4× OPEN (success) + benign rfnvbak fail;
   zero 0x0004/0x0003. uio0 mmap fine. The modem never asks rmt_storage for the buffer —
   see the 2026-07-04 section at the top.
3. ✅ **OBSOLETED 2026-07-04.** Stock diff done a cheaper way: stock's sharedmem debugfs
   shows `Request count: 1` → stock modem gets the buffer via **RFSA svc 28** (in-kernel),
   not via rmt_storage at all. (Stock modem-SSR strace impossible anyway: 3.18 has no
   `msm_subsys` debugfs trigger.)
4. ❌ **FALSIFIED 2026-07-04 — do not swap in mainline `rmtfs`.** The daemon is not the
   problem; the modem never sends it a buffer request of any dialect.
5. **Re-test the `radio-compat` shim** *after* the modem is healthy (`PLAN-radio-compat.md`).
   Stack/strace the hung main thread; confirm whether it was gated by qcril↔modem (comes up
   free) or is a standalone shim/config bug (then diff a sibling's `.rc`).
6. genfs label for the `rmtfs_sharedmem` uio sysfs — hygiene for Enforcing (A16 is currently
   Permissive), not the blocker.

**Out of scope / settled — do NOT reopen:** TZ / `hyp_assign` / SMC convention (falsified
2026-07-02, `PLAN-tz.md`), RFSA `sharedmem_qmi` (falsified 2026-06-29,
`PLAN-sharedmem_qmi.md`), SMEM/DT geometry (verified byte-identical to stock), modem firmware
image (== stock/siblings), the `clock_late_init` hack (ruled out).

> Device state: A16 recovered from the 2026-06-29 offline scare — back on adb, verified
> live 2026-07-02 (rmt_storage pid 996, uio0 present, Permissive).

---

## ⚠️ Modem fatals on EVERY boot — `ONLINE` is a post-fatal zombie (2026-06-26)

Investigating GPS (no QMI_LOC), traced the modem boot in full unfiltered dmesg. The modem is
**not healthily stable** — it hits **`Fatal error on the modem.`** reproducibly on every boot:

```
... modem: Brought out of reset
... modem: Power/Clock ready interrupt received      <- HW: power+clock OK
... sysmon-qmi: ssctl_new_server: ... modem's SSCTL service   <- modem QMI up
... rmt_storage: Open Request for /boot/modem_fs1 .. fs2 .. fsg .. fsc   <- modem opens EFS
... Fatal error on the modem.                        <- ~40-100ms later, EVERY boot
... subsystem_restart_dev(): Restart ... modem, restart_level = RELATED
  (2nd powerup repeats the identical pattern, then:)
... subsys-restart: modem crashed during SSR - NOT panicking (pepito bring-up), dropping re-crash
```

So the panic-survive patch absorbs the 2nd fatal and **stops restarting** the modem. Result:
`subsys0/state=ONLINE`, `crash_count=1` — but that ONLINE is **"we gave up rebooting it after it
fatal'd," not "healthy."** This reframes every "modem stayed ONLINE" reading in this file as
*not* proof of modem health. Plausibly the real gate behind **no QMI_LOC (GPS)** and SIM/data.

**Ruled out as the cause:**
- **Power / clock / firmware-auth / reset** — HW-confirmed (`Brought out of reset` +
  `Power/Clock ready interrupt received`; MBA boots; signed image authenticates).
- **Blank/bad EFS NV** — `modemst1`/`modemst2` hold valid `IMGEFS1/2` data (~1.04M nonzero/MB).
  (Must `adb root` to read `/dev/block/...p13/p14`; a non-root read returns perms-denied which
  *looks* like all-zeros — don't be fooled.)
- **The IPA `ERR_FATAL`** — `CONFIG_RMNET_IPA=n` DID land in the running kernel
  (`/proc/config.gz`); no IPA/ERR_FATAL in dmesg this boot. The fatal here is a *different*,
  modem-internal one that fires right after EFS access.

**SMEM device-tree setup VERIFIED CORRECT (2026-06-26)** — ruled out as the fatal cause.
Running DT `smem_region@86300000 = <0x86300000 0x100000>` and `modem_region@0 =
<0x86800000 0x6a00000>` both match the **stock pepito DTS byte-for-byte**, and PIL loads the
modem to exactly `0x86800000`. Difference is only binding *style*: our 4.19 build uses mainline
`qcom,smem` (a `memory-region` phandle + partition auto-discovery) vs stock downstream
`reg`+`smem_targ_info_reg=0x193d000`; the mainline path works (SMD/QRTR/rmt_storage/QMI all ride
SMEM and function). `smem 611 not available` is a *microdump-feature artifact* — mainline SMEM's
legacy partition has 512 items, the downstream microdump notifier asks for item 611, so
`WARN_ON(611>=512)` fires. Not a misconfigured memory location; it just means the crash reason
isn't reachable via microdump.

**Fault reason was HIDDEN — root-caused to a missing DTS property; FIX STAGED (2026-06-26).**

Ramdump path explored and found blocked, but it pointed at the real fix:
- **Full ramdump = ZEROS (secure region).** Enabled `enable_ramdumps=1` live, parked
  `cat /dev/ramdump_modem`, and triggered an on-demand SSR via the debugfs trigger
  (`mount -t debugfs none /sys/kernel/debug; echo restart > /sys/kernel/debug/msm_subsys/modem`
  — the modem re-inits, hits the same EFS fatal, dump collected). Got an 85MB **ELF core whose
  PT_LOAD segments are all zero** (only 334 nonzero bytes = the ELF/program headers). The modem
  runs in an XPU-secured region and PIL logs `Debug policy not present - msadp` → AP can't read
  secure modem RAM → ramdump is useless without a signed modem debug policy. Microdump also dead
  (`smem 611`). *(Capture infra for reference: `/sys/module/subsystem_restart/parameters/
  enable_ramdumps`, `/dev/ramdump_modem`, `CONFIG_QCOM_MEMORY_DUMP_V2=y`, `MINIDUMP` not set;
  `/dev/mem` off so no live devmem read.)*
- **The real reason lives in NON-secure SMEM and the kernel just wasn't reading it.** The active
  driver is downstream `pil-q6v5-mss.c`; its `restart_modem()` already calls `log_modem_sfr()`,
  which reads the modem failure-reason string from `qcom_smem_get(HOST_ANY, q6->smem_id)`. But
  `smem_id` **defaults to -1** and is only set from DTS `qcom,smem-id`; line 50
  `if (smem_id == -1) return;` → silent. Our compiled modem node
  (`vendor-legacy/qcom/msm8937.dtsi` `pil_mss: qcom,mss@4080000`, resolved via
  `scripts/dtc/include-prefixes/qcom/`) **had no `qcom,smem-id`**. (Stock 3.18's driver
  hardcoded it; the 4.19 backport requires the DTS prop.)
- **FIX STAGED:** added `qcom,smem-id = <421>` (`MPSS_CRASH_REASON_SMEM`, per
  `qcom_q6v5_pil.c:41`; siblings scuba/bengal/khaje use 421 for MSS, 423 for adsp) to that node.

**RESULT (rebuilt + flashed 2026-06-26): the SFR fix WORKED — modem crash reason revealed.**
Running DT now has `qcom,smem-id=0x1a5` (421) and dmesg prints, on every modem fatal:
```
Fatal error on the modem.
modem subsystem failure reason: fs_device_efs_rmts.c:161:[6 ,1572864, -1996169536] EFS: rmts_get_buffer api fa[iled]
```
**Decoded:** the fault is in the modem's **EFS-over-RMTS** layer (Remote Storage = the
rmt_storage/RMTFS path), call `rmts_get_buffer` — the modem cannot obtain its shared EFS
transfer buffer. Args: `1572864 = 0x180000` = **1.5MB** (== a `modemst` partition / the rmtfs
region size); `-1996169536 = 0x890C0000` = an address inside the modem region. So: the modem
brings up the RMTFS QMI link (we see `rmt_storage: Open Request for modem_fs1/2/fsg/fsc`), then
fails to get the 1.5MB shared buffer → ERR_FATAL. NOT NV-content, NOT clocks.

### The buffer handshake — settled facts (2026-06-26 → 2026-07-02)

The shared buffer is the `qcom,rmtfs_sharedmem` node, exposed as UIO (`uio0` "rmtfs",
1.5MB dynamically allocated at `0xf7300000`) that `rmt_storage` mmaps and the modem reaches
via the RMTFS QMI exchange. What's been established:

- **Our DT node is CORRECT vs stock** (client-id=1, size 0x180000, dynamic `addr=0` — stock's
  decompiled DTB has the identical dynamic-alloc node; stock allocates at `0xf7800000`).
- **`hyp_assign_phys` failing (`-95`/`-99`) is BENIGN — identical on stock** (proven
  2026-07-02 by the sysfs unbind/rebind experiment on A11, see `PLAN-tz.md`). Palm TZ rejects
  `MEM_PROT_ASSIGN` with a generic `-1` for every caller on both kernels, under both SMC
  conventions; stock warns and continues and its modem uses the un-granted buffer fine. The
  `-95` was our tree's `scm_remap_error` spelling of TZ's `-1` (stock spells it `-5 EIO`).
  Never "fix" these dmesg lines; never re-add the SMC32-first `scm.c` hack (it was an
  uncommitted local edit, discarded 2026-06-26 — the committed vendor `scm.c` is correct
  stock SMC64-first and also never helped keymaster, see `PLAN-gatekeeper.md`).
- **RFSA / `sharedmem_qmi` is not the mechanism** (falsified 2026-06-29,
  `PLAN-sharedmem_qmi.md`): the ported service registers on the bus but the modem never
  queries it. The port stays (harmless). The modem's only observed buffer-related QMI
  activity is against **RMTFS svc 14** (userspace `rmt_storage`).
- **Build provenance gotcha (keep):** the kernel builds on remote Stellaris16 (`10.0.2.43`)
  via `build-lineage23-remotely.sh` (rsync src, `mka`, rsync imgs back). rsync `-a`
  preserves mtimes, so a `git checkout`/`stash` restoring an OLD mtime can make remote
  `make` skip recompiling a file — `touch` restored files if in doubt.

**Everything kernel-side and TZ-side of the handshake is now verified good or verified
benign. The unexamined link is the userspace RMTFS ALLOC_BUFF exchange itself** — see the
2026-07-02 status section at the top of this file for the current course of action
(strace the exchange on both devices and diff).

---

**Status (2026-06-25):** `qrtr-ns` landed and **worked** — QMI service discovery
completes, QCRIL registers for the modem, and the radio control plane came alive
for the first time. The next wall is a **modem firmware ERR_FATAL**: once the QMI
plane engages, the in-kernel **IPA↔modem QMI handshake** (`ipa_v2/ipa_qmi_service`)
drives the 2018 Palm AML0 modem to ERR_FATAL → it re-crashes during SSR → kernel
panic → boot loop. Mitigated this session, and **the radio control plane now WORKS**: with the
panic-survive patch + qcril gate, enabling qcril on a booted device published the
full `IRadio/slot1` (v1.0–1.5) + `IRadioConfig` + QTI radio stack, and **qcril did
not crash the modem** (the IPA handshake was the only crasher). Framework is
`OUT_OF_SERVICE` only because no physical SIM is inserted. Remaining: insert SIM →
registration; and a *clean* boot via `CONFIG_RMNET_IPA=n` (see "Session 2026-06-25").

> Supersedes `PLAN-radio.old.md`. Forward-only. The transport-model and
> `qrtr-ns` sections below remain valid; the "Session 2026-06-25" section is the
> current frontier.

## Legend
- ✅ Working / proven on-device
- 🔧 Present but not yet runtime-verified
- ❌ Missing / the active blocker

---

## The transport model (corrected, ground-truthed against both phones)

QMI is the protocol the modem speaks. It rides on **IPC Router**, which has two
generations of kernel implementation. The whole radio story is which one our
kernel uses and what userspace that implies:

| | Stock Palm 8.1 (`android11-adb`, 3.18) | Our build (`android16-adb`, 4.19) |
|---|---|---|
| Kernel router | legacy `msm_ipc_router` | `qrtr` (`CONFIG_QRTR=y`, `CONFIG_QRTR_SMD=y`) |
| Userspace socket family | `AF_MSM_IPC` (27) | `AF_QIPCRTR` (42) |
| Name service (who hosts which QMI service) | **in the kernel** | **userspace `qrtr-ns`** — kernel has none |
| RIL | `/vendor/bin/hw/rild` + `libril-qc-qmi-1.so` | `qcrild` + `libril-qc-hal-qmi.so` (nightly) |

**The two routers talk to the *same* modem over the *same* SMD channel
(`IPCRTR`).** "The modem speaks 27, not 42" was a misread: 27 and 42 are *AP-side
socket families*, not modem protocols. The modem speaks the IPC Router wire
protocol; QRTR is a clean reimplementation of exactly that, designed to talk to
unmodified legacy modem firmware. Every sibling Mi8937 variant (santoni, land,
prada, ugg) does telephony over QRTR on this identical kernel and nightly.

### Ground-truth evidence (live boot log, `android16-adb`)

```
pil-q6v5-mss 4080000.qcom,mss: modem: Brought out of reset
qcom_smd_qrtr_callback:Not ready          # modem sends QRTR control burst, x3
qcom_smd_qrtr_callback:Not ready          # qrtr-smd hasn't probed yet -> dropped
qcom_smd_qrtr_callback:Not ready
qcom_smd_qrtr_probe:Entered               # ~32 ms later
qcom_smd_qrtr_probe:SMD QRTR driver probed # probe SUCCEEDS
```

The modem emits QRTR traffic the instant it leaves reset — proof it speaks QRTR.
`Not ready` (`net/qrtr/smd.c:27`) is a benign probe-ordering race: the receive
callback fires before `qcom_smd_qrtr_probe` sets `drvdata`, so the modem's first
three control packets are dropped. QRTR re-announces on the HELLO handshake once
the endpoint registers, so this self-heals — **no kernel patch needed**, provided
a name service is up to catch the re-announcement.

### Why `qrtr-ns` is mandatory here

`net/qrtr/qrtr.c` has **no in-kernel name service** — it routes packets and does
TX flow control (the `radix_tree`s are `qrtr_nodes` + `qrtr_tx_flow`), but there
is no service directory and no `NEW_LOOKUP` handler. The Kconfig says it outright:
*"a userspace daemon is required to maintain a service listing."*

So today: `qcrild` opens its `AF_QIPCRTR` socket, the modem announces its QMI
services via `QRTR_TYPE_NEW_SERVER` — and nothing is listening to build the
directory or answer the lookup. `qcrild` blocks in `recv` forever (observed:
`qcrild` sits in `__skb_wait_for_more_packets`), never completes QMI service
discovery, never calls `RIL_register` → no `IRadio/slot1`.

Stock 3.18 has no `qrtr-ns` *and that is correct* — its legacy router keeps the
name service in the kernel (`[msm_ipc_router]`, `[IPCRTR]`, `[modem_IPCRTR]`
threads on `android11-adb`). That stock has no `qrtr-ns` says nothing about our
build; our QRTR kernel **requires** one.

> **Transport-history correction (2026-06-26, from device owner):** the **original Palm
> Android 8.1** stack used **QMUX/qmuxd** for QMI, not raw IPC-router sockets. qmuxd is a
> userspace QMI multiplexer that can ride the in-kernel IPC router, so this does not
> contradict the `msm_ipc_router` threads above — but note `android11-adb` runs an **A11
> GSI**, not Palm's original 8.1 userspace, so it is *not* a witness to how Palm reached
> QMI_LOC/location. Implication: our QRTR-only build skips qmuxd entirely; **confirm by
> direct bus enumeration** that each needed service (esp. QMI_LOC) is actually *announced*
> over QRTR rather than historically reached via qmuxd mediation. See `PLAN.md` "Holistic
> cross-cutting analysis" → Cluster A and `PLAN-gps.md`.

---

## Session 2026-06-25 — `qrtr-ns` worked; next wall is the AML0 modem ERR_FATAL

### `qrtr-ns` validated

Packaged `qrtr-ns` + `libqrtr.so` from the nightly. On boot the radio control
plane progressed far past its old dead-end: from only `IQcRilAudio`/`IQtiOemHook`
+ "connecting to QMI FW (port 65535)" to **"Radio HAL compat service starting"**,
`IRadioConfig`/`IRadioMessaging/slot1` being requested, and **"PerMgrSrv QCRIL
registered for modem"**. QMI service discovery over QRTR now completes. The
`qrtr-ns` thesis was correct.

### The new failure: modem ERR_FATAL → double-crash → kernel panic

With QMI live, the modem ERR_FATALs ~265 ms after powerup, *every* powerup, and
re-crashes during its own SSR restart window — which the SSR framework treats as
fatal:

```
modem: Brought out of reset → "Subsystem error monitoring services are up"
→ "Fatal error on the modem."                         (~265 ms later, every cycle)
→ restart begins → modem fatals again during restart
→ panic("Subsystem modem crashed during SSR!")        drivers/soc/qcom/subsystem_restart.c:1193
→ reboot loop → recovery
```

The panic at `:1193` is a hard *double-crash-during-restart* guard, **not**
governed by `restart_level`. The modem's own assert reason was unreadable
(`microdump_modem_notifier_nb: smem 611 not available` — it dies before writing
its SMEM error log). Only the modem fatals; adsp/wcnss/venus come up clean.

### Root cause: the in-kernel IPA↔modem QMI handshake

The crasher is **not qcril** (it stays held by the gate and the modem fatals
anyway). It is the kernel **IPA-v2 QMI client** (`ipa_v2/ipa_qmi_service.c`,
`ipa_q6_clnt`): when the modem's IPA QMI service becomes discoverable (which only
happens once `qrtr-ns` is up), IPA does a handshake — `qmi_init_modem_send_sync`,
`handle_install_filter_rule_req` (pushes UL filter rules into the modem). The 2018
AML0 modem's IPA-QMI schema is older than the 4.19 driver's; the version/state
mismatch → ERR_FATAL. (Confirmed pattern: "IPA received MPSS AFTER_POWERUP" then
"Fatal error on the modem.")  `ipa_qmi_service` + `rmnet_ipa` are gated by
`CONFIG_RMNET_IPA` (separate from the IPA core `CONFIG_IPA`), and
`ipa_qmi_service_init()` is called only from `rmnet_ipa.c`.

### Modem identity (so it's on record)

Pulled from the target's modem partition — **identical to stock and to the working
siblings**, so it is *not* a wrong/mismatched image:

```
QC_IMAGE_VERSION_STRING = MPSS.TA.2.3.C1-214411      (matches stock baseband …214411…)
IMAGE_VARIANT_STRING    = 8940.gen.prod              (generic MSM8940 production modem)
OEM_IMAGE_VERSION_STRING = WS241                     (Palm OEM tag)
```

There is **no separate modem chip / name** — it's the integrated LTE modem of the
MSM8940 (Snapdragon 435), and `MPSS.TA.2.3.c1 / 8953_GEN_PACK` is the searchable
identity. **Firmware-bump avenue is closed:** santoni/land/prada ship the *same*
`MPSS.TA.2.3.c1-…-8953_GEN_PACK` and have working telephony, so we're at the
unified ceiling. The fix is integration, not firmware.

### Evidence the modem speaks QMI-over-QRTR (and DTS is not the variable)

- Behavioral proof: with the kernel QRTR link up but *no* name service the modem
  sat idle and stable; the instant `qrtr-ns` enabled QMI discovery the modem began
  *processing* QMI content (and asserting on it). You can't crash on a message you
  never received → the modem actively exchanges QMI over QRTR.
- DTS: QRTR and legacy `msm_ipc_router` ride the **same** SMD `IPCRTR` channel
  (`msm8937.dtsi: qcom,smd-edge=<0>; qcom,smd-channels="IPCRTR"`); `qcom_smd_qrtr`
  binds it by rpmsg name and needs **no DTS node**. Empirically the channel comes
  up and QMI flows, so the transport DTS is already adequate. The crash is QMI
  *content*, above the transport — so switching to the legacy router would carry
  the same content to the same modem and hit the same crash. **Do not port
  `msm_ipc_router`.**

### The QRTR userspace trilogy (mainline names vs our QTI stack)

| Role | Mainline daemon | Our (QTI/Android) status |
|---|---|---|
| Service lookup | `qrtr-ns` | ✅ packaged this session |
| EFS / NV back-end | `rmtfs` | ✅ **covered by `rmt_storage`** (QTI equiv) — running; `modemst1/2`(p13/p14), `fsg`(p16), `fsc`(p2) present + symlinked + served. (`rfnvbak` open-fail is benign: backup NV; primary lives in `modemst1/2`.) |
| PD localization | `pd-mapper` / `tqftpserv` | ❌ `pd-mapper` absent (2026-06-26 confirmed: **no init service** in any rootdir + binary disabled, `proprietary-files-qc-vndr.txt:468`). Its RFS sibling `tftp_server` (= `tqftpserv`) IS packaged but **crash-loops** on socket-create (`PLAN-gps.md`). Not required for the **control plane** (siblings prove it); needed for **user-PD** services → GPS QMI_LOC?, data, VoLTE/audio. See `PLAN.md` Cluster A. |

### Fixes applied this session (all `[TEMP][pepito]`, in `PLAN.md` TEMP table)

1. **Kernel panic-survive** — `subsystem_restart.c:1193` `panic(...)` → `pr_err_ratelimited`
   + drop the re-crash; the in-flight restart finishes. SoC survives any modem crash.
2. **`CONFIG_RMNET_IPA=n`** (`mi8937_defconfig`) — removes the IPA↔modem QMI
   handshake (the confirmed crasher). Keeps IPA core (`CONFIG_IPA=y`). Standard
   escape hatch for old modems on modern kernels.
3. **qcril auto-start gate** — `vendor.qcrild` held behind
   `persist.vendor.radio.autostart=1` so the control plane is opt-in / on-demand.

### RESULT (first flash, 2026-06-25) — control plane up

Device **booted** (panic patch worked). Note: `RMNET_IPA` was still `=y` in this
build (incremental build reused a stale kernel `.config`; the `.c` panic patch
recompiled but the defconfig change didn't regenerate), so the modem still
IPA-ERR_FATALed 3× at boot — **absorbed by the panic patch**, modem recovered to
`ONLINE`. Then, on demand (`setprop persist.vendor.radio.autostart 1`):

- `qcrild` started and stayed healthy; **modem ERR_FATAL count did not increase**
  → qcril's own QMI is compatible with the AML0 modem. (IPA was the sole crasher.)
- `lshal` published the **entire radio HAL surface** for the first time:
  `android.hardware.radio@1.0–1.5::IRadio/slot1`, `…radio.config@1.0/1.1` +
  `lineage.hardware.radio.config@1.0::IRadioConfig`, plus QTI IMS/UIM/LPA/QtiRadio/Sap.
- Framework: `Phone Id=0`, `mVoiceRegState=OUT_OF_SERVICE`, `mSignalStrength=null`,
  `mDefaultSubId=-1` — the expected "HAL up, **no physical SIM**" state.

**To get a clean boot:** force the kernel `.config` to regenerate so `RMNET_IPA=n`
takes (clean `out/.../KERNEL_OBJ`); the `mi8937_defconfig` edit itself is correct.
Then the modem won't crash at all and the panic patch is just insurance.

### Open question (ANSWERED) + data-path roadmap

- ~~Does qcril's own QMI agree with the AML0 modem?~~ **Yes — confirmed.** Full
  `IRadio` stack up, modem stable. The only crasher was the IPA-QMI handshake.

- **Open:** does qcril's *own* QMI init agree with the AML0 modem over QRTR? Test
  after a clean boot via `setprop persist.vendor.radio.autostart 1`. If yes →
  control-plane telephony (registration/SIM/signal/voice/SMS), data deferred. If
  it also ERR_FATALs → a broader QMI-compat problem (still not transport-related).
- **Data path (deferred):** with IPA hardware acceleration off, cellular data uses
  **software RMNET** (`qmi_wwan` / generic rmnet link drivers) — control via QMI/
  RmNet mux ports, IP routing/NAT/checksums on the CPU. This + `pd-mapper` is the
  data/VoLTE workstream once the control plane is stable.

### SIM test (2026-06-25) — slot2 fix landed; new wall is the HIDL→AIDL compat shim

Inserted a physical SIM. Not detected yet — but root-caused *above* the modem:

- **Single-SIM VINTF fix (the slot2 instinct).** The HIDL→AIDL radio compat shim
  (`android.hardware.radio-service.compat`, `service.cpp`) enumerates radio slots
  via `listManifestByInterface(IRadio)` and calls `IRadio::getService("slotN")` for
  each. mithorium `manifest.xml` declared dual-SIM (slot1+slot2), so on single-SIM
  pepito `getService("slot2")` blocked forever (1 Hz retry +
  `ctl.interface_start IRadio/slot2 → PROP_ERROR`), wedging the *whole* AIDL
  bring-up incl. slot1 → `mRadioPowerState=UNAVAILABLE` → no SIM. **Fixed:** removed
  the radio `slot2` instances from `manifest.xml` (matches `…multisim.config=ssss`
  + disabled `qcrild2`). Confirmed the slot2 loop is gone.

- **New blocker (same shim).** With slot2 gone the shim now publishes the slot1
  AIDL interfaces (config/data/messaging/modem/network/sim/voice), but they aren't
  *usable*: each `addService` warns `Thread Pool max thread count is 0, cannot cache
  binder`, init can't lazy-start them (`ctl.interface_start aidl/…IRadioData/slot1
  → PROP_ERROR_HANDLE_CONTROL_MESSAGE`), `lshal` shows no AIDL radio → framework
  `mRadioPowerState=2 (UNAVAILABLE)` → card never queried. The `vendor.radio-compat`
  `.rc` declares **no `interface aidl …` lines** and the binder threadpool reads 0.
  So the SIM blocker is the **`vendor.radio-compat` service integration**, NOT the
  modem (qcril + HIDL `IRadio/slot1` are healthy), the clock, QRTR, or SIM hardware.

- **Next step (next session):** why the compat shim's AIDL interfaces aren't
  serviceable — threadpool / lazy-start / missing `interface aidl` declarations.
  Fast path: diff how a working sibling (`santoni`/`land`) declares + starts
  `vendor.radio-compat` (its `.rc` interface lines, how the AIDL services come up).

- **Clock hack ruled out.** The `8ad870…` `clock_late_init` skip was re-enabled by
  `56f69a…` (active at `clock.c:1423`), has no modem/mss/q6 logic, and only *leaks*
  handoff votes (keeps clocks on) — it cannot starve the modem. Not a factor.

- **Device state:** `manifest.xml` fix is committed in source; also live-edited on
  `/vendor` (so this boot ran single-SIM) → device is hand-patched. Canonical next
  flash = clean build (manifest fix + `RMNET_IPA=n` via `.config` regen).

---

## High-level state

| Layer | Status | Notes |
|---|---|---|
| Modem PIL boot (`pil-q6v5-mss`) | ✅ | Loads `mba.mbn` + `modem.b**`, "Brought out of reset", `modem.state=ONLINE`. |
| `rmt_storage` (modem EFS proxy) | ✅ | Running (must precede modem init or modem SSR-loops). |
| PeripheralManager (`pm-service`/`pm-proxy`) | ✅ | QCRIL registers + votes modem up. (`pm-service` has an early-instance `RefBase` abort; a later instance stays up — technical debt, non-blocking.) |
| Single-SIM config | ✅ | `persist.radio.multisim.config=ssss`, `ro.telephony.default_network=33`; only `vendor.qcrild` runs, one framework phone. |
| QRTR kernel transport (`qrtr` + `qrtr-smd`) | ✅ | Driver probes; modem announces services over it; QMI flows. |
| QRTR name service (`qrtr-ns` + `libqrtr.so`) | ✅ | Packaged 2026-06-25; QMI service discovery completes; QCRIL registers for modem. |
| Modem firmware (`MPSS.TA.2.3.c1`, `8940.gen.prod`) | ✅ | Same image as stock + siblings; not a wrong-image issue. |
| Modem stability under live QMI | ✅* | qcril drives the modem without crashing it (IPA-QMI was the sole crasher; clock hack ruled out). *Clean boot still needs `RMNET_IPA=n` to actually apply (stale `.config` ignored it on 1st build); the panic-survive patch absorbs the IPA crash-dance meanwhile. |
| IPA data path (`CONFIG_RMNET_IPA`) | ⏸ | To be disabled (stale `.config` blocked it on 1st build). Cellular data deferred to software RMNET (`qmi_wwan`) later. |
| `qcrild` + HIDL `IRadio/slot1` (+ QTI stack) | ✅ | qcril healthy; full HIDL `IRadio@1.0–1.5/slot1` + IMS/UIM/LPA/QtiRadio/Sap published; modem stable. |
| **HIDL→AIDL radio compat (`vendor.radio-compat`)** | ❌ | **Active SIM/registration blocker.** Publishes slot1 AIDL but the interfaces aren't serviceable (threadpool=0, init lazy-start `ctl.interface_start` fails) → framework `mRadioPowerState=UNAVAILABLE`. (slot2-hang already fixed via `manifest.xml`.) |
| SIM / network registration | ❌ | Blocked on the compat shim above; modem/card path can't be exercised until the framework has a usable radio. |
| `pd-mapper` (PD service locator) | ❌ | Absent. Not needed for control plane (siblings prove it); needed for data/VoLTE PDs later. |
| GPS (`loc_launcher`) / IMS (`ims*daemon`) | 🔧 | Extracted; out of scope until basic SIM/network registration works. |

---

## The fix: package `qrtr-ns` + `libqrtr.so`

Everything except the two binaries is already in the tree:

- `device/xiaomi/mithorium-common/rootdir/etc/init.qcom.rc:443` —
  `service vendor.qrtr-ns /vendor/bin/qrtr-ns -f`, `class core`,
  `user/group vendor_qrtr`, `capabilities NET_BIND_SERVICE`, `disabled`; started
  on `init.svc.vendor.qrtrns.enable=1`.
- `device/xiaomi/mithorium-common/rootdir/bin/init.qcom.early_boot.sh:426-442` —
  sets `qrtrns.enable=1` for `msm8937` + `soc_hwid ∈ {386,354,353,303,313}` on
  kernel ≥ 4.14. Pepito's `313` is in the list and the gate fires.
- `device/xiaomi/mithorium-common/config.fs` — `AID_VENDOR_QRTR` defined.
- `proprietary-files-qc-vndr.txt:419,468` — `qrtr-ns` and `pd-mapper` already listed.
- `device/qcom/sepolicy-legacy-um/legacy/vendor/common/qrtr.te` — domain exists,
  included via the same path that provided the `tee`/`qcrild` domains.

Sources (nightly is mounted at `/mnt/vendor-nightly`):
- `/mnt/vendor-nightly/bin/qrtr-ns` — aarch64; `NEEDED`: `libqrtr.so`, libc++/c/m/dl.
- `/mnt/vendor-nightly/lib64/libqrtr.so` — present (≈11 KB).

Steps:
1. **Stage both blobs** into the mithorium-common vendor tree (this is the same
   gap that left `pm-service` unpackaged — mithorium-common is in legacy-extractor
   state, so the listed-but-not-on-disk blobs never get installed). Put
   `qrtr-ns` under `proprietary/vendor/bin/` and `libqrtr.so` under
   `proprietary/vendor/lib64/`, and install via the same legacy `PRODUCT_COPY_FILES`
   path used for `pm-service`/`pm-proxy`.
2. **Walk `libqrtr.so`'s `DT_NEEDED` closure** and confirm each dep is already in
   the image (expected: libc/liblog/libcutils tier — trivial).
3. **Confirm sepolicy labels** `qrtr-ns` as `vendor_qrtr_exec` and the domain can
   create `AF_QIPCRTR` sockets + bind the control port. SELinux is currently
   permissive, so denials won't block the first test — collect them for the
   eventual enforcing pass.

This needs **no kernel change** and **no stock AML0 blobs** — the nightly
`qcrild`/`libril-qc-hal-qmi.so` stack already has every other dependency met.

### Validation (flash, then check in order)

1. `/vendor/bin/qrtr-ns` and `/vendor/lib64/libqrtr.so` exist on device.
2. `init.svc.vendor.qrtrns.enable=1` and `init.svc.vendor.qrtr-ns=running`.
3. `qcrild` advances past `qmi_ril_client_get_master_port` and calls `RIL_register`.
4. `lshal` shows `android.hardware.radio@1.x::IRadio/slot1` +
   `IRadioConfig/default` (today only `IQcRilAudio`/`IQtiOemHook` appear).
5. `dumpsys telephony.registry` shows a subscription + service state moving off
   `OUT_OF_SERVICE` (insert a physical SIM for full registration).

### If discovery is flaky after `qrtr-ns` is up

The dropped-burst race means the modem may have announced before `qrtr-ns`
opened its socket. Levers, cheapest first:
- Restart `qcrild` (re-triggers HELLO + lookup) once `qrtr-ns` is confirmed up.
- Force a modem SSR (`subsys_modem`) so it re-announces with `qrtr-ns` listening.
- Only if persistently racy: order `qrtr-ns` strictly before the modem leaves
  reset, or re-kick discovery after `modem.state=ONLINE`.

---

## Strategic note — `qrtr-ns` is the platform QMI keystone, not just radio

Every QMI-over-QRTR subsystem on this kernel needs the same name service:

- **Sensors** — both the SSC and SMGR paths talk QMI to the ADSP. The
  sensors-HAL "blocks in QRTR before registration" symptom is the *same* missing
  name service. See `PLAN-sensors.md`.
- **GPS** (`loc_launcher`/`xtra-daemon`) — location QMI services.
- **IMS / VoLTE** — `imsqmidaemon` bridges IMS to modem over QMI.

Treat `qrtr-ns` as foundational platform plumbing. Landing it is likely to
unblock or de-risk sensors, GPS, and IMS in addition to radio. `pd-mapper` is
the next layer down (protection-domain service location — ADSP audio PD, modem
sub-PDs); source it after `qrtr-ns` proves out (it is not in the nightly — the
`proprietary-files` entry points at an FP3 payload, or build from the Linaro
`pd-mapper` source).

---

## After IRadio comes up (deferred, in order)

1. **ACDB calibration for pepito** — nightly has land/prada/santoni/ulysse, no
   pepito. Pull the real Palm set from `android11-adb:/vendor/etc/acdbdata/` and
   stage it (VoLTE downlink audio depends on it). See `PLAN.md` TODO.
2. **`pd-mapper`** — for PD-hosted QMI services (audio/sensors PDs).
3. **GPS pipeline** — pull stock `gps/izat/flp/lowi/apdr.conf` from `android11-adb`;
   provision `/data/vendor/location/gps.prop` before re-enabling `loc_launcher`.
4. **IMS / VoLTE** — only after stable SIM + data registration.

---

## Two-device methodology (radio)

When radio breaks on `android16-adb`, answer empirically from `android11-adb`
(stock 3.18 + stock 8.1 vendor — every subsystem works there):

```bash
# stock transport truth
adb -s 81eed371 shell 'cat /proc/net/protocols | grep -iE "MSM_IPC|QIPCRTR"'  # -> MSM_IPC (legacy)
adb -s 81eed371 shell 'ps -A | grep -iE "rild|netmgr|IPCRTR|ipc_router"'      # legacy router threads
adb -s 81eed371 shell 'getprop gsm.version.baseband'                          # stock modem fw rev
# our build
adb -s c39a6acf shell 'dmesg | grep -iE "qrtr|q6v5|smp2p"'                    # qrtr-smd probe + modem boot
adb -s c39a6acf shell 'ps -A | grep -iE "qrtr|qcrild|rmt_storage|pm-serv"'
```

The device tree is **not** suspect here: modem PIL boot, `qrtr-smd` probe, and
the QRTR control burst all succeed. The gap is one userspace daemon.

---

## Service / blob cross-reference

| Service | Binary | Backing | State |
|---|---|---|---|
| `vendor.qrtr-ns` | `/vendor/bin/qrtr-ns` | `libqrtr.so` | ✅ packaged; QMI discovery works |
| `vendor.qcrild` | `/vendor/bin/hw/qcrild` | `libril-qc-hal-qmi.so`, `libqmi*`, `libril` | 🔧 past discovery; auto-start gated |
| `vendor.per_mgr` / `vendor.per_proxy` | `/vendor/bin/pm-service`,`pm-proxy` | `libperipheral_client.so` | ✅ registers/votes modem |
| `rmt_storage` (= mainline `rmtfs`) | `/vendor/bin/rmt_storage` | `modemst1/2`, `fsg`, `fsc` | ✅ running; EFS/NV served |
| IPA QMI handshake | kernel `ipa_v2/ipa_qmi_service` | `CONFIG_RMNET_IPA` | ❌ crashes AML0 modem → disabled (`=n`) |
| Modem stability | kernel + bootloader | `rmt_storage` + no IPA-QMI | ⚠️ ERR_FATAL until `RMNET_IPA=n` build |

## TODO order (radio-only)

1. ✅ Single-SIM pepito config.
2. ✅ PeripheralManager (`pm-service`/`pm-proxy`) — modem registered + voted.
3. ✅ Root-cause transport — QRTR is correct; modem speaks QMI over it.
4. ✅ **Package `qrtr-ns` + `libqrtr.so`** (2026-06-25) — QMI service discovery works.
5. ✅ **Root-cause modem ERR_FATAL** — IPA↔modem QMI handshake (`ipa_v2/ipa_qmi_service`),
   not qcril. Modem image confirmed correct (`MPSS.TA.2.3.c1`, == stock/siblings).
6. ✅ **Mitigations staged** (kernel, pending build): panic-survive at
   `subsystem_restart.c:1193`; `CONFIG_RMNET_IPA=n`; qcril auto-start gate.
7. ✅ **Build/flash + control-plane test (2026-06-25).** Booted (panic patch);
   `setprop persist.vendor.radio.autostart 1` → full `IRadio/slot1` + `IRadioConfig`
   + QTI stack published, **modem did not crash**. Control plane works.
8. ✅ **SIM inserted + slot2 fix (2026-06-25).** Removed radio `slot2` from
   `manifest.xml` → the compat shim no longer hangs on the phantom slot2.
9. ❌ **ACTIVE BLOCKER: `vendor.radio-compat` AIDL interfaces not serviceable.**
   Shim publishes slot1 AIDL but threadpool=0 + init lazy-start (`ctl.interface_start`)
   fails → `mRadioPowerState=UNAVAILABLE` → SIM not detected. **Next:** diff a working
   sibling's `vendor.radio-compat` `.rc` (`interface aidl …` lines) + how its AIDL
   radio services come up; check the shim's binder threadpool setup.
10. 🔧 **Once radio is AVAILABLE:** verify UICC detect → subscription → registration
    → signal → calls/SMS (this is where we finally exercise the modem↔card path).
11. 🔧 **Clean boot:** regenerate kernel `.config` so `RMNET_IPA=n` applies (1st build
    reused a stale `.config`) → 0 modem ERR_FATALs at boot. Cleanup, not blocking.
12. ▫️ **Data path (deferred):** software RMNET (`qmi_wwan`/generic rmnet) + `pd-mapper`.
13. ▫️ ACDB calibration, GPS, IMS/VoLTE — deferred per "After IRadio" above.

> **Resume here next session:** the radio HIDL stack + modem are healthy; the lone
> SIM/registration blocker is the HIDL→AIDL `vendor.radio-compat` shim not making its
> AIDL interfaces usable. Start at item 9. Device is hand-patched (live `manifest.xml`
> edit + service restarts); a clean build (manifest + `RMNET_IPA=n`) is the baseline.
