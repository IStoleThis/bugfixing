
#import <Foundation/Foundation.h>
#import "UYTFileSize.h"
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <stdio.h>
#import <sys/types.h>
#import <pthread.h>
#import <fcntl.h>
#import <errno.h>
#import "UYTLog.h"

typedef NS_ENUM(NSInteger, UYTKind) {
    UYTKindOther = 0,
    UYTKindNoise = 1,
    UYTKindSignal = 2
};

@interface UYTGroup : NSObject
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *sample;
@property (nonatomic, copy) NSString *first;
@property (nonatomic, copy) NSString *last;
@property (nonatomic, assign) NSUInteger count;
@property (nonatomic, assign) UYTKind kind;
@property (nonatomic, strong) NSMutableArray<NSString *> *extras;
@end

@implementation UYTGroup
- (instancetype)init {
    self = [super init];
    if (self) {
        _extras = [NSMutableArray array];
        _count = 0;
        _kind = UYTKindOther;
    }
    return self;
}
@end

static NSMutableArray<NSString *> *UYTLogRing;
static NSObject *UYTLogLock;
static NSString *UYTLogFile;
static NSFileHandle *UYTLogHandle;
static NSString *UYTSessionStart;
static int UYTOrigStderr = -1;
// The log file is written on its own queue, in batches, never while the log's lock is held: a slow disk must not make the thread
// that logs (often the main thread) wait. Only that queue touches UYTLogHandle, UYTFileBuffer and UYTFlushPending.
static dispatch_queue_t UYTFileQueue;
static NSMutableData *UYTFileBuffer;
static BOOL UYTFlushPending;
static int UYTFilePendingLines = 0;
static const int UYTFilePendingMax = 4000;
static const NSUInteger UYTFileBufferFlushBytes = 16 * 1024;
static const int64_t UYTFileFlushDelayMs = 500;
static char UYTFileQueueKey;
static NSUncaughtExceptionHandler *UYTPreviousHandler;
static const NSUInteger UYTLogRingCap = 2000;
static const NSUInteger UYTHostCaptureCap = 500;
static const NSUInteger UYTHostSignalCap = 220;
static const NSUInteger UYTNoiseSampleCap = 150;

static NSString *UYTDocDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths firstObject] ?: NSTemporaryDirectory();
}

static NSString *UYTNowStamp(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    return [df stringFromDate:[NSDate date]];
}

static NSString *UYTCap(NSString *text, NSUInteger cap) {
    if (text.length <= cap) return text;
    return [NSString stringWithFormat:@"%@  <+%lu chars>", [text substringToIndex:cap], (unsigned long)(text.length - cap)];
}

static NSString *UYTSqueeze(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([t containsString:@"  "]) t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return t ?: @"";
}

static void UYTCloseLogFile(void) {
    @try {
        [UYTLogHandle synchronizeFile];
        [UYTLogHandle closeFile];
    } @catch (NSException *e) {}
    UYTLogHandle = nil;
}

static void UYTRotateLogFile(void) {
    if (!UYTLogFile.length) return;
    @try {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:UYTLogFile error:nil];
        if (UYTSizeOfAttrs(attrs) > 1024 * 1024) {
            UYTCloseLogFile();
            NSString *old = [UYTLogFile stringByAppendingString:@".old"];
            [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:UYTLogFile toPath:old error:nil];
        }
    } @catch (NSException *e) {}
}

// Writes what has been collected. Runs on UYTFileQueue only.
static void UYTFileFlush(void) {
    if (!UYTFileBuffer.length) return;
    if (!UYTLogFile.length) {
        [UYTFileBuffer setLength:0];
        return;
    }
    if (!UYTLogHandle) {
        @try {
            if (![[NSFileManager defaultManager] fileExistsAtPath:UYTLogFile]) {
                [[NSFileManager defaultManager] createFileAtPath:UYTLogFile contents:nil attributes:nil];
            }
            UYTLogHandle = [NSFileHandle fileHandleForWritingAtPath:UYTLogFile];
            [UYTLogHandle seekToEndOfFile];
        } @catch (NSException *e) {
            UYTLogHandle = nil;
        }
    }
    if (UYTLogHandle) {
        @try {
            [UYTLogHandle writeData:UYTFileBuffer];
        } @catch (NSException *e) {
            @try { [UYTLogHandle closeFile]; } @catch (NSException *e2) {}
            UYTLogHandle = nil;
        }
    }
    [UYTFileBuffer setLength:0];
}

// Write everything that is waiting, and wait for it. For the moments when the process may be about to end.
static void UYTFileFlushNow(void) {
    if (!UYTFileQueue) return;
    if (dispatch_get_specific(&UYTFileQueueKey)) {
        UYTFileFlush();
    } else {
        dispatch_sync(UYTFileQueue, ^{ UYTFileFlush(); });
    }
}

static void UYTFileAppend(NSString *line) {
    if (!UYTFileQueue || !UYTLogFile.length) return;
    // If the disk cannot keep up, the ring still has the line; only the file misses it.
    if (__atomic_add_fetch(&UYTFilePendingLines, 1, __ATOMIC_RELAXED) > UYTFilePendingMax) {
        __atomic_sub_fetch(&UYTFilePendingLines, 1, __ATOMIC_RELAXED);
        return;
    }
    NSString *text = [line stringByAppendingString:@"\n"];
    dispatch_async(UYTFileQueue, ^{
        __atomic_sub_fetch(&UYTFilePendingLines, 1, __ATOMIC_RELAXED);
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (data) [UYTFileBuffer appendData:data];
        if (UYTFileBuffer.length >= UYTFileBufferFlushBytes) {
            UYTFileFlush();
            return;
        }
        if (!UYTFlushPending) {
            UYTFlushPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, UYTFileFlushDelayMs * NSEC_PER_MSEC), UYTFileQueue, ^{
                UYTFlushPending = NO;
                UYTFileFlush();
            });
        }
    });
}

static void UYTWriteLine(NSString *tag, NSString *stamp, NSString *text) {
    NSString *line = [NSString stringWithFormat:@"%@ %@ %@", tag, stamp, text];
    @synchronized (UYTLogLock) {
        if (UYTLogRing.count >= UYTLogRingCap) {
            [UYTLogRing removeObjectsInRange:NSMakeRange(0, UYTLogRing.count - UYTLogRingCap + 1)];
        }
        [UYTLogRing addObject:line];
    }
    UYTFileAppend(line);
}

static void UYTWriteMessage(NSString *tag, NSString *message) {
    NSString *trimmed = UYTSqueeze(message);
    if (!trimmed.length) return;
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"\n"];
    NSUInteger index = 0;
    for (NSString *part in parts) {
        NSString *text = UYTSqueeze(part);
        if (text.length) {
            if (index == 0) UYTWriteLine(tag, UYTNowStamp(), text);
            else UYTWriteLine(@"[CONT]", UYTNowStamp(), text);
        }
        index++;
    }
}

void UYTDebugInfo(NSString *format, ...) {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    UYTWriteMessage(@"[UYT-I]", msg);
}

void UYTDebugWarn(NSString *format, ...) {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    UYTWriteMessage(@"[UYT-W]", msg);
}

void UYTDebugErr(NSString *format, ...) {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    UYTWriteMessage(@"[UYT-E]", msg);
}

static NSString *UYTStripHostPrefix(NSString *raw) {
    static NSRegularExpression *rx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rx = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{1,2}:\\d{2}:\\d{2}\\.\\d{3}\\s+[A-Za-z0-9_.]+\\[\\d+:\\d+\\]\\s*"
                                                     options:0 error:nil];
    });
    NSString *s = raw ?: @"";
    while (s.length) {
        unichar first = [s characterAtIndex:0];
        if (first < '0' || first > '9') break; // the prefix is a date, so only a line that starts with a digit can have one
        NSTextCheckingResult *m = [rx firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (!m || !m.range.length) break;
        s = [s substringFromIndex:m.range.length];
    }
    return s;
}

void UYTDebugCaptureLine(NSString *raw) {
    if (!raw.length) return;
    UYTWriteMessage(@"[LOG]", UYTCap(UYTStripHostPrefix(raw), UYTHostCaptureCap));
    if (UYTOrigStderr >= 0) {
        @try { dprintf(UYTOrigStderr, "%s\n", raw.UTF8String); } @catch (NSException *e) {}
    }
}

static void UYTHandleUncaught(NSException *exception) {
    @autoreleasepool {
        UYTWriteMessage(@"[UYT-E]", [NSString stringWithFormat:
            @"UNCAUGHT EXCEPTION: %@\nReason: %@\n%@",
            exception.name ?: @"?", exception.reason ?: @"?",
            [exception.callStackSymbols componentsJoinedByString:@"\n"]]);
    }
    UYTFileFlushNow(); // the app ends right after this
    if (UYTPreviousHandler) UYTPreviousHandler(exception);
}

// Turns one line of the host's stderr output into a log line.
static void UYTCaptureBytes(const char *bytes, NSUInteger length) {
    NSString *line = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!line) line = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    if (line.length) UYTDebugCaptureLine(line);
}

static void *UYTStderrReaderMain(void *ctx) {
    int fd = (int)(intptr_t)ctx;
    char buf[8192];
    // Bytes, not text, are collected, so a character that arrives in two reads is not lost, and a line is cut at its newline.
    NSMutableData *acc = [NSMutableData data];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        @autoreleasepool {
            [acc appendBytes:buf length:(NSUInteger)n];
            const char *base = (const char *)acc.bytes;
            NSUInteger length = acc.length, start = 0;
            for (NSUInteger i = 0; i < length; i++) {
                if (base[i] != '\n') continue;
                NSUInteger end = i;
                if (end > start && base[end - 1] == '\r') end--;
                if (end > start) UYTCaptureBytes(base + start, end - start);
                start = i + 1;
            }
            if (start > 0) [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            if (acc.length > 64 * 1024) { // no newline in a long time: log what there is and start over
                UYTCaptureBytes((const char *)acc.bytes, 4096);
                [acc setLength:0];
            }
        }
    }
    return NULL;
}

void UYTLogInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTLogLock = [NSObject new];
        UYTLogRing = [NSMutableArray array];
        UYTLogFile = [UYTDocDir() stringByAppendingPathComponent:@"uYouEnhanced-Debug.log"];
        UYTRotateLogFile();
        UYTFileBuffer = [NSMutableData data];
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        UYTFileQueue = dispatch_queue_create("uYouEnhanced.debuglog", attr);
        dispatch_queue_set_specific(UYTFileQueue, &UYTFileQueueKey, &UYTFileQueueKey, NULL);
        for (NSNotificationName name in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(UYTFileQueue, ^{ UYTFileFlush(); });
            }];
        }
        UYTSessionStart = UYTNowStamp();

        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *stamp = [df stringFromDate:[NSDate date]];
#ifdef TWEAK_VERSION
        UYTWriteLine(@"[UYT-I]", UYTNowStamp(), [NSString stringWithFormat:@"[uYouEnhanced] == session start %@ (tweak %s) ==", stamp, TWEAK_VERSION]);
#else
        UYTWriteLine(@"[UYT-I]", UYTNowStamp(), [NSString stringWithFormat:@"[uYouEnhanced] == session start %@ ==", stamp]);
#endif

        int fds[2];
        if (pipe(fds) == 0) {
            int orig = dup(STDERR_FILENO);
            if (orig >= 0) {
                UYTOrigStderr = orig;
                // The write end never blocks. If the reader ever falls behind, a log line is dropped; what would otherwise
                // happen is that whatever wrote to stderr (the main thread, an NSLog) waits for the reader.
                int flags = fcntl(fds[1], F_GETFL, 0);
                if (flags >= 0) fcntl(fds[1], F_SETFL, flags | O_NONBLOCK);
                dup2(fds[1], STDERR_FILENO);
                close(fds[1]);
                pthread_t th;
                if (pthread_create(&th, NULL, UYTStderrReaderMain, (void *)(intptr_t)fds[0]) == 0) {
                    pthread_detach(th);
                } else {
                    close(fds[0]);
                }
            } else {
                close(fds[0]);
                close(fds[1]);
            }
        }

        UYTPreviousHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&UYTHandleUncaught);
    });
}

static BOOL UYTContainsAny(NSString *haystackLower, NSArray<NSString *> *needles) {
    for (NSString *n in needles) {
        if ([haystackLower containsString:n]) return YES;
    }
    return NO;
}

static BOOL UYTIsHostNoise(NSString *lc) {
    static NSArray<NSString *> *noise;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        noise = @[
            @"pindiskcache",
            @"sandbox_extension_issue_file",
            @"uimotioneffects",
            @"uimotioneffectbody",
            @"_startupdatingbodytoken",
            @"_stopupdatingbodytoken",
            @"_didupdatebody",
            @"lotshapegroup",
            @"merge shape is not supported",
            @"loaded mobile-ffmpeg",
            @"ffmpeg version",
            @"library configuration mismatch",
            @"built with apple clang",
            @"avutil      configuration",
            @"avcodec     configuration",
            @"avformat    configuration",
            @"avdevice    configuration",
            @"avfilter    configuration",
            @"swscale     configuration",
            @"swresample  configuration",
            @"libavutil",
            @"libavcodec",
            @"libavformat",
            @"libavdevice",
            @"libswscale",
            @"info:  configuration",
            @"info:  copyright",
            @"info: ffmpeg",
            @"info:",
            @"intermediate_dump_reader_util.cc",
            @"directory_reader_posix.cc",
            @"sinkhole",
            @"ytiicon.icontype",
            @"gradient strokes",
            @"unbalanced calls to begin/end appearance transitions",
            @"tensorflow lite",
            @"xnnpack",
            @"-canopenurl:",
            @"unsupported url -",
            @"osstatus error -10814"
        ];
    });
    return UYTContainsAny(lc, noise);
}

static BOOL UYTIsHostSignal(NSString *lc) {
    static NSArray<NSString *> *signal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        signal = @[
            @"unrecognized selector",
            @"uncaught exception",
            @"handling objective-c exception",
            @"attempt to set an unknown enum value",
            @"exception_processor.mm",
            @"terminating app",
            @"exc_bad",
            @"sigabrt",
            @"signal sig",
            @"abort trap",
            @"assertion failed",
            @"dyld[",
            @"no space left",
            @"disk full",
            @"status code 4",
            @"status code 5",
            @"nsurlsession",
            @"nw_connection",
            @"connection lost",
            @"timed out",
            @"watchdog",
            @"nslayoutconstraint is being configured",
            @"unable to simultaneously satisfy constraints"
        ];
    });
    return UYTContainsAny(lc, signal);
}

static NSString *UYTGroupKey(NSString *text) {
    static NSArray *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *patterns = @[
            @"(?i)^\\s*(info|warning|error|debug|verbose)\\s*:\\s*",
            @"(?i)https?://[^\\s\"'>]+",
            @"(?i)https?%3A%2F%2F[^\\s\"'>]+",
            @"(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b",
            @"0x[0-9a-f]{4,}",
            @"(?i)\\b[0-9a-f]{14,}\\b",
            @"/var/mobile/\\S+",
            @"\\b\\d{6,}\\b",
            @"\\b\\d+[.,]\\d+\\b"
        ];
        NSArray<NSString *> *replacements = @[
            @"", @" <url> ", @" <url> ", @" <uuid> ", @" <ptr> ", @" <blob> ", @" <path> ", @" <n> ", @" <f> "
        ];
        NSMutableArray *rx = [NSMutableArray array];
        for (NSUInteger i = 0; i < patterns.count; i++) {
            NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:patterns[i] options:0 error:nil];
            if (r) [rx addObject:@[r, replacements[i]]];
        }
        rules = rx;
    });
    NSMutableString *key = [text mutableCopy];
    for (NSArray *pair in rules) {
        NSRegularExpression *r = pair[0];
        NSString *replacement = pair[1];
        [r replaceMatchesInString:key options:0 range:NSMakeRange(0, key.length)
                     withTemplate:replacement];
    }
    return UYTSqueeze(key).lowercaseString;
}

static void UYTParseLine(NSString *line, NSString **tag, NSString **stamp, NSString **text) {
    NSRange sp = [line rangeOfString:@" "];
    if (sp.location == NSNotFound) {
        if (tag) *tag = @"[?]";
        if (stamp) *stamp = @"";
        if (text) *text = line;
        return;
    }
    NSString *rest = [line substringFromIndex:sp.location + 1];
    NSRange sp2 = [rest rangeOfString:@" "];
    if (sp2.location == NSNotFound) {
        if (tag) *tag = [line substringToIndex:sp.location];
        if (stamp) *stamp = rest;
        if (text) *text = @"";
        return;
    }
    if (tag) *tag = [line substringToIndex:sp.location];
    if (stamp) *stamp = [rest substringToIndex:sp2.location];
    if (text) *text = [rest substringFromIndex:sp2.location + 1];
}

static NSString *UYTSourceOf(NSString *text) {
    if (![text hasPrefix:@"["]) return @"";
    NSRange end = [text rangeOfString:@"]"];
    if (end.location == NSNotFound || end.location > 32) return @"";
    return [text substringToIndex:end.location + 1];
}

static NSArray<UYTGroup *> *UYTSnapshotGroups(void) {
    NSArray<NSString *> *lines;
    @synchronized (UYTLogLock) {
        lines = [UYTLogRing copy];
    }
    NSMutableDictionary<NSString *, UYTGroup *> *map = [NSMutableDictionary dictionary];
    NSMutableArray<UYTGroup *> *order = [NSMutableArray array];
    UYTGroup *last = nil;
    for (NSString *line in lines) {
        NSString *tag = nil, *stamp = nil, *text = nil;
        UYTParseLine(line, &tag, &stamp, &text);
        if ([tag isEqualToString:@"[CONT]"]) {
            if (last && last.extras.count < 6) [last.extras addObject:text];
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@|%@", tag, UYTGroupKey(text)];
        UYTGroup *g = map[key];
        if (!g) {
            g = [UYTGroup new];
            g.tag = tag;
            g.source = UYTSourceOf(text);
            g.sample = text;
            g.first = stamp;
            g.last = stamp;
            g.count = 1;
            if ([tag isEqualToString:@"[LOG]"]) {
                NSString *lc = text.lowercaseString;
                g.kind = UYTIsHostSignal(lc) ? UYTKindSignal : (UYTIsHostNoise(lc) ? UYTKindNoise : UYTKindOther);
            }
            map[key] = g;
            [order addObject:g];
        } else {
            g.count++;
            g.last = stamp;
            if (text.length > g.sample.length) g.sample = text;
        }
        last = g;
    }
    return order;
}

static void UYTFilterGroups(NSMutableArray<UYTGroup *> *dest, NSArray<UYTGroup *> *all,
                            NSString *tag, NSInteger kind, BOOL anyKind) {
    for (UYTGroup *g in all) {
        if (tag && ![g.tag isEqualToString:tag]) continue;
        if (!anyKind && g.kind != kind) continue;
        [dest addObject:g];
    }
}

static void UYTAppendGroups(NSMutableString *s, NSArray<UYTGroup *> *groups, NSUInteger cap,
                            NSUInteger maxGroups, BOOL showSource) {
    if (!groups.count) {
        [s appendString:@"  (none)\n"];
        return;
    }
    NSUInteger shown = 0;
    for (UYTGroup *g in groups) {
        if (shown >= maxGroups) break;
        shown++;
        NSString *when = g.first;
        if (g.count > 1 && g.last.length && ![g.last isEqualToString:g.first]) {
            when = [NSString stringWithFormat:@"%@ -> %@", g.first, g.last];
        }
        NSMutableString *pad = [when mutableCopy] ?: [NSMutableString string];
        while (pad.length < 26) [pad appendString:@" "];
        NSMutableString *body = [NSMutableString string];
        if (showSource && g.source.length) [body appendFormat:@"%@ ", g.source];
        [body appendString:UYTCap(g.sample, cap)];
        [s appendFormat:@"  x%-3lu %@ %@\n", (unsigned long)g.count, pad, UYTSqueeze(body)];
        for (NSString *extra in g.extras) {
            [s appendFormat:@"        | %@\n", UYTCap(extra, 120)];
        }
    }
    if (groups.count > shown) {
        [s appendFormat:@"  ... and %lu more distinct message(s)\n", (unsigned long)(groups.count - shown)];
    }
}

static NSUInteger UYTGroupTotal(NSArray<UYTGroup *> *groups) {
    NSUInteger total = 0;
    for (UYTGroup *g in groups) total += g.count;
    return total;
}

static void UYTAppendCounts(NSMutableString *s, NSString *label, NSArray<UYTGroup *> *groups) {
    NSMutableString *pad = [label mutableCopy] ?: [NSMutableString string];
    while (pad.length < 22) [pad appendString:@" "];
    [s appendFormat:@"    %@ %5lu line(s) in %lu distinct message(s)\n",
     pad, (unsigned long)UYTGroupTotal(groups), (unsigned long)groups.count];
}

NSUInteger UYTDebugLineCount(void) {
    NSUInteger n = 0;
    @synchronized (UYTLogLock) { n = UYTLogRing.count; }
    return n;
}

NSUInteger UYTDebugErrorCount(void) {
    NSUInteger n = 0;
    @synchronized (UYTLogLock) {
        for (NSString *l in UYTLogRing) {
            if ([l hasPrefix:@"[UYT-E] "]) n++;
        }
    }
    return n;
}

NSString *UYTDebugErrors(void) {
    NSMutableArray<NSString *> *errs = [NSMutableArray array];
    BOOL inError = NO;
    @synchronized (UYTLogLock) {
        for (NSString *l in UYTLogRing) {
            if ([l hasPrefix:@"[UYT-E] "]) inError = YES;
            else if (![l hasPrefix:@"[CONT] "]) inError = NO;
            if (inError) [errs addObject:l];
        }
    }
    return errs.count ? [errs componentsJoinedByString:@"\n"] : @"(none)";
}

NSString *UYTDebugLogText(NSUInteger lastLines) {
    @synchronized (UYTLogLock) {
        if (!UYTLogRing.count) return @"(no entries)";
        NSUInteger n = MIN(lastLines, UYTLogRing.count);
        NSRange r = NSMakeRange(UYTLogRing.count - n, n);
        return [[UYTLogRing subarrayWithRange:r] componentsJoinedByString:@"\n"];
    }
}

NSString *UYTDebugFullReport(void) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        NSArray<UYTGroup *> *all = UYTSnapshotGroups();

        [s appendString:@"============================================================\n"];
        [s appendString:@"  uYouEnhanced — Debug Report\n"];
        [s appendString:@"============================================================\n"];
#ifdef TWEAK_VERSION
        [s appendFormat:@"  tweak    : %s\n", TWEAK_VERSION];
#endif
        [s appendFormat:@"  device   : %@\n", UIDevice.currentDevice.model ?: @"?"];
        [s appendFormat:@"  iOS      : %@\n", UIDevice.currentDevice.systemVersion ?: @"?"];
        id buildNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UYTBuildNumber"];
        [s appendFormat:@"  bundle   : %@ v%@%@\n",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"?",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            buildNumber ? [NSString stringWithFormat:@" (bugfix build %@)", buildNumber] : @""];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        [s appendFormat:@"  exported : %@\n", [df stringFromDate:[NSDate date]]];
        [s appendFormat:@"  session  : started %@, %lu line(s) in ring (cap %lu)\n",
         UYTSessionStart ?: @"?", (unsigned long)UYTDebugLineCount(), (unsigned long)UYTLogRingCap];
        [s appendString:@"------------------------------------------------------------\n"];

        NSMutableArray<UYTGroup *> *errors = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *tweakErrors = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *crashes = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *warns = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *info = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *signals = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *noise = [NSMutableArray array];
        NSMutableArray<UYTGroup *> *other = [NSMutableArray array];
        UYTFilterGroups(tweakErrors, all, @"[UYT-E]", 0, YES);
        for (UYTGroup *g in tweakErrors) {
            if ([g.sample containsString:@"UNCAUGHT EXCEPTION"]) [crashes addObject:g];
            else [errors addObject:g];
        }
        UYTFilterGroups(warns, all, @"[UYT-W]", 0, YES);
        UYTFilterGroups(info, all, @"[UYT-I]", 0, YES);
        UYTFilterGroups(signals, all, @"[LOG]", UYTKindSignal, NO);
        UYTFilterGroups(noise, all, @"[LOG]", UYTKindNoise, NO);
        UYTFilterGroups(other, all, @"[LOG]", UYTKindOther, NO);

        [s appendString:@"\n  SUMMARY\n"];
        [s appendString:@"  ------------------------------------------------------------\n"];
        UYTAppendCounts(s, @"tweak errors", errors);
        UYTAppendCounts(s, @"tweak warnings", warns);
        UYTAppendCounts(s, @"tweak info", info);
        UYTAppendCounts(s, @"host signals", signals);
        UYTAppendCounts(s, @"host noise", noise);
        UYTAppendCounts(s, @"host other", other);
        UYTAppendCounts(s, @"uncaught exceptions", crashes);
        [s appendString:@"\n  HOW TO READ\n"];
        [s appendString:@"  ------------------------------------------------------------\n"];
        [s appendString:@"  [UYT-I/W/E] = this tweak. [LOG] = YouTube app or iOS on stderr.\n"];
        [s appendString:@"  xN = that message happened N times.  a -> b = first to last seen.\n"];
        [s appendString:@"  | = a continuation line of the message above it.\n"];
        [s appendString:@"  Host noise is third-party chatter and is collapsed, not dropped.\n"];
        [s appendString:@"  Fix the first tweak error; later repeats are usually its echo.\n"];

        if (crashes.count) {
            [s appendFormat:@"\n---- UNCAUGHT EXCEPTIONS (%lu) ----\n", (unsigned long)crashes.count];
            UYTAppendGroups(s, crashes, 400, 10, YES);
        }

        [s appendFormat:@"\n---- TWEAK ERRORS (%lu) ----\n", (unsigned long)errors.count];
        UYTAppendGroups(s, errors, 400, 25, YES);

        [s appendFormat:@"\n---- TWEAK WARNINGS (%lu) ----\n", (unsigned long)warns.count];
        UYTAppendGroups(s, warns, 300, 25, YES);

        if (signals.count) {
            [s appendFormat:@"\n---- HOST SIGNALS (%lu, third-party) ----\n", (unsigned long)signals.count];
            UYTAppendGroups(s, signals, UYTHostSignalCap, 20, NO);
        }

        if (noise.count) {
            NSArray<UYTGroup *> *byCount = [noise sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                NSUInteger ca = [(UYTGroup *)a count], cb = [(UYTGroup *)b count];
                if (ca == cb) return NSOrderedSame;
                return ca > cb ? NSOrderedAscending : NSOrderedDescending;
            }];
            [s appendFormat:@"\n---- HOST NOISE (%lu line(s), %lu distinct, third-party, benign, most frequent first) ----\n",
             (unsigned long)UYTGroupTotal(noise), (unsigned long)noise.count];
            UYTAppendGroups(s, byCount, UYTNoiseSampleCap, 12, NO);
        }

        if (other.count) {
            [s appendFormat:@"\n---- HOST OTHER (%lu distinct, unclassified) ----\n", (unsigned long)other.count];
            UYTAppendGroups(s, other, UYTNoiseSampleCap, 12, NO);
        }

        NSMutableArray<UYTGroup *> *recent = [NSMutableArray array];
        for (NSUInteger i = all.count; i-- > 0;) {
            UYTGroup *g = all[i];
            if (![g.tag isEqualToString:@"[UYT-I]"]) continue;
            [recent insertObject:g atIndex:0];
            if (recent.count >= 40) break;
        }
        [s appendFormat:@"\n---- RECENT TWEAK ACTIVITY (%lu distinct) ----\n", (unsigned long)recent.count];
        UYTAppendGroups(s, recent, 300, 40, YES);

        NSString *castSection = UYTCastReportSection();
        if (castSection.length) {
            [s appendString:@"\n"];
            [s appendString:castSection];
            if (![castSection hasSuffix:@"\n"]) [s appendString:@"\n"];
        }

        NSString *selPath = [UYTDocDir() stringByAppendingPathComponent:@"uYouUnrecognizedSelector.log"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:selPath]) {
            NSString *selText = [NSString stringWithContentsOfFile:selPath encoding:NSUTF8StringEncoding error:nil] ?: @"(unreadable)";
            [s appendString:@"\n---- UNRECOGNIZED SELECTORS (crash evidence) ----\n"];
            [s appendString:UYTCap(selText, 4000)];
            [s appendString:@"\n"];
        }

        [s appendString:@"\n============================================================\n"];
        [s appendString:@"  END OF REPORT\n"];
        [s appendString:@"============================================================\n"];
        return [s copy];
    }
}

%ctor {
    UYTLogInstall();
}
