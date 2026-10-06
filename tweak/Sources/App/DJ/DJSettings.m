#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/DJ/SGDJ.h"
#import "DJSettings.h"

UIViewController *SGDJSettingsPage(void) {
    SGModRow *enabled = SGOptionRow(@"DJ Mix", @"Beat-aware buffered transitions between tracks", SGKeyDJEnabled);
    enabled.symbol = @"waveform";
    enabled.changed = ^(BOOL on) { SGDJRefreshConfiguration(); };

    SGModRow *style = SGChoiceRow(@"Style", @"How DJ Mix prefers to transition", SGKeyDJStyle,
                                  @[@"Auto", @"Smooth", @"Club", @"Quick"], 0);
    style.symbol = @"slider.horizontal.3";

    SGModRow *intensity = SGChoiceRow(@"Intensity", @"How strongly tempo and transition effects are allowed to change the sound",
                                      SGKeyDJIntensity, @[@"Low", @"Normal", @"High"], 1);
    intensity.symbol = @"dial.medium";

    SGModRow *indicator = SGOptionRow(@"Player status", @"Show DJ MIX below the progress bar while a transition is being prepared or performed",
                                      SGKeyDJIndicator);
    indicator.defaultOn = YES;
    indicator.symbol = @"text.badge.checkmark";
    indicator.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGDJStateDidChangeNotification object:nil];
    };

    SGModRow *status = SGStatRow(@"Engine", ^NSString *{
        if (!SGDJEnabled()) return @"Off";
        switch (SGDJCurrentState()) {
            case SGDJStatePreparing: return @"Preparing";
            case SGDJStateTransition: return @"Transition";
            case SGDJStateIdle: return @"Ready";
            default: return @"Off";
        }
    });
    status.symbol = @"waveform.path.ecg";
    status.refreshOn = SGDJStateDidChangeNotification;

    SGModRow *mix = SGStatRow(@"Current mix", ^NSString *{ return SGDJCurrentMixSummary(); });
    mix.symbol = @"arrow.triangle.2.circlepath";
    mix.refreshOn = SGDJStateDidChangeNotification;

    SGModRow *analysis = SGStatRow(@"Analysis", ^NSString *{ return SGDJAnalysisSummary(); });
    analysis.symbol = @"metronome";
    analysis.refreshOn = SGDJStateDidChangeNotification;

    NSArray<SGModSection *> *sections = @[
        SGNotedSection(nil, @[enabled],
                       @"DJ Mix analyzes decoded audio locally and caches its results. On verified Spotify builds, V2 buffers both sides of a natural track boundary for a real overlapping mix; otherwise it falls back safely."),
        SGSection(@"Mixing", @[style, intensity]),
        SGSection(@"Player", @[indicator, status, mix, analysis]),
    ];
    return [[SGModPage alloc] initWithTitle:@"DJ Mix" intro:nil sections:sections footer:nil];
}

NSString *SGDJSettingsSummary(void) {
    return SGDJEnabled() ? SGDJStyleName() : @"Off";
}
