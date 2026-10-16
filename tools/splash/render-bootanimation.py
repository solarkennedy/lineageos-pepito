#!/usr/bin/env python3
# render-bootanimation.py — render a bootanimation.zip to a video file.
#
# Draws each frame the way frameworks/base/cmds/bootanimation does: the
# canvas from desc.txt centred on a black screen, every frame scaled (linear)
# into its trim.txt rectangle, or the whole canvas when there is none. Parts
# play in desc.txt order; a part with count 0 loops until boot completes on a
# phone, so here it plays --loops times. Needs Pillow and ffmpeg.
#
#   render-bootanimation.py bootanimation.zip -o boot.mp4 [--hold 1.5] [--loops 2]
#   render-bootanimation.py bootanimation.zip -o boot.gif --scale 0.5   (GIFs come out at 25 fps)

import argparse
import io
import subprocess
import sys
import zipfile

from PIL import Image


def load(path):
    z = zipfile.ZipFile(path)
    desc = [l.split() for l in z.read("desc.txt").decode().splitlines() if l.strip()]
    w, h, fps = map(int, desc[0][:3])
    names = sorted(z.namelist())
    parts = []
    for l in desc[1:]:
        kind, count, pause, folder = l[0], int(l[1]), int(l[2]), l[3]
        frames = [n for n in names if n.startswith(folder + "/") and n.endswith(".png")]
        trim_name = f"{folder}/trim.txt"
        trims = z.read(trim_name).decode().split() if trim_name in names else []
        rects = []
        for i in range(len(frames)):
            if i < len(trims):
                size, x, y = trims[i].split("+")
                tw, th = map(int, size.split("x"))
                rects.append((int(x), int(y), tw, th))
            else:
                rects.append((0, 0, w, h))
        parts.append((kind, count, pause, [(z.read(f), r) for f, r in zip(frames, rects)]))
    return (w, h, fps), parts


def main():
    p = argparse.ArgumentParser(description="render a bootanimation.zip to video")
    p.add_argument("zip")
    p.add_argument("-o", "--output", required=True, help=".mp4, .webm or .gif")
    p.add_argument("--screen", default="720x1280", help="display size (default 720x1280)")
    p.add_argument("--hold", type=float, default=1.5,
                   help="seconds to show the first frame before it starts, as the "
                        "splash is shown before the animation (default 1.5)")
    p.add_argument("--loops", type=int, default=2, help="plays of each looping part (default 2)")
    p.add_argument("--scale", type=float, default=1.0, help="scale the output (e.g. 0.5)")
    args = p.parse_args()

    (cw, ch, fps), parts = load(args.zip)
    sw, sh = map(int, args.screen.split("x"))
    ox, oy = (sw - cw) // 2, (sh - ch) // 2
    ow, oh = round(sw * args.scale) // 2 * 2, round(sh * args.scale) // 2 * 2

    ext = args.output.rsplit(".", 1)[-1].lower()
    enc = {
        "mp4": ["-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart"],
        "webm": ["-c:v", "libvpx-vp9", "-crf", "24", "-b:v", "0", "-pix_fmt", "yuv420p"],
        "gif": ["-vf", "fps=25,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none",
                "-loop", "0"],
    }.get(ext)
    if enc is None:
        sys.exit("output must be .mp4, .webm or .gif")
    ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo",
                           "-pix_fmt", "rgb24", "-s", f"{ow}x{oh}", "-r", str(fps), "-i", "-",
                           *enc, args.output], stdin=subprocess.PIPE)

    def draw(png, rect):
        x, y, tw, th = rect
        img = Image.open(io.BytesIO(png)).convert("RGB")
        if img.size != (tw, th):
            img = img.resize((tw, th), Image.BILINEAR)
        screen = Image.new("RGB", (sw, sh))
        screen.paste(img, (ox + x, oy + y))
        if (ow, oh) != (sw, sh):
            screen = screen.resize((ow, oh), Image.LANCZOS)
        return screen.tobytes()

    total = 0
    first = draw(*parts[0][3][0])
    for _ in range(round(args.hold * fps)):
        ff.stdin.write(first)
        total += 1
    for kind, count, pause, frames in parts:
        plays = count if count > 0 else args.loops
        last = None
        for _ in range(plays):
            for png, rect in frames:
                last = draw(png, rect)
                ff.stdin.write(last)
                total += 1
        for _ in range(pause):
            ff.stdin.write(last)
            total += 1
    ff.stdin.close()
    if ff.wait():
        sys.exit("ffmpeg failed")
    print(f"wrote {args.output}: {ow}x{oh}, {total} frames, {total / fps:.2f} s at {fps} fps")


if __name__ == "__main__":
    main()
