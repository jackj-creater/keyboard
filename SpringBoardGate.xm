#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// This companion is loaded only in SpringBoard.  It does not touch keyboard
// views; it only tells the shared UIKit keyboard process when Spotlight is
// currently on screen.
static const char *kSCFSpotlightStateDirectory =
    "/var/mobile/Media/SpotlightCandidateFix";
static const char *kSCFSpotlightStatePath =
    "/var/mobile/Media/SpotlightCandidateFix/spotlight-active";
static CFStringRef kSCFSpotlightDidOpenNotification =
    CFSTR("com.keyboard.spotlightcandidatefix.spotlight-open");
static CFStringRef kSCFSpotlightDidCloseNotification =
    CFSTR("com.keyboard.spotlightcandidatefix.spotlight-close");
static BOOL gSCFBackdropVisible = NO;
static BOOL gSCFControllerVisible = NO;
static BOOL gSCFLastPublishedState = NO;

static void SCFSetSpotlightActive(BOOL active) {
    if (active == gSCFLastPublishedState) return;
    gSCFLastPublishedState = active;
    mkdir(kSCFSpotlightStateDirectory, 0755);
    int fd = open(kSCFSpotlightStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char value = active ? '1' : '0';
        write(fd, &value, sizeof(value));
        close(fd);
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        active ? kSCFSpotlightDidOpenNotification : kSCFSpotlightDidCloseNotification,
        NULL, NULL, true);
}

static void SCFUpdateSpotlightState(void) {
    SCFSetSpotlightActive(gSCFBackdropVisible || gSCFControllerVisible);
}

%hook SBSearchBackdropView

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    gSCFBackdropVisible = view.window != nil;
    SCFUpdateSpotlightState();
}

- (void)removeFromSuperview {
    %orig;
    gSCFBackdropVisible = NO;
    SCFUpdateSpotlightState();
}

%end

%hook SBSearchViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gSCFControllerVisible = YES;
    SCFUpdateSpotlightState();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gSCFControllerVisible = NO;
    SCFUpdateSpotlightState();
}

%end

%ctor {
    @autoreleasepool {
        gSCFBackdropVisible = NO;
        gSCFControllerVisible = NO;
        gSCFLastPublishedState = YES;
        SCFSetSpotlightActive(NO);
    }
}
