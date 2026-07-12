# PLAN — Disassemble the modem's `rmts_get_buffer` / RFSA decision (pepito/PVG100)

**Owner:** dedicated agent. **Created:** 2026-07-05 (session `radio6`).
**Goal:** Read, from the modem binary itself, *why* the 2018 AML0 modem skips the RFSA
shared-buffer query on our 4.19 boot — replacing 6+ rounds of AP-side input-guessing with the
modem's actual decision logic. This is the current **top lead** for the `rmts_get_buffer`
ERR_FATAL that blocks all telephony. Background: `PLAN-radio.md` (radio4/5/6 sections) and
memory `radio-rmts-buffer-rootcause.md`. **Read those first** — do not re-run falsified AP-side
experiments; this plan is strictly static modem analysis.

---

## The question, precisely

On stock msm-3.18 the modem sends a QMI `GET_BUFF_ADDR` to the AP's RFSA service (svc 28) once
per boot to learn its 1.5 MB EFS transfer buffer address (`/sys/kernel/debug/rmt_storage/info`
`Request count: 1`). On our 4.19 build the **same modem image** never sends it (`Request count:
0`), so `rmts_get_buffer` fails and the modem ERR_FATALs ~200 ms after powerup, every boot:

```
modem subsystem failure reason: fs_device_efs_rmts.c:161:[6 ,1572864, -1996169536] EFS: rmts_get_buffer api failed
```
`1572864 = 0x180000` (buffer size); `-1996169536 = 0x890C0000` (an address/cookie). The modem
DOES talk to RMTFS (svc 14, 4× EFS OPEN every boot) — so the transport is fine; only the RFSA
path is skipped. radio4–6 proved the decision is **modem-internal**: not gated by AP
announcement, instance encoding, HELLO handshake, timing, EFS content, or any SMEM/SMSM item we
write. **The answer is in the modem's own code path from `rmts_get_buffer` to the RFSA client.**

Concretely, find and read the code that decides **buffer-discovery method**: stock modems can
get the buffer via (a) RFSA QMI query, or (b) a fixed/SMEM-published address. Our modem picks a
path that fails. The disassembly must reveal *what input* selects the path (an NV item, an SMEM
item, a QMI/QDI capability probe, a compile-time GUID/geometry check) so we can make our 4.19
platform present that input the way stock 3.18 does.

---

## Ground truth already established (do not re-derive)

- **`modem.bin` is the FAT16 modem partition, not the executable.** Located at
  `~/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/modem.bin`
  (88 MB, `file` → "DOS/MBR boot sector … FAT (16 bit)"). The MPSS executable lives inside as
  `image/modem.mdt` (ELF header + 23 program headers) plus `image/modem.b00 … modem.b20`
  (segment payloads; `.bNN` index == program-header index).
- **It is ELF32, Machine = Qualcomm Hexagon, entry 0x86800000, 23 phdrs, no section headers.**
- **Executable LOAD segments** (vaddr / filesz / flags):
  | seg | vaddr | filesz | flags | `.bNN` |
  |---|---|---|---|---|
  | 2 | 0x86800000 | 0x1574 | R-X | b02 |
  | 5 | 0x86840000 | 0x33d68 | RWX | b05 |
  | 6 | 0x86874000 | 0x8f984 | R-X | b06 |
  | 9 | 0x86b10000 | 0x1d2b14 | R-X | b09 |
  | **10** | **0x86ce3000** | **0x135d0b0 (~20 MB)** | **R-X** | **b10** ← the main text |
  | 20 | 0x8a8d1000 | 0x113000 | RWX | b20 |
- **The fault string `fs_device_efs_rmts.c` is at vaddr `0x88152d31`** (read-only segment at
  0x88140000, phdr flags R). This is the primary anchor — the assert at `:161` loads this
  pointer as its `__FILE__` argument, so the code that references `0x88152d31` **is**
  `rmts_get_buffer`'s failure site. `RFSA_pool` string is also present (vaddr in the same RO
  region). `rmts_get_buffer` / `rfsa_client` appear in `strings modem.bin` but not as contiguous
  literals in the reassembled ELF — use the file-path anchor, not the function-name strings.
- **Toolchain: system `llvm-objdump-15` (`/usr/bin/llvm-objdump-15`) — it HAS the Hexagon
  target. The in-tree clang (`clang-r563880`, LLVM 21) DROPPED Hexagon — do not use it.**
  Confirmed working: constants render as `immext(#…)` + `r=##…` pairs, calls resolve to targets.

### Proven-working reconstruction + disassembly (copy-paste)

The reassembly script is committed at `scripts/mpss-reasm.py` (see below for its content if
missing). Full pipeline, already validated this session:

```bash
WORK=/tmp/mpss                      # any scratch dir
mkdir -p $WORK && cd $WORK
MODEM=~/Projects/android-pepito-pvg100-kernel-upgrade/backup-stock-android-8.1-AML0/modem.bin
7z x -y "$MODEM" 'image/modem.*' >/dev/null      # -> image/modem.mdt + modem.b00..b20
python3 ~/android/lineage-23/scripts/mpss-reasm.py image modem.elf   # -> modem.elf (~60MB)

OBJ=/usr/bin/llvm-objdump-15
# Full text disassembly of the main code segment (slow, ~20MB -> large; redirect to a file):
$OBJ -d --triple=hexagon --start-address=0x86ce3000 --stop-address=0x88080000 modem.elf > seg10.dis
# Windowed disassembly around a known vaddr:
$OBJ -d --triple=hexagon --start-address=0xADDR --stop-address=0xADDR+0x400 modem.elf
```
Verified sample output (segment 10 head) — this is what correct disassembly looks like:
```
86ce3008: immext(#2311730688)
86ce300c: r18 = ##-1983236604 }      # 32-bit const built via immext + ##
86ce3014: call 0x86ce3080
86ce301c: p0 = cmp.eq(r0,#0); if (!p0.new) jump:nt 0x86ce3070
```

---

## Method — anchor-driven, in priority order

### Step 1 — Find the assert call site (`rmts_get_buffer` failure path)
The `##` immediates in llvm-objdump are **signed decimal**. `0x88152d31` → signed 32-bit =
`-2011357391`. Disassemble the code segments to a file and grep for that constant; each hit is a
place that materializes the fault-file pointer:
```bash
$OBJ -d --triple=hexagon modem.elf > all.dis 2>/dev/null   # whole ELF; big but one-time
grep -n -- '-2011357391\|0x88152d31' all.dis
```
Hexagon builds 32-bit constants as `immext(#hi)` + `r = ##val`; the value may also appear as
`##2283609905` (unsigned) depending on render — grep both. Also try the line-number literal
`#161` near the same basic block to disambiguate the `:161` assert from other refs to the same
file. The function containing this site, walked **backwards to its entry** (first instruction
after the preceding `allocframe`/`{ … }` return boundary, or the target of `call`s found by
xref), is `rmts_get_buffer` (or its inlined parent `fs_device_efs_rmts` init).

### Step 2 — Read the decision that precedes the assert
Within that function, identify the branch that chooses buffer-discovery method and fails on our
platform. Look specifically for, in rough likelihood order:
1. **A QMI/QDI client call that returns an error** → the RFSA `GET_BUFF_ADDR` send itself, and
   the predicate guarding whether it is even attempted. If there's a guard `if (cap)` /
   `if (method == X)` **before** the send, that predicate's input is the whole ballgame.
2. **An SMEM read** (`smem_get`/`smem_alloc` equivalent — resolve the callee, then the item id
   in the arg). If the modem keys off an SMEM item our 4.19 kernel doesn't populate (or
   populates differently), that's the fix target. Cross-check against the SMEM item table in
   `PLAN-radio.md` radio6 section — we already dumped every kernel-written item.
3. **An NV/EFS config read** deciding method — but note EFS is excluded as *content* (radio4
   wipe test); a *method-selector* NV read that returns a default when EFS is unreadable is
   still possible and would be visible here.
4. **A compile-time / GUID / geometry constant** (`fs_rmts_guid.c`, `fs_rmts_image_header.c`
   are in the strings) — e.g. the modem validates a client-id/GUID/region-count against what
   the AP advertised; our RFSA registration tuple mismatches something beyond svc/inst/node.

### Step 3 — Resolve callees to names
The ELF is stripped (no symbols). Name functions by the **strings they reference**: a function
that loads a pointer to `"rfsa_client"`, `"RFSA_pool"`, `"fs_rmts_bootup_action.c"`, etc. is
that module. Build a vaddr→string map once and use it to label call targets:
```bash
# map every RO string to its vaddr (reuse the phdr math from mpss-reasm.py)
python3 ~/android/lineage-23/scripts/mpss-strings-vaddr.py modem.elf > strings.vaddr
```
Then for any `call 0xTARGET`, disassemble a window at TARGET and see which string vaddr it
loads → that's the function's identity. Key strings to anchor on (all confirmed present):
`fs_device_efs_rmts.c`, `fs_rmts_bootup_action.c`, `fs_rmts_guid.c`, `fs_rmts_image_header.c`,
`fs_rmts_super.c`, `fs_rmts_pm.c`, `rmts_api.c`, `rfsa_client`, `RFSA_pool`.

### Step 4 — Compare against stock's *working* invocation (if needed)
We only have this one modem image (it's shared stock↔sibling↔ours — same binary works on 3.18).
So the binary can't tell us "3.18 vs 4.19" directly; it tells us **what input the modem reads**.
Once Step 2 names the input, verify on-device which value stock's 3.18 platform provides vs our
4.19 — using the two-device method (`PLAN-radio.md`, and the new `/d/smem_toc`, `/d/smem_raw`,
`/d/smsm_legacy` A16 instruments; A11 `81eed371` for stock ground truth once reconnected).

---

## Deliverable

A written finding in this file (append a dated "RESULT" section) stating:
1. The vaddr + disassembly of `rmts_get_buffer`'s failure path and the exact branch/predicate
   that selects the failing buffer-discovery method.
2. The **input** that predicate reads (SMEM item id / NV item / QMI capability / GUID), with the
   callee resolution that proves it.
3. A concrete, testable AP-side change: what our 4.19 kernel/DT/userspace must present so the
   modem takes the RFSA path — expressed as a staged edit for Kyle to build+flash (Kyle owns
   build/flash; this agent does static analysis + on-device *read-only* diagnostics only, per
   the working agreement).

If the path turns out to be genuinely unfixable from the AP (e.g. the modem hard-requires a
capability only the legacy IPC-router could present), say so decisively — that redirects the
whole radio effort (accept "emergency calls only", or revisit porting a shim) and is itself a
high-value result.

---

## Guardrails

- **Static analysis + read-only on-device only.** No build, flash, dd, reboot, or EDL — stage
  edits and describe them (see memory `feedback-user-does-build-flash`).
- **Do not reopen falsified lanes:** AP-side QRTR/qmi instance-encoding, extended-HELLO,
  announce-timing, HELLO-handshake, EFS-content, TZ/hyp_assign, SMSM handshake — all flashed and
  dead (radio4/5/6, `PLAN-tz.md`). Their *evidence* is useful; their *hypotheses* are closed.
- The 20 MB segment 10 disassembles to a very large text file — window with
  `--start-address/--stop-address` once you have anchors; only do the full `all.dis` once for the
  xref grep, and cache it.
- llvm-objdump-15 emits a harmless "end of file unexpectedly encountered" at a segment tail —
  ignore it.
- Hexagon is a VLIW/packet ISA: instructions group in `{ … }` packets that issue together, and
  `.new` refers to a value produced in the *same* packet. Read per-packet, not per-line.

## Appendix — `scripts/mpss-reasm.py` (if not already committed)

Reassembles a program-header-only Hexagon ELF from `modem.mdt` + `modem.bNN` by placing each
segment at its `p_offset`. Usage: `mpss-reasm.py <image_dir> <out.elf>`.
```python
import struct, os, sys
d, out = sys.argv[1], sys.argv[2]
mdt = open(os.path.join(d, 'modem.mdt'), 'rb').read()
e_phoff = struct.unpack_from('<I', mdt, 0x1c)[0]
e_phnum = struct.unpack_from('<H', mdt, 0x2c)[0]
e_phentsize = struct.unpack_from('<H', mdt, 0x2a)[0]
phdrs, maxend = [], 0
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    t, poff, pva, ppa, pfsz, pmsz, pfl, pal = struct.unpack_from('<IIIIIIII', mdt, o)
    phdrs.append((i, poff, pfsz, pva, pfl)); maxend = max(maxend, poff + pfsz)
buf = bytearray(maxend)
buf[0:e_phoff + e_phnum * e_phentsize] = mdt[0:e_phoff + e_phnum * e_phentsize]
for i, off, fsz, va, fl in phdrs:
    if not fsz: continue
    bn = os.path.join(d, 'modem.b%02d' % i)
    if os.path.exists(bn): buf[off:off + fsz] = open(bn, 'rb').read()[:fsz]
open(out, 'wb').write(buf)
```

---

## RESULT — 2026-07-06 (session `radio7`): the string-anchor method is FALSIFIED; the modem uses QSR hashed diag messages

**Bottom line: Step 1's anchor (xref the fault-file pointer `0x88152d31`) cannot work on
this modem image.** The AML0 MPSS uses Qualcomm's **QSR (hashed) diag-message system**, so the
human-readable strings that appear in the SSR crash reason are *reconstructed by QXDM/diag
tooling from an external `.msg` database* — the running image does **not** load them as code
pointers. Proven this session with the full pipeline running correctly (ELF reassembled, all
R-X segments disassembled with `llvm-objdump-15`):

1. **The fatal's format string is not in the image at all.** `grep` of the reassembled ELF for
   `rmts_get_buffer`, `api failed`, `EFS:` finds only `fs_rmts_*` file-name substrings and
   unrelated `EFS: file name` / `EFS: DalTimetick_Attach fail` — **no** `"rmts_get_buffer api
   failed"` literal anywhere.
2. **The file-string pointer `0x88152d31` is referenced NOWHERE.** Zero immediate loads
   (`r = ##…`) across seg6/9/10, and **zero** raw 4-byte occurrences of the pointer value
   anywhere in the 60 MB ELF (checked aligned + unaligned). Same for the neighbouring cluster:
   **zero** immediates land in `[0x88152d00, 0x88153000)`.
3. **This is selective, not a disassembly failure.** In the same code, **24,131 distinct
   immediates DO point into the RO-string range** `[0x88140000, 0x88568000)` — ordinary (non-diag)
   string/table literals are code-referenced normally (e.g. the table at `0x881da060` is loaded
   as `r = ##-2011324320` in dozens of places). Only the **diag file/format strings** are
   orphaned → confirms QSR replaced their code refs with hashes.
4. **The one diag file-string that IS pointed-to** (`fs_rmts_bootup_action.c` @ `0x88152d98`,
   found at seg17 `0x89f1b70c`) sits inside a **high-entropy blob** (seg17, flags `R`, va
   `0x89eb2000`) — i.e. the QSR string database itself, not code. Not a code anchor.

**Corrections to the plan for the record:** (a) Step 1's signed value is wrong — signed
`0x88152d31` = **`-2011878095`**, not `-2011357391` (moot given the above). (b) `strings modem.bin`
"rmts_get_buffer / rfsa_client" hits the plan mentions are QSR-db / substring noise, not code.

### What the numeric anchors showed (partial, for the next session)
- **`0x890C0000`** (the fatal's 3rd field, `-1996169536`) is **not in any file-backed segment** —
  it's a runtime `.bss`/heap region address (RW segs 14/15 have `filesz=0`, msz spans it). It
  appears as a *runtime pointer* in (i) a cdma1x static-region setup (seg9 `0x86b6b0ec`, id `0xDD`,
  amid `/nv/item_files/modem/1x/*` names) and (ii) a diag/logging helper (seg10 `0x87602cd0`, amid
  `0xF814xxxx` QSR msg pointers). Neither is `rmts_get_buffer`; treat `0x890C0000` as "a modem
  heap control-struct pointer", i.e. the *value* the failed call left in the reason record, not a
  hardcoded buffer base.
- **`RFSA_pool`** survives as a real string (`0x8856a250`, seg13 RW) and is a **modem-internal DSM
  pool descriptor** (name + size `0x00020000`=128 KB at `+0x20`), GP-referenced (no stored 4-byte
  pointer to it). It's the modem's local RFSA buffer pool, not the decision logic.

### Corrected method for the NEXT session (string-anchor is out; use these instead)
The decision site must be found by **structure**, not by diag strings:
1. **QMI-object anchor (best).** The RFSA `GET_BUFF_ADDR` send goes through the QMI client stack.
   Find the RFSA/sharedmem **`qmi_idl_service_object`** (a global struct carrying the service id;
   RFSA ≈ QMI svc `0x1C`/28) and/or the `qmi_client_send_msg_sync` call sites, then walk to the
   caller that guards whether the send happens. That guard's input is the answer — and it's
   diag-independent.
2. **GP-relative resolution.** Build the Hexagon **GP base** and resolve `memw(gp+#off)` loads;
   the msg macro and pool/service names are reached GP-relative, so many "missing" refs live here.
   Add a `--triple=hexagon` pass that also decodes `gp` (llvm-objdump won't compute GP for a
   phdr-only ELF; derive GP from the `.start`/init or from the seg13 base).
3. **QSR msg-const table.** Locate the section of msg-const structs (u16 line numbers); find the
   entry with **line 161** whose file-hash matches `fs_device_efs_rmts.c`, then xref *that struct's
   address* — the ERR_FATAL call passes a pointer to the struct, which (unlike the file string)
   *is* a normal code immediate.

**Net:** the top lead is not dead, but the planned shortcut is. Locating `rmts_get_buffer` here
is a QMI-structure RE effort, not a string grep — scope it as multi-session. Everything upstream
(ELF reconstruction, segment map, toolchain, scripts) is validated and reusable.

### radio7 continued — QSR is SELECTIVE; live EFS-module foothold established
Kyle chose "pursue QMI-object anchor." Key breakthrough: **QSR stripping is per-message, not
total.** Testing a batch of domain strings against the set of all 262,873 code immediates:
`"EFS_sync success"` (`0x88205b4e`), `HWREVNUM_PHYS_ADDR`, `MEM_MAPPING_VIRT_RANDOM` **ARE**
code-referenced; the `fs_device_efs_rmts.c` / txlm / assertion strings are not. So the anchor
strategy works — just not on the fault file string. `"EFS_sync success"` gave a **live entry into
the EFS module** (seg10, ~`0x875e0000–0x875f0000`). Mapped so far:
- **EFS-sync/finalize fn @ `0x875ef4c0`** (refs `EFS_sync success` @ `0x875ef620`). Logs status
  via helper `0x875ef3e0(char* @r0)` — the EFS diag-print wrapper; its string args
  (`0x88205xxx`, i.e. `##-20111454xx`) label each EFS step and are the best local anchors.
- **EFS module state flag = `gp+#19228`** — single writer @ `0x875e9324` (`memw(gp+#19228)=r0`,
  r0=1 when an init predicate on the EFS ctx passes), two readers @ `0x875ef530` and `0x875ef6ec`
  that branch the sync path on it. This is the module's "EFS ready/mode" latch — a prime suspect
  for the RFSA-vs-not decision. Its setter reads an **EFS context struct via r23** (fields
  `+144/+160/+564/+578`) and calls `0x875eb470`, `0x875ec020`, `0x875eb730`.
- Other GP globals in the fn: `gp+#9744`, `gp+#9740` (status scratch). Allocator/dispatch helper
  `0x8756af68` (size>8 path; the `combine(#4,#114)` arg is a *size*, NOT SMEM item 114 — that
  coincidence is dead).
- Numeric leads run down and **excluded**: `0x180000` @ seg9 `0x86c0a484` is a log-ring sizer
  (768KB/1.5MB select, `modwrap` code), not the rmts buffer; `0x890C0000` is a runtime .bss heap
  pointer (cdma1x region-setup + diag helper), not a hardcoded EFS base.

**Did NOT yet reach `rmts_get_buffer` / the RFSA send** — it's deeper in this module's call graph.
**Resume here next session:** (1) walk the EFS ctx-struct (r23) setter that feeds `gp+#19228`
back to its allocation site to name the fields; (2) enumerate all callees of the `0x875ef4c0`
family and the `0x875e9280` init and look for the `qmi_client_init`/`qmi_client_send_msg_sync`
pair (RFSA svc `0x1C`) — the guard immediately before it is the target predicate; (3) use the
surviving `0x88205xxx` EFS step-strings (all `##-20111454xx`) as local anchors to name each fn.
Cached in scratch `.../scratchpad/mpss/`: `modem.elf`, `seg{2,5,6,9,10,20}.dis`, `strings.vaddr`.

> **Correction (see next section): the `0x875ef4c0` / `gp+#19228` "foothold" above is the
> Xiaomi/JRD `tct_update_fsg` NV-golden-copy updater (`jrdcom/nv_update_list.txt`), NOT the
> `fs_device_efs_rmts` / RFSA path. The QShrink-DB unlock below supersedes it.**

---

## RESULT — 2026-07-06 (`radio7` continued): QShrink DB UNLOCKED → `rmts_get_buffer` is a QMI buffer fetch with TWO paths

**This is the breakthrough. The modem ships its own message database.** Inside the modem FAT
partition: **`image/qdsp6m.qdb`** (5.1 MB) — a **QShrink 4.0 Hash Database**. Header `\x7fQDB` +
16-byte GUID; the payload is **zlib** (`78 da`) starting at **file offset `0x40`**. Decompresses
to 23 MB of text, one line per diag message:
```
<hash>:<ss_mask>:<ssid>:<line>:<file>:<format-string>
```
This is why the string-anchor failed — the strings live *here*, stripped from the image. Regenerate:
```bash
7z x -y modem.bin 'image/qdsp6m.qdb'
python3 -c "import zlib;d=open('image/qdsp6m.qdb','rb').read();open('qdb.dec','wb').write(zlib.decompress(d[0x40:]))"
grep -aE ':rmts_api\.c:' qdb.dec        # the whole rmts source, by line number
```
(The `<hash>` column is a build-time sequential id, NOT embedded in the image as an integer —
confirmed 0 raw/immediate hits for 239623 etc. So it doesn't directly give code addresses; its
value is the **recovered source structure**.)

### What the DB reveals — the fatal decoded and the real architecture
The SSR fatal is `fs_device_efs_rmts.c:161` but **the buffer logic is in `rmts_api.c`** (ssid 94).
`rmts_get_buffer` (L1036–1120, "rmts_get_buffer failed %d" @ L1120 is the inner failure the
`fs_device_efs_rmts.c:161` assert wraps) obtains the shared buffer via **QMI**, and there are
**two implementations**:

- **`Get_buffer`** (L704–828) = the classic **RFSA** path (this is what stock uses; RFSA
  debugfs `Request count:1`):
  `L704 Get_buffer : qmi_client_init client = %d` → `L706 …qmi_client_init rc = %d status = %d`
  → `L719 Requesting Shared buffer of size %d` → `L730 …send_msg_sync rc = %d status = %d`
  → `L775 xpu-lock success` → `L828 Shared Memory Physical to virtual mapping successful`.
- **`Smem_get_buffer`** (L624–668) = a newer path via a service the modem calls **"SMEM Kernel
  Service"**: `L624 init client rc/status` → `L628 SMEM Kernel Service not found` / `L632 found`
  → `L647 send_msg` → `L668 SMEM Kernel Service Get_buffer succeeded`.

**Decisive reframe:** the RFSA-skip is **NOT** a mysterious SMEM/NV/GUID input (as radio4–6
hypothesised) — it is a **QMI client init / service-lookup** that yields no buffer. And the SAME
`qmi_client_init` **works** in the same file for the RMTFS partition-open (L536 `Open parti
qmi_client_init`, L567 `send_msg_sync`, svc 14 — the 4 EFS opens we see every boot) but the
RFSA/"SMEM Kernel Service" buffer fetch produces **zero wire traffic** (radio5: modem received
our RFSA `NEW_SERVER` but never sent `GET_BUFF_ADDR`). So the failure is specific to the
buffer-service client, consistent with a QCCI service-table **match/instance** issue or the modem
taking `Smem_get_buffer` first and not falling back. (`GET_BUFF_ADDR` req/resp msg id = `0x0023`;
RFSA svc `0x1C` inst 1, our kernel `sharedmem_qmi.c` — verified correct. memshare = svc `0x34`,
registered in both 3.18 and our 4.19, `CONFIG_MEM_SHARE_QMI_SERVICE=y`.)

### Concrete next steps (well-scoped now)
1. **Map `Get_buffer` (L704) + `Smem_get_buffer` (L624) to code addresses.** The QShrink `msgcfg`
   metadata appears to live in the RO **seg18** (`0x89f41000`+); exact struct layout still needs
   decoding (the `[line_u16|ss_id]` guess gave only scattered hits). Alternative: anchor on the
   RMTFS path that *works* — find the two `qmi_client_init` call sites in one function region and
   the RFSA one is the sibling with the failing predicate.
2. **Determine which path runs and the `qmi_client_init` rc.** If capturable, the modem's F3 for
   these exact lines (L628 "not found", L706 "rc=%d") names the failure — but diag is dead
   pre-fatal (`diag-rides-qrtr.md`), so this likely stays static.
3. **On-device (read-only) test of the QCCI-match hypothesis:** re-run the radio5 kprobe but also
   watch for any modem DATA to memshare port (svc `0x34`) and to the RFSA port after our
   `NEW_SERVER` — confirm the modem's client never matches svc `0x1C` in its QCCI table.

**Net:** the top lead is alive and far better understood — the buffer fetch is a QMI client
problem, not a boot-env/SMEM problem. `qdsp6m.qdb` is now a permanent asset: it gives the full
source-line map for *every* modem subsystem, making all future MPSS RE dramatically cheaper.

### radio7 (3): line→address mapping is BLOCKED with current tooling — pivot needed
Attempted to map `Get_buffer`(L704)/`Smem_get_buffer`(L624) to code addresses. Blocked, root
cause characterised precisely:
- **QShrink 4.0 fully strips the F3 `msg_const` structs from the loadable image.** The qdb
  `<hash>` (e.g. 239623) is a build-time sequential id, **not embedded** in the image in any
  form: 0 raw-word hits, 0 immediate hits, tested against all 337k code immediates under every
  simple encoding (raw / `|ssid<<16/24` / `|mask<<24` / `<<8|mask`); the file-string pointers
  (`rmts_api.c`=`0x88152e00`, etc.) have **0** references in data; and there is **no
  dangling-pointer cluster** into an unloaded section. The message identifier is simply not
  recoverable from the static image.
- **The ERR_FATAL text is stripped too.** `"rmts_get_buffer api failed"` / `"EFS: rmts_get_buffer"`
  exist **nowhere** — not in `modem.bin`, any `modem.bNN`, the reassembled ELF, or the qdb. Only
  the *file* string `fs_device_efs_rmts.c` survives (in `modem.b12`/seg12), and it too is
  unreferenced. So even the assert can't be anchored.
- **No auto-analysis tooling present.** No Ghidra (its Hexagon processor module since 10.3 is the
  natural unlock), no radare2/rizin, no capstone-hexagon. Only linear `llvm-objdump-15` — which
  can't recover function boundaries/call-graph across a 20 MB stripped VLIW image by hand at any
  reasonable cost.

**Two unblock paths (need a decision / resources — this is the end of what pure static
llvm-objdump can deliver):**
1. **Ghidra + qdb oracle (static, exact).** Load `modem.elf` (our reassembly works) into Ghidra
   w/ the Hexagon module → auto-analysis gives the call graph. Then name `Get_buffer` by the
   constants it must use — RFSA svc `0x1C`, msg `0x0023`, buffer size, and the sibling RMTFS
   (`0x0E`) `qmi_client_init` that *works* — and read the `qmi_client_init(RFSA)` predicate/rc.
   The qdb gives file:line for every F3 call to cross-check.
2. **Modem ramdump + qdb (dynamic, direct).** Enable modem ramdump collection on A16
   (`subsystem_restart` enable_ramdumps), capture the coredump at the `rmts_get_buffer` fatal,
   parse its F3 message ring against `qdb.dec`. The exact log lines — `L628 "SMEM Kernel Service
   not found"` vs `L706 "Get_buffer : qmi_client_init rc = %d status = %d"` — name the failing
   path and its rc **without any disassembly**. Highest leverage; fits the two-device method.

Until one of those is available, the actionable output is the **reframe**: stop hunting a
boot-env/SMEM input; the modem's `rmts_get_buffer` fails inside a QMI client init/lookup for the
shared-buffer service, in the same file where the RMTFS(14) client succeeds every boot.

---

## PLAN — radio7 chosen path: modem ramdump + QDB (2026-07-06)

Kyle chose the **modem ramdump** unblock. The insight that makes this decisive: the full modem
ramdump is an **ELF32 of the entire modem DDR** and contains the **modem's saved crash register
context**. The Q6 **PC/LR at the `rmts_get_buffer` ERR_FATAL points into `rmts_api.c` code** —
that is the exact address QShrink stripping denied us. With that single anchor, our working
`llvm-objdump-15` disassembly reads the real `qmi_client_init` predicate/rc backwards from the
fault site. The F3 message ring and rmts client state are also in the dump as corroboration.

### Capture procedure (Kyle runs on A16 `c39a6acf`, root; A16 is Permissive)
Verified against our 4.19 kernel: device = `/dev/ramdump_modem` (full DDR,
`create_ramdump_device("modem")`, `pil-q6v5-mss.c:280`); read yields ELF32
(`ramdump.c` `do_elf_ramdump`); `ramdump_read` **blocks** on `dump_wait_q` until a crash arms it,
so start the reader first. SSR trigger `echo restart > /sys/kernel/debug/msm_subsys/modem` is the
same one used in radio5/6.
```bash
# 0. sanity
ls -l /dev/ramdump_modem /sys/module/subsystem_restart/parameters/enable_ramdumps
# 1. enable FULL ramdumps (not just minidump)
echo 1 > /sys/module/subsystem_restart/parameters/enable_ramdumps
echo 0 > /sys/module/subsystem_restart/parameters/enable_mini_ramdumps    # optional, avoids the md_modem path
# 2. start the reader FIRST — it blocks until the modem crashes and arms the dump
dd if=/dev/ramdump_modem of=/data/local/tmp/modem_dump.elf bs=1M &
sleep 1
# 3. trigger a fresh modem crash → it re-runs rmts_get_buffer → ERR_FATAL → dump armed → dd drains
echo restart > /sys/kernel/debug/msm_subsys/modem
# 4. let it stream, then confirm it grew and finished
wait; ls -l /data/local/tmp/modem_dump.elf; file /data/local/tmp/modem_dump.elf
# 5. pull it off device (adb pull /data/local/tmp/modem_dump.elf) and hand the path to me
```
If `dd` returns instantly with a tiny file: the crash didn't arm the dump (ramdumps not enabled in
time, or restart_level rebooted instead of SSR'd). Retry with the reader already blocked before the
`echo restart`. If `/dev/ramdump_modem` is missing, `enable_ramdumps` alone may gate its creation —
check `dmesg | grep -i ramdump` after enabling.

### What I'll extract from the dump (my side, static — no device)
1. **Find the Q6 crash register context** (scan for a saved-register block whose PC lies in the
   `0x86ce3000–0x88040000` text range) → the ERR_FATAL site in `rmts_api.c`.
2. **Disassemble backwards** from that PC with `llvm-objdump-15` → the `qmi_client_init` /
   `send_msg_sync` call and the branch/rc that fails; compare to the working RMTFS(0x0E) sibling.
3. **Decode the F3 ring** against `qdb.dec` to confirm which path ran (`L628 "SMEM Kernel Service
   not found"` vs `L706 "Get_buffer : qmi_client_init rc = %d status = %d"`) and the literal rc.
4. **Read rmts client state** (the buffer addr `0x890C0000`, size `0x180000`, error code `6`) from
   the data segments to cross-check.
Deliverable: the exact predicate + input, then a staged AP-side fix (per the working agreement).

---

## radio11 (2026-07-07): Ghidra stood up — analysis excellent, QSR4 metadata wall confirmed

**Toolchain unlocked.** Ghidra 12.1.2 ships a **native Hexagon processor** (`Hexagon:LE:32:default`,
v2.4) — no extension needed (a third-party `QDSP6:LE:32:default` "Hexagon_U" is also installed;
we pin the built-in). Full auto-analysis of the reconstructed `modem.elf` (48 min, MAXMEM 8G)
produced **97,474 functions / 5,274,746 instructions** with a clean decompiler (strings, call
targets, and many absolute data refs resolved). This is the call-graph + pseudocode leap over
`llvm-objdump` the plan wanted.

### Reusable setup (all in session scratch `…/scratchpad/ghidra/`)
- `modem.elf` — regenerate reproducibly from the backup FAT image:
  `7z x pepito-stock-backup-20260706/modem.img image/` → `reasm.py image modem.elf`
  (62,787,584 bytes, byte-size-identical to radio7's reconstruction).
- Project: `…/scratchpad/ghidra/proj/mpss`. Import once:
  `analyzeHeadless <proj> mpss -import modem.elf -processor Hexagon:LE:32:default -noanalysis`
  then analyze: `analyzeHeadless <proj> mpss -process modem.elf -analysisTimeoutPerFile 7200`.
- **Ghidra 12 dropped Jython** — scripts MUST be **Java GhidraScripts** (`.java`, run via
  `-postScript foo.java`), NOT `.py` (that needs PyGhidra, which isn't provisioned). Working
  scripts kept in `…/scratchpad/ghidra/scripts/` (`efs_probe`, `efs_search`, `msgid_scan`,
  `decomp_at`). Query pattern: `-process modem.elf -noanalysis -postScript <s>.java` (re-opens the
  saved, analyzed program; ~30s startup; single-writer lock — don't open the GUI concurrently).

### Confirmed foothold (radio7 map validated on this exact ELF)
- `EFS_sync success` @ `0x88205b4e` → `FUN_875ef48c` (the `tct_update_fsg` EFS-sync finalize;
  writes `/jrdcom/ver.txt`). Decompiles cleanly. 14 callees, all in the fs/EFS module @ `0x875exxxx`.
  As radio7 said, `rmts_get_buffer` is NOT this fn — it's a separate module not yet located.

### The QSR4 wall — now fully characterized (every message-metadata anchor is DEAD)
Tried, all zero/coincidental:
1. **rmts strings** (`fs_device_efs_rmts.c` @ `0x88152d31`, `rmts_api.c` @ `0x88152e00`, `RFSA_pool`
   @ `0x8856a250`): present in RO data but **zero code xrefs** (Ghidra ReferenceManager) — QSR
   replaced the refs with hashes, exactly as radio7 found. (`RFSA_pool` is GP-relative, see below.)
2. **qdb msgids as data** (e.g. 239624=L628 "SMEM Kernel Service not found", 240656=L719
   "Requesting Shared buffer"): **not present** as 4-byte LE anywhere. The qdb field0 is a synthetic
   DB id, not stored in the image.
3. **qdb msgids as code immediates**: scanned all 5.27M instructions for scalar operands ==
   any rmts buffer-path msgid → **zero**. The QSR4 runtime token is computed/indirect, not a literal.
4. **`{u16 line; u16 ss_id=0x5E}` struct scan** (ssid 94 confirmed for all rmts_api.c): only
   coincidental byte matches inside code, no real msg-const table located → the QSR struct layout
   is not the classic `msg_const_type`.
5. **`0x180000` scalar hits (40)**: mostly `and R,##0x180000` bit-field masks (bits 19-20); the
   value-carrying ones are red herrings — `FUN_86c09d50` (log-ring sizer, radio7-known),
   `FUN_875efcb0` (**FSG file-table search** over the 1.5 MB `fsg` partition — size coincidence
   with the transfer buffer, NOT it).

### The real remaining unlock: **GP resolution**
The decompiler shows `unaff_GP + <off>` for the GP-relative loads — and the `RFSA_pool` ref and
likely the `Smem_get_buffer`/`Get_buffer` service-object pointers live there. GP is **loader-set**
(QuRT sets it before user code; **no `gp = ##imm` exists in the image** — scanned all instructions;
entry `0x86800000` uses `r25` as a data base, not GP). So GP must be **derived**, then set as a
program-wide register value so the decompiler propagates it and the GP-relative xrefs resolve —
which should land `RFSA_pool` → `Get_buffer` (RFSA), with `Smem_get_buffer` immediately adjacent.

**Next session — GP derivation options (ranked):**
1. Find a global accessed BOTH as `r = add(gp,#off)` (or `memw(gp+#off)`) AND as an absolute
   `r = ##addr`; then `GP = addr - off`. (Hexagon GP-relative range is ±256 KB word-scaled, so GP
   is within ~256 KB below the sdata it addresses — likely near seg13 base `0x8856a000`, since
   `RFSA_pool` @ `0x8856a250` is GP-referenced ⇒ GP ≈ `0x8856a000` ± a page. Test that first.)
2. Set candidate GP over the whole image (`ProgramContext.setRegisterValue`), re-decompile
   `FUN_875ef48c`, and confirm its `gp+0x2610/0x4b1c/0x260c` refs land on sensible seg13 data;
   binary-search GP until they do.
3. With GP set, `getReferencesTo(0x8856a250)` (RFSA_pool) → the `Get_buffer` function; walk its
   siblings/callers to `rmts_get_buffer` and read the `Smem_get_buffer` `qmi_client_init` service
   argument = the actionable answer ("what 'SMEM Kernel Service' is").

**Independent corroboration this session** (`postmarketos-redmi4x/FINDINGS.md`): three AP stacks
(stock 3.18, LOS 4.19, mainline 6.x/7.x) boot Xiaomi 8937 modems via ALLOC_BUFF with **no** SMEM
buffer item, **no** RFSA, **no** memshare anywhere — so the buffer method is purely a modem
build/NV property and the `Smem_get_buffer` predicate is **modem-local** (NV/EFS/private-partition
or internal state), not part of the family's AP contract. This validates targeted disasm as the
only path and confirms the AP-side lanes are exhausted. It also confirms the SMSM apps word is
consumed only for BAM-DMUX data flow (bits 1/11), post-boot — NOT the boot gate (validates the
radio11 `smsm.c` legacy-handshake revert as behavior-neutral).

### radio11 continued — GP DERIVED AND CONFIRMED: **GP = 0x8856a000**
Empirically confirmed by scanning all GP-relative operands: with GP=0x8856a000, **100% of 95,836
GP-relative accesses land inside seg13** (initialized RW data, 0x8856a000..0x887bf224; target
range 0x8856a000..0x88581570). A wrong GP would scatter targets outside seg13. GP is NOT written
in code (QuRT loader sets it); this is the ABI small-data base = seg13 start.

**GP is now SET program-wide in the saved Ghidra program** (ProgramContext.setValue over all 23
blocks, in `gp_set_save.java`). Confirmed effect: `FUN_875ef48c` now decompiles with resolved
globals — `unaff_GP + 0x2610/0x4b1c/0x260c` → concrete `iRam8856c610 / iRam8856eb1c / uRam8856c60c`
(all seg13). Every function now decompiles with GP globals resolved.

**Caveat on grep-anchoring seg13:** the `RFSA_pool` string @ 0x8856a250 is referenced neither as
a GP-relative operand (scan found none forming 0x8856a250), an absolute immediate, nor a stored
data pointer — because the RFSA code loads GP into a scratch register first (`r=GP; memw(r+#0x250)`),
invisible to a raw operand scan but resolvable by the decompiler's constant propagation. **So
seg13 xrefs must be MATERIALIZED by re-running analysis with GP set** (the Hexagon Constant
Reference Analyzer creates them). That GP-aware re-analysis is running now.

**Next (once GP-aware re-analysis completes):** `getReferencesTo(0x8856a250)` → RFSA `Get_buffer`
fn; also find the QMI service-object globals in seg13 for RFSA (svc 0x1C) and the memshare/DHMS
candidate (svc 0x34) → their qmi_client_init call sites are `Get_buffer` and `Smem_get_buffer`.
Read the service arg in `Smem_get_buffer` to CONFIRM/REFUTE the radio13 "SMEM Kernel Service ==
memshare 0x34" hypothesis and the QCCI-table-match predicate that diverts pepito from the RFSA
fallback.

### radio11 continued — GP-aware xrefs materialized; memshare module located; navigation state
- **GP-aware re-analysis DONE and SAVED.** References to seg13 globals now materialized (probe:
  the hot flag @ GP+0x274 has 7,409 refs). The saved program is fully navigable.
- **Reliable query pattern locked in.** Java GhidraScripts in `…/scratchpad/ghidra/scripts/`
  (`decomp_at <hexaddr[,addr…]>`, `imm_scan`, `rfsa_xref`, `rfsa_users`, `gp_derive <gpbase>`).
  **OSGi GOTCHA (cost a detour):** Ghidra compiles the ENTIRE scriptPath dir as one bundle — a
  single broken `.java` makes ALL scripts fail with "could not get OSGi bundle". Keep the dir
  clean; validate scripts with `<jdk-21>/bin/javac -cp <all Ghidra jars>` before running (system
  javac is 17 → wrong class version 61 vs 65; MUST use `~/Projects/jdk-21.0.11+10/bin/javac`).
- **Anchor dead-ends confirmed:** `RFSA_pool` @ 0x8856a250 and `memshare_qmiclient` @ 0x8815ff58
  have ZERO materialized xrefs (referenced via GP-into-scratch-reg or split immext); use the
  scalar/immediate `imm_scan` (finds `immext #val` operands) instead of ReferenceManager for
  seg12/seg13 string targets.
- **Memshare/DHMS module LOCATED (supports radio13's svc-0x34 = "SMEM Kernel Service"):**
  `memshare_qmiclient` (0x8815ff58) and `heap_mem_ptr/size` (0x881667xx) are loaded in
  **`FUN_87ffec00`** — a heap-block allocator init (`mem_init`, kMinBlockSize) called by
  `87fff104 / 88000464 / 87fff10c`. This is the memshare client's heap layer (module @
  ~0x87ffxx–0x88000xx), one level below the DHMS QMI client init. The generic heap init is NOT
  the QMI send path.

**Next (resume here):** in the 0x87ffxx–0x88000xx memshare module, find the DHMS QMI **client
init** (encodes svc 0x34) and the **alloc-request send**; then xref that send's callers — a caller
in rmts_api.c IS `Smem_get_buffer` (confirms 0x34 == "SMEM Kernel Service"). Separately, still need
to positively locate `rmts_get_buffer`/`Smem_get_buffer` (rmts_api.c); best untried anchors: (a)
the modem's RMTFS client init "Open parti" (svc 14) — same .o as Smem_get_buffer; (b) walk callers
of the memshare alloc send back into rmts. Then read the qmi_client_init service arg + the
match/rc predicate that diverts pepito from the RFSA fallback = the deliverable.

### radio11 — ★ rmts_get_buffer FOUND AND DECOMPILED (the fatal function) ★
Anchor chain that worked: EFS partition paths `/boot/modem_fs{1,2,g,c}`,`rfnvbak` survive QSR @
`0x882065e8`+ → pointer table @ **`0x882065d0`** → loaded by `FUN_87603290` (partition-open, L536)
→ that pins the whole `rmts_api.c` module @ **`0x876028xx–0x87604xxx`**. (Reliable technique for
QSR images: anchor on surviving *data* strings — partition paths / pool names — not F3 messages.)

**`FUN_87602d40` = `rmts_get_buffer`** (the function that fatals). Structure:
- Control struct @ **`DAT_8864d340`** (lock) with selector **`DAT_8864d350`**, region
  base/size/off `DAT_8864d358/d360/d364`, fixed-addr `d368`. **ALL ZERO-INITIALIZED in the image**
  and (per full immediate+xref scans) **never written** → `DAT_8864d350` is always **0**.
- `if (DAT_8864d350==1)` → bump-allocate from static region `[d358,+d360]`; if too small → error 8,
  **NO fallback** → return fail. This is the qdb "Smem_get_buffer/SMEM Kernel Service" branch — and
  it is **DEAD CODE on this build** (selector never set to 1).
- `else` (the path actually taken) → **RFSA GET_BUFF_ADDR**, gated by `param_1[0x2d]!=0`:
  retry×10 { `FUN_87603290` → `thunk_FUN_87e2d1d0(1,1,5)` = qmi_client_init →
  **`FUN_87560db0(client,1,0,0,…,1,&DAT_8864d33c)` = qmi get-service/connect** → if rc==0:
  **`FUN_87560824(DAT_8864d33c, 0x23, {1,size}, 8, resp, 0x18, 0)` = qmi_client_send_msg_sync,
  msg 0x23 = GET_BUFF_ADDR** }. rc -3/-2 → retry; success → xpu-lock `thunk_FUN_87ffbae0`
  (L775) + phys-to-virt map `thunk_FUN_88008b20` (L828) at `LAB_876030d4`.
- If `param_1[0x2d]==0` → `iVar5=3`, no buffer acquired.

**★ Root cause REFRAMED (static-proven):** the modem does NOT die in a "Smem-first" branch — that
branch is dead. It takes the **RFSA path and fails BEFORE the GET_BUFF_ADDR send** (which is why
AP RFSA `Request count` stays 0 / zero wire traffic — radio10). The failure is one of:
  (a) `FUN_87560db0` (qmi get-service/**connect to RFSA svc 0x1C**) returns non-zero every retry →
      10 retries exhausted → fatal. Untested QMI variable per radio13 = the **version/instance**
      the client requests vs what the AP announces. **← prime suspect (matches "connect fails
      pre-send").**
  (b) `param_1[0x2d]==0` for the rmts client → RFSA path skipped entirely (iVar5=3).
Next: decompile `FUN_87560db0` + `thunk_FUN_87e2d1d0` (87e2d1d0) to read the exact QMI
service/instance/version requested for RFSA, and inspect where `param_1[0x2d]` is set. That names
the precise (ver,inst) or client-flag mismatch to fix on pepito. Corroborates [[postmarketos-findings]]
(modem-local) and radio13 (QCCI service-table match), now pinned to the connect call.

### radio11 — the RFSA connect fully traced; registration tuple is ALREADY correct
Decompiled the QMI connect chain from `rmts_get_buffer`'s RFSA path:
- `thunk_FUN_87e2d1d0(1,1,5)` returns **`&DAT_8874fec8` = the RFSA qmi_idl_service_object**.
  Read from image: **service_id = 0x1C @ +0x08**, version fields (5,1), 7 req/7 resp msgs. Confirms
  the modem asks for RFSA svc 0x1C.
- `FUN_87560db0(obj, instance=1, …, timeout=1, &handle)` = **qmi_client_init_instance**: looks the
  service up; if absent, waits and returns **-3 (timeout)** → the retry×10 → fatal we see.
- `FUN_87560bd0(obj, 1, out)` = **qmi_client_get_service_list**: gets the registered instances of
  svc 0x1C and iterates comparing each entry's **instance byte == 1**. No instance-1 entry ⇒
  "not found".
- On success only: `FUN_87560824(handle, 0x23, {op=1,size}, …)` = send GET_BUFF_ADDR.

**So the modem requires: RFSA svc 0x1C, instance 1.** Our kernel `sharedmem_qmi.c` does
`qmi_add_server(h, RFSA_SERVICE_ID_V01=0x1C, RFSA_SERVICE_VERS_V01=1, RFSA_SERVICE_INSTANCE_NUM=1)`
— **service 0x1C, version 1, instance 1 — an EXACT match.** ⇒ The fix is NOT the registration
numbers (rules out the radio13 "untested version field" hypothesis: version 1 is what's registered
and the modem's match is on instance, not version).

**Two remaining candidates (need runtime/one more decompile to split):**
1. **`param_1[0x2d]` gate** — the RFSA retry loop is entered only `if (param_1[0x2d]!=0)`; else
   `iVar5=3`, NO QMI at all. This matches radio5's "modem sends ZERO NEW_LOOKUP + ZERO
   GET_BUFF_ADDR" better than a failed lookup would (a lookup would put a NEW_LOOKUP on the wire).
   `param_1` = the rmts client context; need to find where byte 0x2d is set at client-open. Same
   modem binary works on stock ⇒ if this is the gate, [0x2d] is set from a runtime input that
   differs pepito vs stock.
2. **get_service_list instance-encoding mismatch** — kernel wire NEW_SERVER encodes
   instance=(ver|inst<<8)=0x101; the modem must decode inst=0x101>>8=1 to match. If the modem's
   QMI lib (FUN_8755fb40) reads the instance field differently over QRTR, the byte compare != 1.
Next: (a) decompile `FUN_8755fb40` (get_service_list) to see the exact instance field it compares;
(b) trace where `param_1[0x2d]` is written (rmts client-open). On-device cross-check: capture the
NEW_SERVER instance the modem receives for svc 0x1C on pepito vs stock-A11 (radio5 tooling).

### radio13 (2026-07-07): candidate (b) ELIMINATED; matcher decoded to a runtime source-registry
Re-decompiled the chain end-to-end (Ghidra project survived intact — 916M, fully analyzed).

- **Candidate (b) `param_1[0x2d]` — DEAD.** Byte 0x2d is not a mysterious runtime flag: in
  `FUN_87603290` (rmts prep) `if (param_1[0x2d]==1)` is precisely what drives the loop over
  `PTR_s__boot_modem_fs1_882065d0` opening the 6 EFS partitions (modem_fs1/fs2/fsg/fsc/rfnvbak);
  else it opens a single partition (`param_1+7`). It also gates the RFSA path in `rmts_get_buffer`.
  Since pepito's modem *demonstrably opens all 6 EFS partitions over RMTFS svc 14* (radio8: 140
  OPENs of exactly those paths), **byte 0x2d is 1** ⇒ the RFSA path is entered. The retry-loop
  qmi_client_init being local-cache-only (no wire traffic on miss) is what reconciles "RFSA path
  entered" with radio10's "zero wire traffic." So candidate (b) is out; **candidate (a) stands
  alone: `qmi_client_init_instance` for RFSA svc 0x1C fails its local service-cache lookup.**
  (`param_1` is created by `FUN_87602c3c("EFS", &ctx)` in caller `FUN_875f1ebc`; byte 0x2d is set
  inside that create from the "EFS" client profile — no need to chase it further, it's provably 1.)

- **The matcher, decoded (candidate (a) mechanism):**
  `FUN_87560db0` (qmi_client_init_instance) → `FUN_87560bd0` (get_service_list). `FUN_87560bd0`
  with a specific instance (1, not 0xffff) calls `FUN_8755fb40` twice (count, then fill), gets an
  array of **20-byte (0x14) entries**, and loops comparing **`*(char*)(entry+2) == requested
  instance`** (=1). On match it copies `entry` (from `entry-2`, 0x14 bytes) out. So the modem's
  find-RFSA reduces to: *does the service list contain an entry for svc 0x1C whose byte[+2]==1?*
  `FUN_8755fb40` builds that list by taking lock `DAT_88e5ca00` and iterating a **runtime
  source-registry** `DAT_88e5ca1c` (count `DAT_88e5ca10`), invoking each source's
  **`(*(code**)(src[-1]+0xc))(...)`** enumerate-callback that appends its services. So the list is
  the union over registered QMI-CCI transport sources (QRTR, etc.).

- **Static wall reached (honest).** `DAT_88e5ca1c` is populated at runtime by whatever transport
  backends register; no static data-xref writes it (`FUN_8755e73c`, the only fn touching the lock
  besides readers, is just one-time lock init). To read the QRTR source's enumerate-callback +
  cache-insert (how it packs wire inst 0x101 into entry byte[+2], and why RMTFS(14) lands but
  RFSA(0x1C) doesn't) I must find the QRTR-source *register* call via its vtable/strings, not data
  xref. That's the precise next hop. Beyond it, the modem's per-source cache is fed by received
  QRTR NEW_SERVER — runtime state, and the live modem is a zombie w/ zeroed ramdump (known wall).

**Conclusion:** the working-vs-broken difference is now pinned to the modem's **QRTR QMI-CCI
service-source cache population** — identical wire input as stock (which uses IPC-router), svc 14
works over the same QRTR, only svc 0x1C is missing from the modem's get_service_list. Not an AP
announcement-tuple bug (radio13 A/B proved the tuple is stock-identical), not `param_1[0x2d]`
(proved 1). Decompile targets recorded above; on-device qrtr-ns cross-node-relay check in
`PLAN-radio.md` "NEXT STEP" #2.

### radio13 (2026-07-07, sub-agent) — CCI xport enumerate/insert FULLY TRACED: no bug, entry never RETAINED
Static agent traced the whole IPC-router/QRTR CCI service-cache path in `modem.elf`. Key addresses:
- **CCI xport `ops` vtable = `0x887523e8`** (statically-init fn ptrs; source `qmi_cci_xport_ipc.c`,
  strings VA 0x88424c1c). `ops+0x00`=`FUN_87e8dcb8` reg/open (installs async NEW_SERVER notify
  `FUN_87e8de50`); `ops+0x08`=`FUN_87e8dd58` unreg; **`ops+0x0c`=`FUN_87e8dd60` = the enumerate
  callback** `FUN_8755fb40` invokes; `ops+0x10`=`FUN_87e8de4c` addr_len→8 (the `<0x10` check
  confirms vtable identity). (Runtime registry `DAT_88e5ca1c` is BSS/zero-in-file, no static
  writer — identify the xport by its ops vtable, not by data-xref.)
- **Enumerate packing (`FUN_87e8dd60`):** calls router find-servers `FUN_8755a2c0(0,&svc,ver,mask=0xff,…)`,
  then per record builds a 20-byte entry: `entry[+0]=xport-id`, **`entry[+1]=instance&0xff` (version),
  `entry[+2]=(instance>>8)&0xff` (the MATCHER byte)**, `entry[+3]=0`, `entry[+4..0x14]=16B addr`.
  Stride 0x14 out / 0x10 in. RFSA 0x101→byte[+2]=1 (matches `FUN_87560bd0`'s `==1`); RMTFS 0x001→0.
  Packing PROVABLY correct + service-agnostic — a structural invariant of this shipping binary.
- **Server table = 32-bucket hash `DAT_88e5c760`** (bucket=`service&0x1f`, lock `DAT_88e5c740`).
  **Insert = `FUN_8755af70`** (← `FUN_8755a010` ← `FUN_87559fdc` ← notify op `FUN_87e8d1ec`): stores
  `{service,instance,addr,port}` VERBATIM, **no service-id filter/range check**. Lookup type-4 =
  `FUN_8755b800`: `node[0]==service` + version mask `0xff & (qver^nver)==0`. DEL_SERVER=`FUN_8755abd0`.
- **Verdict:** `FUN_87e8dd60` emits entries only if find-servers returned ≥1 for the queried svc.
  RFSA returns 0 because **bucket 0x1C of `DAT_88e5c760` has no `node[0]==0x1C` at query time** — the
  0x1C NEW_SERVER was never retained/accepted, NOT filtered. Runtime table-population gap, upstream.
- **Reconciles with the on-device track** (qrtr_0 ipc_logging): AP delivers NEW_SERVER(0x1c) to the
  modem in the same <1ms burst as (0xe), ~100ms pre-fatal; modem takes ZERO NEW_LOOKUP yet retains
  0xe (so it DOES accept unsolicited NEW_SERVER) but never talks to the 0x1c port. ⇒ divergence is a
  **data-dependent accept/drop in the NEW_SERVER receive→insert path** (`FUN_87559fdc`/`FUN_8755acf0`,
  QSR4-obscured) keyed on something specific to the 0x1c announcement (instance high-byte 0x101 vs
  0x001, or addr/port/dedup). radio5's "announce at inst 0x1 also failed" is confounded (breaks the
  matcher). **Decisive datum = read `DAT_88e5c760` bucket 0x1C on a live modem (stock vs pepito) —
  blocked by the ramdump-zeros/diag-masked wall.** Next static hop = decode `FUN_8755acf0`.
