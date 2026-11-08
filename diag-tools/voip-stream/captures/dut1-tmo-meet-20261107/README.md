# dut1 (T-Mo SIM 310240) — Google Meet / VoIP mic on 20261107, 2026-11-07

Build 24.0-20261107 gapps, `vendor.voice.path.for.pcm.voip=false` (the VoIP mic fix).

| case | capture device | result |
|---|---|---|
| Meet, speaker | `speaker-mic` ACDB 11 (`SND_DEVICE_IN_SPEAKER_MIC`) | opens |
| Meet, earpiece | `handset-mic` ACDB 108 (`SND_DEVICE_IN_HANDSET_MIC_AEC_NS`) | **pcm_prepare -1 ~7/s, mic dead** |
| same, gsm.sim.operator.numeric faked 311480 | same (playback voice-handset ACDB 7) | same failure ⇒ not the TMUS branch |
| pcm.voip=true, earpiece | compress-voip-call | opens (the old garbled path) |
| `voipstream.sh mode-comm 8`, earpiece | ACDB 108 | 53–60 failures, 35 KB of ~256 KB read |
| + `echo-reference handset` = AUDIO_REF_EC_UL1 MUX QUAT_MI2S_RX (bind mount) | ACDB 108 | still fails |
| + platform_info acdb override AEC/NS/AEC_NS → 4 (bind mount) | `handset-mic` ACDB 4 | **0 failures, 252 800 bytes read** |

Kernel: `adm_callback: cmd = 0x10326 returned error = 0x1` → `adm_open: port_id 0x1005 failed -131` →
`msm_pcm_capture_prepare: stream reg failed`. The ADSP refuses the ADM COPP for ACDB 108 (its ECNS topology).
Why speaker escapes: get_snd_device_for_voice_comm_ecns_disabled() → BACK_MIC + fluence_in_spkr_mode but
fluence_in_voice_comm=false ⇒ no AEC device ⇒ plain speaker-mic. BUILTIN_MIC (earpiece) → HANDSET_MIC_AEC_NS.
Side issue (not the cause): our playback is all QUAT_MI2S_RX (TFA9896) but `echo-reference` still taps I2S_RX
(stock value, stock played on PRI_MI2S_RX). `voice-handset-tmus` (ACDB 88) has no mixer path.

Fix candidate: `Mi8937-handset-voip-mic-acdb.patch` (pepito-only platform_info). Trade-off: no ADSP AEC/NS on
earpiece VoIP — same as speaker today; apps (Meet/GV/WhatsApp) run their own WebRTC AEC.

**Listening test 18:2x (Kyle, far end):** with the fix bind-mounted, Kyle2 (dut1) audible on BOTH speaker and earpiece.

## Matrix 18:4x (voipstream, 6 s each, 192 000 bytes = full capture; mode-comm routes to earpiece)

| mode | stock 20261107 | wide fix (api.wide.xml) |
|---|---|---|
| mode-comm (VoIP AEC+NS) | 108 — 44 fails, 27 KB | 4 — 0 fails, 177 KB |
| mode-comm --no-ns (AEC) | 106 — 44 fails, 27 KB | 4 — 0 fails |
| mode-comm --no-aec (NS) | 107 — 44 fails, 27 KB | 4 — 0 fails |
| vrec | 4 — OK | 4 — OK |
| vrec-ns | 107 — 41 fails, 26 KB | 4 — 0 fails, 191 KB |
| vrec-aec | 112 — OK | 112 — OK (untouched) |
| vrec-aec-ns | 114 — OK | 114 — OK (untouched) |

Fable review (11-07) claimed 106-108/112-114 all map to ECNS topology 0x10F89 and fail; bench says 112/114
open fine, so the remap is limited to 106/107/108 + VOICE_REC_MIC_NS. Its "ACDB 47 absent" (wired-headset VoIP,
HEADSET_MIC_FLUENCE) is unverified and untestable here (no headset) — left out.
Open: far-end echo test (platform AEC reports enabled but ACDB 4 has no ECNS), stock silver earpiece Meet.
