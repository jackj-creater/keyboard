#import <UIKit/UIKit.h>

// Temporary isolation build. This file intentionally installs no hooks and
// changes no UIKit state. Use it only to verify that the dylib can load
// without RootHide entering safe mode.
%ctor {
    @autoreleasepool {
        // Deliberately empty.
    }
}
