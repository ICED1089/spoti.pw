#import <Foundation/Foundation.h>

extern NSString *const SGKeyDJEnabled;
extern NSString *const SGKeyDJIndicator;
extern NSString *const SGKeyDJStyle;
extern NSString *const SGKeyDJIntensity;
extern NSNotificationName const SGDJStateDidChangeNotification;

typedef NS_ENUM(NSInteger, SGDJState) {
    SGDJStateOff,
    SGDJStateIdle,
    SGDJStatePreparing,
    SGDJStateTransition,
};

BOOL SGDJEnabled(void);
BOOL SGDJIndicatorEnabled(void);
NSInteger SGDJStyle(void);
NSInteger SGDJIntensity(void);
NSString *SGDJStyleName(void);
NSString *SGDJIntensityName(void);
SGDJState SGDJCurrentState(void);
NSString *SGDJPlayerStatusText(void);

// Main-thread control API for the transition engine. It is intentionally separate from the
// real-time render path: audio callbacks only consume already-published transition parameters.
void SGDJSetState(SGDJState state);
void SGDJRefreshConfiguration(void);
