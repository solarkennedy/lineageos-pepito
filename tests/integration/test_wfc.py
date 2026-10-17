"""Wi-Fi calling, including the "Wi-Fi preferred" TH2 steering (PLAN-android17.md,
"Bench result 2026-10-15 — WFC Wi-Fi preferred at home").

Moving parts: wfc_wlan_bridge (vendor, steers the modem's LTE threshold 2: -80
"sticky" while Wi-Fi preferred and Wi-Fi is good, stock -115 otherwise, status in
vendor.qmux.wfc_th2) and WfcBridge (system app, mirrors the sub's wfc_ims_mode
into persist.sys.pepito.wfc_mode and the framework's Wi-Fi VALIDATED verdict into
sys.pepito.wfc_wifi_ok; init copies both to vendor.qmux.*).

The read-only tests run anywhere. The call tests need a SIM with Wi-Fi calling
registered on WLAN, and the walk-away disables Wi-Fi mid-call.
"""
import re
import time
from pathlib import Path

import pytest

from pepito import DEV_DIR

WIFI_ONLY, CELLULAR_PREFERRED, WIFI_PREFERRED = 0, 1, 2
STICKY_RSSI, RELEASE_RSSI = -75, -82   # wfc_wlan_bridge hysteresis
STOCK_TH2 = -115                       # LTE above this pulls an IWLAN call to LTE at answer
CALL_ACTIVE = 2                        # TelephonyManager.CALL_STATE_OFFHOOK
DRIVER = "device/wfc-call.sh"

HOLD_S = 42          # the test line hangs up on its own ~47 s in
WALK_OFF_S = 15      # Wi-Fi off this long after dialling
SURVIVE_S = 22       # the WIFI_LOST drop lands ~20 s after link loss


def eventually(fn, timeout=10, interval=1):
    """Retry fn until it stops raising AssertionError (props settle within seconds)."""
    end = time.monotonic() + timeout
    while True:
        try:
            return fn()
        except AssertionError:
            if time.monotonic() >= end:
                raise
            time.sleep(interval)


@pytest.fixture(scope="module")
def sub(dut):
    s = dut.active_sub()
    if s is None:
        pytest.skip(f"{dut.nick} has no active SIM")
    return s


# --- read-only ---------------------------------------------------------------

def test_bridge_daemon_state(dut):
    """vendor.qmux.wfc_bridge: off (WFC off), searching (no DSD client or wlan0 down),
    feeding (priming a new association), up (primed, idle watch)."""
    assert dut.sh("pidof wfc_wlan_bridge || true"), "wfc_wlan_bridge is not running"

    def check():
        state, w = dut.prop("vendor.qmux.wfc_bridge"), dut.wifi()
        allowed = {"off", "feeding", "up"} if w["connected"] else {"off", "searching"}
        assert state in allowed, f"bridge {state!r} with Wi-Fi {w}"
    eventually(check, timeout=15)


def test_wfcbridge_app_running(dut):
    assert dut.sh("pidof org.lineageos.pepito.wfcbridge || true"), "WfcBridge app is not running"


def test_mode_mirrors_siminfo(dut, sub):
    """Regression for b82254d8: after a reboot the mirror stayed on 1 while siminfo said 2."""
    mirrored = int(dut.prop("persist.sys.pepito.wfc_mode") or -1)
    assert mirrored in (WIFI_ONLY, CELLULAR_PREFERRED, WIFI_PREFERRED)
    if sub["wfc_ims_mode"] >= 0:      # -1 = never set: WfcBridge uses the carrier default
        assert mirrored == sub["wfc_ims_mode"], f"siminfo {sub['wfc_ims_mode']} vs mirror {mirrored}"


def test_vendor_props_follow_system_props(dut):
    def check():
        p = dut.props("persist.sys.pepito.wfc_mode", "vendor.qmux.wfc_mode",
                      "sys.pepito.wfc_wifi_ok", "vendor.qmux.wfc_wifi_ok")
        assert p["vendor.qmux.wfc_mode"] == p["persist.sys.pepito.wfc_mode"], p
        assert p["vendor.qmux.wfc_wifi_ok"] == p["sys.pepito.wfc_wifi_ok"], p
    eventually(check)


def test_wifi_ok_tracks_wifi(dut):
    w = dut.wifi()
    if not w["connected"]:
        eventually(lambda: _assert_eq(dut.prop("vendor.qmux.wfc_wifi_ok"), "0"))
    else:
        # Connected but not validated (dead uplink) is legitimately 0; just require a value.
        assert dut.prop("vendor.qmux.wfc_wifi_ok") in ("0", "1")


def test_th2_state_matches_conditions(dut, sub):
    """sticky iff WFC on, mode Wi-Fi preferred/only, Wi-Fi validated and RSSI >= -75."""
    def check():
        mode = int(dut.prop("vendor.qmux.wfc_mode") or -1)
        ok = dut.prop("vendor.qmux.wfc_wifi_ok")
        w = dut.wifi()
        th2 = dut.prop("vendor.qmux.wfc_th2")
        ctx = f"th2={th2} mode={mode} wifi_ok={ok} wifi={w} wfc_enabled={sub['wfc_ims_enabled']}"
        assert th2 in ("stock", "sticky"), ctx
        if mode == CELLULAR_PREFERRED or not w["connected"] or ok != "1":
            assert th2 == "stock", ctx
        elif sub["wfc_ims_enabled"] == 1 and w["rssi"] is not None:
            if w["rssi"] >= STICKY_RSSI:
                assert th2 == "sticky", ctx
            elif w["rssi"] < RELEASE_RSSI:
                assert th2 == "stock", ctx
        return ctx
    print(eventually(check, timeout=15))


def test_bridge_reads_wlan_rssi(dut):
    """The SIOCGIWSTATS path; a hit here means it needs the /proc/net/wireless fallback."""
    log = dut.sh("logcat -d -s wfc_wlan_bridge")
    assert "no dBm RSSI" not in log


# --- calls -------------------------------------------------------------------

def _assert_eq(a, b):
    assert a == b, f"{a!r} != {b!r}"


def _num(v):
    return int(v) if re.fullmatch(r"-?\d+", v or "") else None


def run_call(dut, imsa_probe, number, artifacts, hold_s, wifi_off_s=None):
    """Push and run the on-device driver, wait for it, pull and parse its output."""
    dut.push(Path(__file__).parent / DRIVER, f"{DEV_DIR}/wfc-call.sh")
    out = f"{DEV_DIR}/run"
    args = f"{out} {number} {hold_s} {wifi_off_s or ''}"
    dut.sh(f"IMSA={imsa_probe} setsid sh {DEV_DIR}/wfc-call.sh {args} >/dev/null 2>&1 </dev/null &")
    try:
        dut.wait_for(f"cat {out}/marks 2>/dev/null || true",
                     lambda m: m.rstrip().endswith(" done"), timeout=hold_s + 90)
    finally:
        if wifi_off_s is not None:
            dut.wait_for("svc wifi enable && echo ok", lambda o: "ok" in o, timeout=120)
    for name in ("samples", "marks", "logcat"):
        dut.pull(f"{out}/{name}", artifacts / name)
    marks = {}
    for line in (artifacts / "marks").read_text().splitlines():
        t, ev = line.split(maxsplit=1)
        marks.setdefault(ev, int(t))
    samples = []
    for line in (artifacts / "samples").read_text().splitlines():
        f = line.split()
        if not f or not f[0].isdigit():
            continue
        s = dict(kv.split("=", 1) for kv in f[1:] if "=" in kv)
        samples.append({"t": int(f[0]), "cs": _num(s.get("cs")), "rat": _num(s.get("rat")),
                        "rsrp": _num(s.get("rsrp")), "th2": s.get("th2"), "wifi_ok": s.get("wifi_ok")})
    return marks, samples


def in_call(samples, start=None, end=None):
    return [s for s in samples if s["cs"] == CALL_ACTIVE
            and (start is None or s["t"] >= start) and (end is None or s["t"] <= end)]


def summary(samples):
    return "\n".join(f"{s['t']} cs={s['cs']} rat={s['rat']} rsrp={s['rsrp']} th2={s['th2']}"
                     for s in samples)


@pytest.fixture
def on_wlan(dut, sub, imsa_probe, radio_quiet):
    """A call only proves something if IMS voice starts on WLAN."""
    rat = dut.imsa(imsa_probe).get("voip_service_rat")
    if rat != 0:
        pytest.skip(f"IMS voice not on WLAN (voip_service_rat={rat})")
    return int(dut.prop("vendor.qmux.wfc_mode") or -1)


@pytest.mark.call
def test_call_hold(dut, imsa_probe, test_number, artifacts, on_wlan):
    """Wi-Fi preferred/only: the call stays on WLAN for the whole hold with LTE
    camped. Cellular preferred: stock behaviour, the call moves to LTE at answer
    when LTE is above -115."""
    marks, samples = run_call(dut, imsa_probe, test_number, artifacts, HOLD_S)
    call = in_call(samples, marks["dial"], marks["hangup"])
    print(summary(call))
    assert len(call) >= 15, "call never came up (or dropped early)"
    assert call[-1]["t"] >= marks["hangup"] - 5, "call dropped before the hang-up"

    if on_wlan in (WIFI_ONLY, WIFI_PREFERRED):
        off_wlan = [s for s in call if s["rat"] not in (0, None)]
        assert not off_wlan, f"left WLAN mid-call:\n{summary(off_wlan)}"
        assert all(s["th2"] == "sticky" for s in call), "TH2 not held sticky through the call"
    elif on_wlan == CELLULAR_PREFERRED:
        rsrp = [s["rsrp"] for s in call if s["rsrp"] is not None]
        if not rsrp or max(rsrp) <= STOCK_TH2:
            pytest.skip(f"LTE too weak for the stock handover (max RSRP {max(rsrp, default=None)})")
        assert any(s["rat"] not in (0, None) for s in call), "cellular preferred but stayed on WLAN"
    else:
        pytest.fail(f"unexpected vendor.qmux.wfc_mode {on_wlan}")


@pytest.mark.call
@pytest.mark.disruptive
def test_call_walkaway(dut, imsa_probe, test_number, artifacts, on_wlan):
    """Wi-Fi drops mid-call: TH2 goes back to stock and the call hands over to LTE
    instead of the WIFI_LOST drop ~20 s after link loss."""
    marks, samples = run_call(dut, imsa_probe, test_number, artifacts, HOLD_S, WALK_OFF_S)
    off = marks["wifi_off"]
    call = in_call(samples, marks["dial"], marks["hangup"])
    print(summary(call))
    assert in_call(samples, marks["dial"], off), "call not up when Wi-Fi went off"

    moved = [s for s in in_call(samples, off) if s["rat"] not in (0, None)]
    assert moved, "call never left WLAN after Wi-Fi went off"
    print(f"handover seen {moved[0]['t'] - off} s after Wi-Fi off")
    assert in_call(samples, off + SURVIVE_S), f"call did not survive {SURVIVE_S} s past Wi-Fi off"

    if on_wlan in (WIFI_ONLY, WIFI_PREFERRED):
        released = [s for s in samples if s["t"] >= off and s["th2"] == "stock"]
        assert released and released[0]["t"] - off <= 5, "TH2 not released within 5 s of Wi-Fi off"
    assert dut.wifi()["enabled"], "Wi-Fi was not re-enabled"
