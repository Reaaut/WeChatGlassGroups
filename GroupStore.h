//
//  GroupStore.h
//  WeChatGlassGroups
//
//  【数据层】分组定义、会话自动归类、选中状态、插件设置，全部持久化。
//
//  ── 核心模型：自动分组 ───────────────────────────────────────────────
//  不做"手动把会话拖进分组"那套（累人且难维护）。
//  好友 / 群聊 由**会话标识自动判断**，规则见 autoKindForIdentifier:。
//  用户额外想手动分组时，仍可新建自定义分组（走 chatMap）。
//
//  内置（自动）分组：
//     全部   —— 不过滤
//     好友   —— 单聊
//     群聊   —— 群聊
//     公众号 —— gh_ 开头的公众号 / 服务号
//  （系统账号如文件传输助手不单独列组，只在"全部"里出现）
//
//  三条铁律：
//   1. 不 import 任何微信头文件、不 hook 任何东西 —— UI 和 Hook 都依赖它，它不依赖别人。
//   2. 过滤只产出"新数组"，永远不修改微信传入的原始数组。
//   3. 任何取值失败都退回"不过滤"。宁可分组失效，也不许崩微信。
//
//  ── 存储 ────────────────────────────────────────────────────────────
//  NSUserDefaults，整份状态存**一个键**（WGG.state.v2），
//  避免"多键分别读写"造成不一致。
//
//  ⚠️ Tweak 是注入微信**进程**运行的，没有独立沙盒，所以这个 defaults 落在
//     微信容器的 Library/Preferences 下。微信重启/手机重启都不丢，但卸载微信会丢。
//     想独立：把 load/save 换成读写
//     /var/jb/var/mobile/Library/Preferences/com.yourname.wechatglassgroups.plist
//     （无根越狱必须带 /var/jb 前缀）。
//
//  ── 线程模型 ────────────────────────────────────────────────────────
//   读：只读内存，不碰磁盘（主线程上反复过滤也不会卡）。
//   写：@synchronized 改内存 → 整份快照异步丢到串行队列落盘。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 内置分组名（同时也是面板上显示的文案）

extern NSString *const WGGGroupAllName;      // @"全部" —— 不过滤
extern NSString *const WGGGroupFriendsName;  // @"好友" —— 单聊
extern NSString *const WGGGroupGroupsName;   // @"群聊" —— 群聊
extern NSString *const WGGGroupOfficialName; // @"公众号" —— gh_ 开头的公众号/服务号

/// 内置的**自动**分组（不含"全部"）。
extern NSArray<NSString *> *WGGAutoGroupNames(void);

#pragma mark - 会话自动归类

typedef NS_ENUM(NSInteger, WGGAutoKind) {
    WGGAutoKindUnknown = 0,
    WGGAutoKindFriend,     // 好友（单聊）
    WGGAutoKindGroup,      // 群聊
    WGGAutoKindOfficial,   // 公众号 / 服务号
    WGGAutoKindSystem,     // 系统账号（文件传输助手、微信团队等）
};

#pragma mark - 过滤结果

/// indices[i] 是 filtered[i] 在**原始数组**里的下标 —— 防越界的关键：
/// tableView 行数用 filtered.count，取 cell 时用 indices[row] 翻回原生下标。
@interface WGGFilterResult : NSObject
@property (nonatomic, strong, readonly) NSArray *filtered;
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *indices;
@property (nonatomic, assign, readonly) BOOL active;   // NO = 不过滤（原样返回）
+ (instancetype)resultWithFiltered:(NSArray *)filtered
                           indices:(NSArray<NSNumber *> *)indices
                            active:(BOOL)active;
@end

#pragma mark - 数据仓库

@interface WGGGroupStore : NSObject

+ (instancetype)shared;

#pragma mark 总开关
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

#pragma mark 分组
/// 自动分组 + 自定义分组（**不含**"全部"）。
- (NSArray<NSString *> *)allGroupNames;
/// 面板要展示的完整列表：全部 + 各分组。
- (NSArray<NSString *> *)panelGroupNames;
/// 是否是内置自动分组（好友/群聊），这类分组由标识自动判断，不吃 chatMap。
- (BOOL)isAutoGroup:(NSString *)name;
/// 新增自定义分组。重名 / 空名 / 撞内置名 → NO。
- (BOOL)addGroupNamed:(NSString *)name;
/// 删除自定义分组（同时从所有会话归属里摘掉）。内置 → NO。
- (BOOL)removeGroupNamed:(NSString *)name;
/// 重命名自定义分组。新名非法/被占用 → NO。内置不可改名。
- (BOOL)renameGroup:(NSString *)oldName to:(NSString *)newName;

#pragma mark 选中分组
- (NSString *)selectedGroupName;
/// 传非法名（分组已删）时自动回落成"全部"。
- (void)setSelectedGroupName:(NSString *)name;

#pragma mark 会话自动归类（核心）
/// 判断一个会话属于哪一类。优先读会话对象上的类型标记，
/// 读不到就用标识字符串判断（群聊 id 一定以 @chatroom 结尾，最可靠）。
+ (WGGAutoKind)autoKindForConversation:(id _Nullable)conversation;
/// 纯字符串判定，方便单测。ident 可以是 wxid / userName / sessionId。
+ (WGGAutoKind)autoKindForIdentifier:(NSString * _Nullable)ident;
/// 人工可读的类型名（日志用）。
+ (NSString *)nameForAutoKind:(WGGAutoKind)kind;

#pragma mark 会话归属（只对**自定义分组**有意义）
- (NSArray<NSString *> *)groupsForChatKey:(NSString *)key;
- (BOOL)isChatKey:(NSString *)key inGroup:(NSString *)group;
- (void)addChatKey:(NSString *)key toGroup:(NSString *)group;
- (void)removeChatKey:(NSString *)key fromGroup:(NSString *)group;
- (BOOL)toggleChatKey:(NSString *)key inGroup:(NSString *)group;
- (void)removeChatKeyFromAllGroups:(NSString *)key;

#pragma mark 会话对象辅助（KVC + 保护，失败返回 nil）
+ (nullable NSString *)keyForConversation:(id)conversation;
+ (nullable NSString *)displayNameForConversation:(id)conversation;

#pragma mark 过滤 / 统计
/// 按当前选中分组过滤。conversations 不会被修改。
- (WGGFilterResult *)filterConversations:(nullable NSArray *)conversations;
/// 各分组的会话数：@{ @"全部": @10, @"好友": @7, @"群聊": @3 }
- (NSDictionary<NSString *, NSNumber *> *)countsForConversations:(nullable NSArray *)conversations;

#pragma mark 设置项（UI 层读这些值配置自己）
@property (nonatomic, assign) CGFloat glassAlpha;          // 0.0~1.0，默认 0.95
@property (nonatomic, assign) CGFloat drawerWidth;         // pt，默认 268
@property (nonatomic, assign) CGFloat rowSpacing;          // 分组行间距 pt，默认 8
@property (nonatomic, copy)   NSString *arrowSymbolName;   // 分组行箭头图标（SF Symbol 名）
@property (nonatomic, assign) BOOL    triggerButtonHidden;
@property (nonatomic, assign) BOOL    animatedPresentation;
@property (nonatomic, assign) BOOL    searchEnabled;
@property (nonatomic, assign) BOOL    longPressMenuEnabled;
@property (nonatomic, assign) BOOL    verboseLogging;

#pragma mark 备份 / 恢复
- (NSDictionary *)exportState;
- (void)importState:(nullable NSDictionary *)state;

#pragma mark 落盘
- (void)flush;

@end

NS_ASSUME_NONNULL_END
