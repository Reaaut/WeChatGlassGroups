//
//  Discovery.m
//  WeChatGlassGroups
//

#import "Discovery.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 日志入口：无论是否开启 DISCOVERY 都存在，所以 .m / Tweak.x 都可以直接用。
void WGGLogMessage(NSString *msg) {
    NSLog(@"[WGG] %@", msg);
}

#define WGGLog(fmt, ...) WGGLogMessage([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

#ifdef WGG_DISCOVERY

// ---------- 小工具 ----------

// 递归打印 view 树。这是找"哪个 view 是会话列表、哪一层可以放悬浮面板"的最快方式。
static void WGGDumpView(id v, NSUInteger depth) {
    if (!v || depth > 14) return;
    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [pad appendString:@"  "];

    UIView *view = (UIView *)v;
    CGRect f = view.frame;
    CGFloat alpha = view.alpha;
    BOOL hidden = view.hidden;

    NSMutableString *extra = [NSMutableString string];
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)view;
        // dataSource / delegate 的类名是阶段二最关键的信息：
        // 只有知道"谁在供数"，才知道该 hook 哪个类。
        [extra appendFormat:@" rows(s0)=%ld style=%ld insets=%@ dataSource=%@ delegate=%@",
            (long)[tv numberOfRowsInSection:0], (long)tv.style,
            NSStringFromUIEdgeInsets(tv.contentInset),
            tv.dataSource ? NSStringFromClass([tv.dataSource class]) : @"(nil)",
            tv.delegate ? NSStringFromClass([tv.delegate class]) : @"(nil)"];
    } else if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        [extra appendFormat:@" content=%@ offset=%@ insets=%@",
            NSStringFromCGSize(sv.contentSize), NSStringFromCGPoint(sv.contentOffset),
            NSStringFromUIEdgeInsets(sv.contentInset)];
    } else if ([view isKindOfClass:[UILabel class]]) {
        [extra appendFormat:@" text=%@", [(UILabel *)view text]];
    } else if ([view isKindOfClass:[UIImageView class]]) {
        [extra appendFormat:@" image=%@", [(UIImageView *)view image] ? @"yes" : @"nil"];
    } else if ([view isKindOfClass:[UIButton class]]) {
        [extra appendFormat:@" title=%@", [[(UIButton *)view titleLabel] text]];
    } else if ([view isKindOfClass:[UIVisualEffectView class]]) {
        [extra appendString:@" <blur>"];
    } else if ([view isKindOfClass:[UICollectionView class]]) {
        [extra appendString:@" <collectionView>"];
    }

    WGGLog(@"%@%@ frame=%@ alpha=%.2f%@%@",
           pad, NSStringFromClass([view class]), NSStringFromCGRect(f), alpha,
           hidden ? @" HIDDEN" : @"", extra);

    for (UIView *sub in view.subviews) WGGDumpView(sub, depth + 1);
}

void WGGDumpViewTree(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            WGGLog(@"==== WINDOW %@ level=%.1f hidden=%@ ====",
                   NSStringFromClass([w class]), w.windowLevel, w.hidden ? @"YES" : @"NO");
            WGGDumpView(w, 0);
        }
    }
}

// 打印一个类的属性 / ivar / 方法。属性名是 hook 时最需要的（比如 conversationArray 到底叫什么）。
void WGGDumpClassInfo(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        WGGLog(@"class NOT FOUND: %@", className);
        return;
    }
    WGGLog(@"========== CLASS %@ ==========", className);

    // 继承链
    NSMutableString *chain = [NSMutableString string];
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        [chain appendFormat:@"%@ <- ", NSStringFromClass(c)];
    }
    WGGLog(@"inheritance: %@", chain);

    // 属性
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    WGGLog(@"-- properties (%u) --", count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        WGGLog(@"   @property %s   [%s]", name, attrs ? attrs : "");
    }
    free(props);

    // 实例变量（很多"属性"其实是直接访问 ivar，hook getter 无效，必须 hook ivar 或上层方法）
    count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    WGGLog(@"-- ivars (%u) --", count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        WGGLog(@"   ivar %s   [%s]", name, type ? type : "");
    }
    free(ivars);

    // 方法（只看自己实现的，不看继承来的）
    count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    WGGLog(@"-- methods (%u) --", count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        // 只打印看起来和数据源/刷新/生命周期相关的，避免日志爆炸
        NSString *s = NSStringFromSelector(sel);
        BOOL interesting = [s rangeOfString:@"conversation" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"session" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"reload" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"viewDid" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"viewWill" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"Table" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [s rangeOfString:@"DataSource" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (interesting) {
            WGGLog(@"   - %@   [%s]", s, types ? types : "");
        }
    }
    free(methods);
    WGGLog(@"========== END %@ ==========", className);
}

void WGGSearchClasses(NSString *keyword, NSUInteger limit) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)numClasses);
    numClasses = objc_getClassList(classes, numClasses);

    NSUInteger found = 0;
    WGGLog(@"---- search classes containing '%@' ----", keyword);
    for (int i = 0; i < numClasses; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *n = [NSString stringWithUTF8String:name];
        if ([n rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            WGGLog(@"   %@", n);
            if (++found >= limit) { WGGLog(@"   ... (truncated at %lu)", (unsigned long)limit); break; }
        }
    }
    WGGLog(@"---- %lu match(es) ----", (unsigned long)found);
    free(classes);
}

// ---------- 安装探测 ----------
//
// 注意：本文件是纯 Objective-C，不含 Logos 语法（%hook/%ctor）。
// 所有 %hook 都写在 Tweak.x 里，这里只导出普通 C 函数给它调用。
// 原因：Theos 的 Logos 预处理器只处理 .x 文件，把 %hook 写在 .m 里会编译失败。

void WGGDiscoveryBootstrap(void) {
    @autoreleasepool {
        WGGLog(@"loading WeChatGlassGroups DISCOVERY build");

        // 第一步：按关键字搜索真实类名。这是唯一可靠的办法——
        // 设计稿里的 MMConversationListViewController 只是"传闻"，真机上未必叫这个。
        WGGSearchClasses(@"Conversation", 100);
        WGGSearchClasses(@"Session", 100);
        WGGSearchClasses(@"Glass", 20);   // 万一有重名的插件
        WGGSearchClasses(@"MainFrame", 60);

        // 第二步：逐个验证设计稿里假设存在的类名。
        // 让日志直接说出真相，而不是让 hook 静默失效。
        NSArray *candidates = @[
            @"MMConversationListViewController",
            @"MMSessionListView",
            @"MMTableView",
            @"MMConversation",
            @"MMSessionInfo",
            @"NewMainFrameViewController",
            @"MMUINavigationController",
            @"MMTabBarController",
        ];
        for (NSString *c in candidates) {
            Class k = NSClassFromString(c);
            WGGLog(@"candidate %@ -> %@", c, k ? @"EXISTS" : @"missing");
        }
    }
}

#endif  // WGG_DISCOVERY

#ifndef WGG_DISCOVERY
// 关闭探测时提供空实现，Tweak.x 可以无条件调用。
void WGGDiscoveryBootstrap(void) {}
void WGGDumpViewTree(void) {}
void WGGDumpClassInfo(NSString *className) { (void)className; }
void WGGSearchClasses(NSString *keyword, NSUInteger limit) { (void)keyword; (void)limit; }
#endif
