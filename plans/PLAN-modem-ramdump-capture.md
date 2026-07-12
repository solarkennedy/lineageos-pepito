> ## ⛔ UPDATE 2026-07-06 (later) — RAMDUMP IS NOT VIABLE ON THIS DEVICE (reads all zeros)
> The captured `modem_crash.elf` is **89,308,990 bytes of zeros** — only **333 non-zero bytes**
> total, all in the ELF header/phdrs (file offset < 0xce). Every segment body, **including the
> loaded modem code at `0x86ce3000`, is entirely zero**. The AP physically cannot read the modem's
> DDR: `pil_do_ramdump()` (`peripheral-loader.c`) calls `pil_assign_mem_to_linux()` (hyp_assign
> transfer modem→HLOS) *and ignores its return value*, then reads the region; on this device that
> transfer does not make the memory readable (modem carveout stays hyp/XPU-protected — the same
> intractable `hyp_assign`/`MEM_PROT_ASSIGN -95` domain as `tz-hyp-assign` memory / PLAN-tz), so the
> reads return zeros. dmesg during capture also shows most crashes hit
> `Ramdump(ramdump_modem): No consumers. Aborting.. rc:-32` (no reader attached at that instant),
> and the one read that *did* attach produced the all-zero file. `/dev/mem` is absent; there is no
> AP-side path to the modem's live memory. **Do not spend more effort capturing modem ramdumps —
> the content is unreadable.** The register-context / F3-ring decode this runbook was written for is
> therefore impossible from an AP-collected dump. Redirect: see `PLAN-modem-disasm.md` — the
> remaining lead is the **QCCI service-match asymmetry** (RMTFS svc `0x0E` `qmi_client_init` works
> every boot; RFSA svc `0x1C` produces zero wire traffic), which is AP-side observable/fixable.
> The init.rc capture hook Kyle left in place can be reverted; it only ever yields zeros.

> **UPDATE 2026-07-06 — CAPTURED.** The adb-race method below (arm `dd` after `wait-for-device`)
> **cannot work on this device**: dmesg shows the modem's first PIL boot attempt (and its
> `rmts_get_buffer` ERR_FATAL) happens at kernel uptime ~253s, which is *before* adb becomes
> reachable on this device's boot timeline. Confirmed by two clean attempts via the method below:
> both landed with `crash_count` already frozen at a low number and 0 bytes captured.
> **Working method:** hook the arm sequence into `/vendor/etc/init/hw/init.xiaomi.rc` itself (device
> is Permissive, `/vendor` is remountable rw) so it runs on `on init` (very early, well before
> t=253s), writing to tmpfs (`/dev/*.elf`) since `/data` isn't mounted yet at that point:
> ```
> on init
>     write /sys/module/subsystem_restart/parameters/enable_ramdumps 1
>     write /sys/module/subsystem_restart/parameters/enable_mini_ramdumps 1
>     start vendor.ramdump-full
>     start vendor.ramdump-mini
>
> service vendor.ramdump-full /system/bin/dd if=/dev/ramdump_modem of=/dev/modem_crash.elf bs=1M
>     class core
>     user root
>     group root
>     oneshot
>     seclabel u:r:su:s0
>
> service vendor.ramdump-mini /system/bin/dd if=/dev/ramdump_md_modem of=/dev/modem_md.elf bs=1M
>     class core
>     user root
>     group root
>     oneshot
>     seclabel u:r:su:s0
> ```
> **Gotcha:** do NOT wrap `dd` in a shell script that backgrounds it with `&` and exits — init tears
> down the whole process's cgroup (killing detached children) the moment a `oneshot` service's main
> process exits. `dd` must be the literal service executable so it's the tracked process itself.
> After boot, pull with `cp /dev/modem_crash.elf /data/local/tmp/ && adb pull ...` once adb is up.
> Result: full dump captured first-try, 89,308,990 bytes, ELF type 4 (CORE), phnum 20 — matches
> expected geometry. Confirmed via dmesg this device's own boot hit the real crash (not a graceful
> restart): `Fatal error on the modem` → `fs_device_efs_rmts.c:161 ... EFS: rmts_get_buffer api fa`
> at kernel uptime ~253s/255s (double-crash, then suppressed by an existing "pepito bring-up"
> not-panicking patch). Minidump (`md_modem`) did NOT fill this run (service left `running`,
> 0 bytes) — modem only cycles once per boot before an existing patch stops it retrying, so there
> was no second natural crash window to also catch the minidump; worth another attempt if the
> minidump is still wanted. Captured file: `ramdump-capture/modem_crash.elf` (not yet pushed
> anywhere further — hand to whoever does the Q6 register/F3-ring decode). Byte-pattern grep for the
> known fatal args and crash strings found nothing raw in the file — consistent with the qdsp6m.qdb
> string-stripping caveat below; real analysis needs register-context/heap decode, not grep.
> The init.rc hook is **left in place on the device** (Kyle's choice) — every future boot will
> re-arm and re-capture into `/dev/modem_crash.elf` (tmpfs, lost on reboot unless copied out first).
> Revert: `cp /vendor/etc/init/hw/init.xiaomi.rc.bak-ramdump /vendor/etc/init/hw/init.xiaomi.rc`
> after `adb remount`.

# Runbook — Capture a modem ramdump at the `rmts_get_buffer` crash (pepito/PVG100, A16)

**Purpose:** grab a modem coredump around the `fs_device_efs_rmts.c:161 rmts_get_buffer` ERR_FATAL
so we can (a) find the Q6 crash register context → the exact code address in `rmts_api.c`, and
(b) decode the F3 message ring against `image/qdsp6m.qdb` to see which buffer path ran and its rc.
Background: `PLAN-modem-disasm.md` (radio7 sections), memory `radio-rmts-buffer-rootcause.md`.
This is the chosen unblock path (static disasm is dead — QShrink 4.0 stripped all msg strings).

**Device:** A16 = our build = adb serial **`c39a6acf`** (model PVG100, device `pepito`). The other
serial `81eed371` is the STOCK A11 phone — do NOT dump that one.

---

## What you're capturing
- **Full dump:** `/dev/ramdump_modem` → ELF32 `ET_CORE`, ~85 MB, 20 LOAD segs = the modem's entire
  DDR at SSR-shutdown (code + data + runtime heap). Created by `create_ramdump_device("modem")`
  (`pil-q6v5-mss.c`); read yields ELF (`ramdump.c do_elf_ramdump`).
- **Minidump:** `/dev/ramdump_md_modem` → curated debug regions the modem registers (F3 ring,
  err/crash context, key globals). Often has the crash context the full dump may lack — **capture
  this too.**

## Prerequisites
```bash
adb -s c39a6acf wait-for-device
adb -s c39a6acf root            # must show "restarting adbd as root" / already root; uid must be 0
adb -s c39a6acf shell 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; ls /sys/kernel/debug/msm_subsys'  # optional; only needed if you use the echo-restart trigger
```
State knobs (all under `/sys/devices/platform/soc/4080000.qcom,mss/subsys0/`): `state`
(ONLINE/OFFLINE), `crash_count`. Enable knob:
`/sys/module/subsystem_restart/parameters/enable_ramdumps`.

---

## THE WORKING METHOD — arm the reader during active crash-cycling

Key facts learned the hard way this session:
- The modem **crash-loops after boot** (`crash_count` climbs every ~2 s) for a while, then
  **stabilizes ONLINE** and `crash_count` freezes. You can only capture while it is *actively
  cycling*.
- A **real crash's** SSR runs `subsystem_shutdown → subsystem_ramdump → powerup`, so
  `subsystem_ramdump` dumps the modem DDR. `is_ramdump_enabled` gates it on `enable_ramdumps`.
- **DO NOT trigger with `echo restart > /sys/kernel/debug/msm_subsys/modem`.** That is a *graceful*
  restart: its SSR ramdump captures the *running/outgoing* modem (no crash context). Confirmed:
  the echo-restart dump had none of the fatal values. Let a **natural** crash arm the dump instead.
- The `dd` reader **blocks** on `/dev/ramdump_modem` until a crash arms it, then streams the ELF and
  exits at EOF. Arm it *before* the crash.

### Procedure
```bash
S=c39a6acf
adb -s $S root
adb -s $S shell '
  echo 1 > /sys/module/subsystem_restart/parameters/enable_ramdumps
  rm -f /data/local/tmp/modem_crash.elf /data/local/tmp/dd.log
  # arm the reader (blocks until a natural crash arms the dump)
  (dd if=/dev/ramdump_modem of=/data/local/tmp/modem_crash.elf bs=1M 2>/data/local/tmp/dd.log; \
     echo "DD_DONE rc=$?" >> /data/local/tmp/dd.log) &
  DDPID=$!
  # watch for the dump to fill (a real crash bumps crash_count and streams ~85MB)
  for i in $(seq 1 40); do
    sz=$(stat -c %s /data/local/tmp/modem_crash.elf 2>/dev/null)
    cc=$(cat /sys/devices/platform/soc/4080000.qcom,mss/subsys0/crash_count)
    echo "t=$((i*2))s crash_count=$cc dumpsize=$sz"
    if ! kill -0 $DDPID 2>/dev/null && [ "${sz:-0}" -gt 1000000 ]; then echo CAPTURED; break; fi
    sleep 2
  done
  echo 0 > /sys/module/subsystem_restart/parameters/enable_ramdumps   # dont leave SSRs blocking on a reader
  cat /data/local/tmp/dd.log; ls -l /data/local/tmp/modem_crash.elf
'
adb -s $S pull /data/local/tmp/modem_crash.elf ./modem_crash.elf
```

### Also grab the minidump (do the same, second device)
```bash
adb -s $S shell '
  echo 1 > /sys/module/subsystem_restart/parameters/enable_ramdumps
  echo 1 > /sys/module/subsystem_restart/parameters/enable_mini_ramdumps
  (dd if=/dev/ramdump_md_modem of=/data/local/tmp/modem_md.elf bs=1M 2>/dev/null; echo done) &
  # ... same watch loop, then disable both enables ...
'
adb -s $S pull /data/local/tmp/modem_md.elf ./modem_md.elf
```

### If the modem has already stabilized (crash_count frozen, no cycling)
Reboot to restart the crash cycle, then arm the reader *fast* (the first crashes come ~150–200 s
after kernel boot; don't dawdle rooting):
```bash
adb -s c39a6acf reboot; adb -s c39a6acf wait-for-device; adb -s c39a6acf root
# then run the WORKING METHOD block above immediately; you have a window while crash_count climbs
```
Watch `crash_count` — if it's incrementing, you're in the cycling window and the reader will catch
a dump within seconds. If it's frozen and `state=ONLINE`, it stabilized; reboot again.

---

## Deliver back
Hand over the pulled files (absolute paths) and the tail of `dd.log`:
- `modem_crash.elf` (full DDR) — **required**
- `modem_md.elf` (minidump) — **strongly wanted** (best shot at crash context + F3 ring)
- the `crash_count` value at capture time.

## Quick sanity of a good capture
```bash
python3 - <<'PY'
import struct
d=open('modem_crash.elf','rb').read()
assert d[:4]==b'\x7fELF', "not ELF"
print("type", struct.unpack_from('<H',d,16)[0], "phnum", struct.unpack_from('<H',d,0x2c)[0])
PY
```
Expect `type 4` (CORE), `phnum ~20`, size ~85 MB. Non-zero heap in seg @ va `0x889bc000` means live
runtime state was captured.

## Known caveat (why we want the minidump too)
Both full dumps captured so far (echo-restart AND natural-crash) did **not** contain the ERR_FATAL
args as data (`0x00180000`, `0x8904dec0`) or any crash text — the Q6 register/crash context is
likely in TCM/SMEM regions **not** included in the full `/dev/ramdump_modem` segment list, or the
dumped instant is between crashes. The **minidump** (`md_modem`) is the more likely carrier of the
saved crash context and the F3 ring, which is why it's worth grabbing. If neither has it, the
fallback is to locate the F3 message ring in the DDR heap and decode entries against
`qdsp6m.qdb` (`hash:ss_mask:ssid:line:file:string`), or to capture SMEM separately.
