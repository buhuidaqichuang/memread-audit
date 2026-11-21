#import <UIKit/UIKit.h>
#include <sys/types.h>

// 画中画悬浮窗 + 后台自动收敛（RootHide 无法注入 SpringBoard，PiP 是唯一能浮在游戏上的系统级窗口）
@interface FloatPanelController : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

// 诊断输出（App 内进度框直接显示，同时写 /var/mobile/Media/memread_pip.log）
@property (nonatomic, copy) void (^statusHandler)(NSString *line);

// 预览层挂到给定容器（必须在窗口内、非隐藏），建议 16:9
- (void)attachPreviewTo:(UIView *)host;

// cond 用 MEMREAD_VALCOND_*；interval 秒
- (BOOL)startWithPid:(pid_t)pid type:(int)type cond:(int)cond interval:(double)interval;

// 监控「已保存地址」：不同枪的弹匣地址不同，各自存一条标签后一起看
- (BOOL)startWatchSavedWithPid:(pid_t)pid interval:(double)interval;

- (void)stop;

@end
