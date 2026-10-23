# Integration tests

pytest suite that runs against a live bench PVG100 through its `<nick>-adb`
wrapper. One file per feature:

| File | Covers |
|---|---|
| `test_wfc.py` | Wi-Fi calling, including the "Wi-Fi preferred" TH2 steering |
| `test_memory.py` | MGLRU kill switch, zram, vm tunables, lmkd props, kernel health; the `diag-tools/mglru-bench` hog and app-cycle benches against `baselines/memory.toml` |

```bash
cd tests/integration
python3 -m pytest --unit dut1                      # read-only checks only
python3 -m pytest --unit dut1 --allow-calls        # + places a real call
python3 -m pytest --unit dut1 --allow-calls --allow-disruptive   # + Wi-Fi off mid-call
python3 -m pytest --unit dut1 -k th2 -s            # one test, with its printed timeline
```

## Unattended

Every test must run with nobody at the phone or the terminal. The one-shot entry
point runs the release's test plan (or `--all`), then prints the result:

```bash
tests/integration/run-unattended.sh dut1          # the plan's tests
tests/integration/run-unattended.sh dut1 --all    # everything, benches included
```

What makes that hold, and what new tests must keep true:

- **No prompts, no waiting on a person.** stdin is closed for adb and the bench
  scripts. If a test needs the screen it takes the `awake` fixture: screen held on
  for the session (`svc power stayon`, restored after) and the keyguard unlocked
  with `android-unlock-<nick>` — **once** per session; if that fails the rest skip
  rather than retry, because wrong patterns count toward the lockout.
- **Everything is bounded.** Each test has a budget (`@pytest.mark.timeout(s)`,
  default 180 s, enforced in `conftest.py`); hitting it fails that test, kills its
  child processes, and the run carries on. `run-unattended.sh` caps the whole run.
- **Leave the phone as found.** Calls are hung up and Wi-Fi is re-enabled *and seen
  reconnected* in `finally`, even after a timeout; settings changed for a run are
  restored. With the screen off this build's Wi-Fi doesn't reconnect by itself,
  which is one reason `awake` holds it on.
- **Unmet preconditions skip, with the reason** (no SIM, IMS not on WLAN after 90 s,
  someone else's capture running, a call already up). A skipped required test keeps
  the release gate red, and the run's printed result lists it.
- Long or state-changing work that must outlive adb runs on the phone under
  `setsid` (see `device/`).

## Tiers

| Marker | What it does to the phone | Opt-in |
|---|---|---|
| (none) | getprop, dumpsys, content query, logcat -d | always runs |
| `call` | dials the test number and hangs up | `--allow-calls` |
| `disruptive` | toggles Wi-Fi (or another radio) and restores it | `--allow-disruptive` |
| `bench` | ~15 min of memory pressure: 1.2 GB hogs, apps killed and relaunched, screen held on and unlocked | `--allow-bench` |

`--unit` is required; there is no default phone. The suite checks
`ro.serialno` against `~/.config/pepito/units.conf` before touching anything,
and the call/radio tests skip if `diag_mdlog` or `strace` is running on the unit
(someone else's capture) or a call is already up.

## Setup

- The call tests dial `--dial`, else `$PEPITO_TEST_NUMBER`, else the first word
  of `~/.config/pepito/test-number`. Use a line that answers and hangs up on its
  own; the timings assume it lasts at least ~45 s.
- `imsa-probe` (reads IMS voice RAT over QMI) is pushed to `/data/local/tmp` if
  the unit lacks it, from `--probes` (default
  `~/android/lineage-23/diag-tools/nas-probe`).
- The unit is put in `adb root`.

Each run writes `results/<date>-<nick>/` (gitignored): one directory per test
with whatever it pulled (call samples, marks, logcat).

## Release gate

`scripts/release-all.sh` will not release source that hasn't passed here.

1. Every `build-lineage24-remotely.sh` build is stamped with its source id (a hash
   of every project's commit, `scripts/source-id.py`) and filed in
   `~/.local/share/pepito/build-stamps/` under the build date and kernel the phone
   will report.
2. A run writes `results/<run>/summary.json`: the unit, the phone's build, the
   source id found for it, and each test's outcome. A phone on a build that was
   never stamped (built before stamping existed, or not by
   `build-lineage24-remotely.sh`) gives
   `source_id: null`, which the gate ignores. A dirty builder tree stamps as
   `<id>+dirty`, which never matches a release.
3. `scripts/test-gate.py` hashes the source the release build will sync (manifest
   projects at their pushed tips) and wants every test in that release's test plan
   to have PASSED in the latest run on that source that did not skip it, and every
   manual check in the plan done. Runs on different units and flavors combine.

The plan (`scripts/test_plan.py show`) is not the whole suite:

- `coverage.toml`: the read-only `always` tests, plus each group whose path
  patterns match a file changed since the last `pepito-24.0-*` tag (upstream
  moved ⇒ everything);
- the release-sweep skill's review of the changelog, stored per source id in
  `results/plans/`: `add` a test the patterns missed, `waive` a matched one with a
  reason, `manual` checks for changes no test covers (`done <n>` once you've done
  them).

So the order is: push, build, flash, review the plan, run what it asks for, then
release without pushing anything else; any push to a manifest project changes the
id and starts a new plan. Landing-repo commits (plans, scripts) don't.
`python3 scripts/test-gate.py` shows where you stand; the release sweep prints the
same report.

Baselines (`baselines/*.toml`) hold the released configuration and the bench
limits, each with where its numbers came from. A deliberate change to a tuning
(a new lmkd prop, a zram size) means updating the baseline in the same commit.

When you add a test file, give it a `[groups.*]` entry in `coverage.toml` (or put
cheap read-only tests in `always`), or no release will ever require it.

## Writing tests

- Anything that has to keep running when adb drops (Wi-Fi off kills adb over
  Wi-Fi) goes in an on-device script under `device/`, started with `setsid`;
  the host side polls for a `done` mark with `Device.wait_for`.
- Properties settle over a few seconds; assert inside `eventually()` rather than
  sleeping.
- A test whose precondition isn't met on this unit (no SIM, IMS not on WLAN, LTE
  too weak) should `pytest.skip` with the reason, not fail.
- Never cycle airplane mode, flash, or reboot from a test.
- No `input()`, no "press enter", no step that needs a finger on the screen. If a
  check can't be automated yet, it isn't a test.
