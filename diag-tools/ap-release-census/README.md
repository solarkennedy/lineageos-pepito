# ap-release-census

Read-only census of every AP → modem request that can make the modem release,
re-select or re-attach a cell, pulled from a bench unit's radio log over adb.
Written for the 2026-10-20 "AP-side let-go audit" in `plans/PLAN-emergency-only.md`.

```
./ap-release-census.sh new2             # summary on stdout, raw logs under /tmp
./ap-release-census.sh dut1 ./census    # keep the raw logs here
```

Buckets: **COMMAND** (RADIO_POWER, allowed-network-types, network-selection,
initial-attach APN, data-call teardown, modem reset, scans, usage setting);
**STATE** (reporting criteria, filters, data-modem selection); **READ**
(polling — cannot release a cell). Also counts DSRM activity, RIL reconnects,
`wfc_wlan_bridge` WLAN_AVAILABLE/NOT_AVAILABLE sends, EmergencyWatchdog nudges,
and reports whether qcrild and friends have restarted since boot.

The radio ring buffer is small (dut1: ~13 h idle); run it right after the
episode you care about, or enlarge the buffer first (`logcat -b radio -G 8M`).
Touches nothing on the phone.
