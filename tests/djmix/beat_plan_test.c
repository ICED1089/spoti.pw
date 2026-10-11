// Host-side reproducible test: clang -std=c11 -x c SGDJBeatPlan.m beat_plan_test.c -lm
#include "../../tweak/Sources/Shared/DJMix/SGDJBeatPlan.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void require(int yes, const char *why) {
    if (!yes) { fprintf(stderr, "FAILED: %s\n", why); exit(1); }
}

static void test_beats(void) {
    enum { HZ = 100, SECONDS = 32, N = HZ * SECONDS };
    float *env = calloc(N, sizeof(float));
    require(env != NULL, "envelope allocation");
    // Synthetic metronome at 120 BPM, one attack every 50 envelope samples.
    for (int i = 0; i < N; ++i)
        env[i] = (i % 50 == 7) ? 1.0f : (i % 50 == 8 ? 0.4f : 0.01f);
    SGDJBeatGrid grid = SGDJBeatDetect(env, N, HZ);
    printf("120 bpm fixture: %.2f BPM confidence %.3f phase %.3f\n",
           grid.bpm, grid.confidence, grid.downbeatSeconds);
    require(fabs(grid.bpm - 120) < 1.0, "detect 120 BPM");
    require(grid.confidence >= 0.35, "metronome should be confident");
    for (int i = 0; i < N; ++i) env[i] = .25f;
    grid = SGDJBeatDetect(env, N, HZ);
    require(grid.bpm == 0, "do not invent tempo from constant signal");
    free(env);
}

static void test_planner(void) {
    SGDJBeatGrid a = {120, .85, 0, 4}, b = {120, .83, 0, 4};
    SGDJBeatReadiness ready = {
        .durationA = 200, .positionA = 191, .bufferedA = 14,
        .bufferedB = 9, .independentStreams = true,
        .localPlayback = true, .pitchPreservingStretch = true
    };
    SGDJBeatPlan p = SGDJBeatPlanBuild(a, b, ready);
    require(p.ready && p.beatMatched && p.status == SGDJPlanReady, "two good buffered decks");
    require(p.startA >= 191 && p.startA + p.overlap <= 200.01, "outgoing phrase in range");
    require(fabs(p.speedB - 1.0) < .0001, "identical BPM no resample needed");

    ready.independentStreams = false;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(!p.ready && p.status == SGDJPlanUnsupported, "one stream must never mix");
    ready.independentStreams = true;
    ready.bufferedB = .3;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(!p.ready && p.status == SGDJPlanInsufficientB, "incoming PCM must be buffered");
    ready.bufferedB = 9;
    ready.seeksOrRouteChanging = true;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(!p.ready && p.status == SGDJPlanPlaybackChanged, "fail closed on seek");
    ready.seeksOrRouteChanging = false;

    b.bpm = 150;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(!p.ready && p.status == SGDJPlanTempoMismatch, "far-tempo guarded");
    b.bpm = 118;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(p.ready && fabs(p.speedB - (120.0 / 118.0)) < 1e-7, "pitch-safe B rate");
    ready.pitchPreservingStretch = false;
    p = SGDJBeatPlanBuild(a, b, ready);
    require(p.ready && p.overlap < 2, "no stretch => short low-drift transition");
}

static void test_mixer(void) {
    enum { N = 1024 };
    float a[N * 2], b[N * 2], joined[N * 2], chunked[N * 2];
    for (int i = 0; i < N * 2; ++i) { a[i] = .7f; b[i] = -.3f; }
    SGDJBeatMixStereo(a, b, joined, N, 0, N);
    SGDJBeatMixStereo(a, b, chunked, 512, 0, N);
    SGDJBeatMixStereo(a + 1024, b + 1024, chunked + 1024, 512, 512, N);
    require(fabs(joined[0] - .7f) < 1e-6, "first sample equals A");
    require(fabs(joined[N * 2 - 1] + .3f) < 1e-6, "last sample equals B");
    for (int i = 0; i < N * 2; ++i) {
        require(isfinite(joined[i]) && fabs(joined[i]) <= 1, "finite, bounded PCM");
        require(fabs(joined[i] - chunked[i]) < 1e-6, "chunks sample-continuous");
    }
    float same[N * 2];
    for (int i = 0; i < N * 2; ++i) same[i] = a[i];
    SGDJBeatMixStereo(same, b, same, N, 0, N);
    for (int i = 0; i < N * 2; ++i) require(fabs(same[i] - joined[i]) < 1e-6, "in-place A supported");
}
int main(void) {
    test_beats();
    test_planner();
    test_mixer();
    puts("DJ beat plan and offline two-deck PCM mixer: PASS");
    return 0;
}
