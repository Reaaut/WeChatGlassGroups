#import <UIKit/UIKit.h>
#import "WGGlassEngine.h"
#import "WGSettings.h"

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
%end

%hook UITabBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
%end
