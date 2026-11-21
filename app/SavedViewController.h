#import <UIKit/UIKit.h>
#include <sys/types.h>

// 已保存地址（自定义标签）页
@interface SavedViewController : UIViewController
@property (nonatomic, assign) pid_t pid;   // 0 = 未绑定进程，只显示地址不刷值
@end
