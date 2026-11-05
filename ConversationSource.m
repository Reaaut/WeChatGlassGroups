//
// ConversationSource.m
// WCGlass Offline — conservative, verified session collector
//
// 设计原则：只读微信逻辑层；未就绪/未验证/数据不稳定时返回 nil，
// 让原生列表继续工作。绝不通过滚动实例化 cell 来猜测全量会话。
//

#import "ConversationSource.h"
#import "GroupStore.h"
#import "Discovery.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSArray *gPublishedSessions = nil;       // +1, immutable snapshot
static NSString *gPublishedFingerprint = nil;  // +1
static NSString *gPendingFingerprint = nil;    // +1
static NSUInteger gPendingCount = 0;
static BOOL gRetryScheduled = NO;
static NSUInteger gRetryAttempts = 0;
static BOOL gRefreshInProgress = NO;
static NSUInteger gGeneration = 0;


static void WGGCSLog(NSString *message) {
    if ([message length]) WGGLogMessage([@"[SessionSource] " stringByAppendingString:message]);
}

static id WGGCSReadIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding || encoding[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static UITableView *WGGCSFindMainTable(UIView *root) {
    if (!root) return nil;
    UITableView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = [stack lastObject];
        [stack removeLastObject];
        if ([view isKindOfClass:[UITableView class]]) {
            NSString *name = NSStringFromClass([view class]);
            if ([name isEqualToString:@"MainFrameTableView"]) {
                CGRect frame = [view convertRect:view.bounds toView:nil];
                CGFloat area = frame.size.width * frame.size.height;
                if (area > bestArea) { bestArea = area; best = (UITableView *)view; }
            }
        }
        for (UIView *child in view.subviews) [stack addObject:child];
    }
    return best;
}

static NSString *WGGCSFingerprint(NSArray *sessions) {
    NSMutableArray *keys = [NSMutableArray arrayWithCapacity:sessions.count];
    for (id session in sessions) {
        NSString *key = [WGGGroupStore keyForConversation:session];
        if (key.length) [keys addObject:key];
    }
    // 顺序也参与指纹：微信重排会使快照失效。
    return [NSString stringWithFormat:@"%lu:%lu:%@", (unsigned long)sessions.count,
            (unsigned long)keys.count, [keys componentsJoinedByString:@"|"]];
}

static BOOL WGGCSControllerReady(id controller, UITableView **tableOut, id *logicOut) {
    if (!controller || ![controller isKindOfClass:[UIViewController class]]) return NO;
    WGGCSLog([NSString stringWithFormat:@"controller check: %@", NSStringFromClass([controller class])]);
    UIViewController *vc = (UIViewController *)controller;
    if (!vc.isViewLoaded || !vc.view.window) return NO;
    if (![NSStringFromClass([vc class]) isEqualToString:@"NewMainFrameViewController"]) return NO;

    UITableView *table = WGGCSFindMainTable(vc.view);
    if (!table || !table.window || table.dataSource != controller) return NO;

    id logic = WGGCSReadIvar(controller, "m_mainFrameLogicController");
    if (!logic) return NO;

    SEL readySel = NSSelectorFromString(@"hasLoadSessionData");
    if ([logic respondsToSelector:readySel]) {
        BOOL ready = ((BOOL (*)(id, SEL))objc_msgSend)(logic, readySel);
        if (!ready) return NO;
    }

    SEL countSel = NSSelectorFromString(@"getSessionCountForSection:");
    SEL itemSel = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    BOOL hasCount = [logic respondsToSelector:countSel];
    BOOL hasItem = [logic respondsToSelector:itemSel];
    WGGCSLog([NSString stringWithFormat:@"logic=%@ hasCount=%@ hasItem=%@", NSStringFromClass([logic class]), hasCount ? @"YES" : @"NO", hasItem ? @"YES" : @"NO"]);
    if (!hasCount || !hasItem) return NO;

    if (tableOut) *tableOut = table;
    if (logicOut) *logicOut = logic;
    return YES;
}

static NSArray *WGGCSCollect(id logic, NSUInteger *readableKeysOut) {
    SEL countSel = NSSelectorFromString(@"getSessionCountForSection:");
    SEL itemSel = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    NSInteger (*countFn)(id, SEL, NSUInteger) = (NSInteger (*)(id, SEL, NSUInteger))objc_msgSend;
    id (*itemFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger readable = 0;
    NSUInteger emptySections = 0;

    @try {
        for (NSUInteger section = 0; section < 16; section++) {
            WGGCSLog([NSString stringWithFormat:@"before count selector section=%lu", (unsigned long)section]);
            NSInteger rows = countFn(logic, countSel, section);
            WGGCSLog([NSString stringWithFormat:@"after count selector section=%lu rows=%ld", (unsigned long)section, (long)rows]);
            if (rows <= 0) {
                if (++emptySections >= 3) break;
                continue;
            }
            emptySections = 0;
            if (rows > 2000 || sessions.count + (NSUInteger)rows > 5000) return nil;

            for (NSUInteger row = 0; row < (NSUInteger)rows; row++) {
                NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:(NSInteger)section];
                if ((row % 25) == 0) WGGCSLog([NSString stringWithFormat:@"item checkpoint section=%lu row=%lu indexClass=%@", (unsigned long)section, (unsigned long)row, NSStringFromClass([path class])]);
                id session = itemFn(logic, itemSel, path);
                if (!session) continue;
                NSString *key = [WGGGroupStore keyForConversation:session];
                if (key.length) {
                    if ([seen containsObject:key]) continue;
                    [seen addObject:key];
                    readable++;
                }
                [sessions addObject:session];
            }
        }
    } @catch (NSException *exception) {
        WGGCSLog([NSString stringWithFormat:@"enumeration exception: %@", exception.name]);
        return nil;
    }

    if (readableKeysOut) *readableKeysOut = readable;
    if (sessions.count == 0 || readable * 4 < sessions.count * 3) return nil;
    return [NSArray arrayWithArray:sessions];
}

static void WGGCSScheduleRetry(id controller, NSTimeInterval delay) {
    if (gRetryScheduled || !controller || gRetryAttempts >= 8) return;
    static const NSTimeInterval backoff[] = {0.35, 0.55, 0.85, 1.3, 2.0, 3.0, 4.0, 4.0};
    NSTimeInterval wait = backoff[gRetryAttempts++];
    if (delay > wait) wait = delay;
    gRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gRetryScheduled = NO;
        [WGGConversationSource conversationsForViewController:controller];
    });
}

@implementation WGGConversationSource

+ (NSArray *)conversationsForViewController:(id)controller {
    if (!controller) return nil;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self conversationsForViewController:controller];
        });
        return gPublishedSessions;
    }

    if ([self isSearchingViewController:controller]) return nil;
    if (gRefreshInProgress) return gPublishedSessions;
    gRefreshInProgress = YES;

    UITableView *table = nil;
    id logic = nil;
    if (!WGGCSControllerReady(controller, &table, &logic)) {
        gRefreshInProgress = NO;
        WGGCSLog(@"host not ready; native list untouched, retry scheduled");
        WGGCSScheduleRetry(controller, 0.45);
        return nil;
    }

    gRetryAttempts = 0;
    NSUInteger readable = 0;
    NSArray *fresh = WGGCSCollect(logic, &readable);
    if (!fresh) {
        gRefreshInProgress = NO;
        WGGCSLog(@"snapshot failed validation; native list untouched");
        WGGCSScheduleRetry(controller, 0.8);
        return nil;
    }

    NSString *fingerprint = WGGCSFingerprint(fresh);
    if ([fingerprint isEqualToString:gPublishedFingerprint]) {
        gRefreshInProgress = NO;
        return gPublishedSessions;
    }

    // 采用双快照确认：连续两次枚举数量和用户名顺序一致，才发布。
    if ([fingerprint isEqualToString:gPendingFingerprint] && fresh.count == gPendingCount) {
        [gPublishedSessions release];
        gPublishedSessions = [fresh copy];
        [gPublishedFingerprint release];
        gPublishedFingerprint = [fingerprint copy];
        [gPendingFingerprint release];
        gPendingFingerprint = nil;
        gPendingCount = 0;
        gGeneration++;
        WGGCSLog([NSString stringWithFormat:@"stable snapshot published: sessions=%lu readable=%lu generation=%lu",
                  (unsigned long)fresh.count, (unsigned long)readable, (unsigned long)gGeneration]);
        gRefreshInProgress = NO;
        // 让当前首页立即重新走数据源；如果列表已离开 window，UIKit 会自行忽略。
        WGGCSLog(@"before table reloadData after stable snapshot");
        [table reloadData];
        WGGCSLog(@"after table reloadData");
        return gPublishedSessions;
    }

    [gPendingFingerprint release];
    gPendingFingerprint = [fingerprint copy];
    gPendingCount = fresh.count;
    gRefreshInProgress = NO;
    WGGCSLog([NSString stringWithFormat:@"candidate snapshot: sessions=%lu readable=%lu; awaiting confirmation",
              (unsigned long)fresh.count, (unsigned long)readable]);
    WGGCSScheduleRetry(controller, 0.35);
    return nil;
}

+ (BOOL)isSearchingViewController:(id)controller {
    if (!controller) return NO;
    SEL selector = NSSelectorFromString(@"isSearching");
    if (![controller respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(controller, selector);
    } @catch (__unused NSException *exception) {
        return YES; // 无法判断时保守让原生搜索接管
    }
}

@end
