"""Place an inbound test call to a bench phone through Twilio's REST API (stdlib only).

Credentials and numbers live outside this public repo:

  ~/.config/pepito/twilio.env     TWILIO_SID=AC...  TWILIO_TOKEN=...  TWILIO_FROM=+1...
  ~/.config/pepito/unit-numbers   one "<nick> +1NNNNNNNNNN" per line (the SIM's number)

The call plays a short message, stays silent for the hold and then Twilio hangs
up, so the phone sees the far end end it, like the MO test line.
"""
import base64
import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path

CONF = Path(os.environ.get("PEPITO_TWILIO", Path.home() / ".config/pepito/twilio.env"))
NUMBERS = Path(os.environ.get("PEPITO_UNIT_NUMBERS", Path.home() / ".config/pepito/unit-numbers"))
API = "https://api.twilio.com/2010-04-01/Accounts/{sid}/Calls"


def load():
    """(sid, token, from) or None when Twilio isn't set up on this host."""
    if not CONF.exists():
        return None
    kv = dict(line.split("=", 1) for line in CONF.read_text().split() if "=" in line)
    creds = tuple(kv.get(k, "") for k in ("TWILIO_SID", "TWILIO_TOKEN", "TWILIO_FROM"))
    return creds if all(creds) else None


def trial():
    """TWILIO_TRIAL=1: a trial account, whose calls hang up ~14 s in (they wait
    for a key press the phone can't send), so the hold can't be checked."""
    if not CONF.exists():
        return False
    return "TWILIO_TRIAL=1" in CONF.read_text().split()


def unit_number(nick):
    if not NUMBERS.exists():
        return None
    for line in NUMBERS.read_text().splitlines():
        f = line.split()
        if len(f) >= 2 and not line.startswith("#") and f[0] == nick:
            return f[1]
    return None


def _req(creds, url, data=None):
    sid, token, _ = creds
    auth = base64.b64encode(f"{sid}:{token}".encode()).decode()
    body = urllib.parse.urlencode(data).encode() if data else None
    r = urllib.request.Request(url, data=body, headers={"Authorization": f"Basic {auth}"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError:
            raise                      # Twilio answered: a real error, don't repeat a POST
        except OSError:                # reset / timeout on the way there
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def call(creds, to, hold_s, ring_s=60):
    """Start the call; returns Twilio's call SID."""
    twiml = (f'<Response><Pause length="3"/><Say>pepito test call</Say>'
             f'<Pause length="{hold_s}"/></Response>')
    r = _req(creds, API.format(sid=creds[0]) + ".json",
             {"To": to, "From": creds[2], "Twiml": twiml, "Timeout": str(ring_s)})
    return r["sid"]


def status(creds, call_sid, settle_s=15):
    """Twilio's view of the call: status (completed, no-answer, busy, failed, ...)
    and duration in seconds once it is over. Twilio can lag the phone by a few
    seconds, so wait up to settle_s for it to leave queued/ringing/in-progress."""
    end = time.monotonic() + settle_s
    while True:
        r = _req(creds, API.format(sid=creds[0]) + f"/{call_sid}.json")
        st = {"status": r.get("status"), "duration": int(r.get("duration") or 0)}
        if st["status"] not in ("queued", "ringing", "in-progress") or time.monotonic() > end:
            return st
        time.sleep(2)
