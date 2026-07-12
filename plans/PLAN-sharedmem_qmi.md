# LineageOS 23.2 — In-kernel `sharedmem_qmi` (RFSA) Service Port — pepito/PVG100

**Status (2026-06-29): PORT COMPLETE + VERIFIED — but the modem never queried it.**

> **⚠️ 2026-07-04 CORRECTION (session `radio4`): the 06-29 "hypothesis falsified" conclusion
> was WRONG — the mechanism is CONFIRMED and this port is necessary.** Stock ground truth:
> the 3.18 sharedmem_qmi debugfs on `android11-adb` shows **`Request count: 1`** — the stock
> modem DOES fetch its EFS buffer address via RFSA svc 28 (address shown = stock uio0
> `0xF7100000`). `request_count: 0` on A16 means the modem never *queries our instance*,
> not that it doesn't use RFSA. Kprobe-verified: our NEW_SERVER(28) announcement (identical
> registration tuple to stock, inst 0x101) is delivered to the modem every boot — in good
> cycles 1.2–1.7 ms BEFORE its first EFS OPEN — yet the modem sends no GET_BUFF_ADDR and no
> NEW_LOOKUP. Working theory: the legacy router syncs the server table synchronously inside
> the HELLO handshake (µs); QRTR's userspace `qrtr-ns` is ≥1.9 ms late; the modem's rmts
> lookup is a one-shot in that gap (and/or a modem-side persisted "no RFSA" decision).
> **Fix staged: `net/qrtr/qrtr.c` local-server replay at HELLO.** Full evidence + session
> log: `PLAN-radio.md` "2026-07-04" section. The 06-29 text below is kept for history; its
> *conclusion* is superseded (its measurements remain valid).

The 06-29 result, for the record: the port
works correctly (RFSA service 0x1C is on the QRTR bus, debugfs shows correct buffer data, no
panic), but the modem never queries the RFSA service (`request_count: 0` across multiple
modem boot cycles) and the `rmts_get_buffer` ERR_FATAL persists identically.

This was

## Legend
- ✅ Working / proven on-device  - 🔧 Present, not yet verified  - ❌ Missing / blocker
- 📋 Verified on-disk / mapped, not yet ported

---

## Goal

Give the modem an in-kernel QMI service it can query to learn the **physical address +
size of the rmtfs shared buffer** that `msm_sharedmem.c` (the UIO half) already
allocates. Without it the modem falls back to a bad address (`0x890C0000` vs the real
`0xf7300000`) → `rmts_get_buffer` fails → `ERR_FATAL` every boot → zombie-ONLINE modem
that never advertises QMI_LOC or completes EFS. With it, the modem should boot clean
(`crash_count=0`), `/persist/rfs/*` populates, and the GPS/radio/IMS work that's
currently blocked behind a dead modem can proceed.

The service is **RFSA** = Remote File System Access, QMI service ID **`0x1C` (28)**,
version 1, instance 1 (`RFSA_SERVICE_ID_V01` in the stock header). Single message pair:
`GET_BUFF_ADDR_REQ` (0x0023) → `GET_BUFF_ADDR_RESP` (0x0023).

## Root cause recap (detail in `PLAN-radio.md`)

- Modem fatals every boot: `fs_device_efs_rmts.c:161 … EFS: rmts_get_buffer api
  fa[iled]`. Args decoded: `0x180000` = 1.5 MB (the rmtfs region size), `0x890C0000` =
  a wrong address *inside the modem region*.
- The right address (`0xf7300000`, AP-allocated, 1.5 MB) is never communicated to the
  modem because the kernel service that does so is **absent**.
- Ground truth from the two-device method: `android11-adb` (stock, working modem) runs
  an in-kernel **`[sharedmem_qmi_w]`** kthread; our `android16-adb` does not.
- The on-disk snapshot op (`"uio: Add snapshot of MSM sharedmem driver"`) grabbed only
  `msm_sharedmem.c` (the UIO half) — `sharedmem_qmi.c` was never included.
- Bus evidence (`PLAN-qrtr.md`, 2026-06-26 capture): 42 services registered, RFSA is
  **not among them** (only `RMTFS`(14) from `rmt_storage` userspace is).
- `hyp_assign_phys` failing (`-95`) is treated **non-fatal by the driver** ("Device
  created for client 'rmtfs'") and is currently judged a red herring — see **Caveats**.

## Source files 📋

All confirmed present at
`~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/drivers/uio/msm_sharedmem/`:

| File | Lines | Role | Port effort |
|---|---|---|---|
| `sharedmem_qmi.c` | 453 | QMI service + client list + debugfs | **~180L of real logic** (QMI + list); ~250L is debugfs boilerplate that copies near-verbatim |
| `sharedmem_qmi.h` | 34 | `struct sharemem_qmi_entry` + 3 prototypes | trivial |
| `remote_filesystem_access_v01.h` | 39 | RFSA service/msg IDs, req/resp structs | trivial |
| `remote_filesystem_access_v01.c` | 80 | `qmi_elem_info` enc/dec tables | port with field rename (see diff) |

## Template correction (important)

`PLAN-radio.md` (2026-06-26) recommends modeling the port on
`drivers/remoteproc/qcom_sysmon.c`. **Pre-flight found that's the wrong template.**
Sysmon is a **QMI client** — `qmi_add_lookup(&sysmon->qmi, 43, …)` looks *up* the
modem's SSCTL service. RFSA must be a **server** — the AP *hosts* svc 0x1C and the modem
queries it. Sysmon has no `qmi_add_server`, no `qmi_msg_handler[]` request dispatch, no
`qmi_send_response`. It cannot host.

**Use `drivers/soc/qcom/memshare/msm_memshare.c` instead.** It is RFSA's literal
sibling (serves buffer allocations to the modem over QMI) and is **already compiling &
running on this device** — `CONFIG_MEM_SHARE_QMI_SERVICE=y` in `mi8937_defconfig`; the
radio plan's own dmesg shows memshare clients (GPS/FTM/DIAG). It has the exact server
shape: `qmi_handle_init` + `qmi_add_server` + `struct qmi_msg_handler[]` dispatch +
`qmi_send_response`. Keep sysmon only as a secondary reference for the
`qmi_handle_init` argument style and the init-via-workqueue pattern.

## Legacy → 4.19 API delta

| Legacy (`msm-3.18`) | 4.19 port (memshare shape) |
|---|---|
| `qmi_send_resp_from_cb(handle, conn_h, req_handle, &msg_desc, &resp, sizeof)` | `qmi_send_response(handle, sq, txn, MSG_ID, sizeof(struct resp), resp_ei, &resp)` |
| `connect_cb` / `disconnect_cb` / `req_desc_cb` + per-msg-id `switch` | **Deleted.** A `struct qmi_msg_handler[]` does dispatch; framework auto-decodes via each entry's `.ei` + `.decoded_size` |
| `struct msg_desc rfsa_…_desc` (max-len lives here) | **Deleted.** max-len goes to `qmi_handle_init()`'s 2nd arg (`max_msg_len`) |
| `qmi_svc_register(...)` (absent in 4.19) | `qmi_handle_init()` then `qmi_add_server(handle, RFSA_SERVICE_ID_V01=0x1C, vers=1, ins=1)` |
| `struct elem_info`, field `.is_array` | `struct qmi_elem_info`, field **`.array_type`** (rename) |
| `.ei_array = get_qmi_response_type_v01_ei()` | `.ei_array = qmi_response_type_v01_ei` (global array in `<linux/soc/qcom/qmi.h>`, not a fn call) |
| `DECLARE_DELAYED_WORK` recv re-arm loop | **Deleted.** framework calls handlers directly |

`enum qmi_elem_type` constants (`QMI_UNSIGNED_4_BYTE`, `QMI_UNSIGNED_8_BYTE`,
`QMI_OPT_FLAG`, `QMI_STRUCT`, `QMI_EOTI`) and `NO_ARRAY` are **identical** between
legacy and 4.19 — the `_v01` ei tables port with only the field rename. Latent bug to
fix in the port: the legacy `_v01.c` EOTI terminators declare `.is_array` twice (second
one wins); write `.array_type = NO_ARRAY` once.

`qmi_elem_info` struct shape (4.19, `include/linux/soc/qcom/qmi.h:71`):
```c
struct qmi_elem_info {
	enum qmi_elem_type data_type;
	u32 elem_len;
	u32 elem_size;
	enum qmi_array_type array_type;   /* was: is_array */
	u8 tlv_type;
	u32 offset;
	struct qmi_elem_info *ei_array;
};
```

## The load-bearing wire (do not forget)

`msm_sharedmem_probe()` already computes the exact values the modem needs —
`shared_mem_pyhsical` (e.g. `0xf7300000`) + `shared_mem_size` (`0x180000` = 1.5 MB) for
`client_id == MPSS_RMTS_CLIENT_ID` (`drivers/uio/msm_sharedmem/msm_sharedmem.c:19,77`).
**The probe currently never hands these to the QMI service.** The port must, after
`uio_register_device()` succeeds and the address/size are known, call:

```c
struct sharemem_qmi_entry entry = {
	.client_name     = clnt_res->name,
	.client_id       = client_id,           /* MPSS_RMTS_CLIENT_ID = 1 */
	.address         = shared_mem_pyhsical, /* 0xf7300000 */
	.size            = shared_mem_size,     /* 0x180000 */
	.is_addr_dynamic = is_addr_dynamic,
};
sharedmem_qmi_add_entry(&entry);
```

Without this call the service registers but answers every get-buffer with an empty list →
the modem still fatals. This is the single most likely thing to be missed.

## Wiring surface (all verified present)

- **Kconfig symbol**: `drivers/uio/Kconfig:168` (`config UIO_MSM_SHAREDMEM`). Already
  `=y` in `mi8937_defconfig:3927`. **Reuse it — no new symbol needed.** (This is why the
  subdir had no `Kconfig`; the symbol lives one level up.)
- **Makefile**: `drivers/uio/msm_sharedmem/Makefile` is one line
  (`obj-$(CONFIG_UIO_MSM_SHAREDMEM) := msm_sharedmem.o`). Change `:=` to a list adding
  `sharedmem_qmi.o remote_filesystem_access_v01.o`.
- **Parent plumbing**: `drivers/uio/Makefile:14`
  (`obj-$(CONFIG_UIO_MSM_SHAREDMEM) += msm_sharedmem/`) — already correct, no edit.
- **No new headers/includes** beyond `<linux/soc/qcom/qmi.h>` (already in-tree; same one
  memshare uses). No `select`/`depends on` churn — `qmi_handle_init` etc. are built via
  the existing `CONFIG_QMI_HELPERS` (transitively pulled by memshare's `MEM_SHARE`).

## Staged work

- [x] **1. Stage the RFSA enc/dec.** DONE
      `remote_filesystem_access_v01.{c,h}` from
      `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/drivers/uio/msm_sharedmem/` into
      `kernel/xiaomi/msm8937/drivers/uio/msm_sharedmem/`. Adjust: rename the struct
      field `.is_array` → `.array_type` in both ei tables; fix the doubled `.is_array`
      on the EOTI terminators (write `.array_type = NO_ARRAY` once); change
      `get_qmi_response_type_v01_ei()` → `qmi_response_type_v01_ei`. Swap the legacy
      `#include <linux/qmi_encdec.h>` + `<soc/qcom/msm_qmi_interface.h>` for
      `<linux/soc/qcom/qmi.h>`. Keep the struct + ID `#define`s as-is.
- [x] **2. Port `sharedmem_qmi.c` to the new API**, modeled on
      `drivers/soc/qcom/memshare/msm_memshare.c` (server). Keep:
      - the `struct shared_addr_entry` / `shared_addr_list` list + `rwsem` (cheap,
        proven)
      - `sharedmem_qmi_add_entry()` + `get_buffer_for_client()` (the lookup logic —
        unchanged)
      - the debugfs block (`debugfs_init`, `fill_debug_info`, the `rfsa`/`rmts` counters)
        near-verbatim
      Rewrite:
      - delete `connect_cb`/`disconnect_cb`/`req_desc_cb` and the `msg_desc` statics
      - replace the legacy `qmi_handle` callbacks with a `static struct qmi_ops` (a
        `.del_client` only, like memshare's `server_ops`)
      - build a `static struct qmi_msg_handler rfsa_handlers[]` with one entry:
        `{ .type = QMI_REQUEST, .msg_id = QMI_RFSA_GET_BUFF_ADDR_REQ_MSG_V01,
        .ei = rfsa_get_buff_addr_req_msg_v01_ei,
        .decoded_size = sizeof(struct rfsa_get_buff_addr_req_msg_v01),
        .fn = sharedmem_qmi_get_buffer }`
      - rewrite `sharedmem_qmi_get_buffer()` to the
        `(... struct qmi_txn *txn, const void *decoded_msg)` signature and reply with
        `qmi_send_response(handle, sq, txn, QMI_RFSA_GET_BUFF_ADDR_RESP_MSG_V01,
        sizeof(resp), rfsa_get_buff_addr_resp_msg_v01_ei, &resp)` — keep the
        address-lookup body identical
      - `sharedmem_qmi_init()` via a workqueue (memshare pattern): alloc handle,
        `qmi_handle_init(handle, RFSA_GET_BUFF_ADDR_RESP_MSG_MAX_LEN_V01, &server_ops,
        rfsa_handlers)`, then `qmi_add_server(handle, RFSA_SERVICE_ID_V01,
        RFSA_SERVICE_VERS_V01, RFSA_SERVICE_INSTANCE_NUM)`
- [x] **3. Wire the data.** In `msm_sharedmem.c::msm_sharedmem_probe()`, after
      `uio_register_device()` succeeds and the address/size are known, build a
      `struct sharemem_qmi_entry` (the values the probe already computed — see "The
      load-bearing wire") and call `sharedmem_qmi_add_entry(&entry)`. Trigger
      `sharedmem_qmi_init()` (once; guard with a static `done` flag — probe can fire
      per client node, but the service is singleton). `#include "sharedmem_qmi.h"`.
- [x] **4. Build wiring.** Edit `drivers/uio/msm_sharedmem/Makefile`:
      `obj-$(CONFIG_UIO_MSM_SHAREDMEM) := msm_sharedmem.o sharedmem_qmi.o
      remote_filesystem_access_v01.o`. No Kconfig edit (symbol already `=y` in
      `mi8937_defconfig`).
- [ ] **5. Build (remote Stellaris16 via `scripts/build-lineage23-remotely.sh`) +
      flash + reboot.** *(pending — build run by user)* Watch for: (a) build clean — no `qmi_*` unresolved symbols; (b)
      on boot, a new kthread present (memshare-style worker name, not the stock
      `[sharedmem_qmi_w]` unless we name it so — either is fine as a success signal).

## Verification result (2026-06-29): HYPOTHESIS FALSIFIED

The port was built, flashed, and verified on `android16-adb`. All implementation checks
**PASSED**; the hypothesis that this fixes the modem fatal **FAILED**.

### What PASSED (the port is correct)

1. **No boot panic.** The `list_add corruption` bug (found in first flash, `prev is NULL`
   because `add_entry` ran before `INIT_LIST_HEAD`) was fixed by switching to
   `LIST_HEAD(sharedmem_addr_list)` (statically initialized). Boot completes cleanly.
2. **Service registered.** dmesg: `RFSA sharedmem_qmi service registered` at boot. The
   service survives qrtr-ns's late start (qrtr-ns binding to the control port triggers
   `qrtr_reset_ports()` → `ENETRESET` → the framework's `qmi_handle_net_reset()` re-announces).
3. **Service on the QRTR bus.** `qrtr-services` enumerator shows **svc 28 (0x1C, RFSA) on
   AP node 1, port 16459, instance 0x00000101**. It was absent in the 2026-06-26 pre-fix
   capture (42 services). Now 55 services.
4. **Buffer data correct.** debugfs `/sys/kernel/debug/rmt_storage/info` shows:
   `Client_name: rmtfs, Client_id: 0x00000001, Buffer Size: 0x00180000 (1572864),
   Address: 0x00000000F7300000, Dynamic`. Exactly the values the probe computed.

### What FAILED (the hypothesis was wrong)

5. **Modem never queries RFSA.** `request_count: 0` across **multiple** modem boot cycles
   (SSR-triggered powerups). The handler was never invoked (no pr_err in dmesg). Yet the
   modem queries RMTFS (svc 14, also on AP node 1) immediately after powerup — proving it
   CAN discover and reach AP-side QMI services over QRTR. It simply **doesn't query RFSA**.
6. **Modem fatal persists identically.** Same `fs_device_efs_rmts.c:161:[6, 1572864,
   -1996169536] EFS: rmts_get_buffer api fa[iled]`, same `crash_count` climbing (7 → 19
   during testing), same zombie-ONLINE. The referenced address `0x890C0000` is **unchanged**
   from pre-fix — if the modem had queried RFSA and received our answer, it would reference
   `0xf7300000`.

### Why the hypothesis was wrong

The plan (2026-06-26) inferred from A11 having `[sharedmem_qmi_w]` that the modem queries
the RFSA QMI service for the buffer address. **This was an inference, never verified.** The
pepito modem firmware (2018-era AML0) does **not** query RFSA over QMI. The `[sharedmem_qmi_w]`
kthread exists on stock 3.18 but the modem either uses a different buffer-address mechanism
(SMEM item, static DTS, or a non-QMI SCM/SMEM handshake) or doesn't need dynamic address
discovery at all. The service is present on A11 as dead code / for other platforms.

### Independent pre-port corroboration (strace, 2026-06-27)
Before the port, a strace of `qrtr-ns` (pid 1036, `recvfrom` on its `AF_QIPCRTR` socket)
across an on-demand modem SSR showed the modem **never emits a lookup for svc 0x1C**. The only
`QRTR_TYPE_NEW_LOOKUP` (cmd `0x0a`) packets `qrtr-ns` received were from **AP node 1** (qcrild,
for svcs 0/1/2) — **none from the modem (node 5), none for svc 28.** This is consistent with
QRTR semantics (remote nodes learn AP services via `NEW_SERVER` *broadcasts*, not by sending
their own lookups), so it was not by itself proof — but it predicted the post-port
`request_count: 0`. Two independent methods now agree: **the modem does not use RFSA.**

### Why `sharedmem_qmi` was missing / how siblings differ (provenance, answers the "why")
Our kernel is **`github.com/LineageOS/android_kernel_xiaomi_msm8937`** (git remote confirmed) —
the *exact same* kernel every mithorium sibling (santoni/land/…) builds from. `sharedmem_qmi.c`
was **never in its history**: the only relevant commit is the 2015 CodeAurora snapshot
`bc69c707244b "uio: Add snapshot of MSM sharedmem driver"`, which imported **only**
`msm_sharedmem.c` (the UIO half). So siblings run the identical AP kernel with no `sharedmem_qmi`
and their modems are fine — confirming the service isn't on the critical path for *any* modem
here (Palm or Xiaomi).

**Two-device consequence — RESOLVED (2026-07-02, `PLAN-tz.md`):** the clean disambiguation
("does stock 3.18 on A11 actually succeed at `hyp_assign`?") was run via the `msm_sharedmem`
sysfs unbind/rebind experiment: **stock FAILS the same `MEM_PROT_ASSIGN` SMC64 call
identically** (`scm_call failed: func id 0x42000c16, ret: -1` → `err=-5`), warns, continues —
and stock's modem works with no XPU grant. So `hyp_assign` is confirmed benign on this SoC
for every kernel, and neither "Palm TZ vs Xiaomi TZ" nor "4.19 arg-packing" matters — the
call's outcome is irrelevant to the modem.

### What this means for the modem fatal (updated 2026-07-02)

The `rmts_get_buffer` failure is **not** RFSA (this plan's falsified hypothesis) and **not**
`hyp_assign_phys` (falsified 2026-07-02 — stock fails the same SCM call identically and its
modem works without the grant; see `PLAN-tz.md`). The modem's only observed buffer-related
QMI activity is against **RMTFS svc 14** — userspace `rmt_storage` — and `rmts_get_buffer`
is the modem's client end of that ALLOC_BUFF exchange. That exchange is the live suspect;
see `PLAN-radio.md` "2026-07-02: modem-fatal status" for the course of action (strace the
exchange on both devices and diff). The `0x890C0000` in the fatal args is inside the modem's
own region and may be an error cookie rather than an address the modem "used" — don't
over-read it.

### Decision: keep or revert the sharedmem_qmi port?

**Keep.** The code is correct, harmless (the service registers and idles), and may be needed
later for other clients or when the modem firmware is updated. It does not cause any
regressions. The port is a valid in-tree addition regardless of whether it fixes the modem
fatal. The build wiring (Kconfig `select QCOM_QMI_HELPERS`, Makefile, defconfig) is all
correct.

## Caveats

- **`hyp_assign` — RESOLVED (2026-07-02): possibility (A) is the truth.** Stock 3.18 does
  NOT succeed at the call — it fails identically (`0x42000c16`, TZ `ret: -1`) and the
  modem works anyway, so the buffer is modem-accessible without any XPU grant and
  `hyp_assign` is a harmless no-op on this SoC. Proven by sysfs unbind/rebind of
  `msm_sharedmem` on A11; full writeup in `PLAN-tz.md`. (Do **not** re-add the
  SMC32-first hack — both conventions are rejected; SMC32 never fixed keymaster either.)
- **Single client today.** The legacy service supports a list of clients; our only
  registered entry is `MPSS_RMTS_CLIENT_ID`. That's all the modem EFS path needs. If
  other clients (GPS nav, DIAG) later want RFSA buffers, the same `add_entry` hook
  extends trivially — but don't pre-wire them.

## Ground-truth references on bench

- `android11-adb` (`81eed371`) — stock 3.18, has `[sharedmem_qmi_w]`, working modem.
- `android16-adb` (`c39a6acf`) — our 4.19 bringup, the target.
- Stock source on disk:
  `~/Projects/Pepito_GPL_SourceCode/kernel/msm-3.18/drivers/uio/msm_sharedmem/`.
- Working 4.19 server template (in-tree):
  `kernel/xiaomi/msm8937/drivers/soc/qcom/memshare/msm_memshare.c` (esp.
  `qmi_memshare_handlers[]` at `:689`, `memshare_init_worker` at `:735`).
- Bus enumerator (in-tree):
  `device/xiaomi/mithorium-common/qrtr-tools/qrtr-services.c` + capture
  `qrtr-services-boot-2026-06-26.txt` (the "before" state — 42 svcs, no RFSA, no LOC).

## Related plans

- `PLAN-radio.md` — full modem-fatal root-cause chain; this is the implementation
  sequel to its 2026-06-26 RFSA section.
- `PLAN-qrtr.md` — the bus enumerator (verification instrument for step 1 above).
- `PLAN-gps.md` — downstream; QMI_LOC appearance is gated on this fix succeeding.
- `PLAN.md` "Cluster A" — frames why this unblocks more than just radio.
