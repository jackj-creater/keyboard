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

static BOOL SCFIsCandidateContext(UIView *view) {
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth < 10; depth++, current = current.superview) {
        const char *name = class_getName(object_getClass(current));
        if (!name) continue;
        if (strstr(name, "UIKBBackdropView") ||
            strstr(name, "UIKBInputBackdropView") ||
            strstr(name, "UIInputSetHostView") ||
            strstr(name, "UIKeyboardDockView")) return YES;
    }
    return NO;
}

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    if (SCFSpotlightIsActive() && SCFIsCandidateContext(self) && effect) {
        %orig(nil);
        return;
    }
    %orig;
}

%end
