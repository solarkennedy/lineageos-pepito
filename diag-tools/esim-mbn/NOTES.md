# eSIM lane — MCFG/MBN write-path re-open (static, 2026-10-16)

The eSIM lane closed on "no write primitive into the modem's EFS": diag EFS2 `/nv`
writes are ACL-denied in the UIM tree, the modem code image is signed, and
modemst1/2 are TZ-encrypted. **The MCFG/PDC apply path is a *different* EFS write
path that was never tested** — MCFG items are written to EFS from *inside* the
modem by the config processor, not over the diag channel the ACL guards. This
directory holds the static work-up and a tool to test it.

## What is proven statically

1. **The modem reads the target items from EFS** (gated, not unconditional —
   the stronger of the old ~55/60 coin-flip). The modem binary embeds both EFS
   path strings as compiled-in rodata:
   - `/nv/item_files/modem/qmi/uim/apdu_security_restrictions`  (vaddr 0x883dbe9e)
   - `/nv/item_files/modem/qmi/uim/apdu_security_aid_list`      (vaddr 0x883dbf07)
   plus three nearby `security_restrictions` strings (log/validate). A path
   string is only compiled in to efs_get/efs_put that item. (Caveat: the code
   that references these lives in the q6zip-paged region — can't cheaply read
   whether the read truly gates the ISD-R decision vs. only logs. Same q6zip
   wall as before; not re-attacked.)

2. **MCFG can provision UIM-tree EFS items.** Stock `mcfg_sw` configs already
   carry `/nv/item_files/modem/uim/{mmgsdi,gstk,gba}/*` EFS-file items, so the
   MCFG apply path writes into the uim namespace. Our target is the sibling
   `/modem/qmi/uim/` namespace — same mechanism, different subtree.

3. **mcfg_sw.mbn format fully reversed** (format_type=3):
   - ELF32-hexagon wrapper, 3 program headers.
     - ph0 off 0 : ELF header + phdr-table mirror  -> hashtab slot0
     - ph1 off 0x1000 : hash-table seg = hdr(40) + sha256 per phdr + RSA sig +
       13-cert X.509 chain   (slot1 = the hash-seg's own slot, zeroed)
     - ph2 off 0x3000 : MCFG payload = 'MCFG' hdr(16) + item list -> hashtab slot2
   - EFS-file item record (value-first):
     `u16 marker=2 | u16 vallen | value[vallen] | u32 reclen(whole) |
      u32 attr=0x1902 | u16 flags=1 | u16 pathlen | path[pathlen]\0`
   - NV-by-id items up front use a more compact framing (not needed here).

4. **The configs ARE signed, so a modified MBN cannot be re-signed by us**
   (same fused-root wall as the modem image). The hashes, however, are fully
   repairable. So the lane hinges on one unknown that is cheap to test on-device.

## ⛔ RESULT 2026-10-16 — route CLOSED: mcfg_sw signature IS enforced

Tested end-to-end on dut1 (c39a6acf) via `pdc-mbn-loader load`. The modem
authenticates the config at LOAD-commit and rejects any modified blob:

- modified config (even a pristine payload with only the 3-byte mcfg version
  bumped, hashes repaired, RSA sig stale) → terminal LOAD indication
  **`ind_error=34` = `QMI_ERR_AUTHENTICATION_FAILED_V01`**, config not registered.
- control: byte-identical **unmodified** stock config → `ind_error=0`, registers fine.

So `fake_sec_enabled` is NOT in effect on this fuse config — mcfg_sw is signed
AND enforced, same wall as the modem code image. We cannot re-sign against the
fused root, and ANY edit invalidates the RSA signature over the hash table.
**The MCFG/PDC write path is closed.** (It was the right lane to try: it does
bypass the diag `FS_DIAG_VALIDATE_PATH_ACCESS` ACL — a valid config commits and
applies from inside the modem — but auth stops us from making a valid modified one.)

Only surviving MCFG sub-idea (long shot): find a *legitimately signed* stock/vendor
config that already carries `apdu_security_restrictions=0` or an `apdu_security_aid_list`
permitting ISD-R, and load that unchanged. None of pepito's four stock configs do.

Loader bugs fixed along the way (the `load` write path had never been exercised):
32 KB single chunk → `QMI_CLIENT_TRANSPORT_ERR`; `id_len=0` → `INVALID_ID`; and the
tool never waited for the terminal LOAD indication that carries the real verdict.
Fixes in `~/android/lineage-23/diag-tools/pdc-mbn-loader/` (+ `build-nosysroot.sh`,
since the 23-tree `out/` is gone): 4 KB chunks, explicit/optional config id, and a
post-upload drain that decodes `pdc_load_config_ind_msg_v01.ind_error`.

## (superseded) The open question — settled above

Does this modem **enforce** the SW-config signature at PDC load? The modem has
`mcfg_auth_img_verify()` / `mcfg_auth_verify_hash()` *and* a `fake_sec_enabled`
token (Qualcomm's permissive SW-config path, why community carrier MBNs load on
most MSM8937 parts). Whether it's enforced here is in paged code — test it:

### Two-step load probe (reversible; reload the stock set after)
Use `pdc-mbn-loader` (see diag-tools/pdc-mbn-loader, qmux preload per
[[qmux-bridge-lane]]). Target the config the inserted test SIM selects.

1. **Hash-only probe** — `mbn_tool.py flip stock.mbn probe.mbn --off 0x5000`
   flips one payload byte and recomputes slot0/slot2 (RSA sig now stale).
   - Loads/activates -> the modem does NOT verify the RSA sig for SW configs
     (fake-sec) -> injection route is OPEN. Go to step 2's inject.
   - Rejected -> SW-config auth enforced -> route is dead (reader stays the answer).

2. **Inject** — `mbn_tool.py inject stock.mbn out.mbn
   --path /nv/item_files/modem/qmi/uim/apdu_security_restrictions --value 00`
   adds the item (value `00` = restrictions off), bumps num_items, fixes ph2
   size + hashes. Load it, then read the item back over diag EFS2
   (`efs2-probe stat/cat` — reads are allowed) to confirm the modem wrote it,
   then re-probe ISD-R OPEN_LOGICAL_CHANNEL. If ISD-R now opens -> on-device
   eSIM switching without the reader. (Also try `apdu_security_aid_list`.)

Recovery: reload the stock config set; dut1 further recoverable via banked stock
EFS dump. NEVER airplane-cycle around UIM changes ([[sim-uicc-toggle-trap]]).

## Tools here
- `mbn_tool.py verify|flip|inject` — parse/patch/rehash an mcfg_sw.mbn.
- `efs_scan.py` — dump EFS-file items (path+shape) from an mcfg_sw.mbn.
Stock `.mbn` and `modem.elf` are gitignored (public repo; not ours to publish).
Stock configs: build tree / `android-pepito-backups/<serial>/.../modem_config/`.
