// uYou's rotate button no longer forces one landscape side.
//
// What was seen: now and then the video shows upside down in landscape, and turning the phone turns it upside down again.
//
// What the code says (uYou 3.0.4, read from the arm64 code of uYou.dylib in this build; not run on a device yet). uYou adds a
// rotate button (the SF Symbol "rotate.right") to the player's controls, YTMainAppControlsOverlayView, whenever its settings
// showuYouControls and uYouRightRotateButtonVideoControlsOverlay are unset or on, so it is there by default. Its action,
// -fullscreenToTheRight:, which uYou adds to YTMainAppControlsOverlayView, does this:
//   [[UIDevice currentDevice] setOrientation:4];                 // UIDeviceOrientationLandscapeRight
//   if (![overlay isFullscreen]) [overlay didPressToggleFullscreen];
//   [[DownloadsManager sharedInstance] tapticFeedback];
//   [[UIDevice currentDevice] setOrientation:1];                 // UIDeviceOrientationPortrait
// -[UIDevice setOrientation:] is private and overrides the orientation the device reports. The first call turns the screen to one
// fixed landscape side whatever way the phone is held, so a phone held the other way shows the video upside down. The second call
// leaves the device reporting "portrait" while the screen stays in landscape, so the next real turn of the phone is worked out
// from the wrong starting point and can end upside down again. uYou's "Fullscreen on the right" setting (fullscreenOnTheRight)
// does the same from -[YTWatchController showFullScreen] / -didCancelExitFullscreen, but it is off unless it is turned on.
// Nothing else in this build forces an orientation: YouTube itself only asks iOS for landscape (both sides) through
// -[YTWatchLayerViewController requestGeometryUpdateForFullscreenButtonBehavior:errorHandler:], and iOS picks the side the phone is
// held in.
//
// What this file does, behind "Fix the Rotate Button" (kFixRotateButton, on by default): while uYou's -fullscreenToTheRight: runs,
// -[UIDevice setOrientation:] is skipped. The button still opens fullscreen through YouTube's own toggle, so iOS turns the screen
// to the side the phone is held in, and the device keeps reporting its real orientation afterwards. The haptic tap stays. The
// action is wrapped when the first player controls are made, after uYou has added it; a build without uYou has nothing to wrap.

#import "uYouPlus.h"
#import "UYTLog.h"

static NSInteger sUYTInRotateButton = 0;   // > 0 while uYou's rotate action runs (main thread, a button action)
static void (*orig_uYouFullscreenToTheRight)(id, SEL, id);

static void UYT_uYouFullscreenToTheRight(id self, SEL _cmd, id sender) {
    if (!IS_ENABLED(kFixRotateButton)) {
        orig_uYouFullscreenToTheRight(self, _cmd, sender);
        return;
    }
    sUYTInRotateButton++;
    orig_uYouFullscreenToTheRight(self, _cmd, sender);
    sUYTInRotateButton--;
}

static void UYTWrapUYouRotateButton(void) {
    static BOOL wrapped = NO;
    if (wrapped) return;
    Class cls = objc_getClass("YTMainAppControlsOverlayView");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"fullscreenToTheRight:")) : NULL;
    if (!method) return;
    orig_uYouFullscreenToTheRight = (void (*)(id, SEL, id))method_setImplementation(method, (IMP)&UYT_uYouFullscreenToTheRight);
    wrapped = YES;
    UYTDebugInfo(@"[uYouPlus] RotateButton: uYou's rotate button no longer forces the device orientation");
}

%group gRotateButtonFix

%hook UIDevice

- (void)setOrientation:(long long)orientation {
    if (sUYTInRotateButton > 0) {
        UYTDebugInfo(@"[uYouPlus] RotateButton: uYou asked to force device orientation %lld, skipped", orientation);
        return;
    }
    %orig;
}

%end

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    id view = %orig;
    UYTWrapUYouRotateButton();
    return view;
}

%end

%end

%ctor {
    %init(gRotateButtonFix);
}
