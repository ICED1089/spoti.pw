#import "SGEeveeIntegration.h"
#import "SGLog.h"
#import <mach-o/dyld.h>
#import <objc/runtime.h>

static const NSInteger kEeveeDoNotReplaceLyrics = 4;

static void setJSONDefault(NSUserDefaults *defaults, NSString *key, id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (data) [defaults setObject:data forKey:key];
}

static NSDictionary *jsonDefault(NSUserDefaults *defaults, NSString *key) {
    NSData *data = [defaults dataForKey:key];
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

BOOL SGEeveePresent(void) {
    if (objc_getClass("_TtC12EeveeSpotify27EeveeSettingsViewController")) return YES;
    for (uint32_t i = 0, count = _dyld_image_count(); i < count; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *name = [[[NSString stringWithUTF8String:raw] lastPathComponent] lowercaseString];
        if ([name containsString:@"eevee"]) return YES;
    }
    return NO;
}

void SGEeveeApplyIntegration(void) {
    if (!SGEeveePresent()) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    // Lyrics belong to spoti.pw. Eevee raw value 4 means "Do Not Replace Lyrics".
    [defaults setInteger:kEeveeDoNotReplaceLyrics forKey:@"lyricsSource"];

    // Eevee's visual layer is deliberately inactive in the combined build.
    setJSONDefault(defaults, @"eeveeLiquidGlassOptions", @{
        @"enabled": @NO,
        @"spotifyGlass": @NO,
        @"tabBar": @NO,
        @"nowPlayingBar": @NO,
        @"newPlayerDesign": @NO
    });
    setJSONDefault(defaults, @"eeveeNowPlayingBarOptions", @{
        @"albumTint": @NO,
        @"roundArtwork": @NO,
        @"hideConnect": @NO
    });
    setJSONDefault(defaults, @"eeveePlayerOptions", @{
        @"backdrop": @NO,
        @"glassLyricsCard": @NO,
        @"hidden": @[]
    });
    setJSONDefault(defaults, @"eeveePlayerExtrasOptions", @{
        @"doubleTap": @"off",
        @"threeZones": @YES,
        @"haptics": @NO
    });
    setJSONDefault(defaults, @"eeveePlaylistOptions", @{
        @"fullCover": @NO,
        @"dividers": @NO,
        @"hideFind": @NO,
        @"hidden": @[]
    });
    setJSONDefault(defaults, @"eeveeHomeGradient", @{
        @"enabled": @NO,
        @"strength": @1,
        @"height": @1
    });
    setJSONDefault(defaults, @"eeveeHomeHidden", @[]);
    setJSONDefault(defaults, @"eeveeArtistHidden", @[]);

    [defaults setBool:NO forKey:@"eeveeAmoled"];
    [defaults removeObjectForKey:@"eeveeAccent"];
    [defaults setBool:NO forKey:@"eeveeRoundedArtwork"];

    // Clear values Spotify/Eevee leave behind when Eevee Liquid Glass had previously been enabled.
    [defaults removeObjectForKey:@"LiquidGlassOverride"];
    [defaults removeObjectForKey:@"com.apple.SwiftUI.IgnoreSolariumOptOut"];

    // spoti.pw owns Spotify's remote flags. Keep Eevee's flag hook dormant.
    [defaults setObject:@{} forKey:@"eeveeFlagOverrides"];
    [defaults setBool:NO forKey:@"eeveeFlagCapture"];
    [defaults setBool:NO forKey:@"eeveeHideJam"];
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (spotify.length) [defaults setObject:spotify forKey:@"eeveeFlagCatalogVersion"];

    // Eevee owns telemetry/privacy in the combined build.
    [defaults setBool:YES forKey:@"eeveeBlockTelemetry"];

    SGLog(@"Eevee integration: spoti.pw owns UI/player/lyrics/flags; Eevee owns Premium/ads/privacy");
}

BOOL SGEeveeIntegrationConfigured(void) {
    if (!SGEeveePresent()) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *glass = jsonDefault(defaults, @"eeveeLiquidGlassOptions");
    NSDictionary *player = jsonDefault(defaults, @"eeveePlayerOptions");
    NSDictionary *extras = jsonDefault(defaults, @"eeveePlayerExtrasOptions");
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

    BOOL lyrics = [defaults integerForKey:@"lyricsSource"] == kEeveeDoNotReplaceLyrics;
    BOOL ui = [glass[@"enabled"] respondsToSelector:@selector(boolValue)] && ![glass[@"enabled"] boolValue];
    BOOL playerOff = [player[@"backdrop"] respondsToSelector:@selector(boolValue)] && ![player[@"backdrop"] boolValue];
    BOOL gesturesOff = [extras[@"doubleTap"] isEqual:@"off"] && ![extras[@"haptics"] boolValue];
    BOOL flagsOff = [[defaults dictionaryForKey:@"eeveeFlagOverrides"] count] == 0
        && (!spotify.length || [[defaults stringForKey:@"eeveeFlagCatalogVersion"] isEqualToString:spotify])
        && ![defaults boolForKey:@"eeveeHideJam"];
    BOOL privacy = [defaults boolForKey:@"eeveeBlockTelemetry"];
    return lyrics && ui && playerOff && gesturesOff && flagsOff && privacy;
}

NSString *SGEeveeIntegrationSummary(void) {
    if (!SGEeveePresent()) return @"Eevee not found";
    return SGEeveeIntegrationConfigured() ? @"Active" : @"Needs restart";
}

// This dylib is already inside the v0.23 IPA before Eevee is appended by the combined builder,
// so its constructor runs first and sets the launch-time values Eevee reads during its own init.
__attribute__((constructor(101)))
static void SGEeveeIntegrationInit(void) {
    SGEeveeApplyIntegration();
}
