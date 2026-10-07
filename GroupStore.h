//
//  GroupStore.h
//  WeChatGlassGroups
//
//  分组配置的持久化 + 会话数组的过滤 / 重排。
//
//  设计原则（很重要）：
//   1. 永远不修改微信原始会话数组，只产出"新的数组"。
//      直接原地改微信的数组 = 内存越界崩溃。
//   2. 过滤结果必须和 tableView 的行数严格一致，否则 index 越界崩溃。
//      所以 Filtered 结构体同时保存"过滤后的数组"和"过滤后 → 原始的下标映射"。
//   3. 所有对微信对象的取值都用 KVC + respondsToSelector 保护，
//      任何一步失败都退回"不过滤"，宁可分组失效也不能崩微信。
//

#import <Foundation/Foundation.h>
#import "GlassGroupPanel.h"

NS_ASSUME_NONNULL_BEGIN

/// 过滤结果。indices[i] 是 filtered[i] 在原始数组中的下标。
@interface WGGFilterResult : NSObject
@property (nonatomic, strong, readonly) NSArray *filtered;
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *indices;
@property (nonatomic, assign, readonly) BOOL active;   // NO 表示"全部"，不做过滤
+ (instancetype)resultWithFiltered:(NSArray *)filtered
                           indices:(NSArray<NSNumber *> *)indices
                            active:(BOOL)active;
@end

@interface WGGGroupStore : NSObject

+ (instancetype)shared;

/// 面板开关。关掉时 tweak 完全不介入会话列表。
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 当前选中分组。
@property (nonatomic, assign) WGGGroup selectedGroup;

/// 读 / 写某个会话的分组。key 用下面 wgg_keyForConversation: 生成。
- (WGGGroup)groupForConversationKey:(NSString *)key;
- (void)setGroup:(WGGGroup)group forConversationKey:(NSString *)key;

/// 从一个"会话对象"里尽力提取稳定标识（wxid / userName / sessionId ...）。
/// 提取不到时返回 nil，调用方应跳过该会话而不是崩溃。
+ (nullable NSString *)keyForConversation:(id)conversation;

/// 从一个"会话对象"里尽力提取显示名，用于兜底匹配。
+ (nullable NSString *)displayNameForConversation:(id)conversation;

/// 核心：把原始会话数组按当前选中分组过滤。
/// 传入的数组不会被修改。
- (WGGFilterResult *)filterConversations:(nullable NSArray *)conversations;

/// 每个分组的会话数量（用于面板上的计数）。
- (NSDictionary<NSNumber *, NSNumber *> *)countsForConversations:(nullable NSArray *)conversations;

/// 未读数（尽力而为，取不到就全 0）。
- (NSDictionary<NSNumber *, NSNumber *> *)unreadCountsForConversations:(nullable NSArray *)conversations;

@end

NS_ASSUME_NONNULL_END
