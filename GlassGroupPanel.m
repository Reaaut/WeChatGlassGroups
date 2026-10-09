//
//  GlassGroupPanel.m
//  WeChatGlassGroups
//
//  【UI 层】实现。布局思路：
//
//   抽屉（悬浮玻璃卡片，不是贴边）
//   ┌──────────────────────────┐
//   │ (avatar)  #无趣           │  ← 头部（紧凑）
//   │           life is ...     │
//   │  ──────────────────────  │
//   │  › All               128 │  ← 分组行（可滚动，动态数量）
//   │  › Family              3 │
//   │  › Chats              12 │
//   │  ...                     │
//   │  ┌────────────────────┐  │
//   │  │ 🔍 搜索会话         │  │  ← 搜索框（可关）
//   │  └────────────────────┘  │
//   └──────────────────────────┘
//
//  所有尺寸常量集中在下面，改样式只改这一处。
//

#import "GlassGroupPanel.h"

// 注意：WGGGroupAllName 这个常量的**定义**放在 GroupStore.m（数据层拥有这个概念），
// 这里只通过头文件里的 extern 声明使用它。
// 千万不要在这里再写一遍定义 —— 两个 .m 各定义一次 = 链接期 duplicate symbol 报错。

// ---- 尺寸 ----
static const CGFloat kDrawerDefaultWidth = 268.0;
static const CGFloat kDrawerEdgeInset    = 8.0;   // 抽屉离屏幕左边/上下的距离（留出投影空间）
static const CGFloat kDrawerRadius       = 28.0;  // 大圆角 = 液态玻璃感
static const CGFloat kRowHeight          = 48.0;
static const CGFloat kRowSpacing         = 8.0;
static const CGFloat kRowRadius          = 16.0;
static const CGFloat kTriggerSize        = 46.0;
static const CGFloat kAvatarSize         = 38.0;
static const CGFloat kSearchHeight       = 40.0;

/// 统一的"液态玻璃"外观：白玻璃 + 发丝描边 + 柔和外阴影。
/// 注意 clipsToBounds = NO 是为了让阴影能画出来；
/// 真正的圆角裁切交给内部的 UIVisualEffectView。
static void WGGApplyGlassChrome(UIView *v, CGFloat radius) {
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.5;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.16f;
    v.layer.shadowRadius = 24.0;
    v.layer.shadowOffset = CGSizeMake(0, 10);
    v.clipsToBounds = NO;
}

/// 配置一个"液态玻璃"模糊层。
///
/// ⚠️ 刻意写成 void 而不是"返回已创建好的 blur"：
///    本工程是 MRC。如果 helper 返回 autorelease 对象、调用方又把结果直接赋给
///    strong 属性的 ivar（不走 setter 就不会 retain），再在 dealloc 里 release，
///    就会多减一次引用 → 野指针崩溃。
///    让调用方自己 alloc（拿到 +1），dealloc 里 release，收支才平衡。
static void WGGConfigureBlur(UIVisualEffectView *blur, CGFloat radius) {
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.layer.cornerRadius = radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
}

/// 创建一个指定材质的模糊层（alloc 版本，返回 +1，调用方负责 release）。
static UIVisualEffectView *WGGCreateBlur(CGFloat radius) {
    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:
         [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
    WGGConfigureBlur(blur, radius);
    return blur;   // +1 交给调用方
}

static UIImage *WGGSymbol(NSString *name, CGFloat size, UIFontWeight weight) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name
                       withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size
                                                                                        weight:weight]];
    }
    return nil;
}

#pragma mark - 分组行

@interface WGGRowView : UIControl
@property (nonatomic, copy)   NSString *groupName;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIImageView *arrowView;   // 分组行前缀箭头（图标可换，设置页里调）
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, assign) BOOL selectedRow;
- (instancetype)initWithGroupName:(NSString *)groupName;
- (void)setBadgeCount:(NSInteger)count;
- (void)setArrowSymbolName:(NSString *)symbolName;
- (void)handleTap;
- (void)refreshAppearanceAnimated:(BOOL)animated;
@end

@implementation WGGRowView

- (instancetype)initWithGroupName:(NSString *)groupName {
    if ((self = [super initWithFrame:CGRectZero])) {
        _groupName = [groupName copy];
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _blur = WGGCreateBlur(kRowRadius);   // +1，dealloc 里 release
        [self addSubview:_blur];
        WGGApplyGlassChrome(self, kRowRadius);
        self.layer.shadowOpacity = 0.05f;
        self.layer.shadowRadius = 8.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.text = groupName;

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _badgeLabel.textColor = [UIColor secondaryLabelColor];
        _badgeLabel.textAlignment = NSTextAlignmentRight;
        _badgeLabel.hidden = YES;

        // 分组行前缀箭头：具体用哪个 SF Symbol 由设置项决定（默认 chevron.right）
        _arrowView = [[UIImageView alloc] init];
        _arrowView.translatesAutoresizingMaskIntoConstraints = NO;
        _arrowView.contentMode = UIViewContentModeScaleAspectFit;
        [self setArrowSymbolName:nil];   // nil → 用默认图标

        for (UIView *v in @[_nameLabel, _badgeLabel, _arrowView]) {
            [_blur.contentView addSubview:v];
        }

        UILayoutGuide *m = _blur.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_blur.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_arrowView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor constant:2],
            [_arrowView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_arrowView.widthAnchor constraintEqualToConstant:13],
            [_arrowView.heightAnchor constraintEqualToConstant:13],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_arrowView.trailingAnchor constant:8],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [_badgeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_badgeLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_badgeLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_nameLabel.trailingAnchor
                                                                  constant:8],
            [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:24],
        ]];

        [self refreshAppearanceAnimated:NO];
        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)handleTap {
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [UIView animateWithDuration:0.10 animations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.18
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }];
}

- (void)setSelectedRow:(BOOL)selectedRow {
    if (_selectedRow == selectedRow) return;
    _selectedRow = selectedRow;
    [self refreshAppearanceAnimated:YES];
}

- (void)refreshAppearanceAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        if (self.selectedRow) {
            self.blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
            self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:1.0].CGColor;
            self.nameLabel.textColor = [UIColor labelColor];
            self.arrowView.tintColor = [UIColor labelColor];
        } else {
            self.blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.34];
            self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
            self.nameLabel.textColor = [UIColor secondaryLabelColor];
            self.arrowView.tintColor = [UIColor tertiaryLabelColor];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.15 animations:apply];
    } else {
        apply();
    }
}

/// 换分组行的箭头图标。传 nil 或无效的 SF Symbol 名 → 用默认 chevron.right。
/// 选中态的 tint 在 refreshAppearance 里统一上色，这里只负责换图。
- (void)setArrowSymbolName:(NSString *)symbolName {
    UIImage *img = nil;
    if (symbolName.length > 0) img = WGGSymbol(symbolName, 13, UIFontWeightSemibold);
    if (!img) img = WGGSymbol(@"chevron.right", 13, UIFontWeightSemibold);
    _arrowView.image = img;          // UIImageView 的属性 setter 会 retain
    _arrowView.hidden = (img == nil);
}

- (void)setBadgeCount:(NSInteger)count {
    if (count <= 0) {
        _badgeLabel.hidden = YES;
        _badgeLabel.text = nil;
        return;
    }
    _badgeLabel.hidden = NO;
    _badgeLabel.text = count > 999 ? @"999+" : [NSString stringWithFormat:@"%ld", (long)count];
}

- (void)dealloc {
    [_groupName release];
    [_nameLabel release];
    [_badgeLabel release];
    [_arrowView release];
    [_blur release];
    [super dealloc];
}

@end

#pragma mark - 抽屉面板

@interface GlassGroupPanel ()
@property (nonatomic, strong) UIVisualEffectView *glass;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *rowStack;
@property (nonatomic, strong) NSMutableArray<WGGRowView *> *rows;
@property (nonatomic, strong) UIVisualEffectView *searchBlur;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *searchHeightConstraint;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *badges;
@property (nonatomic, assign) BOOL didBuildHierarchy;
@property (nonatomic, strong) UIControl *settingsRow;      // 底部「设置」入口
@property (nonatomic, strong) UILabel *settingsLabel;

// 私有方法显式声明：避免"方法定义在调用点之后"在 -Werror 下出问题
- (void)buildHierarchy;
- (void)refreshSelectionAppearance;
- (void)rowTapped:(WGGRowView *)sender;
- (void)searchChanged;
- (void)applySearchVisibility;
- (void)settingsRowTapped;
@end

@implementation GlassGroupPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _groupNames = [(NSArray<NSString *> *)@[ WGGGroupAllName ] copy];
        _drawerWidth = kDrawerDefaultWidth;
        _glassAlpha = 0.95;
        _cornerRadius = kDrawerRadius;
        _searchEnabled = YES;
        _rowSpacing = kRowSpacing;
        _arrowSymbolName = [@"chevron.right" copy];
        _rows = [[NSMutableArray alloc] init];
        _badges = nil;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor clearColor];
        [self buildHierarchy];
    }
    return self;
}

#pragma mark 构建视图

- (void)buildHierarchy {
    if (_didBuildHierarchy) return;
    _didBuildHierarchy = YES;

    _glass = WGGCreateBlur(_cornerRadius);   // +1，dealloc 里 release
    _glass.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    [self addSubview:_glass];
    WGGApplyGlassChrome(self, _cornerRadius);

    _avatarView = [[UIImageView alloc] init];
    _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    _avatarView.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    _avatarView.layer.cornerRadius = kAvatarSize / 2.0;
    _avatarView.clipsToBounds = YES;
    _avatarView.contentMode = UIViewContentModeScaleAspectFill;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.text = @"#无趣";

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIFont *serif = [UIFont fontWithName:@"TimesNewRomanPS-ItalicMT" size:12];
    _subtitleLabel.font = serif ?: [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.text = @"life is but a dream";

    _sectionLabel = [[UILabel alloc] init];
    _sectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sectionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _sectionLabel.textColor = [UIColor tertiaryLabelColor];
    _sectionLabel.text = @"分组";

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = NO;

    _rowStack = [[UIStackView alloc] init];
    _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
    _rowStack.axis = UILayoutConstraintAxisVertical;
    _rowStack.spacing = kRowSpacing;
    _rowStack.alignment = UIStackViewAlignmentFill;
    [_scrollView addSubview:_rowStack];

    _searchBlur = WGGCreateBlur(kSearchHeight / 2.0);   // +1，dealloc 里 release
    _searchBlur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.34];
    _searchBlur.layer.borderWidth = 0.5;
    _searchBlur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    // 注意：这里**不要**加进 _glass.contentView，统一在下面那个循环里加，
    //       加两次虽然不会崩，但会让 z 顺序变得难以预料。

    // ⚠️ MRC：这三个是局部变量，alloc 出来的 +1 必须还给池子，
    //    否则 addSubview 的 retain 之外还多出一个没人放的引用 → 永久泄漏。
    UIImageView *searchIcon = [[[UIImageView alloc] init] autorelease];
    searchIcon.translatesAutoresizingMaskIntoConstraints = NO;
    searchIcon.image = WGGSymbol(@"magnifyingglass", 15, UIFontWeightRegular);
    searchIcon.tintColor = [UIColor secondaryLabelColor];
    searchIcon.contentMode = UIViewContentModeScaleAspectFit;
    [_searchBlur.contentView addSubview:searchIcon];

    _searchField = [[UITextField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _searchField.textColor = [UIColor labelColor];
    _searchField.placeholder = @"搜索会话";
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [_searchField addTarget:self
                     action:@selector(searchChanged)
           forControlEvents:UIControlEventEditingChanged];
    [_searchBlur.contentView addSubview:_searchField];

    // 底部「设置」入口：点它推出插件设置页（由 Hook 层负责 push）
    _settingsRow = [[UIControl alloc] init];
    _settingsRow.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsRow.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    _settingsRow.layer.cornerRadius = 12.0;
    _settingsRow.layer.cornerCurve = kCACornerCurveContinuous;
    [_settingsRow addTarget:self action:@selector(settingsRowTapped)
           forControlEvents:UIControlEventTouchUpInside];

    UIImageView *gearIcon = [[[UIImageView alloc] init] autorelease];   // MRC：见下方说明
    gearIcon.translatesAutoresizingMaskIntoConstraints = NO;
    gearIcon.image = WGGSymbol(@"gearshape", 14, UIFontWeightRegular);
    gearIcon.tintColor = [UIColor secondaryLabelColor];
    gearIcon.contentMode = UIViewContentModeScaleAspectFit;
    gearIcon.tag = 1;
    [_settingsRow addSubview:gearIcon];

    _settingsLabel = [[UILabel alloc] init];
    _settingsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _settingsLabel.textColor = [UIColor secondaryLabelColor];
    _settingsLabel.text = @"设置";
    [_settingsRow addSubview:_settingsLabel];

    UIImageView *settingsChevron = [[[UIImageView alloc] init] autorelease];   // MRC：同上
    settingsChevron.translatesAutoresizingMaskIntoConstraints = NO;
    settingsChevron.image = WGGSymbol(@"chevron.right", 11, UIFontWeightSemibold);
    settingsChevron.tintColor = [UIColor tertiaryLabelColor];
    settingsChevron.contentMode = UIViewContentModeScaleAspectFit;
    settingsChevron.tag = 2;
    [_settingsRow addSubview:settingsChevron];

    // ⚠️ 这几个必须全部加进 _glass.contentView，一个都不能漏。
    //    漏掉任何一个，它的约束和 layoutMarginsGuide 就没有共同祖先，
    //    激活约束时会直接崩："Unable to activate constraint with anchors ... no common ancestor"。
    for (UIView *v in @[_avatarView, _titleLabel, _subtitleLabel,
                        _sectionLabel, _scrollView, _searchBlur, _settingsRow]) {
        [_glass.contentView addSubview:v];
    }

    UILayoutGuide *m = _glass.contentView.layoutMarginsGuide;

    [NSLayoutConstraint activateConstraints:@[
        // 玻璃底
        [_glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        // 头
        [_avatarView.topAnchor constraintEqualToAnchor:m.topAnchor],
        [_avatarView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_avatarView.widthAnchor constraintEqualToConstant:kAvatarSize],
        [_avatarView.heightAnchor constraintEqualToConstant:kAvatarSize],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_avatarView.trailingAnchor constant:10],
        [_titleLabel.topAnchor constraintEqualToAnchor:_avatarView.topAnchor constant:2],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:m.trailingAnchor],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:m.trailingAnchor],

        // 分组标题
        [_sectionLabel.topAnchor constraintEqualToAnchor:_avatarView.bottomAnchor constant:18],
        [_sectionLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_sectionLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        // 滚动区
        [_scrollView.topAnchor constraintEqualToAnchor:_sectionLabel.bottomAnchor constant:8],
        [_scrollView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [_rowStack.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [_rowStack.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [_rowStack.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [_rowStack.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [_rowStack.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],

        // 搜索框
        [_searchBlur.topAnchor constraintGreaterThanOrEqualToAnchor:_scrollView.bottomAnchor constant:10],
        [_searchBlur.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_searchBlur.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        // 设置入口（在搜索框下面一行）
        [_settingsRow.topAnchor constraintEqualToAnchor:_searchBlur.bottomAnchor constant:8],
        [_settingsRow.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [_settingsRow.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [_settingsRow.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
        [_settingsRow.heightAnchor constraintEqualToConstant:34],

        [gearIcon.leadingAnchor constraintEqualToAnchor:_settingsRow.leadingAnchor constant:12],
        [gearIcon.centerYAnchor constraintEqualToAnchor:_settingsRow.centerYAnchor],
        [gearIcon.widthAnchor constraintEqualToConstant:15],
        [gearIcon.heightAnchor constraintEqualToConstant:15],

        [_settingsLabel.leadingAnchor constraintEqualToAnchor:gearIcon.trailingAnchor constant:7],
        [_settingsLabel.centerYAnchor constraintEqualToAnchor:_settingsRow.centerYAnchor],

        [settingsChevron.trailingAnchor constraintEqualToAnchor:_settingsRow.trailingAnchor constant:-12],
        [settingsChevron.centerYAnchor constraintEqualToAnchor:_settingsRow.centerYAnchor],
        [settingsChevron.widthAnchor constraintEqualToConstant:11],
        [settingsChevron.heightAnchor constraintEqualToConstant:11],

        [searchIcon.leadingAnchor constraintEqualToAnchor:_searchBlur.contentView.leadingAnchor constant:12],
        [searchIcon.centerYAnchor constraintEqualToAnchor:_searchBlur.contentView.centerYAnchor],
        [searchIcon.widthAnchor constraintEqualToConstant:16],
        [searchIcon.heightAnchor constraintEqualToConstant:16],

        [_searchField.leadingAnchor constraintEqualToAnchor:searchIcon.trailingAnchor constant:8],
        [_searchField.trailingAnchor constraintEqualToAnchor:_searchBlur.contentView.trailingAnchor constant:-10],
        [_searchField.centerYAnchor constraintEqualToAnchor:_searchBlur.contentView.centerYAnchor],
    ]];

    _searchHeightConstraint =
        [_searchBlur.heightAnchor constraintEqualToConstant:kSearchHeight];
    _searchHeightConstraint.active = YES;

    // 面板宽度（可调）
    _widthConstraint = [self.widthAnchor constraintEqualToConstant:_drawerWidth];
    _widthConstraint.active = YES;

    [self applySearchVisibility];
    [self reloadGroupRows];
}

#pragma mark 分组行重建

- (void)reloadGroupRows {
    if (!_didBuildHierarchy) return;
    if (![NSThread isMainThread]) {
        // UI 操作一律回主线程，避免后台线程改视图直接崩
        [self performSelectorOnMainThread:@selector(reloadGroupRows) withObject:nil waitUntilDone:NO];
        return;
    }

    for (WGGRowView *row in _rows) {
        [_rowStack removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    [_rows removeAllObjects];

    for (NSString *name in _groupNames) {
        WGGRowView *row = [[[WGGRowView alloc] initWithGroupName:name] autorelease];
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventValueChanged];
        [row.heightAnchor constraintEqualToConstant:kRowHeight].active = YES;
        [row setArrowSymbolName:_arrowSymbolName];   // 箭头图标（设置页可换）
        [_rowStack addArrangedSubview:row];
        [_rows addObject:row];
        NSNumber *b = _badges[name];
        [row setBadgeCount:b ? b.integerValue : 0];
    }

    [self refreshSelectionAppearance];
}

- (void)refreshSelectionAppearance {
    NSString *sel = _selectedGroupName ?: WGGGroupAllName;
    for (WGGRowView *row in _rows) {
        row.selectedRow = [row.groupName isEqualToString:sel];
    }
}

- (void)rowTapped:(WGGRowView *)sender {
    NSString *name = sender.groupName;
    if (!name) return;
    if (![_selectedGroupName isEqualToString:name]) {
        self.selectedGroupName = name;
    }
    if ([self.delegate respondsToSelector:@selector(glassGroupPanel:didSelectGroup:)]) {
        [self.delegate glassGroupPanel:self didSelectGroup:name];
    }
}

- (void)searchChanged {
    if ([self.delegate respondsToSelector:@selector(glassGroupPanel:didChangeSearchText:)]) {
        [self.delegate glassGroupPanel:self didChangeSearchText:_searchField.text ?: @""];
    }
}

- (void)settingsRowTapped {
    if ([self.delegate respondsToSelector:@selector(glassGroupPanelDidRequestSettings:)]) {
        [self.delegate glassGroupPanelDidRequestSettings:self];
    }
}

- (void)resignSearchInput {
    [_searchField resignFirstResponder];
}

#pragma mark 属性

- (void)setGroupNames:(NSArray<NSString *> *)groupNames {
    // 显式写开，不用 ?: —— MRC 下三元表达式混类型容易出意外，也让所有权一目了然
    NSArray<NSString *> *copy = groupNames ? [groupNames copy] : [@[ WGGGroupAllName ] copy];
    if ([_groupNames isEqualToArray:copy]) {
        [copy release];
        return;
    }
    [_groupNames release];
    _groupNames = copy;
    [self reloadGroupRows];
}

- (void)setSelectedGroupName:(NSString *)selectedGroupName {
    NSString *copy = [selectedGroupName copy];
    if (copy == _selectedGroupName || [copy isEqualToString:_selectedGroupName]) {
        [copy release];
        return;
    }
    [_selectedGroupName release];
    _selectedGroupName = copy;
    [self refreshSelectionAppearance];
}

/// 注意：drawerWidth / glassAlpha / cornerRadius / searchEnabled 都是**自定义 setter**。
/// 只要不写同名 getter，编译器仍会合成 ivar，所以这里能直接读写 _ivar。
- (void)setDrawerWidth:(CGFloat)drawerWidth {
    _drawerWidth = MAX(160.0, drawerWidth);
    _widthConstraint.constant = _drawerWidth;
}

- (void)setGlassAlpha:(CGFloat)glassAlpha {
    _glassAlpha = MAX(0.2, MIN(1.0, glassAlpha));
    _glass.alpha = _glassAlpha;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = MAX(0.0, cornerRadius);
    self.layer.cornerRadius = _cornerRadius;
    _glass.layer.cornerRadius = _cornerRadius;
}

- (void)setSearchEnabled:(BOOL)searchEnabled {
    _searchEnabled = searchEnabled;
    [self applySearchVisibility];
}

/// 行间距：设置页拖动滑杆实时生效（改 stack 的 spacing 就够了）。
- (void)setRowSpacing:(CGFloat)rowSpacing {
    _rowSpacing = MAX(0.0, MIN(24.0, rowSpacing));
    _rowStack.spacing = _rowSpacing;
}

/// 换箭头图标：直接刷新所有行（行数不多，开销可忽略）。
- (void)setArrowSymbolName:(NSString *)arrowSymbolName {
    NSString *copy = (arrowSymbolName.length > 0) ? [arrowSymbolName copy] : [@"chevron.right" copy];
    if (_arrowSymbolName && [copy isEqualToString:_arrowSymbolName]) {
        [copy release];
        return;
    }
    [_arrowSymbolName release];
    _arrowSymbolName = copy;
    for (WGGRowView *row in _rows) {
        [row setArrowSymbolName:_arrowSymbolName];
    }
}

- (void)applySearchVisibility {
    if (!_didBuildHierarchy) return;
    _searchBlur.hidden = !_searchEnabled;
    _searchHeightConstraint.constant = _searchEnabled ? kSearchHeight : 0.0;
    if (!_searchEnabled) [_searchField resignFirstResponder];
}

#pragma mark 对外 API

- (void)setHeaderTitle:(NSString *)title subtitle:(NSString *)subtitle avatar:(UIImage *)avatar {
    if (title) _titleLabel.text = title;
    if (subtitle) _subtitleLabel.text = subtitle;
    if (avatar) _avatarView.image = avatar;
}

- (void)setBadgeCounts:(NSDictionary<NSString *, NSNumber *> *)counts {
    [_badges release];
    _badges = [counts copy];
    for (WGGRowView *row in _rows) {
        NSNumber *b = _badges[row.groupName];
        [row setBadgeCount:b ? b.integerValue : 0];
    }
}

- (void)dealloc {
    [_groupNames release];
    [_selectedGroupName release];
    [_glass release];
    [_avatarView release];
    [_titleLabel release];
    [_subtitleLabel release];
    [_sectionLabel release];
    [_scrollView release];
    [_rowStack release];
    [_rows release];
    [_searchBlur release];
    [_searchField release];
    [_settingsRow release];
    [_settingsLabel release];
    [_widthConstraint release];
    [_searchHeightConstraint release];
    [_badges release];
    [_arrowSymbolName release];
    [super dealloc];
}

@end

#pragma mark - 抽屉宿主

@interface WGGDrawerHost ()
@property (nonatomic, strong) UIControl *overlay;
@property (nonatomic, strong) UIButton *triggerButton;
@property (nonatomic, strong) GlassGroupPanel *panel;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL animating;

// 私有方法声明（同前：避免定义顺序带来的 -Werror 风险）
- (void)overlayTapped;
- (void)triggerTapped;
- (void)applyTriggerVisibility;
@end

@implementation WGGDrawerHost

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor clearColor];

        // 1) 遮罩：铺满，点击收起
        _overlay = [[UIControl alloc] init];
        _overlay.translatesAutoresizingMaskIntoConstraints = NO;
        _overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.16];
        _overlay.hidden = YES;
        _overlay.alpha = 0.0;
        [_overlay addTarget:self action:@selector(overlayTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_overlay];

        // 2) 抽屉面板
        _panel = [[GlassGroupPanel alloc] initWithFrame:CGRectZero];
        [self addSubview:_panel];

        // 3) 悬浮触发按钮（最后加 → 在最上层，面板打开时还能点它收起）
        //    buttonWithType: 返回 autorelease 对象；MRC 下要自己 retain 才能在 dealloc 里配对 release。
        _triggerButton = [[UIButton buttonWithType:UIButtonTypeSystem] retain];
        _triggerButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_triggerButton setImage:WGGSymbol(@"line.3.horizontal", 17, UIFontWeightSemibold)
                        forState:UIControlStateNormal];
        _triggerButton.tintColor = [UIColor labelColor];
        _triggerButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.72];
        _triggerButton.layer.cornerRadius = kTriggerSize / 2.0;
        _triggerButton.layer.cornerCurve = kCACornerCurveContinuous;
        _triggerButton.layer.borderWidth = 0.5;
        _triggerButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.7].CGColor;
        _triggerButton.layer.shadowColor = [UIColor blackColor].CGColor;
        _triggerButton.layer.shadowOpacity = 0.16f;
        _triggerButton.layer.shadowRadius = 10.0;
        _triggerButton.layer.shadowOffset = CGSizeMake(0, 4);
        [_triggerButton addTarget:self action:@selector(triggerTapped)
                 forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_triggerButton];

        [NSLayoutConstraint activateConstraints:@[
            [_overlay.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_overlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_overlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_overlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_panel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kDrawerEdgeInset],
            [_panel.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor
                                             constant:kDrawerEdgeInset],
            [_panel.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor
                                                constant:-kDrawerEdgeInset],

            [_triggerButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_triggerButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_triggerButton.widthAnchor constraintEqualToConstant:kTriggerSize],
            [_triggerButton.heightAnchor constraintEqualToConstant:kTriggerSize],
        ]];

        self.animatedPresentation = YES;
        [self applyTriggerVisibility];
    }
    return self;
}

#pragma mark 触摸穿透

/// 关键：宿主铺满整个微信首页，如果什么都不做会把所有触摸都吃掉，
/// 会话列表就点不动了。这里让"落在空白处的触摸"直接穿透给下层微信。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;   // 空白处 → 穿透
    return hit;
}

#pragma mark 显示 / 隐藏

- (void)showPanelAnimated:(BOOL)animated {
    if (_panelVisible) return;
    _panelVisible = YES;
    _overlay.hidden = NO;
    [_panel layoutIfNeeded];

    CGFloat dx = -(self.panel.drawerWidth + kDrawerEdgeInset * 4 + 40.0);
    _panel.transform = CGAffineTransformMakeTranslation(dx, 0);
    _panel.alpha = 0.6;

    void (^show)(void) = ^{
        self.panel.transform = CGAffineTransformIdentity;
        self.panel.alpha = 1.0;
        self.overlay.alpha = 1.0;
    };

    if (animated && self.animatedPresentation) {
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.86
              initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:show
                         completion:nil];
    } else {
        show();
    }
}

- (void)hidePanelAnimated:(BOOL)animated {
    if (!_panelVisible) return;
    _panelVisible = NO;
    [_panel resignSearchInput];

    CGFloat dx = -(self.panel.drawerWidth + kDrawerEdgeInset * 4 + 40.0);
    void (^hide)(void) = ^{
        self.panel.transform = CGAffineTransformMakeTranslation(dx, 0);
        self.panel.alpha = 0.6;
        self.overlay.alpha = 0.0;
    };
    void (^done)(BOOL) = ^(BOOL finished) {
        self.overlay.hidden = YES;
    };

    if (animated && self.animatedPresentation) {
        [UIView animateWithDuration:0.24 animations:hide completion:done];
    } else {
        hide();
        done(YES);
    }
}

- (BOOL)isPanelVisible {
    return _panelVisible;
}

- (void)overlayTapped {
    [self hidePanelAnimated:YES];
}

- (void)triggerTapped {
    if (_panelVisible) {
        [self hidePanelAnimated:YES];
    } else {
        [self showPanelAnimated:YES];
    }
}

#pragma mark 属性

- (void)setDelegate:(id<GlassGroupPanelDelegate>)delegate {
    _delegate = delegate;
    _panel.delegate = delegate;
}

- (void)setTriggerButtonHidden:(BOOL)triggerButtonHidden {
    _triggerButtonHidden = triggerButtonHidden;
    [self applyTriggerVisibility];
}

- (void)applyTriggerVisibility {
    _triggerButton.hidden = _triggerButtonHidden;
    if (_triggerButtonHidden && _panelVisible) {
        [_overlay setHidden:NO];   // 按钮藏了也要能靠点遮罩收起
    }
}

- (void)dealloc {
    [_overlay release];
    [_triggerButton release];
    [_panel release];
    [super dealloc];
}

@end
