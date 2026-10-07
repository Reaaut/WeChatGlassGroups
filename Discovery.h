//
//  Discovery.h
//  WeChatGlassGroups — 运行时逆向探测模块
//
//  只有在 WGG_DISCOVERY=1 时才会编译进包里。
//  它的唯一工作：在你真机的微信 8.0.78 上，把真实存在的类名 / 属性名 / view 层级
//  打印到日志，然后你把日志贴回来，我们再据此写真正的 hook。
//
//  为什么必须这样做：不同微信小版本的类名和属性名是会变的，
//  任何"猜"出来的名字都只会在运行时让 hook 静默失效（不报错，但什么也不发生）。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 启动运行时探测（搜索类名 + 验证候选类）。在 tweak 的 %ctor 里调用。
/// 只有 WGG_DISCOVERY 宏打开时才有实现；否则它是空函数。
void WGGDiscoveryBootstrap(void);

/// 通用日志入口，其它 .m 文件也可以复用。
void WGGLogMessage(NSString *msg);

/// 把当前所有 window 的 view 层级打印到日志（递归，带缩进）。
void WGGDumpViewTree(void);

/// 打印某个类自己的 + 继承链上所有实例变量 / 属性 / 方法。
/// 传入 "MMConversationListViewController" 之类的类名字符串。
void WGGDumpClassInfo(NSString *className);

/// 在所有已加载的类里按关键字搜索类名（大小写不敏感），最多打印 limit 个。
/// 例：WGGSearchClasses(@"Conversation", 80); WGGSearchClasses(@"Session", 80);
void WGGSearchClasses(NSString *keyword, NSUInteger limit);

#ifdef __cplusplus
}
#endif
