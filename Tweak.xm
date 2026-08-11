#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <ctype.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <sys/syslimits.h>

// Diagnostic only: no view, layer, colour, or effect is ever changed here.
static BOOL gSCFIsInputUI = NO;
static FILE *gSCFTrace = NULL;
static char gSCFSeenClasses[256][160];
static size_t gSCFSeenCount = 0;

static BOOL SCFContainsInsensitive(const char *text, const char *needle) {
    if (!text || !needle || !*needle) return NO;
    size_t length = strlen(needle);
    for (const char *start = text; *start; start++) {
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

static BOOL SCFRelevantClass(const char *name) {
    static const char *const words[] = {
        "candidate", "prediction", "suggestion", "completion", "correction",
        "keyboard", "keyplane", "input", "backdrop", "material", "dock",
        "remote", "effect", "textinput"
    };
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
        if (SCFContainsInsensitive(name, words[i])) return YES;
    }
    return NO;
}

static void SCFOpenTraceIfNeeded(void) {
    if (!gSCFIsInputUI || gSCFTrace) return;
    // NSTemporaryDirectory is inside InputUI's own sandbox and is writable.
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"SpotlightCandidateFix-inputui-trace.txt"];
    gSCFTrace = fopen(path.fileSystemRepresentation, "w");
    if (gSCFTrace) {
        fprintf(gSCFTrace, "PROCESS:InputUI\nPATH:%s\n", path.fileSystemRepresentation);
        fflush(gSCFTrace);
    }
}

static BOOL SCFAlreadyLogged(const char *name) {
    for (size_t i = 0; i < gSCFSeenCount; i++) {
        if (strcmp(gSCFSeenClasses[i], name) == 0) return YES;
    }
    if (gSCFSeenCount >= sizeof(gSCFSeenClasses) / sizeof(gSCFSeenClasses[0])) return YES;
    snprintf(gSCFSeenClasses[gSCFSeenCount], sizeof(gSCFSeenClasses[0]), "%s", name);
    gSCFSeenCount++;
    return NO;
}

static void SCFTraceView(UIView *view) {
    SCFOpenTraceIfNeeded();
    if (!gSCFTrace || !view) return;
    const char *name = SCFClassName(view);
    if (!SCFRelevantClass(name) || SCFAlreadyLogged(name)) return;
    CGRect frame = view.frame;
    fprintf(gSCFTrace, "CLASS:%s FRAME:%.1f,%.1f %.1fx%.1f SUBVIEWS:%lu\n",
            name, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            (unsigned long)view.subviews.count);
    fflush(gSCFTrace);
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

%ctor {
    // Keep dylib initialization C-only; system processes are not fully ready yet.
    char executablePath[PATH_MAX] = {0};
    uint32_t pathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &pathSize) != 0) return;
    const char *name = strrchr(executablePath, '/');
    name = name ? name + 1 : executablePath;
    gSCFIsInputUI = strcmp(name, "InputUI") == 0;
    if (gSCFIsInputUI) {
        // Run after process startup, not inside dyld initialization.  InputUI
        // may render through remote layers and never invoke UIView callbacks.
        dispatch_async(dispatch_get_main_queue(), ^{
            SCFOpenTraceIfNeeded();
        });
    }
}
