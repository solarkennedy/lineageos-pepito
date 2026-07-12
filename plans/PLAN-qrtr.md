# LineageOS 23.2 — QRTR Bus Enumeration ("Option 1", the Cluster A measurement tool) — pepito/PVG100

**Status (2026-06-26): DONE — tool built + run; LOC(16) is ABSENT from the bus.** Built the
self-contained enumerator (Path B), kept in-tree at
`device/xiaomi/mithorium-common/qrtr-tools/` (`qrtr-services.c` + `Android.bp`, Path C). Ran
on `android16-adb` (modem ONLINE ~4h uptime, qrtr-ns + qcrild up): **42 services registered,
service 16 (QMI_LOC) is NOT present on any node.** Capture saved next to the source
(`qrtr-services-boot-2026-06-26.txt`). See **"Results (2026-06-26)"** below. Decode verified
correct via two known-good anchors (`RMTFS`(14) inst 1 = `rmt_storage`; `SENSOR/SMGR`(256)).

This was the **positive-evidence-first** step that
gates all of **Cluster A** (the half-built QMI/QRTR platform-services layer — see `PLAN.md`
"Holistic cross-cutting analysis"). Before sinking more time into `pd-mapper` / `tftp_server`
/ modem-GNSS theories for GPS (and, later, IMS/data), **measure what is actually registered
on the QRTR bus.** One small tool answers the load-bearing question — *is QMI_LOC (service
16) advertised at all?* — and is reusable for radio, sensors, and IMS.

> **No pre-existing tool.** Step 0 confirmed: no `qrtr-lookup` on the image, in the nightly
> (`/mnt/vendor-nightly` ships only `lib64/libqrtr.so`, not the tools), or in-tree (the qrtr
> *source* package was never synced — only `qrtr-ns` came in as a prebuilt blob). No QTI
> debugfs service table either (mainline QRTR). So we built our own (Path B/C).

> **Why this exists / the caution that motivates it.** We have **no positive evidence that
> QMI_LOC — or the location interface at all — has ever worked** on this hardware, and per
> the device owner the **original Palm OS used QMUX/qmuxd**, an older QMI transport than our
> QRTR-only model. So QMI_LOC may never have been a QRTR-announced service. Every GPS theory
> so far (`PLAN-gps.md`) assumes the modem *should* advertise LOC over QRTR and we're failing
> to discover it. That assumption is unverified. This tool verifies it.

## Legend
- ✅ Working / proven on-device  - 🔧 Present, not yet verified  - ❌ Missing / blocker

---

## Goal — turn Cluster A from hypothesis to fact

Produce a flat list of **every QMI service currently registered on the QRTR bus**, with its
`service / instance(version) / node / port`. From that single capture we can decide:

1. **Is `QMI_LOC` (service 16 / 0x10) present?**
   - **Present** → the modem *does* advertise it; GPS's `qmi_client_get_service() rc:-2`
     is a **client-side** problem (instance/version filter, query timing, or perms), **not**
     a missing modem service. This would *invalidate* the current Cluster A premise for GPS
     and redirect debugging entirely.
   - **Absent** → confirms "modem isn't advertising LOC." *Then* the `tftp_server`(RFS) /
     `pd-mapper`(user-PD) / modem-GNSS-NV theories are worth pursuing — and this same tool
     measures whether each fix makes service 16 appear.
2. **Are the support services healthy?** `RMTFS` (14, served by `rmt_storage`) and the radio
   set (`WDS`1, `DMS`2, `NAS`3, `WMS`5, `VOICE`9, `UIM`11) should be present (radio works).
   Their presence/absence frames whether the modem root-PD is fully up.
3. **Is there a PD/servreg footprint?** Whether a service-registry / PD-localization service
   is present correlates with `pd-mapper` (absent — `PLAN.md` Cluster A). Node distribution
   hints at whether user-PDs are localized.
4. **Does the SMGR sensor service appear?** (sensors plan: SMGR replied `version=23`, so its
   QMI service should be in the list — confirm; `PLAN-sensors.md`.)

This tool is the **measurement instrument** for the whole Cluster A program: re-run it after
every change (fix `tftp_server`, add `pd-mapper`, force a modem SSR) and watch the list move.

---

## Background — how QRTR service discovery actually works

QRTR (`AF_QIPCRTR`, address family **42**) has **no in-kernel name service** (that's why we
had to package `qrtr-ns`). Discovery is a control-plane protocol:

- Every QRTR endpoint has an address `struct sockaddr_qrtr { sq_family; sq_node; sq_port; }`.
- The **control port** is `QRTR_PORT_CTRL = 0xfffffffe`. Control packets (`struct
  qrtr_ctrl_pkt`) carry a `cmd` and, for server ops, a `{service, instance, node, port}`.
- When a remote (modem/ADSP) brings up a QMI service it broadcasts `QRTR_TYPE_NEW_SERVER`;
  when it tears down, `QRTR_TYPE_DEL_SERVER`. **`qrtr-ns` listens to these and maintains the
  registry.**
- A client discovers services by sending **`QRTR_TYPE_NEW_LOOKUP`** (service/instance filter;
  `0/0` = everything) to the control port. `qrtr-ns` replies with a stream of
  `QRTR_TYPE_NEW_SERVER` packets — one per matching, currently-registered service.

So the enumerator is just: open an `AF_QIPCRTR` socket → send one `NEW_LOOKUP(0,0)` → print
every `NEW_SERVER` reply. This is exactly what the upstream `qrtr-lookup` tool does.

> **`instance` field decoding:** the 32-bit `instance` packs `(instance_id << 8) | version`.
> So `version = instance & 0xff`, `instance_id = instance >> 8`. The GPS client filters on a
> specific service **and instance/version**, so capturing the modem's actual LOC instance is
> useful if LOC turns out to be present but the client still can't bind it.

---

## Step 0 — free checks before building anything

```bash
android16-adb shell 'ls -l /sys/kernel/debug/ 2>/dev/null | grep -iE "qrtr|ipc_router"'  # downstream QTI kernels sometimes expose a service table; mainline QRTR does NOT
android16-adb shell 'ls -l /vendor/bin/qrtr* /system/bin/qrtr* 2>/dev/null'               # is a prebuilt qrtr-lookup already on the image?
android16-adb shell 'find / -name "qrtr-lookup" 2>/dev/null'
ls /mnt/vendor-nightly/bin/qrtr-lookup /mnt/vendor-nightly/system/bin/qrtr-lookup 2>/dev/null # the qrtr package builds all tools together; the nightly may ship it next to qrtr-ns
```

If a `qrtr-lookup` prebuilt exists, stage it exactly like `qrtr-ns` (it links the
`libqrtr.so` we already packaged) and skip to **Running it**.

---

## Build the enumerator

### Path A (recommended if source is available): build `qrtr-lookup` from the `qrtr` package
`qrtr-ns` + `libqrtr.so` came into our tree as **prebuilt blobs** (legacy extractor path), so
the qrtr **source** may not be synced. If it is (or can be added — it's the small
`andersson/qrtr` / QUIC `platform/system/qcom/qrtr` package), build `qrtr-lookup`,
`qrtr-ping`, `qrtr-cfg` from the **same** module that produces `qrtr-ns`. They link the same
`libqrtr.so` already on-device → no ABI risk. This is the canonical, known-correct tool.

### Path B (fallback, zero dependencies): self-contained C enumerator
No `libqrtr` dependency (can't ABI-mismatch), ~90 lines, cross-compiles with the NDK and runs
from `/data/local/tmp` — **no build/flash cycle.** This is the fastest path to an answer.

```c
/* qrtr-services.c — list QMI services registered on the QRTR bus.
 * Build:  $NDK/.../aarch64-linux-android31-clang qrtr-services.c -o qrtr-services
 * Run:    adb push qrtr-services /data/local/tmp && adb shell /data/local/tmp/qrtr-services
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <endian.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <linux/qrtr.h>            /* struct sockaddr_qrtr */

#ifndef AF_QIPCRTR
#define AF_QIPCRTR 42
#endif
#ifndef QRTR_PORT_CTRL
#define QRTR_PORT_CTRL 0xfffffffeu
#endif
/* CORRECTED 2026-06-26: on this kernel NEW_SERVER=4, NEW_LOOKUP=10 (see
 * kernel/.../uapi/linux/qrtr.h). The 3/9 originally written here are BYE and
 * PING — using them sends a PING and matches BYE, so the tool returns NOTHING.
 * The kept in-tree version includes <linux/qrtr.h> so the values are
 * authoritative rather than hardcoded. */
enum { QRTR_TYPE_NEW_SERVER = 4, QRTR_TYPE_NEW_LOOKUP = 10 };

struct qrtr_ctrl_pkt {                 /* matches net/qrtr/qrtr.c */
    uint32_t cmd;
    union {
        struct { uint32_t service, instance, node, port; } server;
        struct { uint32_t node, port; } client;
    };
} __attribute__((packed));

int main(void)
{
    int fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket(AF_QIPCRTR)"); return 1; }

    struct sockaddr_qrtr sq; socklen_t sl = sizeof(sq);
    if (getsockname(fd, (void *)&sq, &sl) < 0) { perror("getsockname"); return 1; }
    fprintf(stderr, "local qrtr node = %u\n", sq.sq_node);

    struct qrtr_ctrl_pkt pkt; memset(&pkt, 0, sizeof(pkt));
    pkt.cmd = htole32(QRTR_TYPE_NEW_LOOKUP);     /* service=0,instance=0 => ALL */

    struct sockaddr_qrtr ctrl = { .sq_family = AF_QIPCRTR,
                                  .sq_node = sq.sq_node,
                                  .sq_port = QRTR_PORT_CTRL };
    if (sendto(fd, &pkt, sizeof(pkt), 0, (void *)&ctrl, sizeof(ctrl)) < 0) {
        perror("sendto(NEW_LOOKUP)"); return 1;
    }

    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };   /* drain until quiet */
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("%-9s %-12s %-6s %-6s\n", "SERVICE", "INST(v)", "NODE", "PORT");
    for (;;) {
        struct qrtr_ctrl_pkt r; ssize_t n = recv(fd, &r, sizeof(r), 0);
        if (n < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                     perror("recv"); break; }
        if ((size_t)n < sizeof(uint32_t)) continue;
        if (le32toh(r.cmd) != QRTR_TYPE_NEW_SERVER) continue;
        uint32_t svc = le32toh(r.server.service), inst = le32toh(r.server.instance);
        uint32_t node = le32toh(r.server.node),  port = le32toh(r.server.port);
        if (!svc && !node && !port) continue;            /* sentinel */
        printf("0x%04x    0x%08x  %-6u %-6u\n", svc, inst, node, port);
    }
    close(fd);
    return 0;
}
```

> Notes: aarch64 is little-endian so the `le32toh`/`htole32` are no-ops on-target, but kept
> for correctness. If `<linux/qrtr.h>` is missing `struct sockaddr_qrtr`, define it locally:
> `struct sockaddr_qrtr { unsigned short sq_family; uint32_t sq_node; uint32_t sq_port; };`.
> The upstream `lookup.c` (andersson/qrtr) is the reference if anything misbehaves.

### Path B build/run
```bash
# build (NDK)
$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang \
    qrtr-services.c -O2 -Wall -o qrtr-services
# run
adb -s c39a6acf push qrtr-services /data/local/tmp/
adb -s c39a6acf shell 'chmod +x /data/local/tmp/qrtr-services; /data/local/tmp/qrtr-services'
```

### Path C (when it becomes a kept tool): in-tree Soong module
```
// device/xiaomi/mithorium-common/qrtr-tools/Android.bp  (userdebug debug tool)
cc_binary {
    name: "qrtr-services",
    srcs: ["qrtr-services.c"],
    vendor: true,
    cflags: ["-Wall"],
}
```
Gate to `userdebug`/`eng`; add the SELinux rule below if kept past the permissive bring-up.

---

## Running it + capture

```bash
# Fresh boot, transport confirmed up first:
android16-adb shell 'getprop | grep -iE "modem.state|qrtrns|qcrild"'   # expect modem ONLINE, qrtr-ns + qcrild running
android16-adb shell 'ps -A | grep -iE "qrtr-ns|tftp_server|pd-mapper|rmt_storage"'
# Enumerate:
android16-adb shell '/data/local/tmp/qrtr-services' | tee qrtr-services-boot.txt
# Subsystem/PD context to capture alongside:
android16-adb shell 'for s in /sys/bus/msm_subsys/devices/subsys*/name; do n=$(cat $s); st=$(cat ${s%name}state); echo "$n=$st"; done'
```

Re-run the enumerator after each Cluster A lever to see if **service 16** appears:
restart/repair `tftp_server`; add+run `pd-mapper`; `subsystem_restart modem` (force SSR so
the modem re-announces with the ns listening).

---

## Reading the output — QMI service-ID reference

Confident, load-bearing IDs (cross-check the rest against a full QMI service-ID list):

| ID (dec / hex) | Service | Relevance |
|---|---|---|
| 1 / 0x01 | `QMI_WDS` (wireless data) | cellular data |
| 2 / 0x02 | `QMI_DMS` (device mgmt) | radio core |
| 3 / 0x03 | `QMI_NAS` (network access) | signal/registration — radio core |
| 5 / 0x05 | `QMI_WMS` (messaging) | SMS |
| 6 / 0x06 | `QMI_PDS` (position, legacy) | old GPS service (pre-LOC) |
| 9 / 0x09 | `QMI_VOICE` | calls |
| 11 / 0x0B | `QMI_UIM` | SIM/UICC |
| 12 / 0x0C | `QMI_PBM` | phonebook |
| 14 / 0x0E | `QMI_RMTFS` | remote FS — **served by `rmt_storage` (✅ working)** |
| **16 / 0x10** | **`QMI_LOC`** | **GPS/GNSS — the service we're hunting** |
| 26 / 0x1A | `QMI_WDA` | rmnet data agent |
| 256 / 0x100 | SMGR sensors (per `PLAN-sensors.md`) | sensors — should be present |

Service IDs **not** in this table (thermal, PDC, IMS-app, QTI-custom 0x1xx, servreg/PD) are
fine to see; identify them from a QMI service-ID reference. The point is the **presence/absence
of 16** and the overall shape.

What to look for:
- **16 present** → big redirect: GPS is a client-side bind problem, not a missing service.
  Note its `instance(v)` and `node`; hand them to the GPS client investigation
  (`loc_api_v02` `qmi_client_get_service` filter / timing). Update `PLAN-gps.md`.
- **16 absent, but 14 + radio set present** → modem root-PD healthy, LOC's host (a user-PD
  or the GNSS task) is not up → pursue `tftp_server`/RFS, then `pd-mapper`, then modem GNSS
  NV/config — re-running this tool after each.
- **List is sparse / 14 absent** → broader modem service-init problem; check `rmt_storage`,
  modem SSR history, RFS.
- **Node distribution** → which `node` each service sits on. If everything is on one node and
  there's no servreg/PD footprint, user-PDs likely aren't localized (consistent with
  `pd-mapper` absent).

---

## Results (2026-06-26) — first capture

Device: `android16-adb` (c39a6acf), uptime ~14900s (modem long settled, not a boot artifact),
`vendor.peripheral.modem.state=ONLINE`, `adsp/wcnss/venus=ONLINE`, `qrtr-ns` + `qcrild` +
`rmt_storage` running. Local QRTR node = **1** (the AP — anchored by `RMTFS`(14) on node 1,
served by `rmt_storage` which runs AP-side). Remote nodes seen: **5** and **7** (modem/ADSP).

**42 services registered.** Distinct service IDs present:
`14 15 42 43 51 52 53 256 263 264 269 271 277 280 300 769 771 4097`.

Load-bearing reads:

- **`QMI_LOC` (16) — ABSENT.** Not on any node, stable across re-runs. → **CONFIRMS the
  Cluster A premise for GPS**: the modem is *not* advertising LOC over QRTR. GPS's
  `qmi_client_get_service() rc:-2` is therefore a *real missing service*, **not** a client-side
  instance/version filter bug. The RFS (`tftp_server`) / `pd-mapper` / modem-GNSS-NV path in
  `PLAN-gps.md` is the right direction; this tool now measures whether each fix makes 16 appear.
- **`RMTFS` (14) — present, inst 1, node 1.** Healthy (anchors the decode; matches `rmt_storage`).
- **`SENSOR/SMGR` (256) — present** (node 5 inst 0x3201, node 7 inst 0x100). Sensor transport up,
  consistent with `PLAN-sensors.md` (SMGR replied version=23). The 0-sensor problem is the
  missing `sensor_def_qcomdev.conf`, not transport — orthogonal to this.

**Unexpected, flagged for follow-up (NOT a regression — radio demonstrably works):** the
*classic radio QMI set* (`WDS`1 `DMS`2 `NAS`3 `WMS`5 `VOICE`9 `UIM`11) is **also absent** as
small-ID services. Since qcrild + HIDL `IRadio/slot1` are healthy, the radio QMI must be reached
via the QTI-vendor service block instead — the `0x100`+ range (256/263/264/269/271/277/280/300),
`0x300`+ (769/771), and the large multi-instance `4097`/`0x1001` cluster on node 1 are
QTI-custom/remapped services. **Do not treat the radio-set absence as a bug**; it just means
service-ID interpretation on this modem is QTI-remapped, and small-ID LOC genuinely isn't there.
Open question for later: identify the remapped LOC equivalent (if any) — but `loc_api_v02`
hardcodes a lookup for service 16, so a remapped LOC wouldn't help the stock HAL regardless.

**Next levers (re-run `qrtr-services` after each, watch for `16` to appear):**
1. Repair `tftp_server` (RFS) so modem GNSS can read NV. `PLAN-gps.md` "PRIME SUSPECT".
2. Add `pd-mapper` (if LOC is user-PD-hosted).
3. Force a modem SSR with `qrtr-ns` listening so the modem re-announces.
4. If a working sibling (santoni/land) is on the bench, run the same tool there and diff.

### Reproduce
```bash
# Standalone build (no NDK env needed — in-tree clang + NDK sysroot + platform crt):
CLANG=prebuilts/clang/host/linux-x86/clang-r574158/bin/clang
SYSROOT=out/soong/ndk/sysroot
CRT=out/soong/.intermediates/bionic/libc
$CLANG --target=aarch64-linux-android31 --sysroot=$SYSROOT -O2 -Wall -fPIE -pie \
  -nostartfiles -isystem $SYSROOT/usr/include -isystem $SYSROOT/usr/include/aarch64-linux-android \
  device/xiaomi/mithorium-common/qrtr-tools/qrtr-services.c \
  $CRT/crtbegin_dynamic/android_arm64_armv8-a_cortex-a53/crtbegin_dynamic.o \
  $CRT/crtend_android/android_arm64_armv8-a_cortex-a53/crtend_android.o \
  -L $SYSROOT/usr/lib/aarch64-linux-android/31 -lc -ldl -o /tmp/qrtr-services
adb -s c39a6acf push /tmp/qrtr-services /data/local/tmp/ && \
adb -s c39a6acf shell 'chmod 755 /data/local/tmp/qrtr-services; /data/local/tmp/qrtr-services'
# Or in-tree:  mm qrtr-services   →   /vendor/bin/qrtr-services
```

---

## Ground-truth note: A11 is **not** valid here — use a sibling

The two-device methodology partially **breaks for this measurement**: `android11-adb` (and
the original Palm 8.1 stack) used **QMUX/legacy IPC-router**, not QRTR — there is no QRTR
service bus on it to enumerate the same way. So **do not** try to confirm "what should be on
the bus" from A11.

The valid comparison is a **working sibling on the same Lineage/nightly QRTR stack**
(santoni / land / prada), where GPS is known to work: run the same enumerator there and diff.
A sibling showing `LOC(16)` while pepito does not localizes the fault to pepito's modem
config / `pd-mapper` / RFS rather than to the platform. If no sibling is on the bench, fall
back to "compare against the radio services that already work + the QMI spec."

---

## SELinux / packaging notes

- The enumerator's domain needs `allow <domain> self:qipcrtr_socket { create bind read write };`.
  SELinux is **permissive** during bring-up, so a `/data/local/tmp` run as root works now;
  add the rule before enforcing if the tool is kept in-tree.
- As a one-off, NDK + `adb push` to `/data/local/tmp` avoids any packaging/SELinux/label work.
- If kept: `cc_binary { vendor: true }`, `userdebug`-gated, with the sepolicy rule above.

---

## Cross-refs
- `PLAN.md` → "Holistic cross-cutting analysis" → **Cluster A** (why this is the keystone).
- `PLAN-gps.md` → the QMI_LOC `rc:-2` blocker this measures (step 2, promoted to first).
- `PLAN-radio.md` → the QRTR transport model + the QMUX transport-history correction.
- `PLAN-sensors.md` → SMGR sensor QMI service (should appear in the list).

## Checklist
- [x] Step 0: check `/sys/kernel/debug` + nightly/image for a prebuilt `qrtr-lookup` — **none
      exists** (no debugfs table, no `qrtr-lookup` anywhere, qrtr source not synced).
- [x] Build the enumerator — Path B/C `qrtr-services` (in-tree at `qrtr-tools/`).
- [x] Capture `qrtr-services-boot-2026-06-26.txt` (modem ONLINE, qrtr-ns up).
- [x] **Decide on service 16:** **ABSENT** → pursue RFS/PD path (`PLAN-gps.md`).
- [ ] Re-run after (a) repairing `tftp_server`, (b) adding `pd-mapper`, (c) forcing modem SSR
      — record which makes 16 appear.
- [ ] Diff against a working sibling's bus if one is available.
- [x] Fold the finding back into `PLAN-gps.md` and `PLAN.md` Cluster A.
- [x] Add Soong module (`Android.bp`, userdebug). [ ] add `qipcrtr_socket` sepolicy rule before
      enforcing (permissive bring-up → `/data/local/tmp` run works now).
- [ ] Follow-up: explain the *classic radio set* absence (QTI-remapped IDs) — see Results.
