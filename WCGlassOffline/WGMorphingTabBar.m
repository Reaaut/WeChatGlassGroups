#import "WGMorphingTabBar.h"
#import <QuartzCore/QuartzCore.h>

@interface WGMorphingTabBar ()
@property(nonatomic,strong) UIVisualEffectView *glass;
@property(nonatomic,strong) UIView *pill;
@property(nonatomic,strong) UIStackView *stack;
@property(nonatomic,strong) NSArray<UIButton *> *buttons;
@end

@implementation WGMorphingTabBar

- (instancetype)initWithFrame:(CGRect)frame {
    self=[super initWithFrame:frame];
    if(self){ _selectedIndex=0; [self build]; }
    return self;
}

- (void)build {
    self.backgroundColor=UIColor.clearColor;
    self.glass=[[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    self.glass.translatesAutoresizingMaskIntoConstraints=NO;
    self.glass.userInteractionEnabled=NO;
    self.glass.clipsToBounds=YES;
    self.glass.layer.cornerRadius=25;
    if(@available(iOS 13.0,*)) self.glass.layer.cornerCurve=kCACornerCurveContinuous;
    [self addSubview:self.glass];

    CAGradientLayer *shine=[CAGradientLayer layer];
    shine.name=@"WGTab.Shine";
    shine.colors=@[(id)[UIColor colorWithWhite:1 alpha:0.25].CGColor,
                   (id)[UIColor colorWithWhite:1 alpha:0.04].CGColor,
                   (id)UIColor.clearColor.CGColor];
    shine.locations=@[@0,@0.3,@1];
    shine.startPoint=CGPointMake(.5,0); shine.endPoint=CGPointMake(.5,1);
    [self.glass.layer addSublayer:shine];

    CAShapeLayer *border=[CAShapeLayer layer];
    border.name=@"WGTab.Border"; border.fillColor=UIColor.clearColor.CGColor;
    border.strokeColor=[UIColor colorWithWhite:1 alpha:.28].CGColor;
    border.lineWidth=.7; [self.glass.layer addSublayer:border];

    self.pill=[UIView new];
    self.pill.backgroundColor=[UIColor colorWithWhite:1 alpha:.22];
    self.pill.layer.cornerRadius=19;
    if(@available(iOS 13.0,*)) self.pill.layer.cornerCurve=kCACornerCurveContinuous;
    self.pill.layer.borderWidth=.5;
    self.pill.layer.borderColor=[UIColor colorWithWhite:1 alpha:.3].CGColor;
    [self.glass.contentView addSubview:self.pill];

    self.stack=[UIStackView new];
    self.stack.translatesAutoresizingMaskIntoConstraints=NO;
    self.stack.axis=UILayoutConstraintAxisHorizontal;
    self.stack.alignment=UIStackViewAlignmentFill;
    self.stack.distribution=UIStackViewDistributionFillEqually;
    [self.glass.contentView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.glass.contentView.leadingAnchor constant:5],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.glass.contentView.trailingAnchor constant:-5],
        [self.stack.topAnchor constraintEqualToAnchor:self.glass.contentView.topAnchor constant:4],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.glass.contentView.bottomAnchor constant:-4]
    ]];
    [self buildItems];
}

- (void)buildItems {
    NSArray *titles=@[@"微信",@"通讯录",@"发现",@"我"];
    NSArray *symbols=@[@"message.fill",@"person.2.fill",@"safari.fill",@"person.crop.circle.fill"];
    NSMutableArray *made=[NSMutableArray array];
    for(NSUInteger i=0;i<titles.count;i++){
        UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
        b.tag=i;
        [b setImage:[UIImage systemImageNamed:symbols[i]] forState:UIControlStateNormal];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        b.tintColor=UIColor.labelColor;
        b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        b.titleLabel.textAlignment=NSTextAlignmentCenter;
        b.imageView.contentMode=UIViewContentModeScaleAspectFit;
        b.contentEdgeInsets=UIEdgeInsetsMake(3,2,3,2);
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [self.stack addArrangedSubview:b]; [made addObject:b];
    }
    self.buttons=made;
    [self setSelectedIndex:0];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for(CALayer *l in self.glass.layer.sublayers){
        if([l.name isEqualToString:@"WGTab.Shine"]) l.frame=self.glass.bounds;
        if([l.name isEqualToString:@"WGTab.Border"]){
            l.frame=self.glass.bounds;
            ((CAShapeLayer *)l).path=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.glass.bounds,.5,.5) cornerRadius:25].CGPath;
        }
    }
    [self movePill:NO];
}

- (void)tap:(UIButton *)sender {
    self.selectedIndex=sender.tag;
    if(self.selectionChanged) self.selectionChanged(sender.tag);
}

- (void)setSelectedIndex:(NSInteger)value {
    _selectedIndex=MIN(MAX(0,value),3);
    [self.buttons enumerateObjectsUsingBlock:^(UIButton *b,NSUInteger idx,BOOL *stop){
        BOOL selected=(idx==self.selectedIndex);
        b.alpha=selected?1:.65;
        b.transform=selected?CGAffineTransformMakeScale(1.04,1.04):CGAffineTransformIdentity;
        b.titleLabel.font=[UIFont systemFontOfSize:10 weight:selected?UIFontWeightSemibold:UIFontWeightRegular];
    }];
    [self movePill:YES];
}

- (void)movePill:(BOOL)animated {
    if(self.buttons.count!=4 || CGRectIsEmpty(self.stack.bounds)) return;
    UIButton *target=self.buttons[self.selectedIndex];
    CGRect frame=CGRectInset(target.frame,2,1);
    void(^changes)(void)=^{ self.pill.frame=frame; };
    if(animated) [UIView animateWithDuration:.4 delay:0 usingSpringWithDamping:.76 initialSpringVelocity:.3 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:changes completion:nil];
    else changes();
}
@end
