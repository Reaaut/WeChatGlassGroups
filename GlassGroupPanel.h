//
//  GlassGroupPanel.h
//  WeChatGlassGroups
//
//  首页顶部的玻璃分组面板（纯 UIKit，不用 SwiftUI）。
//  这个文件不依赖微信的任何类，可以单独编译、单独测试，
//  所以它能在"还没拿到真实类名"的阶段就先把 UI 做完并验证。
//
//  尺寸按效果图（1179x2556 @3x）反推，见 .m 文件顶部的常量。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 4 个固定分组。「全部」用于取消筛选（效果图上没有这一项，需要另找入口）。
typedef NS_ENUM(NSInteger, WGGGroup) {
    WGGGroupFamily = 0,
    WGGGroupChats,
    WGGGroupGroup,
    WGGGroupService,
    WGGGroupAll,
    WGGGroupCount = WGGGroupAll,
};

/// 设置键名（存在 NSUserDefaults，域为 com.tencent.xin，随微信沙盒走）
extern NSString *const WGGDefaultsKeyEnabled;       // BOOL 是否显示面板
extern NSString *const WGGDefaultsKeyBlurAlpha;     // double 玻璃透明度 0.0~1.0
extern NSString *const WGGDefaultsKeyCornerRadius;  // double 圆角
extern NSString *const WGGDefaultsKeySelectedGroup; // int 当前选中分组
extern NSString *const WGGDefaultsKeyGroupMap;      // NSDictionary<wxid, groupName>

@class GlassGroupPanel;

@protocol GlassGroupPanelDelegate <NSObject>
@optional
/// 用户点了某个分组。控制器收到后应该重算过滤 → reloadData。
- (void)glassGroupPanel:(GlassGroupPanel *)panel didSelectGroup:(WGGGroup)group;
/// 面板高度变化。控制器可据此更新 tableView.contentInset。
- (void)glassGroupPanelDidChangeHeight:(GlassGroupPanel *)panel;
@end

@interface GlassGroupPanel : UIView

/// 分组按钮上的显示名，下标对应 WGGGroup 的 rawValue。
@property (nonatomic, copy, readonly) NSArray<NSString *> *groupTitles;
/// 当前选中分组。
@property (nonatomic, assign, readonly) WGGGroup selectedGroup;

/// delegate 用 assign 而不是 weak —— 本工程是 MRC（Makefile 里 -fno-objc-arc），
/// MRC 下没有 weak 概念，写 weak 会编译报
/// "cannot synthesize weak property in file using manual reference counting"。
/// assign 在 MRC 下就是"不持有"，正是 delegate 需要的行为：
/// 面板由父视图持有，delegate（视图控制器）生命周期比面板长。
@property (nonatomic, assign, nullable) id<GlassGroupPanelDelegate> delegate;

/// 玻璃参数（改了立刻重绘，同时写回 NSUserDefaults）
@property (nonatomic, assign) CGFloat glassAlpha;      // 0.0 ~ 1.0，默认 1.0
@property (nonatomic, assign) CGFloat cornerRadius;    // 默认 20.0（对应效果图）

/// 右侧信息卡里的圆形小头像（效果图右上角那张黑白人像）
- (void)setAvatarImage:(nullable UIImage *)image;
/// 左侧大图（效果图里那张黑白叶子照）。不设置就显示灰阶占位。
- (void)setHeroImage:(nullable UIImage *)image;

/// 信息卡文案。传 nil 表示保持原值不变。
- (void)setTitleText:(nullable NSString *)title
            subtitle:(nullable NSString *)subtitle
                date:(nullable NSString *)date;

/// 分组角标。效果图上没有这个元素，当前实现只是保留接口、不渲染。
- (void)setBadgeCounts:(nullable NSDictionary<NSNumber *, NSNumber *> *)counts;

/// 以 NSUserDefaults 中保存的值恢复状态（选中分组 / 透明度 / 圆角）。
- (void)restoreFromDefaults;
/// 把当前状态写回 NSUserDefaults。
- (void)persistToDefaults;

@end

/// 分组枚举 → 存储用的字符串（"Family"/"Chats"/"Group"/"Service"）
extern NSString *WGGGroupName(WGGGroup g);
/// 字符串 → 分组枚举，无法识别时返回 WGGGroupChats（默认分组）
extern WGGGroup WGGGroupFromName(NSString * _Nullable name);

#pragma mark - 底部搜索框（效果图最下方那一条）

/// 纯装饰性的玻璃搜索条：一个圆角胶囊 + 左侧放大镜图标。
/// 效果图上它跟着内容一起滚动，所以它不属于 GlassGroupPanel，
/// 应该由宿主加在会话列表的 tableHeaderView 或滚动内容里。
@interface WGGSearchBar : UIView
@end

NS_ASSUME_NONNULL_END
