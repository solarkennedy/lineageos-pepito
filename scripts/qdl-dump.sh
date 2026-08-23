#!/bin/bash
# qdl-dump.sh — edl-style "read all partitions" for EDL mode, using modern
# linux-msm qdl (read support). Produces, in <outdir>:
#   gpt-lun0.bin            raw MBR + GPT header + entries (sectors 0..33)
#   readback.xml            generated <read> manifest (what was dumped)
#   rawprogram_restore.xml  matching <program> manifest to reflash the dump
#   <partition>.bin         one image per GPT partition
#
# Needs the modern linux-msm qdl (with read support), not the old pepito fork.
#
# Usage: qdl-dump.sh <firehose.elf> <outdir> [--exclude name1,name2,...]
# Example (skip the ~26G empty userdata):
#   qdl-dump.sh pvg100_firehose.elf dump-gold --exclude userdata
#
# Device must already be in EDL. The device is left in EDL afterwards
# (--skip-reset); run "qdl reset" to reboot it.
set -euo pipefail

SECTOR_SIZE=512

die() { echo "qdl-dump: $*" >&2; exit 1; }

# qdl binary: $QDL override > ./qdl next to this script (release bundle) >
# local qdl-upstream build > whatever qdl is in PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${QDL:-}" ]; then
    for cand in "$SCRIPT_DIR/qdl" "$HOME/Projects/qdl-upstream/build/qdl" "$(command -v qdl || true)"; do
        [ -n "$cand" ] && [ -x "$cand" ] && QDL=$cand && break
    done
fi
[ -n "${QDL:-}" ] || die "no qdl binary found (set QDL=...)"
# Reads require modern linux-msm qdl; the old pepito-fork qdl has no read verb.
"$QDL" --help 2>&1 | grep -q "read-xml" || die "$QDL is too old (no read support) — need linux-msm qdl"

[ $# -ge 2 ] || die "usage: qdl-dump.sh <firehose.elf> <outdir> [--exclude a,b,...]"
FIREHOSE=$(realpath "$1")
OUT=$2
EXCLUDE=""
if [ $# -ge 3 ]; then
    [ "$3" = "--exclude" ] && [ $# -ge 4 ] || die "unknown argument: $3"
    EXCLUDE=$4
fi
[ -f "$FIREHOSE" ] || die "firehose not found: $FIREHOSE"

mkdir -p "$OUT"
cd "$OUT"

# GPT: protective MBR (0) + header (1) + 32 entry sectors (2..33)
echo "== reading GPT from LUN 0 =="
"$QDL" --storage emmc --skip-reset "$FIREHOSE" read 0/0+34 gpt-lun0.bin

# Parse GPT, emit readback.xml + rawprogram_restore.xml
python3 - "$EXCLUDE" <<'EOF'
import struct, sys

exclude = set(filter(None, sys.argv[1].split(",")))
S = 512
data = open("gpt-lun0.bin", "rb").read()

hdr = data[S:2*S]
assert hdr[:8] == b"EFI PART", "no GPT header at LBA 1"
entries_lba, = struct.unpack_from("<Q", hdr, 72)
nent, esz = struct.unpack_from("<II", hdr, 80)
ents = data[entries_lba*S : entries_lba*S + nent*esz]

parts, skipped = [], []
for i in range(nent):
    e = ents[i*esz:(i+1)*esz]
    if e[:16] == b"\0"*16:
        continue
    first, last = struct.unpack_from("<QQ", e, 32)
    name = e[56:56+72].decode("utf-16le").rstrip("\0")
    (skipped if name in exclude else parts).append((name, first, last - first + 1))

def attrs(name, start, num, fname):
    return (f'SECTOR_SIZE_IN_BYTES="{S}" filename="{fname}" label="{name}" '
            f'num_partition_sectors="{num}" physical_partition_number="0" '
            f'start_sector="{start}"')

with open("readback.xml", "w") as f:
    f.write("<?xml version=\"1.0\" ?>\n<data>\n")
    for name, start, num in parts:
        f.write(f'  <read {attrs(name, start, num, name + ".bin")}/>\n')
    f.write("</data>\n")

with open("rawprogram_restore.xml", "w") as f:
    f.write("<?xml version=\"1.0\" ?>\n<data>\n")
    for name, start, num in parts:
        f.write(f'  <program {attrs(name, start, num, name + ".bin")}/>\n')
    f.write("</data>\n")

total = sum(n for _, _, n in parts)
print(f"{len(parts)} partitions, {total} sectors ({total*S/2**30:.1f} GiB) to dump")
for name, start, num in skipped:
    print(f"  excluded: {name} ({num*S/2**20:.0f} MiB)")
EOF

echo "== dumping partitions =="
"$QDL" --storage emmc --skip-reset "$FIREHOSE" readback.xml

echo "== done: $(ls *.bin | wc -l) images in $OUT; device still in EDL (use 'qdl reset' to reboot) =="
