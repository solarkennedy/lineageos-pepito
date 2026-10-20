#!/usr/bin/env python3
"""Generate mcfg_sw.mbn fail-open probe variants for the eSIM MCFG lane.

Question being tested (2026-10-17): the boot/recovery "graft" trick boots pepito
GREEN not by presenting a valid TCL signature but by exploiting a FAIL-OPEN parser
branch in aboot's Verified Boot 1.0 -- it inflates the signature-block length field
so the verifier exits (reading only the header) BEFORE parsing/verifying cert or sig.
Does the MODEM's mcfg_sw authenticator (`mcfg_auth_img_verify`) have an analogous
fail-open branch we can trip via a malformed signature/cert size field?

The 10-16 test already established the modem is FAIL-CLOSED for a well-formed-but-stale
signature (modified payload, hashes fixed, RSA sig stale -> ind_error=34). This probe
set asks the sharper question: does MALFORMING the hash-table header's size/pointer
fields (the aboot analog) make the verifier skip the check and accept non-stock content?

Each probe (except the v0 stock control) BUMPS the 4-byte mcfg version (payload+0x14 and
its trailer copies) so the content is genuinely non-stock AND the modem treats it as a new
config -- a same-version/different-content edit stops at ind_error=90 INCOMPATIBLE_STATE
(the version/anti-rollback gate) BEFORE the authenticator, which is why the first probe set
(last-byte flip, version unchanged) was a false negative. After the version bump it fixes
slot0/slot2 so the hash table is internally consistent, leaves the RSA sig STALE, then
malforms one header field. v1 (version bump, well-formed header) is the auth control and
must reach ind_error=34. Decision rule on load:
  * ind_error=0  (registers) -> the malformation caused FAIL-OPEN and a non-stock config
                                was accepted -> route OPEN; proceed to Tier B (real inject).
  * ind_error=34 (AUTHENTICATION_FAILED) -> fail-closed on that field.
  * any other error -> parser rejected the malformation differently (note the code).

Hash-table header (ph1, 40-byte Qualcomm MBN-40), offsets relative to ph1 file start:
  +0x10 image_size  +0x14 code_size  +0x18 sig_ptr  +0x1c sig_size
  +0x20 cert_ptr    +0x24 cert_size

Usage:
  python3 -I make_failopen_probes.py <stock_mcfg_sw.mbn> <out_dir>
Produces out_dir/<name>.mbn for each probe plus a MANIFEST.txt.
The stock .mbn is gitignored (not ours to publish); pass the one the inserted test SIM
selects -- match whatever config the 10-16 control used.
"""
import sys, os, struct, hashlib

HDR = 40; HL = 32

def phdrs(b):
    e_phoff = struct.unpack_from('<I', b, 0x1c)[0]
    e_phnum = struct.unpack_from('<H', b, 0x2c)[0]
    ent     = struct.unpack_from('<H', b, 0x2a)[0]
    out = []
    for i in range(e_phnum):
        o = e_phoff + i * ent
        pt, off, va, pa, fsz, msz, fl, al = struct.unpack_from('<IIIIIIII', b, o)
        out.append(dict(idx=i, o=o, off=off, fsz=fsz, msz=msz))
    return out

def fix_hashes(ba):
    ph = phdrs(ba)
    hoff = ph[1]['off']
    s0 = hashlib.sha256(bytes(ba[ph[0]['off']:ph[0]['off'] + ph[0]['fsz']])).digest()
    s2 = hashlib.sha256(bytes(ba[ph[2]['off']:ph[2]['off'] + ph[2]['fsz']])).digest()
    ba[hoff + HDR + 0 * HL: hoff + HDR + 0 * HL + HL] = s0
    ba[hoff + HDR + 2 * HL: hoff + HDR + 2 * HL + HL] = s2

def bump_mcfg_version(ba):
    """Bump the 4-byte mcfg version (payload+0x14, LE, plus its trailer copies) by 1.

    This is the change that makes the config genuinely non-stock *and* gets past
    the modem's version/anti-rollback compatibility gate (a same-version, different-
    content config terminals at ind_error=90 INCOMPATIBLE_STATE before auth). Bumping
    the version makes the modem treat it as a new config and proceed to the signature
    check -- which, with the RSA sig left stale, then fails as ind_error=34. Mirrors
    the 10-16 methodology (0x07010214 -> 0x07010216) that reached 34. We replace every
    copy of the current version value inside ph2 so the internal config id stays
    consistent (payload+0x14 and two trailer copies)."""
    ph = phdrs(ba)
    p_off, p_end = ph[2]['off'], ph[2]['off'] + ph[2]['fsz']
    cur = bytes(ba[p_off + 0x14: p_off + 0x18])
    new = struct.pack('<I', (struct.unpack('<I', cur)[0] + 1) & 0xFFFFFFFF)
    n = 0; i = p_off
    while True:
        j = ba.find(cur, i, p_end)
        if j < 0:
            break
        ba[j:j + 4] = new; n += 1; i = j + 4
    return (struct.unpack('<I', cur)[0], struct.unpack('<I', new)[0], n)

def set_hdr_u32(ba, rel_off, val):
    hoff = phdrs(ba)[1]['off']
    struct.pack_into('<I', ba, hoff + rel_off, val & 0xFFFFFFFF)

# (name, description, header-field mutations applied after the payload flip + hash fix)
# mutation = list of (rel_off, value); None value means "no header mutation"
PROBES = [
    ("v0_control_stock",  "untouched stock (expect ind_error=0, registers)", "CONTROL_STOCK"),
    ("v1_control_stale",  "flip 1 payload byte, fix hashes, well-formed header, RSA sig stale (expect 34; reproduces 10-16)", []),
    ("v2_sigsize_max",    "sig_size=0xFFFFFFFF (direct aboot 'length exceeds buffer' analog)", [(0x1c, 0xFFFFFFFF)]),
    ("v3_sigsize_over",   "sig_size=0x00010000 (over the ~6.5KB seg, not 0xFFFFFFFF)",          [(0x1c, 0x00010000)]),
    ("v4_sigsize_zero",   "sig_size=0 (verifier may treat as 'no signature -> skip')",          [(0x1c, 0x00000000)]),
    ("v5_certsize_max",   "cert_chain_size=0xFFFFFFFF",                                         [(0x24, 0xFFFFFFFF)]),
    ("v6_certsize_zero",  "cert_chain_size=0 (no chain -> skip chain/root check?)",             [(0x24, 0x00000000)]),
    ("v7_imagesize_max",  "image_size=0xFFFFFFFF (inflate overall declared size)",              [(0x10, 0xFFFFFFFF)]),
    ("v8_sig_cert_zero",  "sig_size=0 AND cert_chain_size=0 together",                          [(0x1c, 0), (0x24, 0)]),
]

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    stock, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    src = open(stock, 'rb').read()
    man = []
    for name, desc, mut in PROBES:
        ba = bytearray(src)
        if mut == "CONTROL_STOCK":
            vernote = "none (stock, version unchanged)"
        else:
            cur, new, n = bump_mcfg_version(ba)
            fix_hashes(ba)
            for rel, val in mut:
                set_hdr_u32(ba, rel, val)
            vernote = f"mcfg ver 0x{cur:08x}->0x{new:08x} ({n} copies)"
        out = os.path.join(outdir, name + ".mbn")
        open(out, 'wb').write(ba)
        man.append(f"{name:20s} {desc}\n{'':20s} {vernote}  size={len(ba)}B\n")
        print(f"wrote {out}")
    mtxt = ("eSIM MCFG fail-open probe set  (base: %s)\n"
            "Load each on dut1 with pdc-mbn-loader (load <probe> <uniq-id> --hw), record\n"
            "terminal ind_error.  Each load needs a UNIQUE id; use --hw (stock mcfg_sw\n"
            "sits in the HW bucket here).  Probes bump the mcfg version so the modem\n"
            "reaches the authenticator (a same-version edit stops at ind_error=90).\n"
            "Expected if FAIL-CLOSED (likely): v0=0, everything else=34.\n"
            "A fail-open shows as ind_error=0 on any v2..v8 -> go to Tier B.\n\n" % os.path.basename(stock)) + "".join(man)
    open(os.path.join(outdir, "MANIFEST.txt"), 'w').write(mtxt)
    print("\n" + mtxt)

if __name__ == '__main__':
    main()
