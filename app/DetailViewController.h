#import <UIKit/UIKit.h>

@interface DetailViewController : UIViewController
@property (nonatomic, strong) NSDictionary *info;
@property (nonatomic, assign) pid_t initialPid;   // >0 时进页面后自动读取该 PID
@end
