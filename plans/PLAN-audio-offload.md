# PLAN-audio-offload: Compressed-offload playback fails DSP-side (NEW, 2026-07-05)

> ## RESOLVED / WORKAROUND CONFIRMED 2026-07-06
> The crash is fixed by disabling compressed offload globally. Verified live on
> `c39a6acf`: `setprop audio.offload.disable 1` + `stop/start audioserver` →
> Twelve stopped crashing and played the `low-latency-playback` usecase with
> **zero** errors (delivered ~145 s of PCM frames, `AudioTrack stop: 6946816
> frames`). Baked into `device/xiaomi/Mi8937/device.mk` (pepito block) as
> `audio.offload.disable=1`.
>
> **The "fix ACDB → offload works for free" theory below is WRONG** and should not
> be pursued. The `topology 0x0 / cal_block NULL` lines fire on the *working* PCM
> path too, so they are common-mode noise, not the offload differentiator. Real
> offload failure = `ASM_STREAM_CMD_OPEN_WRITE_V3 → ADSP_EFAILED`: the stock A8.1
> ADSP image almost certainly lacks the compressed-decode topology. Disabling
> offload is the correct permanent answer; do not gate it on ACDB.
>
> **IMPORTANT:** disabling offload does NOT make sound audible. The device is
> silent for a *separate* reason — the external **NXP TFA9896** speaker amp is not
> brought up. See `PLAN-audio.md` → "External speaker amp (TFA9896) — REAL silence
> root cause". Offload was only ever an app-crash bug, never the reason for silence.


> Scope: this is a **separate bug from `PLAN-audio.md`'s Issue 2** (ACDB A8-format
> mismatch → unprocessed PCM audio). That issue affects the working, non-offload
> playback path (audio plays, just unprocessed). This plan is about **compressed
> hardware-offload playback failing outright** — the DSP rejects the session and
> the app's `AudioTrack` dies. The two may share a cause (see "Working theory"
> below) but keep them as distinct tickets until proven the same.

## Symptom

`org.lineageos.twelve` (LineageOS "Twelve" music app) — playback starts, then
almost immediately the track goes silent and the transport shows paused.
App-level exception (`adb logcat`):

```
W ExoPlayerImplInternal: Recoverable renderer error
W ExoPlayerImplInternal:   androidx.media3.exoplayer.ExoPlaybackException: MediaCodecAudioRenderer error, ...
W ExoPlayerImplInternal:   Caused by: androidx.media3.exoplayer.audio.AudioSink$WriteException: AudioTrack write failed: -6
W ExoPlayerImplInternal:       at androidx.media3.exoplayer.audio.DefaultAudioSink.drainOutputBuffer(...)
W ExoPlayerImplInternal:       at org.lineageos.twelve.services.TwelveAudioSink.handleBuffer(...)
```

`-6` = `AudioTrack.ERROR_DEAD_OBJECT`. Twelve's `PlaybackService` requests
compressed hardware offload (`setOffloadEnabled(sharedPreferences.enableOffload)`,
`PlaybackService.kt:458`) and **`enable_offload` defaults to `true`**
(`ext/SharedPreferences.kt:49-52`) — nothing in the app has to opt in, this fires
on first playback of any AAC/MP3 track. Toggle is user-visible at
Settings → `enable_offload` (`SettingsActivity.kt:148`).

## Evidence chain (traced 2026-07-05, device `c39a6acf`)

### 1. Userspace (`adb logcat`) — HAL fails to open the offload stream

```
D audio_hw_primary: start_output_stream: enter: stream(0xf0f3f800) usecase(3: compress-offload-playback) devices(0x2)
I audio_hw_utils: send_app_type_cfg_for_device PLAYBACK app_type 69936, acdb_dev_id 14, sample_rate 48000, snd_device_be_idx 2
D audio_hw_primary: enable_audio_route: apply mixer and update path: compress-offload-playback
D audio_hw_primary: select_devices: done
E audio_hw_primary: start_output_stream: failed /w error cannot set device: Out of memory
E AudioFlinger: Error when pausing output stream: -61
W AudioFlinger: An invalidated track shouldn't be in active list
```

This repeats 2-3 times (retries) over about half a second, then the stream goes
to standby and the track is torn down. A **separate, non-offloaded
`low-latency-playback` stream opens seconds later with no errors** — i.e. plain
PCM playback still works fine on this device (matches `PLAN-audio.md` — speaker
routing, `acdb_dev_id 14`, is otherwise healthy). The failure is specific to the
`compress-offload-playback` usecase.

`"cannot set device"` is emitted by `external/tinycompress/compress.c` — either
`compress_open()` (`compress.c:254-256`) or `compress_set_codec_params()`
(`compress.c:639-640`), both wrapping `SNDRV_COMPRESS_SET_PARAMS`. The message
suffix is `strerror(errno)` set by the failing ioctl (`compress.c:105-119`,
`oops()`).

### 2. Kernel (`adb shell dmesg`) — DSP rejects the ASM open

Correlated via uptime (`cat /proc/uptime` vs `date` at capture time — dmesg has
no wall-clock stamps by default):

```
[1660.592997] afe_send_port_topology_id: AFE deregister topology for port 0x1000 failed -95
[1660.594401] q6asm_send_cal: cal_block is NULL
[1660.597900] afe_send_port_topology_id: AFE set topology id 0x0  enable for port 0x1000 ret -95
[1660.623218] send_afe_cal_type: cal_index is 0
[1660.623249] send_afe_cal_type: dev_acdb_id[40] is 0
[1660.623249] send_afe_cal_type cal_block not found!!
[1663.073391] q6asm_callback: cmd = 0x10db3 returned error = 0x1
[1663.073528] __q6asm_open_write: DSP returned error[ADSP_EFAILED]
[1663.078548] msm_compr_configure_dsp_for_playback:ASM open write err[-131] for compr type[0]
```
(...repeats ~25 times at ~150-200ms intervals over ~5s, all identical, then:)
```
[1671.472809] afe_close: port_id = 0x1000
```

- `cmd = 0x10db3` is `ASM_STREAM_CMD_OPEN_WRITE_V3`
  (`kernel/xiaomi/msm8937/techpack/audio-legacy/include/dsp/apr_audio-v2.h:7838`).
- `ADSP_EFAILED` (generic DSP failure) maps to Linux `-ENOTRECOVERABLE` (`-131`)
  via the fixed table in
  `kernel/xiaomi/msm8937/techpack/audio-legacy/dsp/adsp_err.c:92-116`
  (`{ -ENOTRECOVERABLE, ADSP_EFAILED_STR }`).
- Driver path: `msm_compr_set_params()` →
  `msm_compr_configure_dsp_for_playback()` → `q6asm_open_write()` (all in
  `kernel/xiaomi/msm8937/techpack/audio-legacy/asoc/msm-compress-q6-v2.c`,
  `msm_compr_set_params` at line 2111, dispatch to
  `msm_compr_configure_dsp_for_playback` at line 2314-2317).

### ⚠️ Open discrepancy — not yet resolved

The kernel-side failure is `-ENOTRECOVERABLE` (131, bionic string "State not
recoverable" — verified against `bionic/libc/private/bionic_errdefs.h:167` and
`bionic/libc/kernel/uapi/asm-generic/errno.h:106`), but the **userspace log
string says `"Out of memory"`** (`ENOMEM` = 12). These are different numbers.
Either:
- a different, earlier `SNDRV_COMPRESS_SET_PARAMS` call (e.g. inside
  `compress_open()`, before the DSP is even engaged) is failing with a genuine
  `-ENOMEM` from a kernel allocation (`kzalloc`/ION/dma-buf) — possibly a real
  low-memory condition or a leak from repeated failed retries not freeing a
  session/buffer — **or**
- the one-shot post-hoc `dmesg` capture used here just happened to land on a
  *different* retry than the specific logcat line quoted above; the two were
  not captured synchronously.

**Next agent: reproduce with synchronized capture** —
`adb shell 'logcat -v threadtime & dmesg -w'` (single shell, interleaved
output) so each HAL "failed /w error" line can be matched 1:1 to its kernel
errno, instead of correlating two separate dumps after the fact.

## Working theory

The `afe_send_port_topology_id ... ret -95` / `q6asm_send_cal: cal_block is
NULL` / `dev_acdb_id[40] is 0` lines fire **immediately before** every
`ASM_STREAM_CMD_OPEN_WRITE_V3` rejection. This is the *exact* symptom already
tracked as **Issue 2 in `PLAN-audio.md`** (A8-era ACDB file format vs. the
A12/13 `acdb_loader` this build ships — cal blocks never resolve, `topology id
0x0`). The working hypothesis is that plain PCM playback **tolerates** missing
calibration (plays unprocessed — no EQ/speaker protection, as already
documented) while the DSP's compressed-session open path **hard-fails** if it
can't resolve calibration/topology for the port, since offload relies on a
DSP-side decode+post-proc chain that PCM doesn't need the same way.

If true: fixing `PLAN-audio.md` Issue 2 (ACDB format mismatch — try the prada
nightly ACDB set) may fix this too, for free. **Test this before doing anything
else below** — it's the cheapest possible experiment and already an open task.

## Immediate workaround (no build/flash required)

Twelve → Settings → turn off "offload" (`enable_offload`, default on). Forces
software decode + plain PCM `AudioTrack`, which is the already-working path.
Tell the user this exists regardless of what the deeper fix turns out to be.

## Next steps for whoever picks this up

1. **Cheap test first:** try the prada ACDB set swap already queued in
   `PLAN-audio.md` Issue 2, then retest offload playback. If cal blocks start
   resolving (nonzero topology id) and offload starts working, this whole plan
   collapses into a duplicate of Issue 2 — close it out.
2. If offload *still* fails after ACDB is fixed: get the synchronized
   logcat+dmesg capture described above to nail down whether a real `-ENOMEM`
   exists somewhere in the `compress_open()` path independent of the ADSP
   rejection.
3. Check whether the ADSP firmware image in use here (Palm 8.1 stock ADSP
   blobs, per the Cluster C stock-blob concern in the holistic model) actually
   contains a hardware AAC *encode-side* decoder license/module at all —
   `ADSP_EFAILED` on `OPEN_WRITE_V3` for an AAC (`audio/mp4a-latm`) session
   could also mean the ADSP topology for that codec plain isn't present/loaded,
   independent of calibration. Compare against what codecs the stock A11 device
   can offload successfully (`android16-adb`/`android11-adb` two-device
   methodology — play the same AAC file on stock and check for the same
   `usecase(3: compress-offload-playback)` path and whether it succeeds).
4. Only if 1-3 don't explain it: look at whether repeated failed retries leak
   an ADSP-side session/buffer, causing later opens to fail differently than
   earlier ones (the retry burst in the kernel log runs ~25 times over 5s
   before giving up — check `msm_compr_configure_dsp_for_playback` /
   `q6asm_open_write` for missing cleanup on the error path).

## Reference — code pointers

- App: `packages/apps/Twelve/app/src/main/java/org/lineageos/twelve/`
  - `services/PlaybackService.kt:458` — `setOffloadEnabled(sharedPreferences.enableOffload)`
  - `ext/SharedPreferences.kt:49-55` — `ENABLE_OFFLOAD_KEY`, default `true`
  - `SettingsActivity.kt:148` — user-facing toggle
- HAL: `hardware/qcom-caf/msm8953/audio/hal/audio_hw.c` (`start_output_stream`,
  around line 4208 for the `"failed /w error %s"` log)
- tinycompress: `external/tinycompress/compress.c`
  - `compress_open()` — lines 195-259 (SET_PARAMS on open, line 254-256)
  - `compress_set_codec_params()` — lines 627-644 (SET_PARAMS on track change)
  - `oops()` — lines 105-120 (error string = `fmt + ": " + strerror(errno)`)
- Kernel driver: `kernel/xiaomi/msm8937/techpack/audio-legacy/asoc/msm-compress-q6-v2.c`
  - `msm_compr_set_params()` — line 2111
  - dispatch to `msm_compr_configure_dsp_for_playback()` — lines 2314-2317
- ADSP error mapping: `kernel/xiaomi/msm8937/techpack/audio-legacy/dsp/adsp_err.c:92-116`
- ASM opcode: `kernel/xiaomi/msm8937/techpack/audio-legacy/include/dsp/apr_audio-v2.h:7838`
  (`ASM_STREAM_CMD_OPEN_WRITE_V3 0x00010DB3`)
- Audio policy: `dumpsys media.audio_policy` confirms `compressed_offload`
  (`AUDIO_OUTPUT_FLAG_DIRECT|COMPRESS_OFFLOAD|NON_BLOCKING`) is advertised as an
  available output on this device — so the app's request is not spurious, the
  policy config says this should work.
- Related: `PLAN-audio.md` Issue 2 (ACDB format mismatch, OPEN); holistic model
  Cluster C (stock A8 blobs on 4.19 ABI gap) for the ADSP-firmware hypothesis.

## Debugging

```bash
android16-adb logcat -v threadtime | grep -iE "audio_hw|AudioFlinger|AudioTrack|ExoPlayer|compr"
android16-adb shell 'logcat -v threadtime & dmesg -w'   # synchronized capture — do this first next time
android16-adb shell dmesg | grep -iE "q6asm|afe_send|compr|adsp"
android16-adb shell dumpsys media.audio_policy | grep -i offload
android16-adb shell date; android16-adb shell cat /proc/uptime   # to correlate dmesg uptime -> wall clock post-hoc
```
