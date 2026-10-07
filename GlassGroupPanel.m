//
//  GlassGroupPanel.m
//  WeChatGlassGroups
//
//  按效果图（1179x2556 @3x）反推的尺寸，换算成 pt 后写在下面。
//  所有"魔法数字"都标了来源注释，改起来有依据。
//

#import "GlassGroupPanel.h"

NSString *const WGGDefaultsKeyEnabled       = @"WGG.enabled";
NSString *const WGGDefaultsKeyBlurAlpha     = @"WGG.blurAlpha";
NSString *const WGGDefaultsKeyCornerRadius  = @"WGG.cornerRadius";
NSString *const WGGDefaultsKeySelectedGroup = @"WGG.selectedGroup";
NSString *const WGGDefaultsKeyGroupMap      = @"WGG.groupMap";

// ---- 从效果图量出来的尺寸（@3x 像素 ÷ 3 = pt）----
static const CGFloat kSidePadding   = 20.0;  // 左右留白：60px
static const CGFloat kHeroWidth     = 178.0; // 左侧大图宽：535px
static const CGFloat kHeroGap       = 12.0;  // 大图与右侧卡片间距：35px
static const CGFloat kHeroRadius    = 20.0;  // 大图圆角
static const CGFloat kCardPadding   = 12.0;  // 右侧卡片内边距
static const CGFloat kAvatarSize    = 52.0;  // 卡片内圆形头像：150px
static const CGFloat kPillHeight    = 72.0;  // 分组按钮高：215px
static const CGFloat kPillSpacing   = 10.0;  // 按钮间距
static const CGFloat kDividerGapTop = 24.0;  // 卡片底 → XXX 的间距
static const CGFloat kDividerGapBot = 16.0;  // XXX → 第一个按钮的间距
static const CGFloat kPillTextLeft  = 32.0;  // 按钮内文字距左边缘（箭头 29pt + 间距）

NSString *WGGGroupName(WGGGroup g) {
    switch (g) {
        case WGGGroupFamily:  return @"Family";
        case WGGGroupChats:   return @"Chats";
        case WGGGroupGroup:   return @"Group";
        case WGGGroupService: return @"Service";
        case WGGGroupAll:     return @"All";
    }
    return @"Chats";
}

WGGGroup WGGGroupFromName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return WGGGroupChats;
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"Family":  @(WGGGroupFamily),
                 @"Chats":   @(WGGGroupChats),
                 @"Group":   @(WGGGroupGroup),
                 @"Service": @(WGGGroupService),
                 @"All":     @(WGGGroupAll) };
    });
    NSNumber *n = map[name];
    return n ? (WGGGroup)n.integerValue : WGGGroupChats;
}

// 统一的玻璃外观：给任何 view 加"白玻璃 + 发丝描边 + 柔和投影"
static void WGGApplyGlassChrome(UIView *v, CGFloat radius) {
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.06f;
    v.layer.shadowRadius = 10.0;
    v.layer.shadowOffset = CGSizeMake(0, 4);
    v.clipsToBounds = NO;   // 投影需要
}

// ---------------------------------------------------------------------------
// 分组按钮：一个整圆角的玻璃胶囊，[›  标题] 靠左排列
// 效果图里箭头在左、文字紧随其后，右边大片留白 —— 和"箭头在最右"的常见做法相反
// ---------------------------------------------------------------------------
@interface WGGPillButton : UIControl
@property (nonatomic, strong) UILabel *titleTextLabel;
@property (nonatomic, strong) UIImageView *chevron;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, assign) BOOL selectedPill;
@end

@implementation WGGPillButton

- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _blur = [[UIVisualEffectView alloc] initWithEffect:
                 [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        _blur.translatesAutoresizingMaskIntoConstraints = NO;
        _blur.userInteractionEnabled = NO;
        _blur.layer.cornerRadius = kPillHeight / 2.0;   // 完全圆角 = 胶囊
        _blur.layer.cornerCurve = kCACornerCurveContinuous;
        _blur.clipsToBounds = YES;
        [self addSubview:_blur];
        WGGApplyGlassChrome(self, kPillHeight / 2.0);

        _chevron = [[UIImageView alloc] init];
        _chevron.translatesAutoresizingMaskIntoConstraints = NO;
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.tintColor = [UIColor tertiaryLabelColor];
        if (@available(iOS 13.0, *)) {
            _chevron.image = [UIImage systemImageNamed:@"chevron.right"
                                     withConfiguration:[UIImageSymbolConfiguration
                                                        configurationWithPointSize:15
                                                        weight:UIImageSymbolWeightSemibold]];
        }

        _titleTextLabel = [[UILabel alloc] init];
        _titleTextLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleTextLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
        _titleTextLabel.textColor = [UIColor labelColor];
        _titleTextLabel.text = title;

        [_blur.contentView addSubview:_chevron];
        [_blur.contentView addSubview:_titleTextLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_blur.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            // 箭头靠左，垂直居中
            [_chevron.leadingAnchor constraintEqualToAnchor:_blur.contentView.leadingAnchor constant:14],
            [_chevron.centerYAnchor constraintEqualToAnchor:_blur.contentView.centerYAnchor],
            [_chevron.widthAnchor constraintEqualToConstant:10],
            [_chevron.heightAnchor constraintEqualToConstant:17],

            // 文字紧跟箭头，与左内边距 kPillTextLeft 对齐（20pt 字号 / 20pt 常规字重）
            [_titleTextLabel.leadingAnchor constraintEqualToAnchor:_blur.contentView.leadingAnchor
                                                          constant:kPillTextLeft],
            [_titleTextLabel.centerYAnchor constraintEqualToAnchor:_blur.contentView.centerYAnchor],
        ]];

        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        [self refreshChromeAnimated:NO];
    }
    return self;
}

- (void)handleTap {
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    // 效果图没有明显选中态，这里给一个很轻的按压缩放，避免"点了没反应"的错觉
    [UIView animateWithDuration:0.10 animations:^{
        self.transform = CGAffineTransformMakeScale(0.985, 0.985);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.16
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }];
}

- (void)setSelectedPill:(BOOL)selectedPill {
    if (_selectedPill == selectedPill) return;
    _selectedPill = selectedPill;
    [self refreshChromeAnimated:YES];
}

- (void)refreshChromeAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        if (self.selectedPill) {
            // 选中：白色更实、描边更亮、标题加粗
            self.blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
            self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:1.0].CGColor;
            self.titleTextLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            self.titleTextLabel.textColor = [UIColor labelColor];
            self.chevron.tintColor = [UIColor secondaryLabelColor];
        } else {
            self.blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
            self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
            self.titleTextLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
            self.titleTextLabel.textColor = [UIColor labelColor];
            self.chevron.tintColor = [UIColor tertiaryLabelColor];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.15 animations:apply];
    } else {
        apply();
    }
}

@end

// ---------------------------------------------------------------------------
// 主面板
// ---------------------------------------------------------------------------
@interface GlassGroupPanel ()
@property (nonatomic, strong) UIView *heroCard;         // 左：大图卡
@property (nonatomic, strong) UIImageView *heroImageView;
@property (nonatomic, strong) UIView *profileCard;      // 右：个人信息卡
@property (nonatomic, strong) UIVisualEffectView *profileBlur;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *slashLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *dividerLabel;    // 那三个 X
@property (nonatomic, strong) NSMutableArray<WGGPillButton *> *pills;
@property (nonatomic, copy) NSArray<NSString *> *groupTitles;
@property (nonatomic, assign) WGGGroup selectedGroup;
@property (nonatomic, assign) CGFloat glassAlpha;
@property (nonatomic, assign) CGFloat cornerRadius;
@end

@implementation GlassGroupPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor clearColor];
        _selectedGroup = WGGGroupChats;
        _glassAlpha = 1.0;
        _cornerRadius = kHeroRadius;
        _groupTitles = @[ @"Family", @"Chats", @"Group", @"Service" ];
        _pills = [NSMutableArray array];

        [self buildHeroAndProfile];
        [self buildDivider];
        [self buildPills];
    }
    return self;
}

// ---------- 上部：左大图 + 右信息卡 ----------
- (void)buildHeroAndProfile {
    _heroCard = [[UIView alloc] init];
    _heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_heroCard];
    WGGApplyGlassChrome(_heroCard, kHeroRadius);

    _heroImageView = [[UIImageView alloc] init];
    _heroImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _heroImageView.contentMode = UIViewContentModeScaleAspectFill;
    _heroImageView.clipsToBounds = YES;
    _heroImageView.layer.cornerRadius = kHeroRadius;
    _heroImageView.layer.cornerCurve = kCACornerCurveContinuous;
    // 效果图是黑白叶子照。素材还没提供，先用灰阶渐变占位，
    // 你之后调用 -setHeroImage: 换成真图即可。
    _heroImageView.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [_heroCard addSubview:_heroImageView];

    _profileCard = [[UIView alloc] init];
    _profileCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_profileCard];
    WGGApplyGlassChrome(_profileCard, kHeroRadius);
    // 效果图里右侧卡片是"白玻璃"而不是普通磨砂，加一层更实的高光
    _profileCard.backgroundColor = [UIColor clearColor];

    _profileBlur = [[UIVisualEffectView alloc] initWithEffect:
                    [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
    _profileBlur.translatesAutoresizingMaskIntoConstraints = NO;
    _profileBlur.layer.cornerRadius = kHeroRadius;
    _profileBlur.layer.cornerCurve = kCACornerCurveContinuous;
    _profileBlur.clipsToBounds = YES;
    _profileBlur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [_profileCard addSubview:_profileBlur];

    _avatarView = [[UIImageView alloc] init];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    _avatarView.layer.cornerRadius = kAvatarSize / 2.0;
    _avatarView.clipsToBounds = YES;
    _avatarView.contentMode = UIViewContentModeScaleAspectFill;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = @"#无趣";

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.text = @"life is but a dream";

    // 效果图里那一行是斜体的 "/"，用的是衬线斜体，不是系统常规字重
    _slashLabel = [[UILabel alloc] init];
    _slashLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIFont *serifItalic = [UIFont fontWithName:@"TimesNewRomanPS-ItalicMT" size:14];
    _slashLabel.font = serifItalic ?: [UIFont systemFontOfSize:14];
    _slashLabel.textColor = [UIColor secondaryLabelColor];
    _slashLabel.textAlignment = NSTextAlignmentCenter;
    _slashLabel.text = @"/";

    _dateLabel = [[UILabel alloc] init];
    _dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIFont *serifItalicSmall = [UIFont fontWithName:@"TimesNewRomanPS-ItalicMT" size:12];
    _dateLabel.font = serifItalicSmall ?: [UIFont monospacedDigitSystemFontOfSize:12
                                                                         weight:UIFontWeightRegular];
    _dateLabel.textColor = [UIColor secondaryLabelColor];
    _dateLabel.textAlignment = NSTextAlignmentCenter;
    _dateLabel.text = @"0920";

    for (UIView *v in @[_avatarView, _titleLabel, _subtitleLabel, _slashLabel, _dateLabel]) {
        [_profileBlur.contentView addSubview:v];
    }

    // 约束
    UILayoutGuide *m = _profileBlur.contentView.layoutMarginsGuide;
    CGFloat cardHalf = kSidePadding + kHeroWidth + kHeroGap;   // 右侧卡片左边缘的 x

    [NSLayoutConstraint activateConstraints:@[
        // 大图卡：固定宽，高由右侧卡片撑开
        [_heroCard.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kSidePadding],
        [_heroCard.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_heroCard.widthAnchor constraintEqualToConstant:kHeroWidth],

        [_heroImageView.topAnchor constraintEqualToAnchor:_heroCard.topAnchor],
        [_heroImageView.bottomAnchor constraintEqualToAnchor:_heroCard.bottomAnchor],
        [_heroImageView.leadingAnchor constraintEqualToAnchor:_heroCard.leadingAnchor],
        [_heroImageView.trailingAnchor constraintEqualToAnchor:_heroCard.trailingAnchor],

        // 信息卡：从大图右侧一直顶到右边距
        [_profileCard.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:cardHalf],
        [_profileCard.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kSidePadding],
        [_profileCard.topAnchor constraintEqualToAnchor:_heroCard.topAnchor],
        [_profileCard.bottomAnchor constraintEqualToAnchor:_heroCard.bottomAnchor],

        [_profileBlur.topAnchor constraintEqualToAnchor:_profileCard.topAnchor],
        [_profileBlur.bottomAnchor constraintEqualToAnchor:_profileCard.bottomAnchor],
        [_profileBlur.leadingAnchor constraintEqualToAnchor:_profileCard.leadingAnchor],
        [_profileBlur.trailingAnchor constraintEqualToAnchor:_profileCard.trailingAnchor],

        // 头像在卡片内水平居中
        [_avatarView.centerXAnchor constraintEqualToAnchor:m.centerXAnchor],
        [_avatarView.topAnchor constraintEqualToAnchor:m.topAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:kAvatarSize],
        [_avatarView.heightAnchor constraintEqualToConstant:kAvatarSize],

        [_titleLabel.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor constant:2],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [_slashLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:10],
        [_slashLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_slashLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [_dateLabel.topAnchor constraintEqualToAnchor:_slashLabel.bottomAnchor constant:2],
        [_dateLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_dateLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        // 卡片高度 = 头像 + 文字链 + 底部内边距（同时决定大图高度 → 两边等高）
        [_dateLabel.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
}

// ---------- 中间那三个 X ----------
- (void)buildDivider {
    _dividerLabel = [[UILabel alloc] init];
    _dividerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dividerLabel.text = @"X X X";
    _dividerLabel.textAlignment = NSTextAlignmentCenter;
    _dividerLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    // 效果图里是很淡的浅灰，不是正文灰
    _dividerLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    [self addSubview:_dividerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_dividerLabel.topAnchor constraintEqualToAnchor:_heroCard.bottomAnchor constant:kDividerGapTop],
        [_dividerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kSidePadding],
        [_dividerLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kSidePadding],
    ]];
}

// ---------- 下部：4 个分组胶囊 ----------
- (void)buildPills {
    UIView *previous = nil;
    for (NSUInteger i = 0; i < self.groupTitles.count; i++) {
        WGGPillButton *pill = [[WGGPillButton alloc] initWithTitle:self.groupTitles[i]];
        pill.tag = (NSInteger)i;
        [pill addTarget:self action:@selector(pillTapped:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:pill];
        [self.pills addObject:pill];

        [NSLayoutConstraint activateConstraints:@[
            [pill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kSidePadding],
            [pill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kSidePadding],
            [pill.heightAnchor constraintEqualToConstant:kPillHeight],
        ]];

        if (previous) {
            [pill.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:kPillSpacing].active = YES;
        } else {
            [pill.topAnchor constraintEqualToAnchor:_dividerLabel.bottomAnchor constant:kDividerGapBot].active = YES;
        }
        previous = pill;
    }
    // 面板底边 = 最后一个胶囊底部
    if (previous) {
        [previous.bottomAnchor constraintEqualToAnchor:self.bottomAnchor].active = YES;
    }
    [self refreshSelectionAppearance];
}

// ---------- 交互 ----------
- (void)pillTapped:(WGGPillButton *)sender {
    WGGGroup g = (WGGGroup)sender.tag;
    if (g == self.selectedGroup) return;
    self.selectedGroup = g;
    [self refreshSelectionAppearance];
    [self persistToDefaults];

    if ([self.delegate respondsToSelector:@selector(glassGroupPanel:didSelectGroup:)]) {
        [self.delegate glassGroupPanel:self didSelectGroup:g];
    }
}

- (void)refreshSelectionAppearance {
    for (WGGPillButton *pill in self.pills) {
        pill.selectedPill = ((WGGGroup)pill.tag == self.selectedGroup);
    }
}

// ---------- 对外 API ----------
- (void)setAvatarImage:(UIImage *)image        { self.avatarView.image = image; }
- (void)setHeroImage:(UIImage *)image          { self.heroImageView.image = image; }

- (void)setTitleText:(NSString *)title subtitle:(NSString *)subtitle date:(NSString *)date {
    if (title)    self.titleLabel.text = title;
    if (subtitle) self.subtitleLabel.text = subtitle;
    if (date)     self.dateLabel.text = date;
}

- (void)setBadgeCounts:(NSDictionary<NSNumber *, NSNumber *> *)counts {
    // 效果图里没有角标位，这里保留接口但不渲染，
    // 等你想加"分组未读数"时再在胶囊右侧补一个 label。
    (void)counts;
}

- (void)setGlassAlpha:(CGFloat)alpha {
    _glassAlpha = MAX(0.0, MIN(1.0, alpha));
    self.profileBlur.alpha = _glassAlpha;
    for (WGGPillButton *p in self.pills) p.blur.alpha = _glassAlpha;
}

- (void)setCornerRadius:(CGFloat)radius {
    _cornerRadius = MAX(0.0, radius);
    self.profileCard.layer.cornerRadius = _cornerRadius;
    self.profileBlur.layer.cornerRadius = _cornerRadius;
    self.heroCard.layer.cornerRadius = _cornerRadius;
    self.heroImageView.layer.cornerRadius = _cornerRadius;
    // 分组胶囊在效果图里是"完全圆角"（高度的一半），不跟随这个值，
    // 否则改圆角会把胶囊变成方角卡片，和设计稿不符。
}

- (void)restoreFromDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSNumber *alpha = [d objectForKey:WGGDefaultsKeyBlurAlpha];
    NSNumber *radius = [d objectForKey:WGGDefaultsKeyCornerRadius];
    NSNumber *sel = [d objectForKey:WGGDefaultsKeySelectedGroup];
    if (alpha) self.glassAlpha = alpha.doubleValue;
    if (radius) self.cornerRadius = radius.doubleValue;
    if (sel) self.selectedGroup = (WGGGroup)sel.integerValue;
    [self refreshSelectionAppearance];
}

- (void)persistToDefaults {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:self.glassAlpha forKey:WGGDefaultsKeyBlurAlpha];
    [d setDouble:self.cornerRadius forKey:WGGDefaultsKeyCornerRadius];
    [d setInteger:self.selectedGroup forKey:WGGDefaultsKeySelectedGroup];
}

@end

#pragma mark - 底部搜索框

@implementation WGGSearchBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                    [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 24.0;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.clipsToBounds = YES;
        blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        [self addSubview:blur];
        WGGApplyGlassChrome(self, 24.0);

        UIImageView *icon = [[UIImageView alloc] init];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = [UIColor labelColor];
        if (@available(iOS 13.0, *)) {
            icon.image = [UIImage systemImageNamed:@"magnifyingglass"
                                 withConfiguration:[UIImageSymbolConfiguration
                                                    configurationWithPointSize:20
                                                    weight:UIImageSymbolWeightRegular]];
        }

        [blur.contentView addSubview:icon];
        [NSLayoutConstraint activateConstraints:@[
            [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [icon.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:26],
            [icon.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:22],
            [icon.heightAnchor constraintEqualToConstant:22],
        ]];
    }
    return self;
}

@end
