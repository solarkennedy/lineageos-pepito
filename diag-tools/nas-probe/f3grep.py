#!/usr/bin/env python3
# f3grep.py <decoded.f3.txt> <include-regex> [exclude-regex]
# Prints matching decode_f3.py lines with the QXDM timestamp converted to local wallclock
# (1.25 ms ticks since 1980-01-06, high 48 bits; UTC-7 hard-coded for PDT).
import sys, re, datetime
pat = re.compile(sys.argv[2]); excl = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
epoch = datetime.datetime(1980,1,6)
for l in open(sys.argv[1], errors='replace'):
    m = re.match(r'\s*\[0x([0-9a-f]+)\]\s*(.*)', l)
    if not m: continue
    if not pat.search(m.group(2)) or (excl and excl.search(m.group(2))): continue
    ticks = int(m.group(1),16) >> 16
    t = epoch + datetime.timedelta(milliseconds=ticks*1.25) - datetime.timedelta(hours=7)
    print(t.strftime('%H:%M:%S.%f')[:-3], m.group(2)[:210])
