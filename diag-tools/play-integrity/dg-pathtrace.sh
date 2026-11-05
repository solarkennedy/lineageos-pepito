#!/bin/bash
# dg-pathtrace.sh — list every path DroidGuard and the Play Store look up during
# a Play Integrity check, without attaching to them.
#
#   dg-pathtrace.sh <unit>            # run check-integrity.py inside the trace window
#   diff <(cut -f3- a.paths) <(cut -f3- b.paths)   # compare two units
#
# DroidGuard checks for being ptraced (TracerPid), so strace is out. This uses a
# kernel return probe on getname_flags() instead, which every path-based syscall
# (open, stat, access, readlink, exec) goes through; the process can't see it.
# The 4.19 kernel's `:string` fetch faults here, so the path is fetched as raw
# 64-bit words from struct filename's inline iname[] (+32) and decoded on the
# host: paths longer than 128 bytes are cut off.
#
# Needs root adb (scripts/root-phone.sh <unit>). Output goes to
# ~/android/lineage-24/integrity-checks/<utc>-<unit>-pathtrace/:
#   trace.raw      the tracefs dump
#   all.paths      tgid <TAB> process <TAB> path, every lookup in the window
#   dg.paths       sorted unique paths looked up by gms.unstable + com.android.vending
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[ $# -ge 1 ] || { sed -n 2,19p "$0"; exit 1; }
UNIT=$1
ADB=${ADB:-$UNIT-adb}
OUT=~/android/lineage-24/integrity-checks/$(date -u +%Y%m%dT%H%M%SZ)-$UNIT-pathtrace
mkdir -p "$OUT"

[ "$($ADB shell id -u | tr -d '\r')" = 0 ] || { echo "needs root adb: scripts/root-phone.sh $UNIT" >&2; exit 1; }

args=""
for i in $(seq 0 15); do args="$args w$i=+$((32 + 8 * i))(\$retval):x64"; done
T=/sys/kernel/tracing

teardown() {
    $ADB shell "cd $T; echo 0 > tracing_on; echo 0 > events/kprobes/pifpath/enable 2>/dev/null; echo > kprobe_events; echo > trace" >/dev/null 2>&1 || true
}
trap teardown EXIT

# Start DroidGuard fresh inside the window, so two units' traces both include its
# startup probes (a warm process skips them and the diff is lopsided).
$ADB shell 'for p in com.google.android.gms.unstable; do pid=$(pidof $p) && kill $pid; done; am force-stop com.android.vending; true'
sleep 2
$ADB shell "cd $T; echo 0 > tracing_on; echo > trace; echo 4096 > buffer_size_kb; echo 1 > options/record-tgid;
    echo 'r:pifpath getname_flags $args' > kprobe_events; echo 1 > events/kprobes/pifpath/enable; echo 1 > tracing_on"
echo "tracing path lookups on $UNIT; running the integrity check"
"$HERE/check-integrity.py" "$UNIT" | grep -E '^(verdict|labels|saved)' || true
$ADB shell "echo 0 > $T/tracing_on"
$ADB shell "cat $T/trace" > "$OUT/trace.raw"
# Process names for the tgids seen, taken now: DroidGuard stays up a while after a check.
$ADB shell 'ps -A -o PID,NAME' | tr -d '\r' > "$OUT/ps.txt"

python3 -I - "$OUT" <<'EOF'
import re, struct, sys, os
out = sys.argv[1]
names = {}
for line in open(os.path.join(out, "ps.txt")):
    f = line.split()
    if len(f) == 2 and f[0].isdigit():
        names[f[0]] = f[1]
rows = []
for line in open(os.path.join(out, "trace.raw"), errors="replace"):
    m = re.match(r'\s*(\S+)-(\d+)\s+\(\s*(\d+|-+)\).*?pifpath:.*?\) (w0=.*)', line)
    if not m:
        continue
    words = re.findall(r'w\d+=0x([0-9a-f]+)', m.group(4))
    raw = b''.join(struct.pack('<Q', int(w, 16)) for w in words)
    path = raw.split(b'\0', 1)[0].decode('utf-8', 'replace')
    tgid = m.group(3)
    rows.append((tgid, names.get(tgid, m.group(1)), path))
with open(os.path.join(out, "all.paths"), "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")
targets = ("com.google.android.gms.unstable", "com.android.vending")
dg = sorted({r[2] for r in rows if r[1] in targets})
with open(os.path.join(out, "dg.paths"), "w") as f:
    f.write("\n".join(dg) + "\n")
print(f"{len(rows)} lookups, {len(dg)} unique paths from {', '.join(targets)}")
EOF
echo "saved: $OUT"
