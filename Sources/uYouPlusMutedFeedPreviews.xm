// Silent video previews in the feeds.
//
// What was seen (YouTube 21.38.2): a video preview on the Home feed plays with sound; turning the sound off with the speaker
// button on the preview does not last, the sound comes back on.
//
// What the code says (read from the arm64 code of 21.38.2; not run on a device yet):
//
// * The player of a preview is muted or unmuted in one place, -[YTInlineMutedPlaybackViewControllerManager
//   overlayDidChangeWithStatusUpdate:] (and the same in YTInlineMutedPlaybackPlayerViewControllerProviderImpl): it calls
//   -setMuted:!update.shouldTurnAudioOn on the player for every YTInlineMutedPlaybackOverlayStatusUpdate it gets.
// * Status updates are made in nine places, and several of them turn the sound on without the speaker button:
//   -systemOutputVolumeDidChangeFromVolume:toVolume: (a volume button was pressed) always asks for sound, -outputRouteDidChange
//   (headphones, Bluetooth) and the synced per-video audio state (YTInlinePlaybackAudioStateEntityModel, through
//   -[YTInlineMutedPlaybackPostVideoPlayerOverlayViewController didUpdateKey:inEntityStore:...]) can as well, and every new preview
//   starts from the app-wide "unmuted at start" state of the last one. That is why turning the sound off does not stick.
// * Eight of the nine are made with initForInception:NO. Only -[YTInlineMutedPlaybackPlayerOverlayView
//   goToWatchPageWithPlaybackTimeStamp:], the tap that opens the video, makes one with initForInception:YES.
// * -[YTInlineMutedPlaybackPlayerOverlayViewController shouldPlaybackAlwaysBeMuted] is asked only by the volume button handler,
//   which leaves the preview alone when the answer is YES.
// * The speaker and the CC button are separate views of YTInlineMutedPlaybackAudioIconView (_audioIconWithOverlayView and
//   _closedCaptionIconWithOverlayView), so the speaker can go and CC stay.
//
// What this file does, behind "Mute Video Previews" (kMuteVideoPreviews, on by default):
// 1. A status update that is not for opening the video never turns the sound on, so every preview player stays muted,
//    whatever asked for sound. The update for opening the video is left alone, so the video plays with sound as usual.
// 2. Previews count as "always muted", so a volume button no longer turns their sound on.
// 3. The speaker button is hidden (it could only turn the sound on), and a tap where it was does nothing. CC still works.
// This covers every preview that uses YouTube's inline preview player: Home, Subscriptions, Search and channel pages, Shorts
// previews in a feed, and videos in posts. The switch is read each time, so it applies to the next preview without a restart.

#import "uYouPlus.h"
#import "UYTLog.h"

@interface YTInlineMutedPlaybackOverlayStatusUpdate : NSObject
- (BOOL)shouldProcessForInception;
@end

// Declared so that the hooked object can be passed on as a UIView (Logos only forward-declares the classes it hooks).
@interface YTInlineMutedPlaybackAudioIconView : UIView
@end

static BOOL UYTMutePreviews(void) {
    return IS_ENABLED(kMuteVideoPreviews);
}

// The views of the speaker button in YTInlineMutedPlaybackAudioIconView (the older layout and the newer one), the line between
// it and CC, and the "tap for sound" hint next to it.
static const char *const kUYTPreviewSpeakerIvars[] = {
    "_audioIconWithOverlayView",
    "_audioIconFrostedGlassView",
    "_audioSoundIconImageView",
    "_verticalSeparatorView",
    "_userEducationLabel",
};

static void UYTHidePreviewSpeaker(UIView *iconView) {
    for (size_t i = 0; i < sizeof(kUYTPreviewSpeakerIvars) / sizeof(kUYTPreviewSpeakerIvars[0]); i++) {
        Ivar ivar = class_getInstanceVariable([iconView class], kUYTPreviewSpeakerIvars[i]);
        if (!ivar) continue;
        id view = object_getIvar(iconView, ivar);
        if ([view isKindOfClass:[UIView class]]) ((UIView *)view).hidden = YES;
    }
}

%group gMutedFeedPreviews

%hook YTInlineMutedPlaybackOverlayStatusUpdate

- (BOOL)shouldTurnAudioOn {
    BOOL turnOn = %orig;
    if (!turnOn || !UYTMutePreviews() || [self shouldProcessForInception]) return turnOn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UYTDebugInfo(@"[uYouPlus] MutedPreviews: a video preview asked for sound and stays muted");
    });
    return NO;
}

%end

%hook YTInlineMutedPlaybackPlayerOverlayViewController

- (BOOL)shouldPlaybackAlwaysBeMuted {
    return UYTMutePreviews() ? YES : %orig;
}

%end

%hook YTInlineMutedPlaybackPlayerOverlayView

- (void)audioIconViewDidToggleAudioIcon:(id)audioIconView {
    if (UYTMutePreviews()) return;
    %orig;
}

%end

%hook YTInlineMutedPlaybackAudioIconView

- (void)layoutSubviews {
    %orig;
    if (UYTMutePreviews()) UYTHidePreviewSpeaker(self);
}

%end

%end

%ctor {
    %init(gMutedFeedPreviews);
}
