// 系统级悬浮窗：由 ElleKit 注入 SpringBoard，画在所有 App 之上
// 只负责显示 /var/mobile/Media/memread_live.txt 里的进度，不读任何目标进程内存

#import <UIKit/UIKit.h>

static UIWindow *gWin = nil;
static UIView *gPanel = nil;
static UILabel *gLabel = nil;
static NSTimer *gTimer = nil;

static NSString *const kLivePath = @"/var/mobile/Media/memread_live.txt";
static NSString *const kHiddenKey = @"com.gsy.memreadfloat.hidden";

static NSString *ReadLive(void) {
    NSString *s = [NSString stringWithContentsOfFile:kLivePath
                                            encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) {
        return @"等待读取…\n在 MemRead 里点「读取内存」";
    }
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    NSMutableArray *tail = [NSMutableArray array];
    NSUInteger start = lines.count > 12 ? lines.count - 12 : 0;
    for (NSUInteger i = start; i < lines.count; i++) {
        if ([lines[i] length]) [tail addObject:lines[i]];
    }
    return [tail componentsJoinedByString:@"\n"];
}

// 透明区域不拦截触摸：否则 SpringBoard 全屏都会吃不到点击
@interface FloatRootView : UIView
@end

@implementation FloatRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface FloatPanelView : UIView
@end

@implementation FloatPanelView
- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}
- (void)onClose:(id)sender {
    gWin.hidden = YES;
    [gTimer invalidate];
    gTimer = nil;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kHiddenKey];
}
@end

static void TryShowPanel(void) {
    if (gWin) return;

    UIApplication *app = [UIApplication sharedApplication];
    UIWindowScene *scene = nil;
    for (id s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) {
        // SpringBoard 场景还没就绪，稍后重试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ TryShowPanel(); });
        return;
    }

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kHiddenKey]) return;

    gWin = [[UIWindow alloc] initWithWindowScene:scene];
    gWin.windowLevel = UIWindowLevelAlert + 1;
    gWin.backgroundColor = [UIColor clearColor];
    gWin.frame = scene.coordinateSpace.bounds;

    FloatRootView *root = [[FloatRootView alloc] initWithFrame:gWin.bounds];
    root.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = root;
    gWin.rootViewController = vc;

    CGRect b = scene.coordinateSpace.bounds;
    CGFloat W = 300, H = 200;
    CGFloat x = b.size.width - W - 20;
    CGFloat y = 110;

    FloatPanelView *panel = [[FloatPanelView alloc] initWithFrame:CGRectMake(x, y, W, H)];
    panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.88];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, W - 52, 22)];
    title.text = @"MemRead 实时读取";
    title.font = [UIFont boldSystemFontOfSize:13];
    title.textColor = [UIColor whiteColor];
    [panel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W - 40, 2, 36, 30);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.65] forState:UIControlStateNormal];
    [close addTarget:panel action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];

    gLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 34, W - 28, H - 44)];
    gLabel.numberOfLines = 0;
    gLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    gLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    gLabel.text = ReadLive();
    [panel addSubview:gLabel];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:panel action:@selector(onPan:)];
    [panel addGestureRecognizer:pan];

    [root addSubview:panel];
    gPanel = panel;
    gWin.hidden = NO;

    gTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        gLabel.text = ReadLive();
    }];
}

__attribute__((constructor))
static void memread_float_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TryShowPanel(); });
}
