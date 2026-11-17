// Keeps the first launch from jumping to the browser.
//
// The symptom: the first time the app is opened after it is installed, the browser opens instead of YouTube.
//
// The likely cause (found by reading the code, not yet seen on a device): AltStore's OPEN button starts an app through a link of
// its own, altstore-<bundle id>:// (AltStore adds that link scheme to the Info.plist of every app it installs). YouTube's link
// handler does not know the scheme, treats the link as something outside the app, and hands it to the system to open
// (-[YTAppDelegate application:openURL:sourceApplication:annotation:] -> ... -> -[UIApplication openURL:options:completionHandler:]).
// That is how a link meant to start the app can send the phone to the browser.
//
// Two guards, either of which is enough for that cause, and the second also covers any other cause:
//  1. A link of the sideloader's own (altstore-... / sidestore-...) is a request to start the app and nothing else. It is taken
//     here and not passed on to YouTube, and it is removed from the launch options, so YouTube never sees it.
//  2. On the first launch of a build (a fresh install or an update, found by comparing the build to the one that last ran), a
//     request to open a web page in the browser during the first seconds after start is held back, and the debug log says what
//     was held back. After that window, and on every later launch, nothing is held back.
#import "uYouPlus.h"
#import "UYTLog.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kLaunchGuardBuildKey = @"uytLaunchGuardBuild";
// Seconds after process start during which a first launch holds back requests to open the browser.
static const NSTimeInterval kLaunchGuardWindow = 20.0;

static NSTimeInterval sLaunchGuardStart = 0;
static BOOL sLaunchGuardFirstLaunch = NO;

// A link of the sideloader that installed the app: altstore-<bundle id>:// or sidestore-<bundle id>://
static BOOL UYTIsSideloaderURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme hasPrefix:@"altstore-"] || [scheme hasPrefix:@"sidestore-"];
}

// Scheme and host only. A full link can carry tokens, so it never goes into the log.
static NSString *UYTURLSummary(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return @"(not a URL)";
    return [NSString stringWithFormat:@"%@://%@", url.scheme ?: @"?", url.host ?: @""];
}

// The version string as it is in the Info.plist, with the build number the build adds. It is read with the CoreFoundation call
// so the NSBundle hook that hands YouTube the version without the number does not hide it here.
static NSString *UYTBuildToken(void) {
    CFTypeRef raw = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("CFBundleShortVersionString"));
    NSString *version = (raw && CFGetTypeID(raw) == CFStringGetTypeID()) ? (__bridge NSString *)raw : @"";
    CFTypeRef rawBuild = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("CFBundleVersion"));
    NSString *build = (rawBuild && CFGetTypeID(rawBuild) == CFStringGetTypeID()) ? (__bridge NSString *)rawBuild : @"";
    return [NSString stringWithFormat:@"%@/%@", version, build];
}

// YES while the first launch of a build is inside its window, and the link is a request to open a web page.
static BOOL UYTShouldHoldBack(NSURL *url) {
    if (!sLaunchGuardFirstLaunch) return NO;
    if ([NSProcessInfo processInfo].systemUptime - sLaunchGuardStart > kLaunchGuardWindow) return NO;
    NSString *scheme = [url isKindOfClass:[NSURL class]] ? url.scheme.lowercaseString : nil;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || UYTIsSideloaderURL(url);
}

static void UYTLogHeldBack(NSURL *url) {
    UYTDebugInfo(@"LaunchGuard: held back an open of %@ %.1fs after start (first launch of this build)",
                 UYTURLSummary(url), [NSProcessInfo processInfo].systemUptime - sLaunchGuardStart);
}

%group gLaunchGuard

%hook YTAppDelegate

// A launch that was started by the sideloader's link: YouTube is started as if it had been opened from the home screen.
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *url = [launchOptions isKindOfClass:[NSDictionary class]] ? launchOptions[UIApplicationLaunchOptionsURLKey] : nil;
    if (UYTIsSideloaderURL(url)) {
        UYTDebugInfo(@"LaunchGuard: launched by a sideloader link (%@), launch options cleaned", UYTURLSummary(url));
        NSMutableDictionary *clean = [launchOptions mutableCopy];
        [clean removeObjectForKey:UIApplicationLaunchOptionsURLKey];
        [clean removeObjectForKey:UIApplicationLaunchOptionsSourceApplicationKey];
        [clean removeObjectForKey:UIApplicationLaunchOptionsAnnotationKey];
        return %orig(application, clean.count ? clean : nil);
    }
    return %orig;
}

// YouTube 21.38 has only this one of the open-URL callbacks, so this is where a link that opened the app arrives.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    if (UYTIsSideloaderURL(url)) {
        UYTDebugInfo(@"LaunchGuard: ignored a sideloader link (%@)", UYTURLSummary(url));
        return YES;
    }
    return %orig;
}

// The step after it, where YouTube's own link handler takes over.
- (void)handleURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    if (UYTIsSideloaderURL(url)) {
        UYTDebugInfo(@"LaunchGuard: ignored a sideloader link in the handler (%@)", UYTURLSummary(url));
        return;
    }
    %orig;
}

%end

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL success))completion {
    if (UYTShouldHoldBack(url)) {
        UYTLogHeldBack(url);
        // Reported as done, so the caller has no reason to try some other way of showing the page.
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
        return;
    }
    %orig;
}

- (BOOL)openURL:(NSURL *)url {
    if (UYTShouldHoldBack(url)) {
        UYTLogHeldBack(url);
        return YES;
    }
    return %orig;
}

%end

%end

%ctor {
    UYTLogInstall(); // safe to call from any constructor (it runs once); the lines below must not be lost to a constructor that runs later
    sLaunchGuardStart = [NSProcessInfo processInfo].systemUptime;
    // First launch of this build: the build that last ran is not this one (a new install has none).
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = UYTBuildToken();
    sLaunchGuardFirstLaunch = ![[defaults stringForKey:kLaunchGuardBuildKey] isEqualToString:token];
    if (sLaunchGuardFirstLaunch) [defaults setObject:token forKey:kLaunchGuardBuildKey];
    UYTDebugInfo(@"LaunchGuard: %@ launch of build %@", sLaunchGuardFirstLaunch ? @"first" : @"later", token);
    %init(gLaunchGuard);
}
