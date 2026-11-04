#!/usr/bin/env python3
"""LTE-only call soak: Wi-Fi off for the whole run, a call every --every minutes,
alternating incoming (Twilio) and outgoing (the test line). For "works at first,
then incoming calls drop on answer" (Neil, T-Mobile, 2026-11-04), which a single
fresh call after Wi-Fi goes off can't show.

  ./soak_lte.py --unit dut1 --hours 2 --every 5

Results go to results/soak-<start>-<unit>/: one directory per call (marks,
samples, logcat) and soak.tsv (one line per call). Wi-Fi and the ringer,
system and notification volumes are put back at the end, even on ^C.
Needs the phone on USB (adb over Wi-Fi dies with Wi-Fi off).
"""
import argparse
import re
import subprocess
import time
from pathlib import Path

import twilio_call
from conftest import TEST_NUMBER_FILE, quiet_now
from pepito import Device, roster
from test_wfc import HOLD_S, TRIAL_HOLD_S, WWAN, in_call, run_call

HERE = Path(__file__).parent
IMSA = "/data/local/tmp/imsa-probe"
QUIET_STREAMS = (1, 2, 5)  # system, ring, notification


def volumes(dut):
    out = dut.sh("; ".join(f"cmd media_session volume --stream {s} --get 2>/dev/null" for s in QUIET_STREAMS))
    return [int(v) for v in re.findall(r"volume is (\d+)", out)]


def set_volumes(dut, vals):
    dut.sh("; ".join(f"cmd media_session volume --stream {s} --set {v} >/dev/null 2>&1"
                     for s, v in zip(QUIET_STREAMS, vals)))


def one_call(dut, kind, out, creds, to, number):
    """Place one call; returns (verdict, detail)."""
    placed = {}

    def ring():
        placed["sid"] = twilio_call.call(creds, to, HOLD_S)

    if kind == "mt":
        marks, samples = run_call(dut, IMSA, "-", out, HOLD_S, on_armed=ring)
        start = marks.get("answer")
        need = TRIAL_HOLD_S if twilio_call.trial() else HOLD_S - 5
        if "sid" not in placed:
            return "fail", "driver never armed"
        for bad in ("no_ring", "rejected"):
            if bad in marks:
                return "fail", bad
        end = marks.get("ended", marks.get("hangup"))
    else:
        marks, samples = run_call(dut, IMSA, number, out, HOLD_S)
        start, end, need = marks.get("dial"), marks.get("hangup"), 20  # ~1.5 s samples over 42 s
    log = (out / "logcat").read_text(errors="replace")
    if "cc_sip_486_busy" in log:
        return "busy", "far end answered 486 Busy (not ours)"
    if kind == "mo" and "state=ACTIVE" not in log and "Request Terminated" in log:
        return "no_answer", "rang (ALERTING), never answered, network sent 487 (not ours)"
    call = in_call(samples, start, end)
    rats = sorted({s["rat"] for s in call if s["rat"] is not None})
    if len(call) < need:
        return "fail", f"connected {len(call)} s (< {need}) rats={rats}"
    if any(r != WWAN for r in rats):
        return "fail", f"left LTE rats={rats}"
    return "pass", f"connected {len(call)} s rats={rats}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--unit", required=True)
    ap.add_argument("--hours", type=float, default=2)
    ap.add_argument("--every", type=float, default=5, help="minutes between call starts")
    ap.add_argument("--ignore-quiet-hours", action="store_true")
    a = ap.parse_args()

    if quiet_now() and not a.ignore_quiet_hours:
        raise SystemExit("quiet hours (~/.config/pepito/quiet-hours); pass --ignore-quiet-hours")
    dut = Device(a.unit)
    if dut.prop("ro.serialno") != roster()[a.unit]:
        raise SystemExit(f"{a.unit}: serial mismatch")
    if "usb" not in subprocess.run(["adb", "devices", "-l"], capture_output=True, text=True).stdout \
            .split(roster()[a.unit], 1)[-1].split("\n", 1)[0]:
        raise SystemExit(f"{a.unit} is not on USB; Wi-Fi off would cut adb")
    creds, to = twilio_call.load(), twilio_call.unit_number(a.unit)
    if not creds or not to:
        raise SystemExit("Twilio not set up (twilio.env / unit-numbers)")
    number = TEST_NUMBER_FILE.read_text().split()[0]

    run = HERE / "results" / f"soak-{time.strftime('%Y%m%d-%H%M%S')}-{a.unit}"
    run.mkdir(parents=True)
    tsv = run / "soak.tsv"
    tsv.write_text("n\tstart\tkind\tverdict\tdetail\n")
    saved = volumes(dut)
    stay = dut.sh("settings get global stay_on_while_plugged_in")
    set_volumes(dut, [0] * len(QUIET_STREAMS))
    dut.sh("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; svc power stayon true; svc wifi disable")
    print(f"{run}: Wi-Fi off, volumes {saved} -> 0, {a.hours} h, every {a.every} min")
    end = time.time() + a.hours * 3600
    n = 0
    try:
        while time.time() < end:
            t0 = time.time()
            kind = "mt" if n % 2 == 0 else "mo"
            out = run / f"{n:03d}-{kind}"
            out.mkdir()
            try:
                verdict, detail = one_call(dut, kind, out, creds, to, number)
            except Exception as e:  # keep soaking; one bad call is a data point
                verdict, detail = "error", f"{type(e).__name__}: {e}"
            line = f"{n}\t{time.strftime('%H:%M:%S', time.localtime(t0))}\t{kind}\t{verdict}\t{detail}"
            print(line, flush=True)
            with tsv.open("a") as f:
                f.write(line + "\n")
            n += 1
            time.sleep(max(0, t0 + a.every * 60 - time.time()))
    finally:
        dut.sh(f"svc wifi enable; settings put global stay_on_while_plugged_in {stay if stay.isdigit() else 0}")
        set_volumes(dut, saved)
        print(f"done: Wi-Fi on, volumes back to {saved}; {tsv}")


if __name__ == "__main__":
    main()
