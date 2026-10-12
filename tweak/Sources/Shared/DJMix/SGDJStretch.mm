// MIT Signalsmith Stretch bridge. Runs only on a control/worker queue BEFORE
// a live two-deck render callback, never in the audio render deadline.
#include "SGDJStretch.h"
#include "signalsmith-stretch.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <new>
#include <cstdint>

bool SGDJStretchIncoming(const float *inStereo, size_t inFrames,
                         float *outStereo, size_t outFrames, double sampleRate) {
    if (!inStereo || !outStereo || inStereo == outStereo ||
        !std::isfinite(sampleRate) || sampleRate < 32000 || sampleRate > 96000 ||
        !inFrames || !outFrames || inFrames > (size_t)(sampleRate * 12) ||
        outFrames > (size_t)(sampleRate * 12)) return false;
    const double playbackRatio = (double)inFrames / (double)outFrames;
    if (playbackRatio < 0.94 || playbackRatio > 1.06) return false;

    // All allocation is off-render; the decoder and the high-priority mixer
    // only handle already-ready frames. 12-second cap prevents unbounded
    // memory growth on unexpected durations or malformed metadata.
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    stretch.presetDefault(2, (float)sampleRate);
    const size_t delay = (size_t)std::max(0, stretch.outputLatency());
    if (delay > (size_t)sampleRate * 2 || outFrames > SIZE_MAX - delay) return false;
    const size_t available = outFrames + delay;
    std::unique_ptr<float[]> a(new (std::nothrow) float[inFrames]);
    std::unique_ptr<float[]> b(new (std::nothrow) float[inFrames]);
    std::unique_ptr<float[]> x(new (std::nothrow) float[available]());
    std::unique_ptr<float[]> y(new (std::nothrow) float[available]());
    if (!a || !b || !x || !y) return false;
    for (size_t i = 0; i < inFrames; ++i) {
        const float l = inStereo[2*i], r = inStereo[2*i+1];
        if (!std::isfinite(l) || !std::isfinite(r)) return false;
        a[i] = l; b[i] = r;
    }

    float *input[2] = {a.get(), b.get()};
    float *output[2] = {x.get(), y.get()};
    const int seed = (int)std::min(inFrames, (size_t)std::max(0, stretch.inputLatency()));
    if (seed > 0) stretch.seek(input, seed, (float)playbackRatio);
    // The library handles pitch preservation; unlike the old V2 deck's
    // linear interpolation, this does not simply change sample frequency.
    stretch.process(input, (int)inFrames, output, (int)available);
    for (size_t i = 0; i < outFrames; i++) {
        const float l = x[delay + i], r = y[delay + i];
        if (!std::isfinite(l) || !std::isfinite(r)) return false;
        outStereo[2*i] = std::max(-1.0f, std::min(1.0f, l));
        outStereo[2*i+1] = std::max(-1.0f, std::min(1.0f, r));
    }
    return true;
}
