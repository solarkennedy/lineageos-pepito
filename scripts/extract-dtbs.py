#!/usr/bin/env python3
"""Split the appended multi-DTB section of a Qualcomm zImage into individual .dtb files."""

import struct
import os
import sys

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <zImage> <output-dir>")
        sys.exit(1)

    zimage_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    data = open(zimage_path, "rb").read()
    magic = b'\xd0\x0d\xfe\xed'

    offsets, pos = [], 0
    while True:
        idx = data.find(magic, pos)
        if idx == -1:
            break
        offsets.append(idx)
        pos = idx + 1

    count = 0
    for i, off in enumerate(offsets):
        totalsize = struct.unpack('>I', data[off + 4:off + 8])[0]
        if totalsize < 128 or totalsize > 2 * 1024 * 1024:
            continue
        out_path = os.path.join(out_dir, f"dtb_{i:03d}.dtb")
        with open(out_path, "wb") as f:
            f.write(data[off:off + totalsize])
        count += 1

    print(f"Extracted {count} DTBs to {out_dir}/")

if __name__ == "__main__":
    main()
