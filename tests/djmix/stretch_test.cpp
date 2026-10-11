// Offline host validation of the ACTUAL MIT Signalsmith pitch-preserving time
// stretcher, not a mock interpolation. Compiled in Dev checks on macOS.
#include "../../tweak/Sources/Shared/DJMix/SGDJStretch.h"
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <vector>

static void check(bool ok, const char *reason) {
    if (!ok) { std::fprintf(stderr, "DJ stretch FAILED: %s\n", reason); std::exit(1); }
}
int main() {
    const double rate = 44100;
    const size_t framesIn = (size_t)(rate * 3.0);
    const size_t framesOut = (size_t)(framesIn / 1.04);
    std::vector<float> a(framesIn * 2), b(framesOut * 2);
    for (size_t i = 0; i < framesIn; ++i) {
        float sine = .4f * std::sin(2*M_PI*440*i/rate);
        a[2*i] = sine; a[2*i+1] = -sine;
    }
    check(!SGDJStretchIncoming(a.data(), framesIn, a.data(), framesOut, rate),
          "output must not alias input");
    check(SGDJStretchIncoming(a.data(), framesIn, b.data(), framesOut, rate),
          "44100Hz 1.04x separate stereo sources should stretch");
    const size_t start = (size_t)rate, length = (size_t)rate;
    double sum = 0;
    unsigned rising = 0;
    for (size_t i = start + 1; i < start + length && i < framesOut; ++i) {
        float x = b[2*i], previous = b[2*(i-1)];
        check(std::isfinite(x) && std::fabs(x) <= 1, "finite bounded mono channel");
        check(std::fabs(x + b[2*i+1]) < .05f, "stereo phase relation");
        sum += x * x;
        if (previous <= 0 && x > 0) ++rising;
    }
    double rms = std::sqrt(sum / length);
    check(rms > 0.05, "must produce non-silent music");
    check(rising >= 425 && rising <= 455,
          "440 Hz test note pitch must remain in tune while tempo changes");
    check(!SGDJStretchIncoming(a.data(), framesIn, b.data(), framesOut/2, rate),
          "refuse ratios beyond small safe beat-match range");
    std::printf("MIT Signalsmith incoming stereo 1.04x stretch: RMS %.3f, pitch %.0f Hz PASS\n",
                rms, (double)rising);
}
