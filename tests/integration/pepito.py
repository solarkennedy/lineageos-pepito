"""Host-side handle on one bench PVG100, driven through its `<nick>-adb` wrapper.

The wrapper (pepito-adb) picks the transport and verifies ro.serialno itself; we
check it once more against the roster so a test can never act on the wrong phone.
"""
import json
import os
import re
import subprocess
import time
from pathlib import Path

STAMPS_DIR = Path(os.environ.get("PEPITO_BUILD_STAMPS",
                                 Path.home() / ".local/share/pepito/build-stamps"))
UNITS_CONF = Path(os.environ.get("PEPITO_UNITS", Path.home() / ".config/pepito/units.conf"))
DEV_DIR = "/data/local/tmp/itest"
# QMI probes from diag-tools/nas-probe need the force-ipcr shim to reach the modem.
QMI_ENV = "LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64"


def roster():
    """nick -> serial, from the units.conf data rows."""
    units = {}
    for line in UNITS_CONF.read_text().splitlines():
        f = line.split()
        if len(f) >= 6 and not line.startswith("#") and "=" not in f[0]:
            units[f[0]] = f[1]
    return units


def find_stamp(date_utc, kernel_uts):
    """The build stamp (scripts/source-id.py, filed by build-lineage24-remotely.sh)
    for the build a phone reports, matched on system build time + kernel UTS_VERSION
    (a --boot-only build keeps the system date but brings a new kernel)."""
    for f in sorted(STAMPS_DIR.glob("*.json")):
        try:
            s = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        b = s.get("build", {})
        if b.get("date_utc") == date_utc and b.get("kernel_uts") == kernel_uts:
            return f, s
    return None, None


class AdbError(RuntimeError):
    pass


class Device:
    def __init__(self, nick):
        self.nick = nick
        self.adb = f"{nick}-adb"

    def _run(self, args, timeout):
        p = subprocess.run([self.adb, *args], capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            raise AdbError(f"{self.adb} {' '.join(args)}: rc={p.returncode} {p.stderr.strip()}")
        return p.stdout.replace("\r", "")

    def sh(self, cmd, timeout=60):
        return self._run(["shell", cmd], timeout).strip()

    def prop(self, name):
        return self.sh(f"getprop {name}")

    def props(self, *names):
        out = self.sh("; ".join(f"echo {n}=$(getprop {n})" for n in names))
        return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)

    def push(self, local, remote):
        self._run(["push", str(local), remote], 120)

    def pull(self, remote, local):
        self._run(["pull", remote, str(local)], 120)

    def ensure_root(self):
        if self.sh("id -u") != "0":
            subprocess.run([self.adb, "--root"], capture_output=True, timeout=60)
            if self.sh("id -u") != "0":
                raise AdbError(f"{self.nick}: adb root failed")

    def wait_for(self, cmd, pred, timeout, interval=5):
        """Run `cmd` until pred(output) is true, riding out adb drops (adb over
        Wi-Fi dies with the Wi-Fi leg during a walk-away)."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                out = self.sh(cmd, timeout=30)
                if pred(out):
                    return out
            except (AdbError, subprocess.TimeoutExpired):
                pass
            time.sleep(interval)
        raise TimeoutError(f"{self.nick}: gave up waiting on `{cmd}` after {timeout}s")

    def build_identity(self):
        p = self.props("ro.lineage.version", "ro.build.date.utc", "ro.build.fingerprint")
        m = re.search(r"\) (#\d+ .+)$", self.sh("cat /proc/version"))
        return {
            "lineage_version": p.get("ro.lineage.version"),
            "date_utc": int(p["ro.build.date.utc"]) if p.get("ro.build.date.utc", "").isdigit() else None,
            "fingerprint": p.get("ro.build.fingerprint"),
            "kernel_uts": m.group(1) if m else None,
        }

    # --- state readers -------------------------------------------------------

    def busy_jobs(self):
        """Capture jobs another session may be running; radio tests must not disturb them."""
        return self.sh("ps -A -o NAME | grep -E '^(diag_mdlog|strace)$' || true")

    def call_state(self):
        m = re.search(r"mCallState=(\d+)", self.sh("dumpsys telephony.registry"))
        return int(m.group(1)) if m else None

    def imsa(self, probe):
        """voip_service_rat etc. from `imsa-probe` (0 = WLAN)."""
        out = self.sh(f"env {QMI_ENV} {probe} 2>/dev/null")
        return {k: int(v) for k, v in re.findall(r"^\s*(\w+)\s*=\s*(-?\d+)", out, re.M)}

    def wifi(self):
        out = self.sh("cmd wifi status")
        m = re.search(r"RSSI: (-?\d+)", out)
        return {
            "enabled": "Wifi is enabled" in out,
            "connected": "Wifi is connected" in out,
            "rssi": int(m.group(1)) if m else None,
        }

    def active_sub(self):
        """The inserted SIM's siminfo row (sim_id >= 0), or None."""
        out = self.sh(
            "content query --uri content://telephony/siminfo "
            "--projection _id:sim_id:wfc_ims_mode:wfc_ims_enabled"
        )
        for line in out.splitlines():
            row = dict(re.findall(r"(\w+)=(-?\d+)", line))
            if row and int(row.get("sim_id", -1)) >= 0:
                return {k: int(v) for k, v in row.items()}
        return None
