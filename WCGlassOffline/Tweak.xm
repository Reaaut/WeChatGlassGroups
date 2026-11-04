#import <UIKit/UIKit.h>
#import "WGGlassEngine.h"
#import "WGSettings.h"

static NSMutableSet<NSString *> *WGLoggedControllerClasses;

static void WGLogBottomViews(UIView *view, NSUInteger depth, CGFloat cutoff) {
    if (!view || depth > 5 || view.hidden || view.alpha < 0.02) return;
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) return;
    if (CGRectGetMaxY(frame) < cutoff && depth > 0) return;

    NSLog(@"[WCGlassOffline][Hierarchy] %@ frame=%@ subviews=%lu",
          NSStringFromClass(view.class), NSStringFromCGRect(frame),
          (unsigned long)view.subviews.count);

    for (UIView *child in view.subviews) {
        WGLogBottomViews(child, depth + 1, cutoff);
    }
}

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
- (void)layoutSubviews {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
%end

%hook UITabBar
- (void)didMoveToWindow {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
- (void)layoutSubviews {
    %orig;
    if (self.window) WGApplyGlassEffect(self);
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.tencent.xin"]) return;
    if (!WGLoggedControllerClasses) WGLoggedControllerClasses = [NSMutableSet set];
    NSString *name = NSStringFromClass(self.class);
    if ([WGLoggedControllerClasses containsObject:name]) return;
    [WGLoggedControllerClasses addObject:name];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *root = self.view;
        UIWindow *window = root.window;
        if (!window) return;
        CGFloat cutoff = CGRectGetHeight(window.bounds) * 0.62;
        NSLog(@"[WCGlassOffline][Hierarchy] --- bottom view scan: %@ ---", name);
        WGLogBottomViews(root, 0, cutoff);
    });
}
%end
