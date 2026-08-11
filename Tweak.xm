#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static BOOL SCFSpotlightIsActive(void) {
    int fd = open("/var/mobile/Media/SpotlightCandidateFix/spotlight-active", O_RDONLY);
    if (fd < 0) return NO;
    char value[64] = {0};
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return NO;
    int active = 0;
    int pid = 0;
    if (sscanf(value, "%d %d", &active, &pid) != 2 || !active || pid <= 0) return NO;
    int result = kill((pid_t)pid, 0);
    return result == 0 || errno == EPERM;
}

static BOOL SCFIsCandidateBackground(UIView *view) {
    const char *name = class_getName(object_getClass(view));
    if (!name) return NO;
    return strstr(name, "UIKBBackdropView") != NULL ||
           strstr(name, "UIKBInputBackdropView") != NULL ||
           strstr(name, "UIKeyboardDockView") != NULL;
}

static void SCFApplyMinimalBackground(UIView *view) {
    if (!SCFSpotlightIsActive() || !SCFIsCandidateBackground(view)) return;
    view.backgroundColor = UIColor.clearColor;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    SCFApplyMinimalBackground(self);
}

- (void)layoutSubviews {
    %orig;
    SCFApplyMinimalBackground(self);
}

%end
