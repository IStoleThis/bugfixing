// Hides the "YouTube featured" promo shelf on the Home feed ("Your home for ...", with an "Explore more" button).
//
// That shelf is YouTube's own promotion, not an ad: it carries no ad logging data and none of the layout names that the
// ad-block filters in AdBlocking.xm look for, so those leave it in place. It gets its own switch (kHideYouTubeFeatured, on
// by default, see uYouPlusForkDefaults.xm).
//
// How it works: like the "Hide Shorts cells" filter in uYouPlus.xm and the ad-block filters, it looks at the text inside the
// feed's section renderers and drops the ones that match, while the sections are being added to the feed. The shelf is gone
// before anything is drawn, so no gap is left. Two places are covered, the arrays of sections that the feed controller receives
// (first load, continuation, refresh) and the entries of an array section. The switch is read each time, so it takes effect on
// the next feed load without a restart. The text is checked through UYTFeedText.h, which searches the serialized renderer
// instead of formatting it as text (that is slow) and remembers the answer per renderer.
//
// What is not known: the exact text that the shelf's renderer contains has not been seen on a device. The label shown on
// screen ("YouTube featured") is what is matched, plus identifier-style spellings of it. If the shelf is still there after
// a feed refresh, the debug log has what is needed to fix the match, a few lines at most per launch:
//   [UYT-I] HideShelf candidate kept ...  a section that looks like a promo and was kept, with the text around the hint
//
// The same filter also drops the community post shelves behind their own switch, kHideCommunitiesShelf (on by default):
// "Communities you may like" and the shelf of one channel's community, "<channel>'s Community". In YouTube 21.38.2 the post cards
// of these shelves can come out wider than the screen, so half of the picture and the text run off the right edge. The cards are
// Elements, laid out from the server's description, in a sideways collection (ELMCollectionNode) that gives its items an
// unlimited width (-constrainedSizeForItemWithSizingMode answers DBL_MAX for a horizontal flow layout); a card that sizes itself
// by its picture then grows past the screen. The app has no setting for that, so the shelves are removed instead. They are
// matched by their titles (English only, see kUYTCommunitiesShelfNames); a video whose own title contains "'s Community" in a
// one-item section would be dropped as well. A community section that was kept shows up in the debug log as a candidate
// (hint "Communit").
#import "uYouPlus.h"
#import "UYTLog.h"
#import "UYTFeedText.h"

// Debug lines about sections that look like a promo but were kept: this many per launch, then the check stops.
static const int kFeaturedCandidateLogMax = 6;
static int sFeaturedCandidateLogs = 0;

// The object whose text is checked: nil for anything that is not a kind of renderer the shelf can be, and for item sections with
// many entries, which are lists of videos. The element renderer is what the ad filters look at too, so the answer is shared.
static id UYTFeaturedTarget(id section) {
    if (!section) return nil;
    @try {
        if ([section isKindOfClass:%c(YTIItemSectionRenderer)]) {
            return ((YTIItemSectionRenderer *)section).contentsArray.count > 3 ? nil : section;
        }
        if ([section isKindOfClass:%c(YTIShelfRenderer)]) return section;
        if ([section isKindOfClass:%c(YTIItemSectionSupportedRenderers)]) return [(YTIItemSectionSupportedRenderers *)section elementRenderer];
        if ([section isKindOfClass:%c(YTIElementRenderer)]) return section;
    } @catch (id exception) {
        return nil;
    }
    return nil;
}

// Printable text around the first promo-like word of the renderer, for the debug log (everything else is shown as a dot).
static NSString *UYTPromoContext(id target) {
    @autoreleasepool {
        NSData *data = UYTSearchableBytes(target);
        const unsigned char *bytes = (const unsigned char *)data.bytes;
        size_t length = data.length;
        for (size_t h = 0; h < UYT_COUNT_OF(kUYTPromoHints); h++) {
            const char *hint = kUYTPromoHints[h];
            size_t n = strlen(hint);
            if (n == 0 || length < n) continue;
            for (size_t i = 0; i + n <= length; i++) {
                if (bytes[i] != (unsigned char)hint[0] || memcmp(bytes + i, hint, n) != 0) continue;
                size_t from = i > 70 ? i - 70 : 0;
                size_t to = MIN(length, i + n + 70);
                NSMutableString *out = [NSMutableString stringWithFormat:@"hint \"%s\" at %lu of %lu bytes: ", hint, (unsigned long)i, (unsigned long)length];
                for (size_t k = from; k < to; k++) {
                    unsigned char c = bytes[k];
                    [out appendString:(c >= 0x20 && c < 0x7f) ? [NSString stringWithFormat:@"%c", c] : @"."];
                }
                return out;
            }
        }
        return @"(no hint found)";
    }
}

// A section that was kept but looks like a promo: say so a few times per launch, so the log can show what the real shelf looks like.
static void UYTNoteFeaturedCandidate(id section, id target) {
    if (__atomic_load_n(&sFeaturedCandidateLogs, __ATOMIC_RELAXED) >= kFeaturedCandidateLogMax) return;
    if (__atomic_fetch_add(&sFeaturedCandidateLogs, 1, __ATOMIC_RELAXED) >= kFeaturedCandidateLogMax) return;
    UYTDebugInfo(@"HideShelf candidate kept: %@ %@", NSStringFromClass([section class]), UYTPromoContext(target));
}

// The shelves to drop, from the switches: UYTFeedFlagFeatured and/or UYTFeedFlagCommunitiesShelf (0 when both are off).
static NSUInteger UYTHiddenShelfFlags(void) {
    return (IS_ENABLED(kHideYouTubeFeatured) ? UYTFeedFlagFeatured : 0) | (IS_ENABLED(kHideCommunitiesShelf) ? UYTFeedFlagCommunitiesShelf : 0);
}

static BOOL UYTIsHiddenShelf(id section, NSUInteger drop) {
    id target = UYTFeaturedTarget(section);
    if (!target) return NO;
    NSUInteger flags = UYTFeedFlags(target);
    if (flags & drop & UYTFeedFlagFeatured) {
        UYTDebugInfo(@"HideFeatured removed a %@", NSStringFromClass([section class]));
        return YES;
    }
    if (flags & drop & UYTFeedFlagCommunitiesShelf) {
        UYTDebugInfo(@"HideCommunities removed a %@", NSStringFromClass([section class]));
        return YES;
    }
    if ((flags & UYTFeedFlagPromoHint) && __atomic_load_n(&sFeaturedCandidateLogs, __ATOMIC_RELAXED) < kFeaturedCandidateLogMax) {
        UYTNoteFeaturedCandidate(section, target);
    }
    return NO;
}

// The same array when nothing matches (so callers can compare pointers), otherwise a mutable copy without the shelves.
static NSArray *UYTWithoutFeaturedShelf(NSArray *sections) {
    NSUInteger drop = UYTHiddenShelfFlags();
    if (!drop || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) return sections;
    NSIndexSet *hidden = [sections indexesOfObjectsPassingTest:^BOOL(id section, NSUInteger index, BOOL *stop) {
        return UYTIsHiddenShelf(section, drop);
    }];
    if (hidden.count == 0) return sections;
    NSMutableArray *kept = [sections mutableCopy];
    [kept removeObjectsAtIndexes:hidden];
    return kept;
}

%group gHideYouTubeFeatured

%hook YTInnerTubeCollectionViewController

- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    if (UYTHiddenShelfFlags()) {
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
    NSUInteger drop = UYTHiddenShelfFlags();
    if (drop && UYTIsHiddenShelf(newEntry, drop)) return;
    %orig;
}

%end

%end

%ctor {
    // The switches are read each time a feed section arrives, so the group is always installed.
    %init(gHideYouTubeFeatured);
}
