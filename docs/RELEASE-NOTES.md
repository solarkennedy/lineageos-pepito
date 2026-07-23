# Release notes — pepito-23.2-r1 (draft)

_Placeholder — filled at release time (PLAN-release.md Phase 10)._

- What works / known limitations
- Commit SHAs / tags across all repos
- qmux escape hatch (`persist.vendor.qmux.enable`)
- Enhanced-4G toggle is cosmetic (modem is v01-IMSS; framework qcril is v02-only)
- ACDB audio calibration status
- Single-SIM; metadata encryption not enabled
- ⚠️ **Recurring, not just fresh-flash**: mobile data/voice can silently drop
  registration and get stuck camping on a roaming partner (seen on both
  AT&T 310-410 and T-Mobile 310-260) instead of home Verizon, showing a `!` on
  the status bar even though data was working moments before. Confirmed twice
  on the same daily-driver unit — once right after a fresh flash, once
  spontaneously during normal use with no flash involved. One Airplane Mode
  toggle forces re-registration and fixes it every time. Cause not fully
  root-caused (looks like the historical NAS domain-selection class of issue);
  confirming needs `diag-tools/nas-probe`, which requires root — not available
  on a release/non-rooted-debugging build. Worth a real investigation pass
  before shipping a release, not just a documented workaround.
