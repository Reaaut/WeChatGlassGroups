//
//  Tweak.x
//  WeChatGlassGroups
//
//  【Hook 层】只做三件事：找到首页 → 挂抽屉 → 把事件转发给数据层。
//  不写任何 UI 渲染代码，也不直接读写 plist。
//
//  ── 当前阶段：阶段一（注入 + UI 验证 + 设置页）────────────────────────
//  已经实现的钩子（只有两个，都刻意保持"只读观察 + 防重复"）：
//      UIViewController -viewDidAppear:
//        识别首页 → 挂 WGGDrawerHost（防重复叠加）
//        识别设置页 → 注入插件入口行（防重复注入）
//      UITableView -reloadData:
//        仅当这张表注入过入口行、且 footer 被微信重置时补挂回去。
//        不改返回值、不碰数据源，对微信无副作用。
//
//  ⚠️ 为什么不钩会话列表的数据源？
//     Tweak 里"钩得越少越不容易崩"。改成侧边抽屉后列表不再需要下移，
//     连 contentInset 那套也删了。少两个钩子 = 少两处可能和微信打架的地方。
//
//  ── 还没做（都依赖阶段一拿到真实类名）──────────────────────────────
//   1. 会话数据源过滤：要成对拦截 numberOfRows / cellForRow，
//      只拦 getter 会 index 越界。见文件末尾注释掉的骨架。
//   2. 长按会话 cell 的分组菜单：需要微信 cell 的真实类名。
//   3. 微信「我 → 设置」里的插件入口：需要 MMSettingViewController 真名。
//
//  ── 版本门禁 ────────────────────────────────────────────────────────
//    非 8.0.78 直接不介入（用 Info.plist 版本号判断，比 hook 类名可靠）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "GlassGroupPanel.h"
#import "GroupStore.h"
#import "SettingsController.h"
#import "Discovery.h"

// ===========================================================================
// MARK: - 前置声明
// ===========================================================================
static BOOL WGGVersionSupported(void);
static UITableView *WGGFindMainTableView(UIView *root);
static BOOL WGGLooksLikeConversationController(UIViewController *vc);
static BOOL WGGIsExcludedController(UIViewController *vc);
static void WGGInstallDrawerIfNeeded(UIViewController *vc);
static void WGGApplyStoreConfigToPanel(GlassGroupPanel *panel);
static void WGGProbeOnceIfPossible(UIViewController *vc);
static void WGGInstallSettingsEntryIfNeeded(UIViewController *vc);
static void WGGPushSettingsFrom(UIViewController *vc);
static UIView *WGGMakeSettingsEntryRow(void);

/// 入口行的点击处理：得从"当前显示中的控制器"往上推设置页。
/// 因为 footer 挂在 table 上，table 不持有任何控制器引用，
/// 所以用一个极小的单例转一手（不持任何对象，方法返回后即释放）。
@interface WGGSettingsEntryHandler : NSObject
+ (instancetype)sharedHandler;
- (void)entryTapped:(UIControl *)sender;
@end

/// 关联对象键：挂在首页控制器上，用来判断"抽屉是否已经装过"。
static const void *kWGGDrawerKey = &kWGGDrawerKey;
/// 关联对象键：挂在微信设置页控制器上，防止那一行被重复注入。
static const void *kWGGSettingsEntryKey = &kWGGSettingsEntryKey;

/// 目标微信版本白名单。
static NSString * const kWGGSupportedWeChatVersion = @"8.0.78";

// ===========================================================================
// MARK: - 版本门禁
// ===========================================================================
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
/// 控制器里面积最大的那个 UITableView（不依赖任何微信私有类名）。
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

static BOOL WGGLooksLikeConversationController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    if ([cls rangeOfString:@"Conversation" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"SessionList" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"MainFrame" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL WGGIsExcludedController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    NSArray *bad = @[ @"Chat", @"Message", @"Detail", @"Setting", @"Picker", @"Search" ];
    for (NSString *b in bad) {
        if ([cls rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// ===========================================================================
// MARK: - 把数据层的配置灌进 UI 层
// ===========================================================================
// UI 层不碰 GroupStore，由这里（Hook/编排层）负责两边对接。
static void WGGApplyStoreConfigToPanel(GlassGroupPanel *panel) {
    if (!panel) return;
    WGGGroupStore *store = [WGGGroupStore shared];
    panel.groupNames        = [store panelGroupNames];
    panel.selectedGroupName = [store selectedGroupName];
    panel.glassAlpha        = store.glassAlpha;
    panel.drawerWidth       = store.drawerWidth;
    panel.searchEnabled     = store.searchEnabled;
    panel.rowSpacing        = store.rowSpacing;          // 分组行间距（设置页可调）
    panel.arrowSymbolName   = [store arrowSymbolName];   // 分组箭头图标（设置页可换）
}

// ===========================================================================
// MARK: - 阶段一探测（拿真实属性名 + 验证自动归类）
// ===========================================================================
/// 只在进首页的头两次探测，避免 viewDidAppear 每次都刷屏。
/// 探测内容：会话数组到底叫什么属性名、每个会话被归到好友还是群聊。
static void WGGProbeOnceIfPossible(UIViewController *vc) {
    if (WGGIsExcludedController(vc)) return;
    if (!WGGLooksLikeConversationController(vc)) return;

    static int probes = 0;
    if (probes >= 2) return;
    probes++;

    WGGLogMessage(@"---- 开始探测会话列表（结果见下方）----");
    // 关闭 WGG_DISCOVERY 时这是个空函数，不会有任何开销
    WGGProbeConversations();
}

// ===========================================================================
// MARK: - 挂抽屉
// ===========================================================================
static void WGGInstallDrawerIfNeeded(UIViewController *vc) {
    if (!WGGVersionSupported()) return;

    WGGGroupStore *store = [WGGGroupStore shared];
    if (!store.isEnabled) return;
    if (!WGGLooksLikeConversationController(vc) || WGGIsExcludedController(vc)) return;

    WGGDrawerHost *host = objc_getAssociatedObject(vc, kWGGDrawerKey);

    if (host) {
        // 已经装过：只把最新配置刷一遍（设置改过之后回到首页就生效），
        // 绝不再 addSubview —— 这就是"防止重复叠加"的关键。
        WGGApplyStoreConfigToPanel(host.panel);
        host.triggerButtonHidden = store.triggerButtonHidden;
        host.animatedPresentation = store.animatedPresentation;
        return;
    }

    // 认一下是不是真有会话列表，没有就别插手（比如微信内嵌的临时页面）
    UITableView *table = WGGFindMainTableView(vc.view);
    if (!table) return;

    host = [[[WGGDrawerHost alloc] initWithFrame:CGRectZero] autorelease];
    host.delegate = (id<GlassGroupPanelDelegate>)vc;   // 分类实现见下
    host.triggerButtonHidden = store.triggerButtonHidden;
    host.animatedPresentation = store.animatedPresentation;
    WGGApplyStoreConfigToPanel(host.panel);

    [vc.view addSubview:host];
    [NSLayoutConstraint activateConstraints:@[
        [host.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
        [host.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [host.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [host.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];

    objc_setAssociatedObject(vc, kWGGDrawerKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WGGLogMessage([NSString stringWithFormat:@"抽屉已挂载：vc=%@ table=%@ 分组=%@",
                   NSStringFromClass([vc class]),
                   NSStringFromClass([table class]),
                   [store allGroupNames]]);
}

// ===========================================================================
// MARK: - 面板事件回调（用分类挂在 UIViewController 上，免去运行时补协议）
// ===========================================================================
@interface UIViewController (WGGDrawerDelegate) <GlassGroupPanelDelegate>
@end

@implementation UIViewController (WGGDrawerDelegate)

- (void)glassGroupPanel:(GlassGroupPanel *)panel didSelectGroup:(NSString *)groupName {
    WGGGroupStore *store = [WGGGroupStore shared];
    store.selectedGroupName = groupName;
    WGGLogMessage([NSString stringWithFormat:@"选中分组 → %@", groupName]);

    // 让微信自己重画列表。阶段一还没接管数据源，所以这一步只是"无害地刷一下"；
    // 阶段二接上过滤后，同一个调用就会真的把列表换成该分组的会话。
    UITableView *table = WGGFindMainTableView(self.view);
    [table reloadData];

    // 角标要等阶段二能拿到会话数组才能算（见 GroupStore 的 countsForConversations:）。
}

- (void)glassGroupPanel:(GlassGroupPanel *)panel didChangeSearchText:(NSString *)text {
    // ⚠️ 搜索"看起来能加"，但它同样需要介入会话数据源才可能正确 ——
    //    只过滤 UI 而不同步行数会直接崩溃。
    //    所以这里先只记录，不动列表。等阶段二确认了数据源结构再接。
    WGGLogMessage([NSString stringWithFormat:@"搜索框输入：%@（阶段三实现过滤）", text]);
}

- (void)glassGroupPanelDidRequestSettings:(GlassGroupPanel *)panel {
    [panel resignSearchInput];
    WGGPushSettingsFrom(self);
}

@end

// ===========================================================================
// MARK: - 设置页：两个入口
// ===========================================================================
// 入口 A：抽屉底部「设置」行（上面那个回调）
// 入口 B：微信「我 → 设置」页面底部注入的一行
//
// 入口 B 的实现思路（刻意避开数据源 hook）：
//   直接给设置页的 UITableView 设 tableFooterView，把我们的入口行挂在列表末尾。
//   好处：不碰 numberOfRowsInSection / cellForRow，就没有下标越界的崩溃风险；
//   微信自己刷新列表也只是把 footer 重画，不会崩。
//   坏处：如果微信在 viewDidAppear 之后又把 tableFooterView 置回 nil，入口会消失
//   —— 所以 %hook UITableView 里有个"补挂"逻辑（见下）。

/// 从任意控制器把设置页推出来；没有导航栈就改成模态弹出。
static void WGGPushSettingsFrom(UIViewController *vc) {
    if (!vc) return;
    WGGSettingsController *settings = [[[WGGSettingsController alloc] init] autorelease];

    UINavigationController *nav = vc.navigationController;
    if (nav && nav.visibleViewController == vc) {
        [nav pushViewController:settings animated:YES];
        return;
    }
    // 兜底：模态弹出（微信首页一般都有导航栈，走不到这里）
    settings.modalPresentationStyle = UIModalPresentationFormSheet;
    [vc presentViewController:settings animated:YES completion:nil];
}

/// 判断这个控制器像不像微信的「设置」页（只能按类名关键字猜，真名等日志确认）。
static BOOL WGGLooksLikeSettingsController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    if (!cls) return NO;
    if ([cls rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;
    // 排除我们自己的和明显不是"我→设置"的页面
    if ([cls hasPrefix:@"WGG"]) return NO;
    NSArray *bad = @[ @"Picker", @"Edit", @"Detail", @"Info", @"Cell", @"View" ];
    for (NSString *b in bad) {
        if ([cls rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    }
    return YES;
}

/// 微信设置页底部注入入口行。
static void WGGInstallSettingsEntryIfNeeded(UIViewController *vc) {
    if (!WGGVersionSupported()) return;
    if (!WGGLooksLikeSettingsController(vc)) return;

    UITableView *table = WGGFindMainTableView(vc.view);
    if (!table) return;

    // 已经注入过就不再重复（ associate 到 table 上，而不是 vc ——
    // 同一个 vc 里可能有多张表，按表去重更准）
    if (objc_getAssociatedObject(table, kWGGSettingsEntryKey)) return;

    UIView *entry = WGGMakeSettingsEntryRow();
    if (!entry) return;
    table.tableFooterView = entry;
    objc_setAssociatedObject(table, kWGGSettingsEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WGGLogMessage([NSString stringWithFormat:@"设置入口已注入：vc=%@ table=%@",
                   NSStringFromClass([vc class]), NSStringFromClass([table class])]);
}

/// 造一行长得像微信设置 cell 的入口（图标 + 标题 + 箭头），点它进插件设置页。
///
/// ⚠️ tableFooterView 的自适应是个坑：
///    如果把 row 的 translatesAutoresizingMaskIntoConstraints 设成 NO，
///    它的宽度就没有约束来源 → 会被压成 0 宽，什么都看不见。
///    所以这里反过来：row 用固定 frame（高 48、宽 = 屏宽），
///    内部子视图再用 Auto Layout 相对 row 排。
static UIView *WGGMakeSettingsEntryRow(void) {
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    UIView *row = [[[UIControl alloc] initWithFrame:CGRectMake(0, 0, w, 48)] autorelease];
    row.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    // 注意：row 自己不要动 translatesAutoresizingMaskIntoConstraints

    UIControl *tap = (UIControl *)row;
    [tap addTarget:[WGGSettingsEntryHandler sharedHandler]
            action:@selector(entryTapped:)
  forControlEvents:UIControlEventTouchUpInside];

    UIImageView *icon = [[[UIImageView alloc] init] autorelease];
    if (@available(iOS 13.0, *)) {
        icon.image = [UIImage systemImageNamed:@"rectangle.stack"];
    }
    icon.tintColor = [UIColor systemBlueColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = @"会话分组（液态玻璃）";
    title.font = [UIFont systemFontOfSize:17];
    title.textColor = [UIColor labelColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:title];

    UIImageView *chevron = [[[UIImageView alloc] init] autorelease];
    if (@available(iOS 13.0, *)) {
        chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    }
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [title.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12],
        [chevron.heightAnchor constraintEqualToConstant:12],
    ]];
    return row;
}

@implementation WGGSettingsEntryHandler

+ (instancetype)sharedHandler {
    static WGGSettingsEntryHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [[WGGSettingsEntryHandler alloc] init]; });
    return h;
}

- (void)entryTapped:(UIControl *)sender {
    // 从 keyWindow 找最顶层的控制器
    UIViewController *top = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            if (!w.isKeyWindow) continue;
            top = w.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
        }
    }
    if (!top) {
        WGGLogMessage(@"设置入口：找不到顶层控制器，弹不出设置页");
        return;
    }
    WGGPushSettingsFrom(top);
}

@end

// ===========================================================================
// MARK: - 通用钩子（只有两个，都刻意保持"只读观察 + 防重复"）
// ===========================================================================
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        WGGProbeOnceIfPossible(self);          // 阶段一：拿真名 + 验证归类
        WGGInstallDrawerIfNeeded(self);        // 首页：挂抽屉
        WGGInstallSettingsEntryIfNeeded(self); // 设置页：注入插件入口
    }
}

%end

// 微信刷新设置页列表时，可能把 tableFooterView 重置掉，导致我们的入口消失。
// 这里只在"这张表确实注入过入口"时补挂 —— 一个关联对象读取，代价可忽略。
// ⚠️ 绝不改返回值、不碰数据源，所以对微信无副作用。
%hook UITableView

- (void)reloadData {
    %orig;
    UITableView *table = self;
    UIView *entry = objc_getAssociatedObject(table, kWGGSettingsEntryKey);
    if (entry && table.tableFooterView != entry) {
        table.tableFooterView = entry;
    }
}

%end

// ===========================================================================
// MARK: - 阶段二骨架：QQ 好友分组样式（拿到真实类名后再启用）
// ===========================================================================
//
// ⚠️⚠️ 这一段必须保持 // 注释状态，不能用 #if 包！⚠️⚠️
//   Theos 的 Logos 预处理器不认 #if，它会照样生成 hook 代码，
//   但方法体被剔除了 → 链接报 "function ... has internal linkage but is not defined"。
//   这个坑已经踩过一次了。
//
// 【需求】不要悬浮窗。把首页聊天列表直接改成 QQ 好友分组那种：
//         好友 (12) ▾ / 群聊 (3) ▸ / 公众号 (2) ▸ —— 点表头折叠/展开。
//
// 【实现思路】在微信的会话表里"插行"（QQ 式分组的经典做法）：
//   1. 用 sectionsForConversations: 把原始会话数组切成若干段
//   2. 构建"虚拟行表"virtualRows：
//        [表头(好友)] + 好友的行(若展开) + [表头(群聊)] + 群聊的行(若展开) + ...
//   3. numberOfRows = virtualRows.count（numberOfSections 不动！微信多半只有 1 段）
//   4. cellForRow：virtualRows[row] 是表头 → 返回我们自己的玻璃表头 cell；
//      是会话 → 用 indices 把行号映射回原始数组，再 %orig 交给微信原生实现
//   5. 点表头 → toggleCollapsedForGroup: → [table reloadData]
//   ⚠️ numberOfSections / didSelectRowAtIndexPath / 行高 全都不动，
//      插入的表头行也走微信的行高，样式用玻璃圆角浮条区分。
//
// // 真机日志确认后填这三个真名：
// static NSString * const kWGGDataSourceClass   = @"（日志里 dataSource= 后面的类名）";
// static NSString * const kWGGConversationArray = @"（日志里 会话数组属性名 = 后面的名字）";
//
// %hook （真实数据源类名）
//
// // 1) 记录原始数组（只读快照，绝不修改微信的数组）
// - (NSArray *)conversationArray {
//     NSArray *raw = %orig;
//     [gWGGRememberedConversations release];
//     gWGGRememberedConversations = [raw copy];
//     return raw;
// }
//
// // 2) 行数 = 表头数 + 展开分组的会话数
// - (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
//     NSArray<WGGSection *> *secs = [[WGGGroupStore shared] sectionsForConversations:gWGGRememberedConversations];
//     NSInteger rows = (NSInteger)secs.count;               // 每段一行表头
//     for (WGGSection *s in secs) if (!s.collapsed) rows += (NSInteger)s.count;
//     return rows;
// }
//
// // 3) cell：表头行自己画；会话行映射回原始下标后 %orig
// - (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
//     WGGVirtualRow *v = WGGVirtualRowAt(indexPath.row);    // 由 sectionsForConversations 构建
//     if (v.kind == WGGRowKindHeader) {
//         return [WGGSectionHeaderCell cellForTable:tv section:v.section];  // 玻璃表头
//     }
//     NSIndexPath *mapped = [NSIndexPath indexPathForRow:v.originalIndex inSection:indexPath.section];
//     return %orig(tv, mapped);
// }
//
// %end
//
// 注意：这三个方法要钩在"真正给首页 table 供数的那个类"上。
//       日志里「会话探测：table=... dataSource=...」会直接给出答案。

// ===========================================================================
// MARK: - 入口
// ===========================================================================
%ctor {
    @autoreleasepool {
        WGGLogMessage(@"WeChatGlassGroups loaded（阶段一：探测 + 抽屉 UI）");

        // 运行时探测：把真实类名打到 syslog（阶段一的核心产出）
        WGGDiscoveryBootstrap();

        // 提前把数据层拉起来（会顺带完成旧格式迁移）
        (void)[WGGGroupStore shared];
    }
}
