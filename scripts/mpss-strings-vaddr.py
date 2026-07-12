#!/usr/bin/env python3
# Map every printable string in a reassembled MPSS Hexagon ELF to its virtual
# address, using the program-header offset->vaddr mapping (the ELF has no
# section headers). Lets you: (a) find the vaddr of an anchor string to xref in
# disassembly, and (b) identify a stripped function by the string vaddr it loads.
# See PLAN-modem-disasm.md. Usage:
#   mpss-strings-vaddr.py <modem.elf>            # dump all strings >=4 chars: vaddr\tstring
#   mpss-strings-vaddr.py <modem.elf> <substr>   # only strings containing substr
import struct, sys, re

elf = open(sys.argv[1], 'rb').read()
want = sys.argv[2].encode() if len(sys.argv) > 2 else None

e_phoff = struct.unpack_from('<I', elf, 0x1c)[0]
e_phnum = struct.unpack_from('<H', elf, 0x2c)[0]
e_phentsize = struct.unpack_from('<H', elf, 0x2a)[0]
segs = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    t, poff, pva, ppa, pfsz, pmsz, pfl, pal = struct.unpack_from('<IIIIIIII', elf, o)
    if pfsz:
        segs.append((poff, pva, pfsz))

def vaddr(off):
    for poff, pva, pfsz in segs:
        if poff <= off < poff + pfsz:
            return pva + (off - poff)
    return None

for m in re.finditer(rb'[\x20-\x7e]{4,}', elf):
    s = m.group()
    if want and want not in s:
        continue
    va = vaddr(m.start())
    if va is not None:
        print('%08x\t%s' % (va, s.decode('latin1')))
