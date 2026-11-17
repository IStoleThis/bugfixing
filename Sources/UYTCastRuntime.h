// Runtime helpers shared by the casting hooks (uYouPlusCastingDiagnostics.xm, uYouPlusCastingStayOnCast.xm).
//
// YouTube's MDX classes are not declared in the headers this tweak builds against, so these helpers reach them through the
// Objective-C runtime. Each one answers "nothing" (nil / the fallback) when the class or selector does not exist in the YouTube
// version that is running, so a hook that runs on a version without them simply does nothing.
#import <Foundation/Foundation.h>
#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

static inline id _Nullable UYTCastSharedInstance(NSString *className) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static inline id _Nullable UYTCastObject(id _Nullable target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static inline BOOL UYTCastBool(id _Nullable target, NSString *selectorName, BOOL fallback) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!target || ![target respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

// Defined in uYouPlusCastingDiagnostics.xm. Adds one line to the cast timeline of the debug report (does nothing while the
// Casting Diagnostics switch is off).
void UYTCastEvent(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
