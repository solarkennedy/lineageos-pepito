"""Post-flash smoke: the checks done by hand on dut1 + new2 after the first
upstream rebase (PLAN-android17.md, "Upstream rebase 2026-10-23"), made repeatable.

What they guard: the build being the one we stamped, a security patch level
that isn't stale, no platform crash or unknown SELinux denial since boot, GApps
privileged on gapps builds, the pepito UI patches carried in rebased forks
(3-button nav in Launcher3 + the vendor/lineage taskbar flag, the QS volume
slider, the torch tile, Updater, the PVG100 Tweaks pages) and cellular service.

All read-only except the three `awake` UI tests, which change what's on screen
and put it back (nav mode restored, HOME pressed).
"""
import re
import time
import tomllib
from datetime import date, datetime, timezone
from pathlib import Path

import pytest

from pepito import find_stamp

HERE = Path(__file__).parent
SELINUX = tomllib.loads((HERE / "baselines/selinux.toml").read_text())

# Lineage bumps the patch level monthly, a few days to weeks after each bulletin.
# A build whose level trails its own build date by more than this skipped at
# least two monthly rebases (REBASE.md).
SPL_MAX_AGE_DAYS = 100

# dropbox tags for platform (preinstalled) crashes; data_app_* is third-party.
CRASH_TAGS = ["system_server_crash", "system_server_native_crash", "system_server_anr",
              "system_server_watchdog", "system_app_crash", "system_app_native_crash",
              "system_app_anr", "SYSTEM_TOMBSTONE"]
# Known crashers that are not a build problem, with the reason.
KNOWN_CRASHERS = {
    "aflags": "debug CLI; `aflags list` aborts partway on 24.0. Nothing in the system runs it",
}
APP_SANDBOXES = re.compile(r"^(untrusted_app\w*|isolated_app\w*|ephemeral_app|sdk_sandbox\w*)$")

LAUNCHER3 = "com.android.launcher3/.uioverrides.QuickstepLauncher"
NAVBAR_THREEBUTTON = "com.android.internal.systemui.navbar.threebutton"
PEPITO_SCREENS = [
    "org.lineageos.updater/.UpdatesActivity",
    "org.lineageos.lineageparts/.perf.GoTweaksSettings",       # PVG100 System Tweaks
    "org.lineageos.lineageparts/.radio.ModemTweaksSettings",   # PVG100 Modem Tweaks
]
GMS = "com.google.android.gms"


# --- helpers -----------------------------------------------------------------

def boot_wall(dut):
    """Boot time as the phone's local 'YYYY-MM-DD HH:MM:SS' (dropbox's format)."""
    return dut.sh('date -d @$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )) "+%Y-%m-%d %H:%M:%S"')


def crash_mark(dut):
    """A `logcat -T` timestamp for 'from now on'."""
    return dut.sh('date "+%m-%d %H:%M:%S.000"')


def crashes_since(dut, mark):
    """Processes in the crash buffer since `mark`."""
    out = dut.sh(f"logcat -d -b crash -T '{mark}' 2>/dev/null || true")
    return set(re.findall(r"Process: ([\w.:]+)", out))


def dropbox_entries(dut, tag):
    """[(timestamp, tag, process)] for one dropbox tag."""
    out = dut.sh(f"dumpsys dropbox --print {tag} 2>/dev/null || true", timeout=120)
    entries = []
    for block in re.split(r"^={20,}$", out, flags=re.M):
        head = re.search(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) \(", block, re.M)
        if not head:
            continue
        proc = re.search(r"^Process: (\S+)|>>> (\S+) <<<|^Cmdline: (\S+)", block, re.M)
        name = next((g for g in proc.groups() if g), "?") if proc else "?"
        entries.append((head.group(1), head.group(2), name))
    return entries


def avc_denials(dut):
    """{(source, target, class): sample line} since boot, from dmesg and logcat
    (the kernel ring wraps within an hour on a busy boot; logcat keeps more)."""
    out = dut.sh("(dmesg; logcat -d -b all 2>/dev/null) | grep 'avc:  denied' || true", timeout=120)
    found = {}
    for line in out.splitlines():
        m = re.search(r"scontext=u:r:([^:]+):\S* tcontext=u:object_r:([^:]+):\S* tclass=(\S+)", line)
        if m:
            found.setdefault(m.groups(), line.strip()[-300:])
    return found


def pid(dut, name):
    return dut.sh(f"pidof {name} || true")


def nav_overlay(dut):
    m = re.search(r"\[x\] (com\.android\.internal\.systemui\.navbar\.\w+)", dut.sh("cmd overlay list"))
    return m.group(1) if m else None


# --- build identity ----------------------------------------------------------

def test_build_is_stamped(dut):
    """The phone runs a build our scripts stamped, and the flavor agrees with it."""
    f, stamp = find_stamp(dut.identity["date_utc"], dut.identity["kernel_uts"])
    assert stamp, (f"no build stamp matches {dut.identity}: not built by build-lineage24-remotely.sh, "
                   "or the stamp wasn't filed (the release gate can't count this run)")
    gapps = "_gapps" in (dut.build or "")
    assert (stamp["build"].get("flavor") == "gapps") == gapps, \
        f"{dut.build} but its stamp {f.name} says flavor {stamp['build'].get('flavor')}"


def test_security_patch_level_fresh(dut):
    """The Android security patch level isn't far behind the build date: we kept
    up with LineageOS's monthly bulletin merges (REBASE.md)."""
    spl = dut.prop("ro.build.version.security_patch")
    built = datetime.fromtimestamp(dut.identity["date_utc"], timezone.utc).date()
    age = (built - date.fromisoformat(spl)).days
    assert age <= SPL_MAX_AGE_DAYS, \
        (f"security patch level {spl} is {age} days older than the build ({built}): "
         "upstream rebase overdue? scripts/upstream.py drift")


# --- health since boot -------------------------------------------------------

def test_no_platform_crashes_since_boot(dut):
    """No crash, ANR or tombstone from a preinstalled process since this boot.
    Third-party apps are someone else's bugs and don't count."""
    since = boot_wall(dut)
    third_party = set(re.findall(r"package:(\S+)", dut.sh("pm list packages -3")))
    bad = []
    for tag in CRASH_TAGS:
        for ts, t, proc in dropbox_entries(dut, tag):
            base = proc.split(":")[0]
            if ts < since or base in third_party or base in KNOWN_CRASHERS:
                continue
            bad.append(f"{ts} {t} {proc}")
    assert not bad, f"platform crashes since boot ({since}):\n" + "\n".join(bad[:30])


def test_selinux_no_new_denials(dut):
    """Every SELinux denial since boot is a known one (baselines/selinux.toml)."""
    allowed = {tuple(e) for e in SELINUX["allowed"]}
    new = {k: v for k, v in avc_denials(dut).items()
           if k not in allowed and not APP_SANDBOXES.match(k[0])}
    assert not new, "denials not in baselines/selinux.toml:\n" + "\n".join(
        f"{' '.join(k)}\n    {v}" for k, v in sorted(new.items()))


# --- GApps -------------------------------------------------------------------

@pytest.mark.timeout(120)
def test_gms_privileged(dut):
    """On a gapps build, Play services is the privileged system copy with its
    cross-user permission, and it's running."""
    present = f"package:{GMS}" in dut.sh(f"pm list packages {GMS}")
    if "_gapps" not in (dut.build or ""):
        if present:
            pytest.skip(f"vanilla build with {GMS} in /data (left from a gapps install): "
                        "it can't be privileged here; flash gapps, or wipe")
        pytest.skip("vanilla build")
    assert present, f"{GMS} missing on a gapps build"
    pkg = dut.sh(f"dumpsys package {GMS} | grep -E 'codePath=|privateFlags=|INTERACT_ACROSS_USERS:'")
    assert re.search(r"codePath=/(system/)?(system|product|system_ext)/priv-app/", pkg), \
        f"no system priv-app copy of {GMS}:\n{pkg}"
    assert "PRIVILEGED" in pkg, f"{GMS} isn't privileged:\n{pkg}"
    assert "INTERACT_ACROSS_USERS: granted=true" in pkg, f"{GMS} lacks INTERACT_ACROSS_USERS:\n{pkg}"
    dut.wait_for(f"pidof {GMS} || true", lambda out: out.strip() != "", timeout=90)


# --- cellular ----------------------------------------------------------------

@pytest.mark.timeout(240)
def test_cell_service(dut):
    """With an active SIM: voice in service (not emergency-only), and mobile data
    up unless the user turned it off."""
    if not dut.active_sub():
        pytest.skip(f"{dut.nick} has no active SIM")

    try:
        dut.wait_for("dumpsys telephony.registry | grep -m1 'mServiceState='",
                     lambda out: "mVoiceRegState=0(IN_SERVICE)" in out and "mIsEmergencyOnly=false" in out,
                     timeout=180, interval=10)
    except TimeoutError:
        ss = dut.sh("dumpsys telephony.registry | grep -m1 'mServiceState='")
        pytest.fail("no voice service after 180 s: " + ", ".join(
            re.findall(r"mVoiceRegState=\S+|mDataRegState=\S+|mIsEmergencyOnly=\w+|mOperatorAlphaLong=[^,]*", ss)))
    if dut.sh("settings get global mobile_data") == "1":
        dut.wait_for("dumpsys telephony.registry | grep -m1 mDataConnectionState",
                     lambda out: "mDataConnectionState=2" in out, timeout=60, interval=5)


# --- pepito UI (rebased forks) ---------------------------------------------

@pytest.mark.timeout(120)
def test_quick_settings(dut, awake):
    """QS shows the volume slider (frameworks/base + lineage-sdk) and the torch tile."""
    try:
        dut.sh("cmd statusbar expand-settings")
        time.sleep(2)
        ui = dut.sh("uiautomator dump /data/local/tmp/itest-ui.xml >/dev/null 2>&1; "
                    "cat /data/local/tmp/itest-ui.xml")
    finally:
        dut.sh("cmd statusbar collapse")
    assert 'resource-id="com.android.systemui:id/Media"' in ui, "no QS volume slider"
    assert 'content-desc="Flashlight"' in ui, "no torch tile in QS"


@pytest.mark.timeout(150)
def test_three_button_nav(dut, awake):
    """3-button nav with Trebuchet up: no launcher/SystemUI crash loop (Launcher3
    TaskbarManagerImpl patch + vendor/lineage enable_taskbar_on_phones=false).
    The nav mode is put back afterwards."""
    before = nav_overlay(dut)
    mark = crash_mark(dut)
    sysui = pid(dut, "com.android.systemui")
    try:
        dut.sh(f"cmd overlay enable-exclusive --category {NAVBAR_THREEBUTTON}")
        assert "Status: ok" in dut.sh(f"am start -W -n {LAUNCHER3}")
        time.sleep(5)
        launcher = pid(dut, "com.android.launcher3")
        time.sleep(20)
        crashed = crashes_since(dut, mark) & {"com.android.launcher3", "com.android.systemui", "system_server"}
        assert not crashed, f"crashed in 3-button mode: {crashed}"
        assert launcher and pid(dut, "com.android.launcher3") == launcher, "Launcher3 restarted"
        assert pid(dut, "com.android.systemui") == sysui, "SystemUI restarted"
    finally:
        if before and before != NAVBAR_THREEBUTTON:
            dut.sh(f"cmd overlay enable-exclusive --category {before}")
        dut.sh("input keyevent KEYCODE_HOME")


@pytest.mark.timeout(120)
def test_pepito_screens_open(dut, awake):
    """Updater and the PVG100 Tweaks pages open and stay up."""
    mark = crash_mark(dut)
    try:
        for act in PEPITO_SCREENS:
            out = dut.sh(f"am start -W -n {act}")
            assert "Status: ok" in out, f"{act} didn't start:\n{out}"
            time.sleep(3)
            pkg = act.split("/")[0]
            assert pid(dut, pkg), f"{pkg} died after opening {act}"
        crashed = {p for p in crashes_since(dut, mark)
                   if p.split(":")[0] in {a.split("/")[0] for a in PEPITO_SCREENS}}
        assert not crashed, f"crashed: {crashed}"
    finally:
        dut.sh("input keyevent KEYCODE_HOME")
