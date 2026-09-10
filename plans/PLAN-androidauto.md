# PLAN — Android Auto (wired) on Palm PVG100 (pepito), LineageOS 23 / Android 16

Getting **wired Android Auto** projecting to a car head unit. Symptom that started this lane:
plug into the car → **"unsupported accessory" / "no installed apps"**, no AA.

**Status (2026-07-18): the entire app layer is SOLVED and baked into the build — the car now
does the AOA handshake and gearhead engages — but AA does not yet project because of a
Palm-side accessory-mode USB-transport instability (the car suspends the phone ~15 s in and the
session flaps).** Everything else (preinstall, permissions, certification, USB HAL) is resolved.

Cross-session detail + the raw evidence trail live in memory
`android-auto-accessory-status.md` (+ `wusb3801-typec-i2c.md`, `usb-adb-modem-composition.md`).

---

## 1. What wired AA actually requires (the gate chain we reverse-engineered)

A car head unit is the USB **host**; the phone is the **peripheral**. The car AOAs the phone
(GET_PROTOCOL → SEND_STRING → START, control reqs 51/52/53), the phone enters **accessory
mode**, gearhead opens the accessory FD, and the AA protocol streams over the accessory bulk
endpoints. For that to work on a non-Pixel/custom build, ALL of these must hold:

| # | Gate | Failure symptom | State |
|---|------|-----------------|-------|
| 1 | Kernel/gadget AOA support (`f_accessory`, `CONFIG_USB_F_ACC`, wired into `configfs.c::android_setup`) | accessory switch never happens | ✅ present, proven |
| 2 | Car will offer AOA to the phone's USB composition | car media-browses / ignores it | ✅ (adb/charging default; NOT mtp — see §4) |
| 3 | **gearhead preinstalled as a privileged system app** | **"Communication error 22 — not preinstalled"** | ✅ **stub baked in** (§3) |
| 4 | gearhead's USB-accessory handler component enabled | "no installed apps" fallback screen | ✅ (auto — NOT cert-gated, see §4) |
| 5 | gearhead attestation (`SECURITY_PATCHER`) | error / bail | ✅ passes with **no** Play cert (§4) |
| 6 | Nearby-devices runtime permission | **error 25** "allow Nearby Devices" | ✅ granted / car prompts in setup (§3) |
| 7 | **Stable accessory-mode USB link long enough to finish the AA handshake (~15 s)** | car SUSPENDS phone, flaps, no projection | ⛔ **OPEN — the remaining blocker (§5)** |

⭐ The real AA accessory identity string is **`manufacturer=Android` / `model="Android Open
Automotive Protocol"`** (NOT "Android Auto" — that early wrong string cost us a day of
false "no handler" results).

---

## 2. Bench tooling — the AOA probe

`scratchpad/aoa_probe.c` (libusb, build `gcc aoa_probe.c -o aoa_probe -lusb-1.0`) makes the
workstation act like a car: it drives GET_PROTOCOL → SEND_STRING (the real AA strings) →
START against the phone on USB, so we can exercise the whole phone-side stack **without a car**.
Usage: `./aoa_probe 18d1 4e11` (pass the phone's current VID:PID from `lsusb`). It switches the
phone to accessory mode (`18d1:2d01` accessory+adb) and gearhead reacts exactly as it would to
a car up to the point a real head unit is required.

---

## 3. What's baked into the build (survives flashes)

- **AA stub** — `AndroidAutoStubPrebuilt.apk` (Google-signed, cert SHA-256
  `1ca8dcc0…b65b5295`, versionCode `12552680`) + its privapp-permissions allowlist
  `com.google.android.projection.gearhead.xml`, sourced from
  **`NikGapps-Addon-16-AndroidAuto-20260222-signed.zip`** (date-matched to the baked
  `NikGapps-basic`). Placed into `vendor/pepito-gapps/product/{priv-app,etc/permissions}` by
  `scripts/extract-nikgapps.py`, which now **accepts multiple zips** (base + addon) — committed
  `lineageos-pepito@9d304a1` on `lineageos23.2`. Regenerate with:
  ```
  scripts/extract-nikgapps.py \
    vendor/pepito-gapps/source/NikGapps-basic-arm64-16-20260222-signed.zip \
    vendor/pepito-gapps/source/NikGapps-Addon-16-AndroidAuto-20260222-signed.zip
  ```
  A Play Store install of Android Auto then **grafts onto the stub** →
  `pkgFlags=[SYSTEM … UPDATED_SYSTEM_APP]`, `privateFlags=[… PRIVILEGED]` → error 22 cleared.
  (vendor/pepito-gapps stays gitignored/local — proprietary Google binaries.)
- **USB port HAL reverted to `1.3-service.basic`** — `device/xiaomi/mithorium-common/mithorium.mk`
  (uncommitted working-tree edit). The `1.1-service.typec` experiment both had a broken toggle
  ("couldn't switch") and blocked the car from AOAing on c39a6acf. See `usb-otg-host-dualrole`.
- **wusb3801 spurious-detach fix** — `kernel/xiaomi/msm8937/drivers/usb/typec/wusb3801.c`
  `hw_update()` now bails out on a failed status read instead of faking `status=0` (which was a
  phantom detach). Real latent bug; **not** the AA flap. Needs a kernel/boot.img flash.

### Per-unit (NOT in the image, resets on a clean `/data` wipe)
- The Play Store gearhead install (reinstall from Play after a clean flash — it re-grafts).
- Nearby-devices runtime perm: AA setup prompts for it, or
  `pm grant com.google.android.projection.gearhead android.permission.{NEARBY_WIFI_DEVICES,BLUETOOTH_SCAN,BLUETOOTH_CONNECT}`.

---

## 4. Falsified theories (do not re-chase)

- **The `persist.*.usb.config=adb` pin blocks AA** — FALSE. The pin does not block accessory
  mode; the car AOAs an adb/charging device fine (`usb-adb-modem-composition`).
- **MTP composition helps** — FALSE and counterproductive: with MTP the car media-browses and
  never offers AOA. A leftover `svc usb setScreenUnlockedFunctions mtp` was a red herring.
- **USB debugging must be off** — FALSE (Kyle's Pixel AOAs with USB debugging ON). AA's own
  "turn off USB debugging" tip is generic.
- **GSF registration / Play certification is required** — FALSE. c39a6acf stayed Play-uncertified
  (Integrity -12) *after* registering, yet Gold projects-far with **zero** registration. gearhead's
  `SECURITY_PATCHER` is its own check, not Play Integrity. **Drop the whole cert lane.**
- **The typec HAL / DRP is the flap cause** — FALSE. Gold on the basic HAL flaps identically.
- **The wusb3801 CC sensor spuriously detaches during the session** — a real bug, but FALSE for
  this flap (no read-failure warnings, low IRQ count, the drop is a host-initiated USB *suspend*).
- **Cable / car** — FALSE. A known-good cable the Pixel works on gives the identical symptom;
  the Pixel projects fine on the same car + cable.

---

## 5. ⛔ The open blocker — accessory-mode USB-transport instability

**The constant across every attempt:** accessory enumerates (`configfs-gadget … high-speed
config #1`, `Avail curr = 500`) → **~15 s** → host-initiated **`CI13XXX_SUSPEND`** (`Avail
curr = 2`, VBUS still present, i.e. the car stops SOF) → `DISCONNECT` → re-enumerate → repeat.
gearhead *inconsistently* reaches `Got USB accessory fd` but never finishes the AA protocol
inside the car's ~15 s handshake window, so the car gives up and suspends. (The audible
"noises" are RingtonePlayer firing on each connect.)

⭐ **Decisive clue: plain adb-over-USB is rock-stable the entire time** — so the instability is
specific to **accessory mode + a real car host**, not general USB signal/power.

### Next-session diagnostic plan (prioritized)
- [ ] **PC accessory-mode stress:** put the Palm in accessory mode against the workstation
      (`aoa_probe`, then a sustained bulk read/write over the AOA endpoints from a small
      libusb host). If it flaps on a PC too → an `f_accessory`/gadget-composition bug we own;
      if it's stable on a PC and only flaps on the car → a car-host electrical/timing interaction.
- [ ] **Compare descriptors:** capture the Palm's vs a Pixel's accessory-mode enumeration on the
      same car (`lsusb -v`/kernel), diff endpoint/config/bcdUSB/current.
- [ ] **f_accessory HS bulk endpoint audit:** compare the accessory composition's high-speed bulk
      IN/OUT endpoint setup on `ci13xxx`/`msm_hsusb` against the *stable* adb composition — look
      for a wMaxPacketSize / bInterval / remote-wakeup / current-draw difference that would make
      a host suspend it.
- [ ] **Suspend/remote-wakeup angle:** the `Avail curr = 2` suspend is the host suspending the
      device. Check whether the accessory gadget advertises remote wakeup / whether msm_hsusb
      is entering LPM and failing to keep the link, vs how the phone behaves under adb (which
      doesn't suspend). `ep_dequeue: Unable to dequeue while in LPM` appears in the flap.
- [ ] **AA connection logging:** enable gearhead verbose (`setprop log.tag.CAR.GAL VERBOSE`,
      `CAR.SETUP` etc.) to see how far the version/SSL/service-discovery handshake gets before
      the drop, to distinguish "USB drops mid-handshake" from "handshake stalls then car drops".

### Recovery / gotchas
- Debugging in the car needs **TCP adb = Wi-Fi on**, which is the `bhy-hub-wedge-no-recovery`
  trigger (unicast churn). Keep the **screen on** (long timeout) to avoid it; prefer USB / a
  short window.
- `am force-stop com.google.android.projection.gearhead` clears a wedged/half-open session (the
  session ID stops repeating) — do this between attempts.
- `logcat -b kernel` works as shell; watch `CI13XXX_*`, `Avail curr`, `configfs-gadget`.

---

## 6. Build / flash checklist for a working AA image

1. Build the `_gapps` target (stub + basic HAL baked in) and flash.
2. After a **clean** flash: install Android Auto from Play (re-grafts onto the stub), grant the
   nearby-devices perm (or let AA setup prompt).
3. **No** GSF registration needed.
3a. Notification access: STAGED 2026-09-10 (uncommitted, unflashed) — gapps-only overlay sets
   `config_defaultListenerAccessPackages=com.google.android.projection.gearhead`, so the stub's
   `SharedNotificationListenerManager$ListenerService` lands in `enabled_notification_listeners`
   on FIRST boot (no `notification_policy.xml` yet). Fresh-flash only; dirty-flashed units keep
   needing the manual toggle. Validate: fresh flash → `settings get secure
   enabled_notification_listeners` shows the gearhead component before AA setup runs.
4. (Optional) flash the kernel with the wusb3801 bail-out fix.
5. Plug into the car → currently stalls at §5. Once §5 is solved, AA should project.

## 7. References
- Memory: `android-auto-accessory-status.md` (primary), `wusb3801-typec-i2c.md`,
  `usb-otg-host-dualrole.md`, `usb-adb-modem-composition.md`, `bhy-hub-wedge-no-recovery.md`.
- Code/build: `scripts/extract-nikgapps.py`, `vendor/pepito-gapps/`,
  `device/xiaomi/mithorium-common/mithorium.mk` (USB HAL),
  `kernel/xiaomi/msm8937/drivers/usb/{gadget/function/f_accessory.c,typec/wusb3801.c}`.
- Tool: `scratchpad/aoa_probe.c`.
