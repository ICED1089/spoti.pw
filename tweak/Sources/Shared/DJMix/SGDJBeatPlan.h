// Independent DJ Mix laboratory: pure, portable analysis / planning / offline PCM mixing.
// No Spotify decoder, subscription state, hooks, CoreML, or third-party DSP dependencies.
// The planner NEVER authorizes an overlapping transition without two independently ready streams.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    double bpm;                 // beats per minute; 0 if unknown
    double confidence;          // measured onset-grid quality 0..1
    double downbeatSeconds;     // time of a beat, in the supplied analysis window
    unsigned beatsPerBar;       // 4 by default
} SGDJBeatGrid;

typedef enum {
    SGDJPlanReady = 0,
    SGDJPlanUnsupported,        // only one decoded audio stream or remote route
    SGDJPlanUnknownBeat,
    SGDJPlanPlaybackChanged,
    SGDJPlanInsufficientA,
    SGDJPlanInsufficientB,
    SGDJPlanNoFuturePhrase,
    SGDJPlanTempoMismatch
} SGDJPlanStatus;

typedef struct {
    double durationA, positionA;
    double bufferedA;           // genuinely ready decoded seconds, not downloaded bytes
    double bufferedB;           // independently ready incoming decoded seconds
    bool independentStreams;    // must be verified before enabling actual DSP
    bool localPlayback;
    bool pitchPreservingStretch;
    bool seeksOrRouteChanging;
} SGDJBeatReadiness;

typedef struct {
    SGDJPlanStatus status;
    bool ready;
    bool beatMatched;
    double startA;              // outgoing track timeline seconds
    double cueB;                // incoming track timeline seconds
    double overlap;             // seconds in output domain
    double speedB;              // rate necessary for B to match A; only with stretch
    double beatDrift;           // beat drift without time stretching
} SGDJBeatPlan;

// Analyze onset envelope at 'envelopeHz' samples/sec; call off audio render thread.
// This is a lightweight estimator, not a learned beat/downbeat model. Confidence is
// deliberately conservative; it does not prove the correct bar/downbeat phase.
SGDJBeatGrid SGDJBeatDetect(const float *envelope, size_t count, double envelopeHz);

// True only when ready PCM from both independent sources satisfies the transition plan.
SGDJBeatPlan SGDJBeatPlanBuild(SGDJBeatGrid a, SGDJBeatGrid b, SGDJBeatReadiness input);

// Offline equal-power overlap from TWO independently supplied, interleaved stereo buffers.
// Input arrays must hold 'frames*2' floats, output separate or aliasing A; call only after
// SGDJBeatPlanBuild.ready and do not use this to force Spotify to decode future audio.
// The 'offset' allows sample-continuous, chunked mixing with a shared total duration.
void SGDJBeatMixStereo(const float *a, const float *b, float *dst,
                      size_t frames, uint64_t offset, uint64_t total);
