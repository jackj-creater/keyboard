#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - User-adjustable constants

// 0 = fully transparent
// 1 = translucent black
// 2 = solid black
static const NSInteger kSCFBackgroundMode = 0;

// Used only when kSCFBackgroundMode == 1.
// Suggested range: 0.18 - 0.45
static const CGFloat kSCFBlackAlpha = 0.30;

// Keep this enabled until the iOS 17.1.1 class names are confirmed on-device.
static const BOOL kSCFEnableLogging = YES;

static const void *kSCFLoggedSurfaceKey = &kSCFLoggedSurfaceKey;
static __weak UIView *gSCFSpotlightResponder = nil;
static id gSCFBeginEditingObserver = nil;
static id gSCFEndEditingObserver = nil;

#pragma mark - Class and context helpers

static BOOL SCFStringContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (value.length == 0) return NO;

    NSString *lower = value.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle.lowercaseString]) return YES;
    }
    return NO;
}

static NSString *SCFClassName(id object) {
    return object ? (NSStringFromClass([object class]) ?: @"") : @"";
}

static NSArray<NSString *> *SCFSearchKeywords(void) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[@"spotlight", @"search", @"searchui"];
    });
    return keywords;
}

static BOOL SCFViewOrAncestorMatches(UIView *view,
                                     NSArray<NSString *> *keywords,
                                     NSUInteger maxDepth) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth <= maxDepth; depth++) {
        if (SCFStringContainsAny(SCFClassName(current), keywords)) return YES;
        current = current.superview;
    }
    return NO;
}

static BOOL SCFControllerChainMatches(UIView *view, NSArray<NSString *> *keywords) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 24; depth++) {
        if (SCFStringContainsAny(SCFClassName(responder), keywords)) return YES;
        responder = responder.nextResponder;
    }
    return NO;
}

static BOOL SCFViewBelongsToSpotlightSearch(UIView *view) {
    if (!view) return NO;
    return SCFViewOrAncestorMatches(view, SCFSearchKeywords(), 20) ||
           SCFControllerChainMatches(view, SCFSearchKeywords());
}

static UIView *SCFFindFirstResponder(UIView *view, NSUInteger depth) {
    if (!view || depth > 30) return nil;
    if (view.isFirstResponder) return view;

    for (UIView *subview in view.subviews) {
        UIView *found = SCFFindFirstResponder(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NSArray<UIWindow *> *SCFApplicationWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (![windows containsObject:window]) [windows addObject:window];
        }
    }

    return windows;
}

static BOOL SCFSpotlightSearchIsEditing(void) {
    if (gSCFSpotlightResponder && gSCFSpotlightResponder.isFirstResponder) return YES;

    static CFTimeInterval lastCheck = 0.0;
    static BOOL cachedResult = NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastCheck < 0.20) return cachedResult;
    lastCheck = now;

    cachedResult = NO;
    for (UIWindow *window in SCFApplicationWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIView *firstResponder = SCFFindFirstResponder(window, 0);
        if (SCFViewBelongsToSpotlightSearch(firstResponder)) {
            gSCFSpotlightResponder = firstResponder;
            cachedResult = YES;
            break;
        }
    }
    return cachedResult;
}

static BOOL SCFViewIsCandidateSurface(UIView *view) {
    NSString *name = SCFClassName(view).lowercaseString;
    if (name.length == 0) return NO;

    BOOL candidateClass = [name containsString:@"candidate"] ||
                          [name containsString:@"prediction"] ||
                          [name containsString:@"completion"];
    if (!candidateClass) return NO;

    // Cells own selection/highlight visuals and are intentionally left alone.
    if ([name containsString:@"cell"] || [name containsString:@"label"]) return NO;

    return SCFStringContainsAny(name, @[
        @"bar", @"grid", @"overlay", @"toggle", @"arrow",
        @"inline", @"header", @"background", @"view"
    ]);
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
    return SCFStringContainsAny(SCFClassName(view), @[
        @"background", @"backdrop", @"material", @"platter",
        @"blur", @"effect", @"overlay"
    ]);
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

    NSString *className = SCFClassName(view);
    BOOL isCell = [view isKindOfClass:UICollectionViewCell.class] ||
                  [view isKindOfClass:UITableViewCell.class] ||
                  [className.lowercaseString containsString:@"cell"];
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

    NSUInteger changes = SCFRepairCandidateTree(view, SCFTargetColor(), 0, NO);
    if (changes == 0 || !kSCFEnableLogging) return;

    if (![objc_getAssociatedObject(view, kSCFLoggedSurfaceKey) boolValue]) {
        NSLog(@"[SCF] repaired surface=%@ frame=%@ changes=%lu window=%@",
              SCFClassName(view),
              NSStringFromCGRect(view.frame),
              (unsigned long)changes,
              SCFClassName(view.window));
        objc_setAssociatedObject(view,
                                 kSCFLoggedSurfaceKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Hook and Spotlight editing state

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!self.window || !SCFViewIsCandidateSurface(self)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SCFApplyToCandidateSurface(self);
    });
}

- (void)layoutSubviews {
    %orig;
    if (SCFViewIsCandidateSurface(self)) SCFApplyToCandidateSurface(self);
}

%end

%ctor {
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

        if (kSCFEnableLogging) {
            NSLog(@"[SCF] 0.2 loaded in process=%@", NSProcessInfo.processInfo.processName);
        }
    }
}
