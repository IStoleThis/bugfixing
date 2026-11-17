// Cheap checks on the text inside feed renderers. Shared by the feed filters (AdBlocking.xm, HideYouTubeFeatured.xm, and the
// "Hide Shorts cells" filter in uYouPlus.xm).
//
// Why this exists: the filters used to call -description on every renderer and look for layout names in the text. -description
// of a protobuf message is very slow, because the library formats every byte of every binary field on its own
// (-[NSMutableString appendFormat:@"%c"] once per byte). The filters also did it for the same renderers again and again: once per
// filter, and again each time the renderer came through another hook. A page of the Home feed took a noticeable part of a second
// on the main thread, which shows as a stutter when scrolling and when switching tabs.
//
// What replaces it:
//  1. The serialized bytes of the message (-data) are searched instead. The library prints the printable characters of a binary
//     field as they are and only escapes the others, so a plain ASCII name that is in -description is in the serialized bytes
//     too, and building the bytes is a copy, not a format call per character. When a message cannot give its bytes, -description
//     is used (as UTF-8 bytes), so the answer is the same and only the cost differs.
//  2. The answer for every list of names is worked out once per renderer object and stored on the object (an associated object),
//     so the next filter that asks about the same renderer gets it for nothing.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

// Bits of the answer. A renderer's text can have several.
static const NSUInteger UYTFeedFlagAd = 1 << 0;           // one of the layout names of an ad or a shopping unit (kUYTAdNames)
static const NSUInteger UYTFeedFlagFeatured = 1 << 1;     // the "YouTube featured" promo shelf (kUYTFeaturedNames)
static const NSUInteger UYTFeedFlagShortsShelf = 1 << 2;  // a Shorts shelf
static const NSUInteger UYTFeedFlagShortsCell = 1 << 3;   // a Shorts video cell
static const NSUInteger UYTFeedFlagPromoHint = 1 << 4;    // looks like a promo (kUYTPromoHints), only used for the debug log
static const NSUInteger UYTFeedFlagKnown = 1 << 7;        // the answer has been worked out (so "no flags" can be told from "not asked")

// The names the ad filters look for in a renderer's text.
static const char *const kUYTAdNames[] = {
    "brand_promo",
    "brand_video_shelf",
    "carousel_footered_layout",
    "carousel_headered_layout",
    "eml.expandable_metadata",
    "feed_ad_metadata",
    "full_width_portrait_image_layout",
    "full_width_square_image_layout",
    "grid_ads_image_layout",
    "landscape_image_wide_button_layout",
    "post_shelf",
    "product_carousel",
    "product_engagement_panel",
    "product_item",
    "shopping_carousel",
    "shopping_item_card_list",
    "statement_banner",
    "square_image_layout",
    "text_image_button_layout",
    "text_search_ad",
    "video_display_full_layout",
    "video_display_full_buttoned_layout",
};

// The "YouTube featured" promo shelf: the label that is drawn, plus identifier-style spellings of it.
static const char *const kUYTFeaturedNames[] = {"YouTube featured", "youtube_featured", "yt_featured"};

static const char *const kUYTShortsShelfNames[] = {"shorts_shelf"};
static const char *const kUYTShortsCellNames[] = {"shorts_video_cell"};

// Words that make a renderer look like a promo. Only for the debug log, see HideYouTubeFeatured.xm.
static const char *const kUYTPromoHints[] = {"featured", "Featured", "FEATURED", "promo", "banner", "campaign", "Your home for", "Explore more"};

#define UYT_COUNT_OF(a) (sizeof(a) / sizeof((a)[0]))

// YES when the plain ASCII name is in the bytes.
static inline BOOL UYTBytesHave(const unsigned char *bytes, size_t length, const char *name) {
    size_t n = strlen(name);
    if (n == 0 || length < n) return NO;
    const unsigned char first = (unsigned char)name[0];
    const unsigned char *p = bytes;
    const unsigned char *end = bytes + (length - n) + 1;
    while (p < end) {
        p = (const unsigned char *)memchr(p, first, (size_t)(end - p));
        if (!p) return NO;
        if (memcmp(p, name, n) == 0) return YES;
        p++;
    }
    return NO;
}

static inline BOOL UYTBytesHaveAny(const unsigned char *bytes, size_t length, const char *const *names, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (UYTBytesHave(bytes, length, names[i])) return YES;
    }
    return NO;
}

// The serialized bytes of a protobuf message, or nil when it cannot give them. Caller keeps an autorelease pool around big loops.
static inline NSData *UYTMessageBytes(id message) {
    if (!message || ![message respondsToSelector:@selector(data)]) return nil;
    NSData *data = nil;
    @try {
        data = ((NSData *(*)(id, SEL))objc_msgSend)(message, @selector(data));
    } @catch (id exception) {
        data = nil;
    }
    return [data isKindOfClass:[NSData class]] ? data : nil;
}

// The bytes to search: the serialized message, or the UTF-8 text of its -description when it cannot be serialized.
static inline NSData *UYTSearchableBytes(id message) {
    NSData *data = UYTMessageBytes(message);
    if (data) return data;
    NSString *text = nil;
    @try {
        text = [message description];
    } @catch (id exception) {
        text = nil;
    }
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static inline NSUInteger UYTComputeFeedFlags(id message) {
    @autoreleasepool {
        NSUInteger flags = UYTFeedFlagKnown;
        NSData *data = UYTSearchableBytes(message);
        if (data.length == 0) return flags;
        const unsigned char *bytes = (const unsigned char *)data.bytes;
        size_t length = data.length;
        if (UYTBytesHaveAny(bytes, length, kUYTAdNames, UYT_COUNT_OF(kUYTAdNames))) flags |= UYTFeedFlagAd;
        if (UYTBytesHaveAny(bytes, length, kUYTFeaturedNames, UYT_COUNT_OF(kUYTFeaturedNames))) flags |= UYTFeedFlagFeatured;
        if (UYTBytesHaveAny(bytes, length, kUYTShortsShelfNames, UYT_COUNT_OF(kUYTShortsShelfNames))) flags |= UYTFeedFlagShortsShelf;
        if (UYTBytesHaveAny(bytes, length, kUYTShortsCellNames, UYT_COUNT_OF(kUYTShortsCellNames))) flags |= UYTFeedFlagShortsCell;
        if (UYTBytesHaveAny(bytes, length, kUYTPromoHints, UYT_COUNT_OF(kUYTPromoHints))) flags |= UYTFeedFlagPromoHint;
        return flags;
    }
}

// The key the answers are stored under. A selector is one pointer for the whole program (the runtime hands out the same one for the same
// name), so every file that includes this header shares the stored answers. A static variable here would be a separate key in each file,
// and each filter would work out the same answers again.
#define kUYTFeedFlagsKey ((const void *)@selector(uytFeedFlags))

// All the answers for one renderer, worked out on the first ask and kept on the object.
static inline NSUInteger UYTFeedFlags(id message) {
    if (!message) return 0;
    NSNumber *cached = objc_getAssociatedObject(message, kUYTFeedFlagsKey);
    if (cached) return cached.unsignedIntegerValue;
    NSUInteger flags = UYTComputeFeedFlags(message);
    objc_setAssociatedObject(message, kUYTFeedFlagsKey, @(flags), OBJC_ASSOCIATION_RETAIN);
    return flags;
}

// YES when the renderer's text has any of the names behind the given flag bits.
static inline BOOL UYTFeedHas(id message, NSUInteger flagBits) {
    return (UYTFeedFlags(message) & flagBits) != 0;
}
