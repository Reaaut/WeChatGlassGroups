//
// ConversationSource.h
// WCGlass Offline
//
// 首页会话快照接口。
// 仅在微信首页、MainFrameTableView、逻辑层加载状态和枚举接口均验证通过，
// 且连续两次读取一致后，才返回稳定快照。未就绪时返回 nil，让原生列表接管。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WGGConversationSource : NSObject

/// 返回已验证的全量会话快照；尚未就绪或校验失败时返回 nil。
+ (NSArray * _Nullable)conversationsForViewController:(id)vc;

/// 微信首页搜索期间必须让原生列表接管。
+ (BOOL)isSearchingViewController:(id)vc;

@end

NS_ASSUME_NONNULL_END
