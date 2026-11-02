#!/usr/bin/env python3
"""check-abstract-impls.py - find concrete classes that would throw AbstractMethodError.

    check-abstract-impls.py --tools <out/host/linux-x86/bin> system.img
    check-abstract-impls.py --tools <out/host/linux-x86/bin> <dir of jars/apexes>
    check-abstract-impls.py ... --baseline known.txt   # ignore listed findings

Release 20261101 gapps shipped a service-connectivity.jar whose R8 run had
dropped NetworkStatsService's INetworkStatsService overrides (registerUsage-
Callback and four more). Nothing failed until system_server called one at
boot. The source was fine; only that build's output was bad, and the build
that was bench-tested was a different one.

This looks at the bits instead. It dexdumps every jar in /system/framework and
in every APEX's javalib/, then for each concrete class walks its superclasses
and interfaces (across all the jars, so a framework interface implemented in
an APEX counts) and reports every abstract method no class in the chain
implements. A chain that leaves the scanned jars (e.g. an app's own classes)
is checked as far as it is known.

Only gaps where the abstract method is declared in a different jar from the
class are reported (--all for every gap). Inside one jar R8 sees every caller,
so a method it removed there is one nothing in that jar calls; R8 leaves
unused $Stub$Proxy and shaded-library methods out routinely. Across jars it
cannot see the callers, which is how NetworkStatsService lost methods that
framework-connectivity-t calls.

Exit 0 = clean, 1 = findings (printed as `class -> Lowner;.method(proto)`),
2 = usage or tool error. Run it on a known-good build first and pass the
findings as --baseline if any are expected.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ACC_INTERFACE = 0x0200
ACC_ABSTRACT = 0x0400


class Cls:
    __slots__ = ("name", "flags", "sup", "ifaces", "methods", "src")

    def __init__(self, name, src):
        self.name, self.src = name, src
        self.flags, self.sup, self.ifaces = 0, None, []
        self.methods = {}   # "name(proto)" -> abstract?


def dexdump_classes(dexdump, jar):
    out = subprocess.run([dexdump, jar], capture_output=True, text=True,
                         errors="replace").stdout
    classes, cur, section, mname = [], None, None, None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("Class descriptor"):
            cur = Cls(s.split("'")[1], os.path.basename(jar))
            classes.append(cur)
            section = None
        elif cur is None:
            continue
        elif s.startswith("Access flags") and section is None:
            cur.flags = int(s.split(":")[1].split()[0], 16)
        elif s.startswith("Superclass"):
            cur.sup = s.split("'")[1]
        elif s.startswith("Interfaces"):
            section = "ifaces"
        elif s.startswith(("Static fields", "Instance fields", "Direct methods")):
            section = "other"
        elif s.startswith("Virtual methods"):
            section = "virtual"
        elif section == "ifaces" and s.startswith("#"):
            cur.ifaces.append(s.split("'")[1])
        elif section == "virtual" and s.startswith("name"):
            mname = s.split("'")[1]
        elif section == "virtual" and s.startswith("type") and mname:
            mname += s.split("'")[1]
        elif section == "virtual" and s.startswith("access") and mname:
            cur.methods[mname] = bool(int(s.split(":")[1].split()[0], 16) & ACC_ABSTRACT)
            mname = None
    return classes


def collect_jars(root, tools, work):
    """Every jar under root, plus the javalib jars of every (c)apex under it."""
    deapexer = os.path.join(tools, "deapexer")
    jars, apexes = [], []
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if f.endswith(".jar"):
                jars.append(p)
            elif f.endswith((".apex", ".capex")):
                apexes.append(p)
    for a in sorted(apexes):
        dest = os.path.join(work, "apex", os.path.basename(a))
        r = subprocess.run([deapexer, "--debugfs_path", os.path.join(tools, "debugfs_static"),
                            "--fsckerofs_path", os.path.join(tools, "fsck.erofs"),
                            "extract", a, dest], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"error: deapexer failed on {a}:\n{r.stderr[-2000:]}")
        jl = os.path.join(dest, "javalib")
        if os.path.isdir(jl):
            jars += [os.path.join(jl, f) for f in sorted(os.listdir(jl)) if f.endswith(".jar")]
    return jars


def extract_image(img, tools, work):
    root = os.path.join(work, "img")
    os.makedirs(root)
    debugfs = os.path.join(tools, "debugfs_static")
    # System-as-root: the tree sits under /system in the image.
    for sub in ("system/framework", "system/apex", "system/system_ext/framework",
                "system/system_ext/apex", "system/product/framework", "system/product/apex"):
        dest = os.path.join(root, sub.replace("/", "_"))
        os.makedirs(dest)
        subprocess.run([debugfs, "-R", f"rdump /{sub} {dest}", img],
                       capture_output=True, text=True)
    return root


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tools", required=True, help="out/host/linux-x86/bin (dexdump, deapexer, debugfs_static, fsck.erofs)")
    ap.add_argument("--baseline", help="file of expected findings to ignore, one per line")
    ap.add_argument("--all", action="store_true",
                    help="also report gaps where the class and the abstract method are in the same jar")
    ap.add_argument("--keep-work", action="store_true")
    ap.add_argument("target", help="raw (non-sparse) system.img, or a directory of jars/apexes")
    a = ap.parse_args()

    dexdump = os.path.join(a.tools, "dexdump")
    for t in ("dexdump", "deapexer", "debugfs_static", "fsck.erofs"):
        if not os.access(os.path.join(a.tools, t), os.X_OK):
            print(f"error: {t} not found in {a.tools}", file=sys.stderr)
            return 2

    work = tempfile.mkdtemp(prefix="abstract-impls-")
    try:
        root = a.target if os.path.isdir(a.target) else extract_image(a.target, a.tools, work)
        jars = collect_jars(root, a.tools, work)
        if not any(os.path.basename(j) == "framework.jar" for j in jars) and not os.path.isdir(a.target):
            print("error: no framework.jar found in the image (not a system image?)", file=sys.stderr)
            return 2
        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
            per_jar = list(ex.map(lambda j: dexdump_classes(dexdump, j), jars))
    finally:
        if not a.keep_work:
            shutil.rmtree(work, ignore_errors=True)

    # First definition wins, as on a classpath; the order is not meaningful
    # here beyond being stable.
    classes = {}
    for cl in per_jar:
        for c in cl:
            classes.setdefault(c.name, c)

    baseline = set()
    if a.baseline and os.path.exists(a.baseline):
        baseline = {l.strip() for l in open(a.baseline) if l.strip() and not l.startswith("#")}

    findings = []
    for c in classes.values():
        if c.flags & (ACC_INTERFACE | ACC_ABSTRACT):
            continue
        implemented, required, seen = set(), {}, set()
        stack, k = [], c
        while k is not None:                      # superclass chain first
            for m, abstract in k.methods.items():
                if abstract:
                    required.setdefault(m, k.name)
                else:
                    implemented.add(m)
            stack += k.ifaces
            k = classes.get(k.sup) if k.sup else None
        while stack:                              # then every interface, transitively
            n = stack.pop()
            if n in seen:
                continue
            seen.add(n)
            i = classes.get(n)
            if i is None:
                continue
            for m, abstract in i.methods.items():
                if abstract:
                    required.setdefault(m, i.name)
                else:
                    implemented.add(m)            # default method
            stack += i.ifaces
        for m, owner in sorted(required.items()):
            if m not in implemented and (a.all or classes[owner].src != c.src):
                f = f"{c.name} -> {owner}.{m}"
                if f not in baseline:
                    findings.append(f"{f}    [{c.src}]")

    print(f"scanned {len(jars)} jars, {len(classes)} classes", file=sys.stderr)
    for f in sorted(findings):
        print(f)
    if findings:
        print(f"{len(findings)} abstract method(s) with no implementation: these classes "
              f"throw AbstractMethodError when the method is called", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
