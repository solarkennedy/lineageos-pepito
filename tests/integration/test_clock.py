"""Boot clock: pepito_clockfix (Mi8937 qmux/pepito_clockfix.c, init.pepito-clockfix.rc).

The PM8937 RTC is a read-only raw counter on this platform (no allow-set-time;
stock locked it the same way because the modem shares it), so every boot starts
at "1970 + counter" until NTP or NITZ. pepito_clockfix is two init oneshots:
`save` at boot_completed and shutdown stores offset = wall - counter in
/data/vendor/time/pepito_clockfix; `restore` at post-fs-data reapplies it while
the clock still reads 1970, unless the counter went backwards (battery died).

Nothing here reboots the phone. The read-only test checks that this boot's save
left an offset consistent with the live clock; the live test forces the clock
to 1970 for about a second and starts the real `restore` service through init,
so the service's identity and SELinux domain are exercised too. It is marked
disruptive because the clock moves (a second of 1970 can blip IMS). Skips on
builds without the feature. Also guards against the earlier mistake of starting
Qualcomm's time_daemon, which resets the clock to 1970 without TimeService.
"""
import re
import time

import pytest

BIN = "/vendor/bin/pepito_clockfix"
STATE = "/data/vendor/time/pepito_clockfix"
PROP = "vendor.qmux.clockfix"
RTC_COUNTER = "/sys/class/rtc/rtc0/since_epoch"
PLAUSIBLE = 1704067200        # 2024-01-01 UTC, the binary's own threshold
OLD_1970 = 1965896            # ~22 days: what a real boot reads before the fix


@pytest.fixture
def clockfix(dut):
    if dut.sh(f"[ -x {BIN} ] && echo y || true") != "y":
        pytest.skip(f"no {BIN}: this build predates pepito_clockfix")
    return BIN


def _state(dut):
    m = re.match(r"v1 (-?\d+) (\d+) (\d+)", dut.sh(f"cat {STATE} 2>/dev/null"))
    assert m, f"{STATE} missing or unparsable: {dut.sh(f'cat {STATE} 2>&1')!r}"
    return tuple(int(x) for x in m.groups())   # offset, counter_saved, wall_saved


def test_time_daemon_not_started(dut):
    """Qualcomm's time_daemon must not run here: without the TimeService app it has
    no stored offset and imposes the raw RTC (1970) on a running system (bench 11-07)."""
    assert dut.prop("init.svc.time_daemon") in ("", "stopped"), \
        f"init.svc.time_daemon={dut.prop('init.svc.time_daemon')!r}"
    assert not dut.sh("pidof time_daemon || true"), "time_daemon process is running"


def test_clockfix_saved_offset_matches_clock(dut, clockfix):
    """Read-only. After boot_completed the save ran, left system-owned 0600 state,
    and its offset + the live RTC counter equals the live clock (within 2 min)."""
    if int(dut.sh("date +%s")) < PLAUSIBLE:
        pytest.skip("phone clock not set yet (no NTP/NITZ); nothing to compare against")
    status = dut.prop(PROP)
    assert status in ("saved", "restored"), \
        f"{PROP}={status!r}: expected the boot_completed save to have run (saved)"
    offset, counter_saved, wall_saved = _state(dut)
    meta = dut.sh(f"ls -laZ {STATE}")
    assert "system system" in meta and "vendor_time_data_file" in meta, meta
    assert meta.startswith("-rw-------"), f"state file should be 0600: {meta}"
    counter = int(dut.sh(f"cat {RTC_COUNTER}"))
    now = int(dut.sh("date +%s"))
    assert counter >= counter_saved, f"RTC counter {counter} went backwards from saved {counter_saved}"
    drift = (counter + offset) - now
    assert abs(drift) < 120, \
        f"saved offset {offset} + counter {counter} = {counter + offset}, clock says {now} (drift {drift} s)"
    assert wall_saved >= PLAUSIBLE
    log = dut.sh("logcat -d -s pepito_clockfix")
    assert "restore:" in log and "save:" in log, f"expected both oneshots in logcat:\n{log}"


@pytest.mark.disruptive
@pytest.mark.timeout(90)
def test_clockfix_restores_live(dut, clockfix):
    """Force the clock to 1970 and start the real restore service through init;
    the clock must come back to within 5 s of the host's. The clock is put back
    from the host if anything goes wrong."""
    if int(dut.sh("date +%s")) < PLAUSIBLE:
        pytest.skip("phone clock not set yet; the save would have nothing to store")
    if dut.busy_jobs():
        pytest.skip(f"someone else's capture is running: {dut.busy_jobs()}")
    try:
        # A fresh save first, so the test does not depend on when boot_completed ran.
        dut.sh("setprop ctl.start pepito_clockfix_save")
        dut.wait_for(f"getprop {PROP}", lambda out: out == "saved", timeout=10, interval=1)
        before = int(time.time())
        dut.sh(f"date @{OLD_1970} >/dev/null")
        assert int(dut.sh("date +%s")) < PLAUSIBLE, "could not move the clock to 1970"
        dut.sh("setprop ctl.start pepito_clockfix_restore")
        dut.wait_for("date +%s", lambda out: int(out) >= PLAUSIBLE, timeout=10, interval=1)
        assert dut.prop(PROP) == "restored", f"{PROP}={dut.prop(PROP)!r}"
        phone = int(dut.sh("date +%s"))
        host = int(time.time())
        assert abs(phone - host) <= 5, f"restored clock {phone} vs host {host} ({phone - host:+d} s)"
        assert (host - before) < 60
    finally:
        if int(dut.sh("date +%s")) < PLAUSIBLE:
            dut.sh(f"date @{int(time.time())} >/dev/null")
