//
//  GlassGroupPanel.h
//  WeChatGlassGroups
//
//  【UI 层】液态玻璃侧边抽屉面板 + 悬浮触发按钮。
//
//  分层铁律：
//   * 本文件只负责渲染和"把点击事件回调出去"。
//   * 绝不读写分组数据（那是 GroupStore 的活），绝不 import 任何微信类。
//   * 所以它可以脱离微信，塞进一个普通 iOS App 里单独跑、单独调 UI。
//
//  MRC 提醒：本工程 -fno-objc-arc，delegate 一律用 assign（MRC 没有 weak）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// "全部会话"保留分组名，固定等于 GroupStore 里的同名常量。
extern NSString *const WGGGroupAllName;

@class GlassGroupPanel;

#pragma mark - 回调协议

@protocol GlassGroupPanelDelegate <NSObject>
@optional
/// 用户点了某个分组。groupName 是分组名字符串（可能是自定义分组）。
/// 收到后应该：写回 GroupStore → 刷新会话列表。
- (void)glassGroupPanel:(GlassGroupPanel *)panel didSelectGroup:(NSString *)groupName;
/// 搜索框文字变化（空串表示清空）。
- (void)glassGroupPanel:(GlassGroupPanel *)panel didChangeSearchText:(NSString *)text;
@end

#pragma mark - 抽屉面板本体

@interface GlassGroupPanel : UIView

/// 要展示的分组名列表（应包含 WGGGroupAllName）。赋值后自动重建行。
@property (nonatomic, copy) NSArray<NSString *> *groupNames;
/// 当前选中的分组名。
@property (nonatomic, copy, nullable) NSString *selectedGroupName;

/// 抽屉宽度（pt），默认 268。
@property (nonatomic, assign) CGFloat drawerWidth;
/// 玻璃透明度 0.0~1.0，默认 0.95。
@property (nonatomic, assign) CGFloat glassAlpha;
/// 圆角，默认 28（液态玻璃要"大圆角"）。
@property (nonatomic, assign) CGFloat cornerRadius;
/// 是否显示底部搜索框，默认 YES。
@property (nonatomic, assign) BOOL searchEnabled;

/// delegate 用 assign：面板由父视图持有，控制器生命周期比面板长。
@property (nonatomic, assign, nullable) id<GlassGroupPanelDelegate> delegate;

/// 顶部文案。传 nil 表示保持原样。
- (void)setHeaderTitle:(nullable NSString *)title
              subtitle:(nullable NSString *)subtitle
                avatar:(nullable UIImage *)avatar;

/// 分组角标：@{ @"好友": @(12), @"群聊": @(3) }。传 nil 清空。
- (void)setBadgeCounts:(nullable NSDictionary<NSString *, NSNumber *> *)counts;

/// 按 groupNames 重建分组行（改 groupNames 时会自动调用，一般不用手动调）。
- (void)reloadGroupRows;

/// 收起键盘（关闭抽屉前调用）。
- (void)resignSearchInput;

@end

#pragma mark - 抽屉宿主

/**
 * Tweak.x 只需要把 WGGDrawerHost 铺满微信首页的 view，剩下的都归它管：
 *   · 左侧悬浮触发按钮（点击弹出/收起）
 *   · 半透明遮罩（点击空白处收起）
 *   · 面板从左侧滑入 / 滑出
 *   · 空白区域的触摸会穿透给微信（不然会话列表就点不动了）
 */
@interface WGGDrawerHost : UIView

@property (nonatomic, strong, readonly) GlassGroupPanel *panel;

/// 隐藏悬浮触发按钮（设置项）。默认 NO。
@property (nonatomic, assign) BOOL triggerButtonHidden;
/// 是否播放滑入/滑出动画（设置项）。默认 YES。
@property (nonatomic, assign) BOOL animatedPresentation;

/// 直接透传给面板的 delegate。
@property (nonatomic, assign, nullable) id<GlassGroupPanelDelegate> delegate;

- (void)showPanelAnimated:(BOOL)animated;
- (void)hidePanelAnimated:(BOOL)animated;
- (BOOL)isPanelVisible;

@end

NS_ASSUME_NONNULL_END
