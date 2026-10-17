# Integration tests

pytest suite that runs against a live bench PVG100 through its `<nick>-adb`
wrapper. One file per feature; `test_wfc.py` (Wi-Fi calling, including the
"Wi-Fi preferred" TH2 steering) is the first.

```bash
cd tests/integration
python3 -m pytest --unit dut1                      # read-only checks only
python3 -m pytest --unit dut1 --allow-calls        # + places a real call
python3 -m pytest --unit dut1 --allow-calls --allow-disruptive   # + Wi-Fi off mid-call
python3 -m pytest --unit dut1 -k th2 -s            # one test, with its printed timeline
```

## Tiers

| Marker | What it does to the phone | Opt-in |
|---|---|---|
| (none) | getprop, dumpsys, content query, logcat -d | always runs |
| `call` | dials the test number and hangs up | `--allow-calls` |
| `disruptive` | toggles Wi-Fi (or another radio) and restores it | `--allow-disruptive` |

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

## Writing tests

- Anything that has to keep running when adb drops (Wi-Fi off kills adb over
  Wi-Fi) goes in an on-device script under `device/`, started with `setsid`;
  the host side polls for a `done` mark with `Device.wait_for`.
- Properties settle over a few seconds; assert inside `eventually()` rather than
  sleeping.
- A test whose precondition isn't met on this unit (no SIM, IMS not on WLAN, LTE
  too weak) should `pytest.skip` with the reason, not fail.
- Never cycle airplane mode, flash, or reboot from a test.
