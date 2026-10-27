# VoiceFX v8 - GitHub build (Auto-Tune styles + Magic Chords)

Your AML base project + VoiceFX v8 (library API 8, menu 8.0). Output: `libvoicefx.so` (armeabi-v7a).

## Build on GitHub (no phone compiler needed)
1. Create a repo and upload **everything in this zip** (keep the folders: `jni/`, `.github/`, `test/`, `menu/`, `project.properties`).
2. Open the **Actions** tab -> `build-libvoicefx` runs by itself on every push (or press *Run workflow*).
3. Open the finished run -> **Artifacts** -> `libvoicefx` -> download -> `libvoicefx.so`.
   The workflow first runs the engine tests (`test` job), then downloads RubberBand 4.0.0 itself and builds.
4. Put `libvoicefx.so` in Nezuko's mods folder (replace the old one), copy `menu/` (Lua, icons, fonts, lib) into MoonLoader, `/vfx`. Status page must say **libvoicefx v8**. Run `/vfx icons` once so the 10 new icons load.

## Notes
* If you ever build without RubberBand (e.g. an offline phone compiler), `Android.mk` notices and builds with the built-in **Lite** pitch shifter only (pitch works; formant control and the High engine do not). The Status page shows which one you have.
* `jni/main.cpp` = AML glue (hook, hear-myself stream); `jni/voicefx_dsp.h` = the audio engine; `jni/mod/` = your AML headers, untouched.
* Hook failed? Send `/storage/emulated/0/voicefx_log.txt`.

## Not checked
No real ndk-build or device run here: `main.cpp` was parsed against your AML headers with stand-in JNI headers, and the engine passes `test/host_test.cpp` both with a RubberBand stand-in and in Lite-only mode.

## v8: Auto-Tune styles and Magic Chords
Effects > **Tune** (on/off, key, scale, retune time, amount, live "singing > tuned" note readout) and Effects > **Chords** (9 chord styles, voice level, choir width). Ten ready-made voices in the new **Tune** chip: Auto-Tune, Hard Tune, Magic Chords, Choir, Angel, Power Chords, Dark Chords, Duet, Octaver, Dreamy. Quick **Noise** / **Tune** buttons on the voice panel. Commands: `/vfx tune on|off|key <C..B|auto>|scale <0-7>`, `/vfx chord <0-8|name>`, `/vfx set tunetime 0`.

* **How it was modelled:** I analysed your Magic Chords demo (D major; chords G - D - A - Bm, i.e. diatonic triads built on the sung note, a bass-octave voice underneath, notes snapped hard onto pitch, long reverb). Magic Chords here = hard-snapped lead + scale-aware 3rd + 5th + bass root + light reverb/treble sparkle. It is my recreation from the audio, not Voicemod's code, so it will not sound identical.
* **Tune:** pitch tracker (YIN, 10 ms hop, accurate to about 2 cents in the tests), 8 scales, key picked by you or found automatically (major + minor profiles). Retune time 0 = instant "robotic" hard tune; 40-100 ms = natural; amount scales the correction. The correction drives the lead pitch shifter (RubberBand, or Lite).
* **Chords:** up to 3 extra voices, each a pitch-adaptive shifter that follows the snapped note and moves along the scale, so the chord quality stays in key (sing B in D major -> B minor). Styles: Magic (3rd + 5th + bass), Triad, Power (5th + octave), Seventh, Sus, Angel (an octave up, airy), Octaves, Duet (3rd above). Slow detune per voice gives a choir width.
* **Limits:** it needs a clear single voice (no tuning of speech over noise; turn Noise on). A new note is corrected after about 40-60 ms (the time the tracker needs). Chord voices have no formant control, so high voices sound brighter/thinner and the bass voice darker. Mono only. Very fast melismas or growls can confuse the pitch tracker for a moment.
