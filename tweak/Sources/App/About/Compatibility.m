// What the mod isn't made to run with: a Spotify other than SGSupportedSpotifyVersion, whose classes have
// moved. EeveeSpotify is supported by this personal combined build through Core/SGEeveeIntegration,
// so it is no longer treated as an incompatibility here.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "App/Onboarding/Onboarding.h"
#import "App/Sheet/SGCardSheet.h"

static const NSTimeInterval kSettle = 3, kRetry = 4;
static const NSInteger kTries = 45;

@interface SGIncompatibility : NSObject
@property (nonatomic, copy) NSString *title, *subtitle, *message;
@property (nonatomic, copy) NSString *key, *stamp;   // said again only when the stamp changes
@end

@implementation SGIncompatibility
@end

static NSString *const kReportLine = @"Please don't open issues or report bugs on Discord from this setup.";

static NSString *runningVersion(void) {
    id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : nil;
}

static NSArray<SGIncompatibility *> *incompatibilities(void) {
    static NSArray<SGIncompatibility *> *found;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<SGIncompatibility *> *list = [NSMutableArray array];
        NSString *version = runningVersion();
        if (version && ![version isEqualToString:SGSupportedSpotifyVersion]) {
            SGIncompatibility *wrong = [SGIncompatibility new];
            wrong.title = [NSString stringWithFormat:@"Spotify %@ isn't supported", version];
            wrong.subtitle = [NSString stringWithFormat:@"The mod is made for %@ only", SGSupportedSpotifyVersion];
            wrong.message = [NSString stringWithFormat:
                @"spoti.pw is made for Spotify %@ only. On any other version parts of it break or go missing, "
                @"so it won't work the way you expect.\n\n%@ Use a %@ IPA instead.",
                SGSupportedSpotifyVersion, kReportLine, SGSupportedSpotifyVersion];
            wrong.key = @"spotifyglass.spotifyversion.warned";
            wrong.stamp = version;
            [list addObject:wrong];
        }
        found = list;
    });
    return found;
}

static void showWarning(SGIncompatibility *problem, void (^done)(void)) {
    UIViewController *top = SGTopController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:problem.title
                                                                   message:problem.message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (done) done();
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

NSArray<SGModRow *> *SGCompatibilityWarningRows(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    NSString *version = runningVersion();
    if (version && ![version isEqualToString:SGSupportedSpotifyVersion]) {
        SGModRow *row = SGStatRow(@"Spotify compatibility", ^NSString *{ return version; });
        row.subtitle = [NSString stringWithFormat:@"v0.23 was built for %@; this personal build is validating newer Spotify versions feature by feature", SGSupportedSpotifyVersion];
        row.symbol = @"wrench.and.screwdriver";
        [rows addObject:row];
    }
    return rows;
}

// One alert at a time, the next after OK. A problem is stored only once its alert is up, so a run
// that never found a clear screen tries again next launch.
static void warnWhenClear(NSArray<SGIncompatibility *> *pending, NSInteger tries) {
    if (!pending.count) return;
    UIViewController *top = SGTopController();
    BOOL busy = !top || SGOnboardingShowing() || [top isKindOfClass:UIAlertController.class]
        || [top isKindOfClass:SGCardSheet.class]
        || UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    if (busy) {
        if (tries > 0)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ warnWhenClear(pending, tries - 1); });
        return;
    }
    SGIncompatibility *problem = pending.firstObject;
    NSArray<SGIncompatibility *> *rest = [pending subarrayWithRange:NSMakeRange(1, pending.count - 1)];
    [NSUserDefaults.standardUserDefaults setObject:problem.stamp forKey:problem.key];
    showWarning(problem, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ warnWhenClear(rest, kTries); });
    });
    SGLog(@"compatibility: warned \"%@\" over %@", problem.title, NSStringFromClass(top.class));
}

void SGCheckCompatibilityOnce(void) {
    NSString *version = runningVersion();
    if (version && ![version isEqualToString:SGSupportedSpotifyVersion])
        SGLog(@"compatibility: Spotify %@ running in personal compatibility mode; original v0.23 target was %@", version, SGSupportedSpotifyVersion);
}
