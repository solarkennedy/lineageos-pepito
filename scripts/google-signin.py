#!/usr/bin/env python3
"""Sign a pepito unit in to the bench Google account with nobody at the phone.

Usage: google-signin.py <serial> [--conf FILE] [--dump-dir DIR] [--timeout S]

Drives GMS's "Add account > Google" flow over adb: dump the screen with
uiautomator, decide which page of the flow it is, act, repeat until
`dumpsys account` lists the account. The sign-in pages are a WebView
(MinuteMaidActivity), and its nodes are readable by uiautomator: the HTML ids
show up as resource-ids (`identifierId`, `totpPin`) and the footer buttons are
native.

If the account has 2-Step Verification, it must use an authenticator app: a
prompt on another signed-in phone can't be answered from here, so the driver
always takes "Try another way" > Google Authenticator. Codes are made here
(RFC 6238, stdlib only).

Credentials come from ~/.config/pepito/google.conf ($PEPITO_GOOGLE_CONF),
never committed, shell syntax:
    GOOGLE_EMAIL='bench@example.com'
    GOOGLE_PASSWORD='...'
    GOOGLE_TOTP_SECRET='JBSW Y3DP EHPK 3PXP'   # base32, from "Can't scan it?"; empty = no 2FA

Exit 0 once the account is on the phone; 1 on a page it doesn't know, a
rejected password/code, or the timeout (the screen it stopped on is saved in
--dump-dir). setup-phone.sh --google falls back to waiting for a human then.
Never prints the password or a code.
"""

import argparse
import base64
import hashlib
import hmac
import os
import re
import shlex
import struct
import subprocess
import sys
import time

CONF = os.environ.get("PEPITO_GOOGLE_CONF", os.path.expanduser("~/.config/pepito/google.conf"))


def log(msg):
    print("   " + msg, flush=True)


def read_conf(path):
    """Parse the shell-syntax conf without running it."""
    vals = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            parts = shlex.split(v, comments=True)
            vals[k.strip()] = parts[0] if parts else ""
    missing = [k for k in ("GOOGLE_EMAIL", "GOOGLE_PASSWORD") if not vals.get(k)]
    if missing:
        sys.exit("google-signin: %s sets no %s" % (path, ", ".join(missing)))
    return vals


def totp(secret, t=None, step=30, digits=6):
    key = base64.b32decode(secret.replace(" ", "").upper() + "=" * (-len(secret.replace(" ", "")) % 8))
    mac = hmac.new(key, struct.pack(">Q", int((time.time() if t is None else t) // step)), hashlib.sha1).digest()
    o = mac[-1] & 0x0F
    return "%0*d" % (digits, (struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits)


class Phone:
    def __init__(self, serial):
        self.serial = serial

    def sh(self, cmd, check=False, timeout=30):
        r = subprocess.run(["adb", "-s", self.serial, "shell", cmd], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=timeout)
        if check and r.returncode:
            raise RuntimeError("adb shell failed: %s" % r.stderr.strip())
        return r.stdout.replace("\r", "")

    def account(self, email=None):
        for name in re.findall(r"Account \{name=([^,]*), type=com\.google\}", self.sh("dumpsys account")):
            if email is None or name.lower() == email.lower():
                return name
        return None

    def dump(self):
        """The screen as a list of node dicts (system UI dropped), or None if the dump failed."""
        out = self.sh("uiautomator dump /sdcard/gsignin.xml >/dev/null 2>&1 && cat /sdcard/gsignin.xml")
        if "<hierarchy" not in out:
            return None, out
        nodes = []
        for m in re.finditer(r"<node ([^>]*?)/?>", out):
            a = dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))
            if a.get("package", "").startswith("com.android.systemui"):
                continue
            for k in ("text", "content-desc"):
                a[k] = unescape(a.get(k, ""))
            b = re.findall(r"\d+", a.get("bounds", ""))
            if len(b) == 4:
                x1, y1, x2, y2 = map(int, b)
                a["xy"] = ((x1 + x2) // 2, (y1 + y2) // 2)
            nodes.append(a)
        return nodes, out

    def tap(self, node):
        self.sh("input tap %d %d" % node["xy"])

    def type_into(self, node, text):
        """Tap the field, clear it, type. `input text` reads %s as a space (and has no escape for it)."""
        if "%s" in text:
            raise SystemExit("google-signin: can't type a string containing '%s' with `input text`")
        self.tap(node)
        time.sleep(0.5)
        self.sh("input keycombination KEYCODE_CTRL_LEFT KEYCODE_A; input keyevent KEYCODE_DEL")
        self.sh("input text " + shlex.quote(text.replace(" ", "%s")))


def unescape(s):
    return (s.replace("&#10;", "\n").replace("&quot;", '"').replace("&apos;", "'")
             .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"))


def page_text(nodes):
    return "\n".join(t for n in nodes for t in (n["text"], n["content-desc"]) if t).lower()


def find(nodes, text=None, rid=None, cls=None, pred=None):
    """First node (with bounds) whose text/desc matches `text` (regex, case-insensitive)."""
    for n in nodes:
        if "xy" not in n:
            continue
        if rid and n.get("resource-id", "").split("/")[-1] != rid:
            continue
        if cls and not n.get("class", "").endswith(cls):
            continue
        if text and not any(re.fullmatch(text, t.strip(), re.I) for t in (n["text"], n["content-desc"]) if t):
            continue
        if pred and not pred(n):
            continue
        return n
    return None


# Pages that mean stop: retrying won't help, or a human must look.
FATAL = [
    (r"couldn.t find (your google|this) account", "Google doesn't know that email"),
    (r"wrong password", "wrong password"),
    (r"(wrong|invalid) code", "TOTP code rejected (secret or phone clock?)"),
    (r"couldn.t sign you in|this browser or app may not be secure", "Google refused the sign-in"),
    (r"too many failed attempts", "locked out for too many attempts"),
]


def step(phone, nodes, conf, state):
    """Act on one screen. Returns a short description of what was done, or None if nothing matched."""
    text = page_text(nodes)

    for pat, why in FATAL:
        if re.search(pat, text):
            raise SystemExit("google-signin: stopped: %s" % why)

    # "Sign in with ease": carrier phone-number lookup; Skip it.
    if "sign in with ease" in text and (b := find(nodes, r"skip", cls="Button")):
        phone.tap(b)
        return "skipped 'Sign in with ease'"

    if (f := find(nodes, rid="identifierId")) and find(nodes, r"forgot email\?"):
        phone.type_into(f, conf["GOOGLE_EMAIL"])
        phone.sh("input keyevent KEYCODE_ENTER")
        return "email"

    if (f := find(nodes, cls="EditText", pred=lambda n: n.get("password") == "true")):
        phone.type_into(f, conf["GOOGLE_PASSWORD"])
        phone.sh("input keyevent KEYCODE_ENTER")
        return "password"

    # TOTP entry. A code is accepted once: wait out its window before a second try,
    # and don't start one with under 5 s left.
    if (f := find(nodes, rid="totpPin")) or ("authenticator app" in text and (f := find(nodes, cls="EditText"))):
        if not conf.get("GOOGLE_TOTP_SECRET"):
            raise SystemExit("google-signin: stopped: Google asks for an authenticator code and google.conf has no GOOGLE_TOTP_SECRET")
        now = time.time()
        win = int(now // 30)
        if state.get("totp_window") == win or 30 - now % 30 < 5:
            time.sleep(30 - now % 30 + 1)
        phone.type_into(f, totp(conf["GOOGLE_TOTP_SECRET"]))
        state["totp_window"] = int(time.time() // 30)
        phone.sh("input keyevent KEYCODE_ENTER")
        return "TOTP code"

    # The list of second steps ("Choose how you want to sign in").
    if (b := find(nodes, r".*(google authenticator|authenticator app).*")):
        phone.tap(b)
        return "chose Google Authenticator"

    # Any other second step (prompt on another phone, security key, ...): ask for the list.
    if (b := find(nodes, r"try another way")):
        phone.tap(b)
        return "'Try another way'"

    # Terms, "Google services", "Back up to Google One", recovery-info nags. Prefer
    # declining the optional ones; "More" pages the Google services sheet down to Accept.
    for label in (r"not now", r"skip", r"no thanks", r"i agree", r"agree", r"accept", r"more", r"next", r"done"):
        if (b := find(nodes, label, pred=lambda n: n.get("clickable") == "true" and n.get("enabled") != "false")):
            phone.tap(b)
            return "pressed '%s'" % (b["text"] or b["content-desc"])

    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("serial")
    ap.add_argument("--conf", default=CONF)
    ap.add_argument("--dump-dir", default="/tmp/google-signin")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--totp", action="store_true", help="print the current code and exit")
    args = ap.parse_args()

    conf = read_conf(args.conf)
    if args.totp:
        if not conf.get("GOOGLE_TOTP_SECRET"):
            sys.exit("google-signin: %s has no GOOGLE_TOTP_SECRET" % args.conf)
        print(totp(conf["GOOGLE_TOTP_SECRET"]))
        return 0
    phone = Phone(args.serial)
    email = conf["GOOGLE_EMAIL"]

    if (name := phone.account(email)):
        log("already signed in: %s" % name)
        return 0
    if phone.account():
        log("note: another Google account is on the phone; adding %s too" % email)

    phone.sh("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; svc power stayon true")
    phone.sh("am start -a android.settings.ADD_ACCOUNT_SETTINGS --esa account_types com.google >/dev/null")
    log("Add account > Google opened; signing in as %s" % email)

    os.makedirs(args.dump_dir, exist_ok=True)
    state, last, repeats, idle_since = {}, None, 0, time.time()
    t0 = time.time()
    raw = ""
    try:
        while time.time() - t0 < args.timeout:
            if phone.account(email):
                log("signed in: %s (%d s)" % (email, time.time() - t0))
                phone.sh("input keyevent KEYCODE_HOME")
                return 0
            nodes, raw = phone.dump()
            if nodes is None:
                time.sleep(2)
                continue
            did = step(phone, nodes, conf, state)
            if did is None:
                # Spinners ("Checking info…", "Just a sec…") and page loads: wait, but not forever.
                if time.time() - idle_since > 45:
                    raise SystemExit("google-signin: stuck on a page it doesn't know")
                time.sleep(2)
                continue
            idle_since = time.time()
            repeats = repeats + 1 if did == last else 0
            if repeats >= 3:
                raise SystemExit("google-signin: did '%s' %d times and the page didn't change" % (did, repeats + 1))
            last = did
            log(did)
            time.sleep(4)
        raise SystemExit("google-signin: not signed in after %d s" % args.timeout)
    except SystemExit as e:
        path = os.path.join(args.dump_dir, time.strftime("stuck-%Y%m%d-%H%M%S.xml"))
        with open(path, "w") as f:
            f.write(raw)
        print(e.code if isinstance(e.code, str) else "google-signin: failed", file=sys.stderr)
        print("   screen saved to %s" % path, file=sys.stderr)
        return 1
    finally:
        phone.sh("svc power stayon false; rm -f /sdcard/gsignin.xml")


if __name__ == "__main__":
    sys.exit(main())
