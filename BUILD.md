# VoiceFX v7 - GitHub build

Your AML base project + VoiceFX v7. Output: `libvoicefx.so` (armeabi-v7a).

## Build on GitHub (no phone compiler needed)
1. Create a repo and upload **everything in this zip** (keep the folders: `jni/`, `.github/`, `test/`, `menu/`, `project.properties`).
2. Open the **Actions** tab -> `build-libvoicefx` runs by itself on every push (or press *Run workflow*).
3. Open the finished run -> **Artifacts** -> `libvoicefx` -> download -> `libvoicefx.so`.
   The workflow first runs the engine tests (`test` job), then downloads RubberBand 4.0.0 itself and builds.
4. Put `libvoicefx.so` in Nezuko's mods folder (replace the old one), copy `menu/` (Lua, icons, fonts, lib) into MoonLoader, `/vfx`. Status page must say **libvoicefx v7**.

## Notes
* If you ever build without RubberBand (e.g. an offline phone compiler), `Android.mk` notices and builds with the built-in **Lite** pitch shifter only (pitch works; formant control and the High engine do not). The Status page shows which one you have.
* `jni/main.cpp` = AML glue (hook, hear-myself stream); `jni/voicefx_dsp.h` = the audio engine; `jni/mod/` = your AML headers, untouched.
* Hook failed? Send `/storage/emulated/0/voicefx_log.txt`.

## Not checked
No real ndk-build or device run here: `main.cpp` was parsed against your AML headers with stand-in JNI headers, and the engine passes `test/host_test.cpp` both with a RubberBand stand-in and in Lite-only mode.
