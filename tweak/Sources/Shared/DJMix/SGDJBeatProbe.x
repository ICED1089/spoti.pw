// Passively observe Spotify's output once per completed render buffer and estimate rhythm
// off the audio thread. This module never calls the private decoder, reads future audio,
// installs a source processor, or changes Spotify's playback/entitlements.
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>
#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "SGDJBeatPlan.h"
#import "SGDJBeatProbe.h"

enum { kEnvelopeHz = 100, kRing = 8192, kWindow = 5500 };
static _Atomic(uint32_t) sg_onsets[kRing]; // float bits; atomic snapshots safe across wraparound
static atomic_uint_fast64_t sg_written;
static atomic_uint sg_epoch, sg_captureHop;
static atomic_bool sg_record, sg_formatGood;
static atomic_flag sg_writer = ATOMIC_FLAG_INIT;
static double sg_partialSquares; // only written under try-lock on audio callback
static uint32_t sg_partialFrames, sg_seenEpoch;

static void prepare(AudioUnit output) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    BOOL ok = output && AudioUnitGetProperty(output, kAudioUnitProperty_StreamFormat,
              kAudioUnitScope_Output, 0, &format, &size) == noErr &&
              format.mFormatID == kAudioFormatLinearPCM &&
              (format.mFormatFlags & kAudioFormatFlagIsFloat) &&
              format.mBitsPerChannel == 32 &&
              format.mSampleRate >= 40000 && format.mSampleRate <= 50000 &&
              format.mChannelsPerFrame >= 1 && format.mChannelsPerFrame <= 2;
    atomic_store(&sg_captureHop, ok ? (uint32_t)lround(format.mSampleRate / kEnvelopeHz) : 0);
    atomic_store(&sg_formatGood, ok);
}
static OSStatus observe(void *unused, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *timestamp, UInt32 bus,
                        UInt32 frames, AudioBufferList *data) {
    (void)unused; (void)timestamp;
    if (!atomic_load_explicit(&sg_record, memory_order_relaxed) ||
        !atomic_load_explicit(&sg_formatGood, memory_order_relaxed) ||
        !flags || (*flags & kAudioUnitRenderAction_OutputIsSilence) ||
        bus != 0 || !frames || !data || !data->mNumberBuffers) return noErr;
    // Try-lock only: never wait, allocate or call Objective-C on the render thread.
    if (atomic_flag_test_and_set_explicit(&sg_writer, memory_order_acquire)) return noErr;
    unsigned epoch = atomic_load_explicit(&sg_epoch, memory_order_relaxed);
    if (epoch != sg_seenEpoch) {
        sg_seenEpoch = epoch;
        sg_partialSquares = 0;
        sg_partialFrames = 0;
        atomic_store_explicit(&sg_written, 0, memory_order_release);
    }
    unsigned hop = atomic_load_explicit(&sg_captureHop, memory_order_relaxed);
    const AudioBuffer *left = &data->mBuffers[0];
    const AudioBuffer *right = data->mNumberBuffers > 1 ? &data->mBuffers[1] : NULL;
    BOOL planar = right && left->mNumberChannels == 1 && right->mNumberChannels == 1 &&
                  left->mDataByteSize >= frames * sizeof(float) &&
                  right->mDataByteSize >= frames * sizeof(float);
    BOOL mono = !right && left->mNumberChannels == 1 &&
                 left->mDataByteSize >= frames * sizeof(float);
    BOOL interleaved = !right && left->mNumberChannels == 2 &&
                        frames <= UINT32_MAX / (2 * sizeof(float)) &&
                        left->mDataByteSize >= frames * 2 * sizeof(float);
    if (hop && left->mData && (planar ? right->mData != NULL : (mono || interleaved))) {
        const float *a = left->mData;
        const float *b = planar ? right->mData : NULL;
        for (UInt32 i = 0; i < frames; i++) {
            const float v = planar ? (a[i] + b[i]) * .5f :
                            interleaved ? (a[i*2] + a[i*2+1]) * .5f : a[i];
            if (isfinite(v)) sg_partialSquares += (double)v * v;
            if (++sg_partialFrames == hop) {
                float rms = (float)sqrt(sg_partialSquares / hop);
                uint32_t bits;
                memcpy(&bits, &rms, sizeof bits);
                uint64_t index = atomic_load_explicit(&sg_written, memory_order_relaxed);
                atomic_store_explicit(&sg_onsets[index % kRing], bits, memory_order_relaxed);
                atomic_store_explicit(&sg_written, index + 1, memory_order_release);
                sg_partialFrames = 0;
                sg_partialSquares = 0;
            }
        }
    }
    atomic_flag_clear_explicit(&sg_writer, memory_order_release);
    return noErr;
}
static const SGAudioProcessor sg_processor = {prepare, observe};

static NSString *hashURI(NSString *uri) {
    if (!uri.length) return nil;
    uint64_t hash = UINT64_C(14695981039346656037);
    const unsigned char *bytes = (const unsigned char *)uri.UTF8String;
    for (; *bytes; ++bytes) hash = (hash ^ *bytes) * UINT64_C(1099511628211);
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}
static SGDJBeatGrid gridFrom(id object) {
    if (![object isKindOfClass:NSDictionary.class]) return (SGDJBeatGrid){0};
    NSDictionary *entry = object;
    return (SGDJBeatGrid){
        .bpm = [entry[@"bpm"] doubleValue],
        .confidence = [entry[@"confidence"] doubleValue],
        .downbeatSeconds = [entry[@"phase"] doubleValue],
        .beatsPerBar = 4
    };
}

@interface SGDJBeatObserver : NSObject <SGPlayerStateObserver>
@end
@implementation SGDJBeatObserver {
    NSString *_current, *_next, *_lastPair;
    double _capturedAt;
    uint64_t _lastAnalyzed;
    unsigned _activeEpoch;
    BOOL _analyzing, _capturing;
    NSMutableDictionary *_cache;
    NSTimer *_timer;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"spotifyglass.djmix.beats.v1"];
    _cache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    _timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(tick)
                                            userInfo:nil repeats:YES];
    return self;
}
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    NSString *upcoming = nil;
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    id candidate = [future isKindOfClass:NSArray.class] ? [(NSArray *)future firstObject] : nil;
    if ([candidate respondsToSelector:@selector(URI)]) upcoming = SGURIString([candidate URI]);
    if (![_current isEqualToString:uri]) {
        _current = [uri copy];
        _capturedAt = fmax(0, state.position);
        _lastAnalyzed = 0;
        _activeEpoch = atomic_fetch_add_explicit(&sg_epoch, 1, memory_order_acq_rel) + 1;
        _lastPair = nil;
    }
    if (![_next isEqualToString:upcoming]) { _next = [upcoming copy]; _lastPair = nil; }
}
- (void)tick {
    SPTPlayerState *state = SGPlayerState();
    if (!state) return;
    [self playerStateDidChange:state];
    BOOL enabled = SGFlag(SGKeyDJBeatProbe, NO) &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        !NSProcessInfo.processInfo.lowPowerModeEnabled && state.isPlaying && !state.isPaused &&
        [_current hasPrefix:@"spotify:track:"];
    if (enabled && !_capturing) {
        // The initial tick may arrive seconds after the player named the track:
        // reset so captured envelope seconds correspond to the actual Spotify clock.
        _capturedAt = fmax(0, state.position);
        _lastAnalyzed = 0;
        _activeEpoch = atomic_fetch_add_explicit(&sg_epoch, 1, memory_order_acq_rel) + 1;
    }
    _capturing = enabled;
    atomic_store(&sg_record, enabled);
    if (!enabled || _analyzing || !atomic_load(&sg_formatGood)) return;
    uint64_t produced = atomic_load_explicit(&sg_written, memory_order_acquire);
    if (produced < 18 * kEnvelopeHz || produced < _lastAnalyzed + 500) return;
    uint64_t length = MIN((uint64_t)kWindow, produced);
    // The consumer copies a stable bounded window; ring entries are atomic,
    // and a changed track epoch invalidates results before publishing.
    NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)length * sizeof(float)];
    float *values = bytes.mutableBytes;
    for (uint64_t i = 0; i < length; i++) {
        uint32_t bits = atomic_load_explicit(&sg_onsets[(produced - length + i) % kRing], memory_order_relaxed);
        memcpy(&values[i], &bits, sizeof bits);
    }
    _analyzing = YES;
    _lastAnalyzed = produced;
    NSString *uri = [_current copy], *next = [_next copy];
    unsigned epoch = _activeEpoch;
    double origin = _capturedAt + (produced - length) / (double)kEnvelopeHz;
    __weak SGDJBeatObserver *weakSelf = self;
    NSData *snapshot = [bytes copy]; // retain the bytes until the utility worker is done
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SGDJBeatGrid grid = SGDJBeatDetect(snapshot.bytes, (size_t)length, kEnvelopeHz);
        if (grid.bpm > 0) grid.downbeatSeconds += origin;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGDJBeatObserver *self = weakSelf;
            if (!self) return;
            self->_analyzing = NO;
            if (epoch != self->_activeEpoch || ![self->_current isEqualToString:uri]) return;
            if (grid.confidence < 0.35) return;
            NSString *key = hashURI(uri);
            if (!key) return;
            self->_cache[key] = @{
                @"bpm": @(grid.bpm), @"confidence": @(grid.confidence),
                @"phase": @(grid.downbeatSeconds), @"updated": @([[NSDate date] timeIntervalSince1970])
            };
            if (self->_cache.count > 100) {
                NSArray *sorted = [self->_cache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [a[@"updated"] compare:b[@"updated"]];
                }];
                for (NSUInteger i = 0; i < sorted.count - 100; ++i)
                    [self->_cache removeObjectForKey:sorted[i]];
            }
            [NSUserDefaults.standardUserDefaults setObject:self->_cache forKey:@"spotifyglass.djmix.beats.v1"];
            SGLog(@"dj lab: local tempo %.1f BPM confidence %.2f, next grid %@, PCM2 not available",
                  grid.bpm, grid.confidence, self->_cache[hashURI(next)] ? @"cached" : @"unknown");
            NSString *pair = [NSString stringWithFormat:@"%@|%@", key, hashURI(next) ?: @""];
            if ([pair isEqualToString:self->_lastPair]) return;
            self->_lastPair = pair;
            SGDJBeatGrid b = gridFrom(self->_cache[hashURI(next)]);
            SGDJBeatReadiness input = {
                .durationA = state.duration, .positionA = state.position,
                .localPlayback = SGAudioPipelineTapped(), .independentStreams = false
            };
            SGDJBeatPlan plan = SGDJBeatPlanBuild(grid, b, input);
            SGLog(@"dj lab: planned pair status %d (0=ready; 1=no second PCM), B BPM %.1f, safe %@", 
                  (int)plan.status, b.bpm, plan.ready ? @"yes" : @"no");
        });
    });
}
@end
static SGDJBeatObserver *sg_observer;

%ctor {
    // No timer, audio tap or hot-path cost when the feature is off. Switching on
    // requires a restart so the central audio pipeline installs our fixed slot.
    if (!SGFlag(SGKeyDJBeatProbe, NO)) return;
    SGAudioPipelineRegister(SGAudioStageDJProbe, &sg_processor);
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_observer = [SGDJBeatObserver new];
        SGAddPlayerStateObserver(sg_observer);
        [sg_observer playerStateDidChange:SGPlayerState()];
    });
}
