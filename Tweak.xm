#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <string.h>
#include <sys/syslimits.h>
#include <sys/time.h>

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
static const uint64_t kSCFHeartbeatLifetimeMs = 200;
static BOOL gSCFIsSpotlightProcess = NO;
static int gSCFStateToken = NOTIFY_TOKEN_INVALID;
static CFTimeInterval gSCFLastStateCheck = 0.0;
static BOOL gSCFCachedActive = NO;
static BOOL gSCFHasPublishedState = NO;
static BOOL gSCFLastPublishedActive = NO;

@interface SCFOriginalViewState : NSObject
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, assign) BOOL opaque;
@property (nonatomic, assign) BOOL hadLayerBackgroundColor;
@property (nonatomic, strong) UIColor *layerBackgroundColor;
@property (nonatomic, assign) BOOL isEffectView;
@property (nonatomic, strong) UIVisualEffect *effect;
@property (nonatomic, assign) BOOL isGradientLayer;
@property (nonatomic, copy) NSArray *gradientColors;
@property (nonatomic, assign) BOOL isLabel;
@property (nonatomic, strong) UIColor *labelTextColor;
@property (nonatomic, assign) BOOL isButton;
@property (nonatomic, strong) UIColor *buttonTintColor;
@property (nonatomic, strong) UIColor *buttonNormalColor;
@property (nonatomic, strong) UIColor *buttonHighlightedColor;
@property (nonatomic, strong) UIColor *buttonSelectedColor;
@end

@implementation SCFOriginalViewState
@end

static const void *kSCFOriginalViewStateKey = &kSCFOriginalViewStateKey;
static NSHashTable<UIView *> *gSCFTrackedViews = nil;
static BOOL gSCFCandidateMonitorRunning = NO;
static BOOL gSCFCandidateMonitorHasState = NO;
static BOOL gSCFCandidateMonitorLastActive = NO;
static NSUInteger gSCFInternalMutationDepth = 0;

static void SCFStartCandidateStateMonitor(void);

static uint64_t SCFNowMilliseconds(void) {
    struct timeval value;
    gettimeofday(&value, NULL);
    return (uint64_t)value.tv_sec * 1000ULL + (uint64_t)value.tv_usec / 1000ULL;
}

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
    uint64_t state = (SCFNowMilliseconds() << 1) | (active ? 1ULL : 0ULL);
    notify_set_state(gSCFStateToken, state);
    notify_post(kSCFStateName);
}

static BOOL SCFSpotlightIsForeground(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastStateCheck < 0.05) return gSCFCachedActive;
    gSCFLastStateCheck = now;

    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) {
        gSCFCachedActive = NO;
        return NO;
    }

    uint64_t state = 0;
    if (notify_get_state(gSCFStateToken, &state) != NOTIFY_STATUS_OK ||
        state == 0 || (state & 1ULL) == 0) {
        gSCFCachedActive = NO;
        return NO;
    }

    uint64_t heartbeat = state >> 1;
    uint64_t current = SCFNowMilliseconds();
    gSCFCachedActive =
        current >= heartbeat && current - heartbeat <= kSCFHeartbeatLifetimeMs;
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

static void SCFScheduleSpotlightHeartbeat(void) {
    if (!gSCFIsSpotlightProcess) return;
    BOOL active = SCFSpotlightSceneIsForeground();
    if (!gSCFHasPublishedState || active != gSCFLastPublishedActive || active) {
        SCFWriteSpotlightState(active);
        gSCFHasPublishedState = YES;
        gSCFLastPublishedActive = active;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SCFScheduleSpotlightHeartbeat();
    });
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

static void SCFRememberOriginalState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kSCFOriginalViewStateKey)) return;

    SCFOriginalViewState *state = [SCFOriginalViewState new];
    state.backgroundColor = view.backgroundColor;
    state.opaque = view.opaque;
    if (view.layer.backgroundColor) {
        state.hadLayerBackgroundColor = YES;
        state.layerBackgroundColor = [UIColor colorWithCGColor:view.layer.backgroundColor];
    }

    if ([view isKindOfClass:UIVisualEffectView.class]) {
        state.isEffectView = YES;
        state.effect = ((UIVisualEffectView *)view).effect;
    }

    if ([view.layer isKindOfClass:CAGradientLayer.class]) {
        state.isGradientLayer = YES;
        state.gradientColors = [((CAGradientLayer *)view.layer).colors copy];
    }

    if ([view isKindOfClass:UILabel.class]) {
        state.isLabel = YES;
        state.labelTextColor = ((UILabel *)view).textColor;
    }

    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        state.isButton = YES;
        state.buttonTintColor = button.tintColor;
        state.buttonNormalColor = [button titleColorForState:UIControlStateNormal];
        state.buttonHighlightedColor = [button titleColorForState:UIControlStateHighlighted];
        state.buttonSelectedColor = [button titleColorForState:UIControlStateSelected];
    }

    objc_setAssociatedObject(view, kSCFOriginalViewStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gSCFTrackedViews) gSCFTrackedViews = [NSHashTable weakObjectsHashTable];
    [gSCFTrackedViews addObject:view];
    SCFStartCandidateStateMonitor();
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

    SCFRememberOriginalState(view);

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
        label.backgroundColor = UIColor.clearColor;
    }

    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        button.tintColor = UIColor.whiteColor;
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateHighlighted];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateSelected];
        changes++;
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
    view.opaque = (kSCFBackgroundMode == 2);

    for (UIView *subview in view.subviews) {
        changes += SCFRepairCandidateTree(subview, target, depth + 1);
    }
    return changes;
}

static void SCFApplyToCandidateSurface(UIView *view) {
    if (!SCFSpotlightIsForeground()) return;
    if (!view.window || !SCFViewIsCandidateSurface(view)) return;
    if (!SCFFrameCanBeCandidateSurface(view)) return;

    UIColor *target = SCFTargetColor();
    gSCFInternalMutationDepth++;
    SCFRepairCandidateTree(view, target, 0);
    gSCFInternalMutationDepth--;
}

static void SCFRestoreTrackedCandidateViews(void) {
    NSArray<UIView *> *views = gSCFTrackedViews.allObjects;
    [UIView performWithoutAnimation:^{
        gSCFInternalMutationDepth++;
        for (UIView *view in views) {
            SCFOriginalViewState *state =
                objc_getAssociatedObject(view, kSCFOriginalViewStateKey);
            if (!state) continue;

            view.backgroundColor = state.backgroundColor;
            view.opaque = state.opaque;
            view.layer.backgroundColor = state.hadLayerBackgroundColor
                ? state.layerBackgroundColor.CGColor : nil;

            if (state.isEffectView && [view isKindOfClass:UIVisualEffectView.class]) {
                ((UIVisualEffectView *)view).effect = state.effect;
            }
            if (state.isGradientLayer &&
                [view.layer isKindOfClass:CAGradientLayer.class]) {
                ((CAGradientLayer *)view.layer).colors = state.gradientColors;
            }
            if (state.isLabel && [view isKindOfClass:UILabel.class]) {
                ((UILabel *)view).textColor = state.labelTextColor;
            }
            if (state.isButton && [view isKindOfClass:UIButton.class]) {
                UIButton *button = (UIButton *)view;
                button.tintColor = state.buttonTintColor;
                [button setTitleColor:state.buttonNormalColor
                              forState:UIControlStateNormal];
                [button setTitleColor:state.buttonHighlightedColor
                              forState:UIControlStateHighlighted];
                [button setTitleColor:state.buttonSelectedColor
                              forState:UIControlStateSelected];
            }

            // Capture a fresh baseline next time Spotlight becomes active.
            objc_setAssociatedObject(view, kSCFOriginalViewStateKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        gSCFInternalMutationDepth--;
    }];
}

static void SCFReapplyTrackedCandidateViews(void) {
    NSArray<UIView *> *views = gSCFTrackedViews.allObjects;
    [UIView performWithoutAnimation:^{
        for (UIView *view in views) {
            BOOL hasTrackedAncestor = NO;
            UIView *ancestor = view.superview;
            for (NSUInteger depth = 0; ancestor && depth < 24; depth++) {
                if ([gSCFTrackedViews containsObject:ancestor]) {
                    hasTrackedAncestor = YES;
                    break;
                }
                ancestor = ancestor.superview;
            }
            if (hasTrackedAncestor) continue;
            SCFApplyToCandidateSurface(view);
        }
    }];
}

static void SCFScheduleCandidateStateMonitor(void) {
    if (!gSCFCandidateMonitorRunning) return;

    BOOL active = SCFSpotlightIsForeground();
    if (!gSCFCandidateMonitorHasState ||
        active != gSCFCandidateMonitorLastActive) {
        gSCFCandidateMonitorHasState = YES;
        gSCFCandidateMonitorLastActive = active;
        if (active) {
            SCFReapplyTrackedCandidateViews();
        } else {
            SCFRestoreTrackedCandidateViews();
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SCFScheduleCandidateStateMonitor();
    });
}

static void SCFStartCandidateStateMonitor(void) {
    if (gSCFCandidateMonitorRunning) return;
    gSCFCandidateMonitorRunning = YES;
    gSCFCandidateMonitorHasState = YES;
    gSCFCandidateMonitorLastActive = SCFSpotlightIsForeground();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SCFScheduleCandidateStateMonitor();
    });
}

// UIKit rebuilds parts of the candidate strip after layout.  Repairing it
// only once is therefore not enough: it can put a black colour/effect back
// on the expand button or candidate grid on the following run-loop turn.
// These helpers are deliberately limited to views in a candidate hierarchy;
// regular keyboard keys and every other SpringBoard view are left untouched.
static BOOL SCFShouldSuppressBackground(UIView *view, UIColor *color) {
    return SCFSpotlightIsForeground() && view && color && SCFViewIsCandidateSurface(view) &&
        SCFColorLooksDark(color, view.traitCollection);
}

#pragma mark - Hook and Spotlight editing state

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if (gSCFInternalMutationDepth > 0) {
        %orig;
        return;
    }
    SCFOriginalViewState *trackedState =
        objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
    if (trackedState) trackedState.backgroundColor = color;
    if (SCFShouldSuppressBackground(self, color)) {
        SCFRememberOriginalState(self);
        SCFOriginalViewState *state =
            objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
        state.backgroundColor = color;
        %orig(SCFTargetColor());
        return;
    }
    %orig;
}

- (void)setOpaque:(BOOL)opaque {
    if (gSCFInternalMutationDepth > 0) {
        %orig;
        return;
    }
    SCFOriginalViewState *trackedState =
        objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
    if (trackedState) trackedState.opaque = opaque;
    if (opaque && SCFSpotlightIsForeground() && SCFViewIsCandidateSurface(self)) {
        SCFRememberOriginalState(self);
        SCFOriginalViewState *state =
            objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
        state.opaque = opaque;
        %orig(NO);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window || !SCFViewIsCandidateSurface(self)) return;
    SCFApplyToCandidateSurface(self);
}

- (void)layoutSubviews {
    %orig;
    if (SCFViewIsCandidateSurface(self)) SCFApplyToCandidateSurface(self);
}

%end

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    if (gSCFInternalMutationDepth > 0) {
        %orig;
        return;
    }
    SCFOriginalViewState *trackedState =
        objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
    if (trackedState) {
        trackedState.isEffectView = YES;
        trackedState.effect = effect;
    }
    if (effect && SCFSpotlightIsForeground() && SCFViewIsCandidateSurface(self)) {
        SCFRememberOriginalState(self);
        SCFOriginalViewState *state =
            objc_getAssociatedObject(self, kSCFOriginalViewStateKey);
        state.isEffectView = YES;
        state.effect = effect;
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
            SCFScheduleSpotlightHeartbeat();
        });
    }
}
