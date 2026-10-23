# Monthly upstream rebase (LineageOS 24.0)

How the pepito tree keeps up with upstream `lineage-24.0`. Run it once a month,
in the week before a release build.

## How the tree tracks upstream

The builder tree (`10.0.2.43:~/android/lineage-24`) has two kinds of project:

- **Forks**: the projects in `manifests/pepito.xml`. Each `pepito-24` branch is
  kept as *upstream + our commits*, so "how far behind" is a single number, and
  rebasing it is mechanical. `manifests/upstreams.conf` names each fork's
  upstream. `scripts/upstream.py` refuses to run if the two files disagree.
- **Everything else** (~1200 projects): upstream's own manifest. About 950
  are AOSP projects pinned to one tag (`android-17.0.0_r1` today); those move
  only when upstream changes the tag. The other ~270 follow Lineage branches
  (`lineage-24.0`, `lineage-24.0-caf-msm8953`, a few `main`).

A normal build (`build-lineage24-remotely.sh`) syncs only the forks, so
upstream can't move under a test build (upstream `01e1033` broke the build that
way on 2026-10-05). Upstream comes in only on rebase day, all at once, together
with the fork rebases. One date, one snapshot.

Since 2026-08-21 the device trees (Mi8937, mithorium-common, kernel) have had no
official maintainer, and their upstream is static. The report still checks them,
and also watches Mi-Thorium's `mithorium-common a17/master`, which has unrelated
history. Port anything from there by hand.

New AOSP code reaches 24.0 through Lineage's forks, not through new AOSP tags.
For example, the 2026-10 manifest commits swapped `external/conscrypt`,
`external/selinux`, `system/ca-certificates` and others to Lineage forks.
The full sync in step 4 is what picks those up.

## Security fixes: how they reach us

Google publishes the Android Security Bulletin monthly. LineageOS
cherry-picks its fixes onto `lineage-24.0` within days to weeks: Google-authored
commits, committed by a Lineage maintainer (Michael Bestas, mostly), spread over
whatever repos they touch (frameworks/base, Bluetooth, MediaProvider, av,
wpa_supplicant, Settings, …). Then they bump the **security patch level**
string, which lives in `vendor/lineage`
(`release/flag_values/cp2a/RELEASE_PLATFORM_SECURITY_PATCH.textproto`). In
September 2026 that was ~120 fixes on 09-10/11 and 09-19, and the string went
to `2026-09-01` on 09-11.

Those fixes reach a pepito build only through **both** halves of this runbook:
the fork rebase (`vendor/lineage` carries the string, and frameworks/base,
telephony, … carry fixes) and the full sync (Bluetooth, MediaProvider, av,
Settings, … aren't forks). Rebasing `vendor/lineage` without a full sync would
make the build *claim* a patch level whose fixes it partly lacks. Do both, or
neither.

Where it shows:

- **`upstream.py drift`** prints our vs upstream patch level, and flags how
  many Google-authored commits are waiting upstream: per fork (`⚠️ N
  Google-authored`) and across the non-fork projects. A new bulletin shows up
  as a jump in those counts, then a patch level bump in `vendor/lineage`.
- **The changelog** (below) prints the patch level of every release that took
  upstream changes, and how many Google fixes came in.

"Google-authored, committed by someone else, not us" is a heuristic. It also
catches the odd non-security Google commit Lineage picks, and it misses fixes
Lineage rewrote under its own name. The patch level string is the official
claim; the count is the evidence behind it.

## The run

All from netbook4 in this repo. `upstream.py` runs itself on the builder.

**0. Preconditions.**

- Every fork is clean and pushed (`release-sweep`).
- No build is running on the builder.
- **No release is pending**: `release.sh` needs the current `out/`, and step 4
  replaces it.

**1. Read the drift report** (read-only, about 20 s):

```bash
scripts/upstream.py drift          # -v lists every commit; --forks-only skips the upstream scan
```

Check these, in order:

- `AOSP tag … CHANGED`: a platform bump (QPR / `_rN`), not a monthly rebase.
  Stop and plan it separately (see "Platform bumps" below).
- `pepito.xml removes X, which upstream no longer has`: upstream renamed or
  forked a project we override. Fix the `remove-project` in `pepito.xml` first,
  or the sync fails.
- `Android security patch level: ours X, upstream Y`, and any `⚠️
  Google-authored` counts: a bulletin is waiting. That's the reason to do the
  run this month rather than next.
- `watch` lines: anything Mi-Thorium did that we want?
- Fork `checkout UNPUSHED/DIVERGED`: commits sit on the builder that aren't on
  the fork. Push or drop them; `rebase` skips that fork until you do.
  `stale` and `+dirty` are fine.
- The upstream-project list: anything that touches what pepito ships
  (Settings, Dialer, Bluetooth, `system/core`, `qcom-caf/*`, `vendor/apn`,
  WebView)? Note it for step 5.

**2. Dry-run the rebase.** It rebases each fork's *pushed* `pepito-24` in a
throwaway worktree under `/tmp/pepito-rebase/`, and publishes nothing:

```bash
scripts/upstream.py rebase                    # or name forks: rebase frameworks/base build/make
```

Per fork it reports `current`, `clean` or `CONFLICT`. For a clean fork it also
gives a range-diff verdict:

- `all identical`: our patches replayed unchanged.
- `N changed`: the patch text shifted. Review it with the printed `range-diff`
  command.
- `N DROPPED`: upstream already contains that commit. Confirm it really landed
  upstream and isn't lost.

Conflicts: see below.

**3. Publish:**

```bash
scripts/upstream.py rebase --push
```

`--push` does nothing unless every selected fork rebased cleanly. Per fork it:

1. tags the old head as `pepito-24-pre-YYYYMMDD`;
2. force-pushes `pepito-24` with a lease on the old head;
3. moves the builder's checkout to the new head.

Pushes go over ssh, because the builder has no https credentials.

**4. Full-sync build.** The tree you're leaving is the last release's,
recorded in `manifests/snapshots/<last release>.xml` (see Rollback):

```bash
SYNC_ALL=1 ./scripts/build-lineage24-remotely.sh
./scripts/build-lineage24-remotely.sh --gapps   # forks + upstream already synced
```

If it doesn't build: see "Build breaks" below.

**5. Test.** Flash a bench unit and run `tests/integration` (the release
gate needs it anyway). Then smoke-test what lives in the rebased forks, plus
anything step 1 flagged:

| Fork | Check |
|---|---|
| Launcher3 + `vendor/lineage` aconfig | 3-button nav: no Trebuchet crash loop |
| `vendor/lineage` aconfig | QS torch strength slider |
| `vendor/lineage` version.mk | OTA zip / build date matches the release tag (`LINEAGE_BUILD_DATE`) |
| `frameworks/base` | face unlock, QS volume slider, lock-screen charging text, FULL at the charge cap |
| LineageParts | PVG100 System Tweaks / Modem Tweaks pages open, toggles stick |
| Updater | "What's new" shows; Install dialog doesn't crash |
| recovery | boots; sideload works |
| `system/sepolicy`, `hardware/*` | `adb shell dmesg | grep avc:` no new denials; boot to home |

**6. Record it.** Add one line to `plans/PLAN-android17.md`: the date, the
behind counts per fork, the backup tag, and anything that needed hand work.

## The changelog

`release-all.sh` → `gen-changelog.sh` handles rebased forks:

- **Anchor.** Each repo is anchored on its newest `pepito-24.0-*` tag by name.
  `git describe` can't be used, because after a rebase the tag isn't an
  ancestor of HEAD.
- **Our commits.** A fork section lists only our commits that are actually new
  (`--cherry-pick`, so patches the rebase replayed drop out). What the rebase
  brought in from upstream isn't listed.
- **The upstream note.** Instead of the upstream commit lists, a release that
  took upstream changes gets:

  ```
  ### Upstream LineageOS 24.0
  - Android security patch level 2026-11-01 (was 2026-10-01)
  - 57 Android fixes from Google, cherry-picked by LineageOS (mostly the monthly security bulletin)
  - Rebased onto upstream LineageOS 24.0 as of 2026-11-08: 320 upstream commits in 14 of our repos; 61 other projects updated (412 commits), 6 of them now LineageOS forks
  ```

  Forks are counted from their previous release tag. The non-fork projects
  are compared against the previous release's
  `manifests/snapshots/<version>.xml`, which `release-all.sh` commits at
  tagging time (`scripts/upstream.py snapshot`). Lineage infra repos and other
  SoCs' CAF trees are left out. An AOSP tag change gets an extra line. A
  release that took nothing from upstream gets no note.

Upstream must not move between the changelog (step 1 of `release-all.sh`) and
the snapshot (step 4). That's why `release-all.sh` ignores `SYNC_ALL`.

## Conflicts

```bash
scripts/upstream.py rebase --keep frameworks/base     # leaves /tmp/pepito-rebase/<date>-frameworks_base mid-rebase
ssh 10.0.2.43
cd /tmp/pepito-rebase/<date>-frameworks_base
# resolve, git add, git rebase --continue, then publish it by hand:
url=ssh://git@github.com/solarkennedy/android_frameworks_base
old=$(git ls-remote $url refs/heads/pepito-24 | cut -f1)
git push $url $old:refs/tags/pepito-24-pre-$(date +%Y%m%d)
git push --force-with-lease=refs/heads/pepito-24:$old $url HEAD:refs/heads/pepito-24
cd ~/android/lineage-24/frameworks/base && git fetch pepito && git reset --keep pepito/pepito-24
git -C ~/android/lineage-24/frameworks/base worktree remove --force /tmp/pepito-rebase/<date>-frameworks_base
```

Then run `scripts/upstream.py rebase --push` again. The hand-done fork now
reports `current`, and the rest go out.

If a conflict is in code upstream rewrote (QS Compose, Launcher, biometrics),
re-port our change instead of forcing the old hunk in. The fork's commit list
is short, so `git log upstream..pepito-24` shows what to carry.

## Build breaks

If it compiled before step 4 and doesn't now, either upstream moved, or an
upstream project now expects something a fork lacks. That's rare, since the
forks were just rebased onto the same upstream. `out/error.log` names the
project.

- Fix forward in a fork: commit, push, rebuild with `SKIP_SYNC=1` or a normal
  build.
- Or put one project back to its pre-sync commit. The last release's snapshot
  lists every project's sha:
  `grep 'path="build/soong"' manifests/snapshots/<last release>.xml`, then
  `git -C build/soong checkout <sha>` on the builder. The next `SYNC_ALL=1`
  moves it forward again.

## Rollback

The non-fork projects: `manifests/snapshots/<last release>.xml` has every
project's commit, one `git checkout` per project (see "Build breaks").

Each fork's previous head is tagged `pepito-24-pre-YYYYMMDD` on the fork.
Released source also stays reachable through the `pepito-24.0-<date>` release
tags.

```bash
cd ~/android/lineage-24/<path>          # on the builder
url=ssh://git@github.com/solarkennedy/<repo>
cur=$(git ls-remote $url refs/heads/pepito-24 | cut -f1)
git fetch -q $url refs/tags/pepito-24-pre-YYYYMMDD
git push --force-with-lease=refs/heads/pepito-24:$cur $url FETCH_HEAD:refs/heads/pepito-24
git reset --keep FETCH_HEAD
```

## Platform bumps and new forks

- **AOSP tag change / Lineage 24.x**: whole-tree event. Every fork rebases
  across real platform change, and the device trees may need A17-QPR work.
  Treat it like the 23.2 → 24.0 port (`plans/PLAN-android17.md` §2–3), not this
  runbook.
- **New fork**: add the `<project>` (and its `<remove-project>`) to
  `pepito.xml`, and a line to `upstreams.conf`. Branch `pepito-24` from
  upstream `lineage-24.0` so the fork stays upstream + ours.
