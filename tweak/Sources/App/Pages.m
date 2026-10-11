#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Pages.h"
#import "Shared/ArtistBlock/ArtistBlock.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsMeanings/Meanings.h"
#import "Shared/Player/PlayerSettings.h"
#import "Shared/Player/SGNativeTransitions.h"
#import "Shared/DJMix/SGDJBeatProbe.h"
#import "Native/Appearance/Appearance.h"
#import "Native/Navbar/Navbar.h"
#import "Native/NowPlayingBar/NowPlayingBar.h"
#import "Native/Player/NowPlaying.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Redesigned/Lyrics/LyricsText.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Redesigned/Kit/SGRAccent.h"

NSString *const SGRedesignedUIInfo = @"The newest version of spoti.pw, leaning towards Apple Music's style. It is not compatible with the legacy look's settings.\n\nThe legacy look gives you more freedom, yet still looks like Spotify.";

void SGSetRedesignedUI(BOOL on) {
    SGSetEnabled(SGKeyRedesign, on);
    if (!SGRedesignTested()) SGSetEnabled(SGKeyRedesignUntested, on);
}

NSString *SGRedesignUntestedWarning(void) {
    return [NSString stringWithFormat:@"The redesign is made for iOS 26 and has not been tested on iOS %@ at all. Expect bugs and freezes. If Spotify stops opening, delete and reinstall it.", UIDevice.currentDevice.systemVersion];
}

// The whole look changes hands at launch, so the switch asks for the restart straight away rather than
// leaving Spotify half in the old look.
static void offerRestart(BOOL on) {
    NSString *restart = on ? @"The redesign takes over when Spotify starts again. Spotify closes now; open it again to see it." : @"Spotify's own look comes back when Spotify starts again. Spotify closes now; open it again to see it.";
    BOOL untested = on && !SGRedesignTested();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:untested ? @"Not tested on this iOS" : @"Restart Spotify"
        message:untested ? [NSString stringWithFormat:@"%@\n\n%@", SGRedesignUntestedWarning(), restart] : restart
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

SGModSection *SGAppearanceSection(void) {
    SGModRow *redesign = SGOptionRow(@"Redesigned UI", nil, SGKeyRedesign);
    redesign.glows = YES;
    redesign.info = SGRedesignedUIInfo;
    redesign.changed = ^(BOOL on) {
        SGSetRedesignedUI(on);
        offerRestart(on);
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObject:SGWithSymbol(redesign, @"sparkles")];
    [rows addObjectsFromArray:SGRedesignedUIStored() ? SGRAppearanceRows() : SGNativeAppearanceRows()];
    return SGNotedSection(@"Appearance", rows, @"Changes apply after you restart Spotify.");
}

UIViewController *SGNavbarPage(void) {
    return SGRedesignedUIStored() ? SGRNavbarSettingsPage() : SGNavbarSettingsPage();
}

// Pronunciation, translation, word sweeping and line meanings exist only in the redesign's lyrics.
UIViewController *SGLyricsSettingsPage(void) {
    BOOL redesigned = SGRedesignedUIStored();
    NSMutableArray<SGModRow *> *more = [NSMutableArray arrayWithObject:SGLockScreenLyricsRow()];
    if (!redesigned) [more insertObject:SGGlassLyricsRow() atIndex:0];
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGLyricsSourcesSection(redesigned)];
    if (redesigned) {
        [sections addObject:SGSection(@"Display", @[SGLyricsWordTimingRow(), SGRLyricsTextSizesRow(), SGLyricsTranslationLanguageRow(), SGLyricsMeaningsRow()])];
    }
    [sections addObject:SGSection(nil, more)];
    return [[SGModPage alloc] initWithTitle:@"Lyrics" intro:SGRestartNote sections:sections footer:nil];
}

UIViewController *SGPlayerSettingsPage(void) {
    SGModRow *blocked = SGPageRow(@"Blocked artists", ^UIViewController *{ return SGArtistBlockSettingsPage(); });
    blocked.value = ^NSString *{
        return SGFlag(SGKeyArtistBlock, NO) ? @(SGBlockedArtists().count).stringValue : @"Off";
    };
    BOOL native = !SGRedesignedUIStored();

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[
        SGWithSymbol(SGPageRow(@"Gestures", ^UIViewController *{ return SGGesturesSettingsPage(); }), @"hand.tap"),
        SGWithSymbol(blocked, @"person.crop.circle.badge.xmark"),
    ])];
    NSMutableArray<SGModRow *> *pages = [NSMutableArray array];
    if (native) {
        [pages addObject:SGWithSymbol(SGPageRow(@"Now playing bar", ^UIViewController *{ return SGNowPlayingBarSettingsPage(); }), @"rectangle.bottomthird.inset.filled")];
        [pages addObject:SGWithSymbol(SGPageRow(@"Queue & devices", ^UIViewController *{ return SGQueueSettingsPage(); }), @"text.line.first.and.arrowtriangle.forward")];
    }
    [pages addObject:SGWithSymbol(SGPageRow(@"Lock screen widget", ^UIViewController *{ return SGLockScreenWidgetPage(); }), @"lock")];
    [sections addObject:SGSection(nil, pages)];
    [sections addObjectsFromArray:native ? SGNativePlayerScreenSections() : SGRNowPlayingSections()];
    [sections addObject:SGNotedSection(@"DJ Mix laboratory", @[
        SGWithSymbol(SGOptionRow(@"Analyze beat grids (experimental)",
            @"Collect a short rhythmic envelope from local audio and estimate BPM off the render thread. This is diagnostics only: it does not mix tracks or download upcoming audio. Restart Spotify after changing.",
            SGKeyDJBeatProbe), @"waveform.path"),
    ], @"Requires restart. Off by default; no audio changes. View results in Mod → Copy diagnostics under 'dj lab'.")];
    [sections addObject:SGNotedSection(@"Transitions (experimental)", @[
        SGWithSymbol(SGOptionRow(@"Synchronize native crossfade",
            @"When you change the crossfade duration in Spotify's own playback settings, keep its crossfade switch in sync. Uses Spotify's existing engine; it does not unlock beat-matched AutoMix.", SGKeyNativeCrossfadeSync), @"arrow.triangle.2.circlepath"),
    ], @"For testing on supported local playback only. Spotify Connect or a server-restricted playback context can ignore the setting. No custom two-deck mixing is installed.")];
    // Vibrations hook Spotify's own controls and its audio, so they answer under either look.
    [sections addObjectsFromArray:SGVibrationsSections()];

    return [[SGModPage alloc] initWithTitle:@"Player" intro:SGRestartNote sections:sections footer:nil];
}
