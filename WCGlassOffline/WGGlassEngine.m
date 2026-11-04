#import "WGGlassEngine.h"
#import "WGSettings.h"
#import <QuartzCore/QuartzCore.h>

static const NSInteger WGGlassTag = 0x574747;

void WGApplyGlassEffect(UIView *view) {
    if (!view || [view viewWithTag:WGGlassTag]) return;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blur.tag = WGGlassTag;
    blur.userInteractionEnabled = NO;
    blur.frame = view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = WGBlurOpacity();
    [view insertSubview:blur atIndex:0];

    CAGradientLayer *shine = [CAGradientLayer layer];
    shine.frame = blur.bounds;
    shine.colors = @[
        (id)[UIColor colorWithWhite:1 alpha:WGHighlightOpacity()].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0.015].CGColor
    ];
    shine.startPoint = CGPointMake(0.5, 0);
    shine.endPoint = CGPointMake(0.5, 1);
    [blur.layer addSublayer:shine];
}
