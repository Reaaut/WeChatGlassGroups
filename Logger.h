//
//  Logger.h
//  WeChatGlassGroups
//
//  【工具层】把插件日志落到一个**普通文本文件**里，方便不用电脑的用户提交日志。
//
//  为什么需要它：syslog 要用 iMazing / Filza 折腾半天才能看，
//  而本插件的关键日志（会话数组属性名、归类分布）是下一步开发的前提。
//  有了文件，用户只需要：打开插件设置 → 点「复制日志」→ 粘贴发出来。
//
//  写哪里（自动探测，先 1 后 2）：
//    1. /var/mobile/Library/WGG.log          —— 微信沙盒如果放得开，这是最好找的
//    2. 微信容器 Documents/WGG日志-发这个文件.txt —— 一定能写进去（在微信自己沙盒里）
//       用 Filza → 应用管理 → 微信 → Documents 就能看到
//
//  线程安全：串行队列；体积控制：超过 512KB 自动截留最后 256KB。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 追加一行日志（自动加 [HH:mm:ss] 前缀和换行）。任何线程可调。
void WGGFileLogAppend(NSString *line);

/// 读出全部日志内容（设置页「复制日志」用）。
NSString * _Nullable WGGFileLogContents(void);

/// 清空日志文件。
void WGGFileLogClear(void);

/// 当前生效的日志文件完整路径（探测失败返回 nil）。
NSString * _Nullable WGGFileLogPath(void);

NS_ASSUME_NONNULL_END
