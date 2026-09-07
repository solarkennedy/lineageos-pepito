#!/bin/bash
# pepito-spec.sh — offline "what did this unit come with" report for a PVG100
# EDL/recovery dump directory (as produced by qdl-dump.sh, or the older
# recovery-adb dd backups).
#
# Reads only the dump; the device does not need to be attached.
#
# Usage: pepito-spec.sh <dumpdir> [--sha256]
#   --sha256   also (re)generate sha256-dump.txt over every image
#
# Writes <dumpdir>/SPEC.md and echoes it.
set -euo pipefail

die() { echo "pepito-spec: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: pepito-spec.sh <dumpdir> [--sha256]"
DIR=$(realpath "$1"); shift
DO_SHA=0
[ "${1:-}" = "--sha256" ] && DO_SHA=1
[ -d "$DIR" ] || die "no such dir: $DIR"
cd "$DIR"

# Report path: alongside the dump when writable (root-owned dumps are not), else $PWD.
tmpid=$(mktemp)
trap 'rm -f "$tmpid"' EXIT
SPEC=${SPEC_OUT:-}
if [ -z "$SPEC" ]; then
    if [ -w "$DIR" ]; then SPEC=$DIR/SPEC.md
    else SPEC=$OLDPWD/SPEC-$(basename "$DIR").md
         echo "pepito-spec: $DIR is not writable — writing $SPEC" >&2
    fi
fi

img() { # img <name> -> path of <name>.bin or <name>.img, else empty
    for e in bin img; do [ -f "$1.$e" ] && { echo "$1.$e"; return 0; }; done
    return 0
}

GPT=$(img gpt-lun0 || true)
for c in gpt-primary gpt_main0 gpt_main gpt; do [ -n "$GPT" ] || GPT=$(img "$c" || true); done

{
echo "# Unit spec — $(basename "$DIR")"
echo
echo "Generated $(date -Iseconds) by pepito-spec.sh (offline, from the dump)."
echo

echo "## Partition layout / variant"
echo
if [ -n "$GPT" ]; then
python3 - "$GPT" <<'EOF'
import struct, sys
S = 512
d = open(sys.argv[1], "rb").read()
# header at LBA1 for a full 0..33 dump; some dumps start at the header itself
off = S if d[S:S+8] == b"EFI PART" else (0 if d[:8] == b"EFI PART" else None)
if off is None:
    print("_(no GPT header found in %s)_" % sys.argv[1]); raise SystemExit
hdr = d[off:off+S]
elba, = struct.unpack_from("<Q", hdr, 72)
nent, esz = struct.unpack_from("<II", hdr, 80)
base = elba*S if off == S else S          # entries follow the header in a bare dump
ents = d[base:base+nent*esz]
rows = []
for i in range(nent):
    e = ents[i*esz:(i+1)*esz]
    if len(e) < esz or e[:16] == b"\0"*16: continue
    first, last = struct.unpack_from("<QQ", e, 32)
    name = e[56:128].decode("utf-16le").rstrip("\0")
    rows.append((len(rows)+1, name, first, last))
print("| # | name | start | sectors | size |")
print("|---|------|-------|---------|------|")
for n, name, f, l in rows:
    num = l-f+1
    print(f"| {n} | `{name}` | {f} | {num} | {num*S/2**20:.1f} MiB |")
print()
names = {r[1] for r in rows}
end = max(r[3] for r in rows)
if "fotadata" in names:
    v = ("**PVG100 (US)** — `fotadata` present. Use pvg100_firehose.elf + rawprogram0.pvg100.xml."
         + ("" if abs(end - 61071327) <= 1 else f" ⚠️ last sector {end} is not the expected ~61,071,327 — check before flashing."))
else:
    v = ("**PVG100E (international/Vodafone)** — no `fotadata` (2 GiB reclaimed into userdata). "
         "Use pvg100e_firehose.elf + rawprogram0.pvg100e.xml. ⚠️ flashing the PVG100 table here destroys modem NV.")
print("Variant verdict:", v)
print(f"\neMMC end sector {end} (~{(end+1)*S/2**30:.2f} GiB), {len(rows)} partitions.")
EOF
else
echo "_(no gpt-lun0/gpt-primary image in this dump)_"
fi
echo

echo "## Firmware chain (X.509 signing dates)"
echo
echo "| image | signer CN | notBefore | SW_SIZE |"
echo "|-------|-----------|-----------|---------|"
for p in sbl1 rpm tz devcfg aboot keymaster cmnlib cmnlib64 hyp modem dsp; do
    f=$(img "$p" || true); [ -n "$f" ] || continue
    python3 - "$f" "$p" <<'EOF'
import re, subprocess, sys
path, name = sys.argv[1], sys.argv[2]
d = open(path, "rb").read(6*1024*1024)
for m in re.finditer(b"\x30\x82", d):
    o = m.start()
    ln = int.from_bytes(d[o+2:o+4], "big") + 4
    blob = d[o:o+ln]
    if len(blob) < ln or blob[4:6] != b"\x30\x82": continue
    p = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-startdate"],
                       input=blob, capture_output=True)
    if p.returncode: continue
    out = p.stdout.decode()
    if "Attestation Cert" not in out: continue      # the leaf, not the CAs
    cn = re.search(r"CN = ([^,\n]+)", out).group(1)
    nb = re.search(r"notBefore=(.+)", out).group(1).strip()
    sw = re.search(r"OU = 05 ([0-9A-F]+) SW_SIZE", out)
    print(f"| `{name}` | {cn} | {nb} | {int(sw.group(1),16) if sw else '?'} |")
    break
EOF
done
echo
echo "Leaf CN tells the variant too: \`Pepito Attestation Cert\` = PVG100, \`PepitoVDF …\` = PVG100E."
echo

echo "## Stock build (from system.bin/build.prop)"
echo
SY=$(img system || true)
if [ -n "$SY" ] && command -v debugfs >/dev/null; then
    tmp=$(mktemp)
    if debugfs -R "dump /build.prop $tmp" "$SY" >/dev/null 2>&1 && [ -s "$tmp" ]; then
        echo '```'
        grep -E '^ro\.build\.(fingerprint|version\.incremental|version\.security_patch|date)=|^ro\.product\.model=' "$tmp" || true
        echo '```'
    else
        echo "_(could not read build.prop — system image may be ours, not stock)_"
    fi
    rm -f "$tmp"
else
    echo "_(no system image, or debugfs not installed)_"
fi
echo

echo "## Modem"
echo
M=$(img modem || true)
if [ -n "$M" ]; then
    echo '```'
    strings -n 12 "$M" | grep -oE 'MPSS\.[A-Z]+\.[0-9.]+[^ ]*' | sort -u | awk 'NR<=5'
    strings -n 12 "$M" | grep -oE 'CRMBuilds/[^ /]+' | sort -u | awk 'NR<=3'
    echo '```'
else echo "_(no modem image)_"; fi
echo

echo "## Identity (traceability partition)"
echo
T=$(img traceability || true)
if [ -n "$T" ]; then
    # The IMEI is the first 15-digit numeric string in the partition. Luhn-check it:
    # a failure means the wrong partition or a corrupt dump, not an unusual phone.
    strings -n 15 "$T" | grep -oE '^0[0-9]{14}' | head -1 > "$tmpid" 2>/dev/null || true
    python3 - "$(cat "$tmpid" 2>/dev/null)" <<'EOF'
import sys
s = sys.argv[1] if len(sys.argv) > 1 else ""
if not s:
    print("**IMEI**: _not found_ — is this really a traceability image?")
else:
    d = [int(c) for c in s][::-1]
    tot = sum(d[0::2]) + sum(sum(divmod(x * 2, 10)) for x in d[1::2])
    print(f"**IMEI**: `{s}`  (Luhn {'✅ valid' if tot % 10 == 0 else '❌ INVALID — suspect dump'})")
EOF
    sku=$(strings -n 6 "$T" | grep -oE '[A-Z0-9]NBPVG100-[A-Z0-9]+' | head -1)
    echo
    echo "**SKU**: \`${sku:-not found}\`  — the leading character tracks the production batch"
    echo "(known: \`1N\`/\`2N\` early units, \`J\`, \`K\`); an empty SKU is unusual and worth noting."
    echo
    echo "Raw traceability strings:"
    echo '```'
    strings -n 6 "$T" | awk 'NR<=10'
    echo '```'
else echo "_(no traceability image)_"; fi
echo

echo "## devinfo (dm-verity sticky state)"
echo
DI=$(img devinfo || true)
if [ -n "$DI" ]; then
    python3 - "$DI" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read(0x200)
print("magic:", d[:13].decode(errors="replace"))
b = d[0xe0]
print(f"byte 0xe0 = 0x{b:02x} → verity_mode = " +
      ("enforcing (green)" if b == 1 else "LOGGING/EIO → red 'corrupt' screen; clear from recovery with "
       "`setprop sys.powerctl 'reboot,dm-verity enforcing'`"))
print("first 0x20 bytes:", d[:0x20].hex(" "))
EOF
else echo "_(no devinfo image)_"; fi
echo

echo "## FRP block (config)"
echo
C=$(img config || true)
if [ -n "$C" ]; then
    python3 - "$C" <<'EOF'
import struct, sys
# AOSP persistent data block: 32-byte digest, then magic 0x19901873, then the FRP data length.
d = open(sys.argv[1], "rb").read()
nz = sum(1 for x in d if x)
magic, dlen = struct.unpack_from(">II", d, 32)
print(f"{len(d)} bytes, {nz} nonzero; header magic 0x{magic:08x}, FRP data length {dlen}")
if magic != 0x19901873:
    print("no valid persistent-data-block header — never written, or a different layout.")
elif dlen == 0:
    print("✅ header only, **zero-length FRP data** — no previous-owner FRP credential stored.")
else:
    print(f"⚠️ {dlen} bytes of FRP data from the previous owner — zero `config` as hygiene "
          "(see [[frp-config-partition-desync]]).")
EOF
else echo "_(no config image)_"; fi
echo

echo "## Per-unit irreplaceables present in this dump"
echo
for p in modemst1 modemst2 fsg fsc persist sec devinfo traceability tunning config misc oem keystore ssd simlock mcfg; do
    f=$(img "$p" || true)
    if [ -n "$f" ]; then printf -- "- %s ✅ (%s)\n" "$p" "$(du -h "$f" | cut -f1)"
    else printf -- "- %s ❌ MISSING\n" "$p"; fi
done
echo

if [ "$DO_SHA" = 1 ]; then
    sha256sum *.bin *.img 2>/dev/null > "$(dirname "$SPEC")/sha256-dump.txt" || true
    echo "## Checksums"
    echo
    echo "\`sha256-dump.txt\` regenerated — $(wc -l < "$(dirname "$SPEC")/sha256-dump.txt") images."
fi
} > "$SPEC"

cat "$SPEC"
