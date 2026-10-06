// Whether the lock screen can open this build at all. MediaRemote launches the now playing app by
// the App ID in its application-identifier entitlement, not by CFBundleIdentifier, so a build signed
// under a profile whose App ID is not the bundle id installs and plays but cannot be opened from the
// now playing card: iOS asks for a bundle that is not installed and offers the App Store instead.
// The signature decides this and nothing in the app can change it, so all the mod does is say so --
// once on the first launch under a signature, and from a red row at the top of Mod Settings for as
// long as it lasts. Both land on the same sheet, which names the bundle id to sign under and copies
// it, because that one string is the whole fix.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "App/Onboarding/Onboarding.h"
#import <dlfcn.h>

NSString *const SGSigningHelpURL = @"https://github.com/skopevoj/spoti.pw#signing-it-yourself";

static NSString *const kWarned = @"spotifyglass.signing.warned";

// SecTaskCopyValueForEntitlement is not in the iOS SDK, so it is resolved at runtime like the rest
// of the private API the mod uses. A build that cannot read its own entitlement stays quiet.
NSString *SGSigningAppIdentifier(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (!security) return;
        CFTypeRef (*createFromSelf)(CFAllocatorRef) = dlsym(security, "SecTaskCreateFromSelf");
        CFTypeRef (*copyValue)(CFTypeRef, CFStringRef, CFErrorRef *) = dlsym(security, "SecTaskCopyValueForEntitlement");
        if (!createFromSelf || !copyValue) return;
        CFTypeRef task = createFromSelf(NULL);
        if (!task) return;
        CFTypeRef value = copyValue(task, CFSTR("application-identifier"), NULL);
        CFRelease(task);
        if (!value) return;
        if (CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *identifier = (__bridge NSString *)value;
            NSRange dot = [identifier rangeOfString:@"."];   // drop the team prefix
            cached = dot.location == NSNotFound ? [identifier copy]
                                               : [identifier substringFromIndex:dot.location + 1];
        }
        CFRelease(value);
    });
    return cached;
}

// Unreadable counts as fine: a guess here would cry wolf at a build that works.
BOOL SGSigningOpensFromLockScreen(void) {
    NSString *appID = SGSigningAppIdentifier();
    return !appID || [appID isEqualToString:NSBundle.mainBundle.bundleIdentifier];
}

// The fix is one string, so the sheet leads with it and Copy is the first action: whoever reads this
// is on their way back to Feather to paste it into the identifier field.


// nil while the signature is sound, which is what keeps the row out of Mod Settings entirely.
SGModRow *SGSigningWarningRow(void) {
    // LiveContainer commonly signs under a different App ID; keep this as diagnostics only.
    return nil;
}

// Said once per signature: re-signing under a different App ID is a new mistake and says so again,
// but a build that is simply left broken does not nag on every launch. The row stays either way.
void SGCheckSigningOnce(void) {
    if (SGSigningOpensFromLockScreen()) return;
    SGLog(@"signing: installed as %@ but signed under %@; the now playing card cannot open this build",
          NSBundle.mainBundle.bundleIdentifier, SGSigningAppIdentifier());
}

void SGShowSigningFixIfPending(void) {
    // Personal fork: signing mismatch is logged, not shown as a warning.
}
