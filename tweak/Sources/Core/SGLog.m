#import "SGLog.h"

static const unsigned long long kSGLogMaxBytes = 2ull * 1024ull * 1024ull;

static dispatch_queue_t SGLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("pw.spoti.personal.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *SGLogPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"spoti-pw-debug.log"];
}

static void trimIfNeeded(void) {
    NSString *path = SGLogPath();
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kSGLogMaxBytes) return;

    NSData *all = [NSData dataWithContentsOfFile:path];
    if (!all.length) return;

    NSUInteger keep = MIN((NSUInteger)(kSGLogMaxBytes / 2), all.length);
    NSData *tail = [all subdataWithRange:NSMakeRange(all.length - keep, keep)];
    NSMutableData *replacement = [NSMutableData data];
    NSData *marker = [@"[spoti.pw] older diagnostic log entries trimmed\n" dataUsingEncoding:NSUTF8StringEncoding];
    [replacement appendData:marker];
    [replacement appendData:tail];
    [replacement writeToFile:path atomically:YES];
}

void SGLogMessage(NSString *message) {
    if (!message.length) return;

    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[spotifyglass] %{public}s", message.UTF8String);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(SGLogQueue(), ^{
        NSString *path = SGLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [[NSData data] writeToFile:path atomically:YES];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
            @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
        }

        static NSUInteger writes = 0;
        if (++writes % 64 == 0) trimIfNeeded();
    });
}

NSString *SGLogFileContents(void) {
    __block NSString *text = @"";
    dispatch_sync(SGLogQueue(), ^{
        NSData *data = [NSData dataWithContentsOfFile:SGLogPath()];
        if (data.length) text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(diagnostic log could not be decoded)";
    });
    return text;
}

void SGClearLogFile(void) {
    dispatch_sync(SGLogQueue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:SGLogPath() error:nil];
    });
}

// The unified log cuts a message at about 1 KB, so long dumps go out as numbered parts.
void SGLogLong(NSString *tag, NSString *text) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (current.length && [current lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 900) {
            [parts addObject:[current copy]];
            [current setString:@""];
        }
        [current appendFormat:@"%@\n", line];
    }
    if (current.length) [parts addObject:current];
    [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger i, BOOL *stop) {
        SGLog(@"%@ %lu/%lu\n%@", tag, (unsigned long)i + 1, (unsigned long)parts.count, part);
    }];
}

void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if (!NSClassFromString(name)) SGLog(@"class %@ not found, its hooks are inactive", name);
    }
}
