//
//  SettingsController.h
//  WeChatGlassGroups
//
//  【UI 层】插件自己的设置页。
//
//  两个入口都能进来：
//   1. 抽屉面板底部的「设置」行（GlassGroupPanelDelegate 回调）
//   2. 微信「我 → 设置」页面底部注入的那一行（Tweak.x 注入 tableFooterView）
//
//  刻意**不用** UITableViewController：
//   · 不碰微信的数据源，就没有"行数/下标"那类崩溃风险
//   · 纯 UIScrollView + UIStackView 手搭，MRC 下也最好写、最好查
//
//  MRC 提醒：-fno-objc-arc，delegate 用 assign，局部控件要 autorelease。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WGGSettingsController : UIViewController
@end

/// 设置页里可以选的箭头图标（SF Symbol 名）。
/// 想加新图标：往这个数组里加名字即可，设置页会自动多一项。
extern NSArray<NSString *> *WGGArrowSymbolChoices(void);

NS_ASSUME_NONNULL_END
