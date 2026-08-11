#import <UIKit/UIKit.h>

// Temporary isolation build. The hook points are present, but every method
// only forwards to the original implementation. No view tree is inspected
// and no colour/effect is changed.
%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    %orig;
}

- (void)setOpaque:(BOOL)opaque {
    %orig;
}

- (void)didMoveToWindow {
    %orig;
}

- (void)layoutSubviews {
    %orig;
}

%end

%hook UIVisualEffectView

- (void)setEffect:(UIVisualEffect *)effect {
    %orig;
}

%end
