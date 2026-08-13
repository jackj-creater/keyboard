#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <signal.h>
#include <string.h>
#include <sys/syslimits.h>
#include <unistd.h>

#pragma mark - User-adjustable constants

// 0 = fully transparent
// 1 = translucent black
// 2 = solid black
static const NSInteger kSCFBackgroundMode = 0;

// Used only when kSCFBackgroundMode == 1.
// Suggested range: 0.18 - 0.45
static const CGFloat kSCFBlackAlpha = 0.30;

#pragma mark - Spotlight foreground scope

static const char *const kSCFStateName =
    "com.keyboard.spotlightcandidatefix.foreground-heartbeat";
static const uint64_t kSCFStateMagic = 0x5343460000000000ULL;
static const uint64_t kSCFStateMagicMask = 0xFFFFFF0000000000ULL;
static const uint64_t kSCFStateProcessMask = 0x000000FFFFFFFFFEULL;
static BOOL gSCFIsSpotlightProcess = NO;
static int gSCFStateToken = NOTIFY_TOKEN_INVALID;
static CFTimeInterval gSCFLastStateCheck = 0.0;
static BOOL gSCFCachedActive = NO;
static NSUInteger gSCFInternalRepairDepth = 0;
static id gSCFDidBecomeActiveObserver = nil;
static id gSCFWillResignActiveObserver = nil;
static id gSCFWillEnterForegroundObserver = nil;
static id gSCFDidEnterBackgroundObserver = nil;
static id gSCFSceneDidActivateObserver = nil;
static id gSCFSceneWillDeactivateObserver = nil;
static id gSCFSceneWillEnterForegroundObserver = nil;

static void SCFEnsureStateToken(void) {
    if (gSCFStateToken != NOTIFY_TOKEN_INVALID) return;
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(kSCFStateName, &token) == NOTIFY_STATUS_OK) {
        gSCFStateToken = token;
    }
}

static void SCFWriteSpotlightState(BOOL active) {
    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) return;
    uint64_t processID = (uint64_t)(uint32_t)getpid();
    uint64_t state = kSCFStateMagic | (processID << 1) |
        (active ? 1ULL : 0ULL);
    notify_set_state(gSCFStateToken, state);
    notify_post(kSCFStateName);
}

static BOOL SCFSpotlightIsForeground(void) {
    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) {
        gSCFCachedActive = NO;
        return NO;
    }

    // This function is reached by global UIKit setters.  During the first
    // keyboard layout after unlock that can mean hundreds of calls in one
    // frame, so all notify-server work must stay behind the time cache.
    // A stale value can live for at most 50 ms; after a lock/unlock cycle the
    // cache is already old and the first call refreshes it immediately.
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastStateCheck < 0.05) return gSCFCachedActive;
    gSCFLastStateCheck = now;

    uint64_t state = 0;
    if (notify_get_state(gSCFStateToken, &state) != NOTIFY_STATUS_OK ||
        (state & kSCFStateMagicMask) != kSCFStateMagic ||
        (state & 1ULL) == 0) {
        gSCFCachedActive = NO;
        return NO;
    }

    pid_t processID = (pid_t)((state & kSCFStateProcessMask) >> 1);
    errno = 0;
    int result = kill(processID, 0);
    gSCFCachedActive = result == 0 || errno == EPERM;
    return gSCFCachedActive;
}

static BOOL SCFSpotlightSceneIsForeground(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) return NO;
    for (UIScene *scene in application.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return YES;
        }
    }
    return NO;
}

static void SCFInstallSpotlightStateObservers(void) {
    if (!gSCFIsSpotlightProcess) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mainQueue = NSOperationQueue.mainQueue;

    gSCFDidBecomeActiveObserver =
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            SCFWriteSpotlightState(YES);
        }];
    gSCFWillResignActiveObserver =
        [center addObserverForName:UIApplicationWillResignActiveNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            SCFWriteSpotlightState(NO);
        }];
    gSCFWillEnterForegroundObserver =
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            // Publish before the shared keyboard lays out its reused views.
            SCFWriteSpotlightState(YES);
        }];
    gSCFDidEnterBackgroundObserver =
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            SCFWriteSpotlightState(NO);
        }];

    if (@available(iOS 13.0, *)) {
        gSCFSceneDidActivateObserver =
            [center addObserverForName:UISceneDidActivateNotification
                               object:nil queue:mainQueue
                           usingBlock:^(__unused NSNotification *note) {
                SCFWriteSpotlightState(YES);
            }];
        gSCFSceneWillDeactivateObserver =
            [center addObserverForName:UISceneWillDeactivateNotification
                               object:nil queue:mainQueue
                           usingBlock:^(__unused NSNotification *note) {
                SCFWriteSpotlightState(NO);
            }];
        gSCFSceneWillEnterForegroundObserver =
            [center addObserverForName:UISceneWillEnterForegroundNotification
                               object:nil queue:mainQueue
                           usingBlock:^(__unused NSNotification *note) {
                // This normally arrives before candidate-view layout.
                SCFWriteSpotlightState(YES);
            }];
    }

    SCFWriteSpotlightState(SCFSpotlightSceneIsForeground());
}

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

static const char *const kSCFCandidateKeywords[] = {
    "candidate", "prediction", "completion", "suggestion",
    "autocorrection", "alternative", "proactive", "inline",
    "uikbbackdrop", "uikbinputbackdrop", "inputsethost", "keyboarddock"
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

static BOOL SCFViewIsCandidateSurface(UIView *view) {
    if (!view) return NO;
    return SCFViewOrAncestorMatches(
        view,
        kSCFCandidateKeywords,
        sizeof(kSCFCandidateKeywords) / sizeof(kSCFCandidateKeywords[0]),
        16);
}

static BOOL SCFFrameCanBeCandidateSurface(UIView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 8.0 || height < 8.0) return NO;

    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    return height < screenHeight * 0.70;
}

static BOOL SCFStringLooksLikeExpandControl(NSString *value) {
    if (value.length == 0) return NO;
    NSString *text = value.lowercaseString;
    static NSArray<NSString *> *needles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        needles = @[
            @"expand", @"collapse", @"chevron", @"arrow", @"more candidates",
            @"show candidates", @"hide candidates",
            @"\u5c55\u5f00", @"\u6536\u8d77", @"\u66f4\u591a\u5019\u9009"
        ];
    });
    for (NSString *needle in needles) {
        if ([text containsString:needle]) return YES;
    }
    return NO;
}

static BOOL SCFViewHasExpandSemantics(UIView *view) {
    static const char *const expandKeywords[] = {
        "expand", "collapse", "chevron", "arrow", "morebutton",
        "candidatebutton", "candidatebarbutton"
    };
    if (SCFClassNameContainsAny(
            view, expandKeywords,
            sizeof(expandKeywords) / sizeof(expandKeywords[0]))) return YES;

    return SCFStringLooksLikeExpandControl(view.accessibilityIdentifier) ||
        SCFStringLooksLikeExpandControl(view.accessibilityLabel) ||
        SCFStringLooksLikeExpandControl(view.accessibilityHint);
}

static BOOL SCFViewHasTrailingButtonGeometry(UIView *view) {
    if (!view.window || !SCFViewIsCandidateSurface(view)) return NO;

    CGRect rect = [view convertRect:view.bounds toView:view.window];
    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    if (width < 24.0 || height < 24.0 || width > 104.0 || height > 104.0) return NO;
    CGFloat ratio = width / height;
    if (ratio < 0.55 || ratio > 1.85) return NO;

    CGFloat windowWidth = CGRectGetWidth(view.window.bounds);
    CGFloat trailingGap = windowWidth - CGRectGetMaxX(rect);
    return trailingGap >= -4.0 && trailingGap <= MAX(20.0, windowWidth * 0.04);
}

static BOOL SCFViewIsExpandControl(UIView *view) {
    if (!view || !view.window || !SCFViewIsCandidateSurface(view)) return NO;
    if (SCFViewHasExpandSemantics(view)) return YES;

    // The private iOS 17 class does not always expose an accessibility label.
    // In that case the expand control is the compact UIControl at the trailing
    // edge of the candidate bar. Candidate cells are not UIControls.
    return [view isKindOfClass:UIControl.class] &&
        SCFViewHasTrailingButtonGeometry(view);
}

static UIView *SCFFindExpandControl(UIView *view) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth <= 6; depth++) {
        if (SCFViewIsExpandControl(current)) return current;
        current = current.superview;
    }
    return nil;
}

static UIView *SCFExpandRepairRoot(UIView *control) {
    UIView *root = control;
    for (NSUInteger depth = 0; root.superview && depth < 4; depth++) {
        UIView *parent = root.superview;
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        if (width < 20.0 || height < 20.0 || width > 112.0 || height > 112.0) break;
        if (!SCFViewIsCandidateSurface(parent)) break;
        root = parent;
    }
    return root;
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

static NSUInteger SCFRepairGradientLayer(CALayer *layer, UIColor *target);

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
                                         NSUInteger depth) {
    if (!view || depth > 18) return 0;

    BOOL isCell = [view isKindOfClass:UICollectionViewCell.class] ||
                  [view isKindOfClass:UITableViewCell.class] ||
                  SCFCStringContainsInsensitive(SCFClassName(view), "cell");
    BOOL isBackground = SCFClassLooksLikeBackground(view);
    BOOL isSurface = SCFViewIsCandidateSurface(view);
    NSUInteger changes = 0;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (!SCFColorsEqual(label.textColor, UIColor.whiteColor, label.traitCollection)) {
            label.textColor = UIColor.whiteColor;
            changes++;
        }
        if (!SCFColorsEqual(label.backgroundColor, UIColor.clearColor,
                            label.traitCollection)) {
            label.backgroundColor = UIColor.clearColor;
            changes++;
        }
    }

    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (!SCFColorsEqual(button.tintColor, UIColor.whiteColor,
                            button.traitCollection)) {
            button.tintColor = UIColor.whiteColor;
            changes++;
        }
        if (!SCFColorsEqual([button titleColorForState:UIControlStateNormal],
                            UIColor.whiteColor, button.traitCollection)) {
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            changes++;
        }
        if (!SCFColorsEqual([button titleColorForState:UIControlStateHighlighted],
                            UIColor.whiteColor, button.traitCollection)) {
            [button setTitleColor:UIColor.whiteColor
                          forState:UIControlStateHighlighted];
            changes++;
        }
        if (!SCFColorsEqual([button titleColorForState:UIControlStateSelected],
                            UIColor.whiteColor, button.traitCollection)) {
            [button setTitleColor:UIColor.whiteColor
                          forState:UIControlStateSelected];
            changes++;
        }
    }

    UIColor *background = view.backgroundColor;
    BOOL shouldReplaceViewColor = isSurface || isBackground || isCell ||
        [view isKindOfClass:UILabel.class] || [view isKindOfClass:UIButton.class] ||
        SCFColorLooksDark(background, view.traitCollection);
    if (shouldReplaceViewColor && !SCFColorsEqual(background, target, view.traitCollection)) {
        view.backgroundColor = target;
        changes++;
    }

    BOOL shouldReplaceLayerColor = view.layer.backgroundColor &&
        (isSurface || isBackground ||
         SCFColorLooksDark([UIColor colorWithCGColor:view.layer.backgroundColor], view.traitCollection));
    if (shouldReplaceLayerColor &&
        !CGColorEqualToColor(view.layer.backgroundColor, target.CGColor)) {
        view.layer.backgroundColor = target.CGColor;
        changes++;
    }

    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        if (effectView.effect) {
            effectView.effect = nil;
            changes++;
        }
    }

    changes += SCFRepairGradientLayer(view.layer, target);
    BOOL targetOpaque = (kSCFBackgroundMode == 2);
    if (view.opaque != targetOpaque) {
        view.opaque = targetOpaque;
        changes++;
    }

    for (UIView *subview in view.subviews) {
        changes += SCFRepairCandidateTree(subview, target, depth + 1);
    }
    return changes;
}

static void SCFApplyToCandidateSurface(UIView *view) {
    if (!SCFSpotlightIsForeground()) return;
    UIView *control = SCFFindExpandControl(view);
    if (!control) return;
    UIView *root = SCFExpandRepairRoot(control);
    if (!root.window || !SCFFrameCanBeCandidateSurface(root)) return;

    UIColor *target = SCFTargetColor();
    gSCFInternalRepairDepth++;
    SCFRepairCandidateTree(root, target, 0);
    gSCFInternalRepairDepth--;
}

// UIKit rebuilds the expand control after layout, so keep suppressing dark
// backgrounds only inside that compact control hierarchy. The candidate bar
// and expanded candidate grid deliberately retain their system appearance.
static BOOL SCFShouldSuppressBackground(UIView *view, UIColor *color) {
    return SCFSpotlightIsForeground() && view && color &&
        SCFFindExpandControl(view) != nil &&
        SCFColorLooksDark(color, view.traitCollection);
}

#pragma mark - Hook and Spotlight editing state

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if (gSCFInternalRepairDepth > 0) {
        %orig;
        return;
    }
    if (SCFShouldSuppressBackground(self, color)) {
        %orig(SCFTargetColor());
        return;
    }
    %orig;
}

- (void)setOpaque:(BOOL)opaque {
    if (gSCFInternalRepairDepth > 0) {
        %orig;
        return;
    }
    if (opaque && SCFSpotlightIsForeground() && SCFFindExpandControl(self)) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window || !SCFFindExpandControl(self)) return;
    SCFApplyToCandidateSurface(self);
}

- (void)layoutSubviews {
    %orig;
    if (!self.window || self.hidden || self.alpha < 0.01) return;
    if (SCFViewIsExpandControl(self)) SCFApplyToCandidateSurface(self);
}

%end

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    if (gSCFInternalRepairDepth > 0) {
        %orig;
        return;
    }
    if (effect && SCFSpotlightIsForeground() && SCFFindExpandControl(self)) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%ctor {
    // Keep dyld initialization C-only.  UIKit objects are touched later on
    // the main queue, after Spotlight has completed process initialization.
    char executablePath[PATH_MAX] = {0};
    uint32_t pathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &pathSize) != 0) return;
    const char *name = strrchr(executablePath, '/');
    name = name ? name + 1 : executablePath;
    gSCFIsSpotlightProcess = strcmp(name, "Spotlight") == 0;
    if (gSCFIsSpotlightProcess) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCFInstallSpotlightStateObservers();
        });
    }
}
