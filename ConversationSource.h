//
//  ConversationSource.h
//  WeChatGlassGroups
//
//  【运行时数据源】找到微信首页的"会话数组"并缓存 ivar 路径。
//
//  日志实锤（8.0.78）：table=MainFrameTableView，dataSource=delegate=
//  NewMainFrameViewController，数组不在 VC 本体上，
//  在 m_mainFrameLogicController（MainFrameLogicController）等逻辑对象里。
//
//  做法：和探测器同一套"安全 ivar 原始读取"（object_getIvar，零副作用），
//  首次发现会话数组的路径后缓存（如 vc → m_mainFrameLogicController → m_arrData），
//  之后每次取值只走路径；路径失效（微信换实例/换名）自动重新发现。
//
//  铁律：只读、只拿引用，绝不修改微信数组。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WGGConversationSource : NSObject

/// 首页会话数组（只读引用）。找不到返回 nil（此时插件应静默让路）。
+ (NSArray * _Nullable)conversationsForViewController:(id)vc;

/// 该控制器是否处于搜索状态（搜索时微信自己换数据/行数，插件必须让路）。
+ (BOOL)isSearchingViewController:(id)vc;

@end

NS_ASSUME_NONNULL_END
