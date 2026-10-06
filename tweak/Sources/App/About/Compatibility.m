// Compatibility status for the personal v0.23 fork.
// Newer Spotify versions are validated feature by feature instead of being blocked by a modal warning.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"

static NSString *runningVersion(void) {
    id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : nil;
}

NSArray<SGModRow *> *SGCompatibilityWarningRows(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    NSString *version = runningVersion();
    if (version && ![version isEqualToString:SGSupportedSpotifyVersion]) {
        SGModRow *row = SGStatRow(@"Spotify compatibility", ^NSString *{ return version; });
        row.subtitle = [NSString stringWithFormat:
            @"v0.23 was built for %@; this personal build validates newer Spotify versions feature by feature",
            SGSupportedSpotifyVersion];
        row.symbol = @"wrench.and.screwdriver";
        [rows addObject:row];
    }
    return rows;
}

void SGCheckCompatibilityOnce(void) {
    NSString *version = runningVersion();
    if (version && ![version isEqualToString:SGSupportedSpotifyVersion])
        SGLog(@"compatibility: Spotify %@ running in personal compatibility mode; original v0.23 target was %@",
              version, SGSupportedSpotifyVersion);
}
