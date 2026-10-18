import json
import os
import time
from pathlib import Path

import pytest

from pepito import DEV_DIR, AdbError, Device, find_stamp, roster

HERE = Path(__file__).parent
DEFAULT_PROBES = Path.home() / "android/lineage-23/diag-tools/nas-probe"
TEST_NUMBER_FILE = Path.home() / ".config/pepito/test-number"


def pytest_addoption(parser):
    g = parser.getgroup("pepito")
    g.addoption("--unit", help="bench unit nick from units.conf (dut1, new2, ...); required")
    g.addoption("--allow-calls", action="store_true", help="run tests that place a real call")
    g.addoption("--allow-disruptive", action="store_true",
                help="run tests that toggle Wi-Fi or other radios on the unit")
    g.addoption("--dial", help="number the call tests dial (default: $PEPITO_TEST_NUMBER, "
                               "then ~/.config/pepito/test-number)")
    g.addoption("--probes", default=str(DEFAULT_PROBES),
                help="dir holding the nas-probe binaries (imsa-probe), pushed if the unit lacks them")


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "call" in item.keywords and not config.getoption("--allow-calls"):
            item.add_marker(pytest.mark.skip(reason="places a call; pass --allow-calls"))
        if "disruptive" in item.keywords and not config.getoption("--allow-disruptive"):
            item.add_marker(pytest.mark.skip(reason="toggles a radio; pass --allow-disruptive"))


@pytest.fixture(scope="session")
def dut(pytestconfig):
    nick = pytestconfig.getoption("--unit")
    if not nick:
        pytest.exit("--unit is required (there is deliberately no default phone)", 2)
    units = roster()
    if nick not in units:
        pytest.exit(f"{nick} is not in the roster ({', '.join(units)})", 2)
    d = Device(nick)
    try:
        serial = d.prop("ro.serialno")
    except AdbError as e:
        pytest.exit(str(e), 2)
    if serial != units[nick]:
        pytest.exit(f"{d.adb} answered as {serial!r}, roster says {units[nick]}", 2)
    d.ensure_root()
    d.sh(f"mkdir -p {DEV_DIR}")
    d.serial = serial
    d.build = d.prop("ro.lineage.version")
    d.identity = d.build_identity()
    pytestconfig._pepito_dut = d
    return d


def _run_dir(config, nick):
    if not hasattr(config, "_pepito_run_dir"):
        p = HERE / "results" / f"{config._pepito_started}-{nick}"
        p.mkdir(parents=True, exist_ok=True)
        config._pepito_run_dir = p
    return config._pepito_run_dir


@pytest.fixture(scope="session")
def run_dir(dut, pytestconfig):
    p = _run_dir(pytestconfig, dut.nick)
    (p / "meta.txt").write_text(f"unit {dut.nick} serial {dut.serial}\nbuild {dut.build}\n")
    return p


# --- run summary: the sentinel the release gate reads (scripts/test-gate.py) ---

_CONFIG = None  # pytest_runtest_logreport gets no config; set at session start
_RANK = {"passed": 0, "skipped": 1, "failed": 2, "error": 3}


def pytest_configure(config):
    config._pepito_started = time.strftime("%Y%m%d-%H%M%S")
    config._pepito_outcomes = {}


def pytest_runtest_logreport(report):
    # setup/teardown failures are "error"; a skip in setup is the test's outcome.
    if report.when == "call" or report.outcome != "passed":
        outcome = report.outcome if report.when == "call" or report.skipped else "error"
    else:
        return
    key = report.nodeid.split("tests/integration/")[-1]
    out = _CONFIG._pepito_outcomes
    if _RANK[outcome] >= _RANK.get(out.get(key), -1):
        out[key] = outcome


def pytest_sessionstart(session):
    global _CONFIG
    _CONFIG = session.config


def pytest_sessionfinish(session, exitstatus):
    """Write results/<run>/summary.json: which build (and, via its build stamp,
    which source id) ran which tests with what outcome. Only full outcomes count:
    a run interrupted with ^C is recorded but the gate ignores it."""
    config = session.config
    dut = getattr(config, "_pepito_dut", None)
    if dut is None or not config._pepito_outcomes:
        return
    ident = dut.identity
    stamp_file, stamp = find_stamp(ident["date_utc"], ident["kernel_uts"])
    summary = {
        "schema": 1,
        "started": config._pepito_started,
        "finished": time.strftime("%Y%m%d-%H%M%S"),
        "unit": dut.nick,
        "serial": dut.serial,
        "build": ident,
        "source_id": stamp["source_id"] if stamp else None,
        "stamp": str(stamp_file) if stamp_file else None,
        "options": {k: config.getoption(k) for k in ("--allow-calls", "--allow-disruptive")},
        "exitstatus": int(exitstatus),
        "tests": dict(sorted(config._pepito_outcomes.items())),
    }
    p = _run_dir(config, dut.nick) / "summary.json"
    p.write_text(json.dumps(summary, indent=1) + "\n")
    tr = config.pluginmanager.get_plugin("terminalreporter")
    if tr:
        sid = summary["source_id"] or "UNSTAMPED (no build stamp for this build; the release gate will ignore it)"
        tr.write_line(f"pepito: summary {p}  source {sid}")


@pytest.fixture
def artifacts(run_dir, request):
    p = run_dir / request.node.name
    p.mkdir(exist_ok=True)
    return p


@pytest.fixture(scope="session")
def imsa_probe(dut, pytestconfig):
    remote = "/data/local/tmp/imsa-probe"
    if dut.sh(f"[ -x {remote} ] && echo y || true") != "y":
        local = Path(pytestconfig.getoption("--probes")) / "imsa-probe"
        if not local.exists():
            pytest.skip(f"imsa-probe not on the unit and not at {local}")
        dut.push(local, remote)
        dut.sh(f"chmod 755 {remote}")
    return remote


@pytest.fixture(scope="session")
def test_number(pytestconfig):
    n = pytestconfig.getoption("--dial") or os.environ.get("PEPITO_TEST_NUMBER")
    if not n and TEST_NUMBER_FILE.exists():
        n = TEST_NUMBER_FILE.read_text().split()[0]
    if not n:
        pytest.skip(f"no number to dial: --dial, $PEPITO_TEST_NUMBER or {TEST_NUMBER_FILE}")
    return n


@pytest.fixture
def radio_quiet(dut):
    """Skip rather than place a call or toggle a radio under someone else's capture."""
    jobs = dut.busy_jobs()
    if jobs:
        pytest.skip(f"capture running on {dut.nick}: {jobs.split()}")
    if dut.call_state() != 0:
        pytest.skip(f"{dut.nick} is already in a call")
