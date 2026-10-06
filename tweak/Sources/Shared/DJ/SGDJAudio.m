#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "SGDJAudio.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { kAnalysisPackets = 192 };

struct SGDJAudio {
    SGAudioRingBuffer *analysis;
    atomic_uint_fast64_t track, expectedTrack, sourceFrame, trackEpoch, dropped;
    atomic_bool boundarySupported;

    atomic_uint planSequence;
    atomic_uint_fast64_t planOutgoingTrack, planIncomingTrack;
    atomic_uint_fast64_t planOutgoingStart, planOutgoingEnd, planIncomingFrames;
    atomic_uint planRecipe, planStrengthBits;

    uint64_t renderTrack;
    float low[2];
    bool lowPrimed;
    float interleaved[SGDJAudioMaximumFrames * 2];
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
    uint32_t recipe;
    float strength;
} RenderPlan;

static bool readPlan(SGDJAudio *audio, RenderPlan *plan) {
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        unsigned before = atomic_load_explicit(&audio->planSequence, memory_order_acquire);
        if (before & 1) continue;
        RenderPlan value = {
            atomic_load_explicit(&audio->planOutgoingTrack, memory_order_relaxed),
            atomic_load_explicit(&audio->planIncomingTrack, memory_order_relaxed),
            atomic_load_explicit(&audio->planOutgoingStart, memory_order_relaxed),
            atomic_load_explicit(&audio->planOutgoingEnd, memory_order_relaxed),
            atomic_load_explicit(&audio->planIncomingFrames, memory_order_relaxed),
            atomic_load_explicit(&audio->planRecipe, memory_order_relaxed),
            floatOfBits(atomic_load_explicit(&audio->planStrengthBits, memory_order_relaxed)),
        };
        unsigned after = atomic_load_explicit(&audio->planSequence, memory_order_acquire);
        if (before == after && !(after & 1)) {
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

static void transitionShape(uint32_t recipe, bool incoming, float progress, float strength,
                            float *gain, float *lowGain) {
    progress = ease(progress);
    strength = fmaxf(0.5f, fminf(strength, 1.35f));

    float g = 1, low = 1;
    switch ((SGDJRecipe)recipe) {
        case SGDJRecipeSmooth:
            if (incoming) {
                g = 0.48f + 0.52f * progress;
                low = 0.25f + 0.75f * progress;
            } else {
                g = 1.0f - 0.48f * progress;
                low = 1.0f - 0.70f * progress;
            }
            break;
        case SGDJRecipeClub:
            if (incoming) {
                g = 0.62f + 0.38f * progress;
                low = 0.04f + 0.96f * progress;
            } else {
                g = 1.0f - 0.32f * progress;
                low = 1.0f - 0.94f * progress;
            }
            break;
        case SGDJRecipeQuick: {
            float q = incoming ? clamp01(progress * 1.8f) : clamp01((progress - 0.42f) / 0.58f);
            q = ease(q);
            if (incoming) {
                g = 0.28f + 0.72f * q;
                low = 0.28f + 0.72f * q;
            } else {
                g = 1.0f - 0.72f * q;
                low = 1.0f - 0.70f * q;
            }
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

    // Intensity scales the audible effect but never boosts above unity.
    *gain = 1.0f - (1.0f - g) * strength;
    *lowGain = 1.0f - (1.0f - low) * strength;
    *gain = fmaxf(0.12f, fminf(*gain, 1.0f));
    *lowGain = fmaxf(0.02f, fminf(*lowGain, 1.0f));
}

static void processDSP(SGDJAudio *audio, uint64_t track, uint64_t frame, UInt32 frames,
                       AudioBufferList *data) {
    RenderPlan plan;
    if (!readPlan(audio, &plan)) return;

    bool outgoing = plan.outgoingTrack && track == plan.outgoingTrack &&
                    plan.outgoingEnd > plan.outgoingStart &&
                    frame < plan.outgoingEnd && frame + frames > plan.outgoingStart;
    bool incoming = plan.incomingTrack && track == plan.incomingTrack &&
                    plan.incomingFrames && frame < plan.incomingFrames;
    if (!outgoing && !incoming) {
        audio->renderTrack = track;
        return;
    }

    if (audio->renderTrack != track) {
        audio->renderTrack = track;
        audio->low[0] = audio->low[1] = 0;
        audio->lowPrimed = false;
    }

    // 200 Hz one-pole split. low + (input-low) reconstructs the original exactly at lowGain 1.
    const float alpha = 1.0f - expf(-2.0f * (float)M_PI * 200.0f / SGDJAudioSampleRate);
    float *left = data->mBuffers[0].mData;
    float *right = data->mBuffers[1].mData;

    for (UInt32 i = 0; i < frames; i++) {
        uint64_t at = frame + i;
        float gain = 1, lowGain = 1;
        if (outgoing && at >= plan.outgoingStart && at < plan.outgoingEnd) {
            float p = (float)((double)(at - plan.outgoingStart) /
                              (double)(plan.outgoingEnd - plan.outgoingStart));
            transitionShape(plan.recipe, false, p, plan.strength, &gain, &lowGain);
        } else if (incoming && at < plan.incomingFrames) {
            float p = (float)((double)at / (double)plan.incomingFrames);
            transitionShape(plan.recipe, true, p, plan.strength, &gain, &lowGain);
        }

        float sample[2] = {left[i], right[i]};
        if (!audio->lowPrimed) {
            audio->low[0] = sample[0];
            audio->low[1] = sample[1];
            audio->lowPrimed = true;
        }
        for (unsigned c = 0; c < 2; c++) {
            audio->low[c] += alpha * (sample[c] - audio->low[c]);
            float high = sample[c] - audio->low[c];
            float out = (high + audio->low[c] * lowGain) * gain;
            if (c == 0) left[i] = out;
            else right[i] = out;
        }
    }
}

static OSStatus pullSegment(SGDJAudio *audio, UInt32 offset, UInt32 frames,
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
        audio->interleaved[i * 2] = ((float *)part.list.mBuffers[0].mData)[i];
        audio->interleaved[i * 2 + 1] = ((float *)part.list.mBuffers[1].mData)[i];
    }
    SGAudioStamp stamp = {epoch, track, frame, 1, frames};
    if (!SGAudioRingWrite(audio->analysis, stamp, audio->interleaved))
        atomic_fetch_add_explicit(&audio->dropped, 1, memory_order_relaxed);

    processDSP(audio, track, frame, frames, &part.list);

    if (epoch == atomic_load_explicit(&audio->trackEpoch, memory_order_acquire) &&
        track == atomic_load_explicit(&audio->track, memory_order_acquire)) {
        atomic_store_explicit(&audio->sourceFrame, frame + frames, memory_order_release);
    }
    return noErr;
}

static void crossBoundary(SGDJAudio *audio, uint64_t expected) {
    if (!expected) return;
    uint64_t currentExpected = expected;
    if (!atomic_compare_exchange_strong_explicit(&audio->expectedTrack, &currentExpected, 0,
                                                  memory_order_acq_rel, memory_order_relaxed)) return;
    publishTrack(audio, expected, 0);
    audio->renderTrack = 0;
    SGLog(@"dj audio: verified source boundary -> %016llx", (unsigned long long)expected);
}

static OSStatus process(void *context, UInt32 frames, AudioBufferList *data, const AudioTimeStamp *time) {
    SGDJAudio *audio = context;
    if (!audio || !data || data->mNumberBuffers != 2 || frames > UINT32_MAX / sizeof(float))
        return kAudio_ParamError;
    for (unsigned c = 0; c < 2; c++) {
        if (!data->mBuffers[c].mData || data->mBuffers[c].mNumberChannels != 1 ||
            data->mBuffers[c].mDataByteSize < frames * sizeof(float)) return kAudio_ParamError;
    }

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
            OSStatus status = pullSegment(audio, done, beforeBoundary, data, time);
            if (status != noErr) return status;
            done += beforeBoundary;
        }
        if (boundary) {
            crossBoundary(audio, expected);
            continue;
        }
    }
    return noErr;
}

SGDJAudio *SGDJAudioCreate(void) {
    SGDJAudio *audio = calloc(1, sizeof *audio);
    if (!audio) return NULL;
    audio->analysis = SGAudioRingCreate(kAnalysisPackets, SGDJAudioMaximumFrames, 2);
    if (!audio->analysis) {
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
    atomic_store_explicit(&audio->planRecipe, plan.recipe, memory_order_relaxed);
    atomic_store_explicit(&audio->planStrengthBits, bitsOfFloat(plan.strength), memory_order_relaxed);
    atomic_fetch_add_explicit(&audio->planSequence, 1, memory_order_release);
}

void SGDJAudioClearPlan(SGDJAudio *audio) {
    SGDJMixPlan empty = {0};
    SGDJAudioSetPlan(audio, empty);
}

bool SGDJAudioReadAnalysisPacket(SGDJAudio *audio, SGAudioStamp *stamp, float *pcm) {
    return audio && SGAudioRingRead(audio->analysis, stamp, pcm);
}

uint64_t SGDJAudioDroppedAnalysisPackets(SGDJAudio *audio) {
    return audio ? atomic_load_explicit(&audio->dropped, memory_order_relaxed) : 0;
}
