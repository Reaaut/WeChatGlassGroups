//
//  GroupStore.m
//  WeChatGlassGroups
//

#import "GroupStore.h"
#import "Discovery.h"

@implementation WGGFilterResult
+ (instancetype)resultWithFiltered:(NSArray *)filtered
                           indices:(NSArray<NSNumber *> *)indices
                            active:(BOOL)active {
    WGGFilterResult *r = [[WGGFilterResult alloc] init];
    if (r) {
        r->_filtered = [filtered copy] ?: @[];
        r->_indices  = [indices copy] ?: @[];
        r->_active   = active;
    }
    return r;
}
@end

@interface WGGGroupStore ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *map; // key -> groupName
@end

@implementation WGGGroupStore

+ (instancetype)shared {
    static WGGGroupStore *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[WGGGroupStore alloc] init];
        [inst load];
    });
    return inst;
}

- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *saved = [d objectForKey:WGGDefaultsKeyGroupMap];
    _map = [NSMutableDictionary dictionary];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        [saved enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
                self.map[k] = v;
            }
        }];
    }
    NSNumber *enabled = [d objectForKey:WGGDefaultsKeyEnabled];
    _enabled = enabled ? enabled.boolValue : YES;   // 默认开启
    NSNumber *sel = [d objectForKey:WGGDefaultsKeySelectedGroup];
    _selectedGroup = sel ? (WGGGroup)sel.integerValue : WGGGroupChats;
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.map forKey:WGGDefaultsKeyGroupMap];
    [d setBool:self.enabled forKey:WGGDefaultsKeyEnabled];
    [d setInteger:self.selectedGroup forKey:WGGDefaultsKeySelectedGroup];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self save];
}

- (void)setSelectedGroup:(WGGGroup)selectedGroup {
    _selectedGroup = selectedGroup;
    [self save];
}

- (WGGGroup)groupForConversationKey:(NSString *)key {
    if (key.length == 0) return WGGGroupChats;
    NSString *name = self.map[key];
    return name ? WGGGroupFromName(name) : WGGGroupChats;   // 新会话默认 Chats
}

- (void)setGroup:(WGGGroup)group forConversationKey:(NSString *)key {
    if (key.length == 0) return;
    self.map[key] = WGGGroupName(group);
    [self save];
}

// ---------------------------------------------------------------------------
// 从微信对象里"尽力"提取信息。全部走 KVC，取不到就返回 nil。
// 这些 key 是常见候选，真名以真机探测结果为准（见 Discovery 模块的日志）。
// ---------------------------------------------------------------------------

static id WGGSafeValue(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(k)]) {
                id v = [obj valueForKey:k];
                if (v && ![v isKindOfClass:[NSNull class]]) return v;
            }
        } @catch (NSException *e) {
            // 忽略：微信对象可能对某些 key 抛异常
        }
    }
    return nil;
}

+ (NSString *)keyForConversation:(id)conversation {
    id v = WGGSafeValue(conversation, @[ @"wxid", @"m_nsUsrName", @"userName", @"username",
                                        @"sessionId", @"m_nsUserName", @"UsrName", @"identifier" ]);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;

    // 有些版本的会话对象把标识藏在子对象里
    id inner = WGGSafeValue(conversation, @[ @"contact", @"m_contact", @"sessionInfo" ]);
    if (inner && inner != conversation) {
        NSString *k = [self keyForConversation:inner];
        if (k.length) return k;
    }
    return nil;
}

+ (NSString *)displayNameForConversation:(id)conversation {
    id v = WGGSafeValue(conversation, @[ @"nickName", @"m_nsNickName", @"displayName",
                                         @"title", @"name", @"m_nsRemark" ]);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    return nil;
}

// ---------------------------------------------------------------------------

- (WGGFilterResult *)filterConversations:(NSArray *)conversations {
    if (![conversations isKindOfClass:[NSArray class]] || conversations.count == 0) {
        return [WGGFilterResult resultWithFiltered:@[] indices:@[] active:NO];
    }

    // "全部" 或 未开启分组：原样返回，不做任何事 —— 最安全
    if (self.selectedGroup == WGGGroupAll || !self.isEnabled) {
        NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:conversations.count];
        for (NSUInteger i = 0; i < conversations.count; i++) [idx addObject:@(i)];
        return [WGGFilterResult resultWithFiltered:conversations indices:idx active:NO];
    }

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
    for (NSUInteger i = 0; i < conversations.count; i++) {
        id conv = conversations[i];
        NSString *key = [WGGGroupStore keyForConversation:conv];
        if (key.length == 0) {
            // 认不出来的会话：为了不"弄丢"用户的消息，归到 Chats（默认组）
            if (self.selectedGroup == WGGGroupChats) {
                [out addObject:conv];
                [idx addObject:@(i)];
            }
            continue;
        }
        if ([self groupForConversationKey:key] == self.selectedGroup) {
            [out addObject:conv];
            [idx addObject:@(i)];
        }
    }
    return [WGGFilterResult resultWithFiltered:out indices:idx active:YES];
}

- (NSDictionary<NSNumber *, NSNumber *> *)countsForConversations:(NSArray *)conversations {
    NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSInteger g = 0; g < WGGGroupCount; g++) counts[@(g)] = @0;

    if (![conversations isKindOfClass:[NSArray class]]) return counts;

    NSUInteger all = conversations.count;
    counts[@(WGGGroupAll)] = @(all);
    for (id conv in conversations) {
        NSString *key = [WGGGroupStore keyForConversation:conv];
        WGGGroup g = key.length ? [self groupForConversationKey:key] : WGGGroupChats;
        counts[@(g)] = @([counts[@(g)] integerValue] + 1);
    }
    return counts;
}

- (NSDictionary<NSNumber *, NSNumber *> *)unreadCountsForConversations:(NSArray *)conversations {
    NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSInteger g = 0; g < WGGGroupCount; g++) counts[@(g)] = @0;
    if (![conversations isKindOfClass:[NSArray class]]) return counts;

    for (id conv in conversations) {
        id unread = WGGSafeValue(conv, @[ @"unreadCount", @"m_uUnReadCount", @"unReadCount", @"nUnReadCount" ]);
        NSInteger n = 0;
        if ([unread respondsToSelector:@selector(integerValue)]) n = [unread integerValue];
        if (n <= 0) continue;

        NSString *key = [WGGGroupStore keyForConversation:conv];
        WGGGroup g = key.length ? [self groupForConversationKey:key] : WGGGroupChats;
        counts[@(g)] = @([counts[@(g)] integerValue] + n);
    }
    // "全部" = 各组之和
    NSInteger sum = 0;
    for (NSInteger g = 0; g < WGGGroupCount; g++) sum += [counts[@(g)] integerValue];
    counts[@(WGGGroupAll)] = @(sum);
    return counts;
}

@end
