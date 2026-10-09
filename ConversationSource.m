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

#pragma mark - 全量会话（类型编码验证过的安全枚举）

// 【0.3.8 方案】0.3.7 对账实锤：原生表格 ~695 行 vs front 数组 15 条——
// 全量数据在逻辑层的 filtered 会话列表里（getFilteredSessionCount /
// getFilteredSessionInfo:）。安全铁律（0.3.6 闪退的教训）：
//   ① 只碰"参数是整数索引"的方法——先用类型编码验证，对象参数一律不猜；
//   ② hasLoadSessionData==YES 才动手；搜索态绝不动；
//   ③ 整个枚举 @try 包住；首个会话用户名读不出 → 永久禁用（对账行兜底）；
//   ④ 结果缓存，filtered 总数变了才重枚举。
static NSArray *gAllSessionsCache = nil;         // +1，MRC
static unsigned long long gAllSessionCount = 0;  // 上次枚举时的 filtered 总数
static BOOL gAllSessionsDisabled = NO;           // 不安全 → 永久禁用

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

/// 枚举 filtered 全列表。返回自动释放数组；任何不安全都返回 nil。
static NSArray *WGGEnumerateFilteredSessions(id logic) {
    @autoreleasepool {
        if (!logic || gAllSessionsDisabled) return nil;
        SEL selCnt = NSSelectorFromString(@"getFilteredSessionCount");
        SEL selGet = NSSelectorFromString(@"getFilteredSessionInfo:");
        if (![logic respondsToSelector:selCnt] || ![logic respondsToSelector:selGet]) return nil;
        if (!WGGMethodTakesIntegerArg(logic, selGet)) {
            gAllSessionsDisabled = YES;   // 参数是对象 → 不猜（0.3.6 的教训）
            WGGLogMessage(@"全量收编：getFilteredSessionInfo: 参数不是整数索引，停用（对账行兜底）");
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
            WGGLogMessage([NSString stringWithFormat:@"全量收编：枚举异常（停用）：%@", e]);
            gAllSessionsDisabled = YES;
            return nil;
        }
        return out;
    }
}

/// 校验 + 合并：front 优先（展示字段最全），filtered 补缺（按用户名去重）。
/// 用户名连续读不出 → 字段不适配，整体停用。
static NSArray *WGGMergeFrontWithAll(NSArray *front, NSArray *all) {
    // 先校验前 3 个的键可读性
    NSUInteger checkN = all.count < 3 ? all.count : 3;
    NSUInteger readable = 0;
    for (NSUInteger i = 0; i < checkN; i++) {
        if ([WGGGroupStore keyForConversation:all[i]].length > 0) readable++;
    }
    if (readable == 0) {
        gAllSessionsDisabled = YES;
        WGGLogMessage([NSString stringWithFormat:
                       @"全量收编：会话对象读不出用户名（类=%@），停用——待字段适配",
                       all.count ? NSStringFromClass([all[0] class]) : @"?"]);
        return front;
    }

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
                       @"全量收编：front=%lu + filtered 补=%lu → 共 %lu（原生总行数对账见对账行）",
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

    // 4) 全量收编：逻辑层 filtered 列表 ≈ 原生表格全部行（0.3.7 对账：
    //    原生 ~695 vs front 15）。四重安全门（见上方说明）。
    if (!gAllSessionsDisabled && ![self isSearchingViewController:vc]) {
        Ivar lv = class_getInstanceVariable([vc class], "m_mainFrameLogicController");
        id logic = lv ? object_getIvar(vc, lv) : nil;
        if (logic) {
            SEL selReady = NSSelectorFromString(@"hasLoadSessionData");
            BOOL ready = YES;
            if ([logic respondsToSelector:selReady]) {
                ready = ((BOOL (*)(id, SEL))objc_msgSend)(logic, selReady);
            }
            if (ready) {
                SEL selCnt = NSSelectorFromString(@"getFilteredSessionCount");
                if ([logic respondsToSelector:selCnt]) {
                    unsigned long long n = ((unsigned long long (*)(id, SEL))objc_msgSend)(logic, selCnt);
                    if (n > 0 && n <= 5000 && (n != gAllSessionCount || !gAllSessionsCache)) {
                        NSArray *fresh = WGGEnumerateFilteredSessions(logic);
                        if (fresh.count > 0) {
                            [gAllSessionsCache release];
                            gAllSessionsCache = [fresh retain];
                            gAllSessionCount = n;
                        }
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
