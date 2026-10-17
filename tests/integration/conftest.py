import os
import time
from pathlib import Path

import pytest

from pepito import DEV_DIR, AdbError, Device, roster

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
    return d


@pytest.fixture(scope="session")
def run_dir(dut):
    p = HERE / "results" / f"{time.strftime('%Y%m%d-%H%M%S')}-{dut.nick}"
    p.mkdir(parents=True, exist_ok=True)
    (p / "meta.txt").write_text(f"unit {dut.nick} serial {dut.serial}\nbuild {dut.build}\n")
    return p


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
