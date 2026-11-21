// Keep the cards of sideways shelves within the screen.
//
// What was seen (YouTube 21.38.2): the post cards of the Home feed's community shelves ("Communities you may like",
// "<channel>'s Community") come out wider than the screen, so half of the picture and the text run off the right edge.
//
// What the code says (read from the arm64 code of 21.38.2; not run on a device yet). These shelves are Elements: an
// ELMCollectionNode (a Texture ASCollectionNode) that scrolls sideways, whose cards are laid out from the server's description.
// Elements leaves the width of the cards open in every place it sizes them:
// * -[ELMCollectionNode collectionNode:constrainedSizeForItemAtIndexPath:] (the Texture route) answers, through
//   -constrainedSizeForItemWithSizingMode, a maximum width of DBL_MAX for a horizontal flow layout (only the height is limited).
// * -[ELMCollectionNode constrainedSizeForItemAtIndexPath:] (the IGListKit route, from ELMCollectionNodeSingleSectionController
//   -sizeRangeForItemAtIndex:) answers {0, 0, inf, inf} for anything that is not a grid.
// * -[ELMCollectionNode calculateSizeThatFitsByMeasuringCells:onlyMeasureFirstCell:forCollectionType:], which works out the height
//   of the shelf, measures the cards with -measure: and a range of its own, again without a width limit. It is given the space
//   the shelf has (the width of the feed) as its first argument.
// Most cards carry a width of their own and are not affected. A card that takes its width from its picture grows to the
// picture's width, which is wider than the screen.
//
// What this file does, behind "Fit Shelf Cards to the Screen" (kFitShelfCards, on by default), and only for Elements collections
// that scroll sideways (-scrollableDirections has the left or right bit; it is read from the element's own data, so it is safe off
// the main thread): wherever one of the three above leaves the width open, the maximum becomes the width of the shelf minus
// kUYTShelfCardMargin. A card that was narrower keeps its size; a card that was wider is laid out at that width, so its text wraps
// and its picture is scaled to fit. Limits the app set itself (a finite maximum) are never changed. The height of the shelf is
// measured with the same width, so no gap is left under the cards.
//
// The width of the shelf is the space it is measured in, or the bounds of the collection, whichever is known; both are remembered on
// the collection. The switch is read each time; a shelf that is already on screen keeps its layout until the feed lays it out again.

#import "uYouPlus.h"
#import "UYTLog.h"

// Texture's ASSizeRange: {min, max}.
typedef struct {
    CGSize min;
    CGSize max;
} UYTSizeRange;

// What is used of an ELMCollectionNode (a Texture ASDisplayNode).
@protocol UYTSidewaysCollection <NSObject>
- (unsigned char)scrollableDirections;
- (CGRect)bounds;
@end

static const CGFloat kUYTShelfCardMargin = 32.0;   // room left beside a fitted card: two 16 pt margins
static const CGFloat kUYTUnbounded = 1.0e6;        // a maximum width above this means "no limit"
static const CGFloat kUYTNarrowestShelf = 120.0;   // narrower than this is not a shelf on screen: left alone
static const unsigned char kUYTScrollHorizontal = 0x3; // ASScrollDirectionRight | ASScrollDirectionLeft
static const int kUYTFitLogMax = 5;                // debug lines per launch

// > 0 while a sideways collection measures its cards (on that thread), with the card width to use.
static __thread CGFloat tUYTMeasureCardWidth = 0;
static int sUYTFitLogs = 0;

static BOOL UYTFitCards(void) {
    return IS_ENABLED(kFitShelfCards);
}

static BOOL UYTIsSideways(id node) {
    if (![node respondsToSelector:@selector(scrollableDirections)]) return NO;
    return ([(id<UYTSidewaysCollection>)node scrollableDirections] & kUYTScrollHorizontal) != 0;
}

static CGFloat UYTCardWidthForShelf(CGFloat shelfWidth) {
    if (shelfWidth < kUYTNarrowestShelf || shelfWidth >= kUYTUnbounded) return 0;
    return shelfWidth - kUYTShelfCardMargin;
}

static UYTSizeRange UYTLimitWidth(UYTSizeRange range, CGFloat cardWidth) {
    if (cardWidth <= 0 || range.max.width < kUYTUnbounded) return range;
    range.max.width = cardWidth;
    if (range.min.width > cardWidth) range.min.width = cardWidth;
    return range;
}

// The width of the shelf as last seen: the space it was measured in, kept on the collection.
#define kUYTShelfWidthKey ((const void *)@selector(uytShelfWidth))

static void UYTRememberShelfWidth(id node, CGFloat width) {
    objc_setAssociatedObject(node, kUYTShelfWidthKey, @(width), OBJC_ASSOCIATION_RETAIN);
}

static CGFloat UYTShelfWidth(id node) {
    CGFloat width = [(id<UYTSidewaysCollection>)node bounds].size.width;
    if (width >= kUYTNarrowestShelf) return width;
    NSNumber *remembered = objc_getAssociatedObject(node, kUYTShelfWidthKey);
    return remembered ? remembered.doubleValue : 0;
}

static void UYTNoteFit(id node, CGFloat cardWidth, const char *where) {
    if (__atomic_load_n(&sUYTFitLogs, __ATOMIC_RELAXED) >= kUYTFitLogMax) return;
    if (__atomic_fetch_add(&sUYTFitLogs, 1, __ATOMIC_RELAXED) >= kUYTFitLogMax) return;
    UYTDebugInfo(@"FitCards: cards of a sideways shelf (%@) limited to %.0f pt wide (%s)", NSStringFromClass([node class]), cardWidth, where);
}

// The size range of one card: the width is limited when the app left it open.
static UYTSizeRange UYTFitCardRange(id node, UYTSizeRange range, const char *where) {
    if (range.max.width < kUYTUnbounded || !UYTFitCards() || !UYTIsSideways(node)) return range;
    CGFloat cardWidth = UYTCardWidthForShelf(UYTShelfWidth(node));
    if (cardWidth <= 0) return range;
    UYTNoteFit(node, cardWidth, where);
    return UYTLimitWidth(range, cardWidth);
}

%group gFitShelfCards

%hook ELMCollectionNode

- (UYTSizeRange)collectionNode:(id)collectionNode constrainedSizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return UYTFitCardRange(self, %orig, "layout");
}

- (UYTSizeRange)constrainedSizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return UYTFitCardRange(self, %orig, "list");
}

- (CGSize)calculateSizeThatFitsByMeasuringCells:(CGSize)constrainedSize onlyMeasureFirstCell:(BOOL)onlyFirstCell forCollectionType:(const void *)collectionType {
    if (!UYTFitCards() || !UYTIsSideways(self)) return %orig;
    CGFloat cardWidth = UYTCardWidthForShelf(constrainedSize.width);
    if (cardWidth <= 0) return %orig;
    UYTRememberShelfWidth(self, constrainedSize.width);
    CGFloat outer = tUYTMeasureCardWidth;
    tUYTMeasureCardWidth = cardWidth;
    CGSize size = %orig;
    tUYTMeasureCardWidth = outer;
    return size;
}

%end

// The cards are measured with -measure: while the shelf works out its height (see above). Outside of that, nothing changes.
%hook ASDisplayNode

- (CGSize)measure:(UYTSizeRange)range {
    if (tUYTMeasureCardWidth > 0) return %orig(UYTLimitWidth(range, tUYTMeasureCardWidth));
    return %orig;
}

%end

%hook ELMNCellNode

- (CGSize)measure:(UYTSizeRange)range {
    if (tUYTMeasureCardWidth > 0) return %orig(UYTLimitWidth(range, tUYTMeasureCardWidth));
    return %orig;
}

%end

%end

%ctor {
    %init(gFitShelfCards);
}
