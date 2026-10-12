#include "SGDJBeatPlan.h"
#include <math.h>
#include <stdlib.h>

static double clampd(double v, double lo, double hi) {
    return v < lo ? lo : v > hi ? hi : v;
}
static double positive(double x) { return x > 0 && isfinite(x) ? x : 0; }

SGDJBeatGrid SGDJBeatDetect(const float *envelope, size_t count, double hz) {
    SGDJBeatGrid result = {0, 0, 0, 4};
    // 18 seconds gives several rhythmic phrases even at slow tempos.
    if (!envelope || count < (size_t)(18 * hz) || hz < 20 || hz > 400 ||
        count > (size_t)(180 * hz)) return result;
    const size_t first = 1;
    int lowLag = (int)ceil(hz * 60.0 / 188.0);
    int highLag = (int)floor(hz * 60.0 / 65.0);
    if (lowLag < 2) lowLag = 2;
    if (highLag > (int)count / 3) highLag = (int)count / 3;
    if (highLag <= lowLag) return result;

    // Use positive spectral/loudness novelty, not amplitude autocorrelation:
    // a sustained loud chorus is not itself evidence of a beat.
    double *onsets = calloc(count, sizeof *onsets);
    if (!onsets) return result;
    double sumSq = 0;
    for (size_t i = first; i < count; ++i) {
        double previous = positive(envelope[i - 1]);
        double current = positive(envelope[i]);
        double change = current - previous;
        onsets[i] = change > 0 ? change : 0;
        sumSq += onsets[i] * onsets[i];
    }
    if (sumSq < 1e-12) { free(onsets); return result; }

    double bestScore = 0, runner = 0;
    int bestLag = 0;
    for (int lag = lowLag; lag <= highLag; ++lag) {
        double corr = 0, normA = 0, normB = 0;
        for (size_t i = (size_t)lag; i < count; ++i) {
            const double x = onsets[i], y = onsets[i - (size_t)lag];
            corr += x * y; normA += x*x; normB += y*y;
        }
        double score = corr / (sqrt(normA * normB) + 1e-12);
        // Very close harmonic candidates: mildly prefer tempi near 120 BPM.
        score *= 1.0 - 0.025 * fmin(1.0, fabs(log((hz * 60.0 / lag) / 120.0)));
        if (score > bestScore) {
            runner = bestScore; bestScore = score; bestLag = lag;
        } else if (score > runner) runner = score;
    }
    if (bestLag == 0 || bestScore < 0.19) { free(onsets); return result; }

    // Estimate the beat phase via onset accumulation modulo the chosen lag.
    // The correct musical DOWNBEAT requires a separate section/downbeat model:
    // this phase is a beat-position hypothesis, not a verified bar-1 label.
    double phaseWeight = -1;
    int phase = 0;
    for (int k = 0; k < bestLag; ++k) {
        double strength = 0;
        for (size_t i = (size_t)k; i < count; i += (size_t)bestLag)
            strength += onsets[i];
        if (strength > phaseWeight) { phaseWeight = strength; phase = k; }
    }
    free(onsets);
    result.bpm = hz * 60.0 / bestLag;
    result.confidence = clampd(bestScore, 0, 1);
    result.downbeatSeconds = phase / hz;
    // The runner-up often represents a half/double-time alias; quality (rather
    // than separation) is used for confidence so regular 4/4 music is not rejected.
    (void)runner;
    return result;
}

static bool validGrid(SGDJBeatGrid g) {
    return isfinite(g.bpm) && g.bpm >= 65 && g.bpm <= 190 &&
        isfinite(g.confidence) && g.confidence >= 0.35 &&
        isfinite(g.downbeatSeconds) && g.downbeatSeconds >= 0 &&
        (g.beatsPerBar == 0 || g.beatsPerBar == 4);
}
static double phaseAt(double phase, double period) {
    if (!(period > 0) || !isfinite(phase)) return 0;
    double normalized = fmod(phase, period);
    return normalized < 0 ? normalized + period : normalized;
}

SGDJBeatPlan SGDJBeatPlanBuild(SGDJBeatGrid a, SGDJBeatGrid b, SGDJBeatReadiness input) {
    SGDJBeatPlan plan = {.status = SGDJPlanUnsupported, .speedB = 1.0};
    // A download/cache flag cannot satisfy this condition. The two decoded
    // streams must genuinely exist as independent, readable PCM sources.
    if (!input.localPlayback || !input.independentStreams) return plan;
    if (input.seeksOrRouteChanging || !isfinite(input.positionA) ||
        !isfinite(input.durationA)) {
        plan.status = SGDJPlanPlaybackChanged;
        return plan;
    }
    if (!validGrid(a) || !validGrid(b)) {
        plan.status = SGDJPlanUnknownBeat;
        return plan;
    }
    if (input.durationA < 8 || input.positionA < 0 || input.positionA >= input.durationA) {
        plan.status = SGDJPlanNoFuturePhrase;
        return plan;
    }

    // Musically equivalent half/double tempo interpretations are not a DSP
    // modification; normalize only to select an appropriate stretch target.
    double normalizedB = b.bpm, distance = fabs(log(normalizedB / a.bpm));
    const double variants[2] = {b.bpm * 0.5, b.bpm * 2.0};
    for (unsigned i = 0; i < 2; i++) {
        if (variants[i] < 65 || variants[i] > 190) continue;
        const double candidate = fabs(log(variants[i] / a.bpm));
        if (candidate < distance) { distance = candidate; normalizedB = variants[i]; }
    }
    const double desiredRate = a.bpm / normalizedB;
    const double mismatch = fabs(desiredRate - 1);
    if (mismatch > 0.06) {
        plan.status = SGDJPlanTempoMismatch;
        return plan;
    }
    if (!input.pitchPreservingStretch && mismatch > 0.025) {
        plan.status = SGDJPlanTempoMismatch;
        return plan;
    }
    plan.speedB = input.pitchPreservingStretch ? desiredRate : 1.0;
    plan.beatDrift = fabs(a.bpm - normalizedB) / 60.0;

    const double beat = 60.0 / a.bpm;
    const double bar = beat * 4.0;
    double overlap = clampd(8 * beat, 2.0, 6.5);
    // Without pitch-preserving stretch, do not promise a long beat match from
    // only the first beat: the phase drifts at different BPMs.
    if (!input.pitchPreservingStretch && mismatch > 0.006)
        overlap = fmin(overlap, 2 * beat);
    const double wanted = input.durationA - overlap;
    const double aPhase = phaseAt(a.downbeatSeconds, bar);
    const double start = aPhase + floor((wanted - aPhase) / bar) * bar;
    if (!(start > input.positionA + 0.05) ||
        !(start >= 0 && start + overlap <= input.durationA + 0.001)) {
        plan.status = SGDJPlanNoFuturePhrase;
        return plan;
    }
    const double bCue = phaseAt(b.downbeatSeconds, beat * 4.0);
    const double needA = start - input.positionA + overlap + 0.10;
    const double needB = bCue + overlap * plan.speedB + 0.10;

    if (!isfinite(input.bufferedA) || input.bufferedA < needA) {
        plan.status = SGDJPlanInsufficientA;
        return plan;
    }
    if (!isfinite(input.bufferedB) || input.bufferedB < needB) {
        plan.status = SGDJPlanInsufficientB;
        return plan;
    }
    plan.startA = start;
    plan.cueB = bCue;
    plan.overlap = overlap;
    plan.ready = true;
    plan.beatMatched = true;
    plan.status = SGDJPlanReady;
    return plan;
}

void SGDJBeatMixStereo(const float *a, const float *b, float *dst,
                      size_t frames, uint64_t offset, uint64_t total) {
    if (!a || !b || !dst || !total) return;
    const double halfPi = 1.57079632679489661923;
    for (size_t i = 0; i < frames; ++i) {
        double p = total > 1 ? clampd((offset + i) / (double)(total - 1), 0, 1) : 1;
        // Equal-power envelopes, continuous across callback boundaries.
        float ga = (float)cos(p * halfPi);
        float gb = (float)sin(p * halfPi);
        for (unsigned channel = 0; channel < 2; ++channel) {
            size_t sample = i * 2 + channel;
            float out = a[sample] * ga + b[sample] * gb;
            // Output protection only; no allocation, locks or logging in DSP.
            dst[sample] = fmaxf(-1.0f, fminf(1.0f, out));
        }
    }
}
