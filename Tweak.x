//
//  Tweak.x
//  WeChatGlassGroups
//
//  ⚠️ 先读这段再改代码
//  ---------------------------------------------------------------------------
//  本文件的 %hook 分两类：
//
//  (A)【通用钩子】不依赖任何微信私有类名，一定安全：
//      UIViewController 的 viewDidAppear / viewDidLayoutSubviews、
//      UITableView 的 reloadData。作用是"找到首页 → 挂上面板 → 撑开 contentInset"。
//      即使类名猜错，这部分也只是不生效，不会崩微信。
//
//  (B)【数据源钩子】依赖真实类名/属性名，必须先用 Discovery 模块在真机上确认。
//      见文件末尾 "阶段二" 区域，默认关闭（需要 -DWGG_STAGE2=1 才编译）。
//      原因：微信刷新会话列表时，很可能"取数组"和"算行数"是两条独立路径。
//      只拦其中一个会造成 filtered.count != rows 的不一致 → index 越界崩溃。
//      所以必须先在真机上确认「谁的 -numberOfRowsInSection: 和 -cellForRowAtIndexPath:
//      在给首页 table 供数」，然后成对地拦这三个方法。
//
//  编译开关（Makefile 里加）：
//      -DWGG_DISCOVERY=1   打开运行时探测（阶段一必开）
//      -DWGG_STAGE2=1      打开数据源过滤（阶段二，确认类名后再开）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "GlassGroupPanel.h"
#import "GroupStore.h"
#import "Discovery.h"

// ===========================================================================
// MARK: - 前置声明
// ===========================================================================
static BOOL WGGVersionSupported(void);
static UITableView *WGGFindMainTableView(UIView *root);
static BOOL WGGLooksLikeConversationController(UIViewController *vc);
static BOOL WGGIsExcludedController(UIViewController *vc);
static void WGGInstallPanelIfNeeded(UIViewController *vc);
static void WGGApplyTableInset(UIViewController *vc);
static void WGGRefreshPanelCountsIfPossible(UIViewController *vc);
static NSArray *WGGCurrentConversations(void);
#if WGG_RESTYLE_SEARCHBAR
static void WGGRestyleSearchBarIfFound(UIView *root);
#endif

// ===========================================================================
// MARK: - 版本门禁
// ===========================================================================
// 设计稿提到"非 8.0.78 不加载"。这里用真实的 Info.plist 版本号判断，
// 比 hook 类名更可靠：类名会变，但版本号是我们自己维护的白名单。
static NSString * const kWGGSupportedWeChatVersion = @"8.0.78";

static BOOL WGGVersionSupported(void) {
    static BOOL ok = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        ok = [v isEqualToString:kWGGSupportedWeChatVersion];
        if (!ok) {
            WGGLogMessage([NSString stringWithFormat:
                @"微信版本 %@ 不在白名单(%@)，插件不介入。", v, kWGGSupportedWeChatVersion]);
        }
    });
    return ok;
}

// ===========================================================================
// MARK: - 首页识别
// ===========================================================================
static const void *kWGGPanelKey = &kWGGPanelKey;
static const void *kWGGTableKey = &kWGGTableKey;
static const void *kWGGInsetKey = &kWGGInsetKey;   // 我们额外加的 top inset，卸载时要还回去

/// 找出这个控制器里"最像会话列表"的那个 table view：面积最大的 UITableView。
static UITableView *WGGFindMainTableView(UIView *root) {
    if (!root) return nil;
    __block UITableView *best = nil;
    __block CGFloat bestArea = 0;
    __block void (^walk)(UIView *);
    walk = ^(UIView *v) {
        if ([v isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)v;
            CGRect r = [tv convertRect:tv.bounds toView:nil];
            CGFloat area = r.size.width * r.size.height;
            if (area > bestArea) { bestArea = area; best = tv; }
        }
        for (UIView *sub in v.subviews) walk(sub);
    };
    walk(root);
    return best;
}

/// 是不是"首页会话列表"控制器：类名命中关键字即可（真名确认后可换成精确判断）。
static BOOL WGGLooksLikeConversationController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    if ([cls rangeOfString:@"Conversation" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"SessionList" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"MainFrame" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

/// 排除"聊天详情 / 设置 / 搜索"这类里面也有大 table 的控制器。
static BOOL WGGIsExcludedController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    NSArray *bad = @[ @"Chat", @"Message", @"Detail", @"Setting", @"Picker", @"Search" ];
    for (NSString *b in bad) {
        if ([cls rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// ===========================================================================
// MARK: - 面板装配
// ===========================================================================
static void WGGInstallPanelIfNeeded(UIViewController *vc) {
    if (!WGGVersionSupported()) return;

    WGGGroupStore *store = [WGGGroupStore shared];
    if (!store.isEnabled) return;
    if (!WGGLooksLikeConversationController(vc) || WGGIsExcludedController(vc)) return;

    UITableView *table = WGGFindMainTableView(vc.view);
    if (!table) return;

    if (objc_getAssociatedObject(vc, kWGGPanelKey)) return;   // 已装过

    GlassGroupPanel *panel = [[GlassGroupPanel alloc] initWithFrame:CGRectZero];
    panel.delegate = (id<GlassGroupPanelDelegate>)vc;

    // 效果图里的两张图：右上角是圆形人像，左侧是黑白大图。
    // 素材还没提供，先留空（面板会显示灰阶占位）。
    // 想换成真图，取消下面两行注释并把图片放进 Resources/ 后一起打包：
    //   [panel setAvatarImage:[UIImage imageNamed:@"avatar"]];
    //   [panel setHeroImage:[UIImage imageNamed:@"hero"]];

    [panel restoreFromDefaults];
    [vc.view addSubview:panel];

    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    // 效果图左右留白是 60px(@3x) = 20pt，这里由 panel 内部自己管，
    // 所以 pin 到 view 边缘，不要再加 12pt 的外边距。
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
    ]];

    objc_setAssociatedObject(vc, kWGGPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kWGGTableKey, table, OBJC_ASSOCIATION_ASSIGN);

    WGGLogMessage([NSString stringWithFormat:@"面板已挂载到 %@，table=%@",
                   NSStringFromClass([vc class]), NSStringFromClass([table class])]);

    [vc.view layoutIfNeeded];
    WGGApplyTableInset(vc);

#if WGG_RESTYLE_SEARCHBAR
    WGGRestyleSearchBarIfFound(vc.view);
#endif
}

#if WGG_RESTYLE_SEARCHBAR
/// 【可选，默认关闭】效果图底部的搜索框是"圆角玻璃胶囊 + 左侧放大镜"。
/// 与其去 hook 微信的搜索框布局（风险高、版本一变就废），
/// 不如直接给它加圆角 + 毛玻璃背景 —— 视觉上就到位了，而且几乎不可能崩。
///
/// 为什么默认关闭：不同微信版本的搜索框实现差别很大
/// （UISearchBar / 自定义 UIView + UITextField 都有），
/// 强行改圆角和 masksToBounds 有可能让它的内容显示错位。
/// 建议阶段一确认了 view 层级之后再打开。
static void WGGRestyleSearchBarIfFound(UIView *root) {
    if (!root) return;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:NSClassFromString(@"UISearchBar")]) {
            v.layer.cornerRadius = 24.0;
            v.layer.cornerCurve = kCACornerCurveContinuous;
            v.clipsToBounds = YES;
            v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
            WGGLogMessage(@"已给搜索框加玻璃圆角");
        }
        WGGRestyleSearchBarIfFound(v);
    }
}
#endif

/// 把会话列表往下压，避免被悬浮面板遮挡。
/// 关键：不要硬编码数字。每次先减掉"上一次我们加的量"再加新的，
/// 否则下拉刷新 / 旋转 / 字号变化时会反复叠加，列表越推越低。
static void WGGApplyTableInset(UIViewController *vc) {
    GlassGroupPanel *panel = objc_getAssociatedObject(vc, kWGGPanelKey);
    UITableView *table = objc_getAssociatedObject(vc, kWGGTableKey);
    if (!panel || !table) return;

    CGFloat panelHeight = panel.bounds.size.height;
    if (panelHeight <= 1.0) {
        [panel layoutIfNeeded];
        panelHeight = panel.bounds.size.height;
    }
    if (panelHeight <= 1.0) return;   // 还没布局完，等下一次 layout 回调

    CGFloat desired = panel.frame.origin.y + panelHeight + 8.0;

    UIEdgeInsets inset = table.contentInset;
    NSValue *previous = objc_getAssociatedObject(vc, kWGGInsetKey);
    CGFloat previousExtra = previous ? previous.CGPointValue.y : 0.0;

    CGFloat newInsetTop = inset.top - previousExtra + desired;
    if (fabs(newInsetTop - inset.top) < 0.5) {
        // 没有变化就别动，避免打断微信正在进行的滚动 / 动画
        objc_setAssociatedObject(vc, kWGGInsetKey,
                                 [NSValue valueWithCGPoint:CGPointMake(0, desired)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    inset.top = newInsetTop;
    table.contentInset = inset;

    // 初始状态（还没滚动过）时，让内容从面板下方开始
    if (table.contentOffset.y < -inset.top + 0.5) {
        table.contentOffset = CGPointMake(table.contentOffset.x, -inset.top);
    }

    objc_setAssociatedObject(vc, kWGGInsetKey,
                             [NSValue valueWithCGPoint:CGPointMake(0, desired)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// 从"当前的会话数组"里算各组计数 / 未读并刷新面板。
/// 阶段一拿不到会话数组（那是私有属性），所以先留空；
/// 阶段二接上真实数据源后这里就有数据了。
static void WGGRefreshPanelCountsIfPossible(UIViewController *vc) {
    GlassGroupPanel *panel = objc_getAssociatedObject(vc, kWGGPanelKey);
    if (!panel) return;
    NSArray *conversations = WGGCurrentConversations();
    if (conversations) {
        WGGGroupStore *store = [WGGGroupStore shared];
        [panel setBadgeCounts:[store unreadCountsForConversations:conversations]];
    }
}

// ===========================================================================
// MARK: - 阶段二的会话数组来源（阶段一返回 nil）
// ===========================================================================
#if WGG_STAGE2
// 缓存最近一次读到的"原始"会话数组，供过滤和角标计数用。
// 注意这是只读快照：我们永远不修改它。
static NSArray *gWGGRememberedConversations = nil;
#endif

static NSArray *WGGCurrentConversations(void) {
#if WGG_STAGE2
    return gWGGRememberedConversations;
#else
    return nil;
#endif
}

// ===========================================================================
// MARK: - 面板 delegate（挂在 UIViewController 上的分类）
// ===========================================================================
@interface UIViewController (WGGPanelDelegate) <GlassGroupPanelDelegate>
@end

@implementation UIViewController (WGGPanelDelegate)

- (void)glassGroupPanel:(GlassGroupPanel *)panel didSelectGroup:(WGGGroup)group {
    WGGLogMessage([NSString stringWithFormat:@"切换到分组 %@", WGGGroupName(group)]);
    [WGGGroupStore shared].selectedGroup = group;

    // 选中分组 → 刷新列表。
    // 阶段一：这里只是普通 reloadData，过滤还没接管，所以视觉上列表不变；
    // 阶段二打开数据源钩子后，这里就会真的只显示该分组的会话。
    UITableView *table = WGGFindMainTableView(self.view);
    [table reloadData];

    WGGRefreshPanelCountsIfPossible(self);
}

- (void)glassGroupPanelDidChangeHeight:(GlassGroupPanel *)panel {
    WGGApplyTableInset(self);
}

@end

// ===========================================================================
// MARK: - (A) 通用钩子 —— 不依赖微信私有类名，安全
// ===========================================================================
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        WGGInstallPanelIfNeeded(self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    @autoreleasepool {
        // 面板高度可能因图片 / 字号变化，每次布局后校正 inset
        if (objc_getAssociatedObject(self, kWGGPanelKey)) {
            WGGApplyTableInset(self);
        }
    }
}

%end

// 微信每次 reloadData，我们都把 inset 校一遍（下拉刷新、收新消息都会走到这里）
%hook UITableView
- (void)reloadData {
    %orig;
    @autoreleasepool {
        UIResponder *r = self;
        while (r && ![r isKindOfClass:[UIViewController class]]) r = [r nextResponder];
        if (r && objc_getAssociatedObject(r, kWGGPanelKey)) {
            WGGApplyTableInset((UIViewController *)r);
        }
    }
}
%end

// ===========================================================================
// MARK: - (B) 阶段二：数据源过滤 —— 需要真机确认类名后启用
// ===========================================================================
#if WGG_STAGE2

// ⚠️ 下面这个名字是设计稿的假设值，真机探测后大概率要改。
static NSString * const kWGGConversationClass = @"MMConversationListViewController";

%hook MMConversationListViewController

// 1) 记录原始数组。永远返回 %orig 的原数组，绝不原地修改。
- (NSArray *)conversationArray {
    NSArray *raw = %orig;
    // copy 一份再存：微信可能随后就地改动这个数组，
    // 我们持有它的同时它被改动 → 遍历时崩溃。
    gWGGRememberedConversations = [raw copy];
    return raw;
}

// 2) 行数：必须与 cellForRow 使用同一份映射，否则越界崩溃。
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
#if WGG_STAGE2_FILTER
    WGGFilterResult *r = [[WGGGroupStore shared] filterConversations:gWGGRememberedConversations];
    if (r.active) return (NSInteger)r.filtered.count;
#endif
    return n;
}

// 3) cell：把"过滤后的行号"翻译回"原始行号"，再调用微信原生实现。
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
#if WGG_STAGE2_FILTER
    WGGFilterResult *r = [[WGGGroupStore shared] filterConversations:gWGGRememberedConversations];
    if (r.active && indexPath.row < (NSInteger)r.indices.count) {
        NSInteger original = r.indices[(NSUInteger)indexPath.row].integerValue;
        NSIndexPath *mapped = [NSIndexPath indexPathForRow:original inSection:indexPath.section];
        return %orig(tv, mapped);
    }
#endif
    return %orig;
}

%end

#endif  // WGG_STAGE2

// ===========================================================================
// MARK: - 入口
// ===========================================================================
%ctor {
    @autoreleasepool {
        WGGLogMessage(@"WeChatGlassGroups loaded");

        // 阶段一：先探测真实类名（把日志贴回来，才能写阶段二的钩子）
        WGGDiscoveryBootstrap();

        // 提前加载配置（每次启动读一次 NSUserDefaults）
        (void)[WGGGroupStore shared];
    }
}
