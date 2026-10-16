#!/usr/bin/env python3
"""Static mcfg_sw.mbn patcher for the pepito eSIM lane.

Layout (verified on stock PVG100 mcfg_sw configs, format_type=3):
  ph0: ELF header + phdr table mirror   (hashed -> hashtab slot0)
  ph1: hash-table seg = hdr(40) + sha256 slot per phdr + RSA sig + X.509 chain
       (slot1, the hash-seg's own slot, is zero)
  ph2: MCFG payload = 'MCFG' hdr(16) + item list   (hashed -> hashtab slot2)

What this tool can do WITHOUT re-signing (RSA sig over the hash table goes stale):
  verify  - recompute slot0/slot2 and confirm they match stock
  flip    - change one payload byte (enforcement probe) and fix the hashes
  inject  - add an EFS-file item (path,value) to the payload, bump num_items,
            fix ph2 size in both the phdr and the ph0 mirror, fix the hashes

The stale RSA signature is the whole point of the first on-device test: if the
modem loads a hash-fixed / sig-stale config, SW-config auth is not enforced
(fake-sec) and the inject route is open; if it rejects it, auth is enforced.
"""
import sys, struct, hashlib, argparse

HDR=40; HL=32

def phdrs(b):
    e_phoff=struct.unpack_from('<I',b,0x1c)[0]
    e_phnum=struct.unpack_from('<H',b,0x2c)[0]
    ent=struct.unpack_from('<H',b,0x2a)[0]
    out=[]
    for i in range(e_phnum):
        o=e_phoff+i*ent
        pt,off,va,pa,fsz,msz,fl,al=struct.unpack_from('<IIIIIIII',b,o)
        out.append(dict(idx=i,o=o,pt=pt,off=off,va=va,pa=pa,fsz=fsz,msz=msz,fl=fl,al=al))
    return e_phoff,ent,out

def fix_hashes(ba):
    """ba: bytearray. Recompute slot0 (ph0 region) and slot2 (payload) in-place."""
    _,_,ph=phdrs(ba)
    hash_off=ph[1]['off']
    # slot0 = sha256 of ph0 file region (header+phdr mirror)
    s0=hashlib.sha256(bytes(ba[ph[0]['off']:ph[0]['off']+ph[0]['fsz']])).digest()
    ba[hash_off+HDR+0*HL:hash_off+HDR+0*HL+HL]=s0
    # slot2 = sha256 of payload
    s2=hashlib.sha256(bytes(ba[ph[2]['off']:ph[2]['off']+ph[2]['fsz']])).digest()
    ba[hash_off+HDR+2*HL:hash_off+HDR+2*HL+HL]=s2
    return s0,s2

def verify(fn):
    b=open(fn,'rb').read()
    _,_,ph=phdrs(b)
    hash_off=ph[1]['off']
    ok=True
    for i in (0,2):
        slot=b[hash_off+HDR+i*HL:hash_off+HDR+i*HL+HL]
        calc=hashlib.sha256(b[ph[i]['off']:ph[i]['off']+ph[i]['fsz']]).digest()
        m=slot==calc
        ok&=m
        print(f"  slot{i}: stored={slot[:8].hex()} calc={calc[:8].hex()} {'OK' if m else 'MISMATCH'}")
    print("  payload num_items:",struct.unpack_from('<I',b,ph[2]['off']+8)[0])
    print("VERIFY",("OK" if ok else "FAIL"))
    return ok

def build_efs_record(path, value):
    """marker(2)=2 | vallen(2) | value | reclen(4) | attr(4)=0x1902 | flags(2)=1 | pathlen(2) | path\\0"""
    p=path.encode('ascii')+b'\x00'
    pathlen=len(p)
    reclen = 2 + 2 + 2 + 2 + pathlen            # reclen counts attr..path (see note)
    # reclen (per stock) = attr(4)+flags(2)+pathlen(2)+path = 8+pathlen  ... PLUS the
    # marker(2)+vallen(2)+value back-reference? Stock refresh_vote_ok: reclen=0x42=66,
    # marker..path = 2+2+2+4+4+2+2+48 = 66 => reclen counts the WHOLE record.
    whole = 2 + 2 + len(value) + 4 + 4 + 2 + 2 + pathlen
    rec = struct.pack('<HH',2,len(value)) + value + struct.pack('<I',whole) \
        + struct.pack('<I',0x1902) + struct.pack('<HH',1,pathlen) + p
    assert len(rec)==whole
    return rec

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('cmd',choices=['verify','flip','inject'])
    ap.add_argument('infile'); ap.add_argument('outfile',nargs='?')
    ap.add_argument('--off',type=lambda x:int(x,0),help='flip: payload-relative byte offset')
    ap.add_argument('--xor',type=lambda x:int(x,0),default=0x01)
    ap.add_argument('--path'); ap.add_argument('--value',help='hex value bytes')
    ap.add_argument('--after',default='/nv/item_files/modem/uim/mmgsdi/refresh_vote_ok',
                    help='inject: insert new record right after this existing EFS path')
    a=ap.parse_args()
    if a.cmd=='verify':
        verify(a.infile); return
    b=bytearray(open(a.infile,'rb').read())
    _,ent,ph=phdrs(b)
    payload_off=ph[2]['off']
    if a.cmd=='flip':
        tgt=payload_off+a.off
        old=b[tgt]; b[tgt]^=a.xor
        print(f"flip payload+0x{a.off:x} (file 0x{tgt:x}): 0x{old:02x} -> 0x{b[tgt]:02x}")
    elif a.cmd=='inject':
        rec=build_efs_record(a.path, bytes.fromhex(a.value))
        anchor=(a.after.encode()+b'\x00')
        ap_off=b.find(anchor, payload_off)
        if ap_off<0: sys.exit("anchor path not found")
        # end of the anchor record = after its NUL-terminated path (EFS record = value-first,
        # path last), so the record boundary is right after the anchor path's NUL.
        ins=ap_off+len(anchor)
        b[ins:ins]=rec
        # bump num_items
        ni=struct.unpack_from('<I',b,payload_off+8)[0]
        struct.pack_into('<I',b,payload_off+8,ni+1)
        # grow ph2 filesz/memsz in the real phdr
        grow=len(rec)
        b[ph[2]['o']+16:ph[2]['o']+20]=struct.pack('<I',ph[2]['fsz']+grow)  # p_filesz
        b[ph[2]['o']+20:ph[2]['o']+24]=struct.pack('<I',ph[2]['msz']+grow)  # p_memsz
        print(f"injected {len(rec)}B record at payload+0x{ins-payload_off:x}; num_items {ni}->{ni+1}")
        # NOTE: ph0 mirror holds a COPY of the phdr table (off 0..0x94); patch it too.
        # the phdr table starts at e_phoff within the mirror.
    s0,s2=fix_hashes(b)
    print(f"fixed slot0={s0[:8].hex()} slot2={s2[:8].hex()}  (RSA sig now STALE)")
    out=a.outfile or (a.infile+'.patched')
    open(out,'wb').write(b)
    print("wrote",out,len(b),"bytes")
    verify(out)

if __name__=='__main__': main()
