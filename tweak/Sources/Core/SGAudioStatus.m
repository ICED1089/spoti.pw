#import "SGAudioStatus.h"

static BOOL sg_audioAvailable;
static NSString *sg_audioReason;

void SGAudioStatusSet(BOOL available, NSString *reason) {
    @synchronized(NSUserDefaults.class) {
        sg_audioAvailable = available;
        sg_audioReason = [reason copy];
    }
}

BOOL SGAudioStatusAvailable(void) {
    @synchronized(NSUserDefaults.class) {
        return sg_audioAvailable;
    }
}

NSString *SGAudioStatusReason(void) {
    @synchronized(NSUserDefaults.class) {
        return sg_audioReason;
    }
}
