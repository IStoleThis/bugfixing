// Casting diagnostics.
//
// A cast from a sideloaded YouTube 21.x starts and then ends, or moves to the TV's own YouTube app, after 10 to 20 seconds. The
// code alone does not say which of several possible causes it is, so this file records what happens and puts it into the
// "uYouEnhanced Debug Logs" export. Nothing here changes how casting behaves: every hook calls %orig, apart from the developer
// setting at the end, which only makes the Cast SDK write its own log.
//
// Recorded while the Casting Diagnostics switch is on (it is by default):
//
// * A timeline of session events, one line each, with the time and the return addresses of the caller inside YouTube
//   (YT:0x... is an address of the YouTube binary with ASLR removed, the form a disassembler shows): connecting and
//   disconnecting (with the error), the Cast SDK's suspend / end / failure callbacks, "device removed" reports, network
//   changes, the list of devices changing, the cast button changing state, the app leaving and entering the foreground.
// * YouTube's own Cast SDK log. YouTube has a developer setting, enableCastSDKLogging, that makes the Cast SDK write every
//   message to Documents/cast_sdk_logs.txt (and turns on the SDK's file logging). It is off by default; the hooks at the
//   end switch it on. The last part of that file goes into the export.
//
// The export contains the names and addresses the Cast SDK logs for the devices on the local network. It is only written when
// the export in the settings is used, and nothing is sent anywhere.

#import "uYouPlus.h"
#import "UYTLog.h"
#import "UYTCastRuntime.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

static const NSUInteger kCastTimelineCap = 400;
static const NSUInteger kCastSDKLogLines = 300;
static const unsigned long long kCastSDKLogTailBytes = 80 * 1024;
static const unsigned long long kCastSDKLogMaxBytes = 3 * 1024 * 1024;

static BOOL UYTCastDiagOn(void) {
    return IS_ENABLED(kFixCasting) && IS_ENABLED(kCastingDiagnostics);
}

#define CAST_EVENT(...) do { if (UYTCastDiagOn()) UYTCastEvent(__VA_ARGS__); } while (0)

// ---------------------------------------------------------------------------------------------------- the timeline

static NSMutableArray<NSString *> *sCastTimeline;
static NSMutableDictionary<NSString *, NSString *> *sCastLastByKey;
static NSTimeInterval sCastTimelineStart;
static NSUInteger sCastTimelineDropped;

static NSObject *UYTCastLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        sCastTimeline = [NSMutableArray array];
        sCastLastByKey = [NSMutableDictionary dictionary];
    });
    return lock;
}

void UYTCastEvent(NSString *format, ...) {
    if (!UYTCastDiagOn()) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSObject *lock = UYTCastLock();
    @synchronized (lock) {
        static NSDateFormatter *clock;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            clock = [NSDateFormatter new];
            clock.dateFormat = @"HH:mm:ss.SSS";
        });
        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        if (sCastTimelineStart == 0) sCastTimelineStart = now;
        NSString *line = [NSString stringWithFormat:@"%@ (+%.3fs) %@", [clock stringFromDate:[NSDate date]], now - sCastTimelineStart, text];
        if (sCastTimeline.count >= kCastTimelineCap) {
            [sCastTimeline removeObjectAtIndex:0];
            sCastTimelineDropped++;
        }
        [sCastTimeline addObject:line];
    }
}

// Adds the line only when it differs from the last one recorded under the same key (for callbacks that fire again and again).
static void UYTCastChange(NSString *key, NSString *text) {
    if (!UYTCastDiagOn()) return;
    NSObject *lock = UYTCastLock();
    @synchronized (lock) {
        if ([sCastLastByKey[key] isEqualToString:text]) return;
        sCastLastByKey[key] = text;
    }
    UYTCastEvent(@"%@ %@", key, text);
}

static BOOL UYTCastTimelineHasEntries(void) {
    NSObject *lock = UYTCastLock();
    @synchronized (lock) {
        return sCastTimeline.count > 0;
    }
}

// ---------------------------------------------------------------------------------------------------- describing things

static NSString *UYTCastErrorText(id error) {
    if (!error) return @"error(nil)";
    if (![error isKindOfClass:[NSError class]]) return [NSString stringWithFormat:@"error(%@)", NSStringFromClass([error class])];
    NSError *e = (NSError *)error;
    NSString *desc = e.localizedDescription ?: @"";
    if (desc.length > 120) desc = [[desc substringToIndex:120] stringByAppendingString:@"..."];
    NSMutableString *text = [NSMutableString stringWithFormat:@"error(%@ %ld \"%@\"", e.domain, (long)e.code, desc];
    id underlying = e.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]]) {
        [text appendFormat:@" underlying %@ %ld", ((NSError *)underlying).domain, (long)((NSError *)underlying).code];
    }
    [text appendString:@")"];
    return text;
}

static NSString *UYTCastShortString(NSString *s, NSUInteger limit) {
    return s.length > limit ? [[s substringToIndex:limit] stringByAppendingString:@"..."] : s;
}

// A screen or a Cast device: class, friendly name, and whether the app is running on it.
static NSString *UYTCastScreenText(id screen) {
    if (!screen) return @"nil";
    id name = UYTCastObject(screen, @"friendlyName");
    NSMutableString *text = [NSMutableString stringWithString:NSStringFromClass([screen class])];
    if ([name isKindOfClass:[NSString class]]) [text appendFormat:@"(\"%@\"", UYTCastShortString(name, 40)];
    else [text appendString:@"(?"];
    if ([screen respondsToSelector:NSSelectorFromString(@"isRunning")]) {
        [text appendFormat:@" running=%d", UYTCastBool(screen, @"isRunning", NO)];
    }
    [text appendString:@")"];
    return text;
}

static NSString *UYTCastObjectText(id obj) {
    if (!obj) return @"nil";
    if ([obj isKindOfClass:[NSError class]]) return UYTCastErrorText(obj);
    if ([obj isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"\"%@\"", UYTCastShortString(obj, 60)];
    if ([obj isKindOfClass:[NSNumber class]]) return [obj stringValue];
    return UYTCastScreenText(obj);
}

static NSString *UYTCastSessionText(id session) {
    if (!session) return @"session=nil";
    return [NSString stringWithFormat:@"session=%@ screen=%@", NSStringFromClass([session class]), UYTCastScreenText(UYTCastObject(session, @"screen"))];
}

static NSString *UYTCastScreensText(id screens) {
    if (!screens) return @"nil";
    if (![screens conformsToProtocol:@protocol(NSFastEnumeration)]) return NSStringFromClass([screens class]);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger total = 0;
    for (id screen in screens) {
        total++;
        if (parts.count < 12) [parts addObject:UYTCastScreenText(screen)];
    }
    return [NSString stringWithFormat:@"%lu [%@%@]", (unsigned long)total, [parts componentsJoinedByString:@", "], total > parts.count ? @", ..." : @""];
}

static NSString *UYTCastNetText(void) {
    id env = UYTCastSharedInstance(@"MDXClientEnvironment");
    if (!env) return @"net(?)";
    return [NSString stringWithFormat:@"net(wifi=%d connected=%d)", UYTCastBool(env, @"isOnWiFi", NO), UYTCastBool(env, @"isConnected", NO)];
}

// The first return addresses outside this tweak. Frames inside the YouTube binary are shown as YT:0x<address without ASLR>.
static NSString *UYTCastCallers(NSUInteger depth) {
    Dl_info self_info;
    const void *selfBase = dladdr((const void *)&UYTCastCallers, &self_info) ? self_info.dli_fbase : NULL;
    const void *mainBase = (const void *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    for (NSNumber *address in [NSThread callStackReturnAddresses]) {
        if (frames.count >= depth) break;
        uintptr_t addr = (uintptr_t)address.unsignedLongLongValue;
        Dl_info info;
        if (!dladdr((const void *)addr, &info)) {
            [frames addObject:[NSString stringWithFormat:@"?0x%lx", (unsigned long)addr]];
        } else if (info.dli_fbase == selfBase) {
            continue;
        } else if (info.dli_fbase == mainBase) {
            [frames addObject:[NSString stringWithFormat:@"YT:0x%lx", (unsigned long)(addr - (uintptr_t)slide)]];
        } else {
            const char *path = info.dli_fname ? info.dli_fname : "?";
            const char *base = strrchr(path, '/');
            [frames addObject:[NSString stringWithFormat:@"%s+0x%lx", base ? base + 1 : path, (unsigned long)(addr - (uintptr_t)info.dli_fbase)]];
        }
    }
    return [frames componentsJoinedByString:@" < "];
}

// ---------------------------------------------------------------------------------------------------- the Cast SDK log

static NSString *UYTCastSDKLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return documents ? [documents stringByAppendingPathComponent:@"cast_sdk_logs.txt"] : nil;
}

// YouTube appends to the file on every launch with the setting on. Delete it at launch when it has grown past the limit.
static void UYTCastTrimSDKLog(void) {
    NSString *path = UYTCastSDKLogPath();
    if (!path) return;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes.fileSize > kCastSDKLogMaxBytes) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static NSString *UYTCastSDKLogTail(void) {
    NSString *path = UYTCastSDKLogPath();
    if (!path) return @"";
    NSString *text = nil;
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) return @"";
        unsigned long long size = [handle seekToEndOfFile];
        unsigned long long start = size > kCastSDKLogTailBytes ? size - kCastSDKLogTailBytes : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    } @catch (NSException *exception) {
        return @"(could not read cast_sdk_logs.txt)";
    }
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if (!lines.count) return @"";
    if (lines.count > 1 && [lines.lastObject length] == 0) [lines removeLastObject];
    if (lines.count > kCastSDKLogLines) [lines removeObjectsInRange:NSMakeRange(0, lines.count - kCastSDKLogLines)];
    NSMutableString *out = [NSMutableString string];
    for (NSString *line in lines) {
        [out appendString:UYTCastShortString(line, 400)];
        [out appendString:@"\n"];
    }
    return out;
}

// Called from UYTDebugFullReport (UYTLog.xm).
NSString *UYTCastReportSection(void) {
    NSMutableString *report = [NSMutableString string];
    if (!UYTCastDiagOn()) return @"";
    NSString *timeline = nil;
    NSObject *lock = UYTCastLock();
    @synchronized (lock) {
        if (sCastTimeline.count) {
            NSString *dropped = sCastTimelineDropped ? [NSString stringWithFormat:@"(%lu older line(s) dropped)\n", (unsigned long)sCastTimelineDropped] : @"";
            timeline = [dropped stringByAppendingString:[sCastTimeline componentsJoinedByString:@"\n"]];
        }
    }
    [report appendString:@"---- CAST DIAGNOSTICS ----\n"];
    if (timeline.length) {
        [report appendString:@"  Timeline, in order. Times are HH:mm:ss.SSS (+ seconds since the first cast event).\n"];
        [report appendString:@"  YT:0x... = return address inside the YouTube binary with ASLR removed. suspend reason: 1 app in background,\n"];
        [report appendString:@"  2 network error, 3 network not reachable (how YouTube's own handler treats them).\n"];
        [report appendString:timeline];
        [report appendString:@"\n"];
    } else {
        [report appendString:@"  on, but no cast event has been recorded in this session yet.\n"];
    }
    NSString *sdk = UYTCastSDKLogTail();
    if (sdk.length) {
        [report appendFormat:@"\n---- CAST SDK LOG (last %lu lines at most of Documents/cast_sdk_logs.txt) ----\n", (unsigned long)kCastSDKLogLines];
        [report appendString:sdk];
    } else {
        [report appendString:@"\n  (Documents/cast_sdk_logs.txt does not exist or is empty: the Cast SDK has not logged anything yet.)\n"];
    }
    return [report copy];
}

// ---------------------------------------------------------------------------------------------------- the hooks

%group gCastingDiagnostics

%hook MDXSessionManager

- (void)connectToScreen:(id)screen source:(int)source {
    CAST_EVENT(@"manager connectToScreen %@ source=%d %@ | %@", UYTCastScreenText(screen), source, UYTCastNetText(), UYTCastCallers(6));
    %orig;
}

- (void)transferToScreen:(id)screen {
    CAST_EVENT(@"manager transferToScreen %@ | %@", UYTCastScreenText(screen), UYTCastCallers(6));
    %orig;
}

- (void)confirmedConnectToScreen:(id)screen withPlaybackDescriptor:(id)descriptor sessionState:(id)state {
    CAST_EVENT(@"manager confirmedConnectToScreen %@", UYTCastScreenText(screen));
    %orig;
}

- (void)disconnectFromScreenWithError:(id)error {
    CAST_EVENT(@"manager disconnectFromScreenWithError %@ %@ %@ | %@", UYTCastErrorText(error), UYTCastSessionText(UYTCastObject(self, @"session")), UYTCastNetText(), UYTCastCallers(8));
    %orig;
}

- (void)disconnectFromDialScreenWithReceiverStatusCheckIfNeededWithError:(id)error {
    CAST_EVENT(@"manager disconnectFromDialScreenWithReceiverStatusCheck %@ | %@", UYTCastErrorText(error), UYTCastCallers(6));
    %orig;
}

- (void)screenAppStatusPollCompletedWithStatus:(NSInteger)status {
    CAST_EVENT(@"manager screenAppStatusPollCompleted status=%ld", (long)status);
    %orig;
}

- (void)handleMDXConnectionStateDidChangeToConnectedFromState:(NSInteger)state {
    CAST_EVENT(@"manager connection state -> connected (was %ld) %@", (long)state, UYTCastSessionText(UYTCastObject(self, @"session")));
    %orig;
}

- (void)handleMDXConnectionStateDidChangeToDisconnectedFromState:(NSInteger)state {
    CAST_EVENT(@"manager connection state -> disconnected (was %ld) %@ | %@", (long)state, UYTCastSessionText(UYTCastObject(self, @"session")), UYTCastCallers(6));
    %orig;
}

- (void)didReceiveTransferSessionWithDeviceID:(id)deviceID sessionState:(id)state {
    CAST_EVENT(@"manager didReceiveTransferSession %@", UYTCastSessionText(UYTCastObject(self, @"session")));
    %orig;
}

- (void)reachabilityDidChange {
    CAST_EVENT(@"manager reachabilityDidChange %@ %@", UYTCastNetText(), UYTCastSessionText(UYTCastObject(self, @"session")));
    %orig;
}

- (void)performForegroundSessionRefresh {
    CAST_EVENT(@"manager performForegroundSessionRefresh %@", UYTCastSessionText(UYTCastObject(self, @"session")));
    %orig;
}

%end

%hook MDXSessionImpl

- (void)disconnectWithError:(id)error {
    CAST_EVENT(@"session disconnectWithError %@ %@ | %@", UYTCastErrorText(error), UYTCastSessionText(self), UYTCastCallers(8));
    %orig;
}

- (void)disconnectWithReceiverStatusCheckWithError:(id)error shouldDisconnectIfReceiverStatusReceived:(BOOL)shouldDisconnect {
    CAST_EVENT(@"session disconnectWithReceiverStatusCheck %@ shouldDisconnectIfReceiverStatusReceived=%d %@ | %@", UYTCastErrorText(error), shouldDisconnect, UYTCastSessionText(self), UYTCastCallers(6));
    %orig;
}

- (void)channelController:(id)controller didDisconnectChannelWithError:(id)error {
    CAST_EVENT(@"session channel disconnected %@ %@", UYTCastErrorText(error), UYTCastSessionText(self));
    %orig;
}

- (void)remoteDisconnected:(id)remote {
    CAST_EVENT(@"session remoteDisconnected %@", UYTCastSessionText(self));
    %orig;
}

- (void)loungeScreenDisconnected:(id)screen {
    CAST_EVENT(@"session loungeScreenDisconnected %@ %@", UYTCastScreenText(screen), UYTCastSessionText(self));
    %orig;
}

- (void)transferSessionReceived:(id)transfer {
    CAST_EVENT(@"session transferSessionReceived %@", UYTCastSessionText(self));
    %orig;
}

- (BOOL)shouldDisconnectWithNetworkChanged {
    BOOL result = %orig;
    CAST_EVENT(@"session shouldDisconnectWithNetworkChanged -> %d %@ %@", result, UYTCastNetText(), UYTCastSessionText(self));
    return result;
}

%end

%hook MDXCloudSession

- (void)disconnectWithError:(id)error {
    CAST_EVENT(@"cloud session disconnectWithError %@ %@ | %@", UYTCastErrorText(error), UYTCastSessionText(self), UYTCastCallers(8));
    %orig;
}

%end

%hook MDXCastSession

- (void)sessionManager:(id)manager didEndCastSession:(id)castSession withError:(id)error {
    CAST_EVENT(@"cast session ended by the Cast SDK %@ %@", UYTCastErrorText(error), UYTCastSessionText(self));
    %orig;
}

- (void)sessionManager:(id)manager didSuspendCastSession:(id)castSession withReason:(NSInteger)reason {
    CAST_EVENT(@"cast session suspended by the Cast SDK reason=%ld %@ %@", (long)reason, UYTCastNetText(), UYTCastSessionText(self));
    %orig;
}

- (void)sessionManager:(id)manager didFailToStartCastSession:(id)castSession withError:(id)error {
    CAST_EVENT(@"cast session failed to start %@ %@", UYTCastErrorText(error), UYTCastSessionText(self));
    %orig;
}

- (void)sessionManager:(id)manager didStartCastSession:(id)castSession {
    CAST_EVENT(@"cast session started %@ %@", UYTCastSessionText(self), UYTCastNetText());
    %orig;
}

- (void)request:(id)request didFailWithError:(id)error {
    CAST_EVENT(@"cast request failed %@ %@", UYTCastObjectText(error), UYTCastSessionText(self));
    %orig;
}

- (void)request:(id)request didAbortWithReason:(NSInteger)reason {
    CAST_EVENT(@"cast request aborted reason=%ld %@", (long)reason, UYTCastSessionText(self));
    %orig;
}

// What the cast session itself reports as an error event.
- (void)logToECatcher:(id)message error:(id)error {
    CAST_EVENT(@"cast session error event %@ %@", UYTCastObjectText(message), UYTCastObjectText(error));
    %orig;
}

%end

%hook MDXDIALSession

- (void)dialScreen:(id)screen appStatusDidChange:(NSInteger)status {
    CAST_EVENT(@"dial session app status=%ld %@", (long)status, UYTCastScreenText(screen));
    %orig;
}

- (void)finishLaunchWithError:(id)error {
    CAST_EVENT(@"dial session finishLaunch %@", UYTCastErrorText(error));
    %orig;
}

%end

%hook MDXCastScreenDiscoveryManager

// (onDeviceRemoved: is hooked in uYouPlusCastingStayOnCast.xm, which also records it.)
- (void)onDeviceDiscovered:(id)event {
    CAST_EVENT(@"discovery onDeviceDiscovered %@", UYTCastObjectText(event));
    %orig;
}

%end

%hook MDXDiscoveredScreensList

- (void)screenDiscoveryManager:(id)manager onlineScreensDidChange:(id)screens {
    if (UYTCastDiagOn()) UYTCastChange(@"screen list ->", UYTCastScreensText(screens));
    %orig;
}

%end

%hook MDXRecoveryManager

- (void)MDXSessionManager:(id)manager didStartSession:(id)session {
    CAST_EVENT(@"recovery manager sees session start %@", UYTCastSessionText(session));
    %orig;
}

- (void)MDXSessionManager:(id)manager didEndSession:(id)session withError:(id)error {
    CAST_EVENT(@"recovery manager sees session end %@ %@", UYTCastErrorText(error), UYTCastSessionText(session));
    %orig;
}

%end

%hook MDXRouteButton

// The cast button's icon: connected, connecting, disconnected, AirPlay, or "device awareness" (the monitor with a phone).
- (void)setDeviceAwareness:(BOOL)on {
    if (on) UYTCastChange(@"cast button ->", @"deviceAwareness (monitor and phone)");
    %orig;
}

- (void)setConnected:(BOOL)on {
    if (on) UYTCastChange(@"cast button ->", @"connected");
    %orig;
}

- (void)setConnecting:(BOOL)on {
    if (on) UYTCastChange(@"cast button ->", @"connecting");
    %orig;
}

- (void)setDisconnected:(BOOL)on {
    if (on) UYTCastChange(@"cast button ->", @"disconnected");
    %orig;
}

- (void)setConnectedToAirPlay:(BOOL)on {
    if (on) UYTCastChange(@"cast button ->", @"connected to AirPlay");
    %orig;
}

%end

%hook MDXDiscoveredScreensSanitizer

// YES: a cloud screen of the Media Hub takes the place of a running Cast screen in the list.
- (BOOL)remoteScreenInDictionary:(id)dictionary fromOnlineScreens:(id)screens preferredOverScreen:(id)screen usingFriendlyName:(BOOL)useFriendlyName {
    BOOL result = %orig;
    if (result) UYTCastChange(@"sanitizer: a cloud screen replaces the Cast screen", UYTCastScreenText(screen));
    return result;
}

// NO: the DIAL screen of a TV is preferred over its Cast screen.
- (BOOL)shouldPreferCastOverDIALWithCastScreen:(id)castScreen DIALScreen:(id)dialScreen {
    BOOL result = %orig;
    if (!result) UYTCastChange(@"sanitizer: the DIAL screen is preferred over the Cast screen", UYTCastScreenText(castScreen));
    return result;
}

%end

// Developer setting: the Cast SDK writes its whole log to Documents/cast_sdk_logs.txt. Read once when the discovery manager is set
// up, so it has to answer YES from the first call. Two classes implement it (the settings object and the defaults store).
%hook YTSettingsImpl

- (BOOL)enableCastSDKLogging {
    return UYTCastDiagOn() ? YES : %orig;
}

%end

%hook YTUserDefaults

- (BOOL)enableCastSDKLogging {
    return UYTCastDiagOn() ? YES : %orig;
}

%end

%end

static void UYTCastObserveAppState(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSDictionary<NSString *, NSString *> *names = @{
        UIApplicationWillResignActiveNotification: @"app will resign active",
        UIApplicationDidBecomeActiveNotification: @"app did become active",
        UIApplicationDidEnterBackgroundNotification: @"app did enter background",
        UIApplicationWillEnterForegroundNotification: @"app will enter foreground",
    };
    [names enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *text, BOOL *stop) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            // Only once a cast event has been seen, so the timeline is not filled with app state changes unrelated to casting.
            if (UYTCastTimelineHasEntries()) UYTCastEvent(@"%@", text);
        }];
    }];
}

%ctor {
    UYTCastTrimSDKLog();
    UYTCastObserveAppState();
    %init(gCastingDiagnostics);
}
