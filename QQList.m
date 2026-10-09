//
//  QQList.m
//  WeChatGlassGroups
//
//  实现说明见头文件。MRC：-fno-objc-arc。
//  ⚠️ 静态缓存一律 alloc/init（+1），严禁把 @[...] 字面量存 static
//     （自动释放对象会被内存池排空 —— 抽屉分组名变乱串就是这个坑）。
//

#import "QQList.h"
#import "GroupStore.h"
#import "ConversationSource.h"
#import "Discovery.h"       // WGGLogMessage（同时会落文件）
#import <QuartzCore/QuartzCore.h>   // kCACornerCurveContinuous
#import <objc/message.h>

// ============================ 自绘会话 cell 声明 ============================
//（实现放在文件后部；声明必须提前，否则 WGGQQList 里引用会编译不过）

static NSString *const kWGGConversationReuseID = @"WGGConversationCell";

// 安全读取器原型（定义在文件后部，WGGQQList 先要用，必须先声明）
static NSString *WGGReadStr(id obj, NSArray<NSString *> *keys);
static id WGGReadObj(id obj, NSArray<NSString *> *keys);
static NSNumber *WGGReadNum(id obj, NSArray<NSString *> *keys);

/// 自绘会话行：玻璃胶囊 + 圆形首字头像 + 名字/最后消息/时间/未读红点。
@interface WGGConversationCell : UITableViewCell {
    UIView *_capsule;
    UILabel *_avatar;
    UILabel *_nameLabel;
    UILabel *_msgLabel;
    UILabel *_timeLabel;
    UILabel *_badgeLabel;
}
- (void)configureWithConversation:(id)conversation;
@end

// ============================ 虚拟行模型 ============================

@interface WGGVirtualRow ()
@property (nonatomic, assign, readwrite) BOOL isHeader;
@property (nonatomic, copy, readwrite) NSString *groupName;
@property (nonatomic, assign, readwrite) NSUInteger groupCount;
@property (nonatomic, assign, readwrite) BOOL collapsed;
@property (nonatomic, assign, readwrite) NSUInteger originalIndex;
@end

@implementation WGGVirtualRow

- (void)dealloc {
    [_groupName release];
    [super dealloc];
}

+ (instancetype)headerRowWithGroupName:(NSString *)name
                                 count:(NSUInteger)count
                             collapsed:(BOOL)collapsed {
    WGGVirtualRow *r = [[WGGVirtualRow alloc] init];   // +1，调用方负责
    if (r) {
        r->_isHeader = YES;
        r->_groupName = [name copy];
        r->_groupCount = count;
        r->_collapsed = collapsed;
        r->_originalIndex = NSNotFound;
    }
    return r;
}

+ (instancetype)conversationRowAtIndex:(NSUInteger)index {
    WGGVirtualRow *r = [[WGGVirtualRow alloc] init];   // +1，调用方负责
    if (r) {
        r->_isHeader = NO;
        r->_originalIndex = index;
    }
    return r;
}

@end

// ============================ 玻璃分组表头 cell ============================

static NSString * const kWGGHeaderReuseID = @"WGGQQSectionHeader";

@interface WGGSectionHeaderCell : UITableViewCell {
    UIView        *_blur;        // 玻璃底（+1 由 contentView 持有）
    UILabel       *_nameLabel;
    UILabel       *_countLabel;
    UIImageView   *_arrowView;
}
- (void)configureWithGroupName:(NSString *)name
                         count:(NSUInteger)count
                     collapsed:(BOOL)collapsed
                    arrowSymbol:(NSString *)symbolName;
@end

@implementation WGGSectionHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.backgroundColor = [UIColor clearColor];

        // 玻璃底：液态玻璃配方（和抽屉行同款）——
        //   UltraThinMaterialLight 毛玻璃 + 白色半透明 tint + 连续圆角 + 高光描边
        _blur = [[UIView alloc] init];                       // +1
        _blur.translatesAutoresizingMaskIntoConstraints = NO;
        _blur.layer.cornerRadius = 12.0;
        _blur.layer.cornerCurve = kCACornerCurveContinuous;  // 连续圆角（液态感）
        _blur.layer.masksToBounds = YES;
        _blur.layer.borderWidth = 0.5;
        _blur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        UIVisualEffectView *effect = [[UIVisualEffectView alloc]
                                      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        effect.translatesAutoresizingMaskIntoConstraints = NO;
        effect.frame = _blur.bounds;                          // layoutSubviews 会再对齐
        effect.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        effect.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.34];   // tint
        [_blur addSubview:effect];
        [effect release];                                     // _blur 已持有（净 +1）
        [self.contentView addSubview:_blur];

        _nameLabel = [[UILabel alloc] init];                  // +1
        _nameLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];

        _countLabel = [[UILabel alloc] init];                 // +1
        _countLabel.font = [UIFont systemFontOfSize:12.0];
        _countLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_countLabel];

        _arrowView = [[UIImageView alloc] init];              // +1
        _arrowView.tintColor = [UIColor secondaryLabelColor];
        _arrowView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_arrowView];
    }
    return self;
}

// 用 frame 布局（cell 里比约束省心，也不会撞"无公共祖先"）
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat h = b.size.height;
    CGFloat insetX = 12.0;
    CGFloat pad = 10.0;

    _blur.frame = CGRectInset(b, insetX, 3.0);               // 上下留缝 → 浮条感
    // 让内部毛玻璃撑满 _blur（autoresizing 也兜着，这里显式对齐一次）
    for (UIView *sub in _blur.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) sub.frame = _blur.bounds;
    }

    CGFloat arrowSize = 16.0;
    _arrowView.frame = CGRectMake(b.size.width - insetX - pad - arrowSize,
                                  (h - arrowSize) / 2.0, arrowSize, arrowSize);
    [_countLabel sizeToFit];
    _countLabel.frame = CGRectMake(_arrowView.frame.origin.x - pad - _countLabel.frame.size.width,
                                   (h - _countLabel.frame.size.height) / 2.0,
                                   _countLabel.frame.size.width,
                                   _countLabel.frame.size.height);
    _nameLabel.frame = CGRectMake(insetX + pad, 0.0,
                                  _countLabel.frame.origin.x - (insetX + pad) - pad,
                                  h);
}

- (void)configureWithGroupName:(NSString *)name
                         count:(NSUInteger)count
                     collapsed:(BOOL)collapsed
                    arrowSymbol:(NSString *)symbolName {
    _nameLabel.text = name;
    _countLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)count];

    // 玻璃透明度跟随设置（用户可调）
    WGGGroupStore *store = [WGGGroupStore shared];
    CGFloat alpha = store.glassAlpha;
    _blur.alpha = MAX(0.2, MIN(1.0, alpha));

    UIImage *img = nil;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
        img = [UIImage systemImageNamed:symbolName];
    }
    if (!img) img = [UIImage systemImageNamed:@"chevron.right"];   // 兜底
    _arrowView.image = img;

    // 展开：箭头朝下（转 90°）；折叠：默认朝右 —— QQ 手感
    CGFloat angle = collapsed ? 0.0 : M_PI_2;
    [UIView animateWithDuration:0.18 animations:^{
        _arrowView.transform = CGAffineTransformMakeRotation(angle);
    }];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _nameLabel.text = nil;
    _countLabel.text = nil;
}

- (void)dealloc {
    [_blur release];
    [_nameLabel release];
    [_countLabel release];
    [_arrowView release];
    [super dealloc];
}

@end

// ============================ 列表协调 ============================

static NSArray<WGGVirtualRow *> *gRows = nil;     // 虚拟行表缓存（+1 static 持有）
static NSString *gRowsSig = nil;                  // 缓存签名（+1）
static NSUInteger gCollapseVersion = 0;           // 折叠状态版本号（变了就重建）
static NSString *gLastToggleGroup = nil;          // 防抖：同组最近一次切换（+1）
static NSTimeInterval gLastToggleTime = 0.0;

@implementation WGGQQList

+ (BOOL)shouldGroupTable:(UITableView *)tableView ofVC:(id)vc {
    if (!tableView || !vc) return NO;
    WGGGroupStore *store = [WGGGroupStore shared];
    if (!store.enabled) return NO;

    // 只干预首页主表（类名日志实锤）
    if (![NSStringFromClass([tableView class]) isEqualToString:@"MainFrameTableView"]) return NO;

    // 搜索时微信自己换数据/行数，必须让路
    if ([WGGConversationSource isSearchingViewController:vc]) return NO;

    // 找不到会话数组（或空）→ 让路
    NSArray *convs = [WGGConversationSource conversationsForViewController:vc];
    if (!convs || convs.count == 0) return NO;

    return YES;
}

+ (NSArray<WGGVirtualRow *> *)virtualRowsForVC:(id)vc {
    NSArray *convs = [WGGConversationSource conversationsForViewController:vc];
    NSUInteger n = convs ? convs.count : 0;

    NSString *sig = [[NSString alloc] initWithFormat:@"%lu|%lu",
                     (unsigned long)n, (unsigned long)gCollapseVersion];
    if (gRowsSig && gRows && [gRowsSig isEqualToString:sig]) {
        [sig release];
        return gRows;
    }
    [gRowsSig release];
    gRowsSig = sig;   // +1 接管

    WGGGroupStore *store = [WGGGroupStore shared];
    NSMutableArray *rows = [[NSMutableArray alloc] init];   // +1
    NSArray<WGGSection *> *secs = [store sectionsForConversations:convs];
    for (WGGSection *s in secs) {
        // 主列表只用三个自动分组（自定义分组不进主列表，避免同一会话重复出现）
        if (![store isAutoGroup:s.name]) continue;
        WGGVirtualRow *h = [WGGVirtualRow headerRowWithGroupName:s.name
                                                           count:s.count
                                                       collapsed:s.collapsed];
        [rows addObject:h];
        [h release];                                        // 数组已持有
        if (!s.collapsed) {
            for (NSNumber *idx in s.indices) {
                WGGVirtualRow *r = [WGGVirtualRow conversationRowAtIndex:idx.unsignedIntegerValue];
                [rows addObject:r];
                [r release];
            }
        }
    }

    [gRows release];
    gRows = rows;                                           // +1 接管
    return gRows;
}

+ (CGFloat)headerHeight {
    WGGGroupStore *store = [WGGGroupStore shared];
    CGFloat h = 44.0 + store.rowSpacing;    // 行间距设置 → 表头更透气
    if (h < 44.0) h = 44.0;
    if (h > 72.0) h = 72.0;
    return h;
}

+ (UITableViewCell *)headerCellForTable:(UITableView *)tableView
                             virtualRow:(WGGVirtualRow *)v {
    WGGSectionHeaderCell *cell = [tableView dequeueReusableCellWithIdentifier:kWGGHeaderReuseID];
    if (!cell) {
        cell = [[[WGGSectionHeaderCell alloc] initWithStyle:UITableViewCellStyleDefault
                                            reuseIdentifier:kWGGHeaderReuseID] autorelease];
    }
    if (v && v.isHeader) {
        WGGGroupStore *store = [WGGGroupStore shared];
        [cell configureWithGroupName:v.groupName
                               count:v.groupCount
                           collapsed:v.collapsed
                          arrowSymbol:store.arrowSymbolName];
    }
    return cell;
}

+ (void)toggleGroupAtRow:(NSInteger)row {
    NSArray *rows = gRows;
    if (row < 0 || (NSUInteger)row >= rows.count) return;
    WGGVirtualRow *v = rows[(NSUInteger)row];
    if (!v.isHeader) return;
    [self toggleGroupNamed:v.groupName];
}

+ (void)toggleGroupNamed:(NSString *)name {
    if (name.length == 0) return;

    // 防抖：同组 0.5 秒内只认第一次。
    // ⚠️ 日志实锤（8.0.78）：reloadData 在 didSelect 里同步执行时，
    //    UIKit 会把同一次点击重复派发 2~4 次（一秒内"展开→折叠→展开→折叠"连响），
    //    最后状态等于没变 —— 用户体感就是"展开不了"。
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gLastToggleGroup && [gLastToggleGroup isEqualToString:name] &&
        (now - gLastToggleTime) < 0.5) {
        return;
    }
    [gLastToggleGroup release];
    gLastToggleGroup = [name copy];
    gLastToggleTime = now;

    WGGGroupStore *store = [WGGGroupStore shared];
    [store toggleCollapsedForGroup:name];
    gCollapseVersion++;   // 版本号变化 → 下次取虚拟行表自动重建
    WGGLogMessage([NSString stringWithFormat:@"分组折叠切换：%@ → %@",
                   name, [store isCollapsedGroup:name] ? @"折叠" : @"展开"]);
}

+ (id)conversationForVC:(id)vc row:(WGGVirtualRow *)v {
    if (!v || v.isHeader) return nil;
    NSArray *convs = [WGGConversationSource conversationsForViewController:vc];
    if (!convs || v.originalIndex >= convs.count) return nil;
    return [convs objectAtIndex:v.originalIndex];
}

+ (UITableViewCell *)conversationCellForTable:(UITableView *)tableView
                                conversation:(id)conversation {
    WGGConversationCell *cell = [tableView dequeueReusableCellWithIdentifier:kWGGConversationReuseID];
    if (!cell) {
        cell = [[[WGGConversationCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:kWGGConversationReuseID] autorelease];
    }
    [cell configureWithConversation:conversation];
    return cell;
}

+ (CGFloat)conversationHeight {
    return 64.0;
}

+ (NSString *)displayNameForConversation:(id)conversation {
    // 日志实锤（8.0.78 FakeMainFrameCellData 只有 7 个 ivar）：
    //   昵称 = _textForNameLabel（"小丸子"），带下划线！
    return WGGReadStr(conversation, @[
        @"_textForNameLabel", @"textForNameLabel",
        @"m_nsTitle", @"title", @"m_nsNickName", @"nickName", @"m_strNickName",
        @"name", @"m_nsDisplayName", @"displayName", @"m_strName"]);
}

@end

// ===========================================================================
// MARK: - 自绘"液态玻璃"会话 cell
// ===========================================================================
//
// 【为什么要自己画】日志实锤（8.0.78）：
//   · 微信自己的 MainFrameTableView 只显示 m_frontSessionArray 的一个小子集
//     （rows=6 而数组有 15 个），它的 cellForRow 对超出自己显示范围的索引
//     直接返回空白 cell → 分组后"组里有行但没有聊天记录"。
//   · 会话对象上 nick 一律读不到 → 只能自己按 ivar 名链去试。
//   · 自己画 = 内容 100% 可控 + UI 全面液态玻璃化。
//
// 数据读取：ivar 优先、respondsToSelector 兜底，永不触发 KVC（血泪教训）。
// 读不到就显示占位，绝不崩溃。

static NSString *WGGReadStr(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        if (k.length == 0) continue;
        const char *name = [k UTF8String];
        Ivar iv = class_getInstanceVariable([obj class], name);
        if (iv) {
            id v = object_getIvar(obj, iv);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                return (NSString *)v;   // +0，调用方立即使用，别留着
        }
        SEL sel = NSSelectorFromString(k);
        if ([obj respondsToSelector:sel]) {
            id v = [obj performSelector:sel];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0)
                return (NSString *)v;   // performSelector 结果已 autorelease
        }
    }
    return nil;
}

static id WGGReadObj(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        if (k.length == 0) continue;
        Ivar iv = class_getInstanceVariable([obj class], [k UTF8String]);
        if (iv) {
            id v = object_getIvar(obj, iv);
            if (v) return v;   // +0
        }
        SEL sel = NSSelectorFromString(k);
        if ([obj respondsToSelector:sel]) {
            id v = [obj performSelector:sel];
            if (v) return v;
        }
    }
    return nil;
}

static NSNumber *WGGReadNum(id obj, NSArray<NSString *> *keys) {
    id v = WGGReadObj(obj, keys);
    if ([v isKindOfClass:[NSNumber class]]) return (NSNumber *)v;
    return nil;
}

static UIColor *WGGColorForName(NSString *name) {
    NSUInteger h = name.hash;
    static UIColor *palette[8];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette[0] = [[UIColor alloc] initWithRed:0.35 green:0.62 blue:0.98 alpha:1.0];  // 蓝
        palette[1] = [[UIColor alloc] initWithRed:0.40 green:0.78 blue:0.55 alpha:1.0];  // 绿
        palette[2] = [[UIColor alloc] initWithRed:0.98 green:0.64 blue:0.30 alpha:1.0];  // 橙
        palette[3] = [[UIColor alloc] initWithRed:0.90 green:0.44 blue:0.50 alpha:1.0];  // 粉红
        palette[4] = [[UIColor alloc] initWithRed:0.62 green:0.55 blue:0.95 alpha:1.0];  // 紫
        palette[5] = [[UIColor alloc] initWithRed:0.36 green:0.77 blue:0.83 alpha:1.0];  // 青
        palette[6] = [[UIColor alloc] initWithRed:0.90 green:0.78 blue:0.35 alpha:1.0];  // 黄
        palette[7] = [[UIColor alloc] initWithRed:0.72 green:0.50 blue:0.34 alpha:1.0];  // 棕
    });
    return palette[(h & 0x7FFF) % 8];
}

@implementation WGGConversationCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        // 玻璃胶囊：UltraThinMaterialLight + 白色 tint + 连续圆角 + 高光描边
        _capsule = [[UIView alloc] init];   // +1
        _capsule.translatesAutoresizingMaskIntoConstraints = NO;
        _capsule.layer.cornerRadius = 16.0;
        _capsule.layer.cornerCurve = kCACornerCurveContinuous;
        _capsule.layer.masksToBounds = YES;
        _capsule.layer.borderWidth = 0.5;
        _capsule.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        UIVisualEffectView *effect = [[UIVisualEffectView alloc]
                                      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        effect.translatesAutoresizingMaskIntoConstraints = NO;
        effect.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.34];
        effect.frame = _capsule.bounds;
        effect.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_capsule addSubview:effect];
        [effect release];                   // 净 +1 归 _capsule
        [self.contentView addSubview:_capsule];

        _avatar = [[UILabel alloc] init];   // +1：圆形色块 + 首字符
        _avatar.translatesAutoresizingMaskIntoConstraints = NO;
        _avatar.textAlignment = NSTextAlignmentCenter;
        _avatar.textColor = [UIColor whiteColor];
        _avatar.font = [UIFont boldSystemFontOfSize:15];
        _avatar.layer.cornerRadius = 18.0;
        _avatar.layer.masksToBounds = YES;
        [_capsule addSubview:_avatar];

        _nameLabel = [[UILabel alloc] init]; // +1
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont boldSystemFontOfSize:15];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_capsule addSubview:_nameLabel];

        _msgLabel = [[UILabel alloc] init];  // +1
        _msgLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _msgLabel.font = [UIFont systemFontOfSize:13];
        _msgLabel.textColor = [UIColor secondaryLabelColor];
        _msgLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_capsule addSubview:_msgLabel];

        _timeLabel = [[UILabel alloc] init]; // +1
        _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _timeLabel.font = [UIFont systemFontOfSize:11];
        _timeLabel.textColor = [UIColor tertiaryLabelColor];
        _timeLabel.textAlignment = NSTextAlignmentRight;
        [_capsule addSubview:_timeLabel];

        _badgeLabel = [[UILabel alloc] init];// +1：未读红点
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.backgroundColor = [UIColor systemRedColor];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.font = [UIFont boldSystemFontOfSize:11];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 9.0;
        _badgeLabel.layer.masksToBounds = YES;
        _badgeLabel.hidden = YES;
        [_capsule addSubview:_badgeLabel];

        NSLayoutConstraint *c1 = [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:22];
        NSLayoutConstraint *c2 = [_badgeLabel.heightAnchor constraintEqualToConstant:18];
        [NSLayoutConstraint activateConstraints:@[
            [_capsule.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_capsule.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_capsule.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_capsule.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],

            [_avatar.leadingAnchor constraintEqualToAnchor:_capsule.leadingAnchor constant:12],
            [_avatar.centerYAnchor constraintEqualToAnchor:_capsule.centerYAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:36],
            [_avatar.heightAnchor constraintEqualToConstant:36],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:10],
            [_nameLabel.topAnchor constraintEqualToAnchor:_capsule.topAnchor constant:9],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_timeLabel.leadingAnchor constant:-6],

            [_msgLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_msgLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_msgLabel.trailingAnchor constraintEqualToAnchor:_capsule.trailingAnchor constant:-12],

            [_timeLabel.trailingAnchor constraintEqualToAnchor:_capsule.trailingAnchor constant:-12],
            [_timeLabel.topAnchor constraintEqualToAnchor:_capsule.topAnchor constant:9],
            [_timeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:44],

            [_badgeLabel.trailingAnchor constraintEqualToAnchor:_capsule.trailingAnchor constant:-12],
            [_badgeLabel.bottomAnchor constraintEqualToAnchor:_capsule.bottomAnchor constant:-9],
            c1, c2,
        ]];
        [c1 release];
        [c2 release];
    }
    return self;
}

- (void)configureWithConversation:(id)conversation {
    if (!conversation) {
        _nameLabel.text = @" ";
        _avatar.text = @"?";
        _msgLabel.text = @" ";
        _timeLabel.text = @" ";
        _badgeLabel.hidden = YES;
        return;
    }

    NSString *name = [WGGQQList displayNameForConversation:conversation];
    _nameLabel.text = name.length ? name : @"会话";
    NSString *first = name.length ? [name substringToIndex:1] : @"?";
    _avatar.text = first;
    _avatar.backgroundColor = WGGColorForName(name.length ? name : @"会话");

    NSString *msg = WGGReadStr(conversation, @[
        @"_textForMessageLabel", @"textForMessageLabel",
        @"m_nsMessage", @"message", @"m_strMessage", @"m_nsLastMsg", @"lastMessage", @"m_lastMsgText"]);
    if (!msg) {
        id wrap = WGGReadObj(conversation, @[
            @"m_lastMsgWrap", @"m_msgWrap", @"lastMsgWrap", @"m_lastMsg", @"lastMsg"]);
        msg = WGGReadStr(wrap, @[
            @"m_nsContent", @"content", @"m_nsText", @"text", @"m_strContent", @"m_strText", @"summary", @"desc"]);
    }
    _msgLabel.text = msg.length ? msg : @" ";

    NSString *time = WGGReadStr(conversation, @[
        @"_textForTimeLabel", @"textForTimeLabel",
        @"m_timeString", @"m_nsTimeString", @"timeString", @"m_timeStr", @"timeText"]);
    if (!time) {
        NSNumber *ts = WGGReadNum(conversation, @[
            @"m_uiLastMsgTime", @"lastMsgTime", @"m_lastMsgTime", @"m_uiTimeStamp"]);
        if (ts) {
            NSTimeInterval ti = ts.doubleValue;
            if (ti > 1e12) ti /= 1000.0;    // 毫秒 → 秒
            NSDate *d = [NSDate dateWithTimeIntervalSince1970:ti];
            static NSDateFormatter *fmt;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                fmt = [[NSDateFormatter alloc] init];
                fmt.dateFormat = @"HH:mm";
            });
            time = [fmt stringFromDate:d];
        }
    }
    _timeLabel.text = time.length ? time : @" ";

    NSNumber *unread = WGGReadNum(conversation, @[
        @"m_uiUnReadCount", @"unReadCount", @"m_unReadCount", @"m_uiCount"]);
    NSUInteger n = unread ? unread.unsignedIntegerValue : 0;
    if (n > 0) {
        _badgeLabel.text = n > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)n];
        _badgeLabel.hidden = NO;
    } else {
        _badgeLabel.text = nil;
        _badgeLabel.hidden = YES;
    }
}

- (void)dealloc {
    [_capsule release];
    [_avatar release];
    [_nameLabel release];
    [_msgLabel release];
    [_timeLabel release];
    [_badgeLabel release];
    [super dealloc];
}

@end
