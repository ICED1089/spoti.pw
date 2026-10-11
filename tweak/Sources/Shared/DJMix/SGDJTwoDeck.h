// Independent, bounded, two-deck PCM staging buffer for DJ Mix experiments.
// No Spotify decode, no playback hooks. Only feed with authorized, independently
// decoded/pre-stretched stereo PCM from TWO sources. Stop render before reset/free.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SGDJTwoDeck SGDJTwoDeck;

// Capacity in decoded stereo frames, fixed at creation (do not allocate on audio thread).
SGDJTwoDeck *SGDJTwoDeckCreate(uint32_t capacityFrames);
void SGDJTwoDeckDestroy(SGDJTwoDeck *mixer);

// Single producer for each deck, not called on the render thread.
bool SGDJTwoDeckFeedA(SGDJTwoDeck *mixer, const float *interleaved, uint32_t frames);
bool SGDJTwoDeckFeedB(SGDJTwoDeck *mixer, const float *interleaved, uint32_t frames);
uint64_t SGDJTwoDeckReadyA(const SGDJTwoDeck *mixer);
uint64_t SGDJTwoDeckReadyB(const SGDJTwoDeck *mixer);

// Arm only after ALL overlap frames from both decks are genuinely available.
// Incoming B must already have had any pitch-preserving tempo match applied.
bool SGDJTwoDeckArm(SGDJTwoDeck *mixer, uint64_t overlapFrames);

// Render at most overlapFrames in total, output noninterleaved stereo.
// Returns false on underrun/unsupported buffer shape WITHOUT consuming either deck
// or partially writing output. No allocation, locks, logging or network activity.
bool SGDJTwoDeckRender(SGDJTwoDeck *mixer, float *left, float *right, uint32_t frames);

uint64_t SGDJTwoDeckRendered(const SGDJTwoDeck *mixer);
uint64_t SGDJTwoDeckUnderruns(const SGDJTwoDeck *mixer);
void SGDJTwoDeckResetStopped(SGDJTwoDeck *mixer);
