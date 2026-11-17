// Default settings of this fork, applied once per install.
//
//   * AdBlock Workaround (the stronger ad blocker) on; the Lite variant and uYou's own "Remove YouTube ads" off, they overlap
//     with it (the Lite switch even says it disables uYou's option).
//   * Shorts, Create (+) and uYou tabs hidden. uYou reads these three switches every time the tab bar is built, so they
//     do not need a restart on top of the first launch.
//   * "YouTube featured" shelf on the Home feed hidden (HideYouTubeFeatured.xm).
//
// This is a versioned, run-once migration rather than "set it when the key is missing". An install that was updated from an
// earlier build already holds stored values for some of these keys (the ad-block switches are written on the first launch),
// and "when missing" would leave those as they were. After the migration has run, every switch belongs to the user again:
// turning one off in the settings sticks. To change the defaults of an existing install later, edit the list below and raise
// kForkDefaultsVersion.
//
// AdBlocking.xm decides in its constructor which ad-block group to install, so the migration has to be done before that
// constructor reads the switches. Constructors of different files run in no guaranteed order, so each of them calls
// UYTApplyForkDefaults() first; the call is idempotent.
#import "uYouPlus.h"
#import "UYTLog.h"

static const NSInteger kForkDefaultsVersion = 1;
static NSString *const kForkDefaultsVersionKey = @"bugfixingForkDefaultsVersion";

void UYTApplyForkDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults integerForKey:kForkDefaultsVersionKey] >= kForkDefaultsVersion) return;

        // Ad blocker.
        [defaults setBool:YES forKey:kAdBlockWorkaround];
        [defaults setBool:NO forKey:kAdBlockWorkaroundLite];
        [defaults setBool:NO forKey:@"removeYouTubeAds"];

        // Tab bar (uYou's switches).
        [defaults setBool:YES forKey:@"hideShortsTab"];
        [defaults setBool:YES forKey:@"hideCreateTab"];
        [defaults setBool:YES forKey:@"hideUYouTab"];

        // Home feed.
        [defaults setBool:YES forKey:kHideYouTubeFeatured];

        [defaults setInteger:kForkDefaultsVersion forKey:kForkDefaultsVersionKey];

        UYTLogInstall();
        UYTDebugInfo(@"ForkDefaults v%ld applied: AdBlock Workaround on, Shorts/Create/uYou tabs hidden, YouTube featured shelf hidden", (long)kForkDefaultsVersion);
    });
}
