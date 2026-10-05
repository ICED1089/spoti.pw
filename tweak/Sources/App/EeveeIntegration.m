#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "EeveeIntegration.h"

static void reapplyAndRestart(void) {
    SGEeveeApplyIntegration();
    SGRestartSpotify();
}

UIViewController *SGEeveeIntegrationPage(void) {
    SGModRow *status = SGStatRow(@"Integration", ^NSString *{ return SGEeveeIntegrationSummary(); });
    status.symbol = @"checkmark.shield";

    SGModRow *ui = SGStatRow(@"UI, player & artwork", ^NSString *{ return @"spoti.pw"; });
    ui.subtitle = @"Liquid Glass, tabs, player, mini-player and artwork";
    ui.symbol = @"paintbrush";

    SGModRow *lyrics = SGStatRow(@"Lyrics & karaoke", ^NSString *{ return @"spoti.pw"; });
    lyrics.subtitle = @"Eevee lyrics replacement is kept off";
    lyrics.symbol = @"quote.bubble";

    SGModRow *flags = SGStatRow(@"Spotify flags", ^NSString *{ return @"spoti.pw"; });
    flags.subtitle = @"Keeps the redesigned UI's required flags consistent";
    flags.symbol = @"flag";

    SGModRow *backend = SGStatRow(@"Premium, ads & privacy", ^NSString *{ return @"Eevee"; });
    backend.subtitle = @"Eevee keeps its core account, ad-blocking and telemetry work";
    backend.symbol = @"shield.lefthalf.filled";

    SGModRow *reapply = SGActionRow(@"Reapply integration & restart",
                                    @"Use this if Eevee UI settings were changed during this session",
                                    ^{ reapplyAndRestart(); });
    reapply.symbol = @"arrow.clockwise";

    NSString *intro = SGEeveePresent()
        ? @"The combined build assigns each mod one job so they do not fight over the same Spotify screens. These ownership settings are applied automatically every launch."
        : @"EeveeSpotify is not present in this build.";

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[status])];
    if (SGEeveePresent()) {
        [sections addObject:SGSection(@"Ownership", @[ui, lyrics, flags, backend])];
        [sections addObject:SGNotedSection(nil, @[reapply], @"Changing overlapping Eevee appearance, lyrics, player, gesture or flag settings will be reset on the next Spotify launch.")];
    }

    return [[SGModPage alloc] initWithTitle:@"Eevee Integration" intro:intro sections:sections footer:nil];
}
