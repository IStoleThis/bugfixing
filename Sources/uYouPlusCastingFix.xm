// Casting from a sideloaded YouTube 21.x.
//
// This was worked out by reading the Objective-C metadata and the arm64 code of YouTube 21.38.2. It has not been run
// on a device yet, so treat it as experimental until someone confirms it.
//
// Why casting stops working once the app is re-signed with a personal certificate (AltStore and the like):
//
// 1. YouTube decides whether the Local Network permission is granted with a socket probe.
//    -[MDXLocalNetworkPermissionsImpl sendMSearchRequest] sends one empty UDP datagram to the SSDP multicast address
//    239.255.255.250:1900 and treats any failure as "denied". Sending to a multicast address needs the
//    com.apple.developer.networking.multicast entitlement, which only Google's own signature carries, so on a
//    re-signed app the send always fails, even with the Local Network switch on. -isAuthorized then answers NO and
//    screen discovery, connecting to a screen and the device picker all refuse to run.
//    Older builds picked the probe with the cxClientEnableIosLocalNetworkPermission... flags that Fix Casting forces
//    (the YTweaks hooks). 21.x runs the probe unconditionally and no longer reads those flags.
//
// 2. The Cast SDK is configured with customMulticastEnabled = !areCastBonjourOverridesEnabled, an A/B flag that is off
//    for most accounts. With custom multicast on, Chromecasts are found by the SDK's own mDNS client, which sends to a
//    multicast address as well and fails for the same reason. With it off, the SDK browses _googlecast._tcp through
//    the system's Bonjour (NSNetServiceBrowser), which needs only the Local Network switch.
//
// The two hooks below leave the real permission to iOS. YouTube stops probing, and the first Bonjour browse makes iOS
// show its own "find devices on your local network" prompt. If that switch is later turned off in iOS Settings,
// casting finds no devices and YouTube does not show its own "permission needed" page.
//
// Both hooks sit behind the Fix Casting switch (kFixCasting) and call %orig when it is off. A class or method that a
// YouTube version does not have is simply never hooked. Screens that can only be found with SSDP (older DIAL-only TVs)
// stay undiscoverable on a sideloaded build for the same entitlement reason; pairing with the TV code still works.

#import "uYouPlus.h"
#import "UYTLog.h"

%group gCastingFix

%hook MDXLocalNetworkPermissionsImpl

// YES in 21.38.2 (older builds read a config flag here). When it answers NO, -lastKnownPermissionsStatus reports
// "authorized" (1) and -verifyAccessWithCompletion: calls its completion with 1 without opening a socket.
- (BOOL)localNetworkPermissionCheckRequired {
    BOOL required = %orig;
    if (!IS_ENABLED(kFixCasting)) return required;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] CastingFix: YouTube's local network permission probe is switched off (YouTube asked for it: %@)", required ? @"yes" : @"no");
    });
    return NO;
}

%end

%hook GCKCastOptions

// Read once, when the Cast SDK builds its device scanner. NO selects the system Bonjour browser.
- (BOOL)isCustomMulticastEnabled {
    BOOL custom = %orig;
    if (!IS_ENABLED(kFixCasting)) return custom;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] CastingFix: Cast discovery uses the system's Bonjour browser (YouTube asked for its own multicast client: %@)", custom ? @"yes" : @"no");
    });
    return NO;
}

%end

%end

%ctor {
    %init(gCastingFix);
}
