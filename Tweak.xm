#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <stdio.h>
#include <string.h>
#include <sys/syslimits.h>
#include <time.h>
#include <unistd.h>

static const char *const kSCFSpotlightStateName =
    "com.keyboard.spotlightcandidatefix.spotlight-visible";
static BOOL gSCFIsSpotlight = NO;
static BOOL gSCFIsInputUI = NO;
static CFTimeInterval gSCFLastStateWrite = 0.0;
static int gSCFStateToken = NOTIFY_TOKEN_INVALID;

static void SCFEnsureStateToken(void) {
    if (gSCFStateToken != NOTIFY_TOKEN_INVALID) return;
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(kSCFSpotlightStateName, &token) == NOTIFY_STATUS_OK) {
        gSCFStateToken = token;
    }
}

static void SCFMarkSpotlightVisible(void) {
    if (!gSCFIsSpotlight) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastStateWrite < 0.5) return;
    gSCFLastStateWrite = now;

    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) return;
    notify_set_state(gSCFStateToken, (uint64_t)time(NULL));
    notify_post(kSCFSpotlightStateName);
}

static BOOL SCFSpotlightWasRecentlyVisible(void) {
    SCFEnsureStateToken();
    if (gSCFStateToken == NOTIFY_TOKEN_INVALID) return NO;
    uint64_t state = 0;
    if (notify_get_state(gSCFStateToken, &state) != NOTIFY_STATUS_OK || state == 0) return NO;
    time_t now = time(NULL);
    return now >= (time_t)state && now - (time_t)state <= 3;
}

static BOOL SCFContainsInsensitive(const char *text, const char *needle) {
    if (!text || !needle || !*needle) return NO;
    size_t needleLength = strlen(needle);
    for (const char *start = text; *start; start++) {
        size_t index = 0;
        while (index < needleLength && start[index] &&
               tolower((unsigned char)start[index]) ==
               tolower((unsigned char)needle[index])) index++;
        if (index == needleLength) return YES;
    }
    return NO;
}

static BOOL SCFCandidateClass(id object) {
    if (!object) return NO;
    const char *name = class_getName(object_getClass(object));
    static const char *const names[] = {
        "candidate", "prediction", "suggestion", "completion",
        "autocorrection", "uikbbackdrop", "uikbinputbackdrop",
        "keyboarddock"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (SCFContainsInsensitive(name, names[i])) return YES;
    }
    return NO;
}

static BOOL SCFIsCandidateSurface(UIView *view) {
    for (UIView *current = view; current; current = current.superview) {
        if (SCFCandidateClass(current)) return YES;
    }
    return NO;
}

static BOOL SCFIsDark(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    if (@available(iOS 13.0, *)) color = [color resolvedColorWithTraitCollection:traits];
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![color getWhite:&white alpha:&alpha]) return NO;
        red = green = blue = white;
    }
    return alpha > 0.05 && (0.2126 * red + 0.7152 * green + 0.0722 * blue) < 0.22;
}

static BOOL SCFEnabledFor(UIView *view) {
    return gSCFIsInputUI && view && SCFIsCandidateSurface(view) &&
           SCFSpotlightWasRecentlyVisible();
}

static void SCFRepairView(UIView *view) {
    if (!SCFEnabledFor(view)) return;
    if (SCFIsDark(view.backgroundColor, view.traitCollection)) {
        view.backgroundColor = UIColor.clearColor;
    }
    if (view.layer.backgroundColor) {
        UIColor *layerColor = [UIColor colorWithCGColor:view.layer.backgroundColor];
        if (SCFIsDark(layerColor, view.traitCollection)) {
            view.layer.backgroundColor = UIColor.clearColor.CGColor;
        }
    }
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        ((UIVisualEffectView *)view).effect = nil;
    }
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (gSCFIsSpotlight && self.window && !self.hidden) SCFMarkSpotlightVisible();
    SCFRepairView(self);
}

- (void)layoutSubviews {
    %orig;
    if (gSCFIsSpotlight && self.window && !self.hidden) SCFMarkSpotlightVisible();
    SCFRepairView(self);
}

- (void)setBackgroundColor:(UIColor *)color {
    if (SCFEnabledFor(self) && SCFIsDark(color, self.traitCollection)) {
        %orig(UIColor.clearColor);
        return;
    }
    %orig;
}

%end

%ctor {
    // No Objective-C messages during dyld initialization.
    char executablePath[PATH_MAX] = {0};
    uint32_t pathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &pathSize) != 0) return;
    const char *name = strrchr(executablePath, '/');
    name = name ? name + 1 : executablePath;
    gSCFIsSpotlight = strcmp(name, "Spotlight") == 0;
    gSCFIsInputUI = strcmp(name, "InputUI") == 0;
}
