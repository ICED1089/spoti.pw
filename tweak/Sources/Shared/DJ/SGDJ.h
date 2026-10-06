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

// Human-readable live details for Mod Settings and diagnostics.
NSString *SGDJCurrentMixSummary(void);
NSString *SGDJAnalysisSummary(void);

// Re-read the stored switch/options and start or stop the real engine immediately.
void SGDJRefreshConfiguration(void);
