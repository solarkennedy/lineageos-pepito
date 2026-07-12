# PLAN-audio: Audio HAL and ACDB Bringup

---

## ✅✅ ACDB SOLVED 2026-07-11 — loader was NEVER SHIPPED; Palm's own stock cal engages
## FLASH-VALIDATED same day: clean flashed image, Enforcing, cal-block match + hw_delay 474µs on cold-boot image; zero avc denials; only leftover dlsym = fluence_nn (newer-HAL feature, harmless). Remaining: subjective call-quality/echo listen (voice cal now engages for the first time).

**The "A8-era ACDB format ≠ A12/13-era loader" theory was FALSE.** Root cause of
"DSP uncalibrated" was much dumber: **`libacdbloader.so` never made it into our
vendor image**, so no ACDB file was ever parsed. `platform_init` logged
`DLOPEN failed for libacdbloader.so` on every boot (the "dlsym error for
acdb_send_voice_call" was the same failure — dlsym against a NULL handle). All
downstream symptoms (topology 0x0, `cal_block is NULL`, hw_delay 0) follow from
that. The blobs ARE listed in `mithorium-common/proprietary-files-qc-vndr.txt`
(and registered in extract-files.py) but were never extracted onto disk — same
class of packaging gap as the camera-chromatix regression.

**Format-mismatch falsified empirically:** Palm's files and prada's nightly files
are the SAME container generation (`QCMSNDDB`/`AVDB`, identical chunk sequence,
both target ADSP.BF.2.4 / codec MSM8X52.1.0, both authored Aug 2018). Palm's are
in fact a *newer* ACDB SW rev (8.0.4 vs prada's 8.0.0). The A15 nightly loader
(ACDB SW 10.0.17) parses ACDB File 8.x fine — **no QACT transplant, no prada
substitution needed. Palm's genuine per-device tuning is the end state, and it
already works.**

**Live-validated on the DUT (Enforcing) 2026-07-11:** pushed the 6-lib closure →
restart `vendor.audio-hal` → `ACDB initialized`, all 7 pepito calfiles loaded;
speaker playback now logs `afe_find_cal: acdb_id 14 ... cal block is a match,
size is 1372` + `Sending cal_index cal 0`, `afe_send_hw_delay: delay_usec 474`
(was 0), AFE topology 0x1025e resolved, audproc/audvol/audstrm tables sent
(`AUDIO_SET_AUDPROC_CAL`, `AUDIO_SET_VOL_CAL`). `acdb_loader_send_voice_cal{,_v2}`
are exported → voice/CVP/EC cal will engage on calls now.

**Staged (uncommitted) in `vendor/xiaomi/mithorium-common`:** the dlopen closure
extracted from the 20260526 nightly vendor.img (debugfs, rootless):
`libacdbloader.so` + DT_NEEDED `libaudcal.so libacdbrtac.so libadiertac.so
libacdb-fts.so` + `libdiag.so` (needed by libaudcal) → `proprietary/vendor/lib/`
+ 6 `PRODUCT_COPY_FILES` entries in `mithorium-common-vendor.mk` (hand-appended,
respecting the no-extract-utils-regen guardrail). 32-bit only (audio HAL is
32-bit). Labels: plain `vendor_file` works under Enforcing (proven live).

**Validate after next build/flash:** play music + check dmesg for `cal block is a
match` / nonzero `delay_usec`; make a VoLTE call → no more `dlsym error for
acdb_send_voice_call`, listen for volume/EC improvement. Leftover benign line:
`afe_send_port_topology_id ... ret -95` at port start (before per-device cal
push; the topology arrives with the AFE cal). Compare against A11 someday if it
bugs anyone.

---

## ✅✅ IN-CALL AUDIO WORKING — VALIDATED LIVE BY KYLE 2026-07-10 ("OMG it's working!!!")

**TWO stacked root causes, both fixed the same evening:**

1. **Voice routing** (section below, staged earlier today): voice paths → QUAT/TFA9896,
   handset = TFA `Handset` profile + `Rec GPIO` (kcontrol reconstructed in the kernel
   driver — Palm's binary had it, the GPL dump didn't; `tfa98xx.{c,h}` staged).
2. **⭐ `audio_platform_info.xml` WAS NEVER LOADED — wrong filename.** On internal-codec
   cards the HAL loads **`audio_platform_info_intcodec.xml`** (suffix from
   `update_codec_type_and_interface` / snd card `msm8952-snd-card-mtp`); on failure it
   logs `platform_info_init: Failed to open ... using defaults` and does NOT fall back
   to the base name. So every platform_info setting (usecase pcm_ids, acdb ids, backend
   interfaces) had been silently defaulted since bring-up began. The fatal symptom:
   HAL default puts VoiceMMode1 at PCM **44**; our kernel FE is **34**
   (`/proc/asound/pcm`) → `voice_start_usecase: cannot open device 44 for card 0:
   Inappropriate ioctl for device` → instant voice teardown = the "silent call".
   Media never noticed because FE→BE mixer ctls route in the DSP regardless.
   **Fix: file renamed** `audio/platform_info/audio_platform_info_intcodec.xml`
   (git mv staged; also pushed live to /vendor/etc/). Diagnosis trick: restart
   `vendor.audio-hal` with logcat clean and read the `platform_info` tag.

**Follow-ups (quality, non-blocking):**
- [ ] Commit the staged work: mixer_paths.xml voice edits, platform_info rename,
      kernel `tfa98xx` Rec GPIO kcontrol.
- [ ] platform_info parse errors (harmless, stock-A8-era device names this HAL lacks):
      `SND_DEVICE_OUT_MUSIC_SPEAKER`, `_IN_HANDSET_STEREO_DMIC`, `_IN_SPEAKER_STEREO_DMIC`,
      `_OUT_VOICE_SPEAKER_AND_VOICE_{HEADPHONES,ANC_HEADSET}` — prune the entries.
- [x] `platform_switch_voice_call_device_post: dlsym error for acdb_send_voice_call` —
      ✅ 2026-07-11: was the missing libacdbloader.so (dlsym on NULL handle), see top section.
- [x] ACDB quality pass — ✅ SOLVED 2026-07-11 (top section): loader was never shipped;
      Palm's own stock cal files parse + engage with the nightly loader. Prada
      substitution and QACT transplant both moot.
- [x] TX mic — ✅ ROOT-CAUSED + FIXED 2026-07-11: post-ACDB-flash call had DEAD TX
      (far side heard nothing; RX fine on earpiece+speakerphone). Two-channel tinycap
      probe showed **ch1/ADC1 = digital zero, ch2/ADC2-INP3 alive**; DAPM dump during
      capture: `ADC1: Off` while ADC2 On. Root cause: the 4.19 sdm660_cdc driver added
      an `ADC1_INP1 Switch` DAPM gate between AMIC1 and ADC1 (`{"ADC1",NULL,"ADC1_INP1"}`,
      `{"ADC1_INP1","Switch","AMIC1"}`) that the stock-3.18-derived mixer_paths.xml never
      sets → primary mic dead at codec level. Proven live: switch On → ch1 signal.
      Fix (2 lines, prada's nightly XML is the canonical pattern): `ADC1_INP1 Switch`
      = 0 in defaults block, = 1 in the `adc1` path (all mic devices include adc1).
      Staged in mixer_paths.xml + live-pushed. Retro-explanation of the 07-10 "both
      ways worked" call: with NO voice cal, the passthrough topology let the far side
      hear via the SECONDARY mic; once real fluence dual-mic cal engaged (ACDB fix),
      the beamformer got dead-primary + ambient-reference and gated TX to silence.
      Pepito does have 2 mics (Kyle: two holes; stock: fluencetype=fluence,
      voice-dmic-ef, AMIC1=Handset Mic + AMIC3/INP3=Secondary Mic).
- [x] Validation ✅ 2026-07-11: stereo recorder app confirmed BOTH mics live with
      correct top/bottom separation (Kyle); live call validated — far side reports
      clean voice, NO ECHO (first call ever with real voice cal + working primary mic).
      Untested: BT-SCO call (bt-sco paths are empty stubs, same as stock).
- [x] Speakerphone echo — no echo reported on the 2026-07-11 validation call (first
      call with voice cal engaged). Watch for complaints in daily use; the EXT_EC
      combo-path question stays as background context if echo ever shows up.

--- (original root-cause writeup below, kept for the record) ---

## 🔴 IN-CALL AUDIO — root cause found + fix STAGED 2026-07-10 (awaiting flash/live-push)

Calls connect (volte lane ✅) but no voice audio either direction. **Root cause is
ROUTING, not ACDB** (media plays fine with the same ACDB cal-miss, so cal-miss does
not mute; it only degrades quality/EC).

**Two stacked routing bugs, both from stock `mixer_paths_mtp.xml` diff
(`backup-stock-android-8.1-AML0/vendor.bin.extracted/etc/mixer_paths_mtp.xml`):**

1. **Voice streams routed to a dead backend.** Every voice path in our
   `mixer_paths.xml` (`voice-call`, `voicemmode1/2-call`, `volte-call`,
   `compress-voip-call`, `vowlan-call`, `voice2-call`, `qchat-call`) connected the
   vocoder stream to `PRI_MI2S_RX_Voice Mixer` — the internal-codec backend, which
   on pepito is unclocked/unused. Stock routes ALL of them to **`QUAT_MI2S_RX_Voice
   Mixer`** (the TFA9896 backend, same one our working speaker uses). Meanwhile our
   `audio_platform_info.xml` already said `SND_DEVICE_OUT_VOICE_HANDSET/SPEAKER →
   QUAT_MI2S_RX` — so the HAL opened the QUAT backend but the voice stream was
   mixed into PRI: silence by construction.
2. **Earpiece is behind the TFA, not the internal codec.** Our `handset` device
   path drove the internal codec EAR PA (RX1/RDAC2/EAR_S) — physically not
   connected on pepito. Stock `handset` = `TFA9896 Profile=Handset` + `TFA9896 Rec
   GPIO=On`: the receiver hangs off the TFA9896's rec-gpio (tlmm 17) output switch
   (this is why stock's TFA DT node has `rec-gpio`). Stock `voice-speaker` likewise
   uses the dedicated `Speech` container profile (not `Music`).

TX (mic) plumbing was already stock-identical (`Voice_Tx Mixer TERT_MI2S_TX_Voice`,
`handset-mic` = adc1) — expected to work, but never exercised; see validation.

**Staged in `device/xiaomi/Mi8937/audio/mixer_paths/mixer_paths.xml`:**
- All 8 voice-family paths PRI→QUAT (incl. `compress-voip-call`, `qchat-call`).
- `handset` → TFA `Handset` profile + `Rec GPIO On`; `voice-speaker` → `Speech` + Rec Off.
- Stock-faithful `voicemmode1/2-call speaker` combo paths with `VOC_EXT_EC MUX =
  QUAT_MI2S_TX` (echo ref from the TFA's I2S feedback; our HAL may not select the
  combo — harmless if unused, revisit for speakerphone echo).
- Reset-defaults block: QUAT voice mixer ctls (0), `VOC_EXT_EC MUX=NONE`,
  `TFA9896 Profile=Bypass` + `Rec GPIO=Off` (stock defaults; were missing).

**Validation (no kernel/DT change — a live vendor push works, no flash needed):**
```bash
adb root; adb remount vendor   # or mount -o remount,rw /vendor
adb push device/xiaomi/Mi8937/audio/mixer_paths/mixer_paths.xml /vendor/etc/mixer_paths.xml
adb shell 'setprop ctl.restart audioserver; setprop ctl.restart vendor.audio-hal'  # or reboot
```
1. Ctl sanity: `/data/local/tmp/tinymix 'TFA9896 Profile'` — enum must include
   `Handset`/`Speech`/`Bypass` (from tfa9896.cnt); `tinymix 'TFA9896 Rec GPIO'` exists.
2. Music to speaker still works (defaults-block regression check).
3. Mic-only sanity BEFORE a call: record with a voice-recorder app (exercises
   handset-mic/TERT_MI2S_TX independent of the voice path).
4. Place a VoLTE call handset-mode; during it: `tinymix | grep VoiceMMode1` →
   `QUAT_MI2S_RX_Voice Mixer VoiceMMode1` = 1; listen both directions.
5. Speakerphone in-call; then BT-SCO call someday (paths untouched, still int-BT).

**If still silent after routing fix:** next suspects (in order): voice vol table /
CVP cal from the ACDB cal-miss (check `dmesg | grep -iE "voice|cvp|cvs"` during
call), then TERT_MI2S_TX clocking (does step 3 record?). ACDB story: see Issue 2 —
Palm A8 set staged but format-incompatible with the A15 loader (topology 0x0 /
cal_block NULL, NON-fatal); format-compatible sibling set = extract prada's
`acdbdata/` from `lineage-23.2-20260526-nightly-Mi8937-signed.zip` (on disk, tree
root) — quality/EC follow-up, not the silence fix. Ideal end-state: QACT transplant
of Palm values into the modern container.

> **Note:** there is a second, older-but-detailed plan at
> `device/xiaomi/mithorium-common/PLAN-audio.md` covering the 2026-06-06 work
> (mixer_paths.xml, audio_platform_info.xml, ACDB staging, audio-policy `Line`
> port removal). This file is the current top-level status.

---

## ⚠️ REAL STATUS (2026-07-06): SPEAKER HAS NEVER MADE SOUND

The **speaker is physically silent** and — per the 2026-07-06 investigation —
**always has been**. The earlier "audible via speaker" claim was an over-read: its
only evidence was `pcm0p RUNNING` / `acdb_dev_id 14` (transport state), which is
NOT acoustic proof. Confirmed dead-silent with a live listen on `c39a6acf`.

### Root cause (traced 2026-07-06): external TFA9896 smart-amp never brought up

Every software layer is verified healthy AND identical to the stock ground-truth
phone during playback — the fault is below the register layer, in the physical
output stage:

| Layer | Live state during playback (`c39a6acf`) |
|---|---|
| App → AudioTrack | ~145 s PCM frames delivered, no errors |
| Volume / mute | `STREAM_MUSIC` max, not muted, master mute off |
| PCM | `RUNNING`, `hw_ptr` advancing, `avail 0` (DSP consuming) |
| Codec routing | `RX3 MIX1 INP1=RX1`, `SPK=Switch` — byte-identical to stock speaker path |
| Codec digital gain | `RX1/RX2/RX3 Digital Volume = 84` (max) |
| Internal class-D | `SPK PA: On`, `SPK DAC: On`, `VDD_SPKDRV: On` (DAPM debugfs) |

**But pepito's speaker is NOT driven by the codec's internal class-D — it uses an
external NXP TFA9896 DSP smart-amp, which is completely absent from this build.**
Proof: stock Palm A8.1 DTB (`backup-stock-android-8.1-AML0/extracted/dtbs/pepito.dts:11296`):

```dts
i2c@7af6000 {                        /* BLSP2 QUP2 — NOT one of our live i2c-2/i2c-3 */
    tfa98xx@34 {
        compatible = "nxp,tfa9896";
        reg = <0x34>;
        irq-gpio   = <&tlmm 126>;    /* 0x7e */
        reset-gpio = <&tlmm 125>;    /* 0x7d */
        rec-gpio   = <&tlmm 17>;     /* 0x11 — receiver/earpiece switch */
        vdd-supply = <...>;
    };
};
```

What's missing in our tree (all four are required for sound):
1. **Kernel driver** — we only have `sound/soc/codecs/tfa9879.c` (a *different*,
   non-DSP chip) and it's `# CONFIG_SND_SOC_TFA9879 is not set`. There is **no
   tfa9896/tfa98xx driver** anywhere in `kernel/xiaomi/msm8937`. Needs the NXP/
   Goodix `tfa98xx` (aka `tfa9896`) ASoC driver ported in.
2. **DT i2c node** — the `tfa98xx@34` node above, on the BLSP2 i2c bus
   (`i2c@7af6000`), which itself is not currently exposed as a live i2c adapter
   (our device only shows `78b6000.i2c`=i2c-2 and `78b7000.i2c`=i2c-3). The bus
   must be enabled too.
3. **Firmware container** — TFA98xx is a DSP amp; it needs a `.cnt`/`.dsp`
   speaker-model + tuning container in `/vendor/firmware` (or `/etc`). None is
   staged (`device/`/`vendor/` have zero tfa firmware; the two "tfa" grep hits are
   camera `ts_detectface` false positives). Pull from stock A8.1 `/vendor` or
   `/etc/firmware`.
4. **ASoC machine wiring + userspace** — route the codec speaker path through the
   TFA and load the container (either in-kernel tfa DSP path or the `tfa` userspace
   HAL). The machine driver's `qcom,msm-ext-pa = "primary"` is already set (pepito
   `audio.dtsi:92`), which is necessary but not sufficient.

### The AW87319 lead is a DEAD END (red herring)
The `MI8937 AW87319 PA` DAPM widget seen in `debugfs/asoc/.../dapm` and the
`AW87319_PA-mi8937` i2c driver exist because our kernel compiles the Awinic amp in
for the **whole Mi8937 family** (`CONFIG_SND_SOC_AW87319_MI8937=y`). pepito does
**not** have that chip — stock uses the TFA9896. The AW87319 widget is orphaned (no
DAPM routes, never powers up) and its driver never binds (no i2c node). Do not
chase it; do not add an aw87319 DT node.

### Reference values captured 2026-07-06 (two-device / stock-DTB)
- Sibling `santoni` DOES use aw87319 (`@0x58` on `&i2c_2`, rst `tlmm 124`) — that
  is santoni's amp, NOT pepito's. Ignore for pepito.
- Stock A8.1 pepito amp = TFA9896 values above. GPIO 125/126/17 are free in our
  pepito DT (no conflicts).
- Instruments left on `c39a6acf`: `/data/local/tmp/tinymix` (pulled from stock
  A11), debugfs mounted (`mount -t debugfs none /sys/kernel/debug`). Read codec
  DAPM at `/sys/kernel/debug/asoc/msm8952-snd-card-mtp/200f000.qcom,spmi:qcom,pm8937@1/dapm/`.

### Driver availability (verified 2026-07-06) — two paths, lighter than first feared

Our tree has ONLY `sound/soc/codecs/tfa9879.c` (compatible `nxp,tfa9879` — a
different, older non-DSP chip). No tfa9896/tfa98xx/tfa989x driver anywhere.

**Path A — mainline `tfa989x` (DSP-bypass), RECOMMENDED FIRST.**
`torvalds/linux:sound/soc/codecs/tfa989x.c` is a ~400-line GPL driver for the TFA1
family. Verified from source:
- Compatible table = `nxp,tfa9890` / `nxp,tfa9895` / `nxp,tfa9897` — **does NOT list
  `nxp,tfa9896`**, but 9896 is same-family; adding a `nxp,tfa9896` compatible + a
  revision-ID struct is a small patch, not a new driver. Must add/verify the 9896
  revision register value.
- **Loads NO firmware** — no `request_firmware`/`.cnt`. It explicitly *bypasses the
  CoolFlux DSP* and drives the amp as a plain class-D via regmap writes.
- So this collapses the "4-part bring-up" to: port the driver → add 9896 compat/rev
  → add DT node → enable the BLSP2 i2c bus → backport to 4.19 (ASoC `component` API;
  our tree is mainline-aligned so likely minimal). ~1 day, gets AUDIBLE sound.
- ⚠️ **Bypass = no speaker protection / no DSP volume+EQ.** No excursion/thermal
  limiter — do not drive at high volume until validated; consider a conservative
  digital-gain cap. Real hardware-safety concern on a device we own.
- Added in Linux 5.14 (9897) / 5.11-era; DT binding `Documentation/devicetree/
  bindings/sound/nxp,tfa989x.yaml`.

**Path B — port pepito's OWN vendor `tfa98xx` driver + container. CHOSEN 2026-07-06
(user: "go all the way, match original quality").**

We have the complete original recipe on local disk — no reverse-engineering, no
approximation, no mainline-bypass. All irreplaceable pieces in hand:

- **Driver source (3.18):** `…/android-pepito-pvg100-kernel-upgrade/kernel_src/
  sound/soc/codecs/tfa98xx.c` (3278 lines) + headers `tfa98xx.h`,
  `tfa98xx_genregs_N1C.h`, `tfa9896_tfafieldnames.h`, `tfa98xx_parameters.h`,
  `tfa98xx_tfafieldnames.h`. **Natively lists `nxp,tfa9896`** in its
  `of_device_id` table (line 3222) — pepito's exact chip, no patching needed.
  **Self-contained DSP driver** — loads the container itself via
  `request_firmware_nowait` (default `fw_name="tfa98xx.cnt"`, DT/module-param
  overridable). **NO userspace tfa HAL required.**
- **Tuning container:** `…/backup-stock-android-8.1-AML0/vendor.bin.extracted/
  firmware/tfa9896.cnt` (10031 B, magic `PM3_01`, embeds `TFA9896`) — the actual
  Palm PVG100 speaker protection + EQ tuning. **This must pair with the matching
  driver version** (container parser `nxpTfaContainer_t`), which is exactly why we
  port THIS driver, not a newer/mainline one.
- **DT values (stock A8.1 DTB):** `tfa98xx@34` on i2c `7af6000` (BLSP2), reset
  `tlmm 125`, irq `tlmm 126`, rec `tlmm 17`. On A11 (3.18) this bus enumerates as
  `i2c-6`; on our 4.19 build the `7af6000` bus is NOT currently exposed (only
  `78b6000`=i2c-2, `78b7000`=i2c-3) → **the i2c bus node must be enabled too**.

**Live working reference: A11 `81eed371` (kernel 3.18.71, device "Pepito").** Has
the vendor `tfa98xx` driver bound and probed: `/sys/bus/i2c/drivers/tfa98xx/6-0034`
→ `7af6000.i2c/i2c-6/6-0034`. Use it as ground truth for register state / DAPM /
routing during the port (two-device method). Plus the A8 stock phone if needed.

### Port work (the actual effort — tractable, ~days not weeks)

1. **codec→component API migration** in `tfa98xx.c` (MAIN LABOR): the 3.18 driver
   uses the removed `snd_soc_codec` API (38 sites, 0 `snd_soc_component`); our 4.19
   kernel is component-only (our `tfa9879.c` confirms: 0 codec / 11 component;
   `snd_soc_register_codec` absent from `include/sound/soc.h`). Mechanical, known
   migration: `snd_soc_register_codec`→`_component`, `snd_soc_codec`→
   `snd_soc_component`, `_codec_get_drvdata`/`_get_dapm`/`kcontrol_codec` →
   component variants, codec `.probe/.remove` → component ops. Cross-reference an
   existing 4.x-ported tfa98xx (other NXP/LOS trees) to speed it, but keep OUR
   chip/container version.
2. **Build glue:** add tfa98xx.c + headers to `kernel/xiaomi/msm8937/sound/soc/
   codecs/` (or techpack), Kconfig + Makefile symbol, enable in `mi8937_defconfig`.
   Independent of the disabled `tfa9879` symbol.
3. **DT:** add `tfa98xx@34` node (values above) under the BLSP2 i2c bus; **enable
   that i2c controller node** (currently off in our DT); add reset/irq/rec gpios +
   pinctrl. Put in `xiaomi-msm8937/pepito/audio.dtsi`.
4. **Container staging:** copy `tfa9896.cnt` into the tree → install to
   `/vendor/firmware/` as `tfa98xx.cnt` (or set `fw_name` to match), via device.mk
   `PRODUCT_COPY_FILES`.
5. **Machine-driver integration — RESOLVED 2026-07-06 by studying stock msm8952.c +
   pepito DTB. Simpler than assumed: the TFA is NOT wired into the ASoC card.**
   Authoritative proof — stock pepito sound node `asoc-codec-names` =
   `"msm-stub-codec.1", "cajon_codec", "msm-hdmi-dba-codec-rx"` (pepito.dts:~9848);
   the PRI_MI2S_RX backend's `dlc_rx1[]` codecs are the two INTERNAL codecs
   (`msm_dig_cdc_dai_rx1` + `msm_anlg_cdc_i2s_rx1`); the machine driver's aux_dev
   path is WSA881x-only (`CONFIG_SND_SOC_WSA881X_ANALOG`). **The TFA9896 is a
   standalone i2c codec (`snd_soc_register_codec`, own `AIF Playback` DAI + monitor
   thread), not a card dai-link/aux_dev.** It:
   - snoops the **PRI_MI2S I2S output** — the DSP clocks PRI_MI2S out the `pri_i2s`
     pins because `qcom,msm-ext-pa="primary"` (already set in our pepito
     `audio.dtsi:92`), so the machine-driver side needs **no dai_link edits**;
   - starts its own DSP via a **monitor `delayed_work` + IRQ** (`tfa98xx.c` ~623-651,
     1231 "don't start if no clock", `tfa_dev_start(profile,vstep)`), gated on I2S
     clocks. Confirm what actually triggers start on the live A11 (monitor auto-start
     vs an init/userspace poke to its debugfs `rw`/state iface) during impl.
6. **Speaker ROUTING must change (key!):** stock sends speaker audio **digitally out
   PRI_MI2S → TFA**, NOT through the internal class-D. Our current build routes
   `speaker` to the internal `SPK`/RX3 class-D (that's why `SPK PA:On` yet silent —
   wrong sink). Need the speaker mixer path / usecase to clock **PRI_MI2S RX** (the
   ext-PA I2S path) so the TFA receives audio. Verify pri_i2s pinctrl active during
   speaker playback; cross-check the working A11's mixer routing (two-device).

---

## Status (2026-07-02) — SUPERSEDED, see REAL STATUS above

Audio **WORKS at the transport level**: sound card `msm8952-snd-card-mtp` registers,
`audio_hw_primary` opens streams, playback routes to speaker and is audible
(verified live: `pcm0p` RUNNING, `acdb_dev_id 14` resolved for app-type cfg).
The 06-29 root causes in the old version of this file (digital codec DAI -517,
audioserver crash, missing acdbdata/init script) are all **RESOLVED** — ACDB files,
mixer_paths.xml and audio_platform_info.xml are staged in-tree
(`device/xiaomi/Mi8937/audio/`, wired via `device.mk`).

Two issues remain:

1. **"Wired headphones" shown in UI** — false jack detection (root-caused, fix below).
2. **DSP calibration not applied** — ACDB version mismatch ("Issue 4" in the
   mithorium-common plan): audio plays unprocessed.

---

## Issue 1: UI shows "Wired headphones" — **FIXED & VERIFIED 2026-07-03**

**Verified on A16 (`c39a6acf`) after flash:** no "Headset Jack" input device in
`/proc/bus/input/devices` (no `SW=` node); `dumpsys audio` "Connected devices:" is
empty (no LINE device); no `line(0x20000)` in any strategy — media routes to
`speaker(2)`, phone to `earpiece(1)`. No `setWiredDeviceConnectionState` OUT_LINE
event. Matches stock behavior. Original root-cause writeup below.

---


### Symptom
Volume panel / Settings shows output as "Wired headphones" even though sound
correctly plays from the speaker.

### Evidence chain (live, both devices)
- A16: ALSA jack input device `msm8952-snd-card-mtp Headset Jack`
  (`/dev/input/event5`) has **`SW_LINEOUT_INSERT (0006)` and
  `SW_JACK_PHYSICAL_INSERT (0007)` asserted** at boot — the WCD MBHC
  false-detects a line-out cable. The PVG100 has **no 3.5mm jack**; the sense
  lines float.
- `WiredAccessoryManager` translates SW_LINEOUT_INSERT →
  `setWiredDeviceConnectionState(AUDIO_DEVICE_OUT_LINE 0x20000, AVAILABLE)`
  (visible in `dumpsys audio`). APM rejects it (`error=1`) because the `Line`
  devicePort was removed from `audio_policy_configuration.xml` in the 06-06 fix —
  so **routing is unaffected**, but AudioService still records a wired device →
  UI label.
- **Stock ground truth (`android11-adb`): NO "Headset Jack" input device exists
  at all.** Palm disabled MBHC entirely: the stock active sound node
  (`dts-3.19-pepito/pepito.dts` `sound{}`) **omits `qcom,msm-mbhc-hphl-swh` /
  `qcom,msm-mbhc-gnd-swh`**, and stock `wcd-mbhc-v2.c` `wcd_mbhc_init()` errors
  out early (before `snd_soc_card_jack_new`) when the props are missing. Stock
  routing also has no headset entries (only Handset Mic / Secondary Mic).

### Root cause
Our pepito inherits `qcom,msm-mbhc-hphl-swh = <0>` / `gnd-swh = <0>` from the
Xiaomi base `vendor-legacy/qcom/msm8937-audio.dtsi` (&int_codec, lines 43-44);
`xiaomi-msm8937/pepito/audio.dtsi` doesn't delete them, so MBHC initializes on
hardware that has no jack.

### Fix (staged plan — matches stock behavior)
1. In `kernel/.../dts/xiaomi-msm8937/pepito/audio.dtsi` `&int_codec`:
   ```dts
   /delete-property/ qcom,msm-mbhc-hphl-swh;
   /delete-property/ qcom,msm-mbhc-gnd-swh;
   ```
   (Optionally also the `qcom,cdc-us-eu-gpios`/`us-euro-gpios` inherited props —
   only used by MBHC gnd/mic swap; stock has neither.)
2. **Required 4.19 driver guard** (stock 3.18 didn't need it, our techpack does):
   ⚠️ **the driver that BUILDS on msm8937 is `techpack/audio-legacy/`, NOT
   `techpack/audio/`** — `techpack/audio/Makefile:1` stubs itself out
   (`obj-y := stub.o`) when `CONFIG_ARCH_MSM8937=y`. Both copies have identical
   MBHC code; patch the **legacy** one (patching only `techpack/audio/` would be
   a no-op and the NULL deref below would still panic).
   With the props absent, `wcd_mbhc_init()` bails **before** setting
   `mbhc->component` (`techpack/audio-legacy/asoc/codecs/wcd-mbhc-v2.c:1789-1801`
   → `goto err` skips the `mbhc->component = component` at `:1833`); the
   codec probe ignores the error (`msm-analog-cdc.c:4542`, fine, matches stock),
   **but** the machine driver `techpack/audio-legacy/asoc/msm8952.c:1891` later
   calls `msm_anlg_cdc_hs_detect()` → `wcd_mbhc_start()` which dereferences
   `mbhc->component->card` (`wcd-mbhc-v2.c:1661-1662`) → **NULL deref**; and if
   it returned an error instead, `msm8952_audrx_init` (`msm8952.c:1892-1895`)
   would fail the whole card. Add to `wcd_mbhc_start()` right after the existing
   `!mbhc || !mbhc_cfg` check:
   ```c
   /* MBHC disabled via DT (no jack on this board) */
   if (!mbhc->component)
       return 0;
   ```
3. Expected result: one benign `missing qcom,msm-mbhc-hphl-swh in dt node`
   dmesg line, **no** Headset Jack input device (= stock), no wired-device event,
   UI shows Phone speaker.

### Verification after flash
```bash
adb shell 'cat /proc/bus/input/devices | grep -B6 SW='   # jack device must be GONE
adb shell 'dumpsys audio | grep setWiredDeviceConnectionState'  # no 0x20000 event
```

---

## Issue 2: ACDB long-term plan — ❌ SUPERSEDED 2026-07-11 (theory was wrong; see top section)

> The "version mismatch" below was never real: the loader was absent, so nothing
> was ever parsed. Kept for the record.

### Current state (verified 2026-07-02)
- Genuine **Palm 8.1 MTP ACDB set** staged in-tree at
  `device/xiaomi/Mi8937/audio/acdbdata/pepito/` (7 files, md5-identical to stock
  `android11-adb:/vendor/etc/acdbdata/MTP/`), installed to
  `/vendor/etc/acdbdata/pepito/` via `device.mk:66`.
- Path selection: `init.xiaomi.device.sh` pepito case sets
  `persist.vendor.audio.calfile{0..6}` (NOT `init.acdbdata.sh` — pepito's DT
  compatible lacks `qcom,mtp`/`qcom,qrd`, so that script bails; it isn't even
  installed on the current image).
- Files load, but **no cal blocks match**: every stream open logs
  `afe_send_port_topology_id: topology id 0x0 ... ret -95`,
  `q6asm_send_cal: cal_block is NULL`, `send_afe_cal_type: dev_acdb_id[40] is 0`,
  `afe_send_hw_delay: delay_usec 0`. Audio plays **unprocessed** — no speaker
  EQ/protection, no echo cancellation, no HW delay compensation.

### Why: the A8-era ACDB file format doesn't match the A12/13-era `acdb_loader`
Lineage 23 ships (block version tags differ), so lookups miss.

### Long-term options (from mithorium-common plan, still the right list)
- **Option A (recommended next):** take a sibling set (prada — closest board:
  MSM8940 + int-codec + MTP) from the Lineage nightly `/vendor/etc/acdbdata/`,
  drop into `audio/acdbdata/pepito/`. Format matches our loader; tuning is
  approximate (wrong speaker EQ curves) but DSP processing engages. Cheap to
  test: push to `/vendor/etc/acdbdata/pepito/` live + reboot, watch for nonzero
  topology id.
- **Option B:** newer Palm ACDB dump — does not exist (PVG100 never got >8.1).
- **Option C:** run stock A8 `acdb_loader` blob — ABI risk against 4.19 cal ioctls;
  last resort.
- **Verification lever (two-device):** play audio on `android11-adb` and capture
  its dmesg — stock should show a nonzero AFE topology id, confirming the
  mismatch theory before investing in Option A tuning cleanup.

**Realistic end state:** pepito-specific *tuning* (Palm's) in a *modern* container
likely requires QACT (Qualcomm's ACDB editor) to transplant Palm's cal values into
a sibling's file — nice-to-have, not bring-up. Sibling calibration is the
practical long-term answer; keep Palm's originals in-tree for reference.

---

## Reference

- **Codec stack:** internal MSM8952/cajon analog+digital codec
  (`techpack/audio/asoc/codecs/sdm660_cdc/` + `msm_digital_cdc`) — **NOT WCD9335**
  (stock's `sound-9335` node is `status = "disabled"`; the old version of this
  file was wrong).
- **Machine driver:** `techpack/audio-legacy/asoc/msm8952.c` (`techpack/audio/`
  is stubbed out on msm8937 — see Issue 1 step 2); card model
  `msm8952-snd-card-mtp` set by `xiaomi-msm8937/pepito/audio.dtsi:91`.
- **In-tree audio assets:** `device/xiaomi/Mi8937/audio/{acdbdata/pepito,
  mixer_paths/mixer_paths.xml, platform_info/audio_platform_info.xml}`.
- **Stock device:** `android11-adb` — real Palm ACDB (`MTP/`,`QRD/`), no jack
  input device, `sound{}` node without MBHC props.

## Debugging

```bash
adb shell cat /proc/asound/cards
adb shell 'getevent -p /dev/input/event5'          # jack switch state (should not exist after fix)
adb shell 'dmesg | grep -iE "afe|cal_block|topology"'   # cal engagement
adb shell 'logcat -d | grep -iE "audio_hw|msm8974_platform"'
adb shell getprop persist.vendor.audio.calfile0
```
