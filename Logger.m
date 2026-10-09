//
//  Logger.m
//  WeChatGlassGroups
//
//  实现说明见 Logger.h。
//
//  MRC 提醒：-fno-objc-arc。静态缓存的对象由 dispatch_once 持有，不 release。
//

#import "Logger.h"

// 超过这个体积就截断（保留最后一段）
static const long kLogTrimThreshold = 512 * 1024;
static const long kLogKeepBytes     = 256 * 1024;

// 解析出来的最终路径（dispatch_once 写入，之后只读）
static NSString *gLogPath = nil;

/// 依次尝试的候选路径（返回数组里第一个能写成功的）。
static NSArray<NSString *> *WGGLogPathCandidates(void) {
    NSMutableArray *paths = [NSMutableArray array];

    // 1) 全局位置：最好找（Filza 直接进 /var/mobile/Library 就能看到）
    [paths addObject:@"/var/mobile/Library/WGG.log"];

    // 2) 微信容器 Documents：一定能写成功（在微信自己的沙盒里）
    //    文件名直接告诉用户"发这个文件"，省得沟通成本
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0) {
        [paths addObject:[docs[0] stringByAppendingPathComponent:@"WGG日志-发这个文件.txt"]];
    }
    return paths;
}

/// 初始化：挑一个能写的路径，并写入第一行（记录最终路径，方便用户找到它）。
static void WGGLogSetup(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *path in WGGLogPathCandidates()) {
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            // 目录不存在就建（/var/mobile/Library 已存在；容器的 Documents 也已存在）
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                                           attributes:nil error:NULL];
        }
        if (![fm isWritableFileAtPath:dir]) continue;

        // 空文件不存在就创建，然后试写一笔，验证真能写
        if (![fm fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) continue;
        NSString *probe = [NSString stringWithFormat:
            @"==== WGG 日志开始 · 本文件路径：%@ ====\n", path];
        [fh seekToEndOfFile];
        [fh writeData:[probe dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];

        // 复核：内容真的落盘了吗？（有的沙盒会让 open 成功但 write 失败）
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
        if (attr && [attr fileSize] > 0) {
            gLogPath = [path copy];
            return;
        }
    }
    gLogPath = nil;   // 两个候选都失败：只能靠 syslog 了
}

void WGGFileLogAppend(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WGGLogSetup();
    });
    if (!gLogPath || !line.length) return;

    // 加时间戳。用 dispatch_time 的 wall time 拿当前时刻
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t fmtOnce;
    dispatch_once(&fmtOnce, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });

    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];

    // ⚠️ 必须同步写：之前用 dispatch_async，进程一崩最后几行全丢——
    //    排查"设置闪退"时日志里连"被点击"都看不到，就是它干的。
    //    单行写入极小，同步的性能代价可以忽略。
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:gLogPath error:NULL];
    unsigned long long size = attr ? [attr fileSize] : 0;

    if (size > (unsigned long long)kLogTrimThreshold) {
        // 截断：只留最后 kLogKeepBytes，避免文件无限膨胀
        NSString *all = [NSString stringWithContentsOfFile:gLogPath
                                              encoding:NSUTF8StringEncoding error:NULL];
        if (all.length > (NSUInteger)kLogKeepBytes) {
            NSString *tail = [all substringFromIndex:all.length - (NSUInteger)kLogKeepBytes];
            [tail writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) return;
    [fh seekToEndOfFile];
    NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (data) [fh writeData:data];
    [fh closeFile];
}

NSString *WGGFileLogContents(void) {
    if (!gLogPath) return nil;
    return [NSString stringWithContentsOfFile:gLogPath
                                     encoding:NSUTF8StringEncoding error:NULL];
}

void WGGFileLogClear(void) {
    if (!gLogPath) return;
    [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

NSString *WGGFileLogPath(void) {
    return gLogPath;
}
