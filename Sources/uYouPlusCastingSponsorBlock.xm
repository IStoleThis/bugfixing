// SponsorBlock while casting.
//
// What YouTube 21.38.2 does during a cast (read from its arm64 code; not run on a device yet):
//
// * -[YTPlayerViewController isMDXActive] asks the player's _playbackController. During a cast that is an MDXPlaybackController,
//   which always answers YES; otherwise it is a YTLocalPlaybackController, which answers NO.
// * The TV's position: MDXVideoProgressController runs an MDXRepeatingTimer every 0.25 s while the TV reports that it is playing,
//   and hands the position to -[MDXSingleVideoController videoDidProgressToTime:]. That posts it through the video's
//   YTSingleVideoEventCenter to the "side-effectful current time" observers, and the player registers itself there for every video
//   it activates (-startObservingStateChangesOnActiveVideo). So -[YTPlayerViewController potentiallyMutatedSingleVideo:
//   currentVideoTimeDidChange:], the method iSponsorBlock skips from, keeps running during a cast, with the TV's position.
// * A new video on the TV: -[MDXPlaybackController startContentVideoControllerWithPlayerResponse:] calls
//   -notifyDidActivateVideo:withPlaybackData:, which calls -[YTPlayerViewController playbackController:didActivateVideo:
//   withPlaybackData:], where iSponsorBlock fetches the segments. The player overlay stays a YTMainAppVideoPlayerOverlayView (it is
//   only switched into its MDX mode), so iSponsorBlock's overlay checks pass.
// * A seek: -[YTPlayerViewController seekToTime:] goes to -[MDXPlaybackController seekToTime:toleranceBefore:toleranceAfter:
//   seekSource:], which calls -[MDXSessionImpl seekTo:] only when -isCurrentVideoLoaded (the TV is on the video the phone expects,
//   its player state is not -1 and the video is not merely cued); otherwise the seek is dropped without a word. -seekTo: moves the
//   phone's clock to the new time at once and sends the TV a "seekTo" message whose newTime is rounded to the nearest whole second.
//
// So iSponsorBlock's skips already reach the TV. What goes wrong while casting, and what this file does about it:
//
// 1. A skip to 125.3 s is sent as 125 s, and the TV plays the last moment of the segment. While casting, iSponsorBlock's skips are
//    rounded up to the next whole second (never past the end of the video).
// 2. A dropped or ignored seek: iSponsorBlock has already moved on to the next segment, so the segment plays out. For a few seconds
//    after each skip the TV's position is watched, and the skip is sent again (at most twice more) while the TV is still inside the
//    part that was skipped. The check stops when another seek happens, the video changes or the cast ends.
// 3. The channel whitelist: iSponsorBlock reads the channel only from a local video (YTSingleVideoController). A cast video is an
//    MDXSingleVideoController, which is a plain NSObject, so the whitelist used the channel of the last video played on the phone.
//    The channel of the video on the TV is taken from its player response instead.
// 4. Each skip during a cast, and what the TV did with it, goes into the cast timeline of the debug report (Casting Diagnostics),
//    together with the number of segments iSponsorBlock loaded for the video on the TV.
//
// iSponsorBlock adds its methods (isb_scrubToTime:, setSkipSegments:, setChannelID:) to YTPlayerViewController when the app has
// finished launching, after this file's constructor has run, so they are wrapped through the runtime the first time a video is
// activated. A build without iSponsorBlock (SPONSORBLOCK_ENABLED=0), or with iSponsorBlock switched off in its own settings, has
// none of them, and then nothing here changes anything. Everything sits behind "SponsorBlock While Casting" (kCastingSponsorBlock)
// and only acts while -isMDXActive answers YES; with the switch off, iSponsorBlock runs exactly as it comes.

#import "uYouPlus.h"
#import "UYTLog.h"
#import "UYTCastRuntime.h"
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideoTime.h>
#import <math.h>

static const NSTimeInterval kCastSBResendAfter = 1.5;  // seconds after a send before the TV's position counts as "did not move"
static const NSTimeInterval kCastSBSettle = 4.0;       // seconds after a send before a skip counts as confirmed
static const NSTimeInterval kCastSBGiveUp = 30.0;      // a check that got no position report for this long is dropped
static const NSInteger kCastSBMaxSends = 3;            // the first send and two more
static const double kCastSBMargin = 1.0;               // the TV counts as past the segment from this close to the target

static BOOL UYTCastSBOn(void) {
    return IS_ENABLED(kCastingSponsorBlock);
}

static BOOL UYTCastSBCasting(id player) {
    return UYTCastBool(player, @"isMDXActive", NO);
}

static double UYTCastSBDouble(id target, NSString *selectorName, double fallback) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:sel]) return fallback;
    return ((double (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *UYTCastSBString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// Where a skip is sent while casting: the TV only takes whole seconds (rounded to the nearest), so round up, but not past the end.
static double UYTCastSBTarget(double asked, double total) {
    double target = asked - floor(asked) > 0.01 ? ceil(asked) : round(asked);
    if (total > 0 && target > total) target = total;
    return target;
}

// ---------------------------------------------------------------------------------------------------- the skip being checked

static struct {
    BOOL active;
    double from;           // the TV's position when iSponsorBlock asked for the skip
    double target;         // where the TV was sent
    NSInteger sends;
    NSTimeInterval sentAt; // uptime of the last send
    NSTimeInterval lastReport;
} sSkip;
static NSString *sSkipVideoID;
static __weak id sSkipPlayer;
static NSInteger sOwnSeek;  // > 0 while this file or iSponsorBlock is seeking, so other seeks can be told apart

static void UYTCastSBStop(NSString *reason) {
    if (sSkip.active && reason) UYTCastEvent(@"sponsorblock: check stopped, %@", reason);
    sSkip.active = NO;
    sSkipVideoID = nil;
    sSkipPlayer = nil;
}

static void UYTCastSBSeek(YTPlayerViewController *player, double target) {
    sOwnSeek++;
    [player seekToTime:target];
    sOwnSeek--;
}

// Called for every position report of the player that sent the skip.
static void UYTCastSBCheck(YTPlayerViewController *player, double now) {
    NSTimeInterval uptime = [NSProcessInfo processInfo].systemUptime;
    if (!UYTCastSBCasting(player)) {
        UYTCastSBStop(@"the cast ended");
        return;
    }
    NSString *videoID = UYTCastSBString([player currentVideoID]);
    if (!videoID || ![videoID isEqualToString:sSkipVideoID]) {
        UYTCastSBStop(@"the video on the TV changed");
        return;
    }
    sSkip.lastReport = uptime;
    if (now < sSkip.from - 2.0) {
        UYTCastSBStop([NSString stringWithFormat:@"the TV went back to %.1fs, before the segment", now]);
        return;
    }
    NSTimeInterval sinceSend = uptime - sSkip.sentAt;
    if (now >= sSkip.target - kCastSBMargin) {
        // The phone's clock jumps to the target as soon as the seek is sent; the TV's own report can pull it back a moment later,
        // so keep watching for a while before calling it done.
        if (sinceSend >= kCastSBSettle) {
            UYTCastEvent(@"sponsorblock: skip confirmed, TV at %.1fs", now);
            UYTCastSBStop(nil);
        }
        return;
    }
    if (sinceSend < kCastSBResendAfter) return;
    if (sSkip.sends >= kCastSBMaxSends) {
        UYTCastEvent(@"sponsorblock: TV still at %.1fs after %ld sends, gave up", now, (long)sSkip.sends);
        UYTCastSBStop(nil);
        return;
    }
    sSkip.sends++;
    sSkip.sentAt = uptime;
    UYTCastEvent(@"sponsorblock: TV still at %.1fs, skip to %.0fs sent again (%ld of %ld)", now, sSkip.target, (long)sSkip.sends, (long)kCastSBMaxSends);
    UYTCastSBSeek(player, sSkip.target);
}

// ---------------------------------------------------------------------------------------------------- iSponsorBlock's methods

static void (*orig_isbScrubToTime)(id, SEL, double);
static void (*orig_isbSetSkipSegments)(id, SEL, id);

// -[YTPlayerViewController isb_scrubToTime:]: every seek iSponsorBlock makes (auto skip, manual skip, unskip, highlight).
static void UYTCastSB_isbScrubToTime(YTPlayerViewController *self, SEL _cmd, double asked) {
    if (!UYTCastSBOn() || !UYTCastSBCasting(self)) {
        orig_isbScrubToTime(self, _cmd, asked);
        return;
    }
    double now = [self currentVideoMediaTime];
    double total = [self currentVideoTotalMediaTime];
    BOOL backward = asked < now - 0.5;
    double target = backward ? asked : UYTCastSBTarget(asked, total);
    sOwnSeek++;
    orig_isbScrubToTime(self, _cmd, target);
    sOwnSeek--;
    if (backward) {
        UYTCastSBStop(@"iSponsorBlock went back (unskip)");
        UYTCastEvent(@"sponsorblock: back on the TV %.1fs -> %.1fs", now, target);
        return;
    }
    UYTCastSBStop(sSkip.active ? @"a new skip" : nil);
    if (target < now + kCastSBMargin) {
        // Less than a second to skip: nothing the TV's reports could tell apart, so it is only sent.
        UYTCastEvent(@"sponsorblock: skip on the TV %.1fs -> %.0fs (iSponsorBlock asked for %.2fs), too short to check", now, target, asked);
        return;
    }
    NSTimeInterval uptime = [NSProcessInfo processInfo].systemUptime;
    sSkip.active = YES;
    sSkip.from = now;
    sSkip.target = target;
    sSkip.sends = 1;
    sSkip.sentAt = uptime;
    sSkip.lastReport = uptime;
    sSkipVideoID = UYTCastSBString([self currentVideoID]);
    sSkipPlayer = self;
    UYTCastEvent(@"sponsorblock: skip on the TV %.1fs -> %.0fs (iSponsorBlock asked for %.2fs) video=%@", now, target, asked, sSkipVideoID ?: @"?");
}

// -[YTPlayerViewController setSkipSegments:]: iSponsorBlock's segments for the active video (only the ones it may skip).
static void UYTCastSB_isbSetSkipSegments(YTPlayerViewController *self, SEL _cmd, id segments) {
    orig_isbSetSkipSegments(self, _cmd, segments);
    if (!UYTCastSBOn() || !UYTCastSBCasting(self)) return;
    NSUInteger count = [segments isKindOfClass:[NSArray class]] ? [(NSArray *)segments count] : 0;
    UYTCastEvent(@"sponsorblock: %lu segment(s) to skip loaded for the video on the TV (%@)", (unsigned long)count, UYTCastSBString([self currentVideoID]) ?: @"?");
}

static BOOL UYTCastSBWrap(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

// iSponsorBlock adds these when the app has finished launching; tried again on every activated video until they are there.
static void UYTCastSBWrapISponsorBlock(void) {
    static BOOL scrubWrapped, segmentsWrapped;
    if (scrubWrapped && segmentsWrapped) return;
    Class cls = objc_getClass("YTPlayerViewController");
    if (!cls) return;
    if (!scrubWrapped) {
        scrubWrapped = UYTCastSBWrap(cls, @"isb_scrubToTime:", (IMP)&UYTCastSB_isbScrubToTime, (IMP *)&orig_isbScrubToTime);
        if (scrubWrapped) UYTDebugInfo(@"[uYouPlus] SponsorBlock while casting: iSponsorBlock's seeks are watched while casting");
    }
    if (!segmentsWrapped) {
        segmentsWrapped = UYTCastSBWrap(cls, @"setSkipSegments:", (IMP)&UYTCastSB_isbSetSkipSegments, (IMP *)&orig_isbSetSkipSegments);
    }
}

// The channel of the video on the TV: MDXSingleVideoController -playerResponse -> YTPlayerResponse -playerData ->
// YTIPlayerResponse -videoDetails -> YTIVideoDetails -channelId (the last two are protobuf properties resolved at run time).
static NSString *UYTCastSBChannelOfVideo(id video) {
    id response = UYTCastObject(video, @"playerResponse");
    id data = UYTCastObject(response, @"playerData");
    id details = UYTCastObject(data, @"videoDetails");
    return UYTCastSBString(UYTCastObject(details, @"channelId"));
}

%group gCastingSponsorBlock

%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    UYTCastSBWrapISponsorBlock();
    if (sSkip.active && sSkipPlayer == self) UYTCastSBStop(@"another video was activated");
    if (!UYTCastSBOn() || !UYTCastSBCasting(self)) return;
    // iSponsorBlock's own hook of this method runs around this one (it is installed later) and leaves channelID alone for a
    // video that is not a YTSingleVideoController, so the value set here is the one its whitelist check sees.
    NSString *channel = UYTCastSBChannelOfVideo(video);
    SEL setChannel = NSSelectorFromString(@"setChannelID:");
    if (channel.length && [self respondsToSelector:setChannel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, setChannel, channel);
    }
    UYTCastEvent(@"sponsorblock: video %@ activated on the TV (channel %@)", UYTCastSBString([self currentVideoID]) ?: @"?", channel.length ? @"known" : @"unknown");
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(YTSingleVideoTime *)videoTime {
    %orig;
    if (!sSkip.active) return;
    if (sSkipPlayer != self) {
        if (!sSkipPlayer) UYTCastSBStop(@"the player went away");
        return;
    }
    if (!UYTCastSBOn()) {
        UYTCastSBStop(@"switched off");
        return;
    }
    if ([NSProcessInfo processInfo].systemUptime - sSkip.lastReport > kCastSBGiveUp) {
        UYTCastSBStop(@"no position report from the TV for a while");
        return;
    }
    UYTCastSBCheck(self, UYTCastSBDouble(videoTime, @"time", [self currentVideoMediaTime]));
}

// Every seek of the player ends here (seekToTime: and seekToTime:seekSource: call it). A seek that did not come from this file or
// from iSponsorBlock (scrubbing, the lock screen buttons) ends the check, so a skip is never sent again against the user's own seek.
- (void)seekToTime:(CGFloat)seekTime toleranceBefore:(CGFloat)before toleranceAfter:(CGFloat)after seekSource:(int)source {
    if (sSkip.active && sOwnSeek == 0 && sSkipPlayer == self) {
        UYTCastSBStop([NSString stringWithFormat:@"another seek to %.1fs (source %d)", seekTime, source]);
    }
    %orig;
}

%end

%end

%ctor {
    %init(gCastingSponsorBlock);
}
