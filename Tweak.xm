#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// The candidate UI is rendered remotely by InputUI, which does not accept
// RootHide injection on this device.  SpringBoard owns its remote keyboard
// placeholder, so pass a temporary light appearance through that host instead.
static const char *const kSCFSpotlightStatePath =
    "/var/mobile/Media/SpotlightCandidateFix/spotlight-active";
static BOOL gSCFIsSpotlight = NO;
static BOOL gSCFIsSpringBoard = NO;
static CFTimeInterval gSCFLastStateWrite = 0.0;

static void SCFMarkSpotlightVisible(void) {
    if (!gSCFIsSpotlight) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gSCFLastStateWrite < 0.5) return;
    gSCFLastStateWrite = now;

    mkdir("/var/mobile/Media/SpotlightCandidateFix", 0755);
    int fd = open(kSCFSpotlightStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    static const char value[] = "1\n";
    write(fd, value, sizeof(value) - 1);
    close(fd);
}

static BOOL SCFSpotlightWasRecentlyVisible(void) {
    struct stat info;
    if (stat(kSCFSpotlightStatePath, &info) != 0) return NO;
    time_t now = time(NULL);
    return now >= info.st_mtime && now - info.st_mtime <= 3;
}

static BOOL SCFIsRemoteKeyboardHost(UIView *view) {
    const char *name = class_getName(object_getClass(view));
    return name && (!strcmp(name, "UIInputSetHostView") ||
                    !strcmp(name, "_UIRemoteKeyboardPlaceholderView"));
}

static void SCFRefreshKeyboardAppearance(UIView *view) {
    if (!gSCFIsSpringBoard || !SCFIsRemoteKeyboardHost(view)) return;

    UIUserInterfaceStyle desired = SCFSpotlightWasRecentlyVisible()
        ? UIUserInterfaceStyleLight
        : UIUserInterfaceStyleUnspecified;
    if (view.overrideUserInterfaceStyle != desired) {
        view.overrideUserInterfaceStyle = desired;
    }
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (gSCFIsSpotlight && self.window && !self.hidden) {
        SCFMarkSpotlightVisible();
    }
    SCFRefreshKeyboardAppearance(self);
}

- (void)layoutSubviews {
    %orig;
    if (gSCFIsSpotlight && self.window && !self.hidden) {
        SCFMarkSpotlightVisible();
    }
    SCFRefreshKeyboardAppearance(self);
}

%end

%ctor {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    gSCFIsSpotlight = [bundleID isEqualToString:@"com.apple.Spotlight"];
    gSCFIsSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
}
