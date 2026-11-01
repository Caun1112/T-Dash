// Copyright 2026 T-Dash contributors. SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
extern void TDashStart(void);
__attribute__((constructor)) static void TDashLoad(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.autonavi.amap"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ TDashStart(); });
    }
}
