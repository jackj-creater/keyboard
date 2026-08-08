#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <string.h>

#pragma mark - User-adjustable constants

// 0 = fully transparent
// 1 = translucent black
// 2 = solid black
static const NSInteger kSCFBackgroundMode = 0;

// Used only when kSCFBackgroundMode == 1.
// Suggested range: 0.18 - 0.45
static const CGFloat kSCFBlackAlpha = 0.30;

static __weak UIView *gSCFSpotlightResponder = nil;
static id gSCFBeginEditingObserver = nil;
static id gSCFEndEditingObserver = nil;

#pragma mark - Class and context helpers

static BOOL SCFCStringContainsInsensitive(const char *value, const char *needle) {
    if (!value || !needle || !*needle) return NO;

    size_t needleLength = strlen(needle);
    for (const char *start = value; *start; start++) {
        size_t index = 0;
        while (index < needleLength && start[index] &&
               tolower((unsigned char)start[index]) ==
               tolower((unsigned char)needle[index])) {
            index++;
        }
        if (index == needleLength) return YES;
    }
    return NO;
}

static const char *SCFClassName(id object) {
    if (!object) return "";
    Class cls = object_getClass(object);
    return cls ? class_getName(cls) : "";
}

static BOOL SCFClassNameContainsAny(id object,
                                    const char *const *needles,
                                    size_t needleCount) {
    const char *name = SCFClassName(object);
    for (size_t index = 0; index < needleCount; index++) {
        if (SCFCStringContainsInsensitive(name, needles[index])) return YES;
    }
    return NO;
}

static const char *const kSCFSearchKeywords[] = {
    "spotlight", "search", "searchui"
};

static BOOL SCFViewOrAncestorMatches(UIView *view,
                                     const char *const *keywords,
                                     size_t keywordCount,
                                     NSUInteger maxDepth) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth <= maxDepth; depth++) {
        if (SCFClassNameContainsAny(current, keywords, keywordCount)) return YES;
        current = current.superview;
    }
    return NO;
}

static BOOL SCFControllerChainMatches(UIView *view,
                                      const char *const *keywords,
                                      size_t keywordCount) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 24; depth++) {
        if (SCFClassNameContainsAny(responder, keywords, keywordCount)) return YES;
        responder = responder.nextResponder;
    }
    return NO;
}

static BOOL SCFViewBelongsToSpotlightSearch(UIView *view) {
    if (!view) return NO;
    const size_t count = sizeof(kSCFSearchKeywords) / sizeof(kSCFSearchKeywords[0]);
    return SCFViewOrAncestorMatches(view, kSCFSearchKeywords, count, 20) ||
           SCFControllerChainMatches(view, kSCFSearchKeywords, count);
}

static BOOL SCFSpotlightSearchIsEditing(void) {
    UIView *responder = gSCFSpotlightResponder;
    return responder && responder.isFirstResponder;
}

static BOOL SCFViewIsCandidateSurface(UIView *view) {
    const char *name = SCFClassName(view);
    if (!name || !*name) return NO;

    BOOL candidateClass = SCFCStringContainsInsensitive(name, "candidate") ||
                          SCFCStringContainsInsensitive(name, "prediction") ||
                          SCFCStringContainsInsensitive(name, "completion");
    if (!candidateClass) return NO;

    // Cells own selection/highlight visuals and are intentionally left alone.
    if (SCFCStringContainsInsensitive(name, "cell") ||
        SCFCStringContainsInsensitive(name, "label")) return NO;

    static const char *const surfaceKeywords[] = {
        "bar", "grid", "overlay", "toggle", "arrow",
        "inline", "header", "background", "view"
    };
    return SCFClassNameContainsAny(view,
                                   surfaceKeywords,
                                   sizeof(surfaceKeywords) / sizeof(surfaceKeywords[0]));
}

static BOOL SCFFrameCanBeCandidateSurface(UIView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 8.0 || height < 8.0) return NO;

    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    return height < screenHeight * 0.70;
}

#pragma mark - Background repair

static BOOL SCFColorLooksDark(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    if (@available(iOS 13.0, *)) color = [color resolvedColorWithTraitCollection:traits];

    CGFloat white = 0.0;
    CGFloat alpha = 0.0;
    if ([color getWhite:&white alpha:&alpha]) {
        return alpha > 0.05 && white < 0.22;
    }

    CGFloat red = 0.0, green = 0.0, blue = 0.0;
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
        return alpha > 0.05 && luminance < 0.22;
    }
    return NO;
}

static UIColor *SCFTargetColor(void) {
    switch (kSCFBackgroundMode) {
        case 1:
            return [UIColor colorWithWhite:0.0 alpha:kSCFBlackAlpha];
        case 2:
            return UIColor.blackColor;
        case 0:
        default:
            return UIColor.clearColor;
    }
}

static BOOL SCFClassLooksLikeBackground(UIView *view) {
    static const char *const backgroundKeywords[] = {
        "background", "backdrop", "material", "platter",
        "blur", "effect", "overlay"
    };
    return SCFClassNameContainsAny(
        view,
        backgroundKeywords,
        sizeof(backgroundKeywords) / sizeof(backgroundKeywords[0]));
}

static BOOL SCFColorsEqual(UIColor *first, UIColor *second, UITraitCollection *traits) {
    if (!first || !second) return first == second;
    if (@available(iOS 13.0, *)) {
        first = [first resolvedColorWithTraitCollection:traits];
        second = [second resolvedColorWithTraitCollection:traits];
    }
    return CGColorEqualToColor(first.CGColor, second.CGColor);
}

static NSUInteger SCFRepairGradientLayer(CALayer *layer, UIColor *target) {
    if (![layer isKindOfClass:CAGradientLayer.class]) return 0;

    CAGradientLayer *gradient = (CAGradientLayer *)layer;
    NSArray *colors = gradient.colors;
    if (colors.count == 0) return 0;

    BOOL containsDarkColor = NO;
    BOOL alreadyTarget = YES;
    for (id value in colors) {
        CGColorRef cgColor = (__bridge CGColorRef)value;
        if (!cgColor || CFGetTypeID(cgColor) != CGColorGetTypeID()) continue;
        UIColor *color = [UIColor colorWithCGColor:cgColor];
        if (SCFColorLooksDark(color, UIScreen.mainScreen.traitCollection)) containsDarkColor = YES;
        if (!CGColorEqualToColor(cgColor, target.CGColor)) alreadyTarget = NO;
    }
    if (!containsDarkColor || alreadyTarget) return 0;

    NSMutableArray *replacement = [NSMutableArray arrayWithCapacity:colors.count];
    for (NSUInteger index = 0; index < colors.count; index++) {
        [replacement addObject:(__bridge id)target.CGColor];
    }
    gradient.colors = replacement;
    return 1;
}

static NSUInteger SCFRepairCandidateTree(UIView *view,
                                         UIColor *target,
                                         NSUInteger depth,
                                         BOOL insideCell) {
    if (!view || depth > 18) return 0;

    BOOL isCell = [view isKindOfClass:UICollectionViewCell.class] ||
                  [view isKindOfClass:UITableViewCell.class] ||
                  SCFCStringContainsInsensitive(SCFClassName(view), "cell");
    BOOL isBackground = SCFClassLooksLikeBackground(view);
    BOOL isSurface = SCFViewIsCandidateSurface(view);
    BOOL preserveCellContent = (insideCell || isCell) && !isBackground;
    NSUInteger changes = 0;

    UIColor *background = view.backgroundColor;
    BOOL shouldReplaceViewColor = !preserveCellContent &&
        (isSurface || isBackground || SCFColorLooksDark(background, view.traitCollection));
    if (shouldReplaceViewColor && !SCFColorsEqual(background, target, view.traitCollection)) {
        view.backgroundColor = target;
        changes++;
    }

    BOOL shouldReplaceLayerColor = !preserveCellContent && view.layer.backgroundColor &&
        (isSurface || isBackground ||
         SCFColorLooksDark([UIColor colorWithCGColor:view.layer.backgroundColor], view.traitCollection));
    if (shouldReplaceLayerColor &&
        !CGColorEqualToColor(view.layer.backgroundColor, target.CGColor)) {
        view.layer.backgroundColor = target.CGColor;
        changes++;
    }

    if (!preserveCellContent && [view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        if (effectView.effect) {
            effectView.effect = nil;
            changes++;
        }
    }

    if (!preserveCellContent) changes += SCFRepairGradientLayer(view.layer, target);
    view.opaque = (kSCFBackgroundMode == 2);

    BOOL descendantsInsideCell = insideCell || isCell;
    for (UIView *subview in view.subviews) {
        changes += SCFRepairCandidateTree(subview, target, depth + 1, descendantsInsideCell);
    }
    return changes;
}

static void SCFApplyToCandidateSurface(UIView *view) {
    if (!view.window || !SCFViewIsCandidateSurface(view)) return;
    if (!SCFFrameCanBeCandidateSurface(view)) return;
    if (!SCFSpotlightSearchIsEditing()) return;

    SCFRepairCandidateTree(view, SCFTargetColor(), 0, NO);
}

#pragma mark - Hook and Spotlight editing state

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!SCFSpotlightSearchIsEditing()) return;
    if (!self.window || !SCFViewIsCandidateSurface(self)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SCFApplyToCandidateSurface(self);
    });
}

- (void)layoutSubviews {
    %orig;
    if (!SCFSpotlightSearchIsEditing()) return;
    if (SCFViewIsCandidateSurface(self)) SCFApplyToCandidateSurface(self);
}

%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            gSCFBeginEditingObserver = [center addObserverForName:UITextFieldTextDidBeginEditingNotification
                                                           object:nil
                                                            queue:NSOperationQueue.mainQueue
                                                       usingBlock:^(NSNotification *note) {
                UIView *view = [note.object isKindOfClass:UIView.class] ? note.object : nil;
                if (SCFViewBelongsToSpotlightSearch(view)) gSCFSpotlightResponder = view;
            }];
            gSCFEndEditingObserver = [center addObserverForName:UITextFieldTextDidEndEditingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(NSNotification *note) {
                if (note.object == gSCFSpotlightResponder) gSCFSpotlightResponder = nil;
            }];
        }
    });
}
