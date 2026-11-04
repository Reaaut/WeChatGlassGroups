#import <UIKit/UIKit.h>
@interface WGMorphingTabBar : UIView
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic,copy,nullable) void (^selectionChanged)(NSInteger index);
@end
