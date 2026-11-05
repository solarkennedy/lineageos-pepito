#!/usr/bin/env python3
"""Run the Play Store's built-in Play Integrity check on a bench phone over adb.

    diag-tools/play-integrity/check-integrity.py new2        # or dut1, gold, ...
    diag-tools/play-integrity/check-integrity.py --adb adb   # plain adb, one phone attached

Drives Play Store -> account menu -> Settings -> General -> Developer options ->
Check integrity (it turns the Play Store developer options on first if they are
hidden, by tapping "Play Store version" seven times), then prints the verdict
dialog's text, the verdict class, and saves a screenshot + logcat.

Verdict classes (read from the dialog AND the log, see plans/PLAN-integrity.md):
  GRADED   dialog shows "Labels: [...]" -- [] means graded but failed everything
  ERROR    dialog shows an error / the log has the Volley 500 or DF-DFERH-01 (-12)
  UNKNOWN  no dialog in time

Results go to ~/android/lineage-24/integrity-checks/<utc>-<unit>/, deliberately
outside this public repo: the dialog carries a TestId. Needs a GApps build. Unlocks
a pattern-locked phone with android-unlock-<unit> when one exists (one attempt only;
failed attempts count towards the lockout).
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

VENDING = "com.android.vending"


class Phone:
    def __init__(self, adb):
        self.adb = adb

    def sh(self, cmd, check=False):
        r = subprocess.run([self.adb, "shell", cmd], capture_output=True, text=True, timeout=60)
        if check and r.returncode:
            sys.exit(f"adb shell {cmd!r} failed: {r.stderr.strip()}")
        return r.stdout

    def tap(self, x, y):
        self.sh(f"input tap {x} {y}")

    def swipe_up(self):
        self.sh("input swipe 360 1000 360 400 400")

    def nodes(self):
        """[(text, desc, (cx, cy))] for every on-screen node with a label."""
        xml = self.sh("uiautomator dump /sdcard/pi-ui.xml >/dev/null && cat /sdcard/pi-ui.xml")
        xml = xml[xml.find("<?xml"):] if "<?xml" in xml else xml
        try:
            root = ET.fromstring(xml)
        except ET.ParseError:
            return []
        out = []
        for n in root.iter("node"):
            t, d = n.get("text", ""), n.get("content-desc", "")
            m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
            if (t or d) and m:
                x1, y1, x2, y2 = map(int, m.groups())
                out.append((t, d, ((x1 + x2) // 2, (y1 + y2) // 2)))
        return out

    def find(self, pattern, nodes=None):
        rx = re.compile(pattern)
        for t, d, c in nodes if nodes is not None else self.nodes():
            if rx.search(t) or rx.search(d):
                return c
        return None

    def wait_tap(self, pattern, timeout=10, scrolls=0, what=None):
        """Tap the first node matching pattern, scrolling down up to `scrolls` times.

        Polls until `timeout`; scrolls only after the screen has had 2.5 s to
        settle, so a slow-loading page doesn't burn the scrolls before it draws.
        """
        end = time.time() + timeout
        tries = 0
        last_scroll = time.time()
        while True:
            c = self.find(pattern)
            if c:
                self.tap(*c)
                return c
            now = time.time()
            if now > end:
                sys.exit(f"couldn't find {what or pattern!r} on screen")
            if tries < scrolls and now - last_scroll >= 2.5:
                self.swipe_up()
                tries += 1
                last_scroll = now
            time.sleep(0.7)


def unlock(phone, unit):
    if "isKeyguardShowing=true" not in phone.sh("dumpsys window"):
        return
    phone.sh("input keyevent KEYCODE_WAKEUP")
    time.sleep(1)
    # A swipe-only keyguard (no credential) goes away with dismiss-keyguard;
    # only a real pattern needs android-unlock-<unit>.
    for attempt in (lambda: phone.sh("wm dismiss-keyguard"), phone.swipe_up):
        attempt()
        time.sleep(1.5)
        if "isKeyguardShowing=true" not in phone.sh("dumpsys window"):
            return
    tool = shutil.which(f"android-unlock-{unit}") if unit else None
    if not tool:
        sys.exit("phone is locked and there is no android-unlock-<unit>; unlock it by hand")
    subprocess.run([tool], timeout=60)
    time.sleep(2)
    if "isKeyguardShowing=true" in phone.sh("dumpsys window"):
        sys.exit("still locked after one unlock attempt; not retrying (lockout)")


def open_dev_options(phone):
    phone.sh(f"am force-stop {VENDING}")
    phone.sh(f"am start -n {VENDING}/com.google.android.finsky.activities.MainActivity", check=True)
    # Signed out, the account avatar is replaced by an "Options" menu that
    # still has Settings (the integrity API works without an account).
    # A fresh account (or cleared GMS data) first gets promo prompts ("local
    # recommendations", "Introducing Google Play Points", ...); decline them.
    avatar = r"^Signed in as|Account and settings|^Options$"
    deadline = time.time() + 30
    while True:
        nodes = phone.nodes()
        c = phone.find(r"^(No thanks|Not now|Maybe later|Skip|Got it)$", nodes)
        if c:
            phone.tap(*c)
            time.sleep(2)
            continue
        c = phone.find(avatar, nodes)
        if c:
            phone.tap(*c)
            break
        if time.time() > deadline:
            sys.exit("couldn't find 'account avatar or Options menu' on screen")
        time.sleep(0.7)
    time.sleep(2)
    phone.wait_tap(r"^Settings$", timeout=20, scrolls=4)
    time.sleep(2)
    phone.wait_tap(r"expand the General settings", timeout=15, what="General section")
    time.sleep(1.5)
    if phone.find(r"^Developer options$"):
        phone.wait_tap(r"^Developer options$")
        return
    # Hidden: Play Store's About -> tap "Play Store version" 7 times, then back to General.
    print("Play Store developer options hidden, enabling them")
    phone.wait_tap(r"expand the About settings", timeout=5, scrolls=4, what="About section")
    time.sleep(1.5)
    c = None
    for _ in range(4):
        c = phone.find(r"^Play Store version")
        if c:
            break
        phone.swipe_up()
        time.sleep(1)
    if not c:
        sys.exit("couldn't find 'Play Store version' under About")
    for _ in range(7):
        phone.tap(*c)
        time.sleep(0.3)
    time.sleep(1.5)
    for _ in range(6):
        if phone.find(r"^Developer options$"):
            break
        phone.sh("input swipe 360 400 360 1000 400")
        time.sleep(1)
    phone.wait_tap(r"^Developer options$", timeout=5, what="Developer options (after enabling)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("unit", nargs="?", help="bench nickname (uses <unit>-adb and android-unlock-<unit>)")
    ap.add_argument("--adb", help="adb command to use instead of <unit>-adb")
    ap.add_argument("--out", default=os.path.expanduser("~/android/lineage-24/integrity-checks"))
    ap.add_argument("--timeout", type=int, default=45, help="seconds to wait for the verdict")
    ap.add_argument("--keep-log", action="store_true",
                    help="don't clear logcat before tapping (caller cleared it earlier)")
    a = ap.parse_args()
    if not a.unit and not a.adb:
        ap.error("give a unit nickname or --adb")
    phone = Phone(a.adb or f"{a.unit}-adb")

    serial = phone.sh("getprop ro.serialno").strip()
    if not serial:
        sys.exit(f"{phone.adb}: phone not reachable")
    if "package:com.google.android.gms" not in phone.sh("pm list packages com.google.android.gms"):
        sys.exit("no GMS on this phone (vanilla build?); the check needs GApps")
    fp = phone.sh("getprop ro.build.fingerprint").strip()
    print(f"unit={a.unit or '-'} serial={serial}\nfingerprint={fp}")

    unlock(phone, a.unit)
    open_dev_options(phone)
    time.sleep(2)

    if not a.keep_log:
        phone.sh("logcat -b all -c")
    phone.wait_tap(r"^Check integrity$", timeout=10, what="Check integrity")
    started = time.time()

    dialog = []
    while time.time() - started < a.timeout:
        time.sleep(2)
        nodes = phone.nodes()
        if any(t.startswith("Labels:") or re.search(r"(?i)error|failed|try again", t) for t, _, _ in nodes):
            if phone.find(r"^Dismiss$", nodes):
                dialog = [t for t, _, _ in nodes if t]
                break
    elapsed = time.time() - started

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    outdir = os.path.join(a.out, f"{stamp}-{a.unit or serial}")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "screenshot.png"), "wb") as f:
        f.write(subprocess.run([phone.adb, "exec-out", "screencap -p"], capture_output=True, timeout=60).stdout)
    log = phone.sh("logcat -b all -d -v threadtime")
    with open(os.path.join(outdir, "logcat.txt"), "w") as f:
        f.write(log)

    # The dialog sits on top of the Developer options page; keep only its lines.
    if "Play Integrity" in dialog:
        dialog = dialog[len(dialog) - dialog[::-1].index("Play Integrity") - 1:]
    dialog = [t for t in dialog if t not in ("Dismiss", "Share")
              and not re.match(r"^(Games|Apps|Search|Books|Developer options)$", t)]
    labels = next((t for t in dialog if t.startswith("Labels:")), None)
    log500 = re.findall(r".*(?:DF-DFERH|fdfe/integrity.*\b500\b|Unexpected response code 500).*", log)
    finished = re.findall(r".*requestIntegrityToken\(\) finished.*", log)

    if labels and not log500:
        verdict = "GRADED"
    elif log500 or dialog:
        verdict = "ERROR"
    else:
        verdict = "UNKNOWN"

    summary = [f"time_utc={stamp}", f"unit={a.unit or '-'}", f"serial={serial}", f"fingerprint={fp}",
               f"build_date_utc={phone.sh('getprop ro.build.date.utc').strip()}",
               f"verdict={verdict}", f"labels={labels or '-'}", f"elapsed_s={elapsed:.0f}",
               "", "dialog:"] + [f"  {t}" for t in dialog] + \
              ["", "log:"] + [f"  {l.strip()}" for l in finished + log500[:5]]
    text = "\n".join(summary) + "\n"
    with open(os.path.join(outdir, "result.txt"), "w") as f:
        f.write(text)
    print(text + f"saved: {outdir}")

    if phone.find(r"^Dismiss$"):
        phone.wait_tap(r"^Dismiss$")
    phone.sh("input keyevent HOME")
    sys.exit(0 if verdict == "GRADED" else 1)


if __name__ == "__main__":
    main()
