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

    // InputUI owns the shared candidate views.  A check token lets it notice
    // Spotlight's foreground event before the first candidate-layout frame,
    // without a callback, a timer, or a view-tree scan.
    if (gSCFIsInputUIProcess) {
        int changed = 0;
        if (notify_check(gSCFStateToken, &changed) == NOTIFY_STATUS_OK && changed) {
            gSCFLastStateCheck = 0.0;
        }
    }

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

static BOOL SCFViewIsStrictCandidateSurface(UIView *view) {
    static const char *const strictKeywords[] = {
        "candidate", "prediction", "completion", "suggestion",
        "autocorrection", "alternative", "proactive", "inline"
    };
    return view && SCFViewOrAncestorMatches(
        view,
        strictKeywords,
        sizeof(strictKeywords) / sizeof(strictKeywords[0]),
        12);
}

static BOOL SCFButtonLooksLikeCandidateToggle(UIButton *button) {
    if (!button || !button.window || !SCFViewIsStrictCandidateSurface(button)) return NO;
    if ([button titleForState:UIControlStateNormal].length > 0) return NO;

    // UIKeyboard creates the toggle before assigning its chevron image on
    // the first presentation. Requiring currentImage here makes the initial
    // Spotlight pull-down miss the button; after one expand/collapse cycle
    // the image exists and the same button starts matching. Candidate cells
    // are not UIButtons, so an untitled compact button in the strict candidate
    // hierarchy is the stable early-life identity we need.
    if (SCFCStringContainsInsensitive(SCFClassName(button), "log")) return NO;

    CGFloat width = CGRectGetWidth(button.bounds);
    CGFloat height = CGRectGetHeight(button.bounds);
    if (width < 20.0 || height < 20.0 || width > 110.0 || height > 110.0) return NO;
    CGFloat ratio = width / height;
    if (ratio < 0.45 || ratio > 2.20) return NO;

    return YES;
}

static UIButton *SCFCandidateToggleForView(UIView *view) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth <= 5; depth++) {
        if ([current isKindOfClass:UIButton.class] &&
            SCFButtonLooksLikeCandidateToggle((UIButton *)current)) {
            return (UIButton *)current;
        }
        current = current.superview;
    }
    return nil;
}

static UIView *SCFCandidateToggleRepairRoot(UIButton *button) {
    UIView *root = button;
    CGFloat buttonWidth = CGRectGetWidth(button.bounds);
    CGFloat buttonHeight = CGRectGetHeight(button.bounds);

    // The black/grey material can live in a same-sized wrapper around the
    // UIButton on its first presentation. Include only compact wrappers that
    // closely match the verified toggle; never climb into the full candidate
    // bar or the expanded candidate grid.
    for (NSUInteger depth = 0; root.superview && depth < 3; depth++) {
        UIView *parent = root.superview;
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        if (!SCFViewIsStrictCandidateSurface(parent)) break;
        if (width < 16.0 || height < 16.0 || width > 120.0 || height > 120.0) break;
        if (width > buttonWidth * 1.65 || height > buttonHeight * 1.65) break;
        root = parent;
    }
    return root;
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
    if (!SCFSpotlightIsForeground()) return;
    UIButton *button = SCFCandidateToggleForView(view);
    if (!button || !SCFFrameCanBeCandidateSurface(button)) return;
    UIView *root = SCFCandidateToggleRepairRoot(button);

    UIColor *target = SCFTargetColor();
    gSCFInternalRepairDepth++;
    SCFRepairCandidateTree(root, target, 0);
    gSCFInternalRepairDepth--;
}

static char kSCFRepairScheduledKey;

static void SCFScheduleCandidateToggleRepair(UIButton *button) {
    if (!SCFButtonLooksLikeCandidateToggle(button)) return;
    if ([objc_getAssociatedObject(button, &kSCFRepairScheduledKey) boolValue]) return;

    objc_setAssociatedObject(button, &kSCFRepairScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIButton *weakButton = button;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *strongButton = weakButton;
        if (strongButton && strongButton.window &&
            SCFButtonLooksLikeCandidateToggle(strongButton)) {
            // Keep the coalescing marker set while repairing so any layout
            // caused by the colour change cannot enqueue a repair loop.
            SCFApplyToCandidateSurface(strongButton);
        }
        if (strongButton) {
            objc_setAssociatedObject(strongButton, &kSCFRepairScheduledKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

// UIKit rebuilds parts of the candidate strip after layout.  Repairing it
// only once is therefore not enough: it can put a black colour/effect back
// on the expand button or candidate grid on the following run-loop turn.
// These helpers are deliberately limited to views in a candidate hierarchy;
// regular keyboard keys and every other SpringBoard view are left untouched.
static BOOL SCFShouldSuppressBackground(UIView *view, UIColor *color) {
    return view && color &&
        SCFCandidateToggleForView(view) != nil &&
        SCFSpotlightIsForeground() &&
        SCFColorLooksDark(color, view.traitCollection);
}

#pragma mark - Hook and Spotlight editing state

%hook UIButton

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
    if (opaque && SCFCandidateToggleForView(self) && SCFSpotlightIsForeground()) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (SCFButtonLooksLikeCandidateToggle(self)) {
        SCFApplyToCandidateSurface(self);
        SCFScheduleCandidateToggleRepair(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!self.window || self.hidden || self.alpha < 0.01) return;
    if (SCFButtonLooksLikeCandidateToggle(self)) {
        SCFApplyToCandidateSurface(self);
        SCFScheduleCandidateToggleRepair(self);
    }
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (self.window && SCFButtonLooksLikeCandidateToggle(self)) {
        SCFScheduleCandidateToggleRepair(self);
    }
}

- (void)setImage:(UIImage *)image forState:(UIControlState)state {
    %orig;
    if (self.window && SCFButtonLooksLikeCandidateToggle(self)) {
        SCFScheduleCandidateToggleRepair(self);
    }
}

%end

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    if (gSCFInternalRepairDepth > 0) {
        %orig;
        return;
    }
    if (effect && SCFCandidateToggleForView(self) && SCFSpotlightIsForeground()) {
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
    gSCFIsInputUIProcess = strcmp(name, "InputUI") == 0;
    if (gSCFIsSpotlightProcess) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCFInstallSpotlightStateObservers();
        });
    }
}
