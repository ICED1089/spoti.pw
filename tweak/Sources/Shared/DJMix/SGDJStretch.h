// Native bridge to MIT-licensed Signalsmith Stretch, when SG_DJ_STRETCH=1.
// Off-render only: do not allocate or perform FFT/time-stretch DSP inside an
// AudioUnit render callback. Incoming PCM must come from an authorized,
// independent decoded B stream. This does not fetch Spotify audio.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// Converts input to the exact requested frame count while approximately
// preserving pitch. Input/output are separate interleaved stereo float arrays.
// Intended for small 0.94..1.06x beat-match ratios, processed before
// SGDJTwoDeckFeedB. Returns false on unsupported frame counts or allocations.
bool SGDJStretchIncoming(const float *inStereo, size_t inFrames,
                         float *outStereo, size_t outFrames, double sampleRate);
#ifdef __cplusplus
}
#endif
