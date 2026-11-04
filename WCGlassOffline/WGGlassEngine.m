#import "WGGlassEngine.h"
#import "WGSettings.h"
#import <QuartzCore/QuartzCore.h>

static const NSInteger WGGlassTag = 0x574747;

static BOOL WGIsTabBar(UIView *view) {
    return [view isKindOfClass:[UITabBar class]];
}

void WGApplyGlassEffect(UIView *view) {
    if (!view || !view.window || CGRectIsEmpty(view.bounds)) return;

    UIVisualEffectView *blur = (UIVisualEffectView *)[view viewWithTag:WGGlassTag];
    if (!blur) {
        blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        blur.tag = WGGlassTag;
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // Put the tab bar blur above its private background, below the tab buttons.
        if (WGIsTabBar(view) && view.subviews.count > 0) {
            [view insertSubview:blur atIndex:1];
        } else {
            [view insertSubview:blur atIndex:0];
        }
    }

    blur.frame = view.bounds;
    blur.alpha = WGBlurOpacity();

    CAGradientLayer *shine = nil;
    for (CALayer *layer in blur.layer.sublayers) {
        if ([layer.name isEqualToString:@"WCGlassOffline.Highlight"]) {
            shine = (CAGradientLayer *)layer;
            break;
        }
    }
    if (!shine) {
        shine = [CAGradientLayer layer];
        shine.name = @"WCGlassOffline.Highlight";
        shine.colors = @[
            (id)[UIColor colorWithWhite:1 alpha:WGHighlightOpacity()].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.015].CGColor
        ];
        shine.startPoint = CGPointMake(0.5, 0);
        shine.endPoint = CGPointMake(0.5, 1);
        [blur.layer addSublayer:shine];
    }
    shine.frame = blur.bounds;
}