# VoiceFX v6 / menu v7 for SA-MP Nezuko (com.nezukosamp.game 1.0.3)

## What changed
### Stutter / dropout fixes (libvoicefx v6)
Found by running the v5 engine on a PC with a stand-in shifter (test/host_test.cpp) - these are real bugs:
| v5 | v6 |
|---|---|
| Dry/wet delay was a ring buffer whose delay depended on the recorder chunk size: with **Mix < 1** the dry copy was misaligned (comb/echo), and "Normal" (no pitch shift) got a random extra latency that jumped (audio skip) whenever a bigger chunk arrived | One fixed-length delay line, sample-exact alignment (verified with random chunk sizes); Normal / no-pitch presets use the zero-latency direct path |
| Switching preset / pitch on-off cut the audio (dead gap + click) | 10 ms cross-fade between direct and pitch path |
| Audio left in the queues replayed at the start of the next mic burst | Pipeline is flushed when the recorder was idle > 120 ms |
| "Hear myself" stream started playing empty and stalled between chunks (this is what a self-test sounds like) | Starts only after 80 ms are queued |
| No protection if RubberBand cannot keep up on a phone | CPU meter; **Auto** pitch engine falls back to a light built-in shifter (Lite) when load > 75 %; build now uses NEON + release flags |
| Denormals in feedback paths can spike the CPU | Flushed in every recursive filter |

Not reproducible without a device: if the stutter you heard comes from RubberBand itself being too slow, the Status page now shows it (CPU load, slow calls, underruns, gap resets) and Auto/Lite is the fix.

### New effects (native, ids 11..31) and 23 new voices
High/low-pass (24 dB/oct), bass/treble, drive, bit-crusher + sample-rate reducer, tremolo, chorus / flanger / vibrato, echo, reverb, robot amount, whisper / cyber vocoder, pitch engine choice.
Voices: Telephone, Radio, Megaphone, Walkie, Muffled, Underwater, Studio, Host (Filter) - Echo, Cave, Stadium, Chorus, Jet (Space) - Drunk, Overlord, Cyborg, Arcade, Rocker, Whisper, Vocoder, Ghost (FX) - Old Man, Villain (Deep).
Menu: voice grid scrolls (drag), chips All/High/Deep/FX/Filter/Space, Effects page has Voice / Tone / Modulate / Crunch / Space / Robot tabs, `/vfx set <name> <value>`, `/vfx quality auto|high|lite`.

## Build (GitHub Actions, unchanged workflow)
Push this folder -> Actions -> `build-libvoicefx` -> artifact `libvoicefx` (`libvoicefx.so`, armeabi-v7a). RubberBand 4.0.0 is downloaded by the workflow.

## Install
1. Replace `Android/data/com.nezukosamp.game/mods/libvoicefx.so` with the new build.
2. Copy `lua/VoiceFX_Menu.lua` over the old one, and `lua/HEXED/Icons/VoiceFX/*.png` (23 new icons) into `<moonloader>/HEXED/Icons/VoiceFX/`.
3. `/vfx` opens the menu. The menu works with the old library too, but the new effects need v6 (Status page shows "libvoicefx v6").

## Tests (run on a PC, no device needed)
`g++ -std=c++17 -O2 -ffast-math -fno-finite-math-only -I test/fake test/host_test.cpp -o ht && ./ht` - with the fake shifter (pure delay) 20+ checks on alignment, switching, bursts, filters, drive level, echo/reverb, vocoder, lite pitch accuracy, 20 s of random parameters.

## Not verified
* Nothing was run on a device; RubberBand itself was not compiled here (no network), only the surrounding engine with a stand-in.
* The menu script could not be executed (no Lua interpreter available): structure was checked, the game APIs were not.
* Formant / Preserve behaviour is still whatever RubberBand's live shifter does (unchanged from v5). Lite mode ignores formant.
* Voice servers may reject voice changers; follow server rules. RubberBand is GPL-2.0-or-later.
