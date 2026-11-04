#import <Foundation/Foundation.h>
#import "WGSettings.h"

static NSDictionary *WGDefaults(void) {
    return @{ @"WGBlurOpacity": @0.82, @"WGHighlightOpacity": @0.22 };
}

CGFloat WGBlurOpacity(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSNumber *v = [d objectForKey:@"WGBlurOpacity"];
    return v ? MIN(1.0, MAX(0.0, v.doubleValue)) : [WGDefaults()[@"WGBlurOpacity"] doubleValue];
}

CGFloat WGHighlightOpacity(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSNumber *v = [d objectForKey:@"WGHighlightOpacity"];
    return v ? MIN(1.0, MAX(0.0, v.doubleValue)) : [WGDefaults()[@"WGHighlightOpacity"] doubleValue];
}
