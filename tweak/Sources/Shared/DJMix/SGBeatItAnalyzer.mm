#import <Foundation/Foundation.h>
#include "SGBeatItAnalyzer.h"

#include "beatit/config.h"
#include "beatit/coreml_preset.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <string>
#include <vector>

static NSString *modelPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:
            [NSBundle.mainBundle pathForResource:@"SpotifyGlassDJ" ofType:@"bundle"] ?: @""];
        path = [[bundle resourcePath] stringByAppendingPathComponent:@"BeatThis_small0.mlpackage"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) path = nil;
    });
    return path;
}

static double median(std::vector<double> values) {
    if (values.empty()) return 0;
    const size_t middle = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + middle, values.end());
    double result = values[middle];
    if ((values.size() & 1) == 0) {
        std::nth_element(values.begin(), values.begin() + middle - 1, values.end());
        result = (result + values[middle - 1]) * 0.5;
    }
    return result;
}

bool SGBeatItAnalyze(const float *mono, uint32_t frames, double sampleRate, SGBeatItAnalysis *out) {
    if (out) *out = (SGBeatItAnalysis){0};
    NSString *path = modelPath();
    if (!mono || frames < (uint32_t)(sampleRate * 8) || sampleRate <= 0 || !path.length || !out) return false;

    @autoreleasepool {
        beatit::BeatitConfig config;
        std::unique_ptr<beatit::CoreMLPreset> preset = beatit::make_coreml_preset("beatthis");
        if (!preset) return false;
        preset->apply(config);
        // Use BeatIt's maintained model I/O names, preprocessing, DBN and phase settings.
        // This call analyzes one contiguous captured region, so sparse probing is handled by
        // our cache/capture policy rather than asking for unavailable future Spotify PCM.
        config.model_path = path.UTF8String;
        config.sparse_probe_mode = false;
        config.execution_target = beatit::BeatitConfig::ExecutionTarget::Auto;
        config.pad_final_window = true;
        config.log_verbosity = beatit::LogVerbosity::Error;

        std::vector<float> samples(mono, mono + frames);
        beatit::CoreMLResult result = beatit::analyze_with_coreml(samples, sampleRate, config, 0);

        const std::vector<unsigned long long> *beats = &result.beat_projected_sample_frames;
        const std::vector<unsigned long long> *beatFeatures = &result.beat_projected_feature_frames;
        if (beats->size() < 8) {
            beats = &result.beat_sample_frames;
            beatFeatures = &result.beat_feature_frames;
        }
        if (beats->size() < 8) return false;

        std::vector<double> intervals;
        intervals.reserve(beats->size() - 1);
        for (size_t i = 1; i < beats->size(); i++) {
            if ((*beats)[i] > (*beats)[i - 1])
                intervals.push_back(((*beats)[i] - (*beats)[i - 1]) / sampleRate);
        }
        double period = median(intervals);
        if (!(period > 0.25 && period < 1.0)) return false;

        // BeatIt's DBN grid is already tempo-normalized. Measure its residual jitter only as a
        // confidence signal; do not run another independent tempo detector on top of it.
        double mean = std::accumulate(intervals.begin(), intervals.end(), 0.0) / intervals.size();
        double variance = 0;
        for (double v : intervals) variance += (v - mean) * (v - mean);
        variance /= intervals.size();
        double cv = mean > 0 ? sqrt(variance) / mean : 1;

        double bpm = 60.0 / period;
        if (!(bpm >= 70 && bpm <= 180)) return false;

        double firstBeat = beats->front() / sampleRate;
        double beatPhase = fmod(firstBeat, period);
        if (beatPhase < 0) beatPhase += period;

        double barPhase = beatPhase;
        bool hasDownbeats = !result.downbeat_projected_feature_frames.empty();
        if (hasDownbeats && !beatFeatures->empty()) {
            unsigned long long firstDown = result.downbeat_projected_feature_frames.front();
            auto nearest = std::min_element(beatFeatures->begin(), beatFeatures->end(),
                [firstDown](unsigned long long a, unsigned long long b) {
                    return llabs((long long)a - (long long)firstDown) < llabs((long long)b - (long long)firstDown);
                });
            size_t index = (size_t)std::distance(beatFeatures->begin(), nearest);
            if (index < beats->size()) {
                double downbeat = (*beats)[index] / sampleRate;
                double bar = period * 4.0;
                barPhase = fmod(downbeat, bar);
                if (barPhase < 0) barPhase += bar;
            }
        }

        double countConfidence = std::min(1.0, beats->size() / 24.0);
        double regularity = std::max(0.0, 1.0 - cv * 8.0);
        double confidence = 0.45 + 0.40 * countConfidence + 0.15 * regularity;
        if (!hasDownbeats) confidence *= 0.88;

        out->bpm = bpm;
        out->confidence = std::max(0.0, std::min(0.99, confidence));
        out->beatPeriod = period;
        out->beatPhase = beatPhase;
        out->barPhase = barPhase;
        out->beatCount = (uint32_t)std::min<size_t>(UINT32_MAX, beats->size());
        out->downbeatCount = (uint32_t)std::min<size_t>(UINT32_MAX, result.downbeat_projected_feature_frames.size());
        out->hasDownbeats = hasDownbeats;
        return true;
    }
}
