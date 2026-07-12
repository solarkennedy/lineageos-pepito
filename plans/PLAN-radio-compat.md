# LineageOS 23.2 — HIDL→AIDL Radio Compat Shim (pepito/PVG100)

> **Revalidated 2026-07-05 (session `radio5`) — STILL RELEVANT, still the active SIM/registration
> blocker; NOT deprecated.** Live re-check on A16 with `persist.vendor.radio.autostart=1`: HIDL
> `IRadio/slot1` v1.0–1.5 all published (shim input ✅), `vendor.radio-compat` `running`, yet
> **zero AIDL radio interfaces in `lshal`**, `mRadioPowerState=2`, `mVoiceRegState=OUT_OF_SERVICE`,
> `mDefaultSubId=-1`. The shim's threads are parked **identically** to the 2026-06-29 capture
> (main `android.hardwar` in `binder_ioctl_write_read`, `HwBinder:_1` in `binder_ioctl_write_read`,
> one idle `futex_wait`). So nothing regressed and nothing self-fixed — the investigation below
> (steps 1–4) has simply **not been started yet**. Note the modem is still a post-fatal zombie
> (`subsys0 ONLINE`, EFS fatal every boot per `PLAN-radio.md`), so the "shim blocks on a sync HIDL
> call qcril can't answer against the dead modem" hypothesis (step 2 / "Relationship to the modem
> keystone") remains the top lead — HIDL `getService` succeeds but live QMI-backed calls may not.
> Resume at **step 1** (strace/stack the hung shim) whenever radio work returns here.

**Status (2026-06-29):** The qcril HIDL radio stack is up, but the framework has
**no usable radio** (`mRadioPowerState=2 UNAVAILABLE`, `mDefaultSubId=-1`, no SIM/
registration) because the **`android.hardware.radio-service.compat`** shim — the
HIDL→AIDL bridge the Android 16 framework requires — **runs but publishes zero AIDL
radio interfaces.** This is the lone blocker between "HIDL `IRadio/slot1` published"
and "framework can talk to the radio." It is *separate* from (and downstream of) the
modem `sharedmem_qmi` work tracked in `PLAN-radio.md`.

> Spun out of `PLAN-radio.md` (the slot2 sub-bug + this AIDL-not-usable wall were
> discovered there). This file owns the compat-shim investigation.

## Legend
- ✅ working / proven  - 🔧 present, not verified  - ❌ broken / active blocker

---

## Why this layer exists

qcril is a **HIDL** RIL (`android.hardware.radio@1.5`). The Android 13+ telephony
framework (RILJ) speaks **AIDL** (`android.hardware.radio.{sim,network,data,voice,
modem,messaging,config}`). AOSP bridges them with a generic shim:

```
modem ── QMI/QRTR ──> qcrild ──> HIDL android.hardware.radio@1.0–1.5::IRadio/slot1   ✅ up
                                          │
                          android.hardware.radio-service.compat   ← THE SHIM (this file)
                          (hardware/interfaces/radio/aidl/compat/) │
                                          ▼
                          AIDL android.hardware.radio.*.IRadio*/slot1   ❌ NOT published
                                          │
                                  RILJ / framework  →  mRadioPowerState=UNAVAILABLE
```

The shim is the generic AOSP one; every Lineage Mi8937 sibling (santoni/land/…) that
runs this same nightly + HIDL qcril must use it too — so it is expected to *work*.

---

## Current symptom (clean build, 2026-06-29)

| Check | Result |
|---|---|
| HIDL `IRadio/slot1` v1.0–1.5 + `radio.config@1.0/1.1` (shim's **input**) | ✅ up (qcrild) |
| Manifest declares AIDL slot1 (`IRadioSim/Data/Network/Voice/Modem/Messaging/slot1`) | ✅ present |
| slot2 removed from manifest (single-SIM) | ✅ baked into clean build |
| `vendor.radio-compat` service | ✅ `running`, pid stable (not crash-looping) |
| AIDL radio interfaces in `lshal` (shim's **output**) | ❌ **none** |
| `mRadioPowerState` | ❌ **2 (UNAVAILABLE)** |
| Shim log output (`Found N slot(s)`, `Publishing …`, any error/crash) | ❌ **silent** — no logs, no tombstone |

### Thread/fd evidence (the shim is *hung*, not failing visibly)

```
pid 2564 (android.hardware.radio-service.compat), threads:
  android.hardwar  -> binder_ioctl_write_read     ← main thread in a SYNC binder call
  HwBinder:2564_1  -> binder_ioctl_write_read      ← HIDL pool (talks to qcril)
  android.hardwar  -> futex_wait_queue_me          ← idle
fds: /dev/binderfs/binder (main, fd7) + /dev/binderfs/hwbinder (fd5)   ← BOTH binders open
lshal: provides nothing
```

The shim holds the **main binder open** (so it *can* register AIDL) and the HwBinder
(so it *can* call qcril), but it never produces any service. The main thread sitting
in a synchronous `binder_ioctl_write_read` + total log silence ⇒ it most likely
**blocks inside a synchronous call during startup, before it finishes publishing.**

---

## Ruled out

- **slot2 hang** — was a real bug (shim looped forever on `getService(IRadio/slot2)`
  on the dual-SIM manifest); **fixed** by removing slot2 from `manifest.xml`. The
  slot2 loop is gone (0 hits) and is *not* this issue.
- **"Thread Pool max thread count is 0" warnings** — a red herring; on the live
  device those lines belong to `display.qservice`, not the radio shim.
- **Missing VINTF declarations** — the AIDL slot1 instances *are* declared.
- **Binder context (vndbinder vs binder)** — the shim has `/dev/binderfs/binder`
  open, so it is on the framework-facing binder, not stuck on vndbinder.
- **Shim crash** — stable pid, no tombstone, `init.svc.vendor.radio-compat=running`.
- **The modem `sharedmem_qmi` EFS fatal** — related but *separate* (see below); the
  HIDL layer already published, so this is above the modem-transport layer.

---

## How the shim works (source) — where it can hang

`hardware/interfaces/radio/aidl/compat/service/service.cpp`:

```c
static void main() {
    publishRadioConfig();                              // (1) getService(HIDL IRadioConfig) → publish AIDL config
    auto slots = hidl_utils::listManifestByInterface(V1_0::IRadio::descriptor);
    LOG(INFO) << "Found " << slots.size() << " slot(s)";   // (2) ← we never see this log
    for (slot : slots) publishRadio(slot);             // (3) per slot
}
static void publishRadio(slot) {
    auto radioHidl = V1_5::IRadio::getService(slot);   // (3a) BLOCKS on HIDL getService
    CHECK(radioHidl) ...
    // builds CallbackManager, then for each AIDL sub-iface:
    publishRadioHal<RadioData/Messaging/Modem/Network/Sim/Voice>(ctx, radioHidl, cm, slot);
    //   → AServiceManager_isDeclared(instance)  → AServiceManager_addService(...)
}
```

Because the shim is **silent even at step (2)** ("Found N slot(s)"), it is likely
stuck in **(1) `publishRadioConfig()`** or its first HIDL interaction — *before* the
slot loop. Candidate blocking points:
- `config::V1_1::IRadioConfig::getService()` or `V1_5::IRadio::getService(slot)`
  not returning (unlikely — both HIDL services show in `lshal`).
- A **synchronous HIDL call into qcril** during callback setup (e.g.
  `setResponseFunctions`/`CallbackManager`) that **qcril never answers** — plausibly
  because qcril is wedged on the **post-fatal zombie modem** (it answers `getService`
  but blocks on calls that need live modem QMI). This is the strongest lead and ties
  back to the Cluster-A modem keystone.
- A deadlock in the shim's own threadpool/callback init.

---

## Investigation plan (ordered)

1. **Pin down WHERE it blocks.** Restart the shim under observation:
   - `strace -f -p $(pidof android.hardware.radio-service.compat)` (or restart it
     attached) to see the syscall/ioctl it's parked in and the binder peer.
   - Root: `cat /proc/<pid>/task/<tid>/stack` for the main thread's kernel stack.
   - Raise its log level (it uses libbase `LOG`); confirm whether it even reaches
     `Found N slot(s)`. If it never logs that, the hang is in `publishRadioConfig()`
     or earlier.
2. **Test the qcril-dependency hypothesis.** Determine whether the blocking sync call
   is *into qcril* and whether qcril is itself wedged on the modem:
   - Check qcril's threads/wchan while the shim hangs.
   - If the shim's HwBinder call targets qcril and qcril is blocked on modem QMI →
     this blocker is **gated by the modem `sharedmem_qmi` fix** (`PLAN-radio.md`).
     That would mean: do the modem fix first, then re-test the shim.
3. **Two-device / sibling comparison (highest-value config check).** Confirm a
   working sibling uses this *same* shim and that it publishes AIDL there:
   - On a santoni/land build (or its `lshal`/init), verify `vendor.radio-compat`
     publishes `android.hardware.radio.sim.IRadioSim/slot1` etc.
   - Diff their `vendor.radio-compat` `.rc`, the radio VINTF manifest, and any
     `setprop`/sequencing (does the sibling gate the shim on a modem-ready trigger?).
   - If siblings publish AIDL fine with the same shim → the delta is our config/
     sequence (or the wedged modem); if they *also* need the modem healthy first →
     confirms the dependency.
4. **SELinux.** Permissive during bring-up, but collect `avc: denied` for
   `vendor.radio-compat` (domain, `add_service`, `binder`, `hwservice`) so the
   eventual enforcing pass isn't surprised — and to rule out a silent denial.
5. **Sequencing.** The shim is `class hal` (eager, boots before qcril is ready). If
   it must (re)bind qcril after qcril publishes HIDL, check whether it retries or
   needs an `on property:` trigger like the sibling (today its `.rc` is bare —
   no `interface aidl` lines, no triggers).

---

## Relationship to the modem keystone

Strong possibility this is **not independently fixable**: if the shim blocks in a
synchronous HIDL call that qcril can't service because the **modem is a post-fatal
zombie** (`rmts_get_buffer` EFS fatal → `sharedmem_qmi` missing, `PLAN-radio.md` /
`MEMORY.md` Cluster A), then landing the modem `sharedmem_qmi` port may unblock the
shim for free. **Sequencing recommendation:** do step 1–2 to confirm the dependency;
if the shim is waiting on qcril↔modem, prioritize the modem fix and re-test the shim
before doing shim-specific work. If the shim hangs *independent* of qcril responses,
it's a standalone shim/config bug to fix here.

---

## Key files / commands / facts

**Source:**
- Shim: `hardware/interfaces/radio/aidl/compat/service/service.cpp` (+ `hidl-utils.cpp`).
- Bridge lib: `hardware/interfaces/radio/aidl/compat/libradiocompat/`.
- Init: `/vendor/etc/init/…radio…compat….rc` → `service vendor.radio-compat
  /vendor/bin/hw/android.hardware.radio-service.compat` (`class hal`, `user nobody`,
  `group system`) — **no `interface aidl` lines, no triggers** (compare to sibling).
- Manifest: `device/xiaomi/mithorium-common/manifest.xml` (slot2 removed = the
  staged single-SIM fix; AIDL slot1 instances declared).

**Live checks (A16 = `c39a6acf`; enable radio first):**
```bash
S=c39a6acf
adb -s $S shell 'setprop persist.vendor.radio.autostart 1; start vendor.qcrild'   # bring up HIDL qcril
adb -s $S shell 'lshal | grep -iE "radio@1.[0-9]::IRadio/slot1"'                   # HIDL input (should be up)
adb -s $S shell 'lshal | grep -iE "radio.(sim|network|data|voice|modem|messaging)"' # AIDL output (currently empty)
adb -s $S shell 'dumpsys telephony.registry | grep -E "mRadioPowerState|mDefaultSubId"'  # want PowerState=1
P=$(adb -s $S shell pidof android.hardware.radio-service.compat)
adb -s $S shell "for t in /proc/$P/task/*; do echo \$(cat \$t/comm)=\$(cat \$t/wchan); done"  # where it's parked
```

**Bench:** A11=`81eed371` (stock ground truth), A16=`c39a6acf` (target). Device is
currently hand-driven: `persist.vendor.radio.autostart=1`, qcril running.

## Done / next

- [x] slot2 removed from manifest (single-SIM) — slot2 hang eliminated.
- [x] Confirmed (clean build) the shim runs+stable but publishes 0 AIDL; `mRadioPowerState=2`.
- [x] Ruled out: threadpool warning, manifest declarations, binder context, crash.
- [ ] **Step 1:** strace/stack the hung shim → exact blocking call.
- [ ] **Step 2:** confirm/deny the qcril↔modem-zombie dependency.
- [ ] **Step 3:** sibling comparison (does the same shim publish AIDL on santoni/land?).
- [ ] SELinux denials audit; sequencing/`.rc` comparison.
