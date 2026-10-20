#!/usr/bin/env python3
"""summarize.py SAMPLE.LOG [...] — PLAN-oos-time §0 split from a v10/v11 sampler log.

Classifies every 15 s sample by what the MODEM says (never the framework):
  HOME        reg=1 on 311480
  HOME-LIMITED reg!=1 on 311480 (limited / searching on Verizon's own cell)
  FOREIGN     reg!=1 on any other PLMN (AT&T 310410, T-Mobile 310260, ...)
  HOLE        no PLMN / lte=0,4 (no service / power save)
  IMS-DOWN    HOME but ims_registered=0 on the last IMS poll (voice-only outage)
  TIMEOUT     probe timed out (counted separately, not as outage)
Then prints episodes (consecutive non-HOME runs), their class mix, recovery
latency, Wi-Fi state, and daily totals in minutes.
"""
import re, sys, collections, datetime

SAMPLE = 15  # s nominal
def parse(line):
    m = re.match(r'(\d\d-\d\d \d\d:\d\d:\d\d) \| MODEM\s+(.*?)\|', line)
    if not m: return None
    t = datetime.datetime.strptime("2026-" + m.group(1), "%Y-%m-%d %H:%M:%S")
    mdm = m.group(2)
    f = dict(re.findall(r'(\w+)=(\S+)', mdm))
    sig = re.search(r'rsrp=(-?\d+)', line)
    rsrp = int(sig.group(1)) if sig else None
    if rsrp is not None and rsrp > 0: rsrp = None       # framework INT_MAX
    srx = re.search(r'srxlev=(-?\d+)\]', line)           # v11 serving-cell srxlev (starred entry may not be first)
    srxs = re.findall(r'\*pci=\d+ rsrp=(-?[\d.]+) rsrq=-?[\d.]+ srxlev=(-?\d+)', line)
    srxlev = int(srxs[0][1]) if srxs else (int(srx.group(1)) if srx else None)
    wifi = re.search(r'wifi=(\d)', line); wifi = wifi.group(1) if wifi else '?'
    ims = re.search(r'ims_registered=(\d)', line); ims = ims.group(1) if ims else None
    emg = 'emg=true' in line
    if 'TIMEOUT' in mdm: cls = 'TIMEOUT'
    else:
        reg, plmn, lte = f.get('reg'), f.get('plmn'), f.get('lte')
        if plmn is None or lte in ('0', '4'): cls = 'HOLE'
        elif plmn == '311480': cls = 'HOME' if reg == '1' else 'HOME-LIMITED'
        else: cls = 'FOREIGN'
    return dict(t=t, cls=cls, plmn=f.get('plmn'), reg=f.get('reg'), rsrp=rsrp, srxlev=srxlev,
                wifi=wifi, ims=ims, emg=emg)

rows = []
for path in sys.argv[1:]:
    for l in open(path, errors='replace'):
        r = parse(l)
        if r: rows.append(r)
rows.sort(key=lambda r: r['t'])
if not rows: sys.exit("no samples")

# carry the last IMS poll forward; HOME + ims=0 -> IMS-DOWN
last_ims = None
for r in rows:
    if r['ims'] is not None: last_ims = r['ims']
    r['ims_eff'] = last_ims
    if r['cls'] == 'HOME' and last_ims == '0': r['cls'] = 'IMS-DOWN'

# each sample "covers" until the next one (cap 5 min: longer gaps = sampler dead / phone off)
GAP_CAP = 300
for a, b in zip(rows, rows[1:]):
    a['dur'] = min((b['t'] - a['t']).total_seconds(), GAP_CAP)
rows[-1]['dur'] = SAMPLE
gaps = [(a['t'], (b['t'] - a['t']).total_seconds()) for a, b in zip(rows, rows[1:]) if (b['t'] - a['t']).total_seconds() > GAP_CAP]
print("samples %d  %s -> %s   (median gap %.0f s, %d gaps > %d s)" % (
    len(rows), rows[0]['t'], rows[-1]['t'],
    sorted(r['dur'] for r in rows)[len(rows) // 2], len(gaps), GAP_CAP))
for g in gaps[:10]: print("   gap at %s: %.0f min" % (g[0], g[1] / 60))

# episodes = maximal runs of non-HOME (TIMEOUT does not break or start one)
eps = []; cur = None
for r in rows:
    bad = r['cls'] not in ('HOME', 'TIMEOUT')
    if bad and cur is None:
        cur = dict(start=r['t'], rows=[r], pre=prev if 'prev' in dir() else None)
    elif bad: cur['rows'].append(r)
    elif r['cls'] == 'HOME' and cur is not None:
        cur['end'] = r['t']; eps.append(cur); cur = None
    if r['cls'] != 'TIMEOUT': prev = r
if cur: cur['end'] = rows[-1]['t']; cur['open'] = True; eps.append(cur)

print("\n== episodes (start -> end, minutes, class mix, Wi-Fi share, RSRP of last HOME sample before loss)")
for e in eps:
    mins = (e['end'] - e['start']).total_seconds() / 60
    mix = collections.Counter()
    for r in e['rows']: mix[r['cls']] += r['dur'] / 60.0
    mixs = ' '.join('%s=%.0fm' % kv for kv in mix.most_common())
    wifi = sum(1 for r in e['rows'] if r['wifi'] == '1') / len(e['rows'])
    pre = e.get('pre')
    pre_s = ('%s dBm' % pre['rsrp'] if pre and pre['rsrp'] is not None else '?') + \
            (' srxlev=%s' % pre['srxlev'] if pre and pre['srxlev'] is not None else '')
    print("  %s -> %s %6.1f min  [%s]  wifi=%.0f%%  lost at %s%s" % (
        e['start'].strftime('%m-%d %H:%M'), e['end'].strftime('%H:%M'), mins, mixs, wifi * 100, pre_s,
        '  (OPEN)' if e.get('open') else ''))

print("\n== daily totals (minutes, time-weighted; TIMEOUT excluded from the denominator)")
days = collections.defaultdict(collections.Counter)
for r in rows: days[r['t'].date()][r['cls']] += r['dur'] / 60.0
for d in sorted(days):
    c = days[d]; tot = sum(v for k, v in c.items() if k != 'TIMEOUT')
    cells = '  '.join('%s=%.0f' % (k, c[k]) for k in
                      ('HOME', 'IMS-DOWN', 'HOME-LIMITED', 'FOREIGN', 'HOLE') if c[k])
    out = sum(c[k] for k in ('IMS-DOWN', 'HOME-LIMITED', 'FOREIGN', 'HOLE'))
    print("  %s  covered=%.0f min  %s  | OUT=%.0f min (%.1f%%) timeout=%.0f min" % (
        d, tot, cells, out, 100.0 * out / tot if tot else 0, c['TIMEOUT']))
