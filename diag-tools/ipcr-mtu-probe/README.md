# ipcr-mtu-probe — largest AP→modem router packet over the legacy IPC Router

Sends a valid QMI DMS `GET_DEVICE_CAP` request padded with one unknown optional
TLV of a chosen size over `AF_MSM_IPC` and reports whether `sendto()` accepts it
and whether the modem answers. Measures the transport limit of
`ipc_router_rpmsg_xprt` (one router packet = one SMD packet, refused above the
IPCRTR FIFO) and is the regression test for any change that lifts it.

```
./build.sh                                   # sysroot-free arm64 build (see ../nas-probe)
dut1-adb push ipcr-mtu-probe /data/local/tmp/ && dut1-adb root
dut1-adb shell /data/local/tmp/ipcr-mtu-probe            # default size sweep
dut1-adb shell /data/local/tmp/ipcr-mtu-probe 9000 32000 # specific pad sizes
dut1-adb shell /data/local/tmp/ipcr-mtu-probe -s 0x03 64 # another service (NAS)
```

## 2026-11-07 dut1 (kernel 34946fdebaab)

| pad | QMI bytes | result |
|---|---|---|
| ≤ 8120 | ≤ 8130 | sent, modem answers `result=0` |
| 8140 | 8150 | `sendto` EINVAL |
| 9000 … 60000 | | `sendto` EINVAL, dmesg `does not fit the ipc_rtr_rpmsg_ipcrtr SMD FIFO` |

8130 + 24 (router header) + 20 (SMD header) = 8174 < 8192; 8150 + 44 = 8194.
⇒ IPCRTR FIFO is 8192 bytes; the AP can send at most ~8128 QMI bytes per
request. The modem accepts large single SMD packets fine. Stock 3.18 streamed
bigger packets with `smd_write_start/segment/end`; the mainline receive side
already reassembles them (`qcom_smd_channel_ext_read`), so the matching fix is
a streaming TX path in `drivers/rpmsg/qcom_smd.c`, not fragmentation at the
router layer (the donor `ipc_router_smd_xprt.c` treats one SMD packet as one
router packet). No oversize send has been observed in normal use (dmesg and
pstore clean on dut1).
