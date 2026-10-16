#!/usr/bin/env python3
# Scan an mcfg_sw.mbn for EFS-file items by signature and verify self-consistency.
# EFS-file item body (after type/attr/len header): efs_attr(u32=0x1902) flags(u16)
#   pathlen(u16) path[pathlen] value[...]. We locate the 0x1902 attr word, read
#   flags+pathlen, and confirm path[pathlen-1]==0 and the path is printable /nv/...
import sys, struct, re

def scan(fn):
    b=open(fn,'rb').read()
    out=[]
    i=0
    sig=b'\x02\x19\x00\x00'   # efs_attr 0x1902 little-endian
    while True:
        j=b.find(sig,i)
        if j<0: break
        i=j+1
        # candidate: at j is efs_attr; flags at j+4, pathlen at j+6, path at j+8
        if j+8>len(b): continue
        flags,pathlen=struct.unpack_from('<HH',b,j+4)
        if pathlen<6 or pathlen>128: continue
        path=b[j+8:j+8+pathlen]
        if not path.endswith(b'\x00'): continue
        s=path[:-1]
        if not s.startswith(b'/nv/'): continue
        try: txt=s.decode('ascii')
        except: continue
        # the preceding 6 bytes should be the item header: type(1) attr(1) len(u32)
        hdr_off=j-6
        itype=b[hdr_off] if hdr_off>=0 else None
        ilen=struct.unpack_from('<I',b,hdr_off+2)[0] if hdr_off>=0 else None
        out.append((hdr_off,itype,ilen,flags,pathlen,txt,j))
    return b,out

for fn in sys.argv[1:]:
    b,items=scan(fn)
    print(f"== {fn}: {len(items)} EFS-file items ==")
    # verify header len == efs_attr(4)+flags(2)+pathlen(2)+pathlen+valuelen
    for (hdr_off,itype,ilen,flags,pathlen,txt,j) in items:
        # value length: next item header or end. Use ilen to compute.
        valuelen = ilen - 8 - pathlen if ilen else None
        val=b[j+8+pathlen : j+8+pathlen+valuelen] if valuelen and valuelen>=0 else b''
        tag=''
        if 'uim' in txt or 'apdu' in txt or 'secur' in txt: tag=' <<< UIM/SEC'
        print(f"  type=0x{itype:02x} ilen={ilen} flags=0x{flags:04x} plen={pathlen} "
              f"vlen={valuelen} {txt} = {val.hex()}{tag}")
