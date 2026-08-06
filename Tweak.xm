#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - User-adjustable constants

// 0 = fully transparent
// 1 = translucent black
// 2 = solid black
static const NSInteger kSCFBackgroundMode = 1;

// Used only when kSCFBackgroundMode == 1.
// Suggested range: 0.18 - 0.45
static const CGFloat kSCFBlackAlpha = 0.30;

// Keep logging enabled for the first test build.
// Logs are prefixed with [SCF].
static const BOOL kSCFEnableLogging = YES;

#pragma mark - Helpers

static BOOL SCFStringContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (value.length == 0) return NO;

    NSString *lower = value.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

static NSString *SCFClassName(id object) {
    if (!object) return @"";
    return NSStringFromClass([object class]) ?: @"";
}

static NSArray<NSString *> *SCFCandidateKeywords(void) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"candidate",
            @"prediction",
            @"completion",
            @"inputset",
            @"keyboard",
            @"textinput",
            @"expanded"
        ];
    });
    return keywords;
}

static NSArray<NSString *> *SCFSearchKeywords(void) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"spotlight",
            @"search",
            @"searchui"
        ];
    });
    return keywords;
}

static BOOL SCFViewOrAncestorMatches(UIView *view, NSArray<NSString *> *keywords, NSUInteger maxDepth) {
    UIView *current = view;
    NSUInteger depth = 0;

    while (current && depth <= maxDepth) {
        if (SCFStringContainsAny(SCFClassName(current), keywords)) {
            return YES;
        }
        current = current.superview;
        depth++;
    }

    return NO;
}

static BOOL SCFControllerChainMatches(UIView *view, NSArray<NSString *> *keywords) {
    UIResponder *responder = view;
    NSUInteger depth = 0;

    while (responder && depth < 20) {
        if (SCFStringContainsAny(SCFClassName(responder), keywords)) {
            return YES;
        }
        responder = responder.nextResponder;
        depth++;
    }

    return NO;
}

static BOOL SCFWindowLooksLikeSpotlight(UIWindow *window) {
    if (!window) return NO;

    if (SCFStringContainsAny(SCFClassName(window), SCFSearchKeywords())) {
        return YES;
    }

    UIViewController *root = window.rootViewController;
    UIViewController *current = root;
    NSUInteger depth = 0;

    while (current && depth < 12) {
        if (SCFStringContainsAny(SCFClassName(current), SCFSearchKeywords())) {
            return YES;
        }

        if (current.presentedViewController) {
            current = current.presentedViewController;
        } else if ([current isKindOfClass:[UINavigationController class]]) {
            current = ((UINavigationController *)current).visibleViewController;
        } else if ([current isKindOfClass:[UITabBarController class]]) {
            current = ((UITabBarController *)current).selectedViewController;
        } else {
            break;
        }
        depth++;
    }

    return NO;
}

static BOOL SCFFrameLooksCandidateRelated(UIView *view) {
    CGRect frame = view.bounds;
    CGFloat width = CGRectGetWidth(frame);
    CGFloat height = CGRectGetHeight(frame);

    if (width <= 0.0 || height <= 0.0) return NO;

    // Candidate bar / arrow button / expanded panel.
    BOOL barLike = width >= 40.0 && height >= 35.0 && height <= 420.0;
    BOOL notFullScreen = !(width > UIScreen.mainScreen.bounds.size.width * 0.95 &&
                           height > UIScreen.mainScreen.bounds.size.height * 0.60);

    return barLike && notFullScreen;
}

static BOOL SCFColorLooksDark(UIColor *color) {
    if (!color) return NO;

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
        case 0:
            return UIColor.clearColor;
        case 2:
            return UIColor.blackColor;
        case 1:
        default:
            return [UIColor colorWithWhite:0.0 alpha:kSCFBlackAlpha];
    }
}

static BOOL SCFShouldInspectView(UIView *view) {
    if (!view.window) return NO;
    if (!SCFFrameLooksCandidateRelated(view)) return NO;

    BOOL candidateContext =
        SCFViewOrAncestorMatches(view, SCFCandidateKeywords(), 8) ||
        SCFControllerChainMatches(view, SCFCandidateKeywords());

    if (!candidateContext) return NO;

    BOOL spotlightContext =
        SCFWindowLooksLikeSpotlight(view.window) ||
        SCFViewOrAncestorMatches(view, SCFSearchKeywords(), 16) ||
        SCFControllerChainMatches(view, SCFSearchKeywords());

    return spotlightContext;
}

static void SCFApplyToView(UIView *view) {
    if (!SCFShouldInspectView(view)) return;

    UIColor *background = view.backgroundColor;
    BOOL classLooksMaterial = SCFStringContainsAny(
        SCFClassName(view),
        @[@"backdrop", @"visualeffect", @"material", @"platter", @"background"]
    );

    BOOL shouldChange = SCFColorLooksDark(background) || classLooksMaterial;
    if (!shouldChange) return;

    UIColor *target = SCFTargetColor();

    if (kSCFEnableLogging) {
        NSLog(@"[SCF] matched class=%@ frame=%@ background=%@ window=%@",
              SCFClassName(view),
              NSStringFromCGRect(view.frame),
              background,
              SCFClassName(view.window));
    }

    view.backgroundColor = target;
    view.opaque = (kSCFBackgroundMode == 2);

    // Some iOS material views keep an internal content view with an opaque color.
    for (UIView *subview in view.subviews) {
        NSString *subclass = SCFClassName(subview);
        BOOL relevantSubview = SCFStringContainsAny(
            subclass,
            @[@"backdrop", @"visualeffect", @"material", @"background", @"content"]
        );

        if (relevantSubview && SCFColorLooksDark(subview.backgroundColor)) {
            subview.backgroundColor = target;
            subview.opaque = (kSCFBackgroundMode == 2);

            if (kSCFEnableLogging) {
                NSLog(@"[SCF] adjusted subview class=%@ frame=%@",
                      subclass,
                      NSStringFromCGRect(subview.frame));
            }
        }
    }
}

#pragma mark - Hook

%hook UIView

- (void)didMoveToWindow {
    %orig;

    if (!self.window) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        SCFApplyToView(self);
    });
}

- (void)layoutSubviews {
    %orig;
    SCFApplyToView(self);
}

%end

%ctor {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        if (kSCFEnableLogging) {
            NSLog(@"[SCF] loaded in process=%@", process);
        }
    }
}
