#!/usr/bin/env python3
# splash.py — read the PVG100 `splash` partition and replace its boot logo.
#
# The partition is 11 MiB, but only its first 128 KiB is the image the
# bootloader draws (the layout is in README.md): a 32-byte "SPLASH!!" header,
# a table at 0x200 and five full-screen 720x1280 BGR24 frames, each
# zlib-compressed at level 9. Frame 0 is the PALM logo. Everything from 0x20000
# on is leftover from an older, larger splash image. It is the same on every
# unit backed up so far and is kept byte-for-byte.
#
# replace-logo re-encodes frame 0 only. Frames 1-4, the header fields we do not
# understand and the leftover region stay as they are, so the new frames have
# to fit below 0x20000.

import argparse
import struct
import sys
import zlib

from PIL import Image

MAGIC = b"SPLASH!!"
WIDTH, HEIGHT = 720, 1280
FRAME_BYTES = WIDTH * HEIGHT * 3
TABLE_OFF = 0x200        # count, total size, then one offset per frame (relative to TABLE_OFF)
REGION_END = 0x20000     # leftover data starts here; the frames must end before it
LEVEL = 9                # reproduces the stock frames byte-for-byte
FRAME_NAMES = ["logo", "charger-unplugged", "download-mode", "charging-1", "charging-2"]


class SplashError(Exception):
    pass


def parse(data):
    if data[:8] != MAGIC:
        raise SplashError("no SPLASH!! magic at offset 0 — not a splash partition")
    width, height = struct.unpack_from("<2I", data, 8)
    if (width, height) != (WIDTH, HEIGHT):
        raise SplashError(f"header says {width}x{height}, expected {WIDTH}x{HEIGHT}")
    count, total = struct.unpack_from("<2I", data, TABLE_OFF)
    if count != len(FRAME_NAMES):
        raise SplashError(f"table lists {count} frames, expected {len(FRAME_NAMES)}")
    offsets = list(struct.unpack_from(f"<{count}I", data, TABLE_OFF + 8))
    bounds = offsets + [total]
    if offsets[0] != 8 + 4 * count or any(a >= b for a, b in zip(bounds, bounds[1:])):
        raise SplashError(f"frame table is not in order: offsets {offsets}, total {total}")
    if TABLE_OFF + total > REGION_END:
        raise SplashError(f"frames end at {TABLE_OFF + total:#x}, past {REGION_END:#x}")
    frames = [data[TABLE_OFF + a:TABLE_OFF + b] for a, b in zip(bounds, bounds[1:])]
    for i, blob in enumerate(frames):
        if len(zlib.decompress(blob)) != FRAME_BYTES:
            raise SplashError(f"frame {i} does not decompress to {FRAME_BYTES} bytes")
    return frames


def frame_image(blob):
    return Image.frombytes("RGB", (WIDTH, HEIGHT), zlib.decompress(blob), "raw", "BGR")


def encode_image(img):
    return zlib.compress(img.convert("RGB").tobytes("raw", "BGR"), LEVEL)


def build(data, frames):
    """Return a copy of `data` with the frame table and frames replaced."""
    count = len(frames)
    offsets, pos = [], 8 + 4 * count
    for blob in frames:
        offsets.append(pos)
        pos += len(blob)
    end = TABLE_OFF + pos
    if end > REGION_END:
        raise SplashError(
            f"the frames would end at {end:#x}, {end - REGION_END} bytes past "
            f"{REGION_END:#x}; frame 0 must compress to at most "
            f"{len(frames[0]) - (end - REGION_END)} bytes (a simpler logo, fewer colours "
            "or a smaller image on black compress better)")
    out = bytearray(data)
    out[TABLE_OFF:REGION_END] = bytes(REGION_END - TABLE_OFF)
    struct.pack_into(f"<2I{count}I", out, TABLE_OFF, count, pos, *offsets)
    out[TABLE_OFF + offsets[0]:end] = b"".join(frames)
    return bytes(out)


def load_logo(path, fit):
    img = Image.open(path)
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, (0, 0, 0, 255))
        img = Image.alpha_composite(bg, img)
    img = img.convert("RGB")
    if img.size == (WIDTH, HEIGHT):
        return img
    if not fit:
        raise SplashError(f"{path} is {img.size[0]}x{img.size[1]}; it must be "
                          f"{WIDTH}x{HEIGHT} (or pass --fit to centre it on black)")
    scale = min(WIDTH / img.size[0], HEIGHT / img.size[1], 1.0)
    if scale < 1.0:
        img = img.resize((round(img.size[0] * scale), round(img.size[1] * scale)),
                         Image.LANCZOS)
    canvas = Image.new("RGB", (WIDTH, HEIGHT))
    canvas.paste(img, ((WIDTH - img.size[0]) // 2, (HEIGHT - img.size[1]) // 2))
    return canvas


def replace_logo(data, img):
    frames = parse(data)
    out = build(data, [encode_image(img)] + frames[1:])
    # Check the result the way the bootloader will read it.
    new = parse(out)
    if new[1:] != frames[1:] or out[REGION_END:] != data[REGION_END:] or out[:TABLE_OFF] != data[:TABLE_OFF]:
        raise SplashError("internal error: something besides frame 0 changed")
    if frame_image(new[0]).tobytes() != img.tobytes():
        raise SplashError("internal error: frame 0 does not decode to the new logo")
    return out


def cmd_info(args):
    data = open(args.splash, "rb").read()
    frames = parse(data)
    end = TABLE_OFF + 8 + 4 * len(frames) + sum(map(len, frames))
    print(f"{args.splash}: {len(data)} bytes, {WIDTH}x{HEIGHT}, {len(frames)} frames, "
          f"frames end at {end:#x} ({REGION_END - end} bytes free below {REGION_END:#x})")
    for i, (name, blob) in enumerate(zip(FRAME_NAMES, frames)):
        print(f"  {i} {name:18} {len(blob):6} bytes compressed")


def cmd_unpack(args):
    import os
    data = open(args.splash, "rb").read()
    os.makedirs(args.outdir, exist_ok=True)
    for i, (name, blob) in enumerate(zip(FRAME_NAMES, parse(data))):
        path = os.path.join(args.outdir, f"{i}-{name}.png")
        frame_image(blob).save(path)
        print(path)


def cmd_replace_logo(args):
    data = open(args.splash, "rb").read()
    out = replace_logo(data, load_logo(args.logo, args.fit))
    with open(args.output, "wb") as f:
        f.write(out)
    used = len(parse(out)[0])
    print(f"wrote {args.output}: new logo is {used} bytes compressed")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__ or "PVG100 splash partition tool")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("info", help="list the frames and the free space")
    s.add_argument("splash")
    s.set_defaults(func=cmd_info)
    s = sub.add_parser("unpack", help="write every frame as a PNG")
    s.add_argument("splash")
    s.add_argument("outdir")
    s.set_defaults(func=cmd_unpack)
    s = sub.add_parser("replace-logo", help="write a copy with a new boot logo (frame 0)")
    s.add_argument("splash", help="the phone's own splash backup (splash.bin)")
    s.add_argument("logo", help=f"the new logo, {WIDTH}x{HEIGHT} (any format Pillow reads)")
    s.add_argument("-o", "--output", required=True)
    s.add_argument("--fit", action="store_true",
                   help="centre a logo of another size on black, shrinking it if needed")
    s.set_defaults(func=cmd_replace_logo)
    args = p.parse_args(argv)
    try:
        args.func(args)
    except SplashError as e:
        sys.exit(f"splash.py: {e}")


if __name__ == "__main__":
    main()
