#import "Donate.h"

NSString *const SGKofiURL = @"https://ko-fi.com/darkksh";

UIColor *SGKofiColor(void) {
    return [UIColor colorWithRed:1.0 green:(94.0 / 255.0) blue:(91.0 / 255.0) alpha:1.0];
}

// Personal fork: donation UI and automatic prompts are intentionally disabled.
// Keep the public functions so onboarding/update code can call them safely without special cases.
void SGShowDonateSheet(void) {}
SGModRow *SGDonateRow(void) { return nil; }
void SGWatchForDonate(void) {}
void SGDonateAfterTour(BOOL restarting) { (void)restarting; }
BOOL SGDonateAfterTourPending(void) { return NO; }
void SGOfferDonate(void) {}
BOOL SGDonateShown(void) { return NO; }
void SGDonateHoldOff(void) {}
