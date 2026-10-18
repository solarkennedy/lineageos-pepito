#!/usr/bin/env python3
"""test_plan.py — which integration tests (and manual checks) this release needs.

Two layers, so the gate does not need the full suite every release:

  mechanical  tests/integration/coverage.toml: `always` tests, plus every group
              whose path patterns match a file changed since the last release
              (scripts/source-id.py changes). If upstream moved, every test.
  review      the release-sweep skill reads the changelog (`show`) and records
              its judgement in a plan bound to the pushed source id:
                add TEST --reason R      require a test the patterns missed
                waive TEST --reason R    drop a matched test (e.g. a comment-only change)
                manual "TEXT" --reason R a check no test covers; blocks until `done N`
                reviewed                 mark the review finished

scripts/test-gate.py requires (mechanical + added - waived) to have passed and
every manual check to be done. With no plan file it uses the mechanical layer.
Plans live in tests/integration/results/plans/<source id>.json (gitignored).

  test_plan.py show [--json]
  test_plan.py add test_wfc.py::test_call_hold --reason "touches IMS registration"
  test_plan.py done 1        # only once Kyle says he did manual check 1
"""
import argparse
import fnmatch
import json
import os
import subprocess
import sys
import time
import tomllib
from pathlib import Path

LANDING_ROOT = Path(os.environ.get("LANDING_ROOT", "/home/kyle/Projects/lineageos-pepito-24"))
TARGET = os.environ.get("TARGET", "10.0.2.43")
REMOTE_TREE = os.environ.get("REMOTE_TREE", "~/android/lineage-24")
TESTS = LANDING_ROOT / "tests/integration"
COVERAGE = TESTS / "coverage.toml"
PLANS = TESTS / "results/plans"

G, Y, R, B, D, X = "\033[32m", "\033[33m", "\033[31m", "\033[1m", "\033[2m", "\033[0m"


def on_builder(mode):
    """Run scripts/source-id.py <mode> on the builder against the LOCAL manifest."""
    tmp = f"/tmp/pepito-gate-manifest.{os.getpid()}.xml"
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", TARGET]
    subprocess.run(ssh + [f"cat > {tmp}"], input=(LANDING_ROOT / "manifests/pepito.xml").read_bytes(),
                   check=True)
    try:
        out = subprocess.run(ssh + [f"python3 - {mode} --tree {REMOTE_TREE} --manifest {tmp}"],
                             input=(LANDING_ROOT / "scripts/source-id.py").read_bytes(),
                             capture_output=True, check=True).stdout
    finally:
        subprocess.run(ssh + [f"rm -f {tmp}"])
    return json.loads(out)


def coverage():
    return tomllib.loads(COVERAGE.read_text())


def all_tests(cov):
    return sorted(set(cov.get("always", [])) | {t for g in cov.get("groups", {}).values()
                                               for t in g.get("tests", [])})


def mechanical(cov, ch):
    """test -> list of reasons, plus changed files no group covers."""
    req = {t: ["always"] for t in cov.get("always", [])}
    uncovered = []
    for proj, r in ch["projects"].items():
        for f in r.get("files") or []:
            full = f"{proj}/{f}"
            hit = False
            for name, g in cov.get("groups", {}).items():
                if any(fnmatch.fnmatchcase(full, pat) for pat in g.get("paths", [])):
                    hit = True
                    for t in g["tests"]:
                        reasons = req.setdefault(t, [])
                        if len(reasons) < 6:
                            reasons.append(f"{name}: {full}")
            if not hit:
                uncovered.append(full)
    if ch.get("upstream_moved"):
        for t in all_tests(cov):
            req.setdefault(t, []).insert(0, f"upstream moved ({len(ch['upstream_moved'])} projects)")
    return req, uncovered


class Plan:
    def __init__(self, source_id):
        self.path = PLANS / f"{source_id}.json"
        self.data = (json.loads(self.path.read_text()) if self.path.exists() else
                     {"source_id": source_id, "created": time.strftime("%Y%m%d-%H%M%S"),
                      "added": {}, "waived": {}, "manual": [], "reviewed": None})

    def save(self):
        PLANS.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=1) + "\n")

    @property
    def exists(self):
        return self.path.exists()


def resolve(cov=None, ch=None, source_id=None):
    """The full picture the gate and `show` use."""
    cov = cov or coverage()
    if source_id is None:
        source_id = on_builder("pushed")["source_id"]
    ch = ch or on_builder("changes")
    mech, uncovered = mechanical(cov, ch)
    plan = Plan(source_id)
    required = (set(mech) | set(plan.data["added"])) - set(plan.data["waived"])
    return {"source_id": source_id, "changes": ch, "mechanical": mech, "uncovered": uncovered,
            "plan": plan, "required": sorted(required)}


def known_tests():
    out = subprocess.run([sys.executable, "-m", "pytest", "--co", "-q", "-p", "no:cacheprovider"],
                         cwd=TESTS, capture_output=True, text=True).stdout
    return {l.strip() for l in out.splitlines() if "::" in l}


def show(res, as_json=False):
    ch, plan = res["changes"], res["plan"].data
    if as_json:
        print(json.dumps({k: v for k, v in res.items() if k != "plan"} | {"plan": plan}, indent=1))
        return
    print(f"{B}test plan{X} for pushed source {res['source_id']}"
          f"  {D}({'reviewed ' + plan['reviewed'] if plan['reviewed'] else 'NOT reviewed'}){X}")
    print(f"\n{B}changes since the last release{X}")
    for proj, r in ch["projects"].items():
        if r.get("missing"):
            print(f"  {R}{proj}: missing on the builder{X}")
        elif r.get("prev") is None:
            print(f"  {Y}{proj}: no previous release tag (not ours to tag?); changes unknown{X}")
        elif r.get("commits"):
            print(f"  {proj}  {D}{r['prev']}..{r['tip'][:12]}, {len(r['files'])} files{X}")
            for c in r["commits"]:
                print(f"    {c}")
    if ch.get("upstream_moved"):
        print(f"  {Y}upstream moved after the last release: {' '.join(ch['upstream_moved'][:8])} ...{X}")
    print(f"\n{B}required tests{X}")
    for t in res["required"]:
        why = res["mechanical"].get(t) or []
        if t in plan["added"]:
            why = why + [f"added: {plan['added'][t]}"]
        print(f"  {t}  {D}{'; '.join(why)}{X}")
    for t, why in plan["waived"].items():
        print(f"  {D}waived {t}: {why}{X}")
    if plan["manual"]:
        print(f"\n{B}manual checks{X}")
        for i, m in enumerate(plan["manual"], 1):
            state = f"{G}done {m['done']}{X}" if m.get("done") else f"{Y}open{X}"
            print(f"  {i}. [{state}] {m['text']}  {D}{m['reason']}{X}")
    if res["uncovered"]:
        print(f"\n{B}changed files no test covers{X} {D}(review: add a test, a manual check, or nothing){X}")
        for f in res["uncovered"][:60]:
            print(f"  {f}")
        if len(res["uncovered"]) > 60:
            print(f"  ... {len(res['uncovered']) - 60} more")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show"); s.add_argument("--json", action="store_true")
    for name in ("add", "waive"):
        s = sub.add_parser(name); s.add_argument("test"); s.add_argument("--reason", required=True)
    s = sub.add_parser("manual"); s.add_argument("text"); s.add_argument("--reason", required=True)
    s = sub.add_parser("done"); s.add_argument("n", type=int)
    sub.add_parser("reviewed")
    a = ap.parse_args()

    if a.cmd == "show":
        show(resolve(), a.json)
        return 0

    plan = Plan(on_builder("pushed")["source_id"])
    d = plan.data
    if a.cmd in ("add", "waive"):
        if a.test not in known_tests():
            sys.exit(f"test_plan: {a.test!r} is not a test in tests/integration (pytest --co)")
        d["added" if a.cmd == "add" else "waived"][a.test] = a.reason
        d["waived" if a.cmd == "add" else "added"].pop(a.test, None)
    elif a.cmd == "manual":
        d["manual"].append({"text": a.text, "reason": a.reason, "done": None})
    elif a.cmd == "done":
        if not 1 <= a.n <= len(d["manual"]):
            sys.exit(f"test_plan: no manual check {a.n}")
        d["manual"][a.n - 1]["done"] = time.strftime("%Y-%m-%d %H:%M")
    elif a.cmd == "reviewed":
        d["reviewed"] = time.strftime("%Y-%m-%d %H:%M")
    plan.save()
    print(f"plan {plan.path.name}: {a.cmd} ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
