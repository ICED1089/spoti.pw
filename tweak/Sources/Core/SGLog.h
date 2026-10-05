#import <Foundation/Foundation.h>
#import <os/log.h>

// Writes to both the iOS unified log and a small rolling file that can be exported from Mod settings.
void SGLogMessage(NSString *message);
NSString *SGLogFileContents(void);
void SGClearLogFile(void);

#define SGLog(fmt, ...) SGLogMessage([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

// Long dumps, split into numbered parts under the unified log's size cap.
void SGLogLong(NSString *tag, NSString *text);
// Logs every class of the list that this Spotify does not have; a feature calls it from its %ctor.
void SGRequireClasses(NSArray<NSString *> *names);
