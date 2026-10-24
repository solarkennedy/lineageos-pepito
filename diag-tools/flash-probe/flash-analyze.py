#!/usr/bin/env python3
"""flash-analyze.py BUNDLE -- grade every photo in a flash-report.sh bundle (.tar.gz or dir).

Per shot: the flash ioctl sequence between the previous shot marker and this one, its timing
against the snapshot frame's SOF, the commanded strobe current vs the Flash power cap, the PMIC
VPH-droop latch, camera-daemon frame slips, and the photo's EXIF flash + mean brightness (needs
Pillow).  Same classification as flash-trace.sh; see PLAN-misc.md §9 addenda 6 and 8.
Run with `python3 -I` -- the bundle is untrusted input.
"""
import os, re, sys, tarfile, tempfile

TYPES = {0: "INIT", 1: "RELEASE", 2: "OFF", 3: "LOW", 4: "HIGH"}


def open_bundle(path):
    if os.path.isdir(path):
        return path
    tmp = tempfile.mkdtemp(prefix="flashrep-")
    with tarfile.open(path) as t:
        t.extractall(tmp, filter="data")
    subs = [os.path.join(tmp, d) for d in os.listdir(tmp)]
    return subs[0] if len(subs) == 1 and os.path.isdir(subs[0]) else tmp


def read(d, name):
    p = os.path.join(d, name)
    return open(p, errors="replace").read().splitlines() if os.path.exists(p) else []


def kmsg(lines):
    out = []
    for ln in lines:
        m = re.match(r"^\[\s*([0-9.]+)\]\s?(.*)", ln)
        if m:
            out.append((float(m.group(1)), m.group(2)))
    return out


def logcat(lines):
    out = []
    for ln in lines:
        m = re.match(r"^\s*([0-9]+\.[0-9]+)\s+(.*)", ln)
        if m:
            out.append((float(m.group(1)), m.group(2)))
    return out


def markers(evts):
    return {int(m.group(1)): t for t, s in evts if (m := re.search(r"FLASHTRACE:? shot (\d+)$", s))}


def photo_grade(path):
    try:
        from PIL import Image
    except ImportError:
        return None, None
    im = Image.open(path)
    f = im.getexif().get_ifd(0x8769).get(0x9209)
    px = list(im.convert("L").resize((30, 40)).getdata())
    return f, sum(px) / len(px)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = open_bundle(sys.argv[1])
    print("\n".join(read(d, "info.txt")))
    K = kmsg(read(d, "kmsg.txt"))
    L = logcat(read(d, "logcat.txt"))
    km, lm = markers(K), markers(L)
    shots = {}
    for ln in read(d, "shots.txt"):
        kv = dict(x.split("=", 1) for x in ln.split() if "=" in x)
        shots[int(kv["shot"])] = kv
    latch_log = read(d, "latch.txt")
    rows = []
    for n in sorted(shots):
        kv = shots[n]
        print(f"\n=================== shot {n}  ({kv.get('photo', '?')}) ===================")
        print(f"at shot: uptime={kv.get('up')} latch={kv.get('latch')} cap={kv.get('cap')} "
              f"status={kv.get('status')} soc={kv.get('soc')} uV={kv.get('uV')} uA={kv.get('uA')}")
        if n not in km or (n - 1) not in km:
            print("  (kernel shot markers missing -- read kmsg.txt by hand)")
            continue
        k0, k1 = km[n - 1], km[n]
        win = [(t, s) for t, s in K if k0 < t <= k1]
        ioc = [(t, TYPES.get(int(m.group(1)), m.group(1))) for t, s in win
               if (m := re.search(r"msm_flash_config:\d+ Enter msm_flash_config type (\d)", s))]
        hfc = [int(m.group(1)) for t, s in win if (m := re.search(r"high_flash_current\[0\] = (\d+)", s))]
        capped = [s for t, s in win if "capped to" in s]
        d342 = sorted({m.group(1) for t, s in win if (m := re.search(r"Write (0x[0-9A-F]+) to addr 0xD342", s))} - {"0x00"})
        invalid = any("Invalid state" in s for t, s in win)
        seq = " ".join(x for _, x in ioc)
        print(f"ioctls: {seq or '(none)'}")
        print(f"strobe: high_flash_current={hfc or '?'} {('(' + capped[-1].split(': ')[-1] + ')') if capped else ''} "
              f"PMIC 0xD342 codes={d342 or '?'}")
        # align to the snapshot frame
        sof = None
        if n in lm and (n - 1) in lm:
            off = lm[n] - k1
            lwin = [(t, s) for t, s in L if lm[n - 1] < t <= lm[n]]
            blobs = [(i, m.group(1)) for i, (t, s) in enumerate(lwin)
                     if "stream format = 33" in s and (m := re.search(r"frame = (\d+),", s))]
            if blobs:
                bi, blob = blobs[-1]
                for t, s in lwin[bi:]:
                    m = re.search(rf"valid frame_number = {blob},.*capture_time = (-?\d+)", s)
                    if m:
                        sof = int(m.group(1)) / 1e9
                        break
            if sof is not None:
                print(f"snapshot frame {blob}, SOF {sof:.3f} (logcat clock); ioctls vs SOF:")
                for t, x in ioc:
                    print(f"  {x:8s} {((t + off) - sof) * 1000:+8.0f} ms")
                slips = [(t, s) for t, s in lwin if re.search(r"Skipping sof|Remap pending request|reporting error frame", s)
                         and -0.4 < t - sof < 0.15]
                for t, s in slips:
                    print(f"  FRAME SLIP {(t - sof) * 1000:+.0f} ms: {s[:140]}")
            else:
                print("  (no snapshot SOF in logcat -- third-party camera app, or the app was not reopened after start)")
                slips = []
        else:
            slips = []
        lat = [ln for ln in latch_log if k0 - 5 < float(ln.split()[0]) <= float(kv.get("up", 1e9)) + 1]
        if lat:
            print("latch changes: " + "; ".join(lat))
        ef, meany = (None, None)
        for ext in ("jpg", "jpeg", "JPG", "heic"):
            p = os.path.join(d, f"shot{n}.{ext}")
            if os.path.exists(p):
                try:
                    ef, meany = photo_grade(p)
                except Exception as e:
                    print(f"  (photo unreadable: {e})")
                break
        if meany is not None:
            print(f"photo: exif_flash={ef} ({'FIRED' if ef is not None and ef & 1 else 'not fired'}) meanY={meany:.0f}")
        flags = []
        if re.search(r"LOW.*OFF.*HIGH.*OFF", seq):
            flags.append("NORMAL")
        elif re.search(r"LOW.*OFF", seq):
            flags.append("NO STROBE REQUESTED")
        elif not ioc:
            flags.append("NO FLASH IOCTLS")
        if seq.count("HIGH") > 1:
            flags.append("SEVERAL STROBES IN WINDOW")
        lv = kv.get("latch", "")
        if re.fullmatch(r"[0-9a-fA-F]{2}", lv) and int(lv, 16) & 0x10 or any(
                re.search(r"latch ([0-9a-fA-F]{2})$", x) and int(x.split()[-1], 16) & 0x10 for x in lat):
            flags.append("VPH DROOP CLAMP")
        if slips:
            flags.append("FRAME SLIP")
        if invalid:
            flags.append("DRIVER DROPPED (Invalid state)")
        cap = kv.get("cap", "")
        if cap in ("", None):
            flags.append("NO FLASH POWER CAP IN KERNEL")
        elif hfc and cap.isdigit() and int(cap) and hfc[-1] > int(cap):
            flags.append("CAP NOT APPLIED")
        print("verdict: " + ", ".join(flags))
        rows.append(f"shot{n} up={kv.get('up')} {kv.get('status')} soc={kv.get('soc')} cap={cap} "
                    f"strobe={hfc[-1] if hfc else '?'}mA latch={lv} exif={ef} meanY={meany and round(meany)}  [{', '.join(flags)}]")
    print("\n=================== summary ===================")
    print("\n".join(rows))
    print("(lit 1000 mA strobe in a dark room: meanY ~120-150; 700 mA ~105; 400 mA ~80; 200 mA droop clamp ~45)")


if __name__ == "__main__":
    main()
