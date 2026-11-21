// Default settings of this fork, applied once per install.
//
// Version 1:
//   * AdBlock Workaround (the stronger ad blocker) on; the Lite variant and uYou's own "Remove YouTube ads" off, they overlap
//     with it (the Lite switch even says it disables uYou's option).
//   * Shorts, Create (+) and uYou tabs hidden. uYou reads these three switches every time the tab bar is built, so they
//     do not need a restart on top of the first launch.
//   * "YouTube featured" shelf on the Home feed hidden (HideYouTubeFeatured.xm).
//   * Casting: "Keep Casting on the Cast Connection" (uYouPlusCastingStayOnCast.xm) and the casting diagnostics
//     (uYouPlusCastingDiagnostics.xm) on.
// Version 2:
//   * "SponsorBlock While Casting" (uYouPlusCastingSponsorBlock.xm) on.
//   * iSponsorBlock's button in the top bar hidden (uYouPlusHideiSponsorBlockButton.xm); its settings are on the uYouEnhanced
//     settings page instead.
// Version 3:
//   * "Mute Video Previews" (uYouPlusMutedFeedPreviews.xm) on.
//   * Community post shelves on the Home feed hidden (HideYouTubeFeatured.xm).
// Version 4:
//   * "Fit Shelf Cards to the Screen" (uYouPlusFitShelfCards.xm) on, and the community post shelves shown again (their cards are
//     fitted instead of the shelves being hidden; the hide switch stays for whoever wants it).
//   * "Fix the Rotate Button" (uYouPlusRotateButtonFix.xm) on.
//
// This is a versioned, run-once migration rather than "set it when the key is missing". An install that was updated from an
// earlier build already holds stored values for some of these keys (the ad-block switches are written on the first launch),
// and "when missing" would leave those as they were. Each version only sets the switches it added, so an install that already
// had version 1 gets the version 2 switches and keeps every choice made since version 1. After the migration has run, every
// switch belongs to the user again: turning one off in the settings sticks. To change the defaults of an existing install later,
// add a step below and raise kForkDefaultsVersion.
//
// AdBlocking.xm decides in its constructor which ad-block group to install, so the migration has to be done before that
// constructor reads the switches. Constructors of different files run in no guaranteed order, so each of them calls
// UYTApplyForkDefaults() first; the call is idempotent.
#import "uYouPlus.h"
#import "UYTLog.h"

static const NSInteger kForkDefaultsVersion = 4;
static NSString *const kForkDefaultsVersionKey = @"bugfixingForkDefaultsVersion";

void UYTApplyForkDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSInteger applied = [defaults integerForKey:kForkDefaultsVersionKey];
        if (applied >= kForkDefaultsVersion) return;

        if (applied < 1) {
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

            // Casting.
            [defaults setBool:YES forKey:kCastingStayOnCast];
            [defaults setBool:YES forKey:kCastingDiagnostics];
        }

        if (applied < 2) {
            // SponsorBlock.
            [defaults setBool:YES forKey:kCastingSponsorBlock];
            [defaults setBool:YES forKey:kHideiSponsorBlockButton];
        }

        if (applied < 3) {
            // Home feed: silent previews, no community post shelves.
            [defaults setBool:YES forKey:kMuteVideoPreviews];
            [defaults setBool:YES forKey:kHideCommunitiesShelf];
        }

        if (applied < 4) {
            // Community post cards fitted to the screen instead of hidden; uYou's rotate button no longer forces a side.
            [defaults setBool:YES forKey:kFitShelfCards];
            [defaults setBool:NO forKey:kHideCommunitiesShelf];
            [defaults setBool:YES forKey:kFixRotateButton];
        }

        [defaults setInteger:kForkDefaultsVersion forKey:kForkDefaultsVersionKey];

        UYTLogInstall();
        UYTDebugInfo(@"ForkDefaults v%ld applied (this install was at v%ld): %@%@%@%@", (long)kForkDefaultsVersion, (long)applied,
            applied < 1 ? @"AdBlock Workaround on, Shorts/Create/uYou tabs hidden, YouTube featured shelf hidden, casting switches on; " : @"",
            applied < 2 ? @"SponsorBlock While Casting on, iSponsorBlock top bar button hidden; " : @"",
            applied < 3 ? @"video previews muted; " : @"",
            @"shelf cards fitted to the screen (community shelves shown), rotate button fixed");
    });
}
