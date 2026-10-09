//
//  ConversationSource.m
//  WeChatGlassGroups
//
//  实现说明见头文件。MRC：-fno-objc-arc。
//

#import "ConversationSource.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Discovery.h"   // WGGLogMessage（落文件日志）
#import "GroupStore.h"  // keyForConversation（全量合并去重用）

// 已解析的 ivar 路径：如 @[@"m_mainFrameLogicController", @"m_arrData"]。
// MRC：alloc/init 产物，static 持有，替换时先 release。
static NSArray<NSString *> *gIvarPath = nil;
static NSString *gOwnerClassName = nil;   // 路径归属的 VC 类名（换类即重新发现）

#pragma mark - 基础工具

/// 按 ivar 路径逐层原始读取（不走 KVC、不触发任何方法）。
static id WGGObjectAtIvarPath(id root, NSArray<NSString *> *path) {
    id cur = root;
    for (NSString *name in path) {
        if (!cur || name.length == 0) return nil;
        Ivar iv = class_getInstanceVariable([cur class], name.UTF8String);
        if (!iv) return nil;
        const char *t = ivar_getTypeEncoding(iv);
        if (!t || t[0] != '@') return nil;
        cur = object_getIvar(cur, iv);
    }
    return cur;
}

/// 首元素是不是业务对象（非 NS__/UI/WK 开头）。
static BOOL WGGBusinessArray(NSArray *arr) {
    if (arr.count == 0) return NO;
    id first = arr[0];
    if (!first) return NO;
    NSString *fc = NSStringFromClass([first class]);
    return !([fc hasPrefix:@"NS"] || [fc hasPrefix:@"__"] ||
             [fc hasPrefix:@"UI"] || [fc hasPrefix:@"WK"]);
}

/// 数组名加分：像会话数组的名字优先（arr/data/session/conversation/list）。
static NSInteger WGGNameBonus(NSString *lower) {
    NSInteger b = 0;
    if ([lower rangeOfString:@"arr"].location != NSNotFound) b += 10000;
    if ([lower rangeOfString:@"data"].location != NSNotFound) b += 10000;
    if ([lower rangeOfString:@"session"].location != NSNotFound) b += 8000;
    if ([lower rangeOfString:@"conversation"].location != NSNotFound) b += 8000;
    if ([lower rangeOfString:@"list"].location != NSNotFound) b += 4000;
    return b;
}

#pragma mark - 递归收集候选

/// 收集 obj 及其逻辑/数据子对象上所有"有内容的业务数组"。
/// prefix：从 vc 到 obj 的 ivar 名路径；results：收集结果（path/score/arr）。
static void WGGCollectArrayCandidates(id obj, NSArray<NSString *> *prefix,
                                      int depth, NSMutableArray *results) {
    if (!obj || depth > 2 || results.count > 40) return;
    Class c = [obj class];
    NSMutableArray *hopHighNames = [NSMutableArray array];
    NSMutableArray *hopHighObjs = [NSMutableArray array];
    NSMutableArray *hopLowNames = [NSMutableArray array];
    NSMutableArray *hopLowObjs = [NSMutableArray array];
    int scanned = 0;

    while (c && scanned < 3) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *tEnc = ivar_getTypeEncoding(ivars[i]);
            const char *nEnc = ivar_getName(ivars[i]);
            if (!tEnc || tEnc[0] != '@' || !nEnc) continue;
            NSString *name = [NSString stringWithUTF8String:nEnc];
            id val = object_getIvar(obj, ivars[i]);        // 原始读取，零副作用
            if (!val) continue;

            if ([val isKindOfClass:[NSArray class]]) {
                NSArray *arr = (NSArray *)val;
                if (arr.count == 0) continue;
                id first = arr[0];
                if (!first) continue;
                NSString *fc = NSStringFromClass([first class]);
                // 排除系统容器和字符串/字典等（不会是会话模型）
                if ([first isKindOfClass:[NSString class]] ||
                    [first isKindOfClass:[NSDictionary class]] ||
                    [first isKindOfClass:[NSNumber class]]) continue;
                if ([fc hasPrefix:@"NS"] || [fc hasPrefix:@"__"] ||
                    [fc hasPrefix:@"UI"] || [fc hasPrefix:@"WK"]) continue;

                NSString *lower = name.lowercaseString;
                NSInteger score = (NSInteger)arr.count + WGGNameBonus(lower);
                NSMutableArray *p = [NSMutableArray arrayWithArray:prefix];
                [p addObject:name];
                [results addObject:@{ @"path": p,
                                      @"score": @(score),
                                      @"arr": arr }];
                continue;
            }

            // 值得深挖的子对象：逻辑/数据管理类（跳过视图、控制器）
            BOOL isView = [val isKindOfClass:[UIView class]];
            BOOL isVC   = [val isKindOfClass:[UIViewController class]];
            if (isView || isVC) continue;
            NSString *vcName = NSStringFromClass([val class]);
            BOOL high = [vcName rangeOfString:@"LogicController"].location != NSNotFound ||
                        [vcName rangeOfString:@"DataManager"].location != NSNotFound ||
                        [vcName rangeOfString:@"CellData"].location != NSNotFound;
            BOOL low  = [vcName rangeOfString:@"Logic"].location != NSNotFound ||
                        [vcName rangeOfString:@"Manager"].location != NSNotFound ||
                        [vcName rangeOfString:@"Store"].location != NSNotFound;
            NSMutableArray *p = [NSMutableArray arrayWithArray:prefix];
            [p addObject:name];
            if (high) {
                [hopHighNames addObject:p];
                [hopHighObjs addObject:val];
            } else if (low && hopLowObjs.count < 2) {
                [hopLowNames addObject:p];
                [hopLowObjs addObject:val];
            }
        }
        free(ivars);
        c = class_getSuperclass(c);
        scanned++;
    }

    for (NSUInteger i = 0; i < hopHighObjs.count; i++) {
        WGGCollectArrayCandidates(hopHighObjs[i], hopHighNames[i], depth + 1, results);
    }
    for (NSUInteger i = 0; i < hopLowObjs.count; i++) {
        WGGCollectArrayCandidates(hopLowObjs[i], hopLowNames[i], depth + 1, results);
    }
}

#pragma mark - 全量会话（双方案：filtered 列表 / 索引路径构造）

// 【0.3.8 实锤】filtered 方案被静默跳过（无任何日志）——filtered 大概率是
// 搜索过滤列表，平时=0。0.3.9：每个跳过路径都打日志 + 新增方案 B
// （索引路径构造枚举，带"黄金验证"：必须枚举出 front 已知的会话才放行）。
static NSArray *gAllSessionsCache = nil;         // +1，MRC
static unsigned long long gAllSessionCount = 0;  // 上次枚举数量
static BOOL gAllSessionsDisabled = NO;           // 不安全 → 永久禁用
static BOOL gSkipLogged = NO;                    // 跳过原因只打一次

/// 判断方法是不是"整数索引"参数。真正的参数编码从 enc[3] 开始
/// （enc[0]=返回值，enc[1]=self，enc[2]=cmd）。
static BOOL WGGMethodTakesIntegerArg(id target, SEL sel) {
    Method m = class_getInstanceMethod([target class], sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || strlen(enc) < 4) return NO;
    char a = enc[3];
    return (a == 'Q' || a == 'q' || a == 'I' || a == 'i' ||
            a == 'L' || a == 'l' || a == 'B' || a == 'C' || a == 'c');
}

static BOOL WGGIsIntEncoding(char c) {
    return (c == 'Q' || c == 'q' || c == 'I' || c == 'i' ||
            c == 'L' || c == 'l' || c == 'B' || c == 'C' || c == 'c');
}

/// 方案 A：枚举 filtered 全列表（参数必须是整数索引）。
static NSArray *WGGEnumerateFilteredSessions(id logic) {
    @autoreleasepool {
        if (!logic || gAllSessionsDisabled) return nil;
        SEL selCnt = NSSelectorFromString(@"getFilteredSessionCount");
        SEL selGet = NSSelectorFromString(@"getFilteredSessionInfo:");
        if (![logic respondsToSelector:selCnt] || ![logic respondsToSelector:selGet]) return nil;
        if (!WGGMethodTakesIntegerArg(logic, selGet)) {
            gAllSessionsDisabled = YES;
            WGGLogMessage(@"全量收编A：getFilteredSessionInfo: 参数不是整数索引，停用");
            return nil;
        }

        unsigned long long total = ((unsigned long long (*)(id, SEL))objc_msgSend)(logic, selCnt);
        if (total <= 0 || total > 5000) return nil;

        NSMutableArray *out = [NSMutableArray array];
        @try {
            typedef id (*GetFn)(id, SEL, unsigned long long);
            GetFn fn = (GetFn)objc_msgSend;
            for (unsigned long long i = 0; i < total; i++) {
                id s = fn(logic, selGet, i);
                if (s) [out addObject:s];
            }
        } @catch (NSException *e) {
            WGGLogMessage([NSString stringWithFormat:@"全量收编A：枚举异常（停用）：%@", e]);
            gAllSessionsDisabled = YES;
            return nil;
        }
        return out;
    }
}

/// 在类里找"两个整数参数的 init"，名字要同时含 Section（或 Part）和 Row。
/// 找不到返回 NULL。纯只读扫描，零风险。
static SEL WGGFindTwoIntInit(Class c) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    SEL found = NULL;
    for (unsigned int i = 0; i < n && !found; i++) {
        SEL s = method_getName(ms[i]);
        const char *cn = sel_getName(s);
        if (!cn) continue;
        NSString *name = [NSString stringWithUTF8String:cn];
        if (![name hasPrefix:@"initWith"]) continue;
        const char *enc = method_getTypeEncoding(ms[i]);
        if (!enc || strlen(enc) < 5) continue;
        if (!WGGIsIntEncoding(enc[3]) || !WGGIsIntEncoding(enc[4])) continue;
        BOOL hasSection = [name rangeOfString:@"ection"].location != NSNotFound ||
                          [name rangeOfString:@"art"].location != NSNotFound;   // Part
        BOOL hasRow = [name rangeOfString:@"ow" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (hasSection && hasRow) found = s;
    }
    free(ms);
    return found;
}

/// 方案 B：索引路径构造枚举。
/// firstSessionIndexPath 拿微信自己的索引对象（0.3.6 实锤绝不能传
/// NSIndexPath——必须用它自己的类构造），扫它的 init 找构造方法，
/// 构造 (row, section) 或 (section, row) 两种顺序都试，
/// 【黄金验证】：枚举结果必须包含真索引换出的那个用户名，否则整体停用。
static NSArray *WGGEnumerateViaIndexPath(id vc, id logic) {
    @autoreleasepool {
        if (!vc || !logic || gAllSessionsDisabled) return nil;
        SEL selFirst = NSSelectorFromString(@"firstSessionIndexPath");
        SEL selGet   = NSSelectorFromString(@"logicGetSessionAtIndexPath:");
        SEL selCnt   = NSSelectorFromString(@"getSessionCountForSection:");
        SEL selIP    = NSSelectorFromString(@"indexPathOfSessionUserName:");
        if (![vc respondsToSelector:selFirst] || ![vc respondsToSelector:selGet] ||
            ![vc respondsToSelector:selIP] || ![logic respondsToSelector:selCnt]) {
            if (!gSkipLogged) {
                gSkipLogged = YES;
                WGGLogMessage(@"全量收编B：缺方法（first/logicGet/ipOf/count），停用");
            }
            return nil;
        }
        if (!WGGMethodTakesIntegerArg(logic, selCnt)) {
            gAllSessionsDisabled = YES;
            WGGLogMessage(@"全量收编B：getSessionCountForSection: 参数不是整数，停用");
            return nil;
        }

        @try {
            id realIP = ((id (*)(id, SEL))objc_msgSend)(vc, selFirst);
            if (!realIP) {
                if (!gSkipLogged) {
                    gSkipLogged = YES;
                    WGGLogMessage(@"全量收编B：firstSessionIndexPath 返回空，停用");
                }
                return nil;
            }
            Class ipCls = [realIP class];

            // ① 微信自己的索引必须换得出会话（黄金会话）
            id sess0 = ((id (*)(id, SEL, id))objc_msgSend)(vc, selGet, realIP);
            NSString *goldenKey = [WGGGroupStore keyForConversation:sess0];
            if (!goldenKey) {
                gAllSessionsDisabled = YES;
                WGGLogMessage([NSString stringWithFormat:
                               @"全量收编B：真索引换会话读不出用户名（%@），停用",
                               NSStringFromClass([sess0 class])]);
                return nil;
            }

            // ② 构造方法
            SEL ctor = WGGFindTwoIntInit(ipCls);
            if (!ctor) {
                gAllSessionsDisabled = YES;
                WGGLogMessage([NSString stringWithFormat:
                               @"全量收编B：索引类 %@ 无两整数参数的 init，停用",
                               NSStringFromClass(ipCls)]);
                return nil;
            }

            // ③ 两种参数顺序都试（row,section / section,row）
            for (int order = 0; order < 2; order++) {
                NSMutableArray *out = [NSMutableArray array];
                NSMutableSet *keys = [[NSMutableSet alloc] init];
                @try {
                    int emptyStreak = 0;
                    for (NSUInteger s = 0; s < 16; s++) {
                        NSInteger rows = ((NSInteger (*)(id, SEL, NSUInteger))objc_msgSend)(logic, selCnt, s);
                        if (rows <= 0) { if (++emptyStreak >= 3) break; continue; }
                        emptyStreak = 0;
                        if (rows > 500) rows = 500;
                        for (NSUInteger r = 0; r < (NSUInteger)rows; r++) {
                            long a = order == 0 ? (long)r : (long)s;
                            long b = order == 0 ? (long)s : (long)r;
                            id ip = ((id (*)(id, SEL, long, long))objc_msgSend)([ipCls alloc], ctor, a, b);
                            if (!ip) continue;
                            id sess = ((id (*)(id, SEL, id))objc_msgSend)(vc, selGet, ip);
                            [ip release];
                            if (sess) {
                                [out addObject:sess];
                                NSString *k = [WGGGroupStore keyForConversation:sess];
                                if (k) [keys addObject:k];
                            }
                        }
                    }
                } @catch (NSException *e) {
                    WGGLogMessage([NSString stringWithFormat:
                                   @"全量收编B：顺序%d 枚举异常：%@", order, e]);
                    [keys release];
                    continue;   // 换一种顺序再试
                }

                // 【黄金验证】必须包含真索引换出的那个用户名
                if (out.count >= 5 && [keys containsObject:goldenKey]) {
                    WGGLogMessage([NSString stringWithFormat:
                                   @"全量收编B：构造顺序=%@ 枚举=%lu 含黄金会话✓",
                                   order == 0 ? @"(row,section)" : @"(section,row)",
                                   (unsigned long)out.count]);
                    [keys release];
                    return out;
                }
                [keys release];
            }

            gAllSessionsDisabled = YES;
            WGGLogMessage(@"全量收编B：两种构造顺序都验证失败，停用（对账行兜底）");
            return nil;
        } @catch (NSException *e) {
            WGGLogMessage([NSString stringWithFormat:@"全量收编B：异常（停用）：%@", e]);
            gAllSessionsDisabled = YES;
            return nil;
        }
    }
}

/// 校验 + 合并：front 优先（展示字段最全），其余补缺（按用户名去重）。
static NSArray *WGGMergeFrontWithAll(NSArray *front, NSArray *all) {
    NSMutableSet *seen = [[NSMutableSet alloc] init];
    NSMutableArray *merged = [NSMutableArray array];
    for (id c in front) {
        NSString *k = [WGGGroupStore keyForConversation:c];
        if (k) [seen addObject:k];
        [merged addObject:c];
    }
    NSUInteger added = 0;
    for (id s in all) {
        NSString *k = [WGGGroupStore keyForConversation:s];
        if (!k || [seen containsObject:k]) continue;   // 读不出键的跳过（防 "?" 行）
        [seen addObject:k];
        [merged addObject:s];
        added++;
    }
    [seen release];

    static BOOL gLoggedOnce = NO;
    if (!gLoggedOnce) {
        gLoggedOnce = YES;
        WGGLogMessage([NSString stringWithFormat:
                       @"全量收编：front=%lu + 补=%lu → 共 %lu",
                       (unsigned long)front.count, added, (unsigned long)merged.count]);
    }
    return merged;
}

#pragma mark - 对外接口

@implementation WGGConversationSource

+ (NSArray *)conversationsForViewController:(id)vc {
    if (!vc) return nil;
    NSArray *front = nil;

    // 1) 已有缓存路径 → 直接走（快路径，每次 reload 都会走这里）
    if (gIvarPath && gOwnerClassName) {
        NSString *cls = NSStringFromClass([vc class]);
        if ([gOwnerClassName isEqualToString:cls]) {
            id val = WGGObjectAtIvarPath(vc, gIvarPath);
            if ([val isKindOfClass:[NSArray class]] && [(NSArray *)val count] > 0) {
                front = (NSArray *)val;
            }
        }
        // 路径失效（换实例/微信更新）→ 重新发现
    }

    // 2) 重新发现：递归收集候选，选"分数最高"（元素多 + 名字像会话数组）
    if (!front) {
        NSMutableArray *results = [NSMutableArray array];
        WGGCollectArrayCandidates(vc, [NSArray array], 0, results);
        if (results.count == 0) return nil;

        NSUInteger best = 0;
        for (NSUInteger i = 1; i < results.count; i++) {
            if ([results[i][@"score"] integerValue] > [results[best][@"score"] integerValue]) best = i;
        }
        NSArray *path = results[best][@"path"];
        front = results[best][@"arr"];

        // 3) 缓存路径（MRC：先放旧值）
        [gIvarPath release];
        gIvarPath = [[NSArray alloc] initWithArray:path];
        [gOwnerClassName release];
        gOwnerClassName = [[NSString alloc] initWithString:NSStringFromClass([vc class])];
    }

    // 4) 全量收编：方案 A（filtered，0.3.8 疑似搜索过滤=0 且静默跳过）
    //    → 方案 B（索引路径构造 + 黄金验证）。每个跳过路径都打日志。
    if (!gAllSessionsDisabled && ![self isSearchingViewController:vc]) {
        Ivar lv = class_getInstanceVariable([vc class], "m_mainFrameLogicController");
        id logic = lv ? object_getIvar(vc, lv) : nil;
        if (!logic) {
            if (!gSkipLogged) {
                gSkipLogged = YES;
                WGGLogMessage(@"全量收编：m_mainFrameLogicController 为空，停用");
            }
        } else {
            SEL selReady = NSSelectorFromString(@"hasLoadSessionData");
            BOOL ready = YES;
            if ([logic respondsToSelector:selReady]) {
                ready = ((BOOL (*)(id, SEL))objc_msgSend)(logic, selReady);
                if (!ready && !gSkipLogged) {
                    gSkipLogged = YES;
                    WGGLogMessage(@"全量收编：hasLoadSessionData=NO（数据未就绪）");
                }
            }
            if (ready) {
                // 方案 A：filtered 列表
                SEL selCnt = NSSelectorFromString(@"getFilteredSessionCount");
                if ([logic respondsToSelector:selCnt]) {
                    unsigned long long n = ((unsigned long long (*)(id, SEL))objc_msgSend)(logic, selCnt);
                    if (!gSkipLogged) {
                        gSkipLogged = YES;
                        WGGLogMessage([NSString stringWithFormat:
                                       @"全量收编A：getFilteredSessionCount=%llu", n]);
                    }
                    if (n > 0 && n <= 5000 && (n != gAllSessionCount || !gAllSessionsCache)) {
                        NSArray *fresh = WGGEnumerateFilteredSessions(logic);
                        if (fresh.count > 0) {
                            [gAllSessionsCache release];
                            gAllSessionsCache = [fresh retain];
                            gAllSessionCount = n;
                        }
                    }
                }
                // 方案 B：索引路径构造（A 没结果才走）
                if (!gAllSessionsCache) {
                    NSArray *fresh = WGGEnumerateViaIndexPath(vc, logic);
                    if (fresh.count > 0) {
                        [gAllSessionsCache release];
                        gAllSessionsCache = [fresh retain];
                        gAllSessionCount = fresh.count;
                    }
                }
            }
        }
    }
    if (gAllSessionsCache.count > 0) {
        return WGGMergeFrontWithAll(front, gAllSessionsCache);
    }
    return front;
}

+ (BOOL)isSearchingViewController:(id)vc {
    if (!vc) return NO;
    SEL sel = NSSelectorFromString(@"isSearching");   // 属性表里实锤存在
    if (![vc respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(vc, sel);
}

@end
