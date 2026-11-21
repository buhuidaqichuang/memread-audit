#import <UIKit/UIKit.h>

@interface ValueListViewController : UIViewController
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) int type;
// YES：候选来自坐标结构扫描，行里按 (x, y, z) 三元组显示，而不是只显示第一个 float
@property (nonatomic, assign) BOOL vec3;
@end
