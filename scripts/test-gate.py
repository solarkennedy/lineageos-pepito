#!/usr/bin/env python3
"""test-gate.py — are the integration tests green for the source we are about to release?

The chain:
  1. build-lineage24-remotely.sh stamps every build (scripts/source-id.py stamp) and
     files the stamp in ~/.local/share/pepito/build-stamps/;
  2. a run of tests/integration matches the phone's build (ro.build.date.utc +
     kernel UTS_VERSION) to its stamp and writes results/<run>/summary.json with
     that source id and every test's outcome;
  3. this script computes the source the next build would get (manifest projects at
     their pushed fork tips, everything else as checked out on the builder) and
     looks for summaries with that source id.

Which tests: the release's test plan (scripts/test_plan.py) — the coverage.toml
`always` set, the groups whose paths changed since the last release, and whatever
the release-sweep skill added or waived after reading the changelog. Green = every
required test PASSED in the most recent run (for this source id) that did not skip
it, and every manual check in the plan is done. Runs on any unit and either flavor
count; the report says which.

  test-gate.py                       # gate the pushed source; exit 0 green, 1 not, 2 error
  test-gate.py --source-id ID        # gate a known id (e.g. the stamp of a fresh build)
  test-gate.py --report              # informational (release sweep): exit 0 unless error
  test-gate.py --id-file F           # also write the gated source id to F (release-all.sh)
  test-gate.py --file-stamp STAMP    # file a fresh build stamp in the ledger, print its id
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_plan  # noqa: E402

LANDING_ROOT = Path(os.environ.get("LANDING_ROOT", "/home/kyle/Projects/lineageos-pepito-24"))
TARGET = os.environ.get("TARGET", "10.0.2.43")
REMOTE_TREE = os.environ.get("REMOTE_TREE", "~/android/lineage-24")
STAMPS_DIR = Path(os.environ.get("PEPITO_BUILD_STAMPS",
                                 Path.home() / ".local/share/pepito/build-stamps"))
RESULTS = LANDING_ROOT / "tests/integration/results"

G, Y, R, B, D, X = "\033[32m", "\033[33m", "\033[31m", "\033[1m", "\033[2m", "\033[0m"


def pushed_source():
    return test_plan.on_builder("pushed")


def load_runs():
    runs = []
    for f in RESULTS.glob("*/summary.json"):
        try:
            s = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        s["_file"] = f
        runs.append(s)
    return sorted(runs, key=lambda s: s["finished"])


def required_tests(path):
    return [l.split("#")[0].strip() for l in path.read_text().splitlines()
            if l.split("#")[0].strip()]


def verdict(runs, required):
    """test -> (outcome, run) from the latest run that did not skip it."""
    out = {}
    for t in required:
        for run in reversed(runs):
            o = run["tests"].get(t)
            if o and o != "skipped":
                out[t] = (o, run)
                break
        else:
            last = next((r for r in reversed(runs) if t in r["tests"]), None)
            out[t] = ("skipped" if last else "not run", last)
    return out


def stamp_projects(run):
    try:
        return json.loads(Path(run["stamp"]).read_text())["projects"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def file_stamp(path):
    """Copy a build stamp into the ledger under <date_utc>-<kernel hash>.json, the
    key a phone running that build reports back."""
    s = json.loads(Path(path).read_text())
    b = s.get("build") or {}
    if not b.get("date_utc") or not b.get("kernel_uts"):
        print(f"test-gate: {path} has no build date/kernel (no build.prop or compile.h in out/?)",
              file=sys.stderr)
        return 2
    STAMPS_DIR.mkdir(parents=True, exist_ok=True)
    dest = STAMPS_DIR / f"{b['date_utc']}-{hashlib.sha1(b['kernel_uts'].encode()).hexdigest()[:8]}.json"
    dest.write_text(json.dumps(s, indent=1) + "\n")
    print(s["source_id"])
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-id")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--id-file", type=Path)
    ap.add_argument("--file-stamp", metavar="STAMP")
    ap.add_argument("--required", type=Path,
                    help="file listing required tests, instead of the release's test plan")
    a = ap.parse_args()
    if a.file_stamp:
        return file_stamp(a.file_stamp)

    current_projects = {}
    if a.source_id:
        sid = a.source_id
        print(f"{B}integration tests{X} for source {sid}")
    else:
        try:
            cur = pushed_source()
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f"{R}test-gate: could not compute the pushed source on {TARGET}: {e}{X}", file=sys.stderr)
            return 2
        sid, current_projects = cur["source_id"], cur["projects"]
        print(f"{B}integration tests{X} for the pushed source {sid}")
        for k in ("missing", "unresolved"):
            if cur.get(k):
                print(f"  {Y}● {k} on the builder: {' '.join(cur[k])}{X}")

    if a.id_file:
        a.id_file.write_text(sid + "\n")

    manual = []
    if a.required:
        required = required_tests(a.required)
    else:
        try:
            plan = test_plan.resolve(source_id=sid)
        except (subprocess.CalledProcessError, ValueError) as e:
            print(f"{R}test-gate: could not work out the test plan on {TARGET}: {e}{X}", file=sys.stderr)
            return 2
        required, manual = plan["required"], plan["plan"].data["manual"]
        pd = plan["plan"].data
        state = f"reviewed {pd['reviewed']}" if pd["reviewed"] else f"{Y}not reviewed{X}{D} (mechanical only)"
        print(f"  {D}test plan: {len(required)} tests, {len(manual)} manual checks, {state}{X}")
        if not pd["reviewed"]:
            print(f"  {D}  review it: release-sweep skill, or scripts/test_plan.py show{X}")
    all_runs = load_runs()
    runs = [r for r in all_runs if r.get("source_id") == sid and r.get("exitstatus") in (0, 1)]
    results = verdict(runs, required)
    open_manual = [m for m in manual if not m.get("done")]
    green = bool(runs) and all(o == "passed" for o, _ in results.values()) and not open_manual

    for t, (o, run) in results.items() if runs else ():
        colour = G if o == "passed" else (R if o in ("failed", "error") else Y)
        where = (f"{run['unit']} {run['build']['lineage_version']} {run['finished']}" if run else "")
        print(f"  {colour}{o:8}{X} {t}  {D}{where}{X}")
    for i, m in enumerate(manual, 1):
        print(f"  {G + 'done    ' if m.get('done') else Y + 'manual  '}{X} {i}. {m['text']}")

    if green:
        print(f"  {G}✓ green: every release-gate test passed on this source.{X}")
        return 0
    if not runs:
        print(f"  {Y}● no test run for this source.{X}")
        stamped = [r for r in all_runs if r.get("source_id")]
        if stamped:
            last = stamped[-1]
            print(f"  {D}last tested source {last['source_id']} ({last['unit']}, {last['finished']}){X}")
            if current_projects:
                old = stamp_projects(last)
                diff = [p for p in sorted(set(old) | set(current_projects))
                        if old.get(p) != current_projects.get(p)]
                for p in diff[:15]:
                    print(f"  {D}  {p}: {(old.get(p) or '-')[:12]} -> {(current_projects.get(p) or '-')[:12]}{X}")
                if len(diff) > 15:
                    print(f"  {D}  ... {len(diff) - 15} more{X}")
    else:
        print(f"  {R}✗ not green.{X}")
    todo = [t for t, (o, _) in results.items() if o != "passed"]
    if todo:
        flags = " --allow-calls" if any("call" in t for t in todo) else ""
        flags += " --allow-disruptive" if any("walkaway" in t for t in todo) else ""
        print(f"  {D}{'run the missing tests' if runs else 'flash a build of this source'}, then:{X}")
        print(f"  {D}  cd tests/integration && python3 -m pytest --unit <nick>{flags} {' '.join(todo)}{X}")
    if open_manual:
        print(f"  {D}manual checks: do them, then scripts/test_plan.py done <n>{X}")
    return 0 if a.report else 1


if __name__ == "__main__":
    sys.exit(main())
