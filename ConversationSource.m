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

#pragma mark - 对外接口

@implementation WGGConversationSource

+ (NSArray *)conversationsForViewController:(id)vc {
    if (!vc) return nil;

    // 1) 已有缓存路径 → 直接走（快路径，每次 reload 都会走这里）
    if (gIvarPath && gOwnerClassName) {
        NSString *cls = NSStringFromClass([vc class]);
        if ([gOwnerClassName isEqualToString:cls]) {
            id val = WGGObjectAtIvarPath(vc, gIvarPath);
            if ([val isKindOfClass:[NSArray class]] && [(NSArray *)val count] > 0) {
                return (NSArray *)val;
            }
        }
        // 路径失效（换实例/微信更新）→ 重新发现
    }

    // 2) 重新发现：递归收集候选，选"分数最高"（元素多 + 名字像会话数组）
    NSMutableArray *results = [NSMutableArray array];
    WGGCollectArrayCandidates(vc, [NSArray array], 0, results);
    if (results.count == 0) return nil;

    NSUInteger best = 0;
    for (NSUInteger i = 1; i < results.count; i++) {
        if ([results[i][@"score"] integerValue] > [results[best][@"score"] integerValue]) best = i;
    }
    NSArray *path = results[best][@"path"];
    NSArray *arr = results[best][@"arr"];

    // 3) 缓存路径（MRC：先放旧值）
    [gIvarPath release];
    gIvarPath = [[NSArray alloc] initWithArray:path];
    [gOwnerClassName release];
    gOwnerClassName = [[NSString alloc] initWithString:NSStringFromClass([vc class])];

    return arr;
}

+ (BOOL)isSearchingViewController:(id)vc {
    if (!vc) return NO;
    SEL sel = NSSelectorFromString(@"isSearching");   // 属性表里实锤存在
    if (![vc respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(vc, sel);
}

@end
