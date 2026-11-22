// Keep the cards of sideways shelves, and the pictures in them, within the screen.
//
// What was seen (YouTube 21.38.2): the post cards of the Home feed's community shelves ("Communities you may like",
// "<channel>'s Community") came out wider than the screen, half of the picture and the text running off the right edge. With the
// cards limited (build 9) a card fits, but its picture keeps its full size: the card shows a zoomed-in top-left part of it and
// grows as tall as the picture.
//
// What the code says (read from the arm64 code of 21.38.2; not run on a device yet). These shelves are Elements: an
// ELMCollectionNode (a Texture ASCollectionNode) that scrolls sideways. All three of its node blocks
// (-collectionNode:nodeBlockForItemAtIndexPath:) make classic ELMCellNodes, never the newer ELMNCellNode, so a picture in a card
// is an ELMImageNode.
// * Elements leaves the width of the cards open in every place it sizes them:
//   -[ELMCollectionNode collectionNode:constrainedSizeForItemAtIndexPath:] (the Texture route) answers, through
//   -constrainedSizeForItemWithSizingMode, a maximum width of DBL_MAX for a horizontal flow layout (only the height is limited);
//   -[ELMCollectionNode constrainedSizeForItemAtIndexPath:] (the IGListKit route, from ELMCollectionNodeSingleSectionController
//   -sizeRangeForItemAtIndex:) answers {0, 0, inf, inf} for anything that is not a grid; and
//   -[ELMCollectionNode calculateSizeThatFitsByMeasuringCells:onlyMeasureFirstCell:forCollectionType:], which works out the height
//   of the shelf, measures the cards with -measure: and a range of its own, again without a width limit. It is given the space
//   the shelf has (the width of the feed) as its first argument.
// * -[ELMImageNode calculateSizeThatFits:] answers the width the element's CSS gives the picture (in points, or a share of the
//   width it is offered) with the height from the picture's proportions; or, with no CSS width, a height-based size (when the CSS
//   gives a height), or the size it is offered (before the picture has loaded); and otherwise the picture's own size, which for a
//   downloaded picture is usually its size in pixels. That last case does not look at the width it is offered at all, so a large
//   picture comes out as large as it is, whatever the width of its card. (On the post's own page the same picture fits.)
// * A card is laid out in one of two ways. With Yoga2 (a flag of the node), -[ASDisplayNode measure:] and -layoutThatFits: call a
//   function that calls -willCalculateLayout: on the card, runs the Yoga layout of everything in it (where the pictures are
//   measured), and then calls -didCalculateLayout:, with nothing in between that can return early. Without Yoga2, the layout is made
//   in -calculateLayoutThatFits:restrictedToSize:relativeToParentSize:, which -layoutThatFits:parentSize: and the layout pass
//   (-_u_measureNodeWithBoundsIfNecessary:) call.
//
// What this file does, behind "Fit Shelf Cards to the Screen" (kFitShelfCards, on by default), and only for Elements collections
// that scroll sideways (-scrollableDirections has the left or right bit; it is read from the element's own data, so it is safe off
// the main thread):
// 1. Wherever one of the three above leaves a card's width open, the maximum becomes the width of the shelf minus
//    kUYTShelfCardMargin. A card that was narrower keeps its size. Limits the app set itself (a finite maximum) are never changed.
//    The height of the shelf is measured with the same width, so no gap is left under the cards.
// 2. While a card of such a shelf is laid out (between -willCalculateLayout: and -didCalculateLayout:, or in
//    -calculateLayoutThatFits:restrictedToSize:relativeToParentSize:, on that thread), a picture that comes out wider than the room
//    it has is scaled down to that room, keeping its proportions; the card's height follows. The room is the width the picture is
//    offered, or, when it is offered no width limit, the card's width minus kUYTCardInnerPadding. A picture that already fits is
//    not changed, so the thumbnails of ordinary shelves keep their size. A card is an Elements cell (ELMCellNode) whose owning
//    node (collectionElement.owningNode) is such a collection, or any Elements cell while such a collection measures its cells.
//    The debug log notes the first few pictures scaled.
//
// The width of the shelf is the space it is measured in, or the bounds of the collection, whichever is known; both are remembered
// on the collection. The switch is kept in memory and follows changes to the settings; a shelf that is already on screen keeps its
// layout until the feed lays it out again.

#import "uYouPlus.h"
#import "UYTLog.h"

// Texture's ASSizeRange: {min, max}.
typedef struct {
    CGSize min;
    CGSize max;
} UYTSizeRange;

// Texture's ASDimension and ASLayoutElementSize (only passed on).
typedef struct {
    NSInteger unit;
    CGFloat value;
} UYTDimension;

typedef struct {
    UYTDimension width;
    UYTDimension height;
    UYTDimension minWidth;
    UYTDimension maxWidth;
    UYTDimension minHeight;
    UYTDimension maxHeight;
} UYTLayoutElementSize;

// What is used of an ELMCollectionNode (a Texture ASDisplayNode) and of an ASCellNode.
@protocol UYTSidewaysCollection <NSObject>
- (unsigned char)scrollableDirections;
- (CGRect)bounds;
@end

@protocol UYTCellNode <NSObject>
- (id)owningNode;
@end

static const CGFloat kUYTShelfCardMargin = 32.0;   // room left beside a fitted card: two 16 pt margins
static const CGFloat kUYTCardInnerPadding = 32.0;  // room inside a card around a picture that was offered no width limit
static const CGFloat kUYTUnbounded = 1.0e6;        // a maximum width above this means "no limit"
static const CGFloat kUYTNarrowestShelf = 120.0;   // narrower than this is not a shelf on screen: left alone
static const unsigned char kUYTScrollHorizontal = 0x3; // ASScrollDirectionRight | ASScrollDirectionLeft
static const int kUYTFitLogMax = 5;                // debug lines per launch, for cards and for pictures each
static const int kUYTCardDepthMax = 8;             // cards inside cards that are followed (a shelf in a card, ...)

// On the thread that lays it out: > 0 while a sideways shelf measures its cards (the widest a card may be), and > 0 while a card
// of such a shelf is laid out (the width of the card).
static __thread CGFloat tUYTShelfCardMax = 0;
static __thread CGFloat tUYTCardWidth = 0;

// The cards being laid out on this thread, with the card width to go back to when each is done.
typedef struct {
    const void *cell;
    CGFloat outerWidth;
} UYTCardEntry;

static __thread UYTCardEntry tUYTCards[kUYTCardDepthMax];
static __thread int tUYTCardDepth = 0;

static BOOL sUYTFitOn = YES;                       // kFitShelfCards, kept in memory (read on layout paths)
static Class sUYTELMCollectionNodeClass = Nil;
static Class sUYTELMCellNodeClass = Nil;
static int sUYTFitLogs = 0;
static int sUYTPictureLogs = 0;

static void UYTReadFitSwitch(void) {
    sUYTFitOn = IS_ENABLED(kFitShelfCards);
}

static BOOL UYTIsLimit(CGFloat width) {
    return width > 0 && width < kUYTUnbounded;   // false for NaN and infinity
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

// A picture's size scaled down, with its proportions, to the room it has; unchanged when it fits.
static CGSize UYTFitPicture(CGSize size, CGFloat offeredWidth, CGFloat cardWidth) {
    if (cardWidth <= 0 || size.width <= 0 || size.height <= 0) return size;
    CGFloat room = (UYTIsLimit(offeredWidth) && offeredWidth <= cardWidth) ? offeredWidth : cardWidth - kUYTCardInnerPadding;
    if (room <= 0 || size.width <= room) return size;
    return CGSizeMake(room, size.height * room / size.width);
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

static BOOL UYTTakeLogTurn(int *counter) {
    if (__atomic_load_n(counter, __ATOMIC_RELAXED) >= kUYTFitLogMax) return NO;
    return __atomic_fetch_add(counter, 1, __ATOMIC_RELAXED) < kUYTFitLogMax;
}

// The size range of one card: the width is limited when the app left it open.
static UYTSizeRange UYTFitCardRange(id node, UYTSizeRange range, const char *where) {
    if (range.max.width < kUYTUnbounded || !sUYTFitOn || !UYTIsSideways(node)) return range;
    CGFloat cardWidth = UYTCardWidthForShelf(UYTShelfWidth(node));
    if (cardWidth <= 0) return range;
    if (UYTTakeLogTurn(&sUYTFitLogs)) {
        UYTDebugInfo(@"FitCards: cards of a sideways shelf (%@) limited to %.0f pt wide (%s)", NSStringFromClass([node class]), cardWidth, where);
    }
    return UYTLimitWidth(range, cardWidth);
}

// Whether a cell that is about to be laid out with this range is a card of a sideways shelf; its width if so, else 0.
static CGFloat UYTCardWidthOfCell(id cell, UYTSizeRange range) {
    if (!sUYTFitOn || !UYTIsLimit(range.max.width)) return 0;
    if (tUYTShelfCardMax > 0) return range.max.width;   // the shelf is measuring its cards
    if (![cell respondsToSelector:@selector(owningNode)]) return 0;
    id owner = [(id<UYTCellNode>)cell owningNode];
    if (!owner || !sUYTELMCollectionNodeClass || ![owner isKindOfClass:sUYTELMCollectionNodeClass] || !UYTIsSideways(owner)) return 0;
    return range.max.width;
}

static BOOL UYTEnterCard(id cell, CGFloat cardWidth) {
    if (cardWidth <= 0 || tUYTCardDepth >= kUYTCardDepthMax) return NO;
    tUYTCards[tUYTCardDepth].cell = (__bridge const void *)cell;
    tUYTCards[tUYTCardDepth].outerWidth = tUYTCardWidth;
    tUYTCardDepth++;
    tUYTCardWidth = cardWidth;
    return YES;
}

// Back to the card width from before this cell (and anything entered after it on this thread).
static void UYTLeaveCard(id cell) {
    for (int i = tUYTCardDepth - 1; i >= 0; i--) {
        if (tUYTCards[i].cell != (__bridge const void *)cell) continue;
        tUYTCardWidth = tUYTCards[i].outerWidth;
        tUYTCardDepth = i;
        return;
    }
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
    if (!sUYTFitOn || !UYTIsSideways(self)) return %orig;
    CGFloat cardMax = UYTCardWidthForShelf(constrainedSize.width);
    if (cardMax <= 0) return %orig;
    UYTRememberShelfWidth(self, constrainedSize.width);
    CGFloat outerMax = tUYTShelfCardMax;
    CGFloat outerCard = tUYTCardWidth;
    tUYTShelfCardMax = cardMax;
    tUYTCardWidth = 0;   // the cards measured here are cards of this shelf, not of one around it
    CGSize size = %orig;
    tUYTShelfCardMax = outerMax;
    tUYTCardWidth = outerCard;
    return size;
}

%end

// The cards are measured with -measure: while the shelf works out its height (see above). Without Yoga2, a card is laid out in
// -calculateLayoutThatFits:restrictedToSize:relativeToParentSize:, which ELMCellNode only inherits; it is hooked on ASDisplayNode,
// whose own method it is, and only Elements cells go further than the class check. (Substrate wraps a method a class only
// inherits in a stub that does not keep the floating-point argument registers, so no inherited method is hooked here.)
%hook ASDisplayNode

- (CGSize)measure:(UYTSizeRange)range {
    if (tUYTShelfCardMax > 0) return %orig(UYTLimitWidth(range, tUYTShelfCardMax));
    return %orig;
}

- (id)calculateLayoutThatFits:(UYTSizeRange)constrainedSize restrictedToSize:(UYTLayoutElementSize)size relativeToParentSize:(CGSize)parentSize {
    if (!sUYTFitOn || !sUYTELMCellNodeClass || ![(id)self isKindOfClass:sUYTELMCellNodeClass]) return %orig;
    if (!UYTEnterCard(self, UYTCardWidthOfCell(self, constrainedSize))) return %orig;
    id layout = %orig;
    UYTLeaveCard(self);
    return layout;
}

%end

%hook ELMNCellNode

- (CGSize)measure:(UYTSizeRange)range {
    if (tUYTShelfCardMax > 0) return %orig(UYTLimitWidth(range, tUYTShelfCardMax));
    return %orig;
}

%end

// With Yoga2, a card is laid out between these two calls (its own methods).
%hook ELMCellNode

- (void)willCalculateLayout:(UYTSizeRange)range {
    %orig;
    UYTEnterCard(self, UYTCardWidthOfCell(self, range));
}

- (void)didCalculateLayout:(UYTSizeRange)range {
    if (tUYTCardDepth > 0) UYTLeaveCard(self);
    %orig;
}

%end

%hook ELMImageNode

- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize {
    CGSize size = %orig;
    CGFloat cardWidth = tUYTCardWidth > 0 ? tUYTCardWidth : tUYTShelfCardMax;
    if (cardWidth <= 0 || !sUYTFitOn) return size;
    CGSize fitted = UYTFitPicture(size, constrainedSize.width, cardWidth);
    if ((fitted.width != size.width || fitted.height != size.height) && UYTTakeLogTurn(&sUYTPictureLogs)) {
        UYTDebugInfo(@"FitCards: a picture in a card scaled from %.0fx%.0f to %.0fx%.0f pt (offered width %.0f, card %.0f)", size.width, size.height, fitted.width, fitted.height, UYTIsLimit(constrainedSize.width) ? constrainedSize.width : -1, cardWidth);
    }
    return fitted;
}

%end

%end

%ctor {
    sUYTELMCollectionNodeClass = objc_getClass("ELMCollectionNode");
    sUYTELMCellNodeClass = objc_getClass("ELMCellNode");
    UYTReadFitSwitch();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        UYTReadFitSwitch();
    }];
    %init(gFitShelfCards);
}
