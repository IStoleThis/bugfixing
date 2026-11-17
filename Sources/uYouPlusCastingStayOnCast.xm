// Keep a cast on the Cast connection.
//
// What was seen (YouTube 21.38.2 sideloaded, casting to an onn. / VIZIO OS TV): the cast plays for roughly 10 to 20 seconds,
// then the cast button changes to a monitor with a phone in front of it, the phone shows a "Now playing" remote for the TV, and
// the TV carries on in its own YouTube app, with ads.
//
// What the code says (read from the arm64 code of 21.38.2; not run on a device, so this is a best explanation, not a proof):
//
// * The cast button shows that monitor-and-phone icon (the "device awareness" image) only when the screen of the current
//   session answers -supportsAwareness. A Cast screen does not; the cloud ("remote") screens of YouTube's Media Hub do.
// * The list of devices is built by -[MDXDiscoveredScreensSanitizer processCastScreens:...]. For each Cast screen it asks
//   -remoteScreenInDictionary:fromOnlineScreens:preferredOverScreen:usingFriendlyName:, which, with isMediaHubDevicePickerEnabled
//   on, answers YES when the TV's own YouTube app is also known through the cloud and the Cast screen reports that the app is
//   running (which it does right after the receiver app has started). The Cast screen is then left out of the list and the
//   cloud screen takes its place.
// * With isPreferDIALRouteOverCastRouteForNonChromecastDevicesEnabled on, the same list prefers the DIAL screen of a TV that is
//   not a Chromecast over its Cast screen (-shouldPreferCastOverDIALWithCastScreen:DIALScreen:).
// * +[MDXHandoffActionUtil shouldHandleAction:] lets the app connect by itself to a TV that announces a session
//   (isAlwaysAutoconnectEnabled).
// * -[MDXCastScreenDiscoveryManager onDeviceRemoved:] disconnects from a device as soon as the Cast SDK's discovery reports it
//   gone, even when a session is running on it.
//
// The hooks below give those four decisions back to the Cast connection: the three flags answer NO and a "device removed" report
// is ignored while a session is connected. NO is what the app answered before the Media Hub existed, so the older code paths
// run. Everything sits behind the Fix Casting switch and "Keep Casting on the Cast Connection" (kCastingStayOnCast); turn the
// second one off in the settings if casting gets worse.
//
// Screens that can only be reached through the TV's own app or the cloud (a TV that is not on this network, pairing by TV code)
// are not affected: they are still listed and can still be connected, they are only no longer swapped in for a Cast screen that
// is already connected.

#import "uYouPlus.h"
#import "UYTLog.h"
#import "UYTCastRuntime.h"

static BOOL UYTStayOnCast(void) {
    return IS_ENABLED(kFixCasting) && IS_ENABLED(kCastingStayOnCast);
}

static BOOL UYTCastSessionIsConnected(void) {
    return UYTCastBool(UYTCastSharedInstance(@"MDXSessionManager"), @"isConnectedToScreen", NO);
}

%group gCastingStayOnCast

%hook MDXFeatureFlags

// The umbrella flag of the Media Hub: unified device picker, "Now playing" remote, device awareness, cloud screens preferred
// over Cast screens.
- (BOOL)isMediaHubDevicePickerEnabled {
    BOOL asked = %orig;
    if (!UYTStayOnCast()) return asked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] CastingFix: Media Hub is switched off, so a cast stays on the Cast connection (YouTube asked for it: %@)", asked ? @"yes" : @"no");
    });
    return NO;
}

- (BOOL)isAlwaysAutoconnectEnabled {
    BOOL asked = %orig;
    if (!UYTStayOnCast()) return asked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] CastingFix: automatic connecting to a TV that announces a session is switched off (YouTube asked for it: %@)", asked ? @"yes" : @"no");
    });
    return NO;
}

- (BOOL)isPreferDIALRouteOverCastRouteForNonChromecastDevicesEnabled {
    BOOL asked = %orig;
    if (!UYTStayOnCast()) return asked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] CastingFix: the Cast route is preferred over the DIAL route for every device (YouTube asked for the DIAL route for non-Chromecasts: %@)", asked ? @"yes" : @"no");
    });
    return NO;
}

%end

%hook MDXCastScreenDiscoveryManager

// The Cast SDK reports a device as removed from the list of discovered devices; the original disconnects from it at once. Mid-cast
// that tears the session down, so while a session is connected the report is only noted. If the TV really is gone, its Cast
// connection fails by itself a moment later and the session ends the normal way.
- (void)onDeviceRemoved:(id)event {
    BOOL connected = UYTCastSessionIsConnected();
    BOOL ignore = connected && UYTStayOnCast();
    UYTCastEvent(@"discovery onDeviceRemoved sessionConnected=%d %@", connected, ignore ? @"-> ignored" : @"-> passed on");
    if (ignore) return;
    %orig;
}

%end

%end

%ctor {
    %init(gCastingStayOnCast);
}
