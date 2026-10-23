"""Camera: the "Flash power" tweak (PLAN-misc.md §9, addenda 6-8).

A worn battery can't supply the 1 A strobe: VPH sags below the PMI8950 droop
threshold and the PMIC drops the LED to 200 mA, so the flash fires but the photo
is dim. PVG100 System Tweaks > Camera > Flash power lets the user cap the strobe:
the row writes persist.gotweak.flash_ma (0 = no cap, the default), init.gotweaks.rc
copies it to /sys/module/msm_flash/parameters/flash_cap_ma, and the camera-legacy
msm_flash.c caps the current it hands the LED trigger.

What these tests can't see is the photo itself; for the droop and the EXIF/meanY
check use diag-tools/flash-probe/flash-trace.sh (staging/flash-power/README.md).
"""
import re
import time

import pytest

PROP = "persist.gotweak.flash_ma"
CAP = "/sys/module/msm_flash/parameters/flash_cap_ma"
TWEAKS = "org.lineageos.lineageparts/.perf.GoTweaksSettings"
ROW_TITLE = "Flash power"


@pytest.fixture
def flash_cap(dut):
    if dut.sh(f"[ -e {CAP} ] && echo y || true") != "y":
        pytest.skip(f"no {CAP}: this build predates the Flash power tweak")
    return CAP


def test_flash_cap_follows_setting(dut, flash_cap):
    """Read-only: the kernel cap matches the setting (unset/0 = no cap = stock 1000 mA)."""
    want = dut.prop(PROP) or "0"
    assert dut.sh(f"cat {flash_cap}") == want, \
        f"{PROP}={want!r} but {flash_cap} reads {dut.sh(f'cat {flash_cap}')!r}"


@pytest.mark.timeout(60)
def test_flash_cap_applies_live(dut, flash_cap):
    """Each choice reaches the kernel within seconds, no reboot; the setting is put back."""
    before = dut.prop(PROP)
    try:
        for value in ("400", "700", "0"):
            dut.sh(f"setprop {PROP} {value}")
            dut.wait_for(f"cat {flash_cap}", lambda out, v=value: out.strip() == v, timeout=10, interval=1)
    finally:
        dut.sh(f"setprop {PROP} '{before}'")
        if before:
            dut.wait_for(f"cat {flash_cap}", lambda out: out.strip() == before, timeout=10, interval=1)


@pytest.mark.timeout(120)
def test_flash_power_row(dut, awake, flash_cap):
    """The row is in PVG100 System Tweaks and shows the current choice."""
    want = {"": "Full", "0": "Full", "700": "Reduced", "400": "Low"}.get(dut.prop(PROP), "?")
    try:
        assert "Status: ok" in dut.sh(f"am start -W -n {TWEAKS}")
        time.sleep(2)
        w, h = (int(x) for x in re.search(r"(\d+)x(\d+)", dut.sh("wm size")).groups())
        ui = ""
        for _ in range(8):   # the Camera category sits near the bottom: scroll to it
            ui = dut.sh("uiautomator dump /data/local/tmp/itest-ui.xml >/dev/null 2>&1; "
                        "cat /data/local/tmp/itest-ui.xml")
            if f'text="{ROW_TITLE}"' in ui:
                break
            dut.sh(f"input swipe {w // 2} {h * 3 // 4} {w // 2} {h // 4} 300")
            time.sleep(1)
        assert f'text="{ROW_TITLE}"' in ui, f"no '{ROW_TITLE}' row in PVG100 System Tweaks"
        summary = re.search(rf'text="{ROW_TITLE}".*?text="([^"]+)"', ui, re.S)
        assert summary and summary.group(1).startswith(want), \
            f"row summary {summary.group(1) if summary else None!r}, expected it to start with {want!r}"
    finally:
        dut.sh("input keyevent KEYCODE_HOME")
