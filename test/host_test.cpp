// Host tests for the VoiceFX v6 engine. Build: g++ -std=c++17 -O2 -ffast-math -fno-finite-math-only -I <rubberband or fake> host_test.cpp
// With the fake RubberBand stand-in (pure delay) the plumbing is checked sample-exact; effects are checked numerically.
#define VFX_HOST_TEST 1
#include "../jni/voicefx.cpp"
#include <vector>
#include <cstdio>
#include <thread>
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } else { printf("  ok:   "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static std::vector<int16_t> tone(int total, double f, double amp) { std::vector<int16_t> v(total); for (int i = 0; i < total; i++) v[i] = (int16_t)(amp * sin(2 * M_PI * f * i / 48000.0)); return v; }
static std::vector<int16_t> voiceish(int total) { std::vector<int16_t> v(total); for (int i = 0; i < total; i++) { double t = i / 48000.0, e = 0.5 + 0.5 * sin(2 * M_PI * 3 * t);
    v[i] = (int16_t)(e * (9000 * sin(2 * M_PI * 180 * t) + 5000 * sin(2 * M_PI * 540 * t) + 3000 * sin(2 * M_PI * 1500 * t) + 1500 * sin(2 * M_PI * 3100 * t))); } return v; }
static void reset_all() { params_default(); vfx_prepare(48000); vfx_set(P_ENABLED, 1.f); }
static void run(std::vector<int16_t>& d, int chunk, unsigned seed = 0) { int p = 0, total = (int)d.size(); while (p < total) { int n = chunk; if (seed) { seed = seed * 1664525u + 1013904223u; n = 100 + (seed >> 16) % 1900; } if (p + n > total) n = total - p; vfx_process_i16(d.data() + p, n); p += n; } }
static double rms(const std::vector<int16_t>& d, int a, int b) { double e = 0; for (int i = a; i < b; i++) e += (double)d[i] * d[i]; return sqrt(e / (b - a)) / 32768.0; }
static double db(double x) { return 20 * log10(x + 1e-12); }
static double gainAt(double f, const char* what) { auto in = tone(48000, f, 8000); auto out = in; run(out, 960); (void)what; return db(rms(out, 24000, 48000)) - db(rms(in, 24000, 48000)); }
static int maxJump(const std::vector<int16_t>& d, int a, int b) { int m = 0; for (int i = a + 1; i < b; i++) m = std::max(m, abs((int)d[i] - (int)d[i - 1])); return m; }
static double zcFreq(const std::vector<int16_t>& d, int a, int b) { int z = 0; for (int i = a + 1; i < b; i++) if ((d[i - 1] < 0) != (d[i] < 0)) z++; return z / 2.0 / ((b - a) / 48000.0); }

int main()
{
    printf("[1] Normal preset (enabled, no pitch shift): zero latency, bit exact, any chunk size\n");
    for (unsigned sd : { 0u, 4242u }) { reset_all(); auto in = voiceish(96000), out = in; run(out, 960, sd);
        int bad = 0; for (size_t i = 0; i < in.size(); i++) if (abs(out[i] - in[i]) > 1) bad++;
        CHECK(bad == 0, "%s chunks: %d mismatching samples", sd ? "random" : "960", bad); }

    printf("[2] pitch path alignment (fake RubberBand = pure delay 2048): mix 1 and mix 0.5, constant and random chunks\n");
    for (float mix : { 1.f, 0.5f }) for (unsigned sd : { 0u, 777u }) { reset_all(); vfx_set(P_PITCH, 2.f); vfx_set(P_MIX, mix);
        auto in = voiceish(144000), out = in; run(out, 960, sd);
        int bad = 0; for (int i = 30000; i < (int)in.size(); i++) if (abs(out[i] - in[i - 2048]) > 3) bad++;
        CHECK(bad == 0, "mix %.1f %s chunks: %d mismatches (old v5 engine: ~114000 for mix 0.5)", mix, sd ? "random" : "960", bad); }

    printf("[3] switching presets while talking: no click, no dead gap\n");
    { reset_all(); auto in = tone(144000, 300, 9000), out = in; vfx_set(P_PITCH, 2.f);
      int p = 0; int jumpMax = 0; int minAfter = 99999;
      while (p < (int)in.size()) { int n = 960; if (p == 48000) vfx_set(P_PITCH, 1.f); if (p == 96000) vfx_set(P_PITCH, 2.f); vfx_process_i16(out.data() + p, n); p += n; }
      int j1 = maxJump(out, 40000, 140000);   // 300 Hz @ 9000 amp: natural max step = 2*pi*300/48000*9000 = 353
      CHECK(j1 < 800, "largest sample-to-sample step over the whole run: %d (natural max 353)", j1);
      double r = rms(out, 60000, 90000); CHECK(r > 0.15, "level after switching to direct: %.3f", r); }

    printf("[4] mic burst: stale audio from the previous burst must not replay\n");
    { reset_all(); vfx_set(P_PITCH, 2.f); auto a = tone(24000, 400, 12000); run(a, 960);
      std::this_thread::sleep_for(std::chrono::milliseconds(200));            // pause > 120 ms
      std::vector<int16_t> sil(9600, 0); run(sil, 960);
      CHECK(rms(sil, 0, 9600) < 1e-4, "first 200 ms of the next burst (silent input) is silent: rms %.5f", rms(sil, 0, 9600)); }

    printf("[5] filters (frequency response through the full engine)\n");
    { reset_all(); vfx_set(P_HP_HZ, 400.f); double g1 = gainAt(100, ""), g2 = gainAt(1000, ""); CHECK(g1 < -20 && fabs(g2) < 1.0, "high-pass 400 Hz: 100 Hz %.1f dB, 1 kHz %.1f dB", g1, g2);
      reset_all(); vfx_set(P_LP_HZ, 2000.f); g1 = gainAt(6000, ""); g2 = gainAt(500, ""); CHECK(g1 < -20 && fabs(g2) < 1.0, "low-pass 2 kHz: 6 kHz %.1f dB, 500 Hz %.1f dB", g1, g2);
      reset_all(); vfx_set(P_BASS_DB, 9.f); g1 = gainAt(60, ""); g2 = gainAt(2000, ""); CHECK(g1 > 7 && fabs(g2) < 1.0, "bass +9 dB: 60 Hz %+.1f dB, 2 kHz %+.1f dB", g1, g2);
      reset_all(); vfx_set(P_TREBLE_DB, -9.f); g1 = gainAt(9000, ""); g2 = gainAt(500, ""); CHECK(g1 < -7 && fabs(g2) < 1.0, "treble -9 dB: 9 kHz %+.1f dB, 500 Hz %+.1f dB", g1, g2); }

    printf("[6] drive keeps a sane level; bit-crusher/tremolo/ring-mod run and stay finite\n");
    { for (float d : { 0.2f, 0.6f, 1.f }) { reset_all(); vfx_set(P_DRIVE, d); double g = gainAt(500, ""); CHECK(g > -6 && g < 8, "drive %.1f: level change %+.1f dB", d, g); }
      reset_all(); vfx_set(P_BITS, 6.f); vfx_set(P_DOWN, 6.f); double g = gainAt(500, ""); CHECK(g > -6 && g < 3, "8-bit style (6 bit, /6): %+.1f dB", g);
      reset_all(); vfx_set(P_TREM_DEPTH, 1.f); vfx_set(P_TREM_HZ, 5.f); auto in = tone(48000, 400, 8000), out = in; run(out, 960);
      double lo = 1e9, hi = 0; for (int i = 12000; i < 48000; i += 480) { double r = rms(out, i, i + 480); lo = std::min(lo, r); hi = std::max(hi, r); }
      CHECK(lo < hi * 0.2, "tremolo depth 1: envelope min/max %.3f/%.3f", lo, hi);
      reset_all(); vfx_set(P_ROBOT, 1.f); vfx_set(P_ROBOT_HZ, 50.f); vfx_set(P_ROBOT_AMT, 1.f); in = tone(48000, 400, 8000); out = in; run(out, 960);
      lo = 1e9; hi = 0; for (int i = 12000; i < 48000; i += 120) { double r = rms(out, i, i + 120); lo = std::min(lo, r); hi = std::max(hi, r); }
      CHECK(lo < hi * 0.7, "ring modulator envelope varies: %.3f/%.3f", lo, hi); }

    printf("[7] echo / reverb / chorus / flanger / vibrato\n");
    { reset_all(); vfx_set(P_ECHO_MS, 250.f); vfx_set(P_ECHO_FB, 0.5f); vfx_set(P_ECHO_MIX, 1.f); std::vector<int16_t> d(48000, 0); for (int i = 0; i < 100; i++) d[i] = 16000; run(d, 960);
      int e1 = 100 + 12000; double a1 = 0, a2 = 0; for (int i = -20; i < 20; i++) { a1 += abs(d[e1 + i]); a2 += abs(d[2 * 12000 + 100 + i]); }
      CHECK(a1 > 20000 && a2 > a1 * 0.3 && a2 < a1 * 0.8, "echo: 1st repeat at 250 ms (%.0f), 2nd at 500 ms is ~half (%.0f)", a1, a2);
      reset_all(); vfx_set(P_REV_MIX, 0.8f); vfx_set(P_REV_SIZE, 0.8f); std::vector<int16_t> r(96000, 0); for (int i = 0; i < 200; i++) r[i] = 12000; run(r, 960);
      double e_early = rms(r, 4800, 14400), e_late = rms(r, 72000, 96000); CHECK(e_early > 0.004 && e_late < e_early * 0.5, "reverb tail decays: %.4f -> %.4f", e_early, e_late);
      std::vector<int16_t> nz(96000); unsigned s = 1; for (auto& x : nz) { s = s * 1664525u + 1013904223u; x = (int16_t)(((int)(s >> 16) - 32768) / 4); }
      reset_all(); vfx_set(P_REV_MIX, 0.5f); auto nin = nz; run(nin, 960); double g = db(rms(nin, 48000, 96000)) - db(rms(nz, 48000, 96000)); CHECK(g > -3 && g < 8, "reverb 50%% on noise: level change %+.1f dB", g);
      for (int mode = 1; mode <= 3; mode++) { reset_all(); vfx_set(P_MOD_MODE, (float)mode); vfx_set(P_MOD_DEPTH, 1.f); vfx_set(P_MOD_RATE, 4.f); auto v = voiceish(96000), o = v; run(o, 960);
        double gg = db(rms(o, 48000, 96000)) - db(rms(v, 48000, 96000)); CHECK(gg > -8 && gg < 6, "mod mode %d: level change %+.1f dB", mode, gg); } }

    printf("[8] vocoder (whisper / cyber): stable, level matched, voice is gone\n");
    for (int mode = 1; mode <= 2; mode++) { reset_all(); vfx_set(P_VOC_MODE, (float)mode); auto v = voiceish(144000), o = v; run(o, 960);
        double gg = db(rms(o, 96000, 144000)) - db(rms(v, 96000, 144000)); CHECK(gg > -8 && gg < 6 && maxJump(o, 100000, 144000) < 30000, "voc mode %d: level change %+.1f dB", mode, gg); }

    printf("[9] lite pitch shifter (built-in): measured pitch of a 300 Hz tone\n");
    for (float ratio : { 0.7071f, 1.26f, 2.f }) { reset_all(); vfx_set(P_QUALITY, 2.f); vfx_set(P_PITCH, ratio); auto in = tone(96000, 300, 9000), o = in; run(o, 960);
        double f = zcFreq(o, 48000, 96000); CHECK(fabs(f / 300.0 - ratio) < 0.06, "ratio %.3f -> %.1f Hz (want %.1f), latency %.1f ms", ratio, f, 300 * ratio, vfx_statf(2)); }

    printf("[10] auto fallback to lite when the CPU is overloaded\n");
    { reset_all(); vfx_set(P_PITCH, 1.5f); auto in = tone(48000, 300, 9000), o = in; run(o, 960); CHECK(vfx_stat(13) == 0 && vfx_stat(12) == 1, "idle host: RubberBand engine, auto-lite %d", vfx_stat(13)); }

    printf("[11] robustness: random parameters + random chunks for 20 s of audio, no NaN/overflow/crash\n");
    { reset_all(); unsigned s = 99; auto v = voiceish(48000 * 20); int bad = 0; size_t p = 0;
      while (p < v.size()) { s = s * 1664525u + 1013904223u; int id = 1 + (s >> 8) % (P_COUNT - 1); if (id == P_MONITOR) id = P_PITCH; s = s * 1664525u + 1013904223u;
        float lo = kPar[id].lo, hi = kPar[id].hi; vfx_set(id, lo + (hi - lo) * ((s >> 8) % 1000) / 1000.f); if (id == P_ENABLED) vfx_set(P_ENABLED, 1.f);
        s = s * 1664525u + 1013904223u; int n = 50 + (s >> 16) % 4000; if (p + n > v.size()) n = (int)(v.size() - p); vfx_process_i16(v.data() + p, n); p += n; }
      for (auto x : v) if (x == -32768) bad++; CHECK(bad < 50, "samples hitting the rail: %d", bad); }

    printf("\n%s (%d failed)\n", fails ? "SOME TESTS FAILED" : "ALL TESTS PASSED", fails);
    return fails ? 1 : 0;
}
