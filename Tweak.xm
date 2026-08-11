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
static const void *gSCFSeenLayers[640];
static size_t gSCFSeenLayerCount = 0;

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

static BOOL SCFAlreadyLoggedLayer(CALayer *layer) {
    const void *pointer = (__bridge const void *)layer;
    for (size_t index = 0; index < gSCFSeenLayerCount; index++) {
        if (gSCFSeenLayers[index] == pointer) return YES;
    }
    if (gSCFSeenLayerCount >= sizeof(gSCFSeenLayers) / sizeof(gSCFSeenLayers[0])) return YES;
    gSCFSeenLayers[gSCFSeenLayerCount++] = pointer;
    return NO;
}

static void SCFTraceLayers(CALayer *layer, NSUInteger depth) {
    if (gSCFTraceFD < 0 || !layer || depth > 10 ||
        gSCFSeenLayerCount >= sizeof(gSCFSeenLayers) / sizeof(gSCFSeenLayers[0])) return;
    if (SCFAlreadyLoggedLayer(layer)) return;

    CGRect frame = layer.frame;
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    BOOL hasRGB = NO;
    if (layer.backgroundColor) {
        UIColor *color = [UIColor colorWithCGColor:layer.backgroundColor];
        hasRGB = [color getRed:&red green:&green blue:&blue alpha:&alpha];
    }
    const char *layerName = layer.name.UTF8String ?: "";
    char line[900];
    int length = snprintf(line, sizeof(line),
                          "LAYER_DEPTH: %lu\nLAYER_CLASS: %s\nLAYER_NAME: %s\nFRAME: %.1f,%.1f %.1fx%.1f\nBG: %s %.2f,%.2f,%.2f,%.2f\nOPAQUE: %s\nSUBLAYERS: %lu\n\n",
                          (unsigned long)depth, SCFClassName(layer), layerName,
                          frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                          hasRGB ? "rgb" : "other", red, green, blue, alpha,
                          layer.opaque ? "YES" : "NO",
                          (unsigned long)layer.sublayers.count);
    if (length > 0) write(gSCFTraceFD, line, (size_t)length);

    NSArray *sublayers = layer.sublayers;
    for (CALayer *sublayer in sublayers) SCFTraceLayers(sublayer, depth + 1);
}

static void SCFTraceView(UIView *view) {
    if (gSCFTraceFD < 0 || !view || !view.window) return;

    const char *name = SCFClassName(view);
    CGRect frame = view.frame;
    if (frame.size.width <= 1.0 || frame.size.height <= 1.0) return;

    BOOL hasKeyboardAncestor = NO;
    UIView *candidateAncestor = view.superview;
    for (NSUInteger depth = 0; candidateAncestor && depth < 14; depth++, candidateAncestor = candidateAncestor.superview) {
        const char *ancestorName = SCFClassName(candidateAncestor);
        if (SCFContainsInsensitive(ancestorName, "keyboard") ||
            SCFContainsInsensitive(ancestorName, "inputset") ||
            SCFContainsInsensitive(ancestorName, "materialview")) {
            hasKeyboardAncestor = YES;
            break;
        }
    }
    if (!SCFIsKeyboardRelatedClass(name) && !hasKeyboardAncestor &&
        !SCFContainsInsensitive(name, "materialview")) return;
    if (SCFAlreadyLogged(name)) return;

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

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    BOOL hasRGB = [view.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha];
    char line[1300];
    int length = snprintf(line, sizeof(line),
                          "CLASS: %s\nFRAME: %.1f,%.1f %.1fx%.1f\nBG: %s %.2f,%.2f,%.2f,%.2f\nOPAQUE: %s\nANCESTORS: %s\n\n",
                          name, frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height,
                          hasRGB ? "rgb" : "other", red, green, blue, alpha,
                          view.opaque ? "YES" : "NO", ancestors);
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
    const char *name = SCFClassName(self);
    if (SCFContainsInsensitive(name, "keyboardlayerhost") ||
        SCFContainsInsensitive(name, "contextlayerhost")) {
        SCFTraceLayers(self.layer, 0);
    }
}

%end
