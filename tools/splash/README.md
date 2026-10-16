# splash

Reads the PVG100 `splash` partition and replaces its boot logo, the PALM
screen the bootloader draws before Android starts. Needs Python 3 and Pillow.

    splash.py info splash.bin                     # frames, sizes, free space
    splash.py unpack splash.bin frames/           # every frame as a PNG
    splash.py replace-logo splash.bin logo.png -o splash-new.bin [--fit]

Start from the phone's own `splash.bin`, taken by a full backup or by Back up
(advanced) in the web flasher. The output is the same size as the input, so
Flash (advanced) can write it back to `splash`. If the phone does not like
it, write the original backup back the same way. A replaced logo has booted
on a PVG100 (dut1, 2026-10-15), so aboot does not check frame 0 against
anything; keep the backup anyway.

The logo must be 720x1280. `--fit` centres an image of another size on black,
shrinking it if it is too big. Transparency is filled with black.

## Boot animation that continues from the logo

`make-bootanimation.py` takes the boot animation LineageOS builds and a stock
`splash.bin`, and writes a new `logo.png` and `bootanimation.zip`. The logo is
the stock PALM logo, in its usual place, without the "powered by Android"
footer. The animation gets a new first part that starts on exactly that screen
and fades PALM out over 30 frames (0.5 s); LineageOS's own parts then play
unchanged, placed with `trim.txt` on a full-screen canvas. The fade frames hold
only the PALM rows, because frames are decoded as they play; on dut1 every
part runs at full speed.

    make-bootanimation.py bootanimation.zip splash.bin -o out/
    splash.py replace-logo splash.bin out/logo.png -o splash-new.bin

The device tree ships the result as
`device/xiaomi/Mi8937/bootanimation/bootanimation.zip` (`TARGET_BOOTANIMATION`).
To try an animation without rebuilding, as root:
`mount --bind /data/local/tmp/b.zip /product/media/bootanimation.zip` and run
`/system/bin/bootanimation`.

`render-bootanimation.py` renders any `bootanimation.zip` to `.mp4`, `.webm`
or `.gif` the way the phone draws it (trim rectangles, linear scaling), for
previews or posting:

    render-bootanimation.py bootanimation.zip -o boot.mp4 [--hold 1.5] [--loops 2] [--scale 0.5]

## How the logo ships

The device tree carries the logo as `device/xiaomi/Mi8937/splash/splash.img`:
the first 128 KiB of the partition (header and frames, everything below
0x20000), not the whole 11 MiB. The build copies it into target-files
`RADIO/` (`Android.mk`, `add-radio-file`), and `releasetools.py` puts it in
every OTA, full and incremental, as `firmware-update/splash.img` and writes
it to `/dev/block/by-name/splash`. The rest of the partition stays as it is
on the phone. For EDL, `prepare-flash.sh` stages it as `splash.bin`, and the
release kit's `manifest.json` has `ota2raw` rebuild `splash.bin` from the zip.
qdl and the web flasher write only those 128 KiB.

To change the logo, run `replace-logo` on a stock `splash.bin` and replace
`splash.img` with the first 128 KiB of the result:

    splash.py replace-logo splash.bin logo.png -o new.bin
    head -c 131072 new.bin > device/xiaomi/Mi8937/splash/splash.img

## Size limit

The new logo has to compress to **18,457 bytes or less** (the stock one is
18,210), because the image must end before 0x20000 (see below). Light shapes
or text on black fit easily: a centred line of anti-aliased text 130 px high
comes to about 14 KB. Gradients, photos and noise do not fit. `replace-logo`
refuses a logo that is too big and says by how much.

## Format

All offsets are from the start of the partition; integers are little-endian
u32.

| Offset | Contents |
|---|---|
| 0x00 | `SPLASH!!` |
| 0x08 | width 720, height 1280 |
| 0x10 | 0x200, 216, 0xffffff06, 0x79: meaning unknown, kept as-is |
| 0x200 | frame count (5), then the end of the last frame, then each frame's offset, all relative to 0x200 |
| 0x21c | the frames, back to back |
| up to 0x20000 | filler: 0x00 on some units, 0xff on others |
| 0x20000 | leftover from an older image, kept as-is |

Each frame is a 720x1280 BGR24 bitmap (2,764,800 bytes), zlib-compressed at
level 9; Python's zlib at level 9 reproduces the stock frames byte-for-byte.
The frames are:

| # | Screen |
|---|---|
| 0 | PALM / powered by Android boot logo |
| 1 | charger prompt, 0% |
| 2 | "Warning! Entering Download mode" |
| 3, 4 | charging, 0%, with a time-to-full estimate |

The data from 0x20000 to about 0x38cc0 is a run of zlib-wrapped PNGs (digits,
a percent sign, a charging bolt). Its first PNG starts below 0x20000 where the
current frames now sit, so it reads as the tail of an older, larger splash
image that the current one was written over. It is the same on all seven units
backed up so far. The tool never touches it, which is why the frames must end
before 0x20000.

Apart from the filler, the `splash` partitions of all seven backed-up units
are identical.

## Tests

    python3 -m unittest tools/splash/test_splash.py
    SPLASH_BIN=…/dump-…/splash.bin python3 -m unittest tools/splash/test_splash.py

The tests build a synthetic splash, since the stock artwork is not ours to
commit. With `SPLASH_BIN` set they also check that putting the stock logo
back reproduces the backup byte-for-byte, filler aside.
