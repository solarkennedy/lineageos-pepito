# voip-stream: open a VoIP-style audio stream from the shell

Opens the audio streams a VoIP app opens (Google Voice does this even during a
carrier-mode call), using `app_process`. No APK and no system changes. The aim
is to reproduce, during an ordinary cellular call, the second ADSP voice session
that `vendor.voice.path.for.pcm.voip=true` creates through the msm-pcm-voip driver,
and have the far end listen for garbling.

## Build

```bash
./build.sh          # javac + d8 against ~/Android/Sdk/platforms/android-36/android.jar
                    # override with ANDROID_JAR=... D8=...; output out/voipstream.jar
```

## Push + run

```bash
dut1-adb push out/voipstream.jar voipstream.sh /data/local/tmp/
dut1-adb shell chmod 644 /data/local/tmp/voipstream.jar

# preferred: the wrapper turns SIGTERM/SIGINT/HUP into a clean release
dut1-adb shell sh /data/local/tmp/voipstream.sh <mode> [seconds] [--tone]
# bare form (works, but a signal kills it outright, see below)
dut1-adb shell CLASSPATH=/data/local/tmp/voipstream.jar app_process / VoipStream <mode> [seconds] [--tone]
```

`seconds` set to 0 or left out means run until stopped. Stop a backgrounded run with
`kill -TERM <wrapper pid>`, by typing `q` + Enter on the tool's stdin, or with
Ctrl-C when the wrapper runs in the foreground.

| mode | opens |
|---|---|
| `record` | AudioRecord, source `VOICE_COMMUNICATION`, 16 kHz mono PCM16, read and thrown away |
| `play` | AudioTrack, `USAGE_VOICE_COMMUNICATION` / `CONTENT_TYPE_SPEECH`, 16 kHz mono, plays silence (`--tone`: 440 Hz at about -26 dBFS) |
| `both` | both at once, like a VoIP app |
| `mode-comm` | `both`, plus `MODE_IN_COMMUNICATION` set through `IAudioService.setMode(mode, binder, "com.android.shell")`, restored to `MODE_NORMAL` on exit |
| `vrec`, `vrec-ns`, `vrec-aec`, `vrec-aec-ns` | AudioRecord only, source `VOICE_RECOGNITION`, with the platform NoiseSuppressor / AcousticEchoCanceler created and enabled as named |

`--no-ns` / `--no-aec` create the auto-attached VOICE_COMMUNICATION effect and disable it, so `mode-comm --no-ns`
is AEC only (HAL `HANDSET_MIC_AEC`) and `mode-comm --no-aec` is NS only (`HANDSET_MIC_NS`).

Runs as root or as the shell user (uid 2000). The streams are attributed to
`com.android.shell` through a ContextWrapper over `ActivityThread.systemMain()`'s
system context. Hidden APIs are reached only by reflection, and the tool runs
without the context if that fails. Every stream start and stop, and every error,
is printed with a timestamp. The exit code is 0 only if there were no errors.

## What it triggers on our build (dut1, no call, 2026-11-07)

- `record`, `both` and `mode-comm` open HAL usecase 43 `compress-voip-call`
  (logcat `compress_voip: voip_start_call: Opening PCM capture/playback device
  card_id(0) device_id(3)`). This happens in MODE_NORMAL too. The kernel log then
  shows `DL data not available` every 20 ms (`voip_process_dl_pkt: N callbacks
  suppressed`) and an `Active_profile:...` switch.
- `play` alone does not open it. The track goes to `low-latency-playback`, even
  under `mode-comm`, so nothing feeds the voip downlink, which is why the DL
  starves in every mode.

## Verify

```bash
dut1-adb shell dmesg -w | grep -E "voip_process_dl_pkt|DL data not available|Active_profile|Fatal error on adsp"
dut1-adb logcat | grep -E "compress_voip|compress-voip-call"
dut1-adb shell dumpsys audio | grep -E "source client=VOICE_COMMUNICATION|USAGE_VOICE_COMMUNICATION|Mode owner|Package: com.android.shell"
```

## Limitations

- ART has no `sun.misc.Signal` and runs no Java code on SIGTERM or SIGINT, so the
  bare `app_process` form simply dies. audioserver still closes the streams on
  binder death, but an AudioManager mode set by `mode-comm` is only cleaned up by
  AudioService's death handling. Use `voipstream.sh`: it traps the signal and
  touches a stop file the tool polls every 200 ms. The shell user can't `mkfifo`
  in /data/local/tmp under SELinux, which is why it uses a file and not a FIFO.
- During a real call, `mode-comm` would fight Telecom for the audio mode
  (IN_CALL). For the Google Voice reproduction, use `both` or `record`.
