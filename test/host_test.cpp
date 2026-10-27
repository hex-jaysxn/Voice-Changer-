// Host tests for the VoiceFX v6 engine. Build: g++ -std=c++17 -O2 -ffast-math -fno-finite-math-only -I <rubberband or fake> host_test.cpp
// With the fake RubberBand stand-in (pure delay) the plumbing is checked sample-exact; effects are checked numerically.
#define VFX_HOST_TEST 1
#include "../jni/voicefx_dsp.h"
#include <vector>
#include <cstdio>
#include <thread>
#include <chrono>
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


// ---- helpers for the Auto-Tune / chord tests
struct Note { double midi; double dur; };
static std::vector<int16_t> sing(const std::vector<Note>& notes, double amp = 0.22) {
    int total = 0; for (auto& n : notes) total += (int)(n.dur * 48000); std::vector<int16_t> v(total); double ph = 0; int i = 0;
    for (auto& n : notes) { int len = (int)(n.dur * 48000); double f = 440.0 * pow(2.0, (n.midi - 69.0) / 12.0);
        for (int k = 0; k < len; k++, i++) { double s = 0, ps = 0; for (int h = 1; h * f < 6000; h++) { double fh = h * f; double a = (1.0 / h) * (1.0 + 1.5 * exp(-pow((fh - 700) / 250, 2)) + 1.0 * exp(-pow((fh - 1200) / 300, 2))); s += a * sin(h * ph); ps += a; }
            double env = std::min(1.0, k / 400.0) * std::min(1.0, (len - k) / 400.0); v[i] = (int16_t)(amp * 32768.0 * env * s / 2.6); ph += 2 * M_PI * f / 48000.0; } }
    return v; }
static double measureMidi(const std::vector<int16_t>& x, int start, int len) {      // normalised autocorrelation, parabolic peak
    int lagMin = 48000 / 1000, lagMax = 48000 / 70; std::vector<double> r(lagMax + 2, 0.0); double e0 = 0; for (int i = 0; i < len; i++) e0 += (double)x[start + i] * x[start + i];
    if (e0 < 1e3) return -1;
    for (int lag = lagMin; lag <= lagMax + 1; lag++) { double c = 0, e1 = 0; for (int i = 0; i < len - lagMax - 2; i++) { c += (double)x[start + i] * x[start + i + lag]; e1 += (double)x[start + i + lag] * x[start + i + lag]; } r[lag] = c / sqrt(e0 * e1 + 1e-9); }
    int bl = lagMin; double bv = -2; for (int lag = lagMin + 1; lag <= lagMax; lag++) if (r[lag] > bv && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1]) { bv = r[lag]; bl = lag; }
    for (int lag = lagMin + 1; lag <= lagMax; lag++) if (r[lag] > 0.9 * bv && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1]) { bl = lag; break; }     // first strong peak (avoid sub-octaves)
    double a = r[bl - 1], b = r[bl], c2 = r[bl + 1], den = a - 2 * b + c2, sh = fabs(den) > 1e-12 ? 0.5 * (a - c2) / den : 0; double lag = bl + sh;
    return 69.0 + 12.0 * log2((48000.0 / lag) / 440.0); }
static double goertzelDb(const std::vector<int16_t>& x, int start, int len, double f) {
    double re = 0, im = 0; for (int i = 0; i < len; i++) { double w = 0.5 - 0.5 * cos(2 * M_PI * i / len), a = 2 * M_PI * f * (start + i) / 48000.0; re += w * x[start + i] * cos(a); im += w * x[start + i] * sin(a); }
    return 10 * log10((re * re + im * im) / ((double)len * len) + 1e-3); }
static double mf(double midi) { return 440.0 * pow(2.0, (midi - 69.0) / 12.0); }
static void tuneSetup(int key, int scale, double timeMs, double amt, int chord) { reset_all(); vfx_set(P_QUALITY, 2.f); vfx_set(P_TUNE_ON, 1.f); vfx_set(P_TUNE_KEY, (float)key); vfx_set(P_TUNE_SCALE, (float)scale);
    vfx_set(P_TUNE_TIME, (float)timeMs); vfx_set(P_TUNE_AMT, (float)amt); vfx_set(P_CHORD, (float)chord); }

int main()
{
    printf("[1] Normal preset (enabled, no pitch shift): zero latency, bit exact, any chunk size\n");
    for (unsigned sd : { 0u, 4242u }) { reset_all(); auto in = voiceish(96000), out = in; run(out, 960, sd);
        int bad = 0; for (size_t i = 0; i < in.size(); i++) if (abs(out[i] - in[i]) > 1) bad++;
        CHECK(bad == 0, "%s chunks: %d mismatching samples", sd ? "random" : "960", bad); }

#ifndef VFX_NO_RUBBERBAND
    printf("[2] pitch path alignment (fake RubberBand = pure delay 2048): mix 1 and mix 0.5, constant and random chunks\n");
    for (float mix : { 1.f, 0.5f }) for (unsigned sd : { 0u, 777u }) { reset_all(); vfx_set(P_PITCH, 2.f); vfx_set(P_MIX, mix);
        auto in = voiceish(144000), out = in; run(out, 960, sd);
        int bad = 0; for (int i = 30000; i < (int)in.size(); i++) if (abs(out[i] - in[i - 2048]) > 3) bad++;
        CHECK(bad == 0, "mix %.1f %s chunks: %d mismatches (old v5 engine: ~114000 for mix 0.5)", mix, sd ? "random" : "960", bad); }

#endif
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

#ifndef VFX_NO_RUBBERBAND
    printf("[10] auto fallback to lite when the CPU is overloaded\n");
    { reset_all(); vfx_set(P_PITCH, 1.5f); auto in = tone(48000, 300, 9000), o = in; run(o, 960); CHECK(vfx_stat(13) == 0 && vfx_stat(12) == 1, "idle host: RubberBand engine, auto-lite %d", vfx_stat(13)); }

#endif
    printf("[11] robustness: random parameters + random chunks for 20 s of audio, no NaN/overflow/crash\n");
    { reset_all(); unsigned s = 99; auto v = voiceish(48000 * 20); int bad = 0; size_t p = 0;
      while (p < v.size()) { s = s * 1664525u + 1013904223u; int id = 1 + (s >> 8) % (P_COUNT - 1); if (id == P_MONITOR) id = P_PITCH; s = s * 1664525u + 1013904223u;
        float lo = kPar[id].lo, hi = kPar[id].hi; vfx_set(id, lo + (hi - lo) * ((s >> 8) % 1000) / 1000.f); if (id == P_ENABLED) vfx_set(P_ENABLED, 1.f);
        s = s * 1664525u + 1013904223u; int n = 50 + (s >> 16) % 4000; if (p + n > v.size()) n = (int)(v.size() - p); vfx_process_i16(v.data() + p, n); p += n; }
      for (auto x : v) if (x == -32768) bad++; CHECK(bad < 50, "samples hitting the rail: %d", bad); }


    printf("[12] noise suppression\n");
    {
        auto fan = [](int total, double rmsTarget, unsigned seed) { std::vector<double> v(total); double lp = 0, lp2 = 0; unsigned r = seed;
            for (int i = 0; i < total; i++) { r = r * 1664525u + 1013904223u; double w = ((int)(r >> 8) - 8388608) / 8388608.0; lp += (w - lp) * 0.08; lp2 += (lp - lp2) * 0.3; v[i] = lp2 + 0.3 * w; }
            double e = 0; for (double x : v) e += x * x; double g = rmsTarget / sqrt(e / total); for (auto& x : v) x *= g; return v; };
        auto speech = [](int total) { std::vector<double> v(total, 0.0); for (int i = 0; i < total; i++) { double t = i / 48000.0; double ph = fmod(t, 1.0);
            double env = (ph > 0.25 && ph < 0.85) ? 0.5 + 0.5 * sin(2 * M_PI * 4 * t) : 0.0; env *= 0.5 * (1 + sin(2 * M_PI * 1.7 * t));
            double f0 = 140 + 20 * sin(2 * M_PI * 0.7 * t), s = 0; for (int h = 1; h <= 14; h++) s += sin(2 * M_PI * f0 * h * t + h) / h; v[i] = 0.12 * env * s; } return v; };
        auto toI16 = [](const std::vector<double>& a) { std::vector<int16_t> o(a.size()); for (size_t i = 0; i < a.size(); i++) o[i] = (int16_t)std::max(-32767.0, std::min(32767.0, a[i] * 32768.0)); return o; };
        const int T = 48000 * 8;
        // (a) fan only, three strengths
        for (float amt : { 0.3f, 0.6f, 1.0f }) { reset_all(); vfx_set(P_NS_ON, 1.f); vfx_set(P_NS_AMT, amt); auto in = toI16(fan(T, 0.012, 5)), out = in; run(out, 960);
            double red = db(rms(in, 48000 * 4, T)) - db(rms(out, 48000 * 4, T));
            CHECK(red > (amt < 0.5f ? 8 : (amt < 0.9f ? 12 : 18)), "fan noise only, strength %.1f: reduced by %.1f dB (floor est %.1f dBFS)", amt, red, vfx_statf(5)); }
        // (b) clean speech must survive
        { reset_all(); vfx_set(P_NS_ON, 1.f); vfx_set(P_NS_AMT, 0.6f); auto in = toI16(speech(T)), out = in; run(out, 960);
          double lv = db(rms(out, 48000 * 2, T)) - db(rms(in, 48000 * 2 - 512, T - 512)); double c = 0, a = 0, b2 = 0;
          for (int i = 48000 * 2; i < T; i++) { c += (double)out[i] * in[i - 512]; a += (double)out[i] * out[i]; b2 += (double)in[i - 512] * in[i - 512]; }
          CHECK(fabs(lv) < 1.5 && c / sqrt(a * b2) > 0.95, "clean speech: level %+.2f dB, correlation with input delayed 512 samples %.3f", lv, c / sqrt(a * b2)); }
        // (c) speech over fan: gaps get quiet, speech keeps its level, SNR improves
        { reset_all(); vfx_set(P_NS_ON, 1.f); vfx_set(P_NS_AMT, 0.7f); auto sp = speech(T), fn = fan(T, 0.012, 9); std::vector<double> mixd(T); for (int i = 0; i < T; i++) mixd[i] = sp[i] + fn[i];
          auto in = toI16(mixd), out = in; run(out, 960);
          // gaps: t mod 1 in [0.9,1.0) ; speech: [0.4,0.8)
          double gi = 0, go = 0, si = 0, so = 0; int gn = 0, sn = 0;
          for (int i = 48000 * 3; i < T; i++) { double ph = fmod(i / 48000.0, 1.0); double xi = in[i] / 32768.0, xo = out[i + 0] / 32768.0;
              if (ph > 0.9) { gi += xi * xi; go += xo * xo; gn++; } else if (ph > 0.45 && ph < 0.75) { si += xi * xi; so += xo * xo; sn++; } }
          double gap = 10 * log10(gi / go), sl = 10 * log10(so / si);
          CHECK(gap > 10 && sl > -4, "speech over fan: noise between words -%.1f dB, speech level %+.1f dB", gap, sl); }
        // (d) keyboard clicks over a quiet room
        { std::vector<double> sig = fan(T, 0.004, 3); for (int c = 0; c < 18; c++) { int at = 48000 + c * 19000; unsigned r = 77 + c; for (int i = 0; i < 160; i++) { r = r * 1664525u + 1013904223u; double w = ((int)(r >> 8) - 8388608) / 8388608.0; sig[at + i] += 0.25 * w * exp(-i / 40.0); } }
          double pk[2];
          for (int ci = 0; ci < 2; ci++) { reset_all(); vfx_set(P_NS_ON, 1.f); vfx_set(P_NS_AMT, 0.6f); vfx_set(P_NS_CLICK, ci ? 1.f : 0.f); auto in = toI16(sig), out = in; run(out, 960);
              double m = 0; for (int c = 4; c < 18; c++) { int at = 48000 + c * 19000 + 512; int pkc = 0; for (int i = 0; i < 400; i++) pkc = std::max(pkc, (int)abs(out[at + i])); m += pkc; } pk[ci] = m / 14.0; }
          CHECK(pk[1] < pk[0] * 0.6 && pk[1] < 0.25 * 32768 * 0.5, "clicks: avg peak %.0f with click guard 0, %.0f with guard 1 (%.1f dB lower)", pk[0], pk[1], db(pk[0]) - db(pk[1])); }
        // (e) deterministic: chunk size does not change the result
        { reset_all(); vfx_set(P_NS_ON, 1.f); auto in = toI16(speech(96000)), o1 = in, o2 = in; run(o1, 960); reset_all(); vfx_set(P_NS_ON, 1.f); run(o2, 0, 31337); int bad = 0; for (size_t i = 0; i < in.size(); i++) if (o1[i] != o2[i]) bad++;
          CHECK(bad == 0, "960-sample chunks vs random chunks: %d differing samples", bad); }
        // (f) switching it on and off while talking: no click
        { reset_all(); auto in = tone(48000 * 4, 300, 9000), out = in; int p = 0; while (p < (int)in.size()) { if (p == 48000) vfx_set(P_NS_ON, 1.f); if (p == 144000) vfx_set(P_NS_ON, 0.f); vfx_process_i16(out.data() + p, 960); p += 960; }
          int j = maxJump(out, 20000, 190000); CHECK(j < 900, "largest step while toggling noise suppression: %d (natural max 353)", j); }
        // (g) latency of the suppressor path
        { reset_all(); vfx_set(P_NS_ON, 1.f); vfx_set(P_NS_AMT, 0.2f); auto in = toI16(speech(48000 * 3)), out = in; run(out, 960); int best = 0; double bc = -1;
          for (int lag = 400; lag < 700; lag++) { double c = 0; for (int i = 60000; i < 100000; i++) c += (double)out[i] * in[i - lag]; if (c > bc) { bc = c; best = lag; } }
          CHECK(best == 512, "added latency %d samples (%.1f ms)", best, best / 48.0); }
    }

    printf("[13] Auto-Tune: pitch tracker, scale snapping, retune speed (Lite pitch engine, real pitch shifting)\n");
    {
        // (a) tracker accuracy over the singing range, notes off pitch by up to 30 cents
        for (double m : { 45.0, 55.0, 60.3, 69.0, 76.2 }) { tuneSetup(0, 0, 0, 0.0, 0); auto in = sing({ { m, 1.2 } }), out = in; run(out, 960);
            double det = vfx_statf(7); CHECK(fabs(det - m) < 0.15, "tracker: sung midi %.2f -> detected %.2f (%.0f Hz)", m, det, mf(m)); }
        // (b) hard tune in C major: every sung note ends up on a scale note
        struct Case { double sung, want; };
        for (Case c : { Case{ 61.3, 62 }, Case{ 64.4, 64 }, Case{ 65.8, 65 }, Case{ 58.6, 59 }, Case{ 70.0, 69.0 + 0 } }) {
            if (c.sung == 70.0) c.want = 71 - 1 + 0;           // A#4 sits halfway: either neighbour is fine (A or B), checked below
            tuneSetup(0, 1, 0, 1.0, 0); auto in = sing({ { c.sung, 1.4 } }), out = in; run(out, 960); double mo = measureMidi(out, 48000 * 6 / 10, 24000);
            bool ok = c.sung == 70.0 ? (fabs(mo - 69) < 0.25 || fabs(mo - 71) < 0.25) : fabs(mo - c.want) < 0.25;
            CHECK(ok, "C major hard tune: sung %.1f -> output %.2f (want %.0f)", c.sung, mo, c.sung == 70.0 ? 69.0 : c.want); }
        // (c) amount scales the correction, chromatic snap
        { tuneSetup(0, 0, 0, 1.0, 0); auto in = sing({ { 60.35, 1.4 } }), out = in; run(out, 960); double mo = measureMidi(out, 28800, 24000); CHECK(fabs(mo - 60.0) < 0.2, "chromatic, amount 1: 60.35 -> %.2f", mo);
          tuneSetup(0, 0, 0, 0.5, 0); in = sing({ { 60.35, 1.4 } }); out = in; run(out, 960); mo = measureMidi(out, 28800, 24000); CHECK(fabs(mo - 60.175) < 0.2, "chromatic, amount 0.5: 60.35 -> %.2f (halfway)", mo); }
        // (d) retune time: a note sung 0.4 semitone flat of E4 (63.6 -> target 64): instant tune is on the note within 100 ms, 300 ms smoothing glides
        for (double tm : { 0.0, 300.0 }) { tuneSetup(0, 1, tm, 1.0, 0); auto in = sing({ { 62.0, 0.8 }, { 63.6, 1.6 } }), out = in; run(out, 960);
            double at100 = measureMidi(out, 38400 + 4800, 1440), at600 = measureMidi(out, 38400 + 28800, 1440);
            printf("        retune time %3.0f ms: 100 ms after the note starts %.2f, after 600 ms %.2f (target 64.00)\n", tm, at100, at600);
            if (tm == 0) CHECK(fabs(at100 - 64.0) < 0.12, "instant retune: on the note after 100 ms (%.2f)", at100); else CHECK(at100 < 63.9 && at100 > 63.55 && at600 > at100 + 0.1, "300 ms retune glides (%.2f -> %.2f)", at100, at600); }
        // (e) speech-like sound without a pitch (noise) must not be tuned / must not explode
        { tuneSetup(0, 1, 0, 1.0, 1); std::vector<int16_t> nz(48000); unsigned r = 5; for (auto& x : nz) { r = r * 1664525u + 1013904223u; x = (int16_t)(((int)(r >> 16) - 32768) / 8); } auto out = nz; run(out, 960);
          CHECK(db(rms(out, 9600, 48000)) < db(rms(nz, 9600, 48000)) + 4, "noise in: output level %+.1f dB vs input", db(rms(out, 9600, 48000)) - db(rms(nz, 9600, 48000))); }
        { tuneSetup(0, 1, 0, 1.0, 1); std::vector<int16_t> z(48000, 0); run(z, 960); int mx = 0; for (auto v : z) mx = std::max(mx, (int)abs(v)); CHECK(mx < 3, "silence in, Magic Chords on: peak %d", mx); }
        // (f) chunk size independence
        { tuneSetup(2, 1, 40, 0.9, 1); auto in = sing({ { 62.3, 0.8 }, { 66.4, 0.8 }, { 69.2, 0.8 } }), o1 = in, o2 = in; run(o1, 960); tuneSetup(2, 1, 40, 0.9, 1); run(o2, 0, 4711); int bad = 0; for (size_t i = 0; i < in.size(); i++) if (o1[i] != o2[i]) bad++;
          CHECK(bad == 0, "tune + chords: 960-sample vs random chunks: %d differing samples", bad); }
    }
    printf("[14] Magic Chords / chord modes (Lite engine)\n");
    {
        // (a) Magic in A major, sung A3: lead 220 Hz + 3rd C#4 + 5th E4 + bass A2, each as a clean single line at the right frequency
        { tuneSetup(9, 1, 0, 1.0, 1); auto in = sing({ { 57.0, 1.8 } }), out = in; run(out, 960);
          auto peak = [&](double lo, double hi, double& at) { double bm = -999; for (double f = lo; f <= hi; f += 0.5) { double v = goertzelDb(out, 28800, 38400, f); if (v > bm) { bm = v; at = f; } } return bm; };
          double fl, f3, f5, fb; double pl = peak(214, 226, fl), p3 = peak(266, 290, f3), p5 = peak(316, 343, f5), pb = peak(104, 117, fb);
          printf("        lead %.1f Hz %.0f dB | 3rd %.1f Hz (want 277.2) %.0f dB | 5th %.1f Hz (want 329.6) %.0f dB | bass %.1f Hz (want 110.0) %.0f dB\n", fl, pl, f3, p3, f5, p5, fb, pb);
          CHECK(fabs(f3 - mf(61)) < 3.0 && fabs(f5 - mf(64)) < 3.0 && fabs(fb - mf(45)) < 2.0, "voices sit on C#4 / E4 / A2 (errors %.1f, %.1f, %.1f Hz)", f3 - mf(61), f5 - mf(64), fb - mf(45));
          CHECK(p3 > pl - 16 && p5 > pl - 16 && pb > pl - 18, "voices are strong single lines: %.0f / %.0f / %.0f dB below the lead", pl - p3, pl - p5, pl - pb);
          double fo1, fo2, fo3; double q1 = peak(293, 305, fo1), q2 = peak(366, 400, fo2), q3 = peak(240, 252, fo3);
          CHECK(q1 < p3 - 8 && q2 < p3 - 8 && q3 < p3 - 8, "notes outside the chord stay down: D4-ish %.0f, G4-ish %.0f, B3-ish %.0f dB vs 3rd %.0f dB", q1, q2, q3, p3);
          tuneSetup(9, 1, 0, 1.0, 0); auto base = in; run(base, 960); double lv = db(rms(out, 24000, 62400)) - db(rms(base, 24000, 62400)); CHECK(lv > 0.5 && lv < 6.0, "level with chords vs without: %+.1f dB", lv); }
        // (b) diatonic: in D major a sung B3 gets a MINOR third (D4) and a fifth (F#4), not D#4
        { tuneSetup(2, 1, 0, 1.0, 2); auto in = sing({ { 59.0, 1.6 } }), out = in; run(out, 960);
          double d4 = goertzelDb(out, 24000, 38400, mf(62)), ds4 = goertzelDb(out, 24000, 38400, mf(63)), fs4 = goertzelDb(out, 24000, 38400, mf(66));
          CHECK(d4 > ds4 + 12 && fs4 > ds4 + 8, "D major, sing B: D4 %.0f dB, F#4 %.0f dB, D#4 %.0f dB (minor chord)", d4, fs4, ds4); }
        // (c) every mode produces its added voices and stays finite
        const char* names[9] = { "off", "Magic", "Triad", "Power", "Seventh", "Sus", "Angel", "Octaves", "Duet" };
        for (int mode = 1; mode <= 8; mode++) { tuneSetup(0, 1, 20, 1.0, mode); auto in = sing({ { 60.0, 1.4 } }), base = in; run(base, 960); tuneSetup(0, 1, 20, 1.0, 0); base = in; run(base, 960);
            tuneSetup(0, 1, 20, 1.0, mode); auto out = in; run(out, 960); double lv = db(rms(out, 24000, 62400)) - db(rms(base, 24000, 62400)); int mx = 0; for (auto v : out) mx = std::max(mx, (int)abs(v));
            CHECK(lv > 0.3 && lv < 6.5 && mx < 32000, "mode %d %-8s: level %+.1f dB, peak %d", mode, names[mode], lv, mx); }
        // (d) auto key: a D-major melody must be recognised as D
        { tuneSetup(12, 1, 40, 1.0, 0); std::vector<Note> mel; unsigned r = 9; const int deg[12] = { 62, 62, 62, 69, 69, 66, 66, 64, 67, 71, 73, 62 }; for (int i = 0; i < 40; i++) { r = r * 1664525u + 1013904223u; mel.push_back({ (double)deg[(r >> 16) % 12] + ((int)((r >> 8) % 21) - 10) * 0.02, 0.33 }); }      // tonic-heavy D-major tune
          auto in = sing(mel), out = in; run(out, 960); CHECK(vfx_stat(15) == 2, "auto key from a D-major melody: root %d (2 = D)", vfx_stat(15));
          tuneSetup(12, 2, 40, 1.0, 0); mel.clear(); const int amin[12] = { 57, 57, 57, 64, 64, 60, 60, 62, 65, 67, 59, 57 }; for (int i = 0; i < 40; i++) { r = r * 1664525u + 1013904223u; mel.push_back({ (double)amin[(r >> 16) % 12], 0.33 }); }      // tonic-heavy A-minor tune
          in = sing(mel); out = in; run(out, 960); CHECK(vfx_stat(15) == 9, "auto key, minor scale, A-minor melody: root %d (9 = A)", vfx_stat(15)); }
        // (e) cost
        { tuneSetup(0, 1, 20, 1.0, 1); auto in = sing({ { 60.0, 4.0 } }), out = in; auto t0 = std::chrono::steady_clock::now(); run(out, 960); double sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
          CHECK(sec / 4.0 < 0.30, "CPU on this PC: %.1f%% of real time for tune + 3 chord voices", 100 * sec / 4.0); }
    }
    printf("\n%s (%d failed)\n", fails ? "SOME TESTS FAILED" : "ALL TESTS PASSED", fails);
    return fails ? 1 : 0;
}
