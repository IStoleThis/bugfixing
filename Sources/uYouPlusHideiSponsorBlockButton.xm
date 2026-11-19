// Hide iSponsorBlock's button in the top bar.
//
// iSponsorBlock (Tweaks/iSponsorBlock, group JustSettings) puts a button for its settings into the top bar of every top-level page,
// next to the cast and search buttons. It creates the button in -[YTHeaderViewController initWithParentResponder:] and hands it to
// the header's YTRightNavigationButtons with -setButton:forType: under a type of its own, 'ispb'. -[YTHeaderViewController
// setRightButtons] hands it over again every time the header is rebuilt (and hands over nil on pages that are not top level).
//
// Upstream uYouEnhanced had a switch for this (kHideiSponsorBlockButton), but its hook looked for a sponsorBlockButton property on
// YTRightNavigationButtons. iSponsorBlock keeps that property on YTHeaderViewController, so the hook could never find the button,
// and upstream later took the hook out while the switch's key stayed. This hook drops the button at the moment iSponsorBlock hands
// it over, so the button is never placed and leaves no gap. YouTube 21.38.2 has -setButton:forType: (v32@0:8@16Q24) with its own
// branch for a nil button, which is what iSponsorBlock itself passes on pages that are not top level.
//
// iSponsorBlock's settings stay reachable from the "iSponsorBlock Settings" row on the uYouEnhanced settings page
// (uYouPlusSettings.xm). The switch is on by default in this fork (uYouPlusForkDefaults.xm). A change applies the next time a page
// builds its top bar; restarting the app covers every page.

#import "uYouPlus.h"

// iSponsorBlock's button type: the multi-character constant 'ispb'.
static const unsigned long long kISBNavigationButtonType = 0x69737062;

%hook YTRightNavigationButtons

- (void)setButton:(id)button forType:(unsigned long long)type {
    if (button && type == kISBNavigationButtonType && IS_ENABLED(kHideiSponsorBlockButton)) {
        %orig(nil, type);
        return;
    }
    %orig;
}

%end
