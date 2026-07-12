#!/usr/bin/env python3
# Reassemble a program-header-only Hexagon ELF (MPSS modem) from an extracted
# image dir containing modem.mdt + modem.bNN. Each modem.bNN payload is placed
# at program-header index NN's p_offset. Output is disassemblable with:
#   llvm-objdump-15 -d --triple=hexagon <out.elf>
# See PLAN-modem-disasm.md. Usage: mpss-reasm.py <image_dir> <out.elf>
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
    phdrs.append((i, poff, pfsz, pva, pfl))
    maxend = max(maxend, poff + pfsz)

buf = bytearray(maxend)
buf[0:e_phoff + e_phnum * e_phentsize] = mdt[0:e_phoff + e_phnum * e_phentsize]
for i, off, fsz, va, fl in phdrs:
    if not fsz:
        continue
    bn = os.path.join(d, 'modem.b%02d' % i)
    if os.path.exists(bn):
        buf[off:off + fsz] = open(bn, 'rb').read()[:fsz]

open(out, 'wb').write(buf)
print('wrote %s (%d bytes)' % (out, len(buf)))
for i, off, fsz, va, fl in phdrs:
    if fl & 1 and fsz:
        flags = ''.join(c for c, b in zip('RWX', (4, 2, 1)) if fl & b)
        print('EXEC seg %d vaddr=%08x filesz=%08x flags=%s' % (i, va, fsz, flags))
