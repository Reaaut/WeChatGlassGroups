//
//  SettingsController.m
//  WeChatGlassGroups
//
//  【UI 层】设置页实现。读写都走 GroupStore 的设置属性（Hook 层不参与）。
//
//  交互约定：
//   * 所有控件都用 target/action + tag 分发，**不用 block**（MRC 下 block 持有
//     self 容易写出循环引用，tag 分发最直白也最安全）。
//   * 改动即时生效并落盘；返回首页时 Hook 层会把新配置刷给抽屉。
//

#import "SettingsController.h"
#import "GroupStore.h"

NSArray<NSString *> *WGGArrowSymbolChoices(void) {
    static NSArray *choices;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        choices = @[
            @"chevron.right",       // ›   细箭头（默认）
            @"chevron.forward",     // ›   同上（语义化名字）
            @"arrow.right",         // →   平箭头
            @"arrowtriangle.right.fill", // ▶ 实心三角
            @"chevron.compact.right",    // ❯ 加粗紧凑
            @"greaterthan",         // ＞  数学符号风
        ];
    });
    return choices;
}

// ---- 常量 ----
static const CGFloat kCardRadius   = 14.0;
static const CGFloat kCardPaddingH = 14.0;
static const CGFloat kCardPaddingV = 12.0;
static const CGFloat kSliderWidth  = 170.0;

// tag 分发表
typedef NS_ENUM(NSInteger, WGGSettingTag) {
    WGGTagSwitchEnabled  = 100,   // 总开关
    WGGTagSwitchTrigger  = 101,   // 显示悬浮按钮（存的是"隐藏"，取反）
    WGGTagSwitchAnimated = 102,   // 滑入动画
    WGGTagSwitchSearch   = 103,   // 显示搜索框
    WGGTagSwitchVerbose  = 104,   // 详细日志
    WGGTagSliderAlpha    = 200,   // 玻璃透明度
    WGGTagSliderWidth    = 201,   // 抽屉宽度
    WGGTagSliderSpacing  = 202,   // 行间距
    WGGTagRowArrow       = 300,   // 箭头图标（点击换下一个）
    WGGTagDeleteBase     = 400,   // 400+i = 删除第 i 个自定义分组
};

@interface WGGSettingsController () {
    UIScrollView *_scroll;
    UIStackView *_stack;
    UITextField *_newGroupField;
    UILabel *_alphaValue;
    UILabel *_widthValue;
    UILabel *_spacingValue;
    UILabel *_arrowValue;
}
- (void)rebuildContent;
- (void)addSectionHeader:(NSString *)title;
- (UIView *)addCard:(CGFloat)height;
- (UIStackView *)makeHStack;
- (UILabel *)makeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color;
- (void)switchChanged:(UISwitch *)sender;
- (void)sliderChanged:(UISlider *)sender;
- (void)arrowRowTapped:(UIControl *)sender;
- (void)addGroupTapped:(UIButton *)sender;
- (void)deleteGroupTapped:(UIButton *)sender;
- (void)addHintRow:(NSString *)text;
@end

@implementation WGGSettingsController

- (instancetype)init {
    if ((self = [super init])) {
        self.title = @"分组设置";
    }
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view = root;      // UIViewController 的 view 属性会 retain
    [root release];

    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_scroll];

    _stack = [[UIStackView alloc] init];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 8.0;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:16],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    [self rebuildContent];
}

#pragma mark 内容构建

- (void)rebuildContent {
    // 清空重建（自定义分组增删后会整体刷新，最省心）
    for (UIView *v in _stack.arrangedSubviews) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    WGGGroupStore *store = [WGGGroupStore shared];

    // ── 分组 ──────────────────────────────────────────────
    [self addSectionHeader:@"分组"];
    UIView *c1 = [self addCard:48];
    UIStackView *s1 = [self makeHStack];
    [c1 addSubview:s1];
    [self pin:s1 toCard:c1];
    [s1 addArrangedSubview:[self makeLabel:@"启用会话分组" font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    UISwitch *main = [[[UISwitch alloc] init] autorelease];
    main.on = store.isEnabled;
    main.tag = WGGTagSwitchEnabled;
    [main addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [s1 addArrangedSubview:main];

    // ── 外观 ──────────────────────────────────────────────
    [self addSectionHeader:@"外观"];

    UIView *cA = [self addCard:48];
    UIStackView *sA = [self makeHStack];
    [cA addSubview:sA];
    [self pin:sA toCard:cA];
    [sA addArrangedSubview:[self makeLabel:@"玻璃透明度" font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    [_alphaValue release];   // MRC：ivar 重新赋值前先放掉旧的
    _alphaValue = [[self makeValueLabel:[NSString stringWithFormat:@"%.0f%%", store.glassAlpha * 100]] retain];
    [sA addArrangedSubview:_alphaValue];
    UISlider *aSlider = [self makeSlider:WGGTagSliderAlpha
                                    min:0.30 max:1.00 value:store.glassAlpha];
    [sA addArrangedSubview:aSlider];

    UIView *cW = [self addCard:48];
    UIStackView *sW = [self makeHStack];
    [cW addSubview:sW];
    [self pin:sW toCard:cW];
    [sW addArrangedSubview:[self makeLabel:@"抽屉宽度" font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    [_widthValue release];
    _widthValue = [[self makeValueLabel:[NSString stringWithFormat:@"%.0f", store.drawerWidth]] retain];
    [sW addArrangedSubview:_widthValue];
    UISlider *wSlider = [self makeSlider:WGGTagSliderWidth
                                    min:220.0 max:340.0 value:store.drawerWidth];
    [sW addArrangedSubview:wSlider];

    UIView *cS = [self addCard:48];
    UIStackView *sS = [self makeHStack];
    [cS addSubview:sS];
    [self pin:sS toCard:cS];
    [sS addArrangedSubview:[self makeLabel:@"分组行间距" font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    [_spacingValue release];
    _spacingValue = [[self makeValueLabel:[NSString stringWithFormat:@"%.0f pt", store.rowSpacing]] retain];
    [sS addArrangedSubview:_spacingValue];
    UISlider *sSlider = [self makeSlider:WGGTagSliderSpacing
                                    min:0.0 max:24.0 value:store.rowSpacing];
    [sS addArrangedSubview:sSlider];

    // 箭头图标（点击循环切换）
    UIView *cAr = [self addCard:48];
    UIControl *arTap = [[[UIControl alloc] initWithFrame:CGRectZero] autorelease];   // MRC：局部控件入池
    arTap.translatesAutoresizingMaskIntoConstraints = NO;
    arTap.tag = WGGTagRowArrow;
    [arTap addTarget:self action:@selector(arrowRowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cAr addSubview:arTap];
    [self pin:arTap toCard:cAr];
    UIStackView *sAr = [self makeHStack];
    [arTap addSubview:sAr];
    [self pin:sAr toCard:arTap];
    [sAr addArrangedSubview:[self makeLabel:@"分组箭头图标" font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    [_arrowValue release];
    _arrowValue = [[self makeValueLabel:[self arrowDisplayName]] retain];
    [sAr addArrangedSubview:_arrowValue];
    UIImageView *arChevron = [[[UIImageView alloc] init] autorelease];
    arChevron.image = [UIImage systemImageNamed:@"chevron.right"];
    arChevron.tintColor = [UIColor tertiaryLabelColor];
    arChevron.contentMode = UIViewContentModeScaleAspectFit;
    [arChevron.widthAnchor constraintEqualToConstant:12].active = YES;
    [sAr addArrangedSubview:arChevron];

    // ── 行为 ──────────────────────────────────────────────
    [self addSectionHeader:@"行为"];
    [self addSwitchRow:@"显示悬浮按钮" tag:WGGTagSwitchTrigger on:(!store.triggerButtonHidden)];
    [self addSwitchRow:@"滑入/滑出动画" tag:WGGTagSwitchAnimated on:store.animatedPresentation];
    [self addSwitchRow:@"显示搜索框" tag:WGGTagSwitchSearch on:store.searchEnabled];

    // ── 自定义分组 ────────────────────────────────────────
    [self addSectionHeader:@"自定义分组"];
    [self addAddGroupRow];
    NSArray *custom = [store allGroupNames];   // 含自动分组，下面过滤
    NSMutableArray *mine = [NSMutableArray array];
    for (NSString *n in custom) {
        if (![store isAutoGroup:n]) [mine addObject:n];
    }
    if (mine.count == 0) {
        [self addHintRow:@"暂无自定义分组。输入名字点「添加」即可创建。"];
    } else {
        for (NSUInteger i = 0; i < mine.count; i++) {
            [self addGroupRow:mine[i] index:i];
        }
    }

    // ── 其他 ──────────────────────────────────────────────
    [self addSectionHeader:@"其他"];
    [self addSwitchRow:@"详细日志（排查用）" tag:WGGTagSwitchVerbose on:store.verboseLogging];

    UIView *cInfo = [self addCard:48];
    UIStackView *sInfo = [self makeHStack];
    [cInfo addSubview:sInfo];
    [self pin:sInfo toCard:cInfo];
    [sInfo addArrangedSubview:[self makeLabel:@"关于"
                                         font:[UIFont systemFontOfSize:16]
                                        color:[UIColor labelColor]]];
    [sInfo addArrangedSubview:[self makeLabel:@"WeChatGlassGroups 0.2.0"
                                         font:[UIFont systemFontOfSize:13]
                                        color:[UIColor tertiaryLabelColor]]];

    // 说明文字
    [self addHintRow:@"自动分组规则：群聊 id 以 @chatroom 结尾；公众号以 gh_ 开头；其余按好友处理。"];
}

#pragma mark 小工具

- (NSString *)arrowDisplayName {
    NSString *cur = [[WGGGroupStore shared] arrowSymbolName];
    if ([cur isEqualToString:@"arrow.right"]) return @"→ 平箭头";
    if ([cur isEqualToString:@"arrowtriangle.right.fill"]) return @"▶ 实心三角";
    if ([cur isEqualToString:@"chevron.compact.right"]) return @"❯ 紧凑";
    if ([cur isEqualToString:@"greaterthan"]) return @"＞ 大于号";
    return @"› 细箭头";
}

- (UILabel *)makeValueLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = text;
    l.textAlignment = NSTextAlignmentRight;
    [l.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    return [l autorelease];
}

- (UILabel *)makeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    l.text = text;
    l.numberOfLines = 1;
    return [l autorelease];
}

- (UIStackView *)makeHStack {
    UIStackView *sv = [[UIStackView alloc] init];
    sv.axis = UILayoutConstraintAxisHorizontal;
    sv.alignment = UIStackViewAlignmentCenter;
    sv.spacing = 10.0;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.layoutMargins = UIEdgeInsetsMake(kCardPaddingV, kCardPaddingH, kCardPaddingV, kCardPaddingH);
    sv.isLayoutMarginsRelativeArrangement = YES;
    return [sv autorelease];
}

- (UISlider *)makeSlider:(NSInteger)tag min:(CGFloat)mn max:(CGFloat)mx value:(CGFloat)v {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = mn;
    s.maximumValue = mx;
    s.value = v;
    s.tag = tag;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [s.widthAnchor constraintEqualToConstant:kSliderWidth].active = YES;
    [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    return [s autorelease];
}

- (UIView *)addCard:(CGFloat)height {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    card.layer.cornerRadius = kCardRadius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [_stack addArrangedSubview:card];
    [card.heightAnchor constraintEqualToConstant:height].active = YES;
    return [card autorelease];
}

- (void)pin:(UIView *)v toCard:(UIView *)card {
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:card.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
}

- (void)addSectionHeader:(NSString *)title {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = title;
    UIEdgeInsets p = UIEdgeInsetsMake(10, 4, 2, 4);
    UIView *wrap = [[UIView alloc] init];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    [l setTranslatesAutoresizingMaskIntoConstraints:NO];
    [wrap addSubview:l];
    [_stack addArrangedSubview:wrap];
    [wrap.heightAnchor constraintEqualToConstant:30].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:p.top],
        [l.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:p.left],
        [l.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-p.bottom],
    ]];
    [l release];
    [wrap release];
}

- (void)addSwitchRow:(NSString *)title tag:(NSInteger)tag on:(BOOL)on {
    UIView *card = [self addCard:48];
    UIStackView *sv = [self makeHStack];
    [card addSubview:sv];
    [self pin:sv toCard:card];
    [sv addArrangedSubview:[self makeLabel:title font:[UIFont systemFontOfSize:16] color:[UIColor labelColor]]];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [sv addArrangedSubview:sw];
    [sw release];
}

- (void)addHintRow:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor tertiaryLabelColor];
    l.text = text;
    l.numberOfLines = 0;
    [l setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_stack addArrangedSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:_stack.leadingAnchor constant:6],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:_stack.trailingAnchor constant:-6],
    ]];
    [l release];
}

#pragma mark 自定义分组的两行

- (void)addAddGroupRow {
    UIView *card = [self addCard:48];
    UIStackView *sv = [self makeHStack];
    [card addSubview:sv];
    [self pin:sv toCard:card];

    [_newGroupField release];   // MRC：rebuildContent 会重新创建，旧的先放掉
    _newGroupField = [[UITextField alloc] init];
    _newGroupField.placeholder = @"新分组名";
    _newGroupField.font = [UIFont systemFontOfSize:15];
    _newGroupField.borderStyle = UITextBorderStyleRoundedRect;
    _newGroupField.returnKeyType = UIReturnKeyDone;
    _newGroupField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _newGroupField.translatesAutoresizingMaskIntoConstraints = NO;
    [sv addArrangedSubview:_newGroupField];
    [_newGroupField.widthAnchor constraintEqualToConstant:150].active = YES;

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add setTitle:@"添加" forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    add.layer.cornerRadius = 10.0;
    add.backgroundColor = [UIColor systemBlueColor];
    [add setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [add addTarget:self action:@selector(addGroupTapped:) forControlEvents:UIControlEventTouchUpInside];
    [add.widthAnchor constraintEqualToConstant:64].active = YES;
    [add.heightAnchor constraintEqualToConstant:32].active = YES;
    [sv addArrangedSubview:add];
}

- (void)addGroupRow:(NSString *)name index:(NSUInteger)index {
    UIView *card = [self addCard:44];
    UIStackView *sv = [self makeHStack];
    [card addSubview:sv];
    [self pin:sv toCard:card];

    [sv addArrangedSubview:[self makeLabel:name
                                     font:[UIFont systemFontOfSize:15]
                                    color:[UIColor labelColor]]];

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.tag = (NSInteger)(WGGTagDeleteBase + index);
    [del setTitle:@"删除" forState:UIControlStateNormal];
    del.titleLabel.font = [UIFont systemFontOfSize:13];
    [del setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [del addTarget:self action:@selector(deleteGroupTapped:) forControlEvents:UIControlEventTouchUpInside];
    [sv addArrangedSubview:del];
}

#pragma mark 事件

- (void)switchChanged:(UISwitch *)sender {
    WGGGroupStore *store = [WGGGroupStore shared];
    switch (sender.tag) {
        case WGGTagSwitchEnabled:  store.enabled = sender.on; break;
        case WGGTagSwitchTrigger:  store.triggerButtonHidden = !sender.on; break;   // 取反
        case WGGTagSwitchAnimated: store.animatedPresentation = sender.on; break;
        case WGGTagSwitchSearch:   store.searchEnabled = sender.on; break;
        case WGGTagSwitchVerbose:  store.verboseLogging = sender.on; break;
        default: break;
    }
}

- (void)sliderChanged:(UISlider *)sender {
    WGGGroupStore *store = [WGGGroupStore shared];
    switch (sender.tag) {
        case WGGTagSliderAlpha:
            store.glassAlpha = sender.value;
            _alphaValue.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100];
            break;
        case WGGTagSliderWidth:
            store.drawerWidth = sender.value;
            _widthValue.text = [NSString stringWithFormat:@"%.0f", sender.value];
            break;
        case WGGTagSliderSpacing:
            store.rowSpacing = sender.value;
            _spacingValue.text = [NSString stringWithFormat:@"%.0f pt", sender.value];
            break;
        default: break;
    }
}

- (void)arrowRowTapped:(UIControl *)sender {
    NSArray *choices = WGGArrowSymbolChoices();
    NSString *cur = [[WGGGroupStore shared] arrowSymbolName];
    NSUInteger idx = 0;
    for (NSUInteger i = 0; i < choices.count; i++) {
        if ([choices[i] isEqualToString:cur]) { idx = i + 1; break; }
    }
    if (idx >= choices.count) idx = 0;
    [[WGGGroupStore shared] setArrowSymbolName:choices[idx]];
    _arrowValue.text = [self arrowDisplayName];
}

- (void)addGroupTapped:(UIButton *)sender {
    NSString *name = _newGroupField.text;
    if (![name isKindOfClass:[NSString class]]) return;
    if ([[WGGGroupStore shared] addGroupNamed:name]) {
        _newGroupField.text = @"";
        [_newGroupField resignFirstResponder];
        [self rebuildContent];   // 重建后 _newGroupField 是新实例，需要重新获取焦点
    }
}

- (void)deleteGroupTapped:(UIButton *)sender {
    WGGGroupStore *store = [WGGGroupStore shared];
    NSMutableArray *mine = [NSMutableArray array];
    for (NSString *n in [store allGroupNames]) {
        if (![store isAutoGroup:n]) [mine addObject:n];
    }
    NSInteger i = sender.tag - WGGTagDeleteBase;
    if (i < 0 || (NSUInteger)i >= mine.count) return;
    [store removeGroupNamed:mine[(NSUInteger)i]];
    [self rebuildContent];
}

#pragma mark 生命周期

- (void)dealloc {
    [_scroll release];
    [_stack release];
    [_newGroupField release];
    [_alphaValue release];
    [_widthValue release];
    [_spacingValue release];
    [_arrowValue release];
    [super dealloc];
}

@end
