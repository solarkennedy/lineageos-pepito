* Life mode
A quick tile that enables/disables zenmode & DND and activates deepsleep?
No persistent service

* Basic Face Unlock
May be super hard, would only enable convenince level and Lineage has no face detection hal

* Pepito Launcher
A reimplementation of the original pepito launcher
see PLAN-pepitolauncher2.md

* Horizontal Volume slider quick tray and down arrow

Similar to how the lineageos drawer has a horizontal brightness slider (with a setting to disable it),
we should also have a volume slider, with the drop down that accesses the different volumes.
Same backing code that handles the vertical slider as _if_ we pressed volume keys (which pepito doesn't have)
This is what the stock A8 port had. It should have a toggle in the settings too for users who don't like it.

**Status: IMPLEMENTED — staged 2026-07-10, needs build+flash validation.**

Design: reuses the A16 Compose volume panel machinery instead of writing a new slider —
`AudioStreamSliderViewModel` (same `AudioVolumeInteractor`/`AudioRepository` backing code as the
vertical dialog and the Sound settings panel) + the existing `ColumnVolumeSliders` composable,
which already implements exactly the PVG100 UX: one primary slider with an arrow button
that expands into the remaining stream sliders. The primary slider follows the currently
*relevant* stream like the vertical dialog does, driven by `AudioRepository.mode`:
MODE_RINGTONE → Ring, MODE_IN_CALL/IN_COMMUNICATION → Call, otherwise Media (what volume keys
target when idle). The five per-stream viewmodels are stable; only the list order re-emits
(StateFlow), so slider state doesn't reset on reorder. Inserted into the Compose QS
fragment (`QSFragmentComposeViewModel` is what actually runs on the DUT — verified live) directly
below the Lineage brightness slider, following its top/bottom position setting.

Changes staged (4 repos):
- `lineage-sdk`: new `LineageSettings.Secure.QS_SHOW_VOLUME_SLIDER` (`qs_show_volume_slider`,
  @hide like its brightness siblings — no public-API update needed) + provider default
  `def_qs_show_volume_slider=false` (defaults.xml + LineageDatabaseHelper).
- `frameworks/base` (SystemUI): `QSFragmentComposeViewModel` injects
  `AudioStreamSliderViewModel.Factory` (all deps verified on the SysUI singleton graph) and
  lazily builds 5 stream viewmodels + `volumeSlidersExpanded` state (reset when QS collapses);
  `QSFragmentCompose.kt` adds the `VolumeSliders` element (gesture-exclusion + AlwaysDarkMode,
  mirroring the brightness slider), a `rememberQsShowVolumeSlider()` ContentObserver-backed
  setting reader, and a `volume` slot in `QuickSettingsLayout`; new `Elements.VolumeSliders` key.
  Expanded QS only (matches brightness "Show when expanded"); not in QQS.
- `packages/apps/LineageParts`: "Volume slider" switch in Settings → System → Status bar
  (new Volume category under Brightness; default off).
- `device/xiaomi/Mi8937`: new `xiaomi_pepito_overlay_lineagesettings` RRO (targets
  `org.lineageos.lineagesettings`, gated on `ro.vendor.xiaomi.device=pepito`) flips the provider
  default to ON for pepito; registered in `lineage_Mi8937.mk` inside the existing
  `TARGET_DEVICE_PEPITO` block.

Validate after flash (fresh userdata):
1. Expand QS → horizontal media slider with arrow button below the brightness slider; drag → media volume.
1b. Relevance: while a call is ringing / active (needs VoLTE… or a VoIP app / `adb shell cmd audio set-mode 2`),
    the primary slider becomes Ring / Call respectively, back to Media after.
2. Arrow → Call/Ring/Notification/Alarm sliders animate in; slider icons toggle mute; ring slider tracks ringer mode.
3. LineageParts toggle (Settings → System → Status bar → Volume) hides/shows live.
4. Default-on came from the RRO:
   `adb shell content query --uri content://lineagesettings/secure --where "name='qs_show_volume_slider'"` → 1.
   VALIDATED 2026-07-10: `cmd overlay lookup org.lineageos.lineagesettings
   org.lineageos.lineagesettings:bool/def_qs_show_volume_slider` → true on the DUT. But the first
   flash booted against a PRE-EXISTING settings DB (row _id showed it was created by the manual
   toggle, not DB creation) — defaults only load at DB creation. Fixed by the standard Lineage
   mechanism: `LineageDatabaseHelper` DATABASE_VERSION 24→25 with an `INSERT OR IGNORE` upgrade
   stanza, so dirty flashes get the default too (and never clobber a user's explicit choice).
   NOTE for repo sync: upstream will eventually also bump to 25 — this stanza will need renumbering.
5. Collapse shade, reopen → expanded sliders collapsed back to just the media slider.

Note: the QS `VolumeTile` from PLAN-misc §6 stays as a complementary stopgap (pops the vertical dialog).
