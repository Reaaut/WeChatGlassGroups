#import "WGGlassEngine.h"
#import "WGSettings.h"
#import <QuartzCore/QuartzCore.h>

static const NSInteger WGGlassTag = 0x574747;
static NSString * const WGHighlightName = @"WCGlassOffline.Highlight";
static NSString * const WGBorderName = @"WCGlassOffline.Border";

static CAGradientLayer *WGGradient(CALayer *root, NSString *name) {
    for (CALayer *layer in root.sublayers) {
        if ([layer.name isEqualToString:name]) return (CAGradientLayer *)layer;
    }
    return nil;
}

static CAShapeLayer *WGBorder(CALayer *root) {
    for (CALayer *layer in root.sublayers) {
        if ([layer.name isEqualToString:WGBorderName]) return (CAShapeLayer *)layer;
    }
    return nil;
}

static void WGPrepareBar(UIView *view) {
    if ([view isKindOfClass:[UITabBar class]]) {
        UITabBar *bar = (UITabBar *)view;
        bar.translucent = YES;
        bar.backgroundImage = [UIImage new];
        bar.shadowImage = [UIImage new];
        bar.backgroundColor = UIColor.clearColor;
        if (@available(iOS 13.0, *)) {
            UITabBarAppearance *a = [bar.standardAppearance copy];
            [a configureWithTransparentBackground];
            a.backgroundEffect = nil;
            a.backgroundColor = UIColor.clearColor;
            a.shadowColor = UIColor.clearColor;
            bar.standardAppearance = a;
            if (@available(iOS 15.0, *)) bar.scrollEdgeAppearance = a;
        }
    } else if ([view isKindOfClass:[UINavigationBar class]]) {
        UINavigationBar *bar = (UINavigationBar *)view;
        bar.translucent = YES;
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *a = [bar.standardAppearance copy];
            [a configureWithTransparentBackground];
            a.backgroundEffect = nil;
            a.backgroundColor = UIColor.clearColor;
            a.shadowColor = UIColor.clearColor;
            bar.standardAppearance = a;
            bar.scrollEdgeAppearance = a;
        }
    }
}

void WGApplyGlassEffect(UIView *view) {
    if (!view || !view.window || CGRectIsEmpty(view.bounds)) return;
    if (![view isKindOfClass:[UITabBar class]] &&
        ![view isKindOfClass:[UINavigationBar class]]) return;

    WGPrepareBar(view);

    UIVisualEffectView *glass = (UIVisualEffectView *)[view viewWithTag:WGGlassTag];
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        glass.tag = WGGlassTag;
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.clipsToBounds = YES;
        [view insertSubview:glass atIndex:0];
    }
    glass.frame = view.bounds;
    glass.alpha = WGBlurOpacity();

    CAGradientLayer *shine = WGGradient(glass.layer, WGHighlightName);
    if (!shine) {
        shine = [CAGradientLayer layer];
        shine.name = WGHighlightName;
        shine.startPoint = CGPointMake(0.5, 0.0);
        shine.endPoint = CGPointMake(0.5, 1.0);
        [glass.layer addSublayer:shine];
    }
    CGFloat amount = WGHighlightOpacity();
    shine.colors = @[
        (id)[UIColor colorWithWhite:1 alpha:amount].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:amount * 0.15].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0].CGColor
    ];
    shine.locations = @[@0.0, @0.2, @1.0];
    shine.frame = glass.bounds;

    CAShapeLayer *edge = WGBorder(glass.layer);
    if (!edge) {
        edge = [CAShapeLayer layer];
        edge.name = WGBorderName;
        edge.fillColor = UIColor.clearColor.CGColor;
        edge.strokeColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        edge.lineWidth = 0.5;
        [glass.layer addSublayer:edge];
    }
    edge.frame = glass.bounds;
    edge.path = [UIBezierPath bezierPathWithRect:CGRectInset(glass.bounds, 0.25, 0.25)].CGPath;
}
