#!/usr/bin/env python3
# Tests for splash.py. They run on a synthetic splash image, because the stock
# one is Palm's artwork and stays out of this repo. Set SPLASH_BIN to a real
# backup (…/dump-*/splash.bin) to also run the round trip against it.
#
#   python3 -m unittest tools/splash/test_splash.py

import os
import random
import struct
import sys
import unittest
import zlib

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import splash  # noqa: E402

W, H = splash.WIDTH, splash.HEIGHT


def solid(rgb):
    return Image.new("RGB", (W, H), rgb)


def synthetic():
    """A splash laid out like the stock one, with plain frames and a random tail."""
    imgs = [solid((0, 0, 0)), solid((40, 40, 40)), solid((200, 0, 0)),
            solid((0, 0, 90)), solid((0, 90, 0))]
    logo = imgs[0].copy()
    logo.paste((255, 255, 255), (300, 600, 420, 680))
    imgs[0] = logo
    data = bytearray(0x40000)
    data[0:32] = splash.MAGIC + struct.pack("<6I", W, H, 0x200, 216, 0xFFFFFF06, 0x79)
    rng = random.Random(1)
    data[splash.REGION_END:] = bytes(rng.randrange(256) for _ in range(len(data) - splash.REGION_END))
    out = splash.build(bytes(data), [splash.encode_image(i) for i in imgs])
    return out, imgs


class SplashTest(unittest.TestCase):
    def setUp(self):
        self.data, self.imgs = synthetic()

    def test_parse_decodes_every_frame(self):
        frames = splash.parse(self.data)
        for blob, img in zip(frames, self.imgs):
            self.assertEqual(splash.frame_image(blob).tobytes(), img.tobytes())

    def test_same_logo_round_trips_byte_for_byte(self):
        self.assertEqual(splash.replace_logo(self.data, self.imgs[0]), self.data)

    def test_new_logo_changes_only_frame_0(self):
        logo = solid((0, 0, 0))
        logo.paste((10, 200, 30), (100, 100, 620, 400))
        out = splash.replace_logo(self.data, logo)
        old, new = splash.parse(self.data), splash.parse(out)
        self.assertEqual(splash.frame_image(new[0]).tobytes(), logo.tobytes())
        self.assertEqual(new[1:], old[1:])
        self.assertEqual(out[:splash.TABLE_OFF], self.data[:splash.TABLE_OFF])
        self.assertEqual(out[splash.REGION_END:], self.data[splash.REGION_END:])
        self.assertEqual(len(out), len(self.data))

    def test_logo_too_big_to_fit_is_refused(self):
        rng = random.Random(2)
        noise = Image.frombytes("RGB", (W, H), bytes(rng.randrange(256) for _ in range(W * H * 3)))
        with self.assertRaisesRegex(splash.SplashError, "past 0x20000"):
            splash.replace_logo(self.data, noise)

    def test_rejects_non_splash(self):
        with self.assertRaisesRegex(splash.SplashError, "magic"):
            splash.parse(bytes(0x40000))
        bad = bytearray(self.data)
        struct.pack_into("<I", bad, 8, 1080)
        with self.assertRaisesRegex(splash.SplashError, "1080x1280"):
            splash.parse(bytes(bad))

    def test_fit_centres_a_small_logo_on_black(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "small.png")
            Image.new("RGBA", (100, 50), (255, 255, 255, 255)).save(path)
            with self.assertRaisesRegex(splash.SplashError, "--fit"):
                splash.load_logo(path, fit=False)
            img = splash.load_logo(path, fit=True)
        self.assertEqual(img.size, (W, H))
        self.assertEqual(img.getpixel((0, 0)), (0, 0, 0))
        self.assertEqual(img.getpixel((W // 2, H // 2)), (255, 255, 255))
        self.assertEqual(img.getbbox(), (310, 615, 410, 665))


@unittest.skipUnless(os.environ.get("SPLASH_BIN"), "set SPLASH_BIN to a real splash backup")
class RealSplashTest(unittest.TestCase):
    def test_stock_logo_round_trips(self):
        data = open(os.environ["SPLASH_BIN"], "rb").read()
        frames = splash.parse(data)
        logo = splash.frame_image(frames[0])
        out = splash.replace_logo(data, logo)
        end = splash.TABLE_OFF + 8 + 4 * len(frames) + sum(map(len, frames))
        # Only the filler between the frames and 0x20000 may differ (0x00 or
        # 0xff depending on how the unit was flashed at the factory).
        self.assertEqual(out[:end], data[:end])
        self.assertEqual(out[splash.REGION_END:], data[splash.REGION_END:])
        self.assertEqual(zlib.decompress(splash.parse(out)[0]), logo.tobytes("raw", "BGR"))


if __name__ == "__main__":
    unittest.main()
