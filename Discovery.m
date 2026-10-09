//
//  Discovery.m
//  WeChatGlassGroups
//

#import "Discovery.h"
#import "GroupStore.h"   // 会话自动归类要用到 autoKindForConversation:
#import "Logger.h"       // 日志落文件（用户设置页「复制日志」就能提交，不用折腾 syslog）
#import <objc/runtime.h>
#import <objc/message.h>

// 日志入口：无论是否开启 DISCOVERY 都存在，所以 .m / Tweak.x 都可以直接用。
// 同时写两处：NSLog（syslog，给接了电脑的人）+ 文件（给手机上直接复制的人）。
void WGGLogMessage(NSString *msg) {
    NSLog(@"[WGG] %@", msg);
    WGGFileLogAppend(msg);
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

// ---------- 会话数组 / 自动归类 探测 ----------
//
// 这是阶段一最有价值的一段：它把"会话数组到底叫什么属性名"和
// "每个会话会被归到好友还是群聊"直接在真机上打出来。
// 有了它，阶段二就不需要猜任何属性名了。

/// 在所有 window 里找面积最大的 UITableView（= 首页会话列表）。
static UITableView *WGGFindLargestTableView(void) {
    __block UITableView *best = nil;
    __block CGFloat bestArea = 0;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
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
            walk(w);
        }
    }
    return best;
}

/// 递归扫描一个对象的成员变量表（含父类，最多 3 层），找"有内容的业务数组"。
/// pathTag 是来源路径（如 vc.m_mainFrameLogicController），depth 0~2。
/// 命中：outName = "路径.ivar名"，返回数组；没命中返回 nil（日志已打全成员地图）。
/// ✅ 日志实锤：会话数组不在 NewMainFrameViewController 本体上，
///    但 m_mainFrameLogicController = MainFrameLogicController —— 数据在逻辑层。
static NSArray *WGGScanIvarsForArray(id obj, NSString *pathTag, int depth, NSString **outName) {
    if (!obj || depth > 2) return nil;
    Class origClass = [obj class];
    Class c = origClass;
    WGGLog(@"---- 成员变量扫描 [%@]（%@）----", pathTag, NSStringFromClass(c));

    NSMutableArray *candNames = [NSMutableArray array];   // 候选数组的路径名
    NSMutableArray *candArrays = [NSMutableArray array];  // 候选数组的值
    NSMutableArray *hopNames = [NSMutableArray array];    // 值得深挖的子对象（高优先）
    NSMutableArray *hopObjs = [NSMutableArray array];
    NSMutableArray *hopLowNames = [NSMutableArray array]; // 低优先（防漏，放最后）
    NSMutableArray *hopLowObjs = [NSMutableArray array];
    int scanned = 0;

    while (c && scanned < 3) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *tEnc = ivar_getTypeEncoding(ivars[i]);
            const char *nEnc = ivar_getName(ivars[i]);
            if (!tEnc || tEnc[0] != '@' || !nEnc) continue;   // 只关心对象类型
            NSString *name = [NSString stringWithUTF8String:nEnc];
            id val = object_getIvar(obj, ivars[i]);            // 原始读取，零副作用
            if (!val) continue;

            // 系统基础容器/字符串等排除（不会是会话数组）
            BOOL blocked = [val isKindOfClass:[NSString class]] ||
                           [val isKindOfClass:[NSDictionary class]] ||
                           [val isKindOfClass:[NSNumber class]] ||
                           [val isKindOfClass:[NSSet class]] ||
                           [val isKindOfClass:[NSDate class]] ||
                           [val isKindOfClass:[NSData class]] ||
                           [val isKindOfClass:[NSValue class]];
            if (blocked) continue;

            if ([val isKindOfClass:[NSArray class]]) {
                NSUInteger n = [(NSArray *)val count];
                id first = n > 0 ? [(NSArray *)val firstObject] : nil;
                NSString *fc = first ? NSStringFromClass([first class]) : @"(空)";
                BOOL systemish = [fc hasPrefix:@"NS"] || [fc hasPrefix:@"__"] ||
                                 [fc hasPrefix:@"UI"] || [fc hasPrefix:@"WK"];
                WGGLog(@"  ⭐ %@.%@ = NSArray count=%lu 首元素=%@%@",
                       pathTag, name, (unsigned long)n, fc,
                       systemish ? @"（系统类，跳过）" : @"");
                if (n > 0 && !systemish) {
                    [candNames addObject:[NSString stringWithFormat:@"%@.%@", pathTag, name]];
                    [candArrays addObject:val];
                }
                continue;
            }

            NSString *vcName = NSStringFromClass([val class]);
            WGGLog(@"  ivar %@.%@ = %@", pathTag, name, vcName);

            // 值得递归的子对象：逻辑/数据管理类（跳过视图和控制器本身）
            BOOL isView = [val isKindOfClass:[UIView class]];
            BOOL isVC   = [val isKindOfClass:[UIViewController class]];
            if (!isView && !isVC) {
                BOOL high = [vcName rangeOfString:@"LogicController"].location != NSNotFound ||
                            [vcName rangeOfString:@"DataManager"].location != NSNotFound ||
                            [vcName rangeOfString:@"CellData"].location != NSNotFound;
                BOOL low  = [vcName rangeOfString:@"Logic"].location != NSNotFound ||
                            [vcName rangeOfString:@"Manager"].location != NSNotFound ||
                            [vcName rangeOfString:@"Store"].location != NSNotFound ||
                            [vcName rangeOfString:@"Center"].location != NSNotFound;
                if (high) {
                    [hopNames addObject:[NSString stringWithFormat:@"%@.%@", pathTag, name]];
                    [hopObjs addObject:val];
                } else if (low && hopLowObjs.count < 2) {
                    [hopLowNames addObject:[NSString stringWithFormat:@"%@.%@", pathTag, name]];
                    [hopLowObjs addObject:val];
                }
            }
        }
        free(ivars);
        c = class_getSuperclass(c);
        scanned++;
    }

    // 属性表只在第一层打（避免刷屏）
    if (depth == 0) {
        unsigned int pcount = 0;
        objc_property_t *props = class_copyPropertyList(origClass, &pcount);
        if (pcount > 0) {
            WGGLog(@"---- 属性表（共 %u 条，只列名字）----", pcount);
            NSMutableString *names = [NSMutableString string];
            for (unsigned int i = 0; i < pcount; i++) {
                [names appendFormat:@"%@  ", @(property_getName(props[i]))];
                if ((i + 1) % 6 == 0) { WGGLog(@"  %@", names); [names setString:@""]; }
            }
            if (names.length) WGGLog(@"  %@", names);
        }
        free(props);
    }

    if (candArrays.count > 0) {
        NSUInteger best = 0;
        for (NSUInteger i = 1; i < candArrays.count; i++) {
            if ([(NSArray *)candArrays[i] count] > [(NSArray *)candArrays[best] count]) best = i;
        }
        if (outName) *outName = candNames[best];
        WGGLog(@"会话探测：⭐ 选定数组 %@（元素最多，count=%lu）",
               candNames[best], (unsigned long)[(NSArray *)candArrays[best] count]);
        return candArrays[best];
    }

    // 本层没数组 → 深挖逻辑/数据管理对象（先高优先：LogicController/DataManager）
    for (NSUInteger i = 0; i < hopObjs.count; i++) {
        NSArray *deep = WGGScanIvarsForArray(hopObjs[i], hopNames[i], depth + 1, outName);
        if (deep) return deep;
    }
    for (NSUInteger i = 0; i < hopLowObjs.count; i++) {
        NSArray *deep = WGGScanIvarsForArray(hopLowObjs[i], hopLowNames[i], depth + 1, outName);
        if (deep) return deep;
    }
    return nil;
}

static NSArray *WGGSafeFindConversationArray(id ds, NSString **outName) {
    if (outName) *outName = nil;
    NSArray *found = WGGScanIvarsForArray(ds, @"vc", 0, outName);
    if (!found) {
        WGGLog(@"会话探测：vc 及其逻辑/数据子对象里都没扫到业务数组 —— 请把【成员变量扫描】整段发回来");
    }
    return found;
}

// 【转储】把类里名字含关键词的方法列出来（只读，不改任何东西）。
// 用途：会话行点击目前靠 %orig 映射，超出微信自己显示范围的索引会静默
// 失效（用户点了没反应）。下一轮直接调用微信自己的"打开聊天"接口，
// 真实方法名就由这份清单给出。
static void WGGSafeDumpMethods(Class cls, NSString *tag, NSArray<NSString *> *keywords) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;
    WGGLog(@"方法清单 [%@] %s（%u 个方法，只列命中）", tag, class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *s = sel_getName(sel);
        if (!s) continue;
        NSString *name = [NSString stringWithUTF8String:s];
        BOOL hit = NO;
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                hit = YES; break;
            }
        }
        if (hit) {
            char *types = method_copyReturnType(methods[i]);
            WGGLog(@"   -[%@ %@] 返回=%s", tag, name, types ? types : "?");
            if (types) free(types);
        }
    }
    free(methods);
}

void WGGProbeConversations(void) {
    @autoreleasepool {
        UITableView *table = WGGFindLargestTableView();
        if (!table) {
            WGGLog(@"会话探测：没找到任何 UITableView");
            return;
        }

        id ds = table.dataSource;
        NSInteger rows = [table numberOfRowsInSection:0];
        WGGLog(@"会话探测：table=%@ rows(s0)=%ld dataSource=%@",
               NSStringFromClass([table class]), (long)rows,
               ds ? NSStringFromClass([ds class]) : @"(nil)");
        WGGLog(@"会话探测：table.delegate=%@",
               table.delegate ? NSStringFromClass([table.delegate class]) : @"(nil)");
        if (!ds) return;

        // 【安全探测】扫描 dataSource 的成员变量表，把"有内容的业务数组"找出来。
        // 之前用 valueForKey: 乱试候选名，在微信对象上触发 KVC 兜底逻辑，
        // 不但没找到数组，还把进程内存搞脏了（我们的分组名一度变成微信请求头）。
        NSString *foundName = nil;
        NSArray *found = WGGSafeFindConversationArray(ds, &foundName);
        if (!found) return;   // 没找到：dump 信息已打在日志里，等用户发回来

        // 逐条打印标识 + 自动归类结果，直接验证"好友/群聊"判断是否成立
        NSUInteger limit = found.count < 15 ? found.count : 15;
        for (NSUInteger i = 0; i < limit; i++) {
            id conv = found[i];
            NSString *key  = [WGGGroupStore keyForConversation:conv];
            NSString *nick = [WGGGroupStore displayNameForConversation:conv];
            WGGAutoKind kind = [WGGGroupStore autoKindForConversation:conv];
            // ⚠️ 格式串不要给 %@ 加宽度（%-28@ 这类）—— clang 的 -Wformat 可能判非法，
            //    本工程 -Werror，一警告就直接挂。想对齐就用普通空格拼接。
            WGGLog(@"   [%2lu] class=%@ key=%@ nick=%@ → %@",
                   (unsigned long)i,
                   NSStringFromClass([conv class]),
                   key  ? key  : @"(取不到)",
                   nick ? nick : @"(取不到)",
                   [WGGGroupStore nameForAutoKind:kind]);
        }

        // 统计一下归类分布，一眼看出比例对不对
        NSUInteger friends = 0, groups = 0, official = 0, sys = 0, unknown = 0;
        for (id conv in found) {
            switch ([WGGGroupStore autoKindForConversation:conv]) {
                case WGGAutoKindFriend:   friends++;  break;
                case WGGAutoKindGroup:    groups++;   break;
                case WGGAutoKindOfficial: official++; break;
                case WGGAutoKindSystem:   sys++;      break;
                default:                  unknown++;  break;
            }
        }
        WGGLog(@"会话探测：归类分布 好友=%lu 群聊=%lu 公众号=%lu 系统=%lu 未知=%lu",
               (unsigned long)friends, (unsigned long)groups,
               (unsigned long)official, (unsigned long)sys, (unsigned long)unknown);

        // 【转储】第一个会话对象的全部成员变量（值截断 40 字符）——
        // 自绘会话 cell 要用到昵称/消息/时间/未读的真实字段名，就看这里。
        if (found.count > 0) {
            id first = found[0];
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList([first class], &ivarCount);
            WGGLog(@"会话探测：%@ 成员变量（%u 个）",
                   NSStringFromClass([first class]), ivarCount);
            unsigned int shown = ivarCount < 60 ? ivarCount : 60;
            for (unsigned int i = 0; i < shown; i++) {
                Ivar iv = ivars[i];
                const char *n = ivar_getName(iv);
                const char *t = ivar_getTypeEncoding(iv);
                NSString *val = @"(标量)";
                if (t && (t[0] == '@' || t[0] == '#')) {
                    id v = object_getIvar(first, iv);
                    if (!v) val = @"(nil)";
                    else if ([v isKindOfClass:[NSString class]]) {
                        NSString *s = (NSString *)v;
                        NSString *trim = s.length > 40 ? [s substringToIndex:40] : s;
                        val = [NSString stringWithFormat:@"\"%@\"", trim];
                    }
                    else if ([v isKindOfClass:[NSNumber class]]) val = [v description];
                    else if ([v isKindOfClass:[NSDate class]]) val = [v description];
                    else val = [NSString stringWithFormat:@"<%@>", NSStringFromClass([v class])];
                }
                WGGLog(@"   %s (%s) = %@", n ? n : "?", t ? t : "?", val);
            }
            free(ivars);
        }

        // 【转储】"打开聊天"候选方法（会话行点击修复的下一步依据）
        WGGSafeDumpMethods(NSClassFromString(@"NewMainFrameViewController"),
                           @"NewMainFrameViewController",
                           @[ @"session", @"chat", @"click", @"open", @"select", @"enter", @"push", @"tap" ]);
        WGGSafeDumpMethods(NSClassFromString(@"MainFrameLogicController"),
                           @"MainFrameLogicController",
                           @[ @"session", @"chat", @"click", @"open", @"select", @"enter", @"push" ]);
        WGGSafeDumpMethods(NSClassFromString(@"MainFrameCellDataManager"),
                           @"MainFrameCellDataManager",
                           @[ @"session", @"chat", @"click", @"open", @"select" ]);
    }
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
void WGGProbeConversations(void) {}
#endif
