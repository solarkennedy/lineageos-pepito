#!/usr/bin/env python3
# make-bootanimation.py — a boot animation that continues from the splash logo.
#
# The bootloader shows the splash (the PALM logo) until SurfaceFlinger starts
# the boot animation, about 30 s into boot. To join the two, this writes the
# stock PALM logo without its "powered by Android" footer as the new splash
# logo, and builds a boot animation that starts on exactly that screen, fades
# PALM out, and then plays LineageOS's animation unchanged.
#
# Input is the boot animation LineageOS builds (a 720x240 strip, stored as
# 360x120 frames) and a stock splash. The output has a full-screen canvas: a
# new first part with the fade, then LineageOS's parts, placed with trim.txt
# where they were before so they look as they did.
#
#   make-bootanimation.py lineage-bootanimation.zip splash.bin -o out/
#   splash.py replace-logo splash.bin out/logo.png -o splash-new.bin

import argparse
import io
import os
import sys
import zipfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import splash  # noqa: E402

W, H = splash.WIDTH, splash.HEIGHT
FPS = 60
STRIP_H = 240                    # LineageOS draws its strip 720x240 ...
STRIP_Y = (H - STRIP_H) // 2     # ... centred on the screen
PALM_Y = (560, 720)              # rows of the PALM block in the stock logo


def smoothstep(t):
    t = min(max(t, 0.0), 1.0)
    return t * t * (3 - 2 * t)


def read_parts(path):
    z = zipfile.ZipFile(path)
    desc = z.read("desc.txt").decode().split("\n")
    w, h, fps = map(int, desc[0].split()[:3])
    if (w, h, fps) != (W, STRIP_H, FPS):
        sys.exit(f"{path}: expected a {W}x{STRIP_H} {FPS} fps animation, desc says {desc[0]!r}")
    lines = [l.split() for l in desc[1:] if l.strip()]
    parts = {}
    for name in sorted(z.namelist()):
        d, _, leaf = name.partition("/")
        if leaf.endswith(".png"):
            parts.setdefault(d, []).append((leaf, z.read(name)))
    return lines, parts


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def main():
    p = argparse.ArgumentParser(description="boot animation that starts from the splash logo")
    p.add_argument("bootanimation", help="LineageOS's bootanimation.zip (720x240 strip)")
    p.add_argument("splash", help="a stock splash.bin")
    p.add_argument("-o", "--outdir", required=True)
    p.add_argument("--fade-frames", type=int, default=30,
                   help=f"length of the PALM fade in frames at {FPS} fps (default 30)")
    args = p.parse_args()

    lines, parts = read_parts(args.bootanimation)
    if any(l[0] not in "cp" or l[3] not in parts for l in lines):
        sys.exit(f"unexpected desc.txt lines: {lines}")

    stock = splash.frame_image(splash.parse(open(args.splash, "rb").read())[0]).convert("L")
    palm = stock.crop((0, PALM_Y[0], W, PALM_Y[1]))
    logo = Image.new("L", (W, H))
    logo.paste(palm, (0, PALM_Y[0]))

    os.makedirs(args.outdir, exist_ok=True)
    logo.convert("RGB").save(os.path.join(args.outdir, "logo.png"))

    out = zipfile.ZipFile(os.path.join(args.outdir, "bootanimation.zip"), "w", zipfile.ZIP_STORED)
    # LineageOS's parts move up one place behind the new part0.
    desc = [f"{W} {H} {FPS}", "c 1 0 part0"]
    for i, l in enumerate(lines):
        desc.append(" ".join(l[:3] + [f"part{i + 1}"] + l[4:]))
    out.writestr("desc.txt", "\n".join(desc) + "\n")

    # The fade: only the PALM rows are stored and drawn (frames are decoded as
    # they play, so small frames keep it at full speed). The first frame is
    # the splash logo itself.
    trim_palm = f"{W}x{PALM_Y[1] - PALM_Y[0]}+0+{PALM_Y[0]}\n"
    for i in range(args.fade_frames):
        a = 1.0 - smoothstep(i / args.fade_frames)
        out.writestr(f"part0/{i:03d}.png", png_bytes(palm.point(lambda v: round(v * a))))
    out.writestr("part0/trim.txt", trim_palm * args.fade_frames)

    trim_strip = f"{W}x{STRIP_H}+0+{STRIP_Y}\n"
    for i, l in enumerate(lines):
        for leaf, png in parts[l[3]]:
            out.writestr(f"part{i + 1}/{leaf}", png)
        out.writestr(f"part{i + 1}/trim.txt", trim_strip * len(parts[l[3]]))
    out.close()
    print(f"wrote {args.outdir}/bootanimation.zip and {args.outdir}/logo.png "
          f"(PALM fades over {args.fade_frames} frames, {args.fade_frames / FPS:.2f} s)")


if __name__ == "__main__":
    main()
