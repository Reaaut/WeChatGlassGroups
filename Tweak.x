//
//  Tweak.x
//  WeChatGlassGroups
//
//  【Hook 层】只做三件事：找到首页 → 挂抽屉 → 把事件转发给数据层。
//  不写任何 UI 渲染代码，也不直接读写 plist。
//
//  ── 当前阶段：阶段一（注入 + UI 验证）────────────────────────────────
//  已经实现的钩子（只有一个，刻意保持最小）：
//      UIViewController -viewDidAppear:
//        识别首页 → 挂 WGGDrawerHost（带防重复叠加）
//
//  ⚠️ 为什么只钩这一个？
//     Tweak 里"钩得越少越不容易崩"。之前的版本还钩了
//     viewDidLayoutSubviews 和 UITableView -reloadData 来调 contentInset ——
//     改成侧边抽屉后列表不再需要下移，那两处就全删了。
//     少两个钩子 = 少两处可能和微信打架的地方。
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

/// 关联对象键：挂在首页控制器上，用来判断"抽屉是否已经装过"。
static const void *kWGGDrawerKey = &kWGGDrawerKey;

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

@end

// ===========================================================================
// MARK: - 唯一的通用钩子
// ===========================================================================
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        WGGInstallDrawerIfNeeded(self);
    }
}

%end

// ===========================================================================
// MARK: - 阶段二骨架（拿到真实类名后再启用）
// ===========================================================================
//
// ⚠️⚠️ 这一段必须保持 // 注释状态，不能用 #if 包！⚠️⚠️
//   Theos 的 Logos 预处理器不认 #if，它会照样生成 hook 代码，
//   但方法体被剔除了 → 链接报 "function ... has internal linkage but is not defined"。
//   这个坑已经踩过一次了。
//
// 启用步骤：
//   1. 阶段一跑起来，从 syslog 里拿到真实的类名和属性名
//   2. 把下面整段的 // 去掉，并换成真名
//   3. 先只开 getter 观察日志（确认拿得到数组），再开过滤
//
// // 需要真机确认的两个名字：
// static NSString * const kWGGConversationClass     = @"MMConversationListViewController";
// static NSString * const kWGGConversationArrayName = @"conversationArray";
//
// // 最近一次读到的原始会话数组（只读快照，绝不修改）
// static NSArray *gWGGRememberedConversations = nil;
//
// %hook MMConversationListViewController
//
// // 1) 记录原始数组，原样返回（绝不在 getter 里改数组）
// - (NSArray *)conversationArray {
//     NSArray *raw = %orig;
//     [gWGGRememberedConversations release];
//     gWGGRememberedConversations = [raw copy];
//     return raw;
// }
//
// // 2) 行数：必须和 cellForRow 用同一份映射，否则越界崩溃
// - (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
//     WGGFilterResult *r = [[WGGGroupStore shared] filterConversations:gWGGRememberedConversations];
//     if (r.active) return (NSInteger)r.filtered.count;
//     return %orig;
// }
//
// // 3) cell：把"过滤后的行号"翻译回原始行号，再交给微信原生实现
// - (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
//     WGGFilterResult *r = [[WGGGroupStore shared] filterConversations:gWGGRememberedConversations];
//     if (r.active && indexPath.row < (NSInteger)r.indices.count) {
//         NSInteger original = r.indices[(NSUInteger)indexPath.row].integerValue;
//         NSIndexPath *mapped = [NSIndexPath indexPathForRow:original inSection:indexPath.section];
//         return %orig(tv, mapped);
//     }
//     return %orig;
// }
//
// %end
//
// 注意：这三个方法要钩在"真正给首页 table 供数的那个类"上。
//       用阶段一的 WGGDumpViewTree 日志看 table 的 dataSource 是谁 —— 很可能不是控制器本身。

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
