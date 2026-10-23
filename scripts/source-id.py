#!/usr/bin/env python3
"""source-id.py — name the exact source a 24.0 build was (or would be) made from.

Runs ON THE BUILD SERVER, fed over ssh (the builder's mirror of this repo can be
stale, so callers pipe the local copy):

    ssh 10.0.2.43 python3 - stamp  --tree ~/android/lineage-24 < scripts/source-id.py
    ssh 10.0.2.43 python3 - pushed --tree ~/android/lineage-24 --manifest /tmp/x.xml < scripts/source-id.py

The source id is a hash over every project's commit (`repo manifest -r`), upstream
included, so a SYNC_ALL that moves upstream counts as new source. Landing-repo
commits (plans, scripts) do not count. A dirty manifest project gets "+dirty"
appended, so it can never match a clean release.

  stamp   the tree as it is checked out, plus the build in out/ (ro.build.date.utc,
          kernel UTS_VERSION) that a phone reports back. build-lineage24-remotely.sh
          runs this right after a build; the integration tests look the phone's
          build up by those two values. --backfill stamps an older build and fails
          if any project's HEAD moved after that build was made.
  pushed  the source the NEXT build would get: manifest projects at their pushed
          fork tips (git ls-remote), everything else as checked out (the default
          sync leaves upstream alone). The release test gate compares against this.
  changes what changed since the last release: per manifest project, the files and
          commits from its previous pepito-24.0-* tag to its pushed tip, plus any
          upstream project that moved after that release (scripts/test_plan.py).

Prints JSON. vendor/pepito-gapps is not git and is not covered.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PRODUCT_OUT = "out/target/product/Mi8937"


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True).stdout


def tree_projects(tree):
    out = subprocess.run([str(Path.home() / "bin/repo"), "manifest", "-r"], cwd=tree,
                         capture_output=True, text=True, check=True).stdout
    return {p.get("path") or p.get("name"): p.get("revision")
            for p in ET.fromstring(out).iter("project")}


def manifest_projects(manifest):
    return {p.get("path") or p.get("name"): p.get("revision")
            for p in ET.parse(manifest).getroot().iter("project")}


def dirty(tree, path):
    st = git(Path(tree) / path, "status", "--porcelain").splitlines()
    # Build noise sweep24.sh also discounts: the API dump appends a blank line here.
    if path == "vendor/lineage" and any(l.endswith("spn/schema/current.txt") for l in st):
        if not git(Path(tree) / path, "diff", "--ignore-blank-lines", "--", "spn/schema/current.txt"):
            st = [l for l in st if not l.endswith("spn/schema/current.txt")]
    return bool(st)


def source_id(projects, dirty_paths):
    h = hashlib.sha256("\n".join(f"{p} {r}" for p, r in sorted(projects.items())).encode())
    return h.hexdigest()[:16] + ("+dirty" if dirty_paths else "")


def pushed_tip(tree, path, rev):
    if re.fullmatch(r"[0-9a-f]{40}", rev or ""):
        return rev
    d = Path(tree) / path
    remote = git(d, "remote").split()
    if not remote:
        return None
    ref = rev if rev.startswith("refs/") else f"refs/heads/{rev}"
    out = git(d, "ls-remote", remote[0], ref).split()
    return out[0] if out else None


def build_info(tree):
    out = Path(tree) / PRODUCT_OUT
    props = {}
    bp = out / "system/build.prop"
    if bp.exists():
        for line in bp.read_text(errors="replace").splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                props[k] = v
    uts = None
    ch = out / "obj/KERNEL_OBJ/include/generated/compile.h"
    if ch.exists():
        m = re.search(r'UTS_VERSION "([^"]+)"', ch.read_text())
        uts = m.group(1) if m else None
    fp = props.get("ro.build.fingerprint", "")
    return {
        "date_utc": int(props["ro.build.date.utc"]) if "ro.build.date.utc" in props else None,
        "fingerprint": fp,
        "flavor": "gapps" if "_gapps/" in fp else "vanilla",
        "kernel_uts": uts,
    }


def changes(tree, ours, prefix):
    """Per manifest project: previous release tag, pushed tip, changed files and
    commit subjects between them. Fetches the tags and the tip's objects into the
    builder's checkout (remote-tracking data only; HEAD does not move)."""
    def one(path):
        d = tree / path
        if not (d / ".git").exists():
            return path, {"missing": True}
        remote = (git(d, "remote").split() or [None])[0]
        tip = pushed_tip(tree, path, ours[path])
        if remote:
            subprocess.run(["git", "-C", str(d), "fetch", "-q", remote,
                            f"+refs/tags/{prefix}*:refs/tags/{prefix}*"], capture_output=True)
            if tip and subprocess.run(["git", "-C", str(d), "cat-file", "-e", tip + "^{commit}"],
                                      capture_output=True).returncode:
                subprocess.run(["git", "-C", str(d), "fetch", "-q", remote, tip], capture_output=True)
        tip = tip or git(d, "rev-parse", "HEAD").strip()
        # Newest tag by name, not `describe`: a monthly upstream rebase (REBASE.md)
        # leaves the previous release tag off the fork's history. The tree diff is
        # still right (replayed patches cancel out); --cherry-pick drops replayed
        # commits from the list, leaving upstream's and our new ones.
        tags = [t for t in git(d, "tag", "-l", f"{prefix}*").split() if t]
        prev = max(tags) if tags else ""
        r = {"tip": tip, "prev": prev or None}
        if prev:
            r["files"] = git(d, "diff", "--name-only", prev, tip).split("\n")
            r["files"] = [f for f in r["files"] if f]
            r["commits"] = git(d, "log", "--no-merges", "--cherry-pick", "--right-only",
                               "--format=%h %s", f"{prev}...{tip}").splitlines()
            r["released_at"] = int(git(d, "log", "-1", "--format=%ct", prev).strip() or 0)
        return path, r

    with ThreadPoolExecutor(8) as ex:
        projects = dict(ex.map(one, sorted(ours)))
    # Upstream only moves with a SYNC_ALL build: any non-manifest project whose
    # HEAD moved after the last release counts.
    released = max((r.get("released_at", 0) for r in projects.values()), default=0)
    moved = []
    if released:
        for p in tree_projects(tree):
            if p in ours:
                continue
            m = re.search(r"HEAD@\{(\d+)\}", git(tree / p, "reflog", "-1", "--date=unix", "HEAD"))
            if m and int(m.group(1)) > released:
                moved.append(p)
    return {"projects": projects, "upstream_moved": moved, "released_at": released}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["stamp", "pushed", "changes"])
    ap.add_argument("--tag-prefix", default="pepito-24.0-")
    ap.add_argument("--tree", required=True)
    ap.add_argument("--manifest", help="local manifest (default: the tree's installed roomservice.xml)")
    ap.add_argument("--backfill", action="store_true")
    a = ap.parse_args()
    tree = Path(a.tree).expanduser()
    manifest = a.manifest or tree / ".repo/local_manifests/roomservice.xml"

    ours = manifest_projects(manifest)
    if a.mode == "changes":
        json.dump(changes(tree, ours, a.tag_prefix), sys.stdout, indent=1)
        print()
        return
    projects = tree_projects(tree)
    missing = sorted(p for p in ours if p not in projects)
    res = {"mode": a.mode, "stamped_at": int(time.time()), "missing": missing}

    if a.mode == "pushed":
        with ThreadPoolExecutor(8) as ex:
            tips = dict(zip(ours, ex.map(lambda p: pushed_tip(tree, p, ours[p]), ours)))
        res["unresolved"] = sorted(p for p, t in tips.items() if t is None)
        projects.update({p: t for p, t in tips.items() if t})
        res["dirty"] = []
    else:
        res["dirty"] = sorted(p for p in ours if p in projects and dirty(tree, p))
        res["build"] = build_info(tree)
        if a.backfill:
            built = res["build"]["date_utc"] or 0
            moved = []
            for p in projects:
                m = re.search(r"HEAD@\{(\d+)\}", git(tree / p, "reflog", "-1", "--date=unix", "HEAD"))
                if m and int(m.group(1)) > built:
                    moved.append(p)
            if moved:
                sys.exit(f"source-id: cannot backfill, HEAD moved after the build in: {' '.join(moved[:10])}")

    res["projects"] = {p: projects[p] for p in sorted(projects)}
    res["manifest_projects"] = sorted(ours)
    res["source_id"] = source_id(projects, res["dirty"] or missing)
    json.dump(res, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
