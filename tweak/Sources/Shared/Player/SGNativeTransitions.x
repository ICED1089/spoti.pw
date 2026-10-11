// Synchronize Spotify's user-selected crossfade duration with the existing
// crossfade-enabled preference, if that setter exists on this app version.
// Does not touch remote configuration, subscription/account state or audio PCM.
// The beat-matched AutoMix core is not exposed by a supported public API.
#import "Core/SGCore.h"
#import "SGNativeTransitions.h"

@interface _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation : NSObject
- (void)setAudioCrossfade:(BOOL)enabled;
@end

%hook _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation
- (void)setAudioCrossfadeTime:(NSInteger)seconds {
    %orig;
    if (!SGFlag(SGKeyNativeCrossfadeSync, NO)) return;
    if (![self respondsToSelector:@selector(setAudioCrossfade:)]) return;
    // Only act after Spotify itself changes the user's crossfade-duration
    // preference. We never enable AutoMix or override the player's gate.
    [self setAudioCrossfade:(seconds > 0)];
    SGLog(@"transitions: Spotify crossfade duration %ld s, switch synchronized", (long)seconds);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation"]);
}
