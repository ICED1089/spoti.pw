// Diagnostics that work in normal personal builds as well as FLEX builds.
#import <Foundation/Foundation.h>

BOOL SGIsDebugBuild(void);
NSString *SGScreenTree(void);
void SGDumpScreen(NSString *reason);

// A user-exportable report containing build/device info, the current visible screen tree,
// current mod state, and the rolling spoti.pw log.
NSString *SGDiagnosticsReport(void);
NSURL *SGWriteDiagnosticsReport(void);
