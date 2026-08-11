#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// InputUI-only diagnostic. It never changes a view, layer, colour, or effect.
static int gSCFTraceFD = -1;
static const void *gSCFSeen[1024];
static size_t gSCFSeenCount = 0;

static BOOL SCFContains(const char *value, const char *needle) {
    return value && needle && strstr(value, needle) != NULL;
}

static const char *SCFName(id object) {
    Class cls = object ? object_getClass(object) : Nil;
    return cls ? class_getName(cls) : "";
}

static BOOL SCFRelevant(UIView *view) {
    const char *name = SCFName(view);
    static const char *const keys[] = {
        "keyboard", "inputset", "candidate", "prediction", "suggestion",
        "backdrop", "material", "dock", "remote", "host", "effect"
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (SCFContains(name, keys[i])) return YES;
    }
    return NO;
}

static void SCFWrite(const char *format, ...) {
    if (gSCFTraceFD < 0) return;
    char line[1600];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (length > 0) write(gSCFTraceFD, line, (size_t)length);
}

static void SCFTraceTree(UIView *view, NSUInteger depth) {
    if (gSCFTraceFD < 0 || !view || depth > 16 || gSCFSeenCount >= 1024) return;
    const void *pointer = (__bridge const void *)view;
    for (size_t i = 0; i < gSCFSeenCount; i++) if (gSCFSeen[i] == pointer) return;
    gSCFSeen[gSCFSeenCount++] = pointer;

    CGRect frame = view.frame;
    UIColor *color = view.backgroundColor;
    CGFloat white = 0.0, alpha = 0.0;
    CGFloat red = 0.0, green = 0.0, blue = 0.0;
    BOOL hasWhite = [color getWhite:&white alpha:&alpha];
    BOOL hasRGB = [color getRed:&red green:&green blue:&blue alpha:&alpha];
    SCFWrite("DEPTH:%lu CLASS:%s FRAME:%.1f,%.1f %.1fx%.1f BG:%s %.2f %.2f %.2f %.2f OPAQUE:%s LAYER:%s SUBVIEWS:%lu\n",
             (unsigned long)depth, SCFName(view), frame.origin.x, frame.origin.y,
             frame.size.width, frame.size.height,
             hasWhite ? "white" : (hasRGB ? "rgb" : "other"),
             hasWhite ? white : red, hasRGB ? green : alpha, hasRGB ? blue : 0.0, alpha,
             view.opaque ? "YES" : "NO", SCFName(view.layer),
             (unsigned long)view.subviews.count);
    for (UIView *subview in view.subviews) SCFTraceTree(subview, depth + 1);
}

static void SCFTraceView(UIView *view) {
    if (gSCFTraceFD < 0 || !view || !view.window) return;
    UIView *root = view;
    for (NSUInteger depth = 0; root.superview && depth < 20; depth++) {
        if (SCFContains(SCFName(root), "UIInputSetHostView") ||
            SCFContains(SCFName(root), "UIRemoteKeyboardWindow")) break;
        root = root.superview;
    }
    if (!SCFRelevant(view) && !SCFRelevant(root)) return;
    SCFWrite("--- TRACE ROOT ---\n");
    SCFTraceTree(root, 0);
    SCFWrite("--- END TRACE ---\n");
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
    mkdir("/var/mobile/Media/SpotlightCandidateFix", 0755);
    gSCFTraceFD = open("/var/mobile/Media/SpotlightCandidateFix/inputui-trace.txt",
                       O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (gSCFTraceFD >= 0) {
        SCFWrite("PROCESS:%s BUNDLE:%s\n",
                 NSProcessInfo.processInfo.processName.UTF8String ?: "",
                 NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "");
    }
}
