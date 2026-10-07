//
//  GroupStore.m
//  WeChatGlassGroups
//
//  【数据层】实现细节见 GroupStore.h 顶部说明。
//
//  MRC 提醒：本工程 -fno-objc-arc。
//   * 自定义 setter 里要手动 release 旧值。
//   * helper 不要返回 autorelease 对象再让调用方 release（会过度释放）。
//

#import "GroupStore.h"
#import "Discovery.h"

NSString *const WGGGroupAllName     = @"全部";
NSString *const WGGGroupFriendsName = @"好友";
NSString *const WGGGroupGroupsName  = @"群聊";

NSArray<NSString *> *WGGAutoGroupNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ WGGGroupFriendsName, WGGGroupGroupsName ];
    });
    return names;
}

// 状态键（v2：内置分组从"手动 Family/Chats/Group/Service"改成"自动 好友/群聊"）
static NSString * const kStateKey    = @"WGG.state.v2";
static NSString * const kGroupsKey   = @"groups";        // 只存自定义分组
static NSString * const kChatMapKey  = @"chatMap";       // 只对自定义分组有意义
static NSString * const kSelectedKey = @"selectedGroup";
static NSString * const kSettingsKey = @"settings";

// 旧格式的键，只用来捞回"设置项"（旧的手动归属数据直接丢弃，理由见 migrateLegacy）
static NSString * const kLegacyV1StateKey = @"WGG.state.v1";
static NSString * const kLegacyGroupMapKey = @"WGG.groupMap";
static NSString * const kLegacyEnabledKey  = @"WGG.enabled";
static NSString * const kLegacyAlphaKey    = @"WGG.blurAlpha";

// 设置项的键
static NSString * const kSetEnabled       = @"enabled";
static NSString * const kSetGlassAlpha    = @"glassAlpha";
static NSString * const kSetDrawerWidth   = @"drawerWidth";
static NSString * const kSetTriggerHidden = @"triggerButtonHidden";
static NSString * const kSetAnimated      = @"animatedPresentation";
static NSString * const kSetSearchEnabled = @"searchEnabled";
static NSString * const kSetLongPress     = @"longPressMenuEnabled";
static NSString * const kSetVerbose       = @"verboseLogging";

static const CGFloat kDefaultGlassAlpha  = 0.95;
static const CGFloat kDefaultDrawerWidth = 268.0;

// 前向声明（定义在文件后面）
static id WGGSafeValue(id obj, NSArray<NSString *> *keys);

#pragma mark - 过滤结果

@implementation WGGFilterResult

+ (instancetype)resultWithFiltered:(NSArray *)filtered
                           indices:(NSArray<NSNumber *> *)indices
                            active:(BOOL)active {
    WGGFilterResult *r = [[WGGFilterResult alloc] init];
    if (r) {
        // copy 返回 +1，直接给 readonly ivar 正好；dealloc 负责 release
        r->_filtered = filtered ? [filtered copy] : (NSArray *)@[];
        r->_indices  = indices  ? [indices copy]  : (NSArray<NSNumber *> *)@[];
        r->_active   = active;
    }
    return [r autorelease];
}

- (void)dealloc {
    [_filtered release];
    [_indices release];
    [super dealloc];
}

@end

#pragma mark - 数据仓库

@interface WGGGroupStore () {
    dispatch_queue_t _saveQueue;
}
/// 只存**自定义**分组；内置的"好友/群聊"是计算出来的，不落盘。
@property (nonatomic, strong) NSMutableArray<NSString *> *customGroups;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *chatMap;
@property (nonatomic, strong) NSMutableDictionary *settings;
@property (nonatomic, copy)   NSString *selectedGroup;

- (void)setup;
- (void)applyStateDictionary:(NSDictionary *)state;
- (void)sanitizeLocked;
- (void)migrateLegacySettings;
- (NSDictionary *)snapshot;
- (void)writeNow;
- (void)scheduleSave;
- (NSString *)normalizedGroupName:(NSString *)name;
- (id)settingForKey:(NSString *)key fallback:(id)fallback;
- (void)setSetting:(id)value forKey:(NSString *)key;
@end

@implementation WGGGroupStore

+ (instancetype)shared {
    static WGGGroupStore *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[WGGGroupStore alloc] init];
        [inst setup];
    });
    return inst;
}

- (void)setup {
    _saveQueue   = dispatch_queue_create("com.yourname.wechatglassgroups.save", DISPATCH_QUEUE_SERIAL);
    _customGroups = [[NSMutableArray alloc] init];
    _chatMap     = [[NSMutableDictionary alloc] init];
    _settings    = [[NSMutableDictionary alloc] init];
    _selectedGroup = [WGGGroupAllName copy];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *saved = [d objectForKey:kStateKey];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        [self applyStateDictionary:saved];
    } else {
        [self migrateLegacySettings];
    }

    @synchronized (self) {
        [self sanitizeLocked];
    }

    if (self.verboseLogging) {
        WGGLogMessage([NSString stringWithFormat:@"GroupStore 就绪：面板分组=%@ 选中=%@ 自定义=%lu 归属记录=%lu",
                       [self panelGroupNames], [self selectedGroupName],
                       (unsigned long)_customGroups.count, (unsigned long)_chatMap.count]);
    }

    [self scheduleSave];
}

#pragma mark - 装载 / 清洗

- (void)applyStateDictionary:(NSDictionary *)state {
    @synchronized (self) {
        id g = state[kGroupsKey];
        if ([g isKindOfClass:[NSArray class]]) {
            for (id n in (NSArray *)g) {
                if ([n isKindOfClass:[NSString class]] && [(NSString *)n length] > 0
                    && ![_customGroups containsObject:n]) {
                    [_customGroups addObject:n];
                }
            }
        }

        id cm = state[kChatMapKey];
        if ([cm isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)cm enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if (![k isKindOfClass:[NSString class]] || [(NSString *)k length] == 0) return;
                if (![v isKindOfClass:[NSArray class]]) return;
                NSMutableArray *arr = [NSMutableArray array];
                for (id n in (NSArray *)v) {
                    if ([n isKindOfClass:[NSString class]] && [(NSString *)n length] > 0
                        && ![arr containsObject:n]) {
                        [arr addObject:n];
                    }
                }
                if (arr.count > 0) self->_chatMap[(NSString *)k] = arr;
            }];
        }

        id s = state[kSelectedKey];
        if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) {
            [_selectedGroup release];
            _selectedGroup = [(NSString *)s copy];
        }

        id st = state[kSettingsKey];
        if ([st isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)st enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSNumber class]]) {
                    self->_settings[k] = v;
                }
            }];
        }
    }
}

/// 清洗：把指向"已不存在的分组"的归属记录、以及非法选中项都清掉。
/// 必须在 @synchronized(self) 内调用。
- (void)sanitizeLocked {
    // 1) 自定义分组里不能混入内置名
    NSArray *autoNames = WGGAutoGroupNames();
    for (NSString *b in autoNames) {
        while ([_customGroups containsObject:b]) [_customGroups removeObject:b];
    }
    while ([_customGroups containsObject:WGGGroupAllName]) [_customGroups removeObject:WGGGroupAllName];

    // 2) 归属记录只能指向自定义分组
    for (NSString *k in [_chatMap allKeys]) {   // allKeys 是快照，遍历中删除安全
        NSMutableArray *arr = _chatMap[k];
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *g in arr) {
            // 自动分组的归属没有意义（由标识实时算出来），一并清掉
            if ([_customGroups containsObject:g] && ![keep containsObject:g]) {
                [keep addObject:g];
            }
        }
        if (keep.count > 0) {
            _chatMap[k] = keep;
        } else {
            [_chatMap removeObjectForKey:k];
        }
    }

    // 3) 选中项必须存在
    if (![_selectedGroup isEqualToString:WGGGroupAllName]
        && ![_customGroups containsObject:_selectedGroup]
        && ![autoNames containsObject:_selectedGroup]) {
        [_selectedGroup release];
        _selectedGroup = [WGGGroupAllName copy];
    }
}

/// 从旧版本捞回**设置项**。
///
/// ⚠️ 刻意**不迁移**旧的手动分组归属：旧内置分组是 Family/Chats/Group/Service
///    那种"手动桶"，语义和现在的"自动好友/群聊"完全不同，
///    强行映射只会得到一堆莫名其妙的归属。旧数据直接丢弃更干净。
- (void)migrateLegacySettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL migrated = NO;

    // 先看 v1 整份状态里有没有设置
    NSDictionary *v1 = [d objectForKey:kLegacyV1StateKey];
    if ([v1 isKindOfClass:[NSDictionary class]]) {
        NSDictionary *st = v1[@"settings"];
        if ([st isKindOfClass:[NSDictionary class]]) {
            @synchronized (self) {
                [st enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                    if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSNumber class]]) {
                        self->_settings[k] = v;
                    }
                }];
            }
            migrated = YES;
        }
    }

    // 再看 v0 的散键
    id enabled = [d objectForKey:kLegacyEnabledKey];
    if ([enabled isKindOfClass:[NSNumber class]]) {
        @synchronized (self) { _settings[kSetEnabled] = enabled; }
        migrated = YES;
    }
    id alpha = [d objectForKey:kLegacyAlphaKey];
    if ([alpha isKindOfClass:[NSNumber class]]) {
        @synchronized (self) { _settings[kSetGlassAlpha] = alpha; }
        migrated = YES;
    }

    // 旧的散键清掉，免得下次又误判
    [d removeObjectForKey:kLegacyGroupMapKey];
    [d removeObjectForKey:kLegacyEnabledKey];
    [d removeObjectForKey:kLegacyAlphaKey];

    if (migrated) WGGLogMessage(@"已迁移旧版设置（旧的手动分组归属按设计丢弃）");
}

#pragma mark - 落盘

- (NSDictionary *)snapshot {
    @synchronized (self) {
        NSMutableDictionary *chatMap = [NSMutableDictionary dictionaryWithCapacity:_chatMap.count];
        [_chatMap enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSArray *v, BOOL *stop) {
            chatMap[k] = [v copy];
        }];
        NSString *sel = _selectedGroup ? _selectedGroup : WGGGroupAllName;
        return @{
            kGroupsKey:   [_customGroups copy],
            kChatMapKey:  chatMap,
            kSelectedKey: sel,
            kSettingsKey: [_settings copy],
        };
    }
}

- (void)writeNow {
    [[NSUserDefaults standardUserDefaults] setObject:[self snapshot] forKey:kStateKey];
}

/// 异步落盘：主线程只改内存，磁盘 I/O 丢到串行队列，绝不卡 UI。
- (void)scheduleSave {
    if (!_saveQueue) return;
    dispatch_async(_saveQueue, ^{
        [self writeNow];
    });
}

- (void)flush {
    [self writeNow];
}

#pragma mark - 分组增删改查

- (NSString *)normalizedGroupName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) return @"";
    NSString *t = [name stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t ? t : @"";
}

- (NSArray<NSString *> *)allGroupNames {
    NSMutableArray *out = [NSMutableArray arrayWithArray:WGGAutoGroupNames()];
    @synchronized (self) {
        [out addObjectsFromArray:_customGroups];
    }
    return out;
}

- (NSArray<NSString *> *)panelGroupNames {
    NSMutableArray *out = [NSMutableArray arrayWithObject:WGGGroupAllName];
    [out addObjectsFromArray:[self allGroupNames]];
    return out;
}

- (BOOL)isAutoGroup:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) return NO;
    return [WGGAutoGroupNames() containsObject:name];
}

- (BOOL)addGroupNamed:(NSString *)name {
    NSString *n = [self normalizedGroupName:name];
    if (n.length == 0) return NO;
    if ([n isEqualToString:WGGGroupAllName] || [self isAutoGroup:n]) return NO;
    BOOL ok = NO;
    @synchronized (self) {
        if (![_customGroups containsObject:n]) {
            [_customGroups addObject:n];
            ok = YES;
        }
    }
    if (ok) [self scheduleSave];
    return ok;
}

- (BOOL)removeGroupNamed:(NSString *)name {
    NSString *n = [self normalizedGroupName:name];
    if (n.length == 0 || [self isAutoGroup:n] || [n isEqualToString:WGGGroupAllName]) return NO;
    BOOL ok = NO;
    @synchronized (self) {
        if ([_customGroups containsObject:n]) {
            [_customGroups removeObject:n];
            for (NSString *k in [_chatMap allKeys]) {
                NSMutableArray *arr = _chatMap[k];
                [arr removeObject:n];
                if (arr.count == 0) [_chatMap removeObjectForKey:k];
            }
            if ([_selectedGroup isEqualToString:n]) {
                [_selectedGroup release];
                _selectedGroup = [WGGGroupAllName copy];
            }
            ok = YES;
        }
    }
    if (ok) [self scheduleSave];
    return ok;
}

- (BOOL)renameGroup:(NSString *)oldName to:(NSString *)newName {
    NSString *o = [self normalizedGroupName:oldName];
    NSString *n = [self normalizedGroupName:newName];
    if (o.length == 0 || n.length == 0) return NO;
    if ([self isAutoGroup:o] || [o isEqualToString:WGGGroupAllName]) return NO;
    if ([n isEqualToString:WGGGroupAllName] || [self isAutoGroup:n]) return NO;
    BOOL ok = NO;
    @synchronized (self) {
        NSUInteger idx = [_customGroups indexOfObject:o];
        if (idx != NSNotFound && ![n isEqualToString:o] && ![_customGroups containsObject:n]) {
            _customGroups[idx] = n;
            for (NSString *k in [_chatMap allKeys]) {
                NSMutableArray *arr = _chatMap[k];
                NSUInteger i = [arr indexOfObject:o];
                if (i != NSNotFound) arr[i] = n;
            }
            if ([_selectedGroup isEqualToString:o]) {
                [_selectedGroup release];
                _selectedGroup = [n copy];
            }
            ok = YES;
        }
    }
    if (ok) [self scheduleSave];
    return ok;
}

#pragma mark - 选中分组

- (NSString *)selectedGroupName {
    @synchronized (self) {
        return [_selectedGroup copy];
    }
}

- (void)setSelectedGroupName:(NSString *)name {
    NSString *n = [self normalizedGroupName:name];
    if (n.length == 0) n = WGGGroupAllName;
    BOOL changed = NO;
    @synchronized (self) {
        BOOL valid = [n isEqualToString:WGGGroupAllName]
                  || [WGGAutoGroupNames() containsObject:n]
                  || [_customGroups containsObject:n];
        if (!valid) n = WGGGroupAllName;      // 分组可能刚被删，非法选择一律回落
        if (![_selectedGroup isEqualToString:n]) {
            [_selectedGroup release];
            _selectedGroup = [n copy];
            changed = YES;
        }
    }
    if (changed) [self scheduleSave];
}

#pragma mark - 会话自动归类（核心）

+ (WGGAutoKind)autoKindForIdentifier:(NSString *)ident {
    if (![ident isKindOfClass:[NSString class]] || ident.length == 0) return WGGAutoKindUnknown;

    // ① 群聊：微信群的会话 id **一定**以 @chatroom 结尾。这条最可靠，优先用。
    if ([ident hasSuffix:@"@chatroom"]) return WGGAutoKindGroup;

    // ② 公众号 / 服务号：gh_ 开头
    if ([ident hasPrefix:@"gh_"]) return WGGAutoKindOfficial;

    // ③ 微信自己的系统会话，是固定的一批 id
    static NSSet *sysIDs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sysIDs = [[NSSet alloc] initWithArray:@[
            @"filehelper",            // 文件传输助手
            @"newsapp", @"fmessage", @"weixin", @"floatbottle", @"medianote",
            @"qqmail", @"tmessage", @"qmessage", @"qqsync", @"weibo",
            @"shakeapp", @"blogapp", @"facebookapp", @"masssendapp",
            @"feedsapp", @"voipapp", @"voicevoipapp", @"officialaccounts",
            @"notification_messages", @"helper_entry", @"exmail_tool",
            @"mphelper", @"weapp", @"notifymessage", @"linkedinplugin",
            @"weixinreminder", @"qqfriend",
        ]];
    });
    if ([sysIDs containsObject:ident]) return WGGAutoKindSystem;

    // ④ 其它带 @ 的内部标识（比如客服 xxx@openim、企业微信等）
    if ([ident rangeOfString:@"@"].location != NSNotFound) return WGGAutoKindSystem;

    // ⑤ 剩下的裸 id 就是普通好友
    //    （好友 wxid 通常形如 wxid_xxx / 自定义微信号，都不含 @）
    return WGGAutoKindFriend;
}

+ (WGGAutoKind)autoKindForConversation:(id)conversation {
    if (!conversation) return WGGAutoKindUnknown;

    // 先看会话对象上有没有直接的"是群聊"标记。
    // ⚠️ 只采信**正向**信号：不是群 ≠ 是好友（公众号、系统号也不是群），
    //    所以只有 YES 才直接返回，NO 要继续往下走标识判断。
    id flag = WGGSafeValue(conversation, @[ @"isGroup", @"m_bIsGroup", @"bIsGroup",
                                           @"isChatroom", @"isGroupChat", @"m_bIsChatroom" ]);
    if ([flag respondsToSelector:@selector(boolValue)] && [flag boolValue]) {
        return WGGAutoKindGroup;
    }

    // 再用标识字符串判定（最可靠的那套规则）
    NSString *ident = [self keyForConversation:conversation];
    return [self autoKindForIdentifier:ident];
}

+ (NSString *)nameForAutoKind:(WGGAutoKind)kind {
    switch (kind) {
        case WGGAutoKindFriend:   return @"好友";
        case WGGAutoKindGroup:    return @"群聊";
        case WGGAutoKindOfficial: return @"公众号";
        case WGGAutoKindSystem:   return @"系统";
        case WGGAutoKindUnknown:  return @"未知";
    }
    return @"未知";
}

#pragma mark - 会话归属（只对自定义分组有意义）

- (NSArray<NSString *> *)groupsForChatKey:(NSString *)key {
    if (key.length == 0) return @[];
    @synchronized (self) {
        NSArray *arr = _chatMap[key];
        return arr ? [arr copy] : (NSArray *)@[];
    }
}

- (BOOL)isChatKey:(NSString *)key inGroup:(NSString *)group {
    if (key.length == 0 || group.length == 0) return NO;
    return [[self groupsForChatKey:key] containsObject:group];
}

- (void)addChatKey:(NSString *)key toGroup:(NSString *)group {
    if (key.length == 0 || group.length == 0) return;
    if ([group isEqualToString:WGGGroupAllName] || [self isAutoGroup:group]) return;  // 自动分组不接受手动归属
    BOOL changed = NO;
    @synchronized (self) {
        if (![_customGroups containsObject:group]) return;
        NSMutableArray *arr = _chatMap[key];
        if (!arr) {
            arr = [NSMutableArray array];
            _chatMap[key] = arr;
        }
        if (![arr containsObject:group]) {
            [arr addObject:group];
            changed = YES;
        }
    }
    if (changed) [self scheduleSave];
}

- (void)removeChatKey:(NSString *)key fromGroup:(NSString *)group {
    if (key.length == 0 || group.length == 0) return;
    BOOL changed = NO;
    @synchronized (self) {
        NSMutableArray *arr = _chatMap[key];
        if (arr && [arr containsObject:group]) {
            [arr removeObject:group];
            if (arr.count == 0) [_chatMap removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) [self scheduleSave];
}

- (BOOL)toggleChatKey:(NSString *)key inGroup:(NSString *)group {
    if ([self isChatKey:key inGroup:group]) {
        [self removeChatKey:key fromGroup:group];
        return NO;
    }
    [self addChatKey:key toGroup:group];
    return [self isChatKey:key inGroup:group];
}

- (void)removeChatKeyFromAllGroups:(NSString *)key {
    if (key.length == 0) return;
    BOOL changed = NO;
    @synchronized (self) {
        if (_chatMap[key]) {
            [_chatMap removeObjectForKey:key];
            changed = YES;
        }
    }
    if (changed) [self scheduleSave];
}

#pragma mark - 从微信对象取值（KVC + 保护）

static id WGGSafeValue(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(k)]) {
                id v = [obj valueForKey:k];
                if (v && ![v isKindOfClass:[NSNull class]]) return v;
            }
        } @catch (NSException *e) {
            // 微信对象对某些 key 会抛异常，忽略继续试下一个
        }
    }
    return nil;
}

+ (NSString *)keyForConversation:(id)conversation {
    // 顺序有讲究：先试会话自己的标识字段
    id v = WGGSafeValue(conversation, @[ @"wxid", @"m_nsUsrName", @"userName", @"username",
                                         @"sessionId", @"m_nsUserName", @"UsrName",
                                         @"identifier", @"m_nsSessionId" ]);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;

    // 有些版本把标识藏在子对象里
    id inner = WGGSafeValue(conversation, @[ @"contact", @"m_contact", @"sessionInfo" ]);
    if (inner && inner != conversation) {
        NSString *k = [self keyForConversation:inner];
        if (k.length > 0) return k;
    }
    return nil;
}

+ (NSString *)displayNameForConversation:(id)conversation {
    id v = WGGSafeValue(conversation, @[ @"nickName", @"m_nsNickName", @"displayName",
                                         @"title", @"name", @"m_nsRemark" ]);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    return nil;
}

#pragma mark - 过滤

- (WGGFilterResult *)filterConversations:(NSArray *)conversations {
    if (![conversations isKindOfClass:[NSArray class]]) {
        return [WGGFilterResult resultWithFiltered:@[] indices:@[] active:NO];
    }

    NSString *sel = [self selectedGroupName];

    // 不过滤的三种情况：总开关关了 / 选了"全部" / 本来就没会话
    if (!self.isEnabled || [sel isEqualToString:WGGGroupAllName] || conversations.count == 0) {
        NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:conversations.count];
        for (NSUInteger i = 0; i < conversations.count; i++) [idx addObject:@(i)];
        return [WGGFilterResult resultWithFiltered:conversations indices:idx active:NO];
    }

    // 自动分组 → 实时归类；自定义分组 → 查归属表
    BOOL autoMode = NO;
    WGGAutoKind wantKind = WGGAutoKindUnknown;
    if ([sel isEqualToString:WGGGroupFriendsName]) {
        autoMode = YES; wantKind = WGGAutoKindFriend;
    } else if ([sel isEqualToString:WGGGroupGroupsName]) {
        autoMode = YES; wantKind = WGGAutoKindGroup;
    }

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
    for (NSUInteger i = 0; i < conversations.count; i++) {
        id conv = conversations[i];
        BOOL match = NO;
        if (autoMode) {
            match = ([WGGGroupStore autoKindForConversation:conv] == wantKind);
        } else {
            NSString *key = [WGGGroupStore keyForConversation:conv];
            match = (key.length > 0 && [[self groupsForChatKey:key] containsObject:sel]);
        }
        if (match) {
            [out addObject:conv];
            [idx addObject:@(i)];
        }
    }
    return [WGGFilterResult resultWithFiltered:out indices:idx active:YES];
}

- (NSDictionary<NSString *, NSNumber *> *)countsForConversations:(NSArray *)conversations {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    counts[WGGGroupAllName] = @0;
    for (NSString *n in WGGAutoGroupNames()) counts[n] = @0;
    for (NSString *n in [self allGroupNames]) if (!counts[n]) counts[n] = @0;

    if (![conversations isKindOfClass:[NSArray class]]) return counts;

    counts[WGGGroupAllName] = @(conversations.count);
    for (id conv in conversations) {
        WGGAutoKind k = [WGGGroupStore autoKindForConversation:conv];
        if (k == WGGAutoKindFriend) {
            counts[WGGGroupFriendsName] = @([counts[WGGGroupFriendsName] integerValue] + 1);
        } else if (k == WGGAutoKindGroup) {
            counts[WGGGroupGroupsName] = @([counts[WGGGroupGroupsName] integerValue] + 1);
        }

        NSString *key = [WGGGroupStore keyForConversation:conv];
        if (key.length == 0) continue;
        for (NSString *g in [self groupsForChatKey:key]) {
            NSNumber *cur = counts[g];
            if (cur) counts[g] = @(cur.integerValue + 1);   // 会话可同时计入多个自定义分组
        }
    }
    return counts;
}

#pragma mark - 设置项

- (id)settingForKey:(NSString *)key fallback:(id)fallback {
    @synchronized (self) {
        id v = _settings[key];
        return v ? v : fallback;
    }
}

- (void)setSetting:(id)value forKey:(NSString *)key {
    @synchronized (self) {
        if (value) {
            _settings[key] = value;
        } else {
            [_settings removeObjectForKey:key];
        }
    }
    [self scheduleSave];
}

- (BOOL)isEnabled {
    return [[self settingForKey:kSetEnabled fallback:@YES] boolValue];
}
- (void)setEnabled:(BOOL)enabled {
    [self setSetting:@(enabled) forKey:kSetEnabled];
}

- (CGFloat)glassAlpha {
    return [[self settingForKey:kSetGlassAlpha fallback:@(kDefaultGlassAlpha)] doubleValue];
}
- (void)setGlassAlpha:(CGFloat)glassAlpha {
    [self setSetting:@(glassAlpha) forKey:kSetGlassAlpha];
}

- (CGFloat)drawerWidth {
    return [[self settingForKey:kSetDrawerWidth fallback:@(kDefaultDrawerWidth)] doubleValue];
}
- (void)setDrawerWidth:(CGFloat)drawerWidth {
    [self setSetting:@(drawerWidth) forKey:kSetDrawerWidth];
}

- (BOOL)triggerButtonHidden {
    return [[self settingForKey:kSetTriggerHidden fallback:@NO] boolValue];
}
- (void)setTriggerButtonHidden:(BOOL)hidden {
    [self setSetting:@(hidden) forKey:kSetTriggerHidden];
}

- (BOOL)animatedPresentation {
    return [[self settingForKey:kSetAnimated fallback:@YES] boolValue];
}
- (void)setAnimatedPresentation:(BOOL)animated {
    [self setSetting:@(animated) forKey:kSetAnimated];
}

- (BOOL)searchEnabled {
    return [[self settingForKey:kSetSearchEnabled fallback:@YES] boolValue];
}
- (void)setSearchEnabled:(BOOL)enabled {
    [self setSetting:@(enabled) forKey:kSetSearchEnabled];
}

- (BOOL)longPressMenuEnabled {
    return [[self settingForKey:kSetLongPress fallback:@YES] boolValue];
}
- (void)setLongPressMenuEnabled:(BOOL)enabled {
    [self setSetting:@(enabled) forKey:kSetLongPress];
}

- (BOOL)verboseLogging {
    return [[self settingForKey:kSetVerbose fallback:@NO] boolValue];
}
- (void)setVerboseLogging:(BOOL)verbose {
    [self setSetting:@(verbose) forKey:kSetVerbose];
}

#pragma mark - 备份 / 恢复

- (NSDictionary *)exportState {
    return [self snapshot];
}

- (void)importState:(NSDictionary *)state {
    if (![state isKindOfClass:[NSDictionary class]]) return;
    @synchronized (self) {
        [_customGroups removeAllObjects];
        [_chatMap removeAllObjects];
        [_settings removeAllObjects];
        [_selectedGroup release];
        _selectedGroup = [WGGGroupAllName copy];
    }
    [self applyStateDictionary:state];
    @synchronized (self) {
        [self sanitizeLocked];
    }
    [self scheduleSave];
}

@end
