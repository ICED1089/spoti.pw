#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Sing/SGSingController.h"
#import "SGDJ.h"
#import "SGDJAudio.h"
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#import <math.h>
#import <float.h>

NSString *const SGKeyDJEnabled = @"spotifyglass.dj.enabled";
NSString *const SGKeyDJIndicator = @"spotifyglass.dj.playerIndicator";
NSString *const SGKeyDJStyle = @"spotifyglass.dj.style";
NSString *const SGKeyDJIntensity = @"spotifyglass.dj.intensity";
NSNotificationName const SGDJStateDidChangeNotification = @"spotifyglass.dj.state";

static NSString *const kAnalysisCacheKey = @"spotifyglass.dj.analysis.v1";
static const NSInteger kAnalysisVersion = 1;
static const NSTimeInterval kTick = 0.10;
static const NSTimeInterval kCacheEvery = 5.0;
enum {
    kEnvelopeCapacity = 9000, // 90 seconds at 100 Hz
    kEnvelopeHop = 441,
    kKeyDownsample = 4,
    kKeyWindow = 4096,
    kKeyNotes = 36,
};

static atomic_int sg_state;

typedef struct {
    double bpm, bpmConfidence, beatPeriod, beatPhase, barPhase;
    NSInteger key;
    BOOL minor;
    double keyConfidence;
    double energy, introEnergy, outroEnergy, analyzedSeconds;
} SGDJAnalysisSnapshot;

static NSString *trackURI(SPTPlayerState *state) {
    return SGURIString(state.track.URI);
}
static BOOL isSong(NSString *uri) {
    return [uri hasPrefix:@"spotify:track:"];
}
static uint64_t hashURI(NSString *uri) {
    const char *text = uri.UTF8String;
    if (!text) return 0;
    uint64_t hash = 14695981039346656037ULL;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) hash = (hash ^ *p) * 1099511628211ULL;
    return hash ?: 1;
}
static NSString *nextURI(SPTPlayerState *state) {
    id next = [state respondsToSelector:@selector(future)] ? state.future.firstObject : nil;
    SPTPlayerOptions *options = [state respondsToSelector:@selector(options)] ? state.options : nil;
    if ([options respondsToSelector:@selector(repeatingTrack)] && options.repeatingTrack) next = state.track;
    NSString *uri = [next respondsToSelector:@selector(URI)] ? SGURIString([next URI]) : nil;
    return isSong(uri) ? uri : nil;
}
static double clampDouble(double value, double low, double high) {
    return value < low ? low : value > high ? high : value;
}

#pragma mark - lightweight local music analysis

@interface SGDJAccumulator : NSObject {
    uint64_t _track, _expectedFrame, _totalFrames;
    double _sumRMS;
    uint64_t _rmsCount;

    double _blockSquares;
    uint32_t _blockFrames;
    uint64_t _blockSourceFrame;
    float _movingEnergy, _previousRMS;
    float _flux[kEnvelopeCapacity];
    float _energy[kEnvelopeCapacity];
    uint64_t _envFrame[kEnvelopeCapacity];
    uint64_t _envTotal;

    double _introSum;
    uint64_t _introCount;

    float _keySamples[kKeyWindow];
    int _keyCount, _downsamplePhase;
    double _keyCoeff[kKeyNotes];
    double _chroma[12];
    uint64_t _keyWindows;
}
- (instancetype)initWithTrack:(uint64_t)track;
- (void)addStamp:(SGAudioStamp)stamp pcm:(const float *)pcm;
- (SGDJAnalysisSnapshot)snapshot;
@end

@implementation SGDJAccumulator

- (instancetype)initWithTrack:(uint64_t)track {
    if (!(self = [super init])) return nil;
    _track = track;
    const double rate = (double)SGDJAudioSampleRate / kKeyDownsample;
    for (int n = 0; n < kKeyNotes; n++) {
        int midi = 36 + n; // C2 through B4
        double frequency = 440.0 * pow(2.0, (midi - 69) / 12.0);
        _keyCoeff[n] = 2.0 * cos(2.0 * M_PI * frequency / rate);
    }
    return self;
}

- (void)resetRhythmAt:(uint64_t)frame {
    _blockSquares = 0;
    _blockFrames = 0;
    _blockSourceFrame = frame;
    _movingEnergy = 0;
    _previousRMS = 0;
    _envTotal = 0;
    _keyCount = 0;
    _downsamplePhase = 0;
}

- (void)analyzeKeyWindow {
    double mean = 0;
    for (int i = 0; i < kKeyWindow; i++) mean += _keySamples[i];
    mean /= kKeyWindow;

    for (int n = 0; n < kKeyNotes; n++) {
        double s1 = 0, s2 = 0, coefficient = _keyCoeff[n];
        for (int i = 0; i < kKeyWindow; i++) {
            // A simple Hann window keeps neighbouring notes from dominating the chroma.
            double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (kKeyWindow - 1));
            double sample = (_keySamples[i] - mean) * w;
            double s0 = sample + coefficient * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        double power = s1 * s1 + s2 * s2 - coefficient * s1 * s2;
        if (power > 0) _chroma[(36 + n) % 12] += sqrt(power);
    }
    _keyWindows++;
    _keyCount = 0;
}

- (void)addStamp:(SGAudioStamp)stamp pcm:(const float *)pcm {
    if (!pcm || stamp.track != _track || !stamp.frames) return;
    if (_expectedFrame && stamp.sourceFrame != _expectedFrame) [self resetRhythmAt:stamp.sourceFrame];
    if (!_expectedFrame && !_blockFrames) _blockSourceFrame = stamp.sourceFrame;

    for (uint32_t i = 0; i < stamp.frames; i++) {
        float mono = 0.5f * (pcm[i * 2] + pcm[i * 2 + 1]);
        _blockSquares += (double)mono * mono;
        _blockFrames++;
        _totalFrames++;

        if (stamp.sourceFrame + i < (uint64_t)SGDJAudioSampleRate * 15) {
            _introSum += fabs(mono);
            _introCount++;
        }

        if ((_downsamplePhase++ & (kKeyDownsample - 1)) == 0) {
            _keySamples[_keyCount++] = mono;
            if (_keyCount == kKeyWindow) [self analyzeKeyWindow];
        }

        if (_blockFrames == kEnvelopeHop) {
            float rms = (float)sqrt(_blockSquares / _blockFrames + 1e-12);
            if (_rmsCount == 0) _movingEnergy = rms;
            else _movingEnergy = _movingEnergy * 0.985f + rms * 0.015f;
            float rise = fmaxf(0, rms - _previousRMS);
            float above = fmaxf(0, rms - _movingEnergy);
            float onset = rise + above * 1.6f;

            uint64_t index = _envTotal % kEnvelopeCapacity;
            _flux[index] = onset;
            _energy[index] = rms;
            _envFrame[index] = _blockSourceFrame;
            _envTotal++;

            _sumRMS += rms;
            _rmsCount++;
            _previousRMS = rms;
            _blockSquares = 0;
            _blockFrames = 0;
            _blockSourceFrame = stamp.sourceFrame + i + 1;
        }
    }
    _expectedFrame = stamp.sourceFrame + stamp.frames;
}

- (float)fluxAtLogical:(int)logical count:(int)count {
    uint64_t first = _envTotal > (uint64_t)count ? _envTotal - count : 0;
    return _flux[(first + logical) % kEnvelopeCapacity];
}
- (float)energyAtLogical:(int)logical count:(int)count {
    uint64_t first = _envTotal > (uint64_t)count ? _envTotal - count : 0;
    return _energy[(first + logical) % kEnvelopeCapacity];
}
- (uint64_t)frameAtLogical:(int)logical count:(int)count {
    uint64_t first = _envTotal > (uint64_t)count ? _envTotal - count : 0;
    return _envFrame[(first + logical) % kEnvelopeCapacity];
}

- (SGDJAnalysisSnapshot)snapshot {
    SGDJAnalysisSnapshot result = {0};
    result.key = -1;
    result.energy = _rmsCount ? _sumRMS / _rmsCount : 0;
    result.introEnergy = _introCount ? _introSum / _introCount : 0;
    result.analyzedSeconds = _totalFrames / (double)SGDJAudioSampleRate;

    int count = (int)MIN(_envTotal, (uint64_t)kEnvelopeCapacity);
    int tail = MIN(count, 1500);
    if (tail) {
        double sum = 0;
        for (int i = count - tail; i < count; i++) sum += [self energyAtLogical:i count:count];
        result.outroEnergy = sum / tail;
    }

    if (count >= 1000) {
        // Normalized autocorrelation over 60–200 BPM. A minute is enough to be stable while
        // keeping a snapshot cheap; the ring itself retains 90 seconds for phase/outro work.
        int use = MIN(count, 6000);
        int base = count - use;
        double best = 0, second = 0;
        int bestLag = 0;
        for (int lag = 30; lag <= 100; lag++) {
            double ab = 0, aa = 0, bb = 0;
            for (int i = base + lag; i < count; i++) {
                double a = [self fluxAtLogical:i count:count];
                double b = [self fluxAtLogical:i - lag count:count];
                ab += a * b; aa += a * a; bb += b * b;
            }
            double score = ab / (sqrt(aa * bb) + 1e-12);
            if (score > best) { second = best; best = score; bestLag = lag; }
            else if (score > second) second = score;
        }

        if (bestLag) {
            double bpm = 6000.0 / bestLag;
            while (bpm < 80) bpm *= 2;
            while (bpm > 190) bpm /= 2;
            result.bpm = bpm;
            result.beatPeriod = 60.0 / bpm;
            result.bpmConfidence = clampDouble((best - 0.06) / 0.34, 0, 1);
            if (best - second < 0.015) result.bpmConfidence *= 0.72;

            int phaseLag = (int)llround(result.beatPeriod * 100.0);
            phaseLag = MAX(1, MIN(phaseLag, 100));
            double phaseBest = -1;
            int phase = 0;
            for (int offset = 0; offset < phaseLag; offset++) {
                double score = 0;
                for (int i = base + offset; i < count; i += phaseLag)
                    score += [self fluxAtLogical:i count:count];
                if (score > phaseBest) { phaseBest = score; phase = offset; }
            }

            int phaseIndex = base + phase;
            if (phaseIndex < count) {
                double absolute = [self frameAtLogical:phaseIndex count:count] / (double)SGDJAudioSampleRate;
                result.beatPhase = fmod(absolute, result.beatPeriod);
                if (result.beatPhase < 0) result.beatPhase += result.beatPeriod;

                int accent = 0;
                double accentBest = -1;
                for (int beat = 0; beat < 4; beat++) {
                    double score = 0;
                    for (int i = phaseIndex + beat * phaseLag; i < count; i += phaseLag * 4)
                        score += [self energyAtLogical:i count:count];
                    if (score > accentBest) { accentBest = score; accent = beat; }
                }
                double bar = result.beatPeriod * 4;
                result.barPhase = fmod(absolute + accent * result.beatPeriod, bar);
                if (result.barPhase < 0) result.barPhase += bar;
            }
        }
    }

    if (_keyWindows >= 4) {
        static const double major[12] = {6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88};
        static const double minor[12] = {6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17};
        double best = -DBL_MAX, second = -DBL_MAX;
        NSInteger bestRoot = -1;
        BOOL bestMinor = NO;
        for (NSInteger root = 0; root < 12; root++) {
            for (int mode = 0; mode < 2; mode++) {
                const double *profile = mode ? minor : major;
                double score = 0, normA = 0, normB = 0;
                for (int pc = 0; pc < 12; pc++) {
                    double a = _chroma[pc];
                    double b = profile[(pc - root + 12) % 12];
                    score += a * b; normA += a * a; normB += b * b;
                }
                score /= sqrt(normA * normB) + 1e-12;
                if (score > best) {
                    second = best; best = score; bestRoot = root; bestMinor = mode != 0;
                } else if (score > second) second = score;
            }
        }
        result.key = bestRoot;
        result.minor = bestMinor;
        result.keyConfidence = clampDouble((best - second) / 0.10, 0, 1);
    }
    return result;
}
@end

#pragma mark - key / Camelot helpers

static NSInteger camelotNumber(NSInteger root, BOOL minor) {
    static const NSInteger major[12] = {8,3,10,5,12,7,2,9,4,11,6,1};
    static const NSInteger minorMap[12] = {5,12,7,2,9,4,11,6,1,8,3,10};
    if (root < 0 || root >= 12) return 0;
    return minor ? minorMap[root] : major[root];
}
static NSString *camelotText(SGDJAnalysisSnapshot value) {
    NSInteger number = camelotNumber(value.key, value.minor);
    return number ? [NSString stringWithFormat:@"%ld%@", (long)number, value.minor ? @"A" : @"B"] : @"—";
}
static BOOL keysCompatible(SGDJAnalysisSnapshot a, SGDJAnalysisSnapshot b) {
    if (a.key < 0 || b.key < 0 || a.keyConfidence < 0.20 || b.keyConfidence < 0.20) return YES;
    NSInteger x = camelotNumber(a.key, a.minor), y = camelotNumber(b.key, b.minor);
    if (!x || !y) return YES;
    if (x == y) return YES;
    if (a.minor == b.minor && (labs(x - y) == 1 || labs(x - y) == 11)) return YES;
    return NO;
}

static NSString *recipeName(SGDJRecipe recipe) {
    switch (recipe) {
        case SGDJRecipeSmooth: return @"Smooth";
        case SGDJRecipeClub: return @"Club";
        case SGDJRecipeQuick: return @"Quick";
        default: return @"Clean Cut";
    }
}

#pragma mark - controller

@interface SGDJController : NSObject <SGPlayerStateObserver> {
    atomic_bool _analysisPending;
}
@property (nonatomic) SGDJAudio *audio;
@property (nonatomic) dispatch_queue_t analysisQueue;
@property (nonatomic) NSMutableDictionary<NSNumber *, SGDJAccumulator *> *analysis;
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *cache;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSString *track;
@property (nonatomic) NSString *nextTrack;
@property (nonatomic) uint64_t trackHash, nextHash;
@property (nonatomic) BOOL interrupted;
@property (nonatomic) BOOL planValid;
@property (nonatomic) uint64_t planTrack, planNext;
@property (nonatomic) double planStart, planEnd, incomingDuration, tempoRatio;
@property (nonatomic) SGDJRecipe planRecipe;
@property (nonatomic) NSString *planReason;
@property (nonatomic) BOOL tempoAdjusted;
@property (nonatomic) double savedSpeed;
@property (nonatomic) BOOL savedFollows;
@property (nonatomic) double lastPosition;
@property (nonatomic) CFTimeInterval lastTick, lastCache;
@property (nonatomic) NSString *lastPositionTrack;
- (void)configure;
- (void)reconcile;
- (NSString *)mixSummary;
- (NSString *)analysisSummary;
@end

static SGDJController *sg_controller;

static void publishState(SGDJState state) {
    if (!SGDJEnabled()) state = SGDJStateOff;
    SGDJState old = (SGDJState)atomic_exchange(&sg_state, state);
    if (old == state) return;
    SGLog(@"dj: state %ld -> %ld", (long)old, (long)state);
    [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
}

@implementation SGDJController

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _audio = SGDJAudioCreate();
    _analysisQueue = dispatch_queue_create("pw.spoti.dj.analysis", DISPATCH_QUEUE_SERIAL);
    _analysis = [NSMutableDictionary dictionary];
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kAnalysisCacheKey];
    _cache = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    atomic_init(&_analysisPending, false);

    SGAddPlayerStateObserver(self);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(route:) name:AVAudioSessionRouteChangeNotification object:nil];
    [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(thermal:) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(memory:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    if (_audio) SGDJAudioDestroy(_audio);
}

- (void)startTimer {
    if (_timer) return;
    __weak typeof(self) weak = self;
    _timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *timer) { [weak reconcile]; }];
    _timer.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    [_timer invalidate];
    _timer = nil;
}

- (void)scheduleAnalysis {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_analysisPending, &expected, true)) return;
    SGDJAudio *audio = _audio;
    dispatch_async(_analysisQueue, ^{
        float pcm[SGDJAudioMaximumFrames * 2];
        SGAudioStamp stamp;
        unsigned packets = 0;
        while (packets++ < 128 && SGDJAudioReadAnalysisPacket(audio, &stamp, pcm)) {
            if (!stamp.track) continue;
            NSNumber *key = @(stamp.track);
            SGDJAccumulator *acc = self.analysis[key];
            if (!acc) {
                acc = [[SGDJAccumulator alloc] initWithTrack:stamp.track];
                self.analysis[key] = acc;
                // Retain only a small live working set; the persistent cache holds old songs.
                if (self.analysis.count > 8) {
                    NSNumber *old = self.analysis.allKeys.firstObject;
                    if (![old isEqual:key]) [self.analysis removeObjectForKey:old];
                }
            }
            [acc addStamp:stamp pcm:pcm];
        }
        atomic_store(&self->_analysisPending, false);
    });
}

- (SGDJAnalysisSnapshot)liveSnapshot:(uint64_t)track {
    if (!track) return (SGDJAnalysisSnapshot){.key = -1};
    __block SGDJAnalysisSnapshot value = {.key = -1};
    dispatch_sync(_analysisQueue, ^{
        SGDJAccumulator *acc = self.analysis[@(track)];
        if (acc) value = [acc snapshot];
    });
    return value;
}

- (BOOL)cachedSnapshotForURI:(NSString *)uri into:(SGDJAnalysisSnapshot *)out {
    NSDictionary *d = uri ? _cache[uri] : nil;
    if (![d isKindOfClass:NSDictionary.class] || [d[@"v"] integerValue] != kAnalysisVersion) return NO;
    SGDJAnalysisSnapshot value = {
        .bpm = [d[@"bpm"] doubleValue],
        .bpmConfidence = [d[@"bpmC"] doubleValue],
        .beatPeriod = [d[@"beat"] doubleValue],
        .beatPhase = [d[@"phase"] doubleValue],
        .barPhase = [d[@"bar"] doubleValue],
        .key = [d[@"key"] integerValue],
        .minor = [d[@"minor"] boolValue],
        .keyConfidence = [d[@"keyC"] doubleValue],
        .energy = [d[@"energy"] doubleValue],
        .introEnergy = [d[@"intro"] doubleValue],
        .outroEnergy = [d[@"outro"] doubleValue],
        .analyzedSeconds = [d[@"seconds"] doubleValue],
    };
    if (out) *out = value;
    return YES;
}

- (void)storeSnapshot:(SGDJAnalysisSnapshot)value uri:(NSString *)uri duration:(double)duration {
    if (!uri.length || value.analyzedSeconds < 8) return;
    _cache[uri] = @{
        @"v": @(kAnalysisVersion),
        @"bpm": @(value.bpm), @"bpmC": @(value.bpmConfidence),
        @"beat": @(value.beatPeriod), @"phase": @(value.beatPhase), @"bar": @(value.barPhase),
        @"key": @(value.key), @"minor": @(value.minor), @"keyC": @(value.keyConfidence),
        @"energy": @(value.energy), @"intro": @(value.introEnergy), @"outro": @(value.outroEnergy),
        @"seconds": @(value.analyzedSeconds), @"duration": @(duration), @"updated": @([[NSDate date] timeIntervalSince1970]),
    };
    if (_cache.count > 300) {
        NSArray *keys = [_cache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"updated"] compare:b[@"updated"]];
        }];
        NSUInteger remove = _cache.count - 300;
        for (NSUInteger i = 0; i < remove && i < keys.count; i++) [_cache removeObjectForKey:keys[i]];
    }
    [NSUserDefaults.standardUserDefaults setObject:_cache forKey:kAnalysisCacheKey];
    SGLog(@"dj analysis: %016llx %.1f BPM (%.2f), %@ (%.2f), %.0f s, dropped %llu",
          (unsigned long long)hashURI(uri), value.bpm, value.bpmConfidence, camelotText(value), value.keyConfidence,
          value.analyzedSeconds, (unsigned long long)SGDJAudioDroppedAnalysisPackets(_audio));
}

- (SGDJAnalysisSnapshot)bestSnapshotForURI:(NSString *)uri hash:(uint64_t)track {
    SGDJAnalysisSnapshot live = [self liveSnapshot:track];
    SGDJAnalysisSnapshot cached = {.key = -1};
    BOOL hasCached = [self cachedSnapshotForURI:uri into:&cached];
    if (!hasCached) return live;
    if (live.analyzedSeconds < 10) return cached;
    if (cached.bpmConfidence > live.bpmConfidence + 0.15) live.bpm = cached.bpm, live.bpmConfidence = cached.bpmConfidence,
        live.beatPeriod = cached.beatPeriod, live.beatPhase = cached.beatPhase, live.barPhase = cached.barPhase;
    if (cached.keyConfidence > live.keyConfidence) live.key = cached.key, live.minor = cached.minor, live.keyConfidence = cached.keyConfidence;
    return live;
}

- (void)restoreTempo {
    if (!_tempoAdjusted) return;
    SGSetPlayerSpeed(_savedSpeed);
    if (_savedFollows) SGSetPlayerPitchFollowsSpeed(YES);
    _tempoAdjusted = NO;
    SGLog(@"dj: restored user speed %.2fx%@", _savedSpeed, _savedFollows ? @" and pitch-follow" : @"");
}

- (void)abortPlan:(NSString *)reason {
    if (_planValid) SGLog(@"dj: aborted %@ transition: %@", recipeName(_planRecipe), reason ?: @"state changed");
    [self restoreTempo];
    SGDJAudioClearPlan(_audio);
    _planValid = NO;
    _planTrack = _planNext = 0;
    _planReason = nil;
    if (SGDJEnabled()) publishState(SGDJStateIdle);
}

- (void)beginTempoIfNeeded {
    if (_tempoAdjusted || !_planValid || fabs(_tempoRatio - 1) < 0.005 || !SGPlayerSpeedAllowed()) return;
    _savedSpeed = SGPlayerSpeed();
    _savedFollows = SGPlayerPitchFollowsSpeed();
    if (_savedFollows) SGSetPlayerPitchFollowsSpeed(NO);
    SGSetPlayerSpeed(clampDouble(_savedSpeed * _tempoRatio, 0.5, 2.0));
    _tempoAdjusted = YES;
    SGLog(@"dj: tempo convergence %.3fx (user %.2fx)", _tempoRatio, _savedSpeed);
}

- (void)buildPlanForState:(SPTPlayerState *)state {
    if (_planValid || !_trackHash || !_nextHash || state.duration <= 0) return;

    SGDJAnalysisSnapshot a = [self bestSnapshotForURI:_track hash:_trackHash];
    SGDJAnalysisSnapshot b = {.key = -1};
    BOOL bKnown = [self cachedSnapshotForURI:_nextTrack into:&b];

    NSInteger style = SGDJStyle();
    SGDJRecipe recipe = SGDJRecipeQuick;
    NSString *reason = nil;

    double bNorm = b.bpm;
    if (a.bpm > 0 && bNorm > 0) {
        while (bNorm / a.bpm > 1.45) bNorm /= 2;
        while (bNorm / a.bpm < 0.69) bNorm *= 2;
    }
    double bpmDistance = a.bpm > 0 && bNorm > 0 ? fabs(bNorm / a.bpm - 1) : 1;

    if (style == 1) recipe = SGDJRecipeSmooth;
    else if (style == 2) recipe = SGDJRecipeClub;
    else if (style == 3) recipe = SGDJRecipeQuick;
    else if (a.bpmConfidence < 0.18) {
        recipe = SGDJRecipeCleanCut;
        reason = @"low BPM confidence";
    } else if (!bKnown || b.bpmConfidence < 0.18) {
        recipe = SGDJRecipeQuick;
        reason = @"next track not cached yet";
    } else if (bpmDistance > 0.10 || !keysCompatible(a, b)) {
        recipe = bpmDistance > 0.16 ? SGDJRecipeCleanCut : SGDJRecipeQuick;
        reason = bpmDistance > 0.10 ? @"large BPM difference" : @"harmonic mismatch";
    } else if (SGDJIntensity() >= 2 && a.outroEnergy > 0.04 && b.introEnergy > 0.02) {
        recipe = SGDJRecipeClub;
    } else {
        recipe = SGDJRecipeSmooth;
    }

    double bpm = a.bpmConfidence >= 0.15 && a.bpm > 0 ? a.bpm : 120;
    double period = 60.0 / bpm;
    NSInteger beats = recipe == SGDJRecipeSmooth ? 16 : recipe == SGDJRecipeClub ? 8 : recipe == SGDJRecipeQuick ? 4 : 1;
    double desired = beats * period;
    if (recipe == SGDJRecipeSmooth) desired = clampDouble(desired, 4.0, 12.0);
    else if (recipe == SGDJRecipeClub) desired = clampDouble(desired, 3.0, 8.0);
    else if (recipe == SGDJRecipeQuick) desired = clampDouble(desired, 1.4, 3.5);
    else desired = clampDouble(desired, 0.25, 0.8);

    double rawStart = MAX(0, state.duration - desired);
    double start = rawStart;
    if (a.bpmConfidence >= 0.22 && a.beatPeriod > 0) {
        double bar = a.beatPeriod * 4;
        double phase = a.barPhase;
        double aligned = phase + floor((rawStart - phase) / bar) * bar;
        double length = state.duration - aligned;
        if (aligned >= 0 && length >= desired * 0.65 && length <= desired * 1.65) start = aligned;
    }

    double incomingBPM = bKnown && b.bpmConfidence >= 0.15 && bNorm > 0 ? bNorm : bpm;
    NSInteger incomingBeats = recipe == SGDJRecipeSmooth ? 8 : recipe == SGDJRecipeClub ? 8 : recipe == SGDJRecipeQuick ? 2 : 1;
    double incoming = incomingBeats * 60.0 / incomingBPM;
    incoming = clampDouble(incoming, recipe == SGDJRecipeCleanCut ? 0.18 : 0.7, 6.0);

    double ratio = 1;
    if (a.bpmConfidence >= 0.25 && bKnown && b.bpmConfidence >= 0.25 && a.bpm > 0 && bNorm > 0) {
        double wanted = bNorm / a.bpm;
        double limit = SGDJIntensity() == 0 ? 0.03 : SGDJIntensity() == 2 ? 0.07 : 0.05;
        if (fabs(wanted - 1) <= limit && recipe != SGDJRecipeCleanCut) ratio = wanted;
        else if (!reason && fabs(wanted - 1) > limit) reason = @"tempo stretch outside quality limit";
    }

    float strength = SGDJIntensity() == 0 ? 0.72f : SGDJIntensity() == 2 ? 1.18f : 1.0f;
    SGDJMixPlan plan = {
        .outgoingTrack = _trackHash, .incomingTrack = _nextHash,
        .outgoingStartFrame = (uint64_t)llround(start * SGDJAudioSampleRate),
        .outgoingEndFrame = (uint64_t)llround(state.duration * SGDJAudioSampleRate),
        .incomingFrames = (uint64_t)llround(incoming * SGDJAudioSampleRate),
        .recipe = recipe, .strength = strength,
    };
    SGDJAudioSetPlan(_audio, plan);

    _planValid = YES;
    _planTrack = _trackHash;
    _planNext = _nextHash;
    _planStart = start;
    _planEnd = state.duration;
    _incomingDuration = incoming;
    _tempoRatio = ratio;
    _planRecipe = recipe;
    _planReason = reason;

    SGLog(@"dj plan: A %016llx %.1f BPM/%.2f %@/%.2f -> B %016llx %.1f BPM/%.2f %@/%.2f; %@ %.2f-%.2f s, in %.2f s, tempo %.3f, boundary %@%@",
          (unsigned long long)_trackHash, a.bpm, a.bpmConfidence, camelotText(a), a.keyConfidence,
          (unsigned long long)_nextHash, b.bpm, b.bpmConfidence, camelotText(b), b.keyConfidence,
          recipeName(recipe), start, state.duration, incoming, ratio,
          SGDJAudioBoundarySupported(_audio) ? @"verified" : @"state-driven",
          reason ? [@"; fallback " stringByAppendingString:reason] : @"");
    publishState(SGDJStatePreparing);
}

- (void)updateTrackFromState:(SPTPlayerState *)state {
    NSString *uri = trackURI(state);
    NSString *next = nextURI(state);
    uint64_t hash = hashURI(uri), nextHash = hashURI(next);

    if (![_track isEqualToString:uri]) {
        NSString *oldURI = _track;
        uint64_t oldHash = _trackHash;
        if (oldURI.length && oldHash) {
            SGDJAnalysisSnapshot final = [self liveSnapshot:oldHash];
            [self storeSnapshot:final uri:oldURI duration:0];
        }

        BOOL expected = _planValid && hash && hash == _planNext;
        if (_planValid && !expected) [self abortPlan:@"queue/track changed"];
        if (expected) [self restoreTempo];

        _track = uri;
        _trackHash = hash;
        _nextTrack = next;
        _nextHash = nextHash;

        uint64_t audioTrack = SGDJAudioCurrentTrack(_audio);
        if (hash && audioTrack != hash) SGDJAudioSetTrack(_audio, hash, (uint64_t)llround(MAX(0, state.position) * SGDJAudioSampleRate));
        SGDJAudioExpectTrack(_audio, nextHash);

        _lastPositionTrack = uri;
        _lastPosition = state.position;
        _lastTick = CACurrentMediaTime();

        if (expected) {
            SGLog(@"dj: incoming track %016llx entered %@ transition", (unsigned long long)hash, recipeName(_planRecipe));
            publishState(SGDJStateTransition);
        } else if (SGDJEnabled()) {
            publishState(SGDJStateIdle);
        }
        return;
    }

    if (![_nextTrack isEqualToString:next]) {
        if (_planValid && _planTrack == hash && _planNext != nextHash) [self abortPlan:@"next track changed"];
        _nextTrack = next;
        _nextHash = nextHash;
        SGDJAudioExpectTrack(_audio, nextHash);
    }
}

- (void)ensureAttached:(SPTPlayerState *)state {
    if (!state || !isSong(trackURI(state)) || _interrupted ||
        NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) return;
    if (SGDJAudioAttached(_audio)) return;
    if (!SGAudioPipelineAvailable()) return;

    uint64_t audioTrack = SGDJAudioCurrentTrack(_audio);
    if (!audioTrack) SGDJAudioSetTrack(_audio, _trackHash, (uint64_t)llround(MAX(0, state.position) * SGDJAudioSampleRate));
    SGDJAudioExpectTrack(_audio, _nextHash);
    if (!SGDJAudioAttach(_audio)) {
        static NSUInteger logged;
        if (logged++ < 5) SGLog(@"dj: waiting for supported local 44.1 kHz stereo source");
    }
}

- (void)configure {
    if (!SGDJEnabled()) {
        [self abortPlan:@"DJ Mix switched off"];
        SGDJAudioDetach(_audio);
        [self stopTimer];
        publishState(SGDJStateOff);
        return;
    }

    // DJ V1 owns the single source processor; Sing cannot safely own it at the same time.
    SGSingConfigure(NO);
    [self startTimer];
    [self reconcile];
}

- (void)reconcile {
    if (!SGDJEnabled()) { [self configure]; return; }
    SPTPlayerState *state = SGPlayerState();
    [self scheduleAnalysis];
    [self updateTrackFromState:state];
    [self ensureAttached:state];

    if (!state || !isSong(_track) || state.isLoading) {
        if (!_planValid) publishState(SGDJStateIdle);
        return;
    }

    // Detect a seek from the continuously computed player position rather than adding another
    // player command hook. Normal speed changes are accounted for in the expected movement.
    CFTimeInterval now = CACurrentMediaTime();
    if ([_lastPositionTrack isEqualToString:_track] && _lastTick > 0 && !state.isPaused) {
        double elapsed = now - _lastTick;
        double moved = state.position - _lastPosition;
        double expected = elapsed * MAX(0.25, SGPlayerSpeed());
        if (elapsed < 1.0 && fabs(moved - expected) > 2.5) {
            [self abortPlan:@"seek detected"];
            SGDJAudioSetTrack(_audio, _trackHash, (uint64_t)llround(MAX(0, state.position) * SGDJAudioSampleRate));
            SGDJAudioExpectTrack(_audio, _nextHash);
        }
    }
    _lastPosition = state.position;
    _lastTick = now;
    _lastPositionTrack = _track;

    // A verified source boundary can cross before the main-thread player state catches up.
    uint64_t audibleTrack = SGDJAudioCurrentTrack(_audio);
    if (_planValid && audibleTrack == _planNext && _trackHash == _planTrack) {
        [self restoreTempo];
        publishState(SGDJStateTransition);
    }

    if (_planValid && _trackHash == _planTrack) {
        if (state.position >= _planStart) {
            [self beginTempoIfNeeded];
            publishState(SGDJStateTransition);
        } else {
            publishState(SGDJStatePreparing);
        }
    } else if (_planValid && _trackHash == _planNext) {
        if (state.position >= _incomingDuration) {
            SGLog(@"dj: %@ transition complete; incoming %.2f s", recipeName(_planRecipe), state.position);
            SGDJAudioClearPlan(_audio);
            _planValid = NO;
            _planTrack = _planNext = 0;
            _planReason = nil;
            publishState(SGDJStateIdle);
        } else {
            publishState(SGDJStateTransition);
        }
    }

    if (!_planValid && _nextHash && state.duration > 0 && state.isPlaying && !state.isPaused) {
        SGDJAnalysisSnapshot a = [self bestSnapshotForURI:_track hash:_trackHash];
        double bpm = a.bpmConfidence >= 0.15 && a.bpm > 0 ? a.bpm : 120;
        double longest = 16 * 60.0 / bpm;
        double lead = clampDouble(longest + 4.0, 8.0, 18.0);
        if (state.duration - state.position <= lead) [self buildPlanForState:state];
    }

    if (now - _lastCache >= kCacheEvery && _trackHash && _track.length) {
        _lastCache = now;
        SGDJAnalysisSnapshot current = [self liveSnapshot:_trackHash];
        [self storeSnapshot:current uri:_track duration:state.duration];
        [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
    }
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateTrackFromState:state];
    [self reconcile];
}

- (void)route:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        SGLog(@"dj: route changed, rebuilding source processor");
        [self abortPlan:@"audio route changed"];
        SGDJAudioDetach(self.audio);
        [self reconcile];
    });
}

- (void)interruption:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.interrupted = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
        if (self.interrupted) {
            [self abortPlan:@"audio interruption"];
            SGDJAudioDetach(self.audio);
        }
        [self reconcile];
    });
}

- (void)thermal:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) {
            [self abortPlan:@"thermal pressure"];
            SGDJAudioDetach(self.audio);
            SGLog(@"dj: paused for thermal pressure");
        } else [self reconcile];
    });
}

- (void)memory:(NSNotification *)note {
    dispatch_async(_analysisQueue, ^{ [self.analysis removeAllObjects]; });
    SGLog(@"dj: released live analysis buffers for memory pressure");
}

- (NSString *)mixSummary {
    if (!SGDJEnabled()) return @"Off";
    if (_planValid) {
        NSString *tempo = fabs(_tempoRatio - 1) >= 0.005 ? [NSString stringWithFormat:@" · %.3f× tempo", _tempoRatio] : @"";
        return [NSString stringWithFormat:@"%@ · %.1f s%@", recipeName(_planRecipe), MAX(0, _planEnd - _planStart), tempo];
    }
    if (!SGDJAudioAttached(_audio)) return @"Waiting for audio";
    return _nextHash ? @"Ready for next track" : @"Ready";
}

- (NSString *)analysisSummary {
    if (!_trackHash) return @"No song";
    SGDJAnalysisSnapshot value = [self bestSnapshotForURI:_track hash:_trackHash];
    if (value.analyzedSeconds < 8) return [NSString stringWithFormat:@"Analyzing · %.0f s", value.analyzedSeconds];
    NSString *bpm = value.bpmConfidence >= 0.15 ? [NSString stringWithFormat:@"%.0f BPM", value.bpm] : @"BPM uncertain";
    NSString *key = value.keyConfidence >= 0.15 ? camelotText(value) : @"key uncertain";
    return [NSString stringWithFormat:@"%@ · %@ · %.0f s", bpm, key, value.analyzedSeconds];
}
@end

static SGDJController *controller(void) {
    if (!sg_controller) sg_controller = [SGDJController new];
    return sg_controller;
}

#pragma mark - public API

BOOL SGDJEnabled(void) {
    return SGFlag(SGKeyDJEnabled, NO);
}
BOOL SGDJIndicatorEnabled(void) {
    return SGFlag(SGKeyDJIndicator, YES);
}
NSInteger SGDJStyle(void) {
    return SGInt(SGKeyDJStyle, 0);
}
NSInteger SGDJIntensity(void) {
    return SGInt(SGKeyDJIntensity, 1);
}
NSString *SGDJStyleName(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"Auto", @"Smooth", @"Club", @"Quick"]; });
    NSInteger value = SGDJStyle();
    return value >= 0 && value < (NSInteger)names.count ? names[(NSUInteger)value] : names.firstObject;
}
NSString *SGDJIntensityName(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"Low", @"Normal", @"High"]; });
    NSInteger value = SGDJIntensity();
    return value >= 0 && value < (NSInteger)names.count ? names[(NSUInteger)value] : names[1];
}
SGDJState SGDJCurrentState(void) {
    return (SGDJState)atomic_load(&sg_state);
}
NSString *SGDJPlayerStatusText(void) {
    if (!SGDJEnabled() || !SGDJIndicatorEnabled()) return nil;
    switch (SGDJCurrentState()) {
        case SGDJStatePreparing: return @"DJ MIX · PREPARING";
        case SGDJStateTransition: return @"DJ MIX · TRANSITION";
        default: return nil;
    }
}
NSString *SGDJCurrentMixSummary(void) {
    return [controller() mixSummary];
}
NSString *SGDJAnalysisSummary(void) {
    return [controller() analysisSummary];
}
void SGDJRefreshConfiguration(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGDJRefreshConfiguration(); });
        return;
    }
    [controller() configure];
    [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
}

__attribute__((constructor))
static void SGDJInit(void) {
    atomic_store(&sg_state, SGDJEnabled() ? SGDJStateIdle : SGDJStateOff);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (SGDJEnabled()) [controller() configure];
    });
}
