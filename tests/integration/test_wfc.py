"""Wi-Fi calling, including the "Wi-Fi preferred" TH2 steering (PLAN-android17.md,
"Bench result 2026-10-15 — WFC Wi-Fi preferred at home").

Moving parts: wfc_wlan_bridge (vendor, steers the modem's LTE threshold 2: -80
"sticky" while Wi-Fi preferred and Wi-Fi is good, stock -115 otherwise, status in
vendor.qmux.wfc_th2) and WfcBridge (system app, mirrors the sub's wfc_ims_mode
into persist.sys.pepito.wfc_mode and the framework's Wi-Fi VALIDATED verdict into
sys.pepito.wfc_wifi_ok; init copies both to vendor.qmux.*).

The read-only tests run anywhere. The Wi-Fi call tests need a SIM with Wi-Fi
calling registered on WLAN, and the walk-away disables Wi-Fi mid-call. The
cellular call test is the control: a plain VoLTE call over LTE, which the Wi-Fi
tests never place (they start on WLAN and at most hand over).
"""
import re
import time
from pathlib import Path

import pytest

import twilio_call
from pepito import DEV_DIR

WIFI_ONLY, CELLULAR_PREFERRED, WIFI_PREFERRED = 0, 1, 2
STICKY_RSSI, RELEASE_RSSI = -75, -82   # wfc_wlan_bridge hysteresis
STOCK_TH2 = -115                       # LTE above this pulls an IWLAN call to LTE at answer
CALL_ACTIVE = 2                        # TelephonyManager.CALL_STATE_OFFHOOK
DRIVER = "device/wfc-call.sh"

HOLD_S = 42          # the test line hangs up on its own ~47 s in
WALK_OFF_S = 15      # Wi-Fi off this long after dialling
ON_WLAN_WAIT_S = 180  # modem t_minonwwan is 120 s; give the tunnel time after a walk-away
SURVIVE_S = 22       # the WIFI_LOST drop lands ~20 s after link loss
ON_WWAN_WAIT_S = 120  # IMS re-registers on LTE after Wi-Fi goes off
WWAN = 1             # IMSA voip_service_rat for LTE (0 = WLAN)


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


RING_S = 90          # driver waits this long for an MT call to ring
TRIAL_HOLD_S = 8     # Twilio trial calls end ~14 s in; require this much connected


def run_call(dut, imsa_probe, number, artifacts, hold_s, wifi_off_s=None, pre_wwan_s=None,
             on_armed=None, env_extra=""):
    """Push and run the on-device driver, wait for it, pull and parse its output.
    pre_wwan_s: first get IMS voice onto LTE (Wi-Fi off if needed), waiting up to
    that long; the driver marks on_wwan, or no_wwan and skips the call.
    number "-" is an MT call: on_armed() is called once the driver is waiting
    for the ring, and should make the phone ring."""
    dut.push(Path(__file__).parent / DRIVER, f"{DEV_DIR}/wfc-call.sh")
    out = f"{DEV_DIR}/run"
    args = f"{out} {number} {hold_s} {wifi_off_s or ''}"
    env = f"IMSA={imsa_probe}" + (f" PRE_WWAN={pre_wwan_s}" if pre_wwan_s else "") + env_extra
    # Clear the last run first, here, not only in the driver: the driver runs in
    # the background, so the wait below could read the previous run's marks
    # (ending "done") before the driver's own rm, return at once and pull from
    # a directory the driver is wiping (and the next test then starts a second
    # driver over a live call). 2026-11-02, dut1 + new2.
    dut.sh(f"rm -rf {out}")
    dut.sh(f"{env} RING_S={RING_S} setsid sh {DEV_DIR}/wfc-call.sh {args} >/dev/null 2>&1 </dev/null &")
    try:
        budget = hold_s + (pre_wwan_s or 0) + 90
        if on_armed:
            marks = dut.wait_for(f"cat {out}/marks 2>/dev/null || true",
                                 lambda m: " armed" in m or m.rstrip().endswith(" done"),
                                 timeout=(pre_wwan_s or 0) + 60)
            if " armed" in marks:
                on_armed()
            budget += RING_S + 30
        dut.wait_for(f"cat {out}/marks 2>/dev/null || true",
                     lambda m: m.rstrip().endswith(" done"), timeout=budget)
    finally:
        # Leave the phone as found even if the driver wedged or we timed out:
        # Wi-Fi on and back on its network, no call up.
        if wifi_off_s is not None or pre_wwan_s:
            dut.wait_for("svc wifi enable && echo ok", lambda o: "ok" in o, timeout=120)
            dut.wait_for("cmd wifi status", lambda o: "Wifi is connected" in o, timeout=120)
        dut.end_call()
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
def on_wlan(dut, sub, imsa_probe, radio_quiet, awake):
    """A call only proves something if IMS voice starts on WLAN. Waits up to
    ON_WLAN_WAIT_S for it, then skips. After a fallback to LTE (the previous
    test's walk-away) the modem's MPPM holds the ims PDN on WWAN for its
    t_minonwwan timer, 120 s on T-Mobile (F3, PLAN-android17 2026-11-01), before
    it will bring the ePDG tunnel back, so 90 s was shorter than a healthy
    phone."""
    rat = None
    for _ in range(ON_WLAN_WAIT_S // 5):
        rat = dut.imsa(imsa_probe).get("voip_service_rat")
        if rat == 0:
            return int(dut.prop("vendor.qmux.wfc_mode") or -1)
        time.sleep(5)
    pytest.skip(f"IMS voice not on WLAN after {ON_WLAN_WAIT_S} s (voip_service_rat={rat})")


@pytest.mark.call
@pytest.mark.timeout(HOLD_S + 300)
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
@pytest.mark.timeout(HOLD_S + 420)
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
        # Time the bridge from the link loss, not from `svc wifi disable`: the
        # Pronto teardown alone takes 5-6 s before wlan0 disassociates and the
        # framework drops VALIDATED (wifi_ok=0), and the ~1.5 s sampling made a
        # fixed 5 s-from-the-command budget a coin flip (dut1 + new2, 10-31).
        lost = [s for s in samples if s["t"] >= off and s["wifi_ok"] == "0"]
        assert lost and lost[0]["t"] - off <= 10, "Wi-Fi loss not visible within 10 s of Wi-Fi off"
        released = [s for s in samples if s["t"] >= off and s["th2"] == "stock"]
        assert released, "TH2 never released after Wi-Fi off"
        print(f"Wi-Fi loss seen {lost[0]['t'] - off} s after Wi-Fi off, "
              f"TH2 released {released[0]['t'] - lost[0]['t']} s after that")
        assert released[0]["t"] - lost[0]["t"] <= 3, "TH2 not released within 3 s of the Wi-Fi loss"
    assert dut.wifi()["enabled"], "Wi-Fi was not re-enabled"


def ims_failures(artifacts):
    """The framework's reason lines for a failed or dropped IMS call, for the failure message."""
    log = (artifacts / "logcat").read_text(errors="replace").splitlines()
    return "\n".join([l for l in log if "ImsReasonInfo" in l or "DisconnectCause" in l][-8:])


@pytest.mark.call
@pytest.mark.disruptive
@pytest.mark.timeout(HOLD_S + ON_WWAN_WAIT_S + 300)
def test_call_cellular(dut, sub, imsa_probe, test_number, artifacts, radio_quiet, awake):
    """A VoLTE call over LTE: connects, stays on LTE and lasts to the hang-up.
    Wi-Fi is turned off first if IMS voice is on WLAN, which puts the call where a
    phone with Wi-Fi calling off places it (US Mobile Verizon "Server error",
    2026-11-03: a SIP refusal on the LTE path, which no other test dials on)."""
    marks, samples = run_call(dut, imsa_probe, test_number, artifacts, HOLD_S,
                              pre_wwan_s=ON_WWAN_WAIT_S)
    if "no_wwan" in marks:
        pytest.skip(f"IMS voice not on LTE after {ON_WWAN_WAIT_S} s")
    call = in_call(samples, marks["dial"], marks["hangup"])
    print(summary(call))
    assert len(call) >= 15, f"call never came up (or dropped early):\n{ims_failures(artifacts)}"
    assert call[-1]["t"] >= marks["hangup"] - 5, f"call dropped before the hang-up:\n{ims_failures(artifacts)}"
    off_lte = [s for s in call if s["rat"] not in (WWAN, None)]
    assert not off_lte, f"left LTE mid-call:\n{summary(off_lte)}"
    assert dut.wifi()["enabled"], "Wi-Fi was not re-enabled"


@pytest.fixture(scope="session")
def twilio(dut):
    creds = twilio_call.load()
    if creds is None:
        pytest.skip(f"Twilio not set up ({twilio_call.CONF})")
    to = twilio_call.unit_number(dut.nick)
    if to is None:
        pytest.skip(f"no number for {dut.nick} in {twilio_call.NUMBERS}")
    return creds, to


@pytest.mark.call
@pytest.mark.timeout(HOLD_S + ON_WWAN_WAIT_S + ON_WLAN_WAIT_S + RING_S + 300)
@pytest.mark.parametrize("path", [
    "wlan",
    pytest.param("lte", marks=pytest.mark.disruptive),
])
def test_call_incoming(dut, sub, imsa_probe, twilio, artifacts, radio_quiet, awake, request, path):
    """An MT call from Twilio rings, is answered, and lasts until Twilio hangs up,
    on the path it started on: Wi-Fi calling (wlan) or VoLTE over LTE with Wi-Fi
    off (lte). US Mobile Verizon 2026-11-03: incoming calls hung up as well as the
    outgoing "Server error"; nothing else in the suite receives a call."""
    if path == "wlan":
        request.getfixturevalue("on_wlan")   # skips unless IMS voice is on WLAN
    creds, to = twilio
    placed = {}

    def ring():
        placed["sid"] = twilio_call.call(creds, to, HOLD_S)

    marks, samples = run_call(dut, imsa_probe, "-", artifacts, HOLD_S,
                              pre_wwan_s=ON_WWAN_WAIT_S if path == "lte" else None, on_armed=ring)
    if "no_wwan" in marks:
        pytest.skip(f"IMS voice not on LTE after {ON_WWAN_WAIT_S} s")
    far = twilio_call.status(creds, placed["sid"]) if "sid" in placed else {}
    print(f"twilio {far}")
    assert "sid" in placed, "driver never armed, so no call was placed"
    assert "no_ring" not in marks, f"never rang in {RING_S} s (twilio {far}):\n{ims_failures(artifacts)}"
    assert "rejected" not in marks, \
        f"ended while ringing, before the answer (call screening? the Twilio number must be a contact):\n{ims_failures(artifacts)}"

    # A trial call hangs up by itself ~14 s in, so a trial run proves ring, answer,
    # setup and a clean far-end hang-up, but not the full hold.
    hold = TRIAL_HOLD_S if twilio_call.trial() else HOLD_S - 5
    end = marks.get("ended", marks.get("hangup"))
    call = in_call(samples, marks["answer"], end)
    print(summary(call))
    assert len(call) >= hold, f"answer did not hold (twilio {far}):\n{ims_failures(artifacts)}"
    assert "ended" in marks and marks["ended"] - marks["answer"] >= hold, \
        f"call dropped {end - marks['answer']} s after answer (twilio {far}):\n{ims_failures(artifacts)}"
    if twilio_call.trial():
        log = (artifacts / "logcat").read_text(errors="replace")
        assert "CODE_USER_TERMINATED_BY_REMOTE" in log, \
            f"ended early, but not by the far end:\n{ims_failures(artifacts)}"
    want = 0 if path == "wlan" else WWAN
    moved = [s for s in call if s["rat"] not in (want, None)]
    assert not moved, f"left {path} mid-call:\n{summary(moved)}"
    assert far.get("status") == "completed" and far.get("duration", 0) >= hold, f"twilio says {far}"
    if path == "lte":
        assert dut.wifi()["enabled"], "Wi-Fi was not re-enabled"


def adsp_crashes(dut):
    """ADSP fatal errors in the kernel log so far this boot (each takes the modem with it)."""
    return int(dut.sh("dmesg | grep -c 'Fatal error on adsp' || true").strip() or 0)


# Speaker presses after the answer, as Neil's T-Mobile phone logged them on
# 2026-11-05 19:14: USER_SWITCH_SPEAKER 1.25 s after the call went active and
# again 1.75 s later; the speaker engaged only ~2.8 s after the first press
# (the voice path still starting), and the next press, back to the earpiece
# 1.35 s later and 0.3 s after it engaged, crashed the ADSP and the modem.
# Intervals in seconds, the first from the answer key.
SPEAKER_TAPS = {
    "neil": "1.25 1.75 1.35",
    "rapid": "0.5 0.5 0.5 0.5 0.5",
}
# The in-call Speaker label on the PVG100's 720x1280 screen (LineageOS Dialer,
# 2026-11-05); a fixed spot so the first press needs no 1-2 s uiautomator lookup.
# Each press is checked against Telecom's log, so a moved button fails loudly.
SPEAKER_XY = "599 661"
ROUTE_PRESS = re.compile(r"Message received: (USER_SWITCH_SPEAKER|USER_SWITCH_BASELINE_ROUTE)")


@pytest.mark.call
@pytest.mark.disruptive
@pytest.mark.timeout(HOLD_S + ON_WWAN_WAIT_S + RING_S + 300)
@pytest.mark.parametrize("taps", list(SPEAKER_TAPS))
def test_call_speaker_toggle(dut, sub, imsa_probe, twilio, artifacts, radio_quiet, awake, taps):
    """An MT VoLTE call over LTE survives the Speaker button pressed on and off
    right after answering: no ADSP crash, and the call lasts until Twilio hangs up.
    Neil's T-Mobile phone, 2026-11-05 19:14, super-wideband capped: three presses
    in the first 4.5 s crashed the ADSP and the modem (qpaudio_svs.c:4475) and
    ended the call."""
    creds, to = twilio
    placed = {}

    def ring():
        placed["sid"] = twilio_call.call(creds, to, HOLD_S)

    before = adsp_crashes(dut)
    marks, samples = run_call(dut, imsa_probe, "-", artifacts, HOLD_S, pre_wwan_s=ON_WWAN_WAIT_S,
                              on_armed=ring,
                              env_extra=f' TAPS="{SPEAKER_TAPS[taps]}" SPEAKER_XY="{SPEAKER_XY}"')
    if "no_wwan" in marks:
        pytest.skip(f"IMS voice not on LTE after {ON_WWAN_WAIT_S} s")
    crashed = adsp_crashes(dut) - before
    try:
        dut.pull(f"{DEV_DIR}/run/ui.xml", artifacts / "ui.xml")
    except Exception:
        pass
    far = twilio_call.status(creds, placed["sid"]) if "sid" in placed else {}
    print(f"twilio {far}  evs={dut.sh('getprop vendor.pepito.modem.evs_boot').strip()}")
    assert "sid" in placed, "driver never armed, so no call was placed"
    assert "no_ring" not in marks and "rejected" not in marks, f"no answered call:\n{ims_failures(artifacts)}"
    assert "no_speaker_button" not in marks, "no Speaker button on the in-call screen (see ui.xml)"
    want = len(SPEAKER_TAPS[taps].split())
    presses = [k for k in marks if k.startswith("tap")]
    assert len(presses) == want, f"pressed {len(presses)} times: {marks}"
    log = (artifacts / "logcat").read_text(errors="replace")
    routed = ROUTE_PRESS.findall(log)
    print(f"route presses Telecom saw: {routed}")
    # At 0.5 s apart the Dialer can swallow a press while its button animates
    # (dut1 2026-11-05: 4 of 5); none at all means the button is not there.
    assert len(routed) >= want - 1, f"Telecom saw {len(routed)} of {want} Speaker presses (button moved? see ui.xml)"
    assert crashed == 0, f"ADSP crashed {crashed}x during the call (modem SSR follows):\n{ims_failures(artifacts)}"

    hold = TRIAL_HOLD_S if twilio_call.trial() else HOLD_S - 5
    end = marks.get("ended", marks.get("hangup"))
    call = in_call(samples, marks["answer"], end)
    print(summary(call))
    assert "ended" in marks and marks["ended"] - marks["answer"] >= hold, \
        f"call dropped {end - marks['answer']} s after answer:\n{ims_failures(artifacts)}"
    if twilio_call.trial():
        assert "CODE_USER_TERMINATED_BY_REMOTE" in log, f"ended early, but not by the far end:\n{ims_failures(artifacts)}"
    assert dut.wifi()["enabled"], "Wi-Fi was not re-enabled"
