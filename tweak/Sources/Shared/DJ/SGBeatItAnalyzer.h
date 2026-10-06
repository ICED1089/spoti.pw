#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    double bpm;
    double confidence;
    double beatPeriod;
    double beatPhase;
    double barPhase;
    uint32_t beatCount;
    uint32_t downbeatCount;
    bool hasDownbeats;
} SGBeatItAnalysis;

// Runs BeatIt's MIT-licensed Beat This! Core ML + DBN pipeline off the audio thread.
// Input is mono float PCM at the supplied sample rate. Returns false rather than guessing.
bool SGBeatItAnalyze(const float *mono, uint32_t frames, double sampleRate, SGBeatItAnalysis *out);
