# LineageOS 24.0 (Android 17) for the Palm PVG100 ("pepito")

This is the landing repo for the port, on branch `lineageos24.0`. It holds the
manifest, the build/flash/release scripts, the plans and the public README. It
is a git worktree of `~/Projects/lineageos-pepito` (branch `lineageos23.2`,
Android 16, now in maintenance).

**This repo is public.** No keys, tokens, IMEIs or unlock patterns in anything
committed here (`.gitignore` explains the one time a key nearly landed).

## Where things live

| What | Where |
|---|---|
| 24.0 source tree | **build server only**: `10.0.2.43:~/android/lineage-24` (a plain `repo` checkout) |
| This machine (netbook4) | no 24.0 source. `~/android/lineage-24/` holds only `flash-staging/` |
| Pepito changes | forks under `github.com/solarkennedy/`, pinned in `manifests/pepito.xml` |
| 23.2 source tree | `~/android/lineage-23` here (full checkout; read it for history, don't assume it matches 24.0) |
| Plans / investigation notes | `plans/PLAN-*.md`; `plans/PLAN-android17.md` is the live one for this branch |
| Release signing keys | build server, `vendor/lineage-priv/keys/` — never copied here |

The source of truth for a build is **what is pushed**. A change exists for the
build only once it is committed and pushed to its fork (and the fork is in
`manifests/pepito.xml`). To read or search 24.0 code, `ssh 10.0.2.43`.

## Device model

Pepito is a runtime-detected variant of the unified `lineage_Mi8937` target
(MSM8940, Adreno 505, kernel 4.19), sharing its device tree with the Xiaomi
siblings. Lunch is `lineage_Mi8937 cp2a userdebug`; the GApps flavor is
`lineage_Mi8937_gapps`. Push each change as deep as it can go without breaking
siblings: `mithorium-common` only for what is true of every variant,
`device/xiaomi/Mi8937` for the Adreno 505 group, and pepito-only behaviour
behind kernel DTS overrides, `ro.vendor.xiaomi.device=pepito` triggers or the
libinit variant branch.

The PVG100 has no fastboot. Flashing is over Qualcomm EDL (9008) with `qdl`, or
an OTA zip through recovery. Boot and recovery images need the signature graft
(`device/xiaomi/mithorium-common/boot-signing/sign-boot-graft.py`); the build
applies it.

## Build, flash, release

Kyle runs builds and flashes himself. Stage the change, say what to run, stop.
Do not flash, reboot a phone into EDL, or start a release without being asked.

```bash
./scripts/build-lineage24-remotely.sh            # sync the manifest on the server, build, stage + fetch flash images
./scripts/build-lineage24-remotely.sh --gapps
~/android/lineage-24/flash-staging/flash-staging.sh   # EDL-flash the staged images (hard-wired to dut1 via android16-adb; --no-adb otherwise)
./scripts/release-all.sh [--gapps] [--dry-run]   # changelog, build + release each flavor, tag every repo
```

`release-all.sh` first requires a green `tests/integration` run on a build of
the exact pushed source (`scripts/test-gate.py`, `tests/integration/README.md`).

A release publishes **one zip per flavor**: the OTA zip with `README.md` and
the EDL kit (`edl/`) packed in and re-signed. Users rebuild the raw images from
it with `tools/ota2raw`. `release.sh` runs on the build server and must run
before the next build replaces `out/`; `--package-only` builds and verifies the
zip without publishing. See `scripts/README.md`.

The 23.2 scripts (`*-lineage23*`, and the release scripts on the
`lineageos23.2` branch) are separate. Do not change them when working on 24.0
unless asked.

## Bench phones

The roster is `~/.config/pepito/units.conf`; each unit has an adb wrapper
(`dut1-adb`, `gold-adb`, `silver-adb`, `new2-adb`, `daily-adb`). **Check
`getprop ro.serialno` before acting on a phone.** `new2` is Kyle's daily
phone. Other agent sessions may be running captures on bench phones (look for
`diag_mdlog` or strace jobs in `ps`) — don't toggle a radio, Wi-Fi or
Bluetooth under them.

Pattern-locked phones: run `android-unlock-<nick>` (`new2`, `dut1`, `silver`)
whenever you need the screen unlocked; no need to ask. The patterns live in the
units.conf header, never in this repo. Each failed run counts as a wrong
attempt (five trigger a 30 s lockout), so don't loop it.

## Working habits that have mattered

- A priv-app requesting a `signature|privileged` permission needs its
  allowlist entry in the same commit, or the phone bootloops
  (`scripts/audit-privapp-permissions.py` checks a built tree).
- Device sepolicy goes in the device trees, not in `system/sepolicy`.
- Never regenerate `mithorium-common` vendor blobs with extract-utils.
- Recursive greps through the `rtk` wrapper can silently return nothing; use
  `rtk proxy grep` when a zero-match result matters.
- Keep `plans/PLAN-android17.md` current when a bench result or decision lands.
