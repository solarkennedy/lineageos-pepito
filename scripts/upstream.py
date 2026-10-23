#!/usr/bin/env python3
"""Track and rebase the pepito forks against upstream LineageOS 24.0.

    scripts/upstream.py drift [--forks-only] [-v]
    scripts/upstream.py rebase [--push] [--keep] [PATH...]
    scripts/upstream.py snapshot [--forks-at-tag TAG] > manifests/snapshots/YYYYMMDD.xml
    scripts/upstream.py tree-changelog --tag TAG manifests/snapshots/YYYYMMDD.xml

The runbook is REBASE.md. Upstreams come from manifests/upstreams.conf, forks
from manifests/pepito.xml.

Runs on the build server, where the only 24.0 tree is. Started anywhere else, it
copies itself and the two manifest files there and re-runs over ssh.

drift is read-only: fetches land in FETCH_HEAD and never move a branch, a
checkout or a remote-tracking ref.

rebase rebases each fork's pushed pepito-24 onto its upstream in a throwaway
worktree under /tmp and reports conflicts and changed patches. Nothing is
published without --push. With --push, and only if every selected fork rebased
cleanly, each fork gets a backup tag pepito-24-pre-YYYYMMDD on its old head and
a force-push (with lease) of pepito-24. The build tree's checkout is then moved
to the new head.

snapshot prints `repo manifest -r` of the tree: every project at its exact
commit. release-all.sh commits one per release to manifests/snapshots/.
--forks-at-tag pins the forks to a release tag instead of their checkouts
(that's how a past release's snapshot is reconstructed).

tree-changelog is the changelog's upstream note: the Android security patch
level, how many Google-authored fixes LineageOS cherry-picked in (the security
bulletin), and that we rebased. Forks are counted from their previous release
tag, the other projects from the previous release's snapshot.

"Google fixes" = commits authored @google.com but committed by someone else
(not us): how LineageOS merges the bulletin. drift counts the ones still
upstream of us.
"""

import argparse
import concurrent.futures as cf
import datetime
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import xml.etree.ElementTree as ET

TARGET = os.environ.get("TARGET", "10.0.2.43")
TREE = os.environ.get("REMOTE_ROOT", "/home/kyle/android/lineage-24")
FORK_BRANCH = "pepito-24"
MANIFEST_URL = "https://github.com/LineageOS/android"
MANIFEST_BRANCH = "lineage-24.0"
HERE = os.path.dirname(os.path.abspath(__file__))
LANDING = os.path.dirname(HERE)
WORK = "/tmp/pepito-rebase"
REPO = os.path.expanduser("~/bin/repo")
TAG_PREFIX = "pepito-24.0-"
# The Android security patch level our builds report. scripts/build-lineage24.sh
# lunches release config cp2a, and LineageOS sets the string for it in
# vendor/lineage (one of our forks), bumping it each month once that bulletin's
# fixes are merged.
SPL_REPO = "vendor/lineage"
SPL_FILE = "release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto"


def git(cwd, *args, check=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args)} in {cwd}: {r.stderr.strip()}")
    return r.stdout.rstrip() if check else r


def fetch(cwd, url, ref):
    """Fetch url ref into FETCH_HEAD only; return its sha. Callers must not
    fetch twice in one repo concurrently (FETCH_HEAD is shared)."""
    git(cwd, "fetch", "-q", "--no-tags", url, ref)
    return git(cwd, "rev-parse", "FETCH_HEAD")


def count(cwd, rng):
    return int(git(cwd, "rev-list", "--count", rng))


def push_url(url):
    # Builder has no https credential helper; pushes go over ssh.
    return re.sub(r"^https://github\.com/", "ssh://git@github.com/", url)


def spl(rev):
    """Security patch level string at a vendor/lineage revision."""
    r = git(os.path.join(TREE, SPL_REPO), "show", f"{rev}:{SPL_FILE}", check=False)
    m = re.search(r'string_value:\s*"([^"]+)"', r.stdout) if r.returncode == 0 else None
    return m.group(1) if m else "?"


_me = None


def google_fixes(d, *rng):
    """Subjects of Google-authored commits that LineageOS cherry-picked into
    rng: how the monthly Android security bulletin fixes arrive. Google's own
    commits (an AOSP tag move) and our own backports don't count."""
    global _me
    if _me is None:
        _me = git(TREE, "config", "user.email", check=False).stdout.strip()
    r = git(d, "log", "--no-merges", "--format=%ae%x09%ce%x09%s", *rng, check=False)
    out = []
    for line in r.stdout.splitlines() if r.returncode == 0 else []:
        author, committer, subject = line.split("\t", 2)
        if author.endswith("@google.com") and not committer.endswith(("@google.com", "@android.com")) \
                and committer != _me:
            out.append(subject)
    return out


# --------------------------------------------------------------------------
# config

def load_forks(manifest):
    root = ET.parse(manifest).getroot()
    remotes = {r.get("name"): r.get("fetch") for r in root.iter("remote")}
    forks = {}
    for p in root.iter("project"):
        forks[p.get("path")] = {
            "url": remotes[p.get("remote")].rstrip("/") + "/" + p.get("name"),
            "branch": p.get("revision"),
            # on our remotes = tagged each release and changelogged per repo
            "ours": p.get("remote") in ("pepito", "pepito-ssh"),
        }
    removed = [r.get("name") for r in root.iter("remove-project")]
    return forks, removed


def load_upstreams(conf):
    ups = []
    for line in open(conf):
        line = line.split("#", 1)[0].split()
        if line:
            path, mode, url, ref = line
            ups.append({"path": path, "mode": mode, "url": url, "ref": ref})
    return ups


def load_config():
    forks, removed = load_forks(os.path.join(LANDING, "manifests/pepito.xml"))
    ups = load_upstreams(os.path.join(LANDING, "manifests/upstreams.conf"))
    missing = set(forks) - {u["path"] for u in ups}
    extra = {u["path"] for u in ups} - set(forks)
    if missing or extra:
        sys.exit("manifests/upstreams.conf out of step with pepito.xml:"
                 + "".join(f"\n  no upstream line for {p}" for p in sorted(missing))
                 + "".join(f"\n  {p} is not in pepito.xml" for p in sorted(extra)))
    return forks, removed, ups


def upstream_manifest():
    """Fetch the upstream lineage-24.0 manifest; return (sha, aosp tag)."""
    mdir = os.path.join(TREE, ".repo/manifests")
    sha = fetch(mdir, MANIFEST_URL, MANIFEST_BRANCH)
    default = git(mdir, "show", f"{sha}:default.xml")
    aosp = ET.fromstring(default).find("remote[@name='aosp']").get("revision")
    return mdir, sha, aosp


# --------------------------------------------------------------------------
# drift

def checkout_state(path, pushed):
    """How the build tree's checkout of a fork relates to the pushed branch."""
    d = os.path.join(TREE, path)
    # Builds dirty some trees (vendor/lineage's spn API dump gains a newline);
    # reported, but harmless: rebases run in their own worktree.
    dirty = "+dirty" if git(d, "status", "--porcelain", "--untracked-files=no") else ""
    head = git(d, "rev-parse", "HEAD")
    if head == pushed:
        return "ok" + dirty
    if git(d, "merge-base", "--is-ancestor", head, pushed, check=False).returncode == 0:
        return "stale" + dirty  # behind the fork; next build's sync fixes it
    if git(d, "merge-base", "--is-ancestor", pushed, head, check=False).returncode == 0:
        return "UNPUSHED" + dirty
    return "DIVERGED" + dirty


def drift_project(path, lines, forks, aosp, verbose):
    """All upstream lines of one path, sequentially (shared FETCH_HEAD)."""
    d = os.path.join(TREE, path)
    out = []
    fork = forks[path]
    for u in lines:
        if u["mode"] == "none":
            out.append(f"{path:34} --        no upstream")
            continue
        ref = aosp if u["ref"] == "@aosp" else u["ref"]
        try:
            if u["mode"] == "follow":
                up = fetch(d, u["url"], ref)
                head = git(d, "rev-parse", "HEAD")
                n = count(d, f"{head}..{up}")
                out.append(f"{path:34} follow    {n} new upstream (synced by the normal build)")
                continue
            up = fetch(d, u["url"], ref)
            if u["mode"] == "watch":
                log = git(d, "log", "--since=45.days", "-n", "10",
                          "--format=      %cs %h %s", up)
                out.append(f"{path:34} watch     {u['url'].split('/')[3]} {ref}: "
                           f"{'commits in the last 45 days:' if log else 'nothing in 45 days'}")
                if log:
                    out.append(log)
                continue
            pushed = fetch(d, fork["url"], fork["branch"])
            behind, ours = count(d, f"{pushed}..{up}"), count(d, f"{up}..{pushed}")
            state = checkout_state(path, pushed)
            when = git(d, "log", "-1", "--format=%cs", up)
            flag = "BEHIND" if behind else "ok"
            fixes = len(google_fixes(d, f"{pushed}..{up}")) if behind else 0
            out.append(f"{path:34} {flag:9} {behind:3} upstream / {ours:3} ours   "
                       f"upstream tip {when}   checkout {state}"
                       + (f"   ⚠️ {fixes} Google-authored" if fixes else ""))
            if path == SPL_REPO:
                out.append(f"{'':34} Android security patch level: ours {spl(pushed)}, upstream {spl(up)}")
            if behind:
                log = git(d, "log", "--format=      %cs %h %s",
                          *([] if verbose else ["-n", "8"]), f"{pushed}..{up}")
                out.append(log + ("" if verbose or behind <= 8 else f"\n      … {behind - 8} more (-v)"))
        except RuntimeError as e:
            out.append(f"{path:34} ERROR     {e}")
    return "\n".join(out)


def upstream_behind(forks):
    """Branch-tracking upstream projects whose checkout is behind upstream,
    i.e. what SYNC_ALL=1 would move. Tag/sha pins only move with the manifest."""
    r = subprocess.run(
        [REPO, "forall", "-c",
         'echo "$REPO_PATH|$REPO_RREV|$(git rev-parse HEAD)|$(git config remote.$REPO_REMOTE.url)"'],
        cwd=TREE, capture_output=True, text=True)
    projs = []
    for line in r.stdout.splitlines():
        path, rrev, head, url = line.split("|")
        if path in forks or rrev.startswith("refs/tags/") or re.fullmatch(r"[0-9a-f]{40}", rrev):
            continue
        projs.append((path, rrev if rrev.startswith("refs/") else "refs/heads/" + rrev, head, url))

    def check(p):
        path, ref, head, url = p
        r = subprocess.run(["git", "ls-remote", url, ref], capture_output=True, text=True)
        tip = r.stdout.split()[0] if r.stdout.split() else None
        if not tip or tip == head:
            return None
        d = os.path.join(TREE, path)
        fixes = len(google_fixes(d, f"HEAD..{tip}")) if \
            git(d, "fetch", "-q", "--no-tags", url, ref, check=False).returncode == 0 else 0
        return (path, ref, fixes)

    with cf.ThreadPoolExecutor(16) as ex:
        moved = sorted(filter(None, ex.map(check, projs)))
    return len(projs), moved


def cmd_drift(args):
    forks, removed, ups = load_config()

    print(f"== Upstream manifest ({MANIFEST_URL} {MANIFEST_BRANCH})")
    mdir, msha, aosp = upstream_manifest()
    synced = git(os.path.join(TREE, "android"), "rev-parse", "HEAD")  # moves only on a full sync
    if git(mdir, "cat-file", "-e", synced, check=False).returncode == 0:
        log = git(mdir, "log", "--format=    %cs %h %s", f"{synced}..{msha}")
        print("  since the last full sync:\n" + log if log else "  no changes since the last full sync")
        synced_aosp = ET.fromstring(git(mdir, "show", f"{synced}:default.xml")) \
            .find("remote[@name='aosp']").get("revision")
    else:
        synced_aosp = "?"
    print(f"  AOSP tag: {aosp}" + ("" if aosp == synced_aosp else
          f"   ⚠️ CHANGED from {synced_aosp}: a platform bump, not a monthly rebase"))
    for name in removed:
        if git(mdir, "grep", "-q", "-F", f'name="{name}"', msha, "--", "*.xml",
               check=False).returncode:
            print(f"  ⚠️ pepito.xml removes {name}, which upstream no longer has: "
                  "repo sync will fail until the remove-project is updated")

    print("\n== Forks (pushed pepito-24 vs upstream)")
    by_path = {}
    for u in ups:
        by_path.setdefault(u["path"], []).append(u)
    with cf.ThreadPoolExecutor(6) as ex:
        for block in ex.map(lambda p: drift_project(p, by_path[p], forks, aosp, args.verbose), by_path):
            print(block)

    if args.forks_only:
        return
    print("\n== Upstream projects SYNC_ALL=1 would move (no fork)")
    total, moved = upstream_behind(forks)
    other_soc = [m for m in moved if re.search(r"caf-s[dm]\d", m[1])]
    rest = [m for m in moved if m not in other_soc]
    fixes = sum(m[2] for m in rest)
    print(f"  {len(moved)} of {total} branch-tracking projects have new commits"
          + (f"; ⚠️ {fixes} Google-authored commit{'s' * (fixes != 1)} picked by LineageOS among them"
             " (security-bulletin style)" if fixes else ""))
    for path, ref, n in rest:
        print(f"    {path:52} {ref.removeprefix('refs/heads/'):24}" + (f" {n} Google-authored" if n else ""))
    if other_soc:
        print(f"  + {len(other_soc)} on other SoCs' caf branches (not built for Mi8937)")


# --------------------------------------------------------------------------
# rebase

def range_diff(wt, old_base, old, up, new):
    """(identical, changed, dropped, added) patches between old and new series."""
    out = git(wt, "range-diff", "--no-color", f"{old_base}..{old}", f"{up}..{new}")
    marks = re.findall(r"^\s*(?:\d+|-):\s+\S+\s+([=!<>])", out, re.M)
    return [marks.count(m) for m in "=!<>"]


def rebase_one(path, u, fork, aosp, stamp, keep):
    d = os.path.join(TREE, path)
    ref = aosp if u["ref"] == "@aosp" else u["ref"]
    res = {"path": path, "url": fork["url"], "status": "?"}
    old = fetch(d, fork["url"], fork["branch"])
    up = fetch(d, u["url"], ref)
    res["old"] = old
    behind = count(d, f"{old}..{up}")
    if not behind:
        res["status"] = "current"
        return res
    state = checkout_state(path, old)
    if state.startswith(("UNPUSHED", "DIVERGED")):
        res["status"] = f"SKIPPED: build-tree checkout is {state}; push or drop its commits first"
        return res
    base = git(d, "merge-base", old, up)
    wt = os.path.join(WORK, f"{stamp}-{path.replace('/', '_')}")
    if os.path.exists(wt):
        git(d, "worktree", "remove", "--force", wt, check=False)
        shutil.rmtree(wt, ignore_errors=True)
    git(d, "worktree", "prune")
    git(d, "worktree", "add", "-q", "--detach", wt, old)
    r = git(wt, "rebase", "-q", up, check=False)
    if r.returncode:
        files = git(wt, "diff", "--name-only", "--diff-filter=U").split()
        res["status"] = "CONFLICT"
        res["detail"] = f"{behind} upstream commits; conflicts in: {' '.join(files) or '(see worktree)'}"
        if keep:
            res["detail"] += f"\n      left mid-rebase in {wt}"
        else:
            git(wt, "rebase", "--abort", check=False)
            git(d, "worktree", "remove", "--force", wt, check=False)
        return res
    new = git(wt, "rev-parse", "HEAD")
    same, changed, dropped, added = range_diff(wt, base, old, up, new)
    res.update(status="clean", new=new, wt=wt, ups=up,
               detail=f"{behind} upstream commits taken; {same + changed} ours replayed"
                      + (f", {changed} changed by the rebase (review: git -C {d} range-diff {base}..{old[:12]} {up[:12]}..{new[:12]})"
                         if changed else ", all identical")
                      + (f", {dropped} DROPPED (already upstream?)" if dropped else ""))
    return res


def publish(res, stamp):
    d = os.path.join(TREE, res["path"])
    url = push_url(res["url"])
    tag = f"{FORK_BRANCH}-pre-{stamp}"
    git(d, "push", "-q", url, f"{res['old']}:refs/tags/{tag}")
    git(d, "push", "-q", f"--force-with-lease=refs/heads/{FORK_BRANCH}:{res['old']}",
        url, f"{res['new']}:refs/heads/{FORK_BRANCH}")
    # Move the build tree's checkout too: it's often a local pepito-24 branch
    # (commits are made on the builder), which repo sync would not move past a
    # force-push on its own.
    if git(d, "symbolic-ref", "-q", "HEAD", check=False).returncode == 0:
        r = git(d, "reset", "-q", "--keep", res["new"], check=False)
    else:
        r = git(d, "checkout", "-q", "--detach", res["new"], check=False)
    if r.returncode:
        print(f"  ⚠️ {res['path']}: pushed, but the build-tree checkout did not move "
              f"(local changes in the way?): {r.stderr.strip()}")
    return tag


def cmd_rebase(args):
    forks, _, ups = load_config()
    ups = [u for u in ups if u["mode"] == "rebase" and (not args.paths or u["path"] in args.paths)]
    unknown = set(args.paths) - {u["path"] for u in ups}
    if unknown:
        sys.exit(f"not a rebase-mode fork in upstreams.conf: {' '.join(sorted(unknown))}")
    who = git(TREE, "config", "user.email", check=False).stdout.strip()
    print(f"committer: {who or '(unset!)'}")
    if not who:
        sys.exit("set git user.email on the builder first")
    _, _, aosp = upstream_manifest()
    stamp = datetime.date.today().strftime("%Y%m%d")
    os.makedirs(WORK, exist_ok=True)

    with cf.ThreadPoolExecutor(4) as ex:
        results = list(ex.map(lambda u: rebase_one(u["path"], u, forks[u["path"]], aosp,
                                                   stamp, args.keep), ups))
    for r in results:
        print(f"{r['path']:34} {r['status']}")
        if r.get("detail"):
            print(f"      {r['detail']}")

    todo = [r for r in results if r["status"] == "clean"]
    blocked = [r for r in results if r["status"] not in ("clean", "current")]
    if args.push and todo:
        if blocked:
            print(f"\n--push: nothing published; {len(blocked)} fork(s) need hand work first "
                  "(REBASE.md §Conflicts), or pass only the clean paths")
        else:
            print()
            for r in todo:
                tag = publish(r, stamp)
                print(f"pushed {r['path']}: {r['old'][:12]} -> {r['new'][:12]} (backup tag {tag})")
    elif todo:
        print("\nDry run: nothing pushed. Re-run with --push to publish.")
    for r in todo:
        if r.get("wt") and not args.keep:
            git(os.path.join(TREE, r["path"]), "worktree", "remove", "--force", r["wt"], check=False)


# --------------------------------------------------------------------------
# snapshots + the upstream changelog section

def repo_manifest():
    """`repo manifest -r`, corrected to what is checked out. repo takes the
    revisions from the checkouts but names and remotes from the latest fetched
    manifest, which a forks-only sync updates too: a project upstream moved to a
    fork would read as already switched before any full sync."""
    xml = subprocess.run([REPO, "manifest", "-r"], cwd=TREE, capture_output=True,
                         text=True, check=True).stdout
    root = ET.fromstring(xml)

    def synced_from(p):
        r = git(os.path.join(TREE, p.get("path") or p.get("name")), "config",
                "--get-regexp", r"^remote\..*\.projectname$", check=False)
        line = r.stdout.split("\n")[0].split() if r.returncode == 0 else []
        return p, line

    with cf.ThreadPoolExecutor(16) as ex:
        for p, line in ex.map(synced_from, root.iter("project")):
            if len(line) == 2 and line[1] != p.get("name"):
                remote = line[0].removeprefix("remote.").removesuffix(".projectname")
                p.set("name", line[1])
                p.set("remote", remote)
    return ET.tostring(root, encoding="unicode") + "\n"


def cmd_snapshot(args):
    xml = repo_manifest()
    if args.forks_at_tag:
        forks, _, _ = load_config()
        root = ET.fromstring(xml)
        for p in root.iter("project"):
            path = p.get("path")
            if path in forks and forks[path]["ours"]:
                d = os.path.join(TREE, path)
                tag = args.forks_at_tag
                git(d, "fetch", "-q", "--no-tags", forks[path]["url"], f"+refs/tags/{tag}:refs/tags/{tag}")
                p.set("revision", git(d, "rev-parse", f"{tag}^{{commit}}"))
        xml = ET.tostring(root, encoding="unicode") + "\n"
    sys.stdout.write(xml)


def snapshot_projects(xml):
    """({path: <project>}, AOSP tag) of a `repo manifest -r` dump."""
    root = ET.fromstring(xml)
    aosp = root.find("remote[@name='aosp']")
    tag = (aosp.get("revision") or "?").removeprefix("refs/tags/") if aosp is not None else "?"
    return {p.get("path") or p.get("name"): p for p in root.iter("project")}, tag


def fork_intake(path, u, fork, aosp):
    """What a fork took from upstream since the last release: (commits, newest
    commit date, Google fixes). None when it has no release tag yet."""
    d = os.path.join(TREE, path)
    git(d, "fetch", "-q", "--no-tags", fork["url"], f"+refs/tags/{TAG_PREFIX}*:refs/tags/{TAG_PREFIX}*",
        check=False)
    tags = git(d, "tag", "-l", f"{TAG_PREFIX}*").split()
    if not tags:
        return None
    prev = max(tags)    # YYYYMMDD sorts as text; a rebase makes it a non-ancestor
    up = fetch(d, u["url"], aosp if u["ref"] == "@aosp" else u["ref"])
    base = git(d, "merge-base", "HEAD", up)    # the upstream commit HEAD sits on
    dates = git(d, "log", "--no-merges", "--format=%cs", base, f"^{prev}").split()
    return len(dates), max(dates, default=""), len(google_fixes(d, base, f"^{prev}"))


def cmd_tree_changelog(args):
    """The changelog's upstream note: the security patch level, the Android
    fixes LineageOS brought in, and that we rebased. Silent when nothing moved."""
    forks, _, ups = load_config()
    _, _, aosp = upstream_manifest()
    rebase = [u for u in ups if u["mode"] == "rebase" and forks[u["path"]]["ours"]]
    with cf.ThreadPoolExecutor(6) as ex:
        intake = [i for i in ex.map(lambda u: fork_intake(u["path"], u, forks[u["path"]], aosp), rebase)
                  if i and i[0]]
    parts = [f"{sum(i[0] for i in intake)} upstream commits in {len(intake)} of our repos"] if intake else []
    dates = [i[1] for i in intake]
    fixes = sum(i[2] for i in intake)
    aosp_note = None

    snap = args.snapshot if os.path.isabs(args.snapshot) else os.path.join(LANDING, args.snapshot)
    if os.path.exists(snap):
        (old, old_aosp), (new, new_aosp) = snapshot_projects(open(snap).read()), snapshot_projects(repo_manifest())

        def shipped(path):
            # Lineage infra repos and other SoCs' CAF trees never reach a Mi8937 build.
            p = new.get(path) if path in new else old[path]
            return not path.startswith("lineage/") and \
                not re.search(r"caf-s[dm]\d", p.get("upstream", "") or p.get("revision", ""))

        # Our repos are counted above; everything else (incl. FaceUnlock, taken
        # straight from crDroid) is counted here.
        ours = {p for p, f in forks.items() if f["ours"]}
        paths = [p for p in sorted(set(old) | set(new)) if p not in ours and shipped(p)]
        moved = [p for p in paths if p in old and p in new
                 and old[p].get("revision") != new[p].get("revision")]
        switched = [p for p in moved if old[p].get("name") != new[p].get("name")]

        def info(path):
            d = os.path.join(TREE, path)
            rng = f"{old[path].get('revision')}..{new[path].get('revision')}"
            r = git(d, "rev-list", "--count", "--no-merges", rng, check=False)
            return (int(r.stdout) if r.returncode == 0 else 0,
                    git(d, "log", "-1", "--format=%cs", new[path].get("revision"), check=False).stdout.strip(),
                    len(google_fixes(d, rng)))

        with cf.ThreadPoolExecutor(16) as ex:
            infos = list(ex.map(info, moved))
        if moved:
            n, c = len(moved), sum(i[0] for i in infos)
            parts.append(f"{n} other project{'s' * (n != 1)} updated ({c} commit{'s' * (c != 1)})"
                         + (f", {len(switched)} of them now LineageOS forks" if switched else ""))
            dates += [i[1] for i in infos if i[1]]
            fixes += sum(i[2] for i in infos)
        if old_aosp != new_aosp:
            aosp_note = f"- AOSP base moved to {new_aosp} (was {old_aosp})"
    elif intake:
        parts.append(f"(no snapshot of {args.tag}: other upstream projects not counted)")

    old_spl, new_spl = spl(args.tag), spl("HEAD")
    if not parts and old_spl == new_spl:
        return
    print("### Upstream LineageOS 24.0")
    print(f"- Android security patch level {new_spl}"
          + (f" (was {old_spl})" if old_spl != new_spl else " (unchanged)"))
    if fixes:
        print(f"- {fixes} Android fix{'es' * (fixes != 1)} from Google, cherry-picked by LineageOS"
              " (mostly the monthly security bulletin)")
    if parts:
        print(f"- Rebased onto upstream LineageOS 24.0 as of {max(dates) if dates else '?'}: "
              + "; ".join(parts))
    if aosp_note:
        print(aosp_note)


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("drift", help="report how far the forks and the tree are behind upstream")
    d.add_argument("--forks-only", action="store_true", help="skip the slow upstream-project scan")
    d.add_argument("-v", "--verbose", action="store_true", help="list every upstream commit")
    r = sub.add_parser("rebase", help="rebase forks onto upstream (dry run unless --push)")
    r.add_argument("--push", action="store_true", help="publish: backup tag + force-push pepito-24")
    r.add_argument("--keep", action="store_true", help="keep worktrees (conflicts stay mid-rebase)")
    r.add_argument("paths", nargs="*", help="fork paths (default: every rebase-mode fork)")
    s = sub.add_parser("snapshot", help="print `repo manifest -r` of the tree")
    s.add_argument("--forks-at-tag", metavar="TAG", help="pin the forks to this release tag")
    t = sub.add_parser("tree-changelog", help="changelog note: security patch level, upstream intake")
    t.add_argument("--tag", required=True, help="the previous release")
    t.add_argument("snapshot", help="the previous release's snapshot (relative to the landing repo; may not exist)")
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(TREE, ".repo")):
        # Not on the builder: ship ourselves and manifests/ (pepito.xml,
        # upstreams.conf, snapshots) there and re-run. stdout passes through.
        stage = f"/tmp/pepito-upstream-{socket.gethostname()}"
        subprocess.run(["ssh", TARGET, f"mkdir -p {stage}/scripts"], check=True)
        subprocess.run(["rsync", "-a", "--delete", os.path.abspath(__file__), f"{TARGET}:{stage}/scripts/"],
                       check=True)
        subprocess.run(["rsync", "-a", "--delete", os.path.join(LANDING, "manifests/"),
                        f"{TARGET}:{stage}/manifests/"], check=True)
        sys.exit(subprocess.run(["ssh", TARGET, "python3", f"{stage}/scripts/upstream.py",
                                 *[shlex.quote(a) for a in sys.argv[1:]]]).returncode)
    {"drift": cmd_drift, "rebase": cmd_rebase, "snapshot": cmd_snapshot,
     "tree-changelog": cmd_tree_changelog}[args.cmd](args)


if __name__ == "__main__":
    main()
