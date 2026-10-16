# mglru-bench — reclaim/lmkd measurement harness (PLAN-mglru Phase 0)

Plan: `plans/PLAN-mglru.md`. Measures the thing MGLRU is supposed to improve — how
often reclaim pressure turns into lmkd kills and cold starts — so the same scripts give
the baseline on today's kernel and both arms of the kill-switch A/B later.

Unit: `${PEPITO_ADB:-dut1-adb}`. Host-side bash, everything over adb; the scripts wake and
unlock the unit, keep the screen on for the run, and never reboot, flash or toggle a radio.
Don't run them while another session is capturing on the unit.

| Script | What it measures |
|---|---|
| `vmstat-delta.sh snap F` / `diff A B` / `watch TAG SECS` | `/proc/vmstat` reclaim counters, memory PSI stall time, kswapd CPU, `dumpsys activity lmk` kill count, zram/meminfo gauges; `diff` prints deltas plus `steal_per_scan`, `refault_per_steal`, `direct_share` |
| `app-cycle.sh [-r ROUNDS] [-d DWELL] [-t TAG] [apps…]` | round-robin launches of 15 apps (`lib.sh DEFAULT_APPS`); round 1 primes, rounds 2+ count COLD (killed) vs WARM/HOT starts and mean `TotalTime` |
| `hog-resume.sh [-n ITER] [-m MB] [-t TAG] [apps…]` | the zram lane's anon hog (`head -c (MB+100)m /dev/zero \| tail -c MBm`, default 1200 MB) then resume Settings/Messages/Jelly/Aperture: process survived?, LaunchState, TotalTime |

Each run writes `results/<stamp>-<tag>/`: `meta.txt` (serial, build, kernel, `lru_gen`
state, zram/swappiness/lmk props), the CSV, `before/after` snapshots, `delta.txt`, and
`killlog.*.txt` — the `lowmemorykiller` logcat lines for the window, one per victim with
`oom_score_adj` and the reason (`low watermark is breached`, `… and swap is low`).

A/B use (Phase 2): same boot, flip `/sys/kernel/mm/lru_gen/enabled`, idle ~2 min, run; the
`lru_gen` line in `meta.txt` and the snapshots records the arm. Interleave arms.

## Gotchas found on 2026-10-15

- `am start -W` returns `LaunchState: UNKNOWN` when the screen is off, or when the target
  process is being killed as it launches. After the hog, lmkd's "swap is low" sweep keeps
  killing for ~10 s; `hog-resume.sh` waits 20 s before resuming for that reason.
- `pidof <pkg>` also matches `<pkg>:sub` processes; `lib.sh pid_of` uses an exact `ps` name match.
- A snapshot is ~9 s of adb round trips, so `watch` windows are longer than asked.
- dut1's keyguard is swipe-only; `android-unlock-dut1` dismisses it but exits 1 wanting a
  pattern grid. `bench_awake` trusts `isKeyguardShowing`, not the exit code.
- Settings' `LaunchState` is unreliable (`UNKNOWN` after an lmkd kill, and for a warm
  `SettingsHomepageActivity`); read `survived` + `TotalTime` for it (~400 ms hot, ~560 ms
  after an lmkd kill, ~1300 ms after `force-stop`).
- 15 apps all fit in RAM+lz4 zram once warm: a second `app-cycle` run straight after the
  first showed 0/45 cold, 0 kills. Run it from a cold-ish state (after a hog, or add apps)
  if the kill count is the point; `hog-resume` is the pressure test.
- lmkd on this build logs kills as logcat tag `lowmemorykiller` (not kmsg); the count in
  `dumpsys activity lmk` is cumulative since boot.
