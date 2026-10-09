//
//  QQList.h
//  WeChatGlassGroups
//
//  【QQ 式分组列表】把"好友/群聊/公众号"折叠分组直接做进微信首页聊天列表。
//  —— 不是悬浮窗：分组表头作为额外行插在原表里，会话行映射回原始下标。
//
//  用法（在 Tweak.x 的数据源钩子里）：
//    shouldGroupTable:ofVC:      → 该不该干预（总开关/主表/非搜索）
//    virtualRowsForVC:           → 虚拟行表（表头行 + 展开分组的会话行）
//    headerCellForTable:row:     → 表头行自己的玻璃 cell
//    headerHeight                → 表头行高（44 + 行间距设置）
//    toggleGroupAtRow:reloadTable: → 点表头折叠/展开（持久化）
//
//  铁律：绝不修改微信数组；行号映射防越界；找不到数组就整体让路。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 虚拟行：表头行 或 原始会话行的映射。
/// 工厂方法返回 +1（调用方负责 release）。
@interface WGGVirtualRow : NSObject
@property (nonatomic, assign, readonly) BOOL isHeader;
@property (nonatomic, copy, readonly) NSString *groupName;        // 表头行：组名
@property (nonatomic, assign, readonly) NSUInteger groupCount;    // 表头行：组内会话数
@property (nonatomic, assign, readonly) BOOL collapsed;           // 表头行：是否折叠
@property (nonatomic, assign, readonly) NSUInteger originalIndex; // 会话行：原始下标

+ (instancetype)headerRowWithGroupName:(NSString *)name
                                 count:(NSUInteger)count
                             collapsed:(BOOL)collapsed;
+ (instancetype)conversationRowAtIndex:(NSUInteger)index;
@end

@interface WGGQQList : NSObject

/// 该不该干预这张表（分组总开关开 + 是首页主表 + 不在搜索态）。
+ (BOOL)shouldGroupTable:(UITableView *)tableView ofVC:(id)vc;

/// 虚拟行表（内部按"会话数 + 折叠版本号"缓存，reload 一轮只用建一次）。
+ (NSArray<WGGVirtualRow *> *)virtualRowsForVC:(id)vc;

/// 表头行高（44 + 用户设置的行间距，间距越大分组越透气）。
+ (CGFloat)headerHeight;

/// 生成/复用玻璃分组表头 cell（传入该行的虚拟行模型）。
+ (UITableViewCell *)headerCellForTable:(UITableView *)tableView
                             virtualRow:(WGGVirtualRow *)virtualRow;

/// 折叠/展开某分组（持久化），调用后请 reloadData。
+ (void)toggleGroupAtRow:(NSInteger)row;
/// 折叠/展开（直接给组名）。
+ (void)toggleGroupNamed:(NSString *)name;

/// 会话行：取该虚拟行对应的原始会话对象（nil = 越界/表头）。
+ (nullable id)conversationForVC:(id)vc row:(WGGVirtualRow *)virtualRow;

/// 会话行：生成/复用自绘"液态玻璃"会话 cell（不依赖微信原生渲染 ——
/// 实测微信的 cellForRow 只渲染自己显示范围内的小子集，映射回原下标会空白）。
+ (UITableViewCell *)conversationCellForTable:(UITableView *)tableView
                                conversation:(id)conversation;

/// 会话行高（固定 64，含上下留白）。
+ (CGFloat)conversationHeight;

/// 从会话对象读出显示名（供 cell 与探测调试复用）。
+ (NSString *)displayNameForConversation:(id)conversation;

@end

NS_ASSUME_NONNULL_END
