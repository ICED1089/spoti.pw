#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "SGDJAudio.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum {
    kAnalysisPackets = 192,
    kDeckCapacityFrames = SGDJAudioSampleRate * 12,
};

typedef struct {
    float *pcm; // interleaved stereo
    uint32_t capacity;
    uint32_t head;
    uint32_t count;
    double fractional;
} SGDJDeck;

struct SGDJAudio {
    SGAudioRingBuffer *analysis;
    atomic_uint_fast64_t track, expectedTrack, sourceFrame, trackEpoch, dropped;
    atomic_bool boundarySupported;

    atomic_uint planSequence;
    atomic_uint_fast64_t planOutgoingTrack, planIncomingTrack;
    atomic_uint_fast64_t planOutgoingStart, planOutgoingEnd, planIncomingFrames;
    atomic_uint_fast64_t planPrefetchStart, planOverlapFrames, planIncomingCue;
    atomic_uint planRecipe, planStrengthBits, planBuffered, planARateBits, planBRateBits;

    SGDJDeck deckA, deckB;
    unsigned activePlanGeneration;
    uint64_t audibleTrack, audibleFrame;
    uint64_t cueRemaining, overlapTotal, overlapDone;
    bool v2Prefetching, v2BoundarySeen, v2Mixing, v2AfterMix;
    float lowA[2], lowB[2];

    atomic_bool bufferedMixActive, bufferedMixCompleted;
    atomic_uint_fast64_t bufferedOverlapFrames, bufferedUnderruns;

    uint64_t renderTrack;
    float low[2];
    bool lowPrimed;

    float interleaved[SGDJAudioMaximumFrames * 2];
    float scratchL[SGDJAudioMaximumFrames], scratchR[SGDJAudioMaximumFrames];
    float outA[SGDJAudioMaximumFrames * 2], outB[SGDJAudioMaximumFrames * 2];
};

static uint32_t bitsOfFloat(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return bits;
}
static float floatOfBits(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}
static float clamp01(float value) {
    return value < 0 ? 0 : value > 1 ? 1 : value;
}
static float ease(float value) {
    value = clamp01(value);
    return value * value * (3 - 2 * value);
}

typedef struct {
    uint64_t outgoingTrack, incomingTrack, outgoingStart, outgoingEnd, incomingFrames;
    uint64_t prefetchStart, overlapFrames, incomingCue;
    uint32_t recipe;
    float strength, deckARate, deckBRate;
    bool buffered;
    unsigned generation;
} RenderPlan;

static bool readPlan(SGDJAudio *audio, RenderPlan *plan) {
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        unsigned before = atomic_load_explicit(&audio->planSequence, memory_order_acquire);
        if (before & 1) continue;
        RenderPlan value = {
            .outgoingTrack = atomic_load_explicit(&audio->planOutgoingTrack, memory_order_relaxed),
            .incomingTrack = atomic_load_explicit(&audio->planIncomingTrack, memory_order_relaxed),
            .outgoingStart = atomic_load_explicit(&audio->planOutgoingStart, memory_order_relaxed),
            .outgoingEnd = atomic_load_explicit(&audio->planOutgoingEnd, memory_order_relaxed),
            .incomingFrames = atomic_load_explicit(&audio->planIncomingFrames, memory_order_relaxed),
            .prefetchStart = atomic_load_explicit(&audio->planPrefetchStart, memory_order_relaxed),
            .overlapFrames = atomic_load_explicit(&audio->planOverlapFrames, memory_order_relaxed),
            .incomingCue = atomic_load_explicit(&audio->planIncomingCue, memory_order_relaxed),
            .recipe = atomic_load_explicit(&audio->planRecipe, memory_order_relaxed),
            .strength = floatOfBits(atomic_load_explicit(&audio->planStrengthBits, memory_order_relaxed)),
            .deckARate = floatOfBits(atomic_load_explicit(&audio->planARateBits, memory_order_relaxed)),
            .deckBRate = floatOfBits(atomic_load_explicit(&audio->planBRateBits, memory_order_relaxed)),
            .buffered = atomic_load_explicit(&audio->planBuffered, memory_order_relaxed) != 0,
            .generation = before,
        };
        unsigned after = atomic_load_explicit(&audio->planSequence, memory_order_acquire);
        if (before == after && !(after & 1)) {
            value.generation = after;
            *plan = value;
            return true;
        }
    }
    memset(plan, 0, sizeof *plan);
    return false;
}

static void publishTrack(SGDJAudio *audio, uint64_t track, uint64_t frame) {
    atomic_fetch_add_explicit(&audio->trackEpoch, 1, memory_order_acq_rel);
    atomic_store_explicit(&audio->track, track, memory_order_release);
    atomic_store_explicit(&audio->sourceFrame, frame, memory_order_release);
    atomic_fetch_add_explicit(&audio->trackEpoch, 1, memory_order_acq_rel);
}

#pragma mark - deck buffers

static bool deckInit(SGDJDeck *deck, uint32_t capacity) {
    deck->pcm = calloc((size_t)capacity * 2, sizeof(float));
    deck->capacity = deck->pcm ? capacity : 0;
    return deck->pcm != NULL;
}
static void deckReset(SGDJDeck *deck) {
    deck->head = deck->count = 0;
    deck->fractional = 0;
}
static void deckDestroy(SGDJDeck *deck) {
    free(deck->pcm);
    memset(deck, 0, sizeof *deck);
}
static uint32_t deckSpace(const SGDJDeck *deck) {
    return deck->capacity - deck->count;
}
static uint32_t deckWrite(SGDJDeck *deck, const float *pcm, uint32_t frames) {
    frames = MIN(frames, deckSpace(deck));
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t at = (deck->head + deck->count + i) % deck->capacity;
        deck->pcm[(size_t)at * 2] = pcm[(size_t)i * 2];
        deck->pcm[(size_t)at * 2 + 1] = pcm[(size_t)i * 2 + 1];
    }
    deck->count += frames;
    return frames;
}
static uint32_t deckDrop(SGDJDeck *deck, uint32_t frames) {
    frames = MIN(frames, deck->count);
    deck->head = (deck->head + frames) % deck->capacity;
    deck->count -= frames;
    if (!deck->count) deck->fractional = 0;
    return frames;
}
static float deckSample(const SGDJDeck *deck, uint32_t offset, unsigned channel) {
    if (!deck->count) return 0;
    if (offset >= deck->count) offset = deck->count - 1;
    uint32_t at = (deck->head + offset) % deck->capacity;
    return deck->pcm[(size_t)at * 2 + channel];
}
static uint32_t deckOutputCapacity(const SGDJDeck *deck, float rate) {
    rate = fmaxf(0.94f, fminf(rate, 1.06f));
    if (!deck->count) return 0;
    double usable = deck->count > 1 ? deck->count - 1 - deck->fractional : 0;
    if (usable <= 0) return deck->count ? 1 : 0;
    return (uint32_t)floor(usable / rate) + 1;
}
static uint32_t deckRender(SGDJDeck *deck, float rate, float *out, uint32_t frames) {
    if (!deck->count || !frames) return 0;
    rate = fmaxf(0.94f, fminf(rate, 1.06f));
    uint32_t possible = MIN(frames, deckOutputCapacity(deck, rate));
    double pos = deck->fractional;
    for (uint32_t i = 0; i < possible; i++) {
        uint32_t base = (uint32_t)floor(pos);
        float frac = (float)(pos - base);
        for (unsigned c = 0; c < 2; c++) {
            float a = deckSample(deck, base, c);
            float b = deckSample(deck, base + 1, c);
            out[(size_t)i * 2 + c] = a + (b - a) * frac;
        }
        pos += rate;
    }
    uint32_t consume = (uint32_t)floor(pos);
    if (consume > deck->count) consume = deck->count;
    deckDrop(deck, consume);
    deck->fractional = pos - consume;
    return possible;
}

#pragma mark - V1 DSP

static void transitionShape(uint32_t recipe, bool incoming, float progress, float strength,
                            float *gain, float *lowGain) {
    progress = ease(progress);
    strength = fmaxf(0.5f, fminf(strength, 1.35f));

    float g = 1, low = 1;
    switch ((SGDJRecipe)recipe) {
        case SGDJRecipeSmooth:
            if (incoming) { g = 0.48f + 0.52f * progress; low = 0.25f + 0.75f * progress; }
            else { g = 1.0f - 0.48f * progress; low = 1.0f - 0.70f * progress; }
            break;
        case SGDJRecipeClub:
            if (incoming) { g = 0.62f + 0.38f * progress; low = 0.04f + 0.96f * progress; }
            else { g = 1.0f - 0.32f * progress; low = 1.0f - 0.94f * progress; }
            break;
        case SGDJRecipeQuick: {
            float q = incoming ? clamp01(progress * 1.8f) : clamp01((progress - 0.42f) / 0.58f);
            q = ease(q);
            if (incoming) { g = 0.28f + 0.72f * q; low = 0.28f + 0.72f * q; }
            else { g = 1.0f - 0.72f * q; low = 1.0f - 0.70f * q; }
            break;
        }
        case SGDJRecipeCleanCut:
        default: {
            float q = incoming ? clamp01(progress * 5.0f) : clamp01((progress - 0.88f) / 0.12f);
            q = ease(q);
            if (incoming) g = 0.18f + 0.82f * q;
            else g = 1.0f - 0.82f * q;
            low = 1;
            break;
        }
    }
    *gain = 1.0f - (1.0f - g) * strength;
    *lowGain = 1.0f - (1.0f - low) * strength;
    *gain = fmaxf(0.12f, fminf(*gain, 1.0f));
    *lowGain = fmaxf(0.02f, fminf(*lowGain, 1.0f));
}

static void processDSP(SGDJAudio *audio, const RenderPlan *plan, uint64_t track, uint64_t frame,
                       UInt32 frames, AudioBufferList *data) {
    bool outgoing = plan->outgoingTrack && track == plan->outgoingTrack &&
                    plan->outgoingEnd > plan->outgoingStart &&
                    frame < plan->outgoingEnd && frame + frames > plan->outgoingStart;
    bool incoming = plan->incomingTrack && track == plan->incomingTrack &&
                    plan->incomingFrames && frame < plan->incomingFrames;
    if (!outgoing && !incoming) {
        audio->renderTrack = track;
        return;
    }

    if (audio->renderTrack != track) {
        audio->renderTrack = track;
        audio->low[0] = audio->low[1] = 0;
        audio->lowPrimed = false;
    }

    const float alpha = 1.0f - expf(-2.0f * (float)M_PI * 200.0f / SGDJAudioSampleRate);
    float *left = data->mBuffers[0].mData, *right = data->mBuffers[1].mData;
    for (UInt32 i = 0; i < frames; i++) {
        uint64_t at = frame + i;
        float gain = 1, lowGain = 1;
        if (outgoing && at >= plan->outgoingStart && at < plan->outgoingEnd) {
            float p = (float)((double)(at - plan->outgoingStart) /
                              (double)(plan->outgoingEnd - plan->outgoingStart));
            transitionShape(plan->recipe, false, p, plan->strength, &gain, &lowGain);
        } else if (incoming && at < plan->incomingFrames) {
            float p = (float)((double)at / (double)plan->incomingFrames);
            transitionShape(plan->recipe, true, p, plan->strength, &gain, &lowGain);
        }
        float sample[2] = {left[i], right[i]};
        if (!audio->lowPrimed) {
            audio->low[0] = sample[0]; audio->low[1] = sample[1]; audio->lowPrimed = true;
        }
        for (unsigned c = 0; c < 2; c++) {
            audio->low[c] += alpha * (sample[c] - audio->low[c]);
            float high = sample[c] - audio->low[c];
            float out = (high + audio->low[c] * lowGain) * gain;
            if (c == 0) left[i] = out; else right[i] = out;
        }
    }
}

#pragma mark - source pulling

static void analyzePacket(SGDJAudio *audio, uint64_t epoch, uint64_t track, uint64_t frame,
                          uint32_t frames, const float *interleaved) {
    SGAudioStamp stamp = {epoch, track, frame, 1, frames};
    if (!SGAudioRingWrite(audio->analysis, stamp, interleaved))
        atomic_fetch_add_explicit(&audio->dropped, 1, memory_order_relaxed);
}

static OSStatus pullRaw(SGDJAudio *audio, UInt32 frames, const AudioTimeStamp *time,
                        uint64_t *trackOut, uint64_t *frameOut) {
    if (!frames || frames > SGDJAudioMaximumFrames) return kAudio_ParamError;
    struct { AudioBufferList list; AudioBuffer more; } part;
    part.list.mNumberBuffers = 2;
    part.list.mBuffers[0] = (AudioBuffer){1, frames * sizeof(float), audio->scratchL};
    part.more = (AudioBuffer){1, frames * sizeof(float), audio->scratchR};

    uint64_t epoch = atomic_load_explicit(&audio->trackEpoch, memory_order_acquire);
    uint64_t track = atomic_load_explicit(&audio->track, memory_order_acquire);
    uint64_t frame = atomic_load_explicit(&audio->sourceFrame, memory_order_acquire);
    OSStatus status = SGAudioPipelinePullOriginal(frames, &part.list, time);
    if (status != noErr) return status;

    for (UInt32 i = 0; i < frames; i++) {
        audio->interleaved[(size_t)i * 2] = audio->scratchL[i];
        audio->interleaved[(size_t)i * 2 + 1] = audio->scratchR[i];
    }
    analyzePacket(audio, epoch, track, frame, frames, audio->interleaved);
    if (epoch == atomic_load_explicit(&audio->trackEpoch, memory_order_acquire) &&
        track == atomic_load_explicit(&audio->track, memory_order_acquire))
        atomic_store_explicit(&audio->sourceFrame, frame + frames, memory_order_release);
    if (trackOut) *trackOut = track;
    if (frameOut) *frameOut = frame;
    return noErr;
}

static void crossBoundary(SGDJAudio *audio, uint64_t expected) {
    if (!expected) return;
    uint64_t currentExpected = expected;
    if (!atomic_compare_exchange_strong_explicit(&audio->expectedTrack, &currentExpected, 0,
                                                  memory_order_acq_rel, memory_order_relaxed)) return;
    publishTrack(audio, expected, 0);
    audio->renderTrack = 0;
    audio->v2BoundarySeen = true;
}

static uint32_t routePulledToDecks(SGDJAudio *audio, const RenderPlan *plan,
                                   uint64_t track, const float *pcm, uint32_t frames) {
    if (track == plan->outgoingTrack) return deckWrite(&audio->deckA, pcm, frames);
    if (track == plan->incomingTrack) {
        uint32_t skip = (uint32_t)MIN((uint64_t)frames, audio->cueRemaining);
        audio->cueRemaining -= skip;
        pcm += (size_t)skip * 2;
        frames -= skip;
        return skip + deckWrite(&audio->deckB, pcm, frames);
    }
    return 0;
}

// Pull up to requested frames into the local deck buffers. Extra pulls are allowed only when
// Spotify's verified decoder queue says the PCM is already present; required pulls may use the
// normal source contract but still split exactly at the verified natural track boundary.
static OSStatus pullIntoDecks(SGDJAudio *audio, const RenderPlan *plan, UInt32 requested,
                              bool extraOnly, const AudioTimeStamp *time, UInt32 *pulledOut) {
    UInt32 pulled = 0;
    while (pulled < requested) {
        UInt32 want = MIN((UInt32)SGDJAudioMaximumFrames, requested - pulled);
        uint64_t expected = atomic_load_explicit(&audio->expectedTrack, memory_order_acquire);
        SGAudioSourcePrefix prefix = expected ?
            SGAudioPipelineSourcePrefix(want, true) : (SGAudioSourcePrefix){0, UINT32_MAX};

        if (extraOnly) {
            if (!prefix.frames) break;
            want = MIN(want, prefix.frames);
        }

        UInt32 before = want;
        bool boundary = false;
        if (expected && prefix.boundary != UINT32_MAX && prefix.boundary < want) {
            before = prefix.boundary;
            boundary = true;
        }
        if (boundary && before == 0) {
            crossBoundary(audio, expected);
            continue;
        }

        if (before) {
            uint64_t track = 0, frame = 0;
            OSStatus status = pullRaw(audio, before, time, &track, &frame);
            if (status != noErr) return status;
            uint32_t accepted = routePulledToDecks(audio, plan, track, audio->interleaved, before);
            if (accepted < before) {
                atomic_fetch_add_explicit(&audio->bufferedUnderruns, 1, memory_order_relaxed);
                return kAudioUnitErr_TooManyFramesToProcess;
            }
            pulled += before;
        }
        if (boundary) crossBoundary(audio, expected);
        if (!before && !boundary) break;
    }
    if (pulledOut) *pulledOut = pulled;
    return noErr;
}

static OSStatus pullDirect(SGDJAudio *audio, const RenderPlan *plan, UInt32 offset, UInt32 frames,
                           AudioBufferList *data, const AudioTimeStamp *time) {
    struct { AudioBufferList list; AudioBuffer more; } part;
    part.list.mNumberBuffers = 2;
    for (unsigned c = 0; c < 2; c++) {
        float *base = data->mBuffers[c].mData;
        part.list.mBuffers[c] = (AudioBuffer){1, frames * sizeof(float), base + offset};
    }

    uint64_t epoch = atomic_load_explicit(&audio->trackEpoch, memory_order_acquire);
    uint64_t track = atomic_load_explicit(&audio->track, memory_order_acquire);
    uint64_t frame = atomic_load_explicit(&audio->sourceFrame, memory_order_acquire);
    OSStatus status = SGAudioPipelinePullOriginal(frames, &part.list, time);
    if (status != noErr) return status;

    for (UInt32 i = 0; i < frames; i++) {
        audio->interleaved[(size_t)i * 2] = ((float *)part.list.mBuffers[0].mData)[i];
        audio->interleaved[(size_t)i * 2 + 1] = ((float *)part.list.mBuffers[1].mData)[i];
    }
    analyzePacket(audio, epoch, track, frame, frames, audio->interleaved);
    processDSP(audio, plan, track, frame, frames, &part.list);
    if (epoch == atomic_load_explicit(&audio->trackEpoch, memory_order_acquire) &&
        track == atomic_load_explicit(&audio->track, memory_order_acquire))
        atomic_store_explicit(&audio->sourceFrame, frame + frames, memory_order_release);
    audio->audibleTrack = track;
    audio->audibleFrame = frame + frames;
    return noErr;
}

#pragma mark - V2 buffered two-deck mixer

static void resetV2(SGDJAudio *audio, const RenderPlan *plan) {
    deckReset(&audio->deckA);
    deckReset(&audio->deckB);
    audio->activePlanGeneration = plan->generation;
    audio->audibleTrack = atomic_load_explicit(&audio->track, memory_order_acquire);
    audio->audibleFrame = atomic_load_explicit(&audio->sourceFrame, memory_order_acquire);
    audio->cueRemaining = plan->incomingCue;
    audio->overlapTotal = audio->overlapDone = 0;
    audio->v2Prefetching = audio->v2BoundarySeen = audio->v2Mixing = audio->v2AfterMix = false;
    audio->lowA[0] = audio->lowA[1] = audio->lowB[0] = audio->lowB[1] = 0;
    atomic_store_explicit(&audio->bufferedMixActive, false, memory_order_release);
    atomic_store_explicit(&audio->bufferedMixCompleted, false, memory_order_release);
    atomic_store_explicit(&audio->bufferedOverlapFrames, 0, memory_order_relaxed);
}

static void copyInterleavedToABL(const float *pcm, uint32_t frames, AudioBufferList *data, uint32_t offset) {
    float *left = data->mBuffers[0].mData, *right = data->mBuffers[1].mData;
    for (uint32_t i = 0; i < frames; i++) {
        left[offset + i] = pcm[(size_t)i * 2];
        right[offset + i] = pcm[(size_t)i * 2 + 1];
    }
}

static void mixCurves(uint32_t recipe, float p, float strength,
                      float *gainA, float *gainB, float *lowA, float *lowB) {
    p = ease(p);
    strength = fmaxf(0.65f, fminf(strength, 1.25f));
    float a = cosf(p * (float)M_PI_2);
    float b = sinf(p * (float)M_PI_2);
    float la = 1, lb = 1;

    if (recipe == SGDJRecipeClub) {
        a = 1.0f - 0.55f * ease(clamp01((p - 0.45f) / 0.55f));
        b = 0.55f + 0.45f * ease(clamp01(p / 0.55f));
        la = 1.0f - 0.96f * ease(clamp01((p - 0.35f) / 0.22f));
        lb = 0.04f + 0.96f * ease(clamp01((p - 0.48f) / 0.22f));
    } else if (recipe == SGDJRecipeQuick) {
        a = cosf(ease(clamp01(p * 1.15f)) * (float)M_PI_2);
        b = sinf(ease(clamp01(p * 1.15f)) * (float)M_PI_2);
        la = 1.0f - 0.85f * ease(clamp01((p - 0.30f) / 0.30f));
        lb = 0.15f + 0.85f * ease(clamp01((p - 0.45f) / 0.25f));
    } else {
        la = 1.0f - 0.82f * ease(clamp01((p - 0.32f) / 0.36f));
        lb = 0.18f + 0.82f * ease(clamp01((p - 0.48f) / 0.34f));
    }

    *gainA = 1.0f - (1.0f - a) * strength;
    *gainB = 1.0f - (1.0f - b) * strength;
    *lowA = 1.0f - (1.0f - la) * strength;
    *lowB = 1.0f - (1.0f - lb) * strength;
}

static void filterDeckSample(float sample, float *low, float lowGain, float *out) {
    const float alpha = 1.0f - expf(-2.0f * (float)M_PI * 200.0f / SGDJAudioSampleRate);
    *low += alpha * (sample - *low);
    *out = (sample - *low) + *low * lowGain;
}

static uint32_t requiredDeckInput(uint32_t outputFrames, float rate) {
    rate = fmaxf(0.94f, fminf(rate, 1.06f));
    return (uint32_t)ceil((outputFrames + 2) * rate) + 2;
}

static OSStatus ensureIncoming(SGDJAudio *audio, const RenderPlan *plan, uint32_t outputFrames,
                               const AudioTimeStamp *time) {
    uint32_t need = requiredDeckInput(outputFrames, plan->deckBRate);
    while (audio->deckB.count < need) {
        uint32_t request = MIN((UInt32)SGDJAudioMaximumFrames, need - audio->deckB.count + (uint32_t)MIN(audio->cueRemaining, (uint64_t)SGDJAudioMaximumFrames));
        UInt32 pulled = 0;
        OSStatus status = pullIntoDecks(audio, plan, request, false, time, &pulled);
        if (status != noErr) return status;
        if (!pulled) break;
    }
    return noErr;
}

static OSStatus processV2Chunk(SGDJAudio *audio, const RenderPlan *plan, UInt32 frames,
                               AudioBufferList *data, UInt32 offset, const AudioTimeStamp *time) {
    if (audio->activePlanGeneration != plan->generation) resetV2(audio, plan);

    // Before the prefetch window, behave exactly like normal Spotify.
    if (!audio->v2Prefetching && audio->audibleTrack == plan->outgoingTrack &&
        audio->audibleFrame < plan->prefetchStart) {
        uint64_t remaining = plan->prefetchStart - audio->audibleFrame;
        UInt32 direct = (UInt32)MIN((uint64_t)frames, remaining);
        if (direct) {
            OSStatus status = pullDirect(audio, plan, offset, direct, data, time);
            if (status != noErr) return status;
            if (direct == frames) return noErr;
            offset += direct; frames -= direct;
        }
        audio->v2Prefetching = true;
    }

    if (!audio->v2Prefetching) audio->v2Prefetching = true;

    // After a completed overlap, drain the already-consumed B prefix before returning to direct pulls.
    if (audio->v2AfterMix) {
        while (frames) {
            uint32_t have = deckRender(&audio->deckB, 1.0f, audio->outB, frames);
            if (have) {
                copyInterleavedToABL(audio->outB, have, data, offset);
                offset += have; frames -= have;
                audio->audibleTrack = plan->incomingTrack;
                audio->audibleFrame += have;
                continue;
            }
            // Fractional tail shorter than one renderable frame: it is below a sample of timing
            // significance. The decoder is already positioned immediately after this local prefix.
            deckReset(&audio->deckB);
            atomic_store_explicit(&audio->bufferedMixCompleted, true, memory_order_release);
            if (frames) return pullDirect(audio, plan, offset, frames, data, time);
        }
        return noErr;
    }

    if (audio->v2Mixing) {
        OSStatus incomingStatus = ensureIncoming(audio, plan, frames, time);
        if (incomingStatus != noErr) return incomingStatus;
        uint32_t possibleA = deckOutputCapacity(&audio->deckA, plan->deckARate);
        uint32_t possibleB = deckOutputCapacity(&audio->deckB, plan->deckBRate);
        uint32_t mixed = MIN(frames, MIN(possibleA, possibleB));
        if (!mixed) {
            atomic_fetch_add_explicit(&audio->bufferedUnderruns, 1, memory_order_relaxed);
            audio->v2Mixing = false;
            audio->v2AfterMix = true;
            return processV2Chunk(audio, plan, frames, data, offset, time);
        }
        // Render exactly the amount both decks can supply so one deck can never be consumed
        // further than the audio that was actually mixed.
        uint32_t aFrames = deckRender(&audio->deckA, plan->deckARate, audio->outA, mixed);
        uint32_t bFrames = deckRender(&audio->deckB, plan->deckBRate, audio->outB, mixed);
        mixed = MIN(aFrames, bFrames);

        float *left = data->mBuffers[0].mData, *right = data->mBuffers[1].mData;
        for (uint32_t i = 0; i < mixed; i++) {
            float p = audio->overlapTotal > 1 ?
                (float)((double)(audio->overlapDone + i) / (double)(audio->overlapTotal - 1)) : 1;
            float ga, gb, la, lb;
            mixCurves(plan->recipe, p, plan->strength, &ga, &gb, &la, &lb);
            for (unsigned ch = 0; ch < 2; ch++) {
                float af, bf;
                filterDeckSample(audio->outA[(size_t)i * 2 + ch], &audio->lowA[ch], la, &af);
                filterDeckSample(audio->outB[(size_t)i * 2 + ch], &audio->lowB[ch], lb, &bf);
                // 0.86 headroom prevents normal full-scale masters from clipping during overlap.
                float sample = 0.86f * (af * ga + bf * gb);
                sample = fmaxf(-1.0f, fminf(1.0f, sample));
                if (ch == 0) left[offset + i] = sample; else right[offset + i] = sample;
            }
        }
        audio->overlapDone += mixed;
        audio->audibleFrame += mixed;
        if (audio->overlapDone >= audio->overlapTotal || deckOutputCapacity(&audio->deckA, plan->deckARate) <= 1) {
            audio->v2Mixing = false;
            audio->v2AfterMix = true;
            deckReset(&audio->deckA);
            atomic_store_explicit(&audio->bufferedMixActive, false, memory_order_release);
        }
        if (mixed < frames) return processV2Chunk(audio, plan, frames - mixed, data, offset + mixed, time);
        return noErr;
    }

    // Build a local lead by pulling only PCM Spotify has already verified in its decoder queue.
    // Required A frames are pulled normally; additional frames are never speculative.
    while (audio->deckA.count < frames + 2 && !audio->v2BoundarySeen) {
        UInt32 pulled = 0;
        OSStatus status = pullIntoDecks(audio, plan, frames + 2 - audio->deckA.count, false, time, &pulled);
        if (status != noErr) return status;
        if (!pulled) break;
    }

    uint32_t renderedA = deckRender(&audio->deckA, 1.0f, audio->outA, frames);
    if (renderedA) {
        copyInterleavedToABL(audio->outA, renderedA, data, offset);
        audio->audibleTrack = plan->outgoingTrack;
        audio->audibleFrame += renderedA;
    }

    // Target decoder lead includes the planned overlap and any incoming cue that will be skipped.
    uint64_t targetLead64 = plan->overlapFrames + plan->incomingCue;
    targetLead64 = MIN(targetLead64, (uint64_t)kDeckCapacityFrames - SGDJAudioMaximumFrames);
    uint32_t targetLead = (uint32_t)targetLead64;
    if (!audio->v2BoundarySeen && audio->deckA.count < targetLead) {
        uint32_t want = MIN((uint32_t)SGDJAudioMaximumFrames, targetLead - audio->deckA.count);
        UInt32 pulled = 0;
        OSStatus status = pullIntoDecks(audio, plan, want, true, time, &pulled);
        if (status != noErr) return status;
    }

    if (audio->v2BoundarySeen) {
        // Consume B's selected cue point using only verified/normal sequential source pulls while
        // A continues from its retained tail.
        uint32_t desiredB = requiredDeckInput(frames, plan->deckBRate);
        uint32_t attempts = 0;
        while ((audio->cueRemaining || audio->deckB.count < desiredB) && attempts++ < 3) {
            UInt32 pulled = 0;
            uint32_t want = MIN((uint32_t)SGDJAudioMaximumFrames,
                                (uint32_t)MIN((uint64_t)SGDJAudioMaximumFrames,
                                             audio->cueRemaining + desiredB - MIN(desiredB, audio->deckB.count)));
            OSStatus status = pullIntoDecks(audio, plan, MAX(want, (uint32_t)1), true, time, &pulled);
            if (status != noErr) return status;
            if (!pulled) break;
        }
        uint32_t possibleA = deckOutputCapacity(&audio->deckA, plan->deckARate);
        uint32_t possibleB = deckOutputCapacity(&audio->deckB, plan->deckBRate);
        uint32_t overlap = (uint32_t)MIN(plan->overlapFrames, (uint64_t)possibleA);
        if (!audio->cueRemaining && possibleB >= MIN(frames, overlap) && overlap >= SGDJAudioSampleRate / 4) {
            audio->overlapTotal = overlap;
            audio->overlapDone = 0;
            audio->v2Mixing = true;
            audio->audibleTrack = plan->outgoingTrack;
            atomic_store_explicit(&audio->bufferedOverlapFrames, overlap, memory_order_relaxed);
            atomic_store_explicit(&audio->bufferedMixActive, true, memory_order_release);
        }
    }

    if (renderedA < frames) {
        // If there was not enough retained A to sustain the requested V2 lead, fail soft into
        // sequential B rather than outputting silence or stalling the real-time callback.
        atomic_fetch_add_explicit(&audio->bufferedUnderruns, 1, memory_order_relaxed);
        audio->v2AfterMix = true;
        audio->v2Mixing = false;
        if (audio->deckB.count) {
            uint32_t b = deckRender(&audio->deckB, 1.0f, audio->outB, frames - renderedA);
            copyInterleavedToABL(audio->outB, b, data, offset + renderedA);
            renderedA += b;
        }
        if (renderedA < frames)
            return pullDirect(audio, plan, offset + renderedA, frames - renderedA, data, time);
    }
    return noErr;
}

static OSStatus processV1(SGDJAudio *audio, const RenderPlan *plan, UInt32 frames,
                          AudioBufferList *data, const AudioTimeStamp *time) {
    for (UInt32 done = 0; done < frames;) {
        UInt32 count = MIN(frames - done, (UInt32)SGDJAudioMaximumFrames);
        uint64_t expected = atomic_load_explicit(&audio->expectedTrack, memory_order_acquire);
        UInt32 beforeBoundary = count;
        bool boundary = false;
        if (expected && atomic_load_explicit(&audio->boundarySupported, memory_order_relaxed)) {
            SGAudioSourcePrefix prefix = SGAudioPipelineSourcePrefix(count, true);
            if (prefix.boundary != UINT32_MAX && prefix.boundary < count) {
                beforeBoundary = prefix.boundary;
                boundary = true;
            }
        }
        if (boundary && beforeBoundary == 0) {
            crossBoundary(audio, expected);
            continue;
        }
        if (beforeBoundary) {
            OSStatus status = pullDirect(audio, plan, done, beforeBoundary, data, time);
            if (status != noErr) return status;
            done += beforeBoundary;
        }
        if (boundary) crossBoundary(audio, expected);
    }
    return noErr;
}

static OSStatus process(void *context, UInt32 frames, AudioBufferList *data, const AudioTimeStamp *time) {
    SGDJAudio *audio = context;
    if (!audio || !data || data->mNumberBuffers != 2 || frames > UINT32_MAX / sizeof(float))
        return kAudio_ParamError;
    for (unsigned c = 0; c < 2; c++)
        if (!data->mBuffers[c].mData || data->mBuffers[c].mNumberChannels != 1 ||
            data->mBuffers[c].mDataByteSize < frames * sizeof(float)) return kAudio_ParamError;

    RenderPlan plan;
    if (!readPlan(audio, &plan) || !plan.outgoingTrack)
        return processV1(audio, &(RenderPlan){0}, frames, data, time);

    if (plan.buffered && atomic_load_explicit(&audio->boundarySupported, memory_order_relaxed)) {
        for (UInt32 done = 0; done < frames;) {
            UInt32 count = MIN(frames - done, (UInt32)SGDJAudioMaximumFrames);
            OSStatus status = processV2Chunk(audio, &plan, count, data, done, time);
            if (status != noErr) return status;
            done += count;
        }
        return noErr;
    }
    return processV1(audio, &plan, frames, data, time);
}

SGDJAudio *SGDJAudioCreate(void) {
    SGDJAudio *audio = calloc(1, sizeof *audio);
    if (!audio) return NULL;
    audio->analysis = SGAudioRingCreate(kAnalysisPackets, SGDJAudioMaximumFrames, 2);
    if (!audio->analysis || !deckInit(&audio->deckA, kDeckCapacityFrames) ||
        !deckInit(&audio->deckB, kDeckCapacityFrames)) {
        SGAudioRingDestroy(audio->analysis);
        deckDestroy(&audio->deckA); deckDestroy(&audio->deckB);
        free(audio);
        return NULL;
    }
    atomic_init(&audio->trackEpoch, 2);
    atomic_init(&audio->planSequence, 0);
    return audio;
}

void SGDJAudioDestroy(SGDJAudio *audio) {
    if (!audio) return;
    SGDJAudioDetach(audio);
    SGAudioRingDestroy(audio->analysis);
    deckDestroy(&audio->deckA); deckDestroy(&audio->deckB);
    free(audio);
}

bool SGDJAudioAttach(SGDJAudio *audio) {
    if (!audio) return false;
    AudioStreamBasicDescription format = {0};
    if (!SGAudioPipelineSourceFormat(&format) ||
        format.mSampleRate != SGDJAudioSampleRate ||
        format.mChannelsPerFrame != 2 ||
        format.mFormatID != kAudioFormatLinearPCM ||
        format.mBitsPerChannel != 32 ||
        format.mBytesPerFrame != sizeof(float) ||
        !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
        !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved)) return false;

    bool boundary = SGAudioPipelineSourceCanReadAhead();
    atomic_store(&audio->boundarySupported, boundary);
    bool attached = SGAudioPipelineSetSourceProcessor(process, audio);
    if (attached) SGLog(@"dj audio: attached, verified boundary read-ahead %@", boundary ? @"available" : @"unavailable");
    return attached;
}

void SGDJAudioDetach(SGDJAudio *audio) {
    if (!audio) return;
    if (SGAudioPipelineClearSourceProcessor(audio)) SGLog(@"dj audio: detached");
}

bool SGDJAudioAttached(SGDJAudio *audio) {
    return audio && SGAudioPipelineSourceProcessorAttached(audio);
}
bool SGDJAudioBoundarySupported(SGDJAudio *audio) {
    return audio && atomic_load(&audio->boundarySupported);
}

void SGDJAudioSetTrack(SGDJAudio *audio, uint64_t track, uint64_t sourceFrame) {
    if (!audio) return;
    publishTrack(audio, track, sourceFrame);
    audio->audibleTrack = track;
    audio->audibleFrame = sourceFrame;
}
void SGDJAudioExpectTrack(SGDJAudio *audio, uint64_t track) {
    if (!audio) return;
    atomic_store_explicit(&audio->expectedTrack, track, memory_order_release);
}
uint64_t SGDJAudioCurrentTrack(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->track, memory_order_acquire) : 0;
}
uint64_t SGDJAudioCurrentFrame(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->sourceFrame, memory_order_acquire) : 0;
}

void SGDJAudioSetPlan(SGDJAudio *audio, SGDJMixPlan plan) {
    if (!audio) return;
    atomic_fetch_add_explicit(&audio->planSequence, 1, memory_order_acq_rel);
    atomic_store_explicit(&audio->planOutgoingTrack, plan.outgoingTrack, memory_order_relaxed);
    atomic_store_explicit(&audio->planIncomingTrack, plan.incomingTrack, memory_order_relaxed);
    atomic_store_explicit(&audio->planOutgoingStart, plan.outgoingStartFrame, memory_order_relaxed);
    atomic_store_explicit(&audio->planOutgoingEnd, plan.outgoingEndFrame, memory_order_relaxed);
    atomic_store_explicit(&audio->planIncomingFrames, plan.incomingFrames, memory_order_relaxed);
    atomic_store_explicit(&audio->planPrefetchStart, plan.prefetchStartFrame, memory_order_relaxed);
    atomic_store_explicit(&audio->planOverlapFrames, plan.overlapFrames, memory_order_relaxed);
    atomic_store_explicit(&audio->planIncomingCue, plan.incomingCueFrame, memory_order_relaxed);
    atomic_store_explicit(&audio->planRecipe, plan.recipe, memory_order_relaxed);
    atomic_store_explicit(&audio->planStrengthBits, bitsOfFloat(plan.strength), memory_order_relaxed);
    atomic_store_explicit(&audio->planBuffered, plan.bufferedOverlap ? 1u : 0u, memory_order_relaxed);
    atomic_store_explicit(&audio->planARateBits, bitsOfFloat(plan.deckARate > 0 ? plan.deckARate : 1), memory_order_relaxed);
    atomic_store_explicit(&audio->planBRateBits, bitsOfFloat(plan.deckBRate > 0 ? plan.deckBRate : 1), memory_order_relaxed);
    atomic_fetch_add_explicit(&audio->planSequence, 1, memory_order_release);
}

void SGDJAudioClearPlan(SGDJAudio *audio) {
    SGDJMixPlan empty = {0};
    SGDJAudioSetPlan(audio, empty);
}
bool SGDJAudioBufferedMixActive(SGDJAudio *audio) {
    return audio && atomic_load_explicit(&audio->bufferedMixActive, memory_order_acquire);
}
bool SGDJAudioBufferedMixCompleted(SGDJAudio *audio) {
    return audio && atomic_load_explicit(&audio->bufferedMixCompleted, memory_order_acquire);
}
uint64_t SGDJAudioBufferedOverlapFrames(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->bufferedOverlapFrames, memory_order_relaxed) : 0;
}
uint64_t SGDJAudioBufferedUnderruns(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->bufferedUnderruns, memory_order_relaxed) : 0;
}
bool SGDJAudioReadAnalysisPacket(SGDJAudio *audio, SGAudioStamp *stamp, float *pcm) {
    return audio && SGAudioRingRead(audio->analysis, stamp, pcm);
}
uint64_t SGDJAudioDroppedAnalysisPackets(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->dropped, memory_order_relaxed) : 0;
}
