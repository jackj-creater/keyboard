#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syslimits.h>
#include <sys/time.h>
#include <unistd.h>

// Restores the old, proven candidate-tree repair.  The important change is
// scope: a short-lived foreground heartbeat replaces the old "process alive"
// test, because Spotlight remains alive after App Library is opened.
static const NSInteger kSCFBackgroundMode = 0;
static const CGFloat kSCFBlackAlpha = 0.30;
static const long long kSCFHeartbeatLifetimeMs = 1100;
static const char *const kSCFStatePath =
    "/var/mobile/Media/SpotlightCandidateFix/spotlight-active";

static BOOL gSCFIsSpotlightProcess = NO;
static CFTimeInterval gSCFLastHeartbeatWrite = 0.0;
static CFTimeInterval gSCFLastHeartbeatRead = 0.0;
static BOOL gSCFCachedSpotlightActive = NO;

static long long SCFNowMilliseconds(void) {
    struct timeval value;
    gettimeofday(&value, NULL);
    return (long long)value.tv_sec * 1000LL + value.tv_usec / 1000LL;
}

static void SCFWriteHeartbeat(void) {
    if (!gSCFIsSpotlightProcess) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastHeartbeatWrite < 0.20) return;
    gSCFLastHeartbeatWrite = now;

    mkdir("/var/mobile/Media/SpotlightCandidateFix", 0755);
    int fd = open(kSCFStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char value[64];
    int length = snprintf(value, sizeof(value), "%lld\n", SCFNowMilliseconds());
    if (length > 0) write(fd, value, (size_t)length);
    close(fd);
}

static BOOL SCFSpotlightViewIsForeground(UIView *view) {
    if (!gSCFIsSpotlightProcess || !view.window || view.hidden || view.alpha < 0.01) return NO;
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) return NO;
    UIWindowScene *scene = view.window.windowScene;
    return !scene || scene.activationState == UISceneActivationStateForegroundActive;
}

static void SCFRefreshHeartbeatForView(UIView *view) {
    if (SCFSpotlightViewIsForeground(view)) SCFWriteHeartbeat();
}

static BOOL SCFSpotlightIsActive(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastHeartbeatRead < 0.05) return gSCFCachedSpotlightActive;
    gSCFLastHeartbeatRead = now;

    int fd = open(kSCFStatePath, O_RDONLY);
    if (fd < 0) {
        gSCFCachedSpotlightActive = NO;
        return NO;
    }
    char value[64] = {0};
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) {
        gSCFCachedSpotlightActive = NO;
        return NO;
    }
    long long heartbeat = 0;
    if (sscanf(value, "%lld", &heartbeat) != 1) {
        gSCFCachedSpotlightActive = NO;
        return NO;
    }
    long long age = SCFNowMilliseconds() - heartbeat;
    gSCFCachedSpotlightActive = age >= 0 && age <= kSCFHeartbeatLifetimeMs;
    return gSCFCachedSpotlightActive;
}

static BOOL SCFContainsInsensitive(const char *value, const char *needle) {
    if (!value || !needle || !*needle) return NO;
    size_t length = strlen(needle);
    for (const char *start = value; *start; start++) {
        size_t index = 0;
        while (index < length && start[index] &&
               tolower((unsigned char)start[index]) ==
               tolower((unsigned char)needle[index])) index++;
        if (index == length) return YES;
    }
    return NO;
}

static const char *SCFClassName(id object) {
    Class cls = object ? object_getClass(object) : Nil;
    return cls ? class_getName(cls) : "";
}

static BOOL SCFClassContainsAny(id object,
                                const char *const *words,
                                size_t count) {
    const char *name = SCFClassName(object);
    for (size_t i = 0; i < count; i++) {
        if (SCFContainsInsensitive(name, words[i])) return YES;
    }
    return NO;
}

static const char *const kSCFCandidateWords[] = {
    "candidate", "prediction", "completion", "suggestion",
    "autocorrection", "alternative", "proactive", "inline",
    "uikbbackdrop", "uikbinputbackdrop", "inputsethost", "keyboarddock"
};

static BOOL SCFViewIsCandidateSurface(UIView *view) {
    for (UIView *current = view; current; current = current.superview) {
        if (SCFClassContainsAny(current,
                               kSCFCandidateWords,
                               sizeof(kSCFCandidateWords) / sizeof(kSCFCandidateWords[0]))) {
            return YES;
        }
    }
    return NO;
}

static BOOL SCFFrameCanBeCandidateSurface(UIView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 8.0 || height < 8.0) return NO;
    return height < CGRectGetHeight(UIScreen.mainScreen.bounds) * 0.70;
}

static BOOL SCFColorLooksDark(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    if (@available(iOS 13.0, *)) color = [color resolvedColorWithTraitCollection:traits];
    CGFloat white = 0.0, alpha = 0.0;
    if ([color getWhite:&white alpha:&alpha]) return alpha > 0.05 && white < 0.22;
    CGFloat red = 0.0, green = 0.0, blue = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return NO;
    CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    return alpha > 0.05 && luminance < 0.22;
}

static UIColor *SCFTargetColor(void) {
    if (kSCFBackgroundMode == 1) return [UIColor colorWithWhite:0.0 alpha:kSCFBlackAlpha];
    if (kSCFBackgroundMode == 2) return UIColor.blackColor;
    return UIColor.clearColor;
}

static BOOL SCFClassLooksLikeBackground(UIView *view) {
    static const char *const words[] = {
        "background", "backdrop", "material", "platter", "blur", "effect", "overlay"
    };
    return SCFClassContainsAny(view, words, sizeof(words) / sizeof(words[0]));
}

static BOOL SCFColorsEqual(UIColor *first, UIColor *second, UITraitCollection *traits) {
    if (!first || !second) return first == second;
    if (@available(iOS 13.0, *)) {
        first = [first resolvedColorWithTraitCollection:traits];
        second = [second resolvedColorWithTraitCollection:traits];
    }
    return CGColorEqualToColor(first.CGColor, second.CGColor);
}

static NSUInteger SCFRepairGradient(CALayer *layer, UIColor *target) {
    if (![layer isKindOfClass:CAGradientLayer.class]) return 0;
    CAGradientLayer *gradient = (CAGradientLayer *)layer;
    if (gradient.colors.count == 0) return 0;
    BOOL dark = NO;
    for (id value in gradient.colors) {
        CGColorRef colorRef = (__bridge CGColorRef)value;
        if (colorRef && CFGetTypeID(colorRef) == CGColorGetTypeID() &&
            SCFColorLooksDark([UIColor colorWithCGColor:colorRef], UIScreen.mainScreen.traitCollection)) {
            dark = YES;
            break;
        }
    }
    if (!dark) return 0;
    NSMutableArray *replacement = [NSMutableArray arrayWithCapacity:gradient.colors.count];
    for (NSUInteger i = 0; i < gradient.colors.count; i++) {
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
                  SCFContainsInsensitive(SCFClassName(view), "cell");
    BOOL isBackground = SCFClassLooksLikeBackground(view);
    BOOL isSurface = SCFViewIsCandidateSurface(view);
    NSUInteger changes = 0;

    if (!isCell) {
        UIColor *background = view.backgroundColor;
        if ((isSurface || isBackground || SCFColorLooksDark(background, view.traitCollection)) &&
            !SCFColorsEqual(background, target, view.traitCollection)) {
            view.backgroundColor = target;
            changes++;
        }
        if (view.layer.backgroundColor &&
            (isSurface || isBackground ||
             SCFColorLooksDark([UIColor colorWithCGColor:view.layer.backgroundColor], view.traitCollection)) &&
            !CGColorEqualToColor(view.layer.backgroundColor, target.CGColor)) {
            view.layer.backgroundColor = target.CGColor;
            changes++;
        }
        if ([view isKindOfClass:UIVisualEffectView.class] && ((UIVisualEffectView *)view).effect) {
            ((UIVisualEffectView *)view).effect = nil;
            changes++;
        }
        changes += SCFRepairGradient(view.layer, target);
        view.opaque = (kSCFBackgroundMode == 2);
    }

    for (UIView *subview in view.subviews) {
        changes += SCFRepairCandidateTree(subview, target, depth + 1);
    }
    return changes;
}

static void SCFApplyToCandidateSurface(UIView *view) {
    if (!SCFSpotlightIsActive() || !view.window || !SCFViewIsCandidateSurface(view)) return;
    if (!SCFFrameCanBeCandidateSurface(view)) return;
    SCFRepairCandidateTree(view, SCFTargetColor(), 0);
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (gSCFIsSpotlightProcess) {
        SCFRefreshHeartbeatForView(self);
        return;
    }
    if (!self.window || !SCFViewIsCandidateSurface(self)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ SCFApplyToCandidateSurface(self); });
}

- (void)layoutSubviews {
    %orig;
    if (gSCFIsSpotlightProcess) {
        SCFRefreshHeartbeatForView(self);
        return;
    }
    if (SCFViewIsCandidateSurface(self)) SCFApplyToCandidateSurface(self);
}

%end


%ctor {
    // System processes can crash if NSBundle/NSString is messaged during dyld init.
    char executablePath[PATH_MAX] = {0};
    uint32_t pathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &pathSize) != 0) return;
    const char *name = strrchr(executablePath, '/');
    name = name ? name + 1 : executablePath;
    gSCFIsSpotlightProcess = strcmp(name, "Spotlight") == 0;
}
