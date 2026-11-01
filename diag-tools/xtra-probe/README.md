# xtra-probe

Raw QMI LOC client used to prove XTRA (predicted orbits) injection without
Qualcomm's xtra-daemon (PLAN-android17.md, "Bug 2026-11-01"). The production
version of the same injection lives in mithorium-common
`gps/android/2.1/GnssXtra.cpp`.

    source            modem's XTRA URL list (QMI_LOC 0x36)
    validity          predicted-orbits validity window (0x37), UTC seconds
    info              QUERY_XTRA_INFO (0xB0); not supported on C1-214411
    time              inject UTC time from the AP clock (0x38)
    inject FILE [old] 0xA7 INJECT_XTRA_DATA (not supported on C1-214411), or
                      "old" = 0x35 INJECT_PREDICTED_ORBITS_DATA (works)

Build: `dut1-adb pull /vendor/lib64/libloc_api_v02.so lib/` then `./build.sh`
(lineage-23 prebuilt clang + bionic headers, QMI headers from lineage-23's
`diag-tools/pdc-mbn-loader`). `lib/` and the binary are git-ignored (vendor blob).

Run as root on the phone:

    LD_PRELOAD=/vendor/lib64/libqmi_force_ipcr.so LD_LIBRARY_PATH=/vendor/lib64 \
        ./xtra-probe inject xtra3grc.bin old

Use `https://path1.xtracloud.net/xtra3grc.bin`; the izatcloud.net file the
modem lists fails on its last part with INVALID_PARAMETER.
