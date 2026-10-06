#import "Core/SGCore.h"
#import "SGDJ.h"
#import <stdatomic.h>

NSString *const SGKeyDJEnabled = @"spotifyglass.dj.enabled";
NSString *const SGKeyDJIndicator = @"spotifyglass.dj.playerIndicator";
NSString *const SGKeyDJStyle = @"spotifyglass.dj.style";
NSString *const SGKeyDJIntensity = @"spotifyglass.dj.intensity";
NSNotificationName const SGDJStateDidChangeNotification = @"spotifyglass.dj.state";

static atomic_int sg_state = SGDJStateOff;

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

void SGDJSetState(SGDJState state) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGDJSetState(state); });
        return;
    }
    if (!SGDJEnabled()) state = SGDJStateOff;
    SGDJState old = (SGDJState)atomic_exchange(&sg_state, state);
    if (old == state) return;
    SGLog(@"dj: state %ld -> %ld", (long)old, (long)state);
    [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
}

void SGDJRefreshConfiguration(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGDJRefreshConfiguration(); });
        return;
    }
    SGDJSetState(SGDJEnabled() ? SGDJStateIdle : SGDJStateOff);
    [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
}

__attribute__((constructor))
static void SGDJInit(void) {
    atomic_store(&sg_state, SGDJEnabled() ? SGDJStateIdle : SGDJStateOff);
}
