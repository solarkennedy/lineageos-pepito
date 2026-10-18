"""Memory subsystem: MGLRU (kernel 253a9ff4e4d1 backport, kill switch
persist.gotweak.mglru), zram, lmkd tuning, kernel health; plus the
diag-tools/mglru-bench pressure runs. Reference: plans/PLAN-mglru.md and
baselines/memory.toml (the 20261017 release).

The config and health tests are read-only. The bench tests (`bench` marker) push
the phone hard for ~15 min: they hog 1.2 GB, kill and relaunch apps, keep the
screen on and unlock it; don't run them on a phone someone is using.
"""
import csv
import os
import re
import subprocess
import time
import tomllib
from pathlib import Path

import pytest

HERE = Path(__file__).parent
BENCH = HERE.parent.parent / "diag-tools/mglru-bench"
BASE = tomllib.loads((HERE / "baselines/memory.toml").read_text())
LG = "/sys/kernel/mm/lru_gen/enabled"
# The same patterns and known-benign lines as mglru-bench/mglru-check.sh health.
BAD = r"BUG:|WARNING:|Bad page|list_del corruption|kernel BUG at|VM_BUG_ON|page dumped"
BENIGN = r"irq-gic.c:1008|mm_types.h:591"


# --- read-only ---------------------------------------------------------------

def test_kernel_health(dut):
    """No BUG/WARN/bad-page in dmesg since boot, no panic left in pstore from the last one."""
    hits = dut.sh(f"dmesg | grep -E '{BAD}' | grep -v -E '{BENIGN}' || true")
    assert not hits, f"kernel complaints:\n{hits[:2000]}"
    panics = dut.sh("grep -l -E 'Kernel panic|Internal error|BUG:' /sys/fs/pstore/* 2>/dev/null || true")
    assert not panics, f"previous boot left a panic in pstore: {panics}"


def test_kernel_config(dut):
    cfg = set(dut.sh("zcat /proc/config.gz").splitlines())
    missing = [c for c in BASE["config"]["kernel_config"] if c not in cfg]
    assert not missing, f"kernel config lacks {missing}"


def test_mglru_follows_kill_switch(dut):
    """lru_gen/enabled must match persist.gotweak.mglru (default on) via the init.gotweaks.rc trigger."""
    prop = dut.prop("persist.gotweak.mglru") or "1"
    want = BASE["config"]["lru_gen_disabled" if prop == "0" else "lru_gen_enabled"]
    assert dut.sh(f"cat {LG}") == want, f"persist.gotweak.mglru={prop}"


def test_zram(dut):
    algo = re.search(r"\[(\w+)\]", dut.sh("cat /sys/block/zram0/comp_algorithm"))
    assert algo and algo.group(1) == BASE["config"]["zram_algorithm"]
    assert int(dut.sh("cat /sys/block/zram0/disksize")) == BASE["config"]["zram_disksize"]
    assert "/dev/block/zram0" in dut.sh("cat /proc/swaps"), "zram swap not active"


def test_vm_tunables(dut):
    c = BASE["config"]
    got = {k: int(dut.sh(f"cat /proc/sys/vm/{k}")) for k in ("swappiness", "watermark_scale_factor",
                                                              "extra_free_kbytes")}
    assert got == {k: c[k] for k in got}


def test_lmkd_config(dut):
    want = BASE["config"]["lmk_props"]
    got = dut.props(*want)
    assert got == want
    assert dut.sh("pidof lmkd || true"), "lmkd not running"


# --- bench -------------------------------------------------------------------

def run_bench(dut, artifacts, script, *args, timeout):
    """Run a mglru-bench script against the unit; return its results directory."""
    env = os.environ | {"PEPITO_ADB": dut.adb, "MGLRU_RESULTS": str(artifacts)}
    try:
        p = subprocess.run(["bash", str(BENCH / script), "-t", "itest", *args], env=env,
                           capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    finally:
        # The bench's bench_done drops `svc power stayon`; the session holds it (conftest _stay_on).
        dut.sh("svc power stayon true")
    (artifacts / f"{script}.log").write_text(p.stdout + p.stderr)
    assert p.returncode == 0, f"{script} failed:\n{p.stderr[-2000:]}"
    runs = sorted(d for d in artifacts.iterdir() if d.is_dir() and d.name.endswith("-itest"))
    assert runs, f"{script} wrote no results"
    return runs[-1]


def delta(path):
    """vmstat-delta.sh diff output: "key value [unit]" per line."""
    return {f[0]: f[1] for f in map(str.split, path.read_text().splitlines()) if len(f) >= 2}


def installed(dut, activities):
    have = set(dut.sh("pm list packages").replace("package:", "").split())
    return [a for a in activities if a.split("/")[0] in have]


@pytest.fixture
def bench_ok(dut, awake):
    jobs = dut.busy_jobs()
    if jobs:
        pytest.skip(f"capture running on {dut.nick}: {jobs.split()}")
    if dut.call_state() != 0:
        pytest.skip(f"{dut.nick} is in a call")
    assert dut.sh(f"cat {LG}") == BASE["config"]["lru_gen_enabled"], \
        "MGLRU is off on this unit; the limits are for the shipped (on) arm"
    yield
    test_kernel_health(dut)


HOG_APPS = [
    "com.android.settings/.Settings",
    "com.google.android.apps.messaging/.ui.ConversationListActivity",
    "com.android.messaging/.ui.conversationlist.ConversationListActivity",
    "org.lineageos.jelly/.MainActivity",
    "org.lineageos.aperture/.CameraLauncher",
]


@pytest.mark.bench
@pytest.mark.timeout(BASE["hog"]["iterations"] * 300 + 120)
def test_hog_pressure(dut, artifacts, bench_ok):
    """1.2 GB anon hog, then resume warmed apps: lmkd kills, survival, resume latency, stall."""
    b = BASE["hog"]
    run = run_bench(dut, artifacts, "hog-resume.sh", "-n", str(b["iterations"]),
                    *installed(dut, HOG_APPS), timeout=b["iterations"] * 300)
    rows = [r for r in csv.DictReader((run / "resume.csv").open()) if int(r["iter"]) >= 2]
    kills, psi = [], []
    for it in range(2, b["iterations"] + 1):
        d = delta(run / f"iter{it}.delta.txt")
        kills.append(int(d["lmk_kills"]))
        psi.append(float(d["psi_full_stall"]))
    survival = sum(int(r["survived"]) for r in rows) / len(rows)
    resume = [int(r["total_ms"]) for r in rows if int(r["total_ms"]) > 0]
    mean_resume = sum(resume) / len(resume)
    print(f"kills/hog {kills} survival {survival:.0%} resume {mean_resume:.0f} ms psi_full {psi}")
    assert sum(kills) / len(kills) <= b["max_mean_kills_per_hog"], f"lmkd kills per hog {kills}"
    assert survival >= b["min_survival"], f"resumed-app survival {survival:.0%}"
    assert mean_resume <= b["max_mean_resume_ms"], f"mean resume {mean_resume:.0f} ms"
    assert sum(psi) / len(psi) <= b["max_mean_psi_full_s"], f"psi full stall per hog {psi}"


@pytest.mark.bench
@pytest.mark.timeout(1800)
def test_app_cycle(dut, artifacts, bench_ok):
    """Round-robin launches of the 15-app set: cold-start rate and launch latency."""
    c = BASE["cycle"]
    apps = subprocess.run(["bash", "-c", f'. "{BENCH}/lib.sh" >/dev/null; printf "%s\\n" "${{DEFAULT_APPS[@]}}"'],
                          env=os.environ | {"PEPITO_ADB": dut.adb},
                          capture_output=True, text=True).stdout.split()
    apps = installed(dut, apps)
    if len(apps) < 8:
        pytest.skip(f"only {len(apps)} of the bench apps are installed (vanilla build?)")
    run = run_bench(dut, artifacts, "app-cycle.sh", "-r", str(c["rounds"]), "-d", "2", *apps,
                    timeout=c["rounds"] * len(apps) * 20 + 120)
    rows = [r for r in csv.DictReader((run / "cycle.csv").open()) if int(r["round"]) >= 2]
    cold = sum(r["state"] == "COLD" for r in rows) / len(rows)
    times = [int(r["total_ms"]) for r in rows if int(r["total_ms"]) > 0]
    mean = sum(times) / len(times)
    print(f"cold {cold:.0%} of {len(rows)}, mean launch {mean:.0f} ms, "
          f"lmk_kills {delta(run / 'delta.txt').get('lmk_kills')}")
    assert cold <= c["max_cold_rate"], f"cold-start rate {cold:.0%}"
    assert mean <= c["max_mean_launch_ms"], f"mean launch {mean:.0f} ms"
