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
static BOOL gSCFIsInputUIProcess = NO;
static int gSCFStateToken = NOTIFY_TOKEN_INVALID;
static CFTimeInterval gSCFLastProcessValidation = 0.0;
static BOOL gSCFHasReadState = NO;
static BOOL gSCFCachedActive = NO;
static uint64_t gSCFStateGeneration = 0;
static uint64_t gSCFLastLayoutRepairGeneration = ~0ULL;
static NSUInteger gSCFInternalRepairDepth = 0;
static id gSCFWillResignActiveObserver = nil;
static id gSCFDidEnterBackgroundObserver = nil;
static id gSCFSceneWillDeactivateObserver = nil;

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

static BOOL SCFReadPublishedSpotlightState(void) {
    uint64_t state = 0;
    if (notify_get_state(gSCFStateToken, &state) != NOTIFY_STATUS_OK ||
        (state & kSCFStateMagicMask) != kSCFStateMagic ||
        (state & 1ULL) == 0) {
        return NO;
    }

    pid_t processID = (pid_t)((state & kSCFStateProcessMask) >> 1);
    errno = 0;
    int result = kill(processID, 0);
    return result == 0 || errno == EPERM;
}

static BOOL SCFSpotlightIsForeground(void) {
    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) {
        gSCFCachedActive = NO;
        return NO;
    }

    int changed = 0;
    BOOL stateChanged =
        notify_check(gSCFStateToken, &changed) == NOTIFY_STATUS_OK && changed;
    if (!gSCFHasReadState || stateChanged) {
        BOOL firstRead = !gSCFHasReadState;
        BOOL previous = gSCFCachedActive;
        gSCFCachedActive = SCFReadPublishedSpotlightState();
        gSCFHasReadState = YES;
        gSCFLastProcessValidation = CACurrentMediaTime();
        if (firstRead || previous != gSCFCachedActive) {
            gSCFStateGeneration++;
        }
        return gSCFCachedActive;
    }

    // This is only a stale-state safety net for an abnormal Spotlight exit;
    // normal transitions are handled entirely by notify_check above.
    if (gSCFCachedActive) {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - gSCFLastProcessValidation >= 1.0) {
            gSCFLastProcessValidation = now;
            if (!SCFReadPublishedSpotlightState()) {
                gSCFCachedActive = NO;
                gSCFStateGeneration++;
            }
        }
    }
    return gSCFCachedActive;
}

static void SCFInstallSpotlightStateObservers(void) {
    if (!gSCFIsSpotlightProcess) return;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mainQueue = NSOperationQueue.mainQueue;

    gSCFWillResignActiveObserver =
        [center addObserverForName:UIApplicationWillResignActiveNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            SCFWriteSpotlightState(NO);
        }];
    gSCFDidEnterBackgroundObserver =
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                           object:nil queue:mainQueue
                       usingBlock:^(__unused NSNotification *note) {
            SCFWriteSpotlightState(NO);
        }];

    if (@available(iOS 13.0, *)) {
        gSCFSceneWillDeactivateObserver =
            [center addObserverForName:UISceneWillDeactivateNotification
                               object:nil queue:mainQueue
                           usingBlock:^(__unused NSNotification *note) {
                SCFWriteSpotlightState(NO);
            }];
    }
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

static BOOL SCFViewClassIsCandidateContainer(UIView *view) {
    static const char *const containerKeywords[] = {
        "candidate", "prediction", "completion", "suggestion",
        "autocorrection", "alternative", "proactive", "inline"
    };
    return view && SCFClassNameContainsAny(
        view,
        containerKeywords,
        sizeof(containerKeywords) / sizeof(containerKeywords[0]));
}

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
    if (!view.window || !SCFViewIsCandidateSurface(view)) return;
    if (!SCFFrameCanBeCandidateSurface(view)) return;
    if (!SCFSpotlightIsForeground()) return;

    UIColor *target = SCFTargetColor();
    gSCFInternalRepairDepth++;
    SCFRepairCandidateTree(view, target, 0);
    gSCFInternalRepairDepth--;
}

// UIKit rebuilds parts of the candidate strip after layout.  Repairing it
// only once is therefore not enough: it can put a black colour/effect back
// on the expand button or candidate grid on the following run-loop turn.
// These helpers are deliberately limited to views in a candidate hierarchy;
// regular keyboard keys and every other SpringBoard view are left untouched.
static BOOL SCFShouldSuppressBackground(UIView *view, UIColor *color) {
    return view && color && SCFViewIsCandidateSurface(view) &&
        SCFColorLooksDark(color, view.traitCollection) &&
        SCFSpotlightIsForeground();
}

#pragma mark - Hook and Spotlight editing state

%group SCFSpotlightHooks

%hook UITextField

- (BOOL)becomeFirstResponder {
    // Publish synchronously before UIKit asks InputUI to present the shared
    // keyboard.  This avoids the late scene-activation event after unlock.
    SCFWriteSpotlightState(YES);
    BOOL result = %orig;
    if (!result) SCFWriteSpotlightState(NO);
    return result;
}

- (BOOL)resignFirstResponder {
    BOOL result = %orig;
    if (result) SCFWriteSpotlightState(NO);
    return result;
}

%end

%end

%group SCFInputUIHooks

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
    if (opaque && SCFViewIsCandidateSurface(self) && SCFSpotlightIsForeground()) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window || !SCFViewClassIsCandidateContainer(self)) return;
    SCFApplyToCandidateSurface(self);
}

- (void)layoutSubviews {
    %orig;
    if (!self.window || self.hidden || self.alpha < 0.01) return;
    if (!SCFViewClassIsCandidateContainer(self)) return;
    if (!SCFSpotlightIsForeground()) return;
    if (gSCFLastLayoutRepairGeneration == gSCFStateGeneration) return;
    gSCFLastLayoutRepairGeneration = gSCFStateGeneration;
    SCFApplyToCandidateSurface(self);
}

%end

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    if (gSCFInternalRepairDepth > 0) {
        %orig;
        return;
    }
    if (effect && SCFViewIsCandidateSurface(self) && SCFSpotlightIsForeground()) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

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
    gSCFIsInputUIProcess = strcmp(name, "InputUI") == 0;
    if (gSCFIsInputUIProcess) {
        %init(SCFInputUIHooks);
    }
    if (gSCFIsSpotlightProcess) {
        %init(SCFSpotlightHooks);
        dispatch_async(dispatch_get_main_queue(), ^{
            SCFInstallSpotlightStateObservers();
        });
    }
}
