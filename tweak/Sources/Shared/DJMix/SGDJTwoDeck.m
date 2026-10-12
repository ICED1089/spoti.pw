#include "SGDJTwoDeck.h"
#include "SGDJBeatPlan.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { kRenderBlock = 256 };
typedef struct {
    float *pcm; // interleaved stereo, allocated off render
    uint32_t capacity;
    _Atomic(uint64_t) written, consumed;
} SGDJDeckBuffer;
struct SGDJTwoDeck {
    SGDJDeckBuffer a, b;
    uint64_t overlap, cursor;
    uint64_t underruns;
    bool armed;
};

static bool createDeck(SGDJDeckBuffer *deck, uint32_t frames) {
    if (frames < 256 || frames > UINT32_MAX / (2 * sizeof(float))) return false;
    deck->pcm = calloc((size_t)frames * 2, sizeof(float));
    if (!deck->pcm) return false;
    deck->capacity = frames;
    return true;
}
SGDJTwoDeck *SGDJTwoDeckCreate(uint32_t capacityFrames) {
    SGDJTwoDeck *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    if (!createDeck(&m->a, capacityFrames) || !createDeck(&m->b, capacityFrames)) {
        SGDJTwoDeckDestroy(m);
        return NULL;
    }
    return m;
}
void SGDJTwoDeckDestroy(SGDJTwoDeck *m) {
    if (!m) return;
    free(m->a.pcm);
    free(m->b.pcm);
    free(m);
}
static uint64_t available(const SGDJDeckBuffer *deck) {
    uint64_t w = atomic_load_explicit(&deck->written, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&deck->consumed, memory_order_acquire);
    return w >= r ? w - r : 0;
}
uint64_t SGDJTwoDeckReadyA(const SGDJTwoDeck *m) { return m ? available(&m->a) : 0; }
uint64_t SGDJTwoDeckReadyB(const SGDJTwoDeck *m) { return m ? available(&m->b) : 0; }

static bool feed(SGDJDeckBuffer *deck, const float *pcm, uint32_t frames) {
    if (!deck || !deck->pcm || !pcm || !frames || frames > deck->capacity) return false;
    uint64_t w = atomic_load_explicit(&deck->written, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&deck->consumed, memory_order_acquire);
    if (w < r || w - r > deck->capacity || frames > deck->capacity - (w - r)) return false;
    uint32_t at = (uint32_t)(w % deck->capacity);
    uint32_t first = frames < deck->capacity - at ? frames : deck->capacity - at;
    memcpy(deck->pcm + (size_t)at * 2, pcm, (size_t)first * 2 * sizeof(float));
    if (first < frames)
        memcpy(deck->pcm, pcm + (size_t)first * 2, (size_t)(frames - first) * 2 * sizeof(float));
    atomic_store_explicit(&deck->written, w + frames, memory_order_release);
    return true;
}
bool SGDJTwoDeckFeedA(SGDJTwoDeck *m, const float *pcm, uint32_t n) { return m && feed(&m->a, pcm, n); }
bool SGDJTwoDeckFeedB(SGDJTwoDeck *m, const float *pcm, uint32_t n) { return m && feed(&m->b, pcm, n); }

bool SGDJTwoDeckArm(SGDJTwoDeck *m, uint64_t frames) {
    if (!m || m->armed || frames < 256 || frames > m->a.capacity ||
        SGDJTwoDeckReadyA(m) < frames || SGDJTwoDeckReadyB(m) < frames) return false;
    m->overlap = frames;
    m->cursor = 0;
    m->armed = true;
    return true;
}

bool SGDJTwoDeckRender(SGDJTwoDeck *m, float *left, float *right, uint32_t frames) {
    if (!m || !left || !right || !m->armed || !frames ||
        frames > m->overlap - m->cursor) return false;
    if (SGDJTwoDeckReadyA(m) < frames || SGDJTwoDeckReadyB(m) < frames) {
        ++m->underruns;
        return false; // no deck advanced, no output buffer modified
    }
    float a[kRenderBlock * 2], b[kRenderBlock * 2], result[kRenderBlock * 2];
    uint64_t ra = atomic_load_explicit(&m->a.consumed, memory_order_relaxed);
    uint64_t rb = atomic_load_explicit(&m->b.consumed, memory_order_relaxed);
    for (uint32_t done = 0; done < frames;) {
        uint32_t chunk = frames - done < kRenderBlock ? frames - done : kRenderBlock;
        for (uint32_t i = 0; i < chunk; i++) {
            size_t ai = (size_t)((ra + done + i) % m->a.capacity) * 2;
            size_t bi = (size_t)((rb + done + i) % m->b.capacity) * 2;
            a[i*2] = m->a.pcm[ai];
            a[i*2+1] = m->a.pcm[ai+1];
            b[i*2] = m->b.pcm[bi];
            b[i*2+1] = m->b.pcm[bi+1];
        }
        SGDJBeatMixStereo(a, b, result, chunk, m->cursor + done, m->overlap);
        for (uint32_t i = 0; i < chunk; ++i) {
            left[done+i] = result[i*2];
            right[done+i] = result[i*2+1];
        }
        done += chunk;
    }
    atomic_store_explicit(&m->a.consumed, ra + frames, memory_order_release);
    atomic_store_explicit(&m->b.consumed, rb + frames, memory_order_release);
    m->cursor += frames;
    if (m->cursor >= m->overlap) m->armed = false;
    return true;
}
uint64_t SGDJTwoDeckRendered(const SGDJTwoDeck *m) { return m ? m->cursor : 0; }
uint64_t SGDJTwoDeckUnderruns(const SGDJTwoDeck *m) { return m ? m->underruns : 0; }
void SGDJTwoDeckResetStopped(SGDJTwoDeck *m) {
    if (!m) return;
    m->armed = false;
    m->overlap = m->cursor = m->underruns = 0;
    atomic_store_explicit(&m->a.written, 0, memory_order_relaxed);
    atomic_store_explicit(&m->a.consumed, 0, memory_order_relaxed);
    atomic_store_explicit(&m->b.written, 0, memory_order_relaxed);
    atomic_store_explicit(&m->b.consumed, 0, memory_order_relaxed);
}
