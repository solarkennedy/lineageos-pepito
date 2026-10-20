# nas-probe (source mirror) + OOS sampler v11

`nas-probe.c` is the read-mostly QMI probe used by every emergency-only / OOS
investigation (NAS 0x24/0x34/0x4D status, `sig` = NAS 0x4F signal info + 0x43
cell location with srxlev, WDS/UIM/DMS reads, and a few `--yes-touch-nas`
writes). The build lives in `~/android/lineage-23/diag-tools/nas-probe/`
(`build-nosysroot.sh`, needs the lineage-23 prebuilt clang + bionic headers +
the QMI libs vendored under `../pdc-mbn-loader`); this directory mirrors the
source so it is under version control. Keep both copies in sync.

`new2-sampler-v11-oos.sh` is the PLAN-oos-time E0 observer: one line / 15 s with
modem-sourced RSRP and S-criterion (`srxlev`), framework state only as a
"what the user saw" column. Runs on the unit as `/data/local/tmp/rec/sampler-v11.sh`.
