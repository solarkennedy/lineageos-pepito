# SPDX-License-Identifier: Apache-2.0
"""Read-only Firehose backup for the Palm PVG100 over a Windows QDLoader COM port.

The Windows counterpart of qdl-dump.sh: writes the same files (gpt-lun0.bin,
readback.xml, rawprogram_restore.xml, <partition>.bin) plus SHA256SUMS.txt.

qdl v2.8 can't read from this phone: the PVG100 firehose sends the sector data
*before* its XML ACK (and never sends rawmode="true"), so qdl discards the data.
This tool accepts either ordering. It only ever sends <configure> and <read>.

The phone must already be in Firehose mode (qdl has uploaded the loader once;
qdl prints "device is already in Firehose mode" on later runs).

Usage: python fh_dump.py COM10 <outdir> [--exclude userdata] [--rom-xml rawprogram0.pvg100.xml]
"""
import argparse
import hashlib
import os
import re
import struct
import sys
import time
import xml.etree.ElementTree as ET

import serial

S = 512
CHUNK_SECTORS = 131072          # 64 MiB per <read> command
STALL_SECONDS = 30


class Firehose:
    def __init__(self, port):
        self.ser = serial.Serial(port, timeout=1)
        try:
            self.ser.set_buffer_size(rx_size=4 << 20, tx_size=1 << 16)
        except Exception:
            pass
        self.buf = bytearray()

    def _fill(self):
        n = self.ser.in_waiting
        data = self.ser.read(n if n else 1)
        self.buf += data
        return len(data)

    def _wait(self, cond, what):
        last = time.monotonic()
        while not cond():
            if self._fill():
                last = time.monotonic()
            elif time.monotonic() - last > STALL_SECONDS:
                raise RuntimeError(f"timed out waiting for {what}; buffer head={bytes(self.buf[:80])!r}")

    def _strip_ws(self):
        while self.buf and self.buf[0] in b" \r\n\t\0":
            del self.buf[0]

    def _starts_xml(self):
        self._strip_ws()
        return self.buf[:5] == b"<?xml"

    def _pop_xml(self):
        """Pop one complete <?xml ...><data>...</data> document from the buffer."""
        self._wait(lambda: b"</data>" in self.buf, "end of XML document")
        end = self.buf.index(b"</data>") + len(b"</data>")
        doc = bytes(self.buf[:end]).decode("utf-8", "replace")
        del self.buf[:end]
        root = ET.fromstring(re.sub(r"^<\?xml[^>]*\?>", "", doc))
        return root

    def _handle_doc(self, root):
        """Print logs; return the response element if the doc has one."""
        resp = None
        for el in root:
            if el.tag == "log":
                print("   phone:", el.get("value"), flush=True)
            elif el.tag == "response":
                resp = el
        return resp

    def send(self, inner):
        self.ser.write(f'<?xml version="1.0"?><data>{inner}</data>'.encode())

    def wait_response(self):
        while True:
            self._wait(lambda: len(self.buf) >= 5, "XML")
            if not self._starts_xml():
                raise RuntimeError(f"expected XML, got {bytes(self.buf[:80])!r}")
            resp = self._handle_doc(self._pop_xml())
            if resp is not None:
                return resp

    def drain(self):
        time.sleep(0.5)
        while self.ser.in_waiting:
            self._fill()
            time.sleep(0.2)
        while self.buf and self._starts_xml() and b"</data>" in self.buf:
            self._handle_doc(self._pop_xml())
        if self.buf:
            print(f"   (discarding {len(self.buf)} stray bytes)")
            self.buf.clear()

    def configure(self):
        self.send('<configure MemoryName="emmc" MaxPayloadSizeToTargetInBytes="1048576" '
                  'Verbose="0" ZlpAwareHost="1" SkipStorageInit="0"/>')
        resp = self.wait_response()
        print("configure:", resp.attrib, flush=True)

    def read(self, start, count, out):
        """Read `count` sectors from `start` into file object `out`."""
        self.send(f'<read SECTOR_SIZE_IN_BYTES="{S}" num_partition_sectors="{count}" '
                  f'physical_partition_number="0" start_sector="{start}"/>')
        need = count * S
        # Before data: the phone may (standard) send ACK rawmode="true" first,
        # or (PVG100) send the raw data straight away.
        while True:
            self._wait(lambda: len(self.buf) >= 5, "read data")
            # No whitespace stripping here: sector data may begin with zeros.
            if self.buf[:5] != b"<?xml":
                break
            resp = self._handle_doc(self._pop_xml())
            if resp is None:
                continue
            if resp.get("value") != "ACK":
                raise RuntimeError(f"read NAK at sector {start}: {resp.attrib}")
            if resp.get("rawmode") == "true":
                break
            raise RuntimeError(f"ACK without data at sector {start}: {resp.attrib}")
        got = 0
        last = time.monotonic()
        while got < need:
            if not self.buf:
                if not self._fill():
                    if time.monotonic() - last > STALL_SECONDS:
                        raise RuntimeError(f"data stalled at sector {start}, {got}/{need} bytes")
                    continue
                last = time.monotonic()
            take = min(len(self.buf), need - got)
            out.write(self.buf[:take])
            del self.buf[:take]
            got += take
        resp = self.wait_response()
        if resp.get("value") != "ACK":
            raise RuntimeError(f"read finished with {resp.attrib} at sector {start}")


def parse_gpt(data):
    hdr = data[S:2 * S]
    if hdr[:8] != b"EFI PART":
        sys.exit("no GPT header at LBA 1")
    entries_lba, = struct.unpack_from("<Q", hdr, 72)
    nent, esz = struct.unpack_from("<II", hdr, 80)
    ents = data[entries_lba * S: entries_lba * S + nent * esz]
    parts = []
    for i in range(nent):
        e = ents[i * esz:(i + 1) * esz]
        if e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        name = e[56:56 + 72].decode("utf-16le").rstrip("\0")
        parts.append((name, first, last - first + 1))
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("outdir")
    ap.add_argument("--exclude", default="")
    ap.add_argument("--rom-xml", help="ROM rawprogram XML to cross-check against the phone's GPT")
    ap.add_argument("--gpt-only", action="store_true")
    a = ap.parse_args()

    out = os.path.abspath(a.outdir)
    os.makedirs(out, exist_ok=True)
    exclude = set(filter(None, a.exclude.split(",")))

    fh = Firehose(a.port)
    fh.drain()
    fh.configure()

    print("== reading GPT ==", flush=True)
    with open(os.path.join(out, "gpt-lun0.bin"), "wb") as f:
        fh.read(0, 34, f)
    parts = parse_gpt(open(os.path.join(out, "gpt-lun0.bin"), "rb").read())
    print(f"{len(parts)} partitions in GPT")

    if a.rom_xml:
        rom = {p.get("label"): p for p in ET.parse(a.rom_xml).getroot().iter("program")}
        bad = 0
        for name, start, num in parts:
            p = rom.get(name)
            if p is None:
                print(f"  NOT IN ROM XML: {name}"); bad += 1; continue
            if (int(p.get("start_sector")), int(p.get("num_partition_sectors"))) != (start, num):
                print(f"  MISMATCH {name}: phone {start}+{num}, rom {p.get('start_sector')}+{p.get('num_partition_sectors')}")
                bad += 1
        print(f"ROM XML cross-check: {'OK - every partition offset and size matches' if not bad else f'{bad} MISMATCHES'}")

    if a.gpt_only:
        return

    keep = [p for p in parts if p[0] not in exclude]
    def attrs(name, start, num):
        return (f'SECTOR_SIZE_IN_BYTES="{S}" filename="{name}.bin" label="{name}" '
                f'num_partition_sectors="{num}" physical_partition_number="0" start_sector="{start}"')
    for fname, tag in (("readback.xml", "read"), ("rawprogram_restore.xml", "program")):
        with open(os.path.join(out, fname), "w") as f:
            f.write('<?xml version="1.0" ?>\n<data>\n')
            for p in keep:
                f.write(f"  <{tag} {attrs(*p)}/>\n")
            f.write("</data>\n")

    total = sum(n for _, _, n in keep) * S
    print(f"== dumping {len(keep)} partitions, {total / 2**30:.2f} GiB ==", flush=True)
    done = 0
    t0 = time.monotonic()
    with open(os.path.join(out, "SHA256SUMS.txt"), "w") as sums:
        for name, start, num in keep:
            h = hashlib.sha256()
            path = os.path.join(out, name + ".bin")

            class Tee:
                def __init__(self, f): self.f = f
                def write(self, b): self.f.write(b); h.update(b)

            with open(path, "wb") as f:
                tee = Tee(f)
                off = 0
                while off < num:
                    n = min(CHUNK_SECTORS, num - off)
                    fh.read(start + off, n, tee)
                    off += n
            if os.path.getsize(path) != num * S:
                sys.exit(f"size mismatch for {name}")
            sums.write(f"{h.hexdigest()}  {name}.bin\n")
            sums.flush()
            done += num * S
            rate = done / max(time.monotonic() - t0, 0.001) / 2**20
            print(f"  {name:14s} {num * S / 2**20:9.1f} MiB   total {done / 2**30:5.2f}/{total / 2**30:.2f} GiB  ({rate:.1f} MiB/s)", flush=True)
    for name in sorted(exclude):
        print(f"  excluded: {name}")
    print(f"== done: {len(keep)} partitions in {out}; phone still in EDL ==")


if __name__ == "__main__":
    main()
