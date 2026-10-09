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
#import <objc/message.h>

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

        // 玻璃底：小毛玻璃 + 圆角浮条（和抽屉行同风格）
        _blur = [[UIView alloc] init];                       // +1
        _blur.translatesAutoresizingMaskIntoConstraints = NO;
        _blur.layer.cornerRadius = 12.0;
        _blur.layer.masksToBounds = YES;
        UIVisualEffectView *effect = [[UIVisualEffectView alloc]
                                      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        effect.translatesAutoresizingMaskIntoConstraints = NO;
        effect.frame = _blur.bounds;                          // layoutSubviews 会再对齐
        effect.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
    [gSig release];
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
        cell = [[WGGSectionHeaderCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:kWGGHeaderReuseID];
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
    WGGGroupStore *store = [WGGGroupStore shared];
    [store toggleCollapsedForGroup:name];
    gCollapseVersion++;   // 版本号变化 → 下次取虚拟行表自动重建
    WGGLogMessage([NSString stringWithFormat:@"分组折叠切换：%@ → %@",
                   name, [store isCollapsedGroup:name] ? @"折叠" : @"展开"]);
}

@end
