#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Diagnostic build only.  It does not alter any keyboard colours or effects.
// It records the private UIKit class hierarchy that Spotlight creates.

static int gSCFTraceFD = -1;
static char gSCFSeenClasses[160][192];
static size_t gSCFSeenClassCount = 0;

static BOOL SCFContainsInsensitive(const char *value, const char *needle) {
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
    Class cls = object ? object_getClass(object) : Nil;
    return cls ? class_getName(cls) : "";
}

static BOOL SCFIsKeyboardRelatedClass(const char *name) {
    static const char *const keywords[] = {
        "keyboard", "candidate", "prediction", "suggestion", "input",
        "proactive", "completion", "autocorrection", "backdrop", "platter",
        "visualeffect", "material"
    };
    for (size_t index = 0; index < sizeof(keywords) / sizeof(keywords[0]); index++) {
        if (SCFContainsInsensitive(name, keywords[index])) return YES;
    }
    return NO;
}

static BOOL SCFAlreadyLogged(const char *name) {
    for (size_t index = 0; index < gSCFSeenClassCount; index++) {
        if (strcmp(gSCFSeenClasses[index], name) == 0) return YES;
    }
    if (gSCFSeenClassCount >= sizeof(gSCFSeenClasses) / sizeof(gSCFSeenClasses[0])) return YES;
    snprintf(gSCFSeenClasses[gSCFSeenClassCount], sizeof(gSCFSeenClasses[0]), "%s", name);
    gSCFSeenClassCount++;
    return NO;
}

static void SCFTraceView(UIView *view) {
    if (gSCFTraceFD < 0 || !view || !view.window) return;

    const char *name = SCFClassName(view);
    if (!SCFIsKeyboardRelatedClass(name) || SCFAlreadyLogged(name)) return;

    char ancestors[600] = {0};
    size_t offset = 0;
    UIView *ancestor = view.superview;
    for (NSUInteger depth = 0; ancestor && depth < 5; depth++, ancestor = ancestor.superview) {
        const char *ancestorName = SCFClassName(ancestor);
        int written = snprintf(ancestors + offset, sizeof(ancestors) - offset,
                               "%s%s", depth ? " <- " : "", ancestorName);
        if (written <= 0 || (size_t)written >= sizeof(ancestors) - offset) break;
        offset += (size_t)written;
    }

    CGRect frame = view.frame;
    char line[1100];
    int length = snprintf(line, sizeof(line),
                          "CLASS: %s\nFRAME: %.1f,%.1f %.1fx%.1f\nANCESTORS: %s\n\n",
                          name, frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height, ancestors);
    if (length > 0) write(gSCFTraceFD, line, (size_t)length);
}

%ctor {
    mkdir("/var/mobile/Media/SpotlightCandidateFix", 0755);
    gSCFTraceFD = open("/var/mobile/Media/SpotlightCandidateFix/trace.txt",
                       O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (gSCFTraceFD >= 0) {
        const char header[] = "SpotlightCandidateFix diagnostic trace\n\n";
        write(gSCFTraceFD, header, sizeof(header) - 1);
    }
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    SCFTraceView(self);
}

- (void)layoutSubviews {
    %orig;
    SCFTraceView(self);
}

%end
