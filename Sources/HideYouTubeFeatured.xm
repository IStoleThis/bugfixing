// Hides the "YouTube featured" promo shelf on the Home feed ("Your home for ...", with an "Explore more" button).
//
// That shelf is YouTube's own promotion, not an ad: it carries no ad logging data and none of the layout names that the
// ad-block filters in AdBlocking.xm look for, so those leave it in place. It gets its own switch (kHideYouTubeFeatured, on
// by default, see uYouPlusForkDefaults.xm).
//
// How it works: like the "Hide Shorts cells" filter in uYouPlus.xm and the ad-block filters, it looks at the text form
// (-description) of the feed's section renderers and drops the ones that match, while the sections are being added to the
// feed. The shelf is gone before anything is drawn, so no gap is left. Two places are covered, the arrays of sections that
// the feed controller receives (first load, continuation, refresh) and the entries of an array section. The switch is read each
// time, so it takes effect on the next feed load without a restart.
//
// What is not known: the exact text that the shelf's renderer contains has not been seen on a device. The label shown on
// screen ("YouTube featured") is what is matched, plus identifier-style spellings of it. If the shelf is still there after
// a feed refresh, the debug log has what is needed to fix the match:
//   [UYT-I] HideFeatured candidate ...  a section that looks like a promo and was kept, with the identifiers found in it
//   [UYT-I] HideFeatured: the label is on screen ...  the shelf was drawn; the views it sits in are listed
#import "uYouPlus.h"
#import "UYTLog.h"

static const NSUInteger kFeaturedMaxChars = 12000;

static NSArray<NSString *> *UYTFeaturedNeedles(void) {
    static NSArray<NSString *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@"YouTube featured", @"youtube_featured", @"yt_featured"];
    });
    return needles;
}

// Text form of a feed section (or of one entry of an array section), cut to a sane length. Nil for anything that is not
// a kind of renderer the shelf can be, and for item sections with many entries, which are lists of videos.
static NSString *UYTSectionText(id section) {
    if (!section) return nil;
    NSString *text = nil;
    @try {
        if ([section isKindOfClass:%c(YTIItemSectionRenderer)]) {
            if (((YTIItemSectionRenderer *)section).contentsArray.count > 3) return nil;
            text = [section description];
        } else if ([section isKindOfClass:%c(YTIShelfRenderer)]) {
            text = [section description];
        } else if ([section isKindOfClass:%c(YTIItemSectionSupportedRenderers)]) {
            text = [[(YTIItemSectionSupportedRenderers *)section elementRenderer] description];
        } else if ([section isKindOfClass:%c(YTIElementRenderer)]) {
            text = [section description];
        }
    } @catch (id exception) {
        return nil;
    }
    if (text.length > kFeaturedMaxChars) text = [text substringToIndex:kFeaturedMaxChars];
    return text;
}

// Identifier-style names found in a renderer's text ("statement_banner.eml", "brand_promo", ...), for the debug log only.
static NSString *UYTIdentifierTokens(NSString *text) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[a-z][a-z0-9_]*\\.eml|[a-z][a-z0-9]*(?:_[a-z0-9]+)*_(?:layout|shelf|banner|promo|carousel|cell|card|hub|featured)"
                                                          options:0
                                                            error:nil];
    });
    NSMutableOrderedSet<NSString *> *tokens = [NSMutableOrderedSet orderedSet];
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        [tokens addObject:[text substringWithRange:match.range]];
        if (tokens.count >= 12) break;
    }
    return [tokens.array componentsJoinedByString:@", "];
}

// A section that was kept but looks like a promo: say so once per distinct shape, so the log can show what the real shelf looks like.
static void UYTNoteFeaturedCandidate(id section, NSString *text) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    BOOL hasPhrase = NO;
    for (NSString *hint in @[@"featured", @"Featured", @"FEATURED", @"promo", @"banner", @"campaign", @"Your home for", @"Explore more"]) {
        if ([text containsString:hint]) { hasPhrase = YES; break; }
    }
    if (!hasPhrase) return;
    NSString *tokens = UYTIdentifierTokens(text);
    NSString *shape = [NSString stringWithFormat:@"%@|%@", NSStringFromClass([section class]), tokens];
    @synchronized (seen) {
        if (seen.count >= 40 || [seen containsObject:shape]) return;
        [seen addObject:shape];
    }
    UYTDebugInfo(@"HideFeatured candidate kept: %@ identifiers=[%@] text-has[Your home for=%d, Explore more=%d, featured=%d] length=%lu",
                 NSStringFromClass([section class]), tokens,
                 [text containsString:@"Your home for"], [text containsString:@"Explore more"],
                 [text localizedCaseInsensitiveContainsString:@"featured"], (unsigned long)text.length);
}

static BOOL UYTIsFeaturedShelf(id section) {
    NSString *text = UYTSectionText(section);
    if (text.length == 0) return NO;
    for (NSString *needle in UYTFeaturedNeedles()) {
        if ([text containsString:needle]) {
            UYTDebugInfo(@"HideFeatured removed a %@ (matched \"%@\", %lu chars)", NSStringFromClass([section class]), needle, (unsigned long)text.length);
            return YES;
        }
    }
    UYTNoteFeaturedCandidate(section, text);
    return NO;
}

// The same array when nothing matches (so callers can compare pointers), otherwise a mutable copy without the shelf.
static NSArray *UYTWithoutFeaturedShelf(NSArray *sections) {
    if (!IS_ENABLED(kHideYouTubeFeatured) || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) return sections;
    NSIndexSet *featured = [sections indexesOfObjectsPassingTest:^BOOL(id section, NSUInteger index, BOOL *stop) {
        return UYTIsFeaturedShelf(section);
    }];
    if (featured.count == 0) return sections;
    NSMutableArray *kept = [sections mutableCopy];
    [kept removeObjectsAtIndexes:featured];
    return kept;
}

%group gHideYouTubeFeatured

%hook YTInnerTubeCollectionViewController

- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    if (IS_ENABLED(kHideYouTubeFeatured)) {
        @try {
            NSArray *current = [self valueForKey:@"_sectionRenderers"];
            NSArray *kept = UYTWithoutFeaturedShelf(current);
            if (kept != current) [self setValue:kept forKey:@"_sectionRenderers"];
        } @catch (id exception) {}
    }
    %orig;
}

- (void)addSectionsFromArray:(NSArray *)array {
    %orig(UYTWithoutFeaturedShelf(array));
}

%end

%hook YTArraySectionViewModel

- (id)initWithEntries:(NSArray *)entries {
    return %orig(UYTWithoutFeaturedShelf(entries));
}

- (id)initWithTransform:(id)transform entries:(NSArray *)entries {
    return %orig(transform, UYTWithoutFeaturedShelf(entries));
}

- (void)insertEntries:(NSArray *)entries atIndex:(NSUInteger)index {
    NSArray *kept = UYTWithoutFeaturedShelf(entries);
    if (kept.count) %orig(kept, index);
}

- (void)replaceEntry:(id)oldEntry withEntry:(id)newEntry {
    if (IS_ENABLED(kHideYouTubeFeatured) && UYTIsFeaturedShelf(newEntry)) return;
    %orig;
}

%end

// Diagnostic only, nothing is hidden here: if the label is drawn, the data filters above missed the shelf. Report the views
// it sits in once, so the identifier of the shelf can be read from the log. This hook sees every view that enters a window,
// so it stops looking after the first report.
%hook _ASDisplayView

- (void)didMoveToWindow {
    %orig;
    static BOOL reported;
    if (reported || !self.window || !IS_ENABLED(kHideYouTubeFeatured)) return;
    NSString *label = self.accessibilityLabel;
    if (label.length == 0 || label.length > 120 || ![label containsString:@"YouTube featured"]) return;
    reported = YES;
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    NSUInteger depth = 0;
    for (UIView *view = self; view && depth < 14; view = view.superview, depth++) {
        NSString *identifier = view.accessibilityIdentifier;
        [chain addObject:identifier.length ? [NSString stringWithFormat:@"%@(%@)", NSStringFromClass([view class]), identifier] : NSStringFromClass([view class])];
    }
    UYTDebugInfo(@"HideFeatured: the label is on screen, so the shelf got past the feed filters. Views: %@", [chain componentsJoinedByString:@" < "]);
}

%end

%end

%ctor {
    // The switch is read each time a feed section arrives, so the group is always installed.
    %init(gHideYouTubeFeatured);
}
