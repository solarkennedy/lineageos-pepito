#!/usr/bin/env python3
"""SIP messages and RTP activity from a modem .qmdl (no-ringback lane, 2026-11-06).

  diag-tools/ringback/sip-from-qmdl.py cap.qmdl [--from HH:MM:SS] [--to HH:MM:SS] [-v]

Per IMS SIP message (log 0x156E): local time, direction, start line, and the SDP lines
that decide early media (m=audio, a=sendrecv/recvonly/sendonly/inactive, P-Early-Media).
-v prints whole messages. Then a per-second count of IMS RTP log packets (0x1568) when the
mask had them, so you can see whether audio flowed while the call was ringing.
0x156E layout from scat (diag1xlogparser.parse_sip_message).
"""
import argparse
import collections
import datetime
import struct

EPOCH = datetime.datetime(1980, 1, 6, tzinfo=datetime.timezone.utc)
SIP, RTP = 0x156E, 0x1568
SDP_KEYS = ('m=audio', 'a=sendrecv', 'a=recvonly', 'a=sendonly', 'a=inactive', 'p-early-media',
            'require:', 'supported:', 'a=rtpmap')


def frames(data):
    for raw in data.split(b'\x7e'):
        if not raw:
            continue
        out, esc = bytearray(), False
        for b in raw:
            if esc:
                out.append(b ^ 0x20)
                esc = False
            elif b == 0x7D:
                esc = True
            else:
                out.append(b)
        if len(out) > 2:
            yield bytes(out[:-2])  # drop CRC


def ts_local(ts):
    t = EPOCH + datetime.timedelta(milliseconds=(ts >> 16) * 1.25 + (ts & 0xFFFF) / 40960)  # as scat util.parse_qxdm_ts
    return t.astimezone()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('qmdl', nargs='+')
    ap.add_argument('--from', dest='t0')
    ap.add_argument('--to', dest='t1')
    ap.add_argument('-v', action='store_true')
    a = ap.parse_args()
    rtp = collections.Counter()
    for path in a.qmdl:
        for f in frames(open(path, 'rb').read()):
            if f[0] != 0x10 or len(f) < 16:
                continue
            code, ts = struct.unpack_from('<HQ', f, 6)
            if code not in (SIP, RTP):
                continue
            t = ts_local(ts)
            hms = t.strftime('%H:%M:%S')
            if (a.t0 and hms < a.t0) or (a.t1 and hms > a.t1):
                continue
            body = f[16:]
            if code == RTP:
                rtp[hms] += 1
                continue
            _, direction, has_sdp, len_cid, _, len_real = struct.unpack_from('<BBBBHH', body, 0)
            sip = body[16 + len_cid:16 + len_cid + len_real - 1].decode('latin-1', 'replace')
            lines = sip.replace('\r', '').split('\n')
            arrow = '->' if direction == 1 else '<-'
            print(f"{t.strftime('%H:%M:%S.%f')[:-3]} {arrow} {lines[0][:80]}  sdp={has_sdp}")
            if a.v:
                print('    ' + '\n    '.join(lines))
            else:
                for l in lines[1:]:
                    if l.lower().startswith(SDP_KEYS):
                        print(f'      {l[:110]}')
    if rtp:
        print('\nIMS RTP log packets per second:')
        for s in sorted(rtp):
            print(f'  {s} {rtp[s]}')


if __name__ == '__main__':
    main()
