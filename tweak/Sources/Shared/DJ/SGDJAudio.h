#pragma once
#import <Foundation/Foundation.h>
#import "Shared/Audio/SGAudioRingBuffer.h"
#include <stdbool.h>
#include <stdint.h>

enum { SGDJAudioSampleRate = 44100, SGDJAudioMaximumFrames = 4096 };

typedef NS_ENUM(uint32_t, SGDJRecipe) {
    SGDJRecipeCleanCut = 0,
    SGDJRecipeSmooth = 1,
    SGDJRecipeClub = 2,
    SGDJRecipeQuick = 3,
};

typedef struct {
    uint64_t outgoingTrack;
    uint64_t incomingTrack;
    uint64_t outgoingStartFrame;
    uint64_t outgoingEndFrame;
    uint64_t incomingFrames;
    SGDJRecipe recipe;
    float strength;

    // V2 buffered-deck plan. The source decoder is allowed to run ahead only through Spotify's
    // already verified queue. Audio not yet presented is retained locally so A and B can overlap.
    bool bufferedOverlap;
    uint64_t prefetchStartFrame;
    uint64_t overlapFrames;
    uint64_t incomingCueFrame;
    float deckARate;
    float deckBRate;
} SGDJMixPlan;

typedef struct SGDJAudio SGDJAudio;

SGDJAudio *SGDJAudioCreate(void);
void SGDJAudioDestroy(SGDJAudio *audio);

// Off-render control. The processor is a transparent pass-through when no transition plan is active.
bool SGDJAudioAttach(SGDJAudio *audio);
void SGDJAudioDetach(SGDJAudio *audio);
bool SGDJAudioAttached(SGDJAudio *audio);
bool SGDJAudioBoundarySupported(SGDJAudio *audio);

void SGDJAudioSetTrack(SGDJAudio *audio, uint64_t track, uint64_t sourceFrame);
void SGDJAudioExpectTrack(SGDJAudio *audio, uint64_t track);
uint64_t SGDJAudioCurrentTrack(SGDJAudio *audio);
uint64_t SGDJAudioCurrentFrame(SGDJAudio *audio);

void SGDJAudioSetPlan(SGDJAudio *audio, SGDJMixPlan plan);
void SGDJAudioClearPlan(SGDJAudio *audio);

// V2 diagnostics. These are lock-free snapshots safe for the controller/settings page.
bool SGDJAudioBufferedMixActive(SGDJAudio *audio);
bool SGDJAudioBufferedMixCompleted(SGDJAudio *audio);
uint64_t SGDJAudioBufferedOverlapFrames(SGDJAudio *audio);
uint64_t SGDJAudioBufferedUnderruns(SGDJAudio *audio);

// Background analyzer consumer. Packets are untouched original Spotify PCM, interleaved stereo.
bool SGDJAudioReadAnalysisPacket(SGDJAudio *audio, SGAudioStamp *stamp, float *pcm);
uint64_t SGDJAudioDroppedAnalysisPackets(SGDJAudio *audio);
