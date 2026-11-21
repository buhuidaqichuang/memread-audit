#import "AppDelegate.h"
#import "ViewController.h"

extern void MemReadEnvGPUCheck(const char *tag);
extern BOOL MemReadGPUAvailable(void);

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 此时 App 已连上系统服务，GPU 状态比 main() 里可靠
    MemReadEnvGPUCheck("launch");

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:[[ViewController alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 再测一次，看运行期是否恢复（结果写进同一个 env 文件）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MemReadEnvGPUCheck("runtime");
    });
    return YES;
}

@end
