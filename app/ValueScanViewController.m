#import "ValueScanViewController.h"
#import "ValueListViewController.h"
#import "SavedViewController.h"
#import "SavedAddressStore.h"
#import "memread_core.h"
#import "FloatPanelController.h"
#include <string.h>
#include <QuartzCore/QuartzCore.h>

@interface ValueScanViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *pidLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UISegmentedControl *typeControl;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UITextView *progressView;
@property (nonatomic, strong) UIView *previewBox;
@property (nonatomic, assign) pid_t currentPid;
- (void)appendProgressLine:(NSString *)line;
- (void)clearProgress;
@end

typedef struct {
    void *vc;                       // __bridge ValueScanViewController *
    unsigned long long total;       // 首扫：可写总字节；收敛：候选总数
    unsigned long long regions;
    CFAbsoluteTime start;
    CFAbsoluteTime last;
} ScanProgCtx;

// 首扫回调：addr / chunk / 累计字节
static void FirstProgCb(unsigned long long addr, unsigned long long chunk,
                        unsigned long long bytes, int skipped, void *p) {
    ScanProgCtx *c = (ScanProgCtx *)p;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - c->last < 0.2 && bytes < c->total) return;
    c->last = now;
    double pct = c->total ? (100.0 * (double)bytes / (double)c->total) : 0.0;
    NSString *line = [NSString stringWithFormat:@"首扫 %5.1f%%   %.0f/%.0f MB   区 %llu",
                      pct, (double)bytes / 1048576.0, (double)c->total / 1048576.0, c->regions];
    ValueScanViewController *vc = (__bridge ValueScanViewController *)c->vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc appendProgressLine:line];
        vc.statusLabel.text = line;
    });
}

// 收敛回调：idx / 候选总数
static void RefineProgCb(unsigned long long idx, unsigned long long total,
                         unsigned long long unused, int skipped, void *p) {
    ScanProgCtx *c = (ScanProgCtx *)p;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - c->last < 0.2 && idx < total) return;
    c->last = now;
    double pct = total ? (100.0 * (double)idx / (double)total) : 0.0;
    NSString *line = [NSString stringWithFormat:@"收敛 %5.1f%%   %llu/%llu",
                      pct, idx, total];
    ValueScanViewController *vc = (__bridge ValueScanViewController *)c->vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc appendProgressLine:line];
        vc.statusLabel.text = line;
    });
}

@implementation ValueScanViewController

- (int)type {
    return (int)self.typeControl.selectedSegmentIndex;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.title = @"数值扫描";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentPid = 0;

    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat panelH = 210.0;

    self.scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, W, H - panelH)];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    CGFloat y = 16;

    self.infoLabel = [self addLabel:[NSString stringWithFormat:@"目标: %@\n%@",
                                     self.info[@"name"], self.info[@"bid"]] width:W y:&y];
    self.pidLabel = [self addLabel:@"PID: 查找中" width:W y:&y];

    UILabel *t = [self addLabel:@"数值类型" width:W y:&y];
    t.font = [UIFont boldSystemFontOfSize:13];

    self.typeControl = [[UISegmentedControl alloc] initWithItems:@[@"int32", @"int64", @"float", @"double"]];
    self.typeControl.frame = CGRectMake(20, y, W - 40, 36);
    self.typeControl.selectedSegmentIndex = 0;
    [self.typeControl addTarget:self action:@selector(onTypeChanged) forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:self.typeControl];
    y += 44;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.frame = CGRectMake(20, y, 40, 40);
    [self.scroll addSubview:self.spinner];
    y += 48;

    self.statusLabel = [self addLabel:@"就绪" width:W y:&y];
    self.countLabel  = [self addLabel:@"候选: 0" width:W y:&y];

    [self addButton:@"首扫：按当前值找地址（值 / 容差）" width:W y:&y sel:@selector(onFirst)];
    [self addButton:@"收敛：按变化筛选候选" width:W y:&y sel:@selector(onRefine)];
    [self addButton:@"查看候选列表（点一行读当前值）" width:W y:&y sel:@selector(onList)];
    [self addButton:@"已保存地址（自定义标签）" width:W y:&y sel:@selector(onSaved)];
    [self addButton:@"画中画悬浮窗（后台自动收敛）" width:W y:&y sel:@selector(onFloat)];
    [self addButton:@"重置候选" width:W y:&y sel:@selector(onReset)];

    self.scroll.contentSize = CGSizeMake(W, y + 20);

    // 底部固定进度框
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, H - panelH, W, panelH)];
    panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:panel];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 0.5)];
    sep.backgroundColor = [UIColor separatorColor];
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:sep];

    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, W - 190, 18)];
    pt.text = @"进度";
    pt.font = [UIFont boldSystemFontOfSize:12];
    pt.textColor = [UIColor secondaryLabelColor];
    [panel addSubview:pt];

    // 画中画预览（PiP 启动前必须挂在一个可见视图上）
    UIView *previewBox = [[UIView alloc] initWithFrame:CGRectMake(W - 166, 8, 152, 86)];
    previewBox.backgroundColor = [UIColor blackColor];
    previewBox.clipsToBounds = YES;
    previewBox.layer.cornerRadius = 6;
    previewBox.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [panel addSubview:previewBox];
    self.previewBox = previewBox;
    [[FloatPanelController shared] attachPreviewTo:previewBox];

    self.progressView = [[UITextView alloc] initWithFrame:CGRectMake(10, 100, W - 20, panelH - 106)];
    self.progressView.editable = NO;
    self.progressView.selectable = NO;
    self.progressView.backgroundColor = [UIColor clearColor];
    self.progressView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.progressView.textColor = [UIColor labelColor];
    self.progressView.textContainerInset = UIEdgeInsetsMake(0, 0, 0, 0);
    self.progressView.text = @"等待操作";
    self.progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:self.progressView];

    [self refreshCount];
    [self findPidNow];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.previewBox) {
        [[FloatPanelController shared] attachPreviewTo:self.previewBox];
    }
}

- (UILabel *)addLabel:(NSString *)text width:(CGFloat)W y:(CGFloat *)y {
    CGFloat w = W - 40;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, *y, w, 0)];
    l.text = text;
    l.font = [UIFont systemFontOfSize:14];
    l.numberOfLines = 0;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    l.preferredMaxLayoutWidth = w;
    CGSize fit = [l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    l.frame = CGRectMake(20, *y, w, ceil(fit.height));
    [self.scroll addSubview:l];
    *y += l.frame.size.height + 8;
    return l;
}

- (void)addButton:(NSString *)title width:(CGFloat)W y:(CGFloat *)y sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(20, *y, W - 40, 44);
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [self.scroll addSubview:b];
    *y += 48;
}

#pragma mark - 进度框

- (void)clearProgress {
    self.progressView.text = @"";
}

- (void)appendProgressLine:(NSString *)line {
    if (!self.isViewLoaded || !line.length) return;
    NSMutableString *t = [NSMutableString stringWithString:self.progressView.text ?: @""];
    if (t.length) [t appendString:@"\n"];
    [t appendString:line];
    if (t.length > 5000) {
        NSRange r = [t rangeOfString:@"\n" options:0 range:NSMakeRange(0, t.length - 4000)];
        if (r.location != NSNotFound) [t deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
    }
    self.progressView.text = t;
    [self.progressView scrollRangeToVisible:NSMakeRange(t.length - 1, 1)];
}

- (void)onTypeChanged {
    // 换类型后旧候选不保证仍对应，只提示不强制清空
}

- (void)refreshCount {
    self.countLabel.text = [NSString stringWithFormat:@"候选: %llu", memread_valscan_count()];
}

- (NSString *)resolveBundlePath {
    NSString *p = self.info[@"bundlePath"];
    if (p.length) return p;
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return nil;
    id ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL sApp = NSSelectorFromString(@"applicationForBundleIdentifier:");
    if (![ws respondsToSelector:sApp]) return nil;
    id proxy = [ws performSelector:sApp withObject:self.info[@"bid"]];
    if (!proxy) return nil;
    NSURL *u = [proxy performSelector:NSSelectorFromString(@"bundleURL")];
    return u.path;
}

- (pid_t)resolvePid {
    NSString *bundlePath = [self resolveBundlePath];
    if (!bundlePath.length) return 0;
    NSBundle *b = [NSBundle bundleWithPath:bundlePath];
    NSString *exeName = [b objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if (!exeName.length) exeName = [bundlePath.lastPathComponent stringByDeletingPathExtension];
    NSString *exePath = [bundlePath stringByAppendingPathComponent:exeName];

    pid_t pids[8192];
    int n = memread_list_procs(pids, 8192);
    for (int i = 0; i < n; i++) {
        char path[MEMREAD_PROC_PATH_MAX] = {0};
        if (memread_proc_path(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if (!p.length) continue;
        if ([p isEqualToString:exePath] || [p hasPrefix:[bundlePath stringByAppendingString:@"/"]]) {
            return pids[i];
        }
    }
    return 0;
}

- (void)findPidNow {
    pid_t pid = [self resolvePid];
    self.currentPid = pid;
    if (pid > 0) {
        self.pidLabel.text = [NSString stringWithFormat:@"PID: %d（运行中）", pid];
    } else {
        self.pidLabel.text = @"PID: 未运行，请先在详情页点「启动 App」";
    }
}

- (pid_t)ensurePid {
    if (self.currentPid <= 0) [self findPidNow];
    if (self.currentPid <= 0) self.statusLabel.text = @"目标未运行，请先启动";
    return self.currentPid;
}

#pragma mark - 首扫 / 收敛

- (void)onFirst {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"首扫：找当前值"
        message:@"值：要搜的数值；容差：允许误差（int 填 0，float 可填 0.5）"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"值，如 100";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"容差，如 0";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"开始首扫" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        double value = [a.textFields[0].text doubleValue];
        double tol = [a.textFields[1].text doubleValue];
        [ws runFirst:value tol:tol];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runFirst:(double)value tol:(double)tol {
    if (self.currentPid <= 0) return;
    [self.spinner startAnimating];
    [self clearProgress];
    self.statusLabel.text = @"首扫中";
    int vt = [self type];
    pid_t pid = self.currentPid;
    [self appendProgressLine:[NSString stringWithFormat:@"首扫开始  pid=%d  %@  值=%.6g  容差=%.6g",
                             pid, [SavedAddressStore typeName:vt], value, tol]];

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(ws) self2 = ws;
        if (!self2) return;

        unsigned long long totalBytes = 0, regions = 0;
        int rc0 = memread_writable_bytes(pid, 1, &totalBytes, &regions);
        if (rc0 != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self2.spinner stopAnimating];
                self2.statusLabel.text = [NSString stringWithFormat:@"枚举区域失败 rc=%d", rc0];
                [self2 appendProgressLine:[NSString stringWithFormat:@"错误  memread_writable_bytes rc=%d", rc0]];
            });
            return;
        }

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        ScanProgCtx ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.vc = (__bridge void *)self2;
        ctx.total = totalBytes;
        ctx.regions = regions;
        ctx.start = t0;
        ctx.last = t0;

        unsigned long long hits = 0;
        int rc = memread_valscan_first(pid, 1, vt, value, tol, FirstProgCb, &ctx, &hits, NULL);
        double cost = CFAbsoluteTimeGetCurrent() - t0;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self2.spinner stopAnimating];
            self2.statusLabel.text = [NSString stringWithFormat:@"首扫完成 rc=%d 候选=%llu", rc, hits];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"首扫结束  rc=%d  候选=%llu  用时 %.1f s", rc, hits, cost]];
            [self2 refreshCount];
        });
    });
}

- (void)onRefine {
    if (memread_valscan_count() == 0) {
        self.statusLabel.text = @"先做一次首扫，才有候选可收敛";
        return;
    }
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"收敛条件"
        message:[NSString stringWithFormat:@"当前候选 %llu 个", memread_valscan_count()]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    void (^addCond)(NSString *, int, BOOL) = ^(NSString *title, int cond, BOOL needVal) {
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            if (needVal) [ws askTargetFor:cond];
            else [ws runRefine:cond target:0];
        }]];
    };
    addCond(@"变小了（cur < prev）", MEMREAD_VALCOND_DECREASED, NO);
    addCond(@"变大了（cur > prev）", MEMREAD_VALCOND_INCREASED, NO);
    addCond(@"变了（cur != prev）", MEMREAD_VALCOND_CHANGED, NO);
    addCond(@"没变（cur == prev）", MEMREAD_VALCOND_UNCHANGED, NO);
    addCond(@"等于目标值", MEMREAD_VALCOND_EQUAL, YES);
    addCond(@"差值等于 N", MEMREAD_VALCOND_DELTA, YES);
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)askTargetFor:(int)cond {
    NSString *title = (cond == MEMREAD_VALCOND_DELTA) ? @"差值等于 N" : @"等于目标值";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"N";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"收敛" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        double t = [a.textFields[0].text doubleValue];
        [ws runRefine:cond target:t];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runRefine:(int)cond target:(double)t {
    if (self.currentPid <= 0) return;
    int vt = [self type];
    pid_t pid = self.currentPid;
    unsigned long long before = memread_valscan_count();

    [self.spinner startAnimating];
    [self clearProgress];
    self.statusLabel.text = @"收敛中";
    [self appendProgressLine:[NSString stringWithFormat:@"收敛开始  候选=%llu", before]];

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(ws) self2 = ws;
        if (!self2) return;

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        ScanProgCtx ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.vc = (__bridge void *)self2;
        ctx.total = before;
        ctx.start = t0;
        ctx.last = t0;

        unsigned long long left = 0;
        int rc = memread_valscan_refine(pid, vt, cond, t, RefineProgCb, &ctx, &left, NULL);
        double cost = CFAbsoluteTimeGetCurrent() - t0;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self2.spinner stopAnimating];
            self2.statusLabel.text = [NSString stringWithFormat:@"收敛完成 rc=%d 剩余=%llu", rc, left];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"收敛结束  rc=%d  %llu → %llu  用时 %.1f s", rc, before, left, cost]];
            [self2 refreshCount];
        });
    });
}

#pragma mark - 列表 / 保存

- (void)onList {
    if (memread_valscan_count() == 0) {
        self.statusLabel.text = @"没有候选，先做首扫";
        return;
    }
    ValueListViewController *vc = [[ValueListViewController alloc] init];
    vc.pid = self.currentPid;
    vc.type = [self type];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onSaved {
    SavedViewController *vc = [[SavedViewController alloc] init];
    vc.pid = [self ensurePid];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 画中画悬浮窗

- (void)onFloat {
    FloatPanelController *fp = [FloatPanelController shared];
    if (fp.isRunning) {
        [fp stop];
        self.statusLabel.text = @"悬浮窗已停止";
        [self appendProgressLine:@"悬浮窗已停止"];
        return;
    }
    if (memread_valscan_count() == 0) {
        self.statusLabel.text = @"先做一次首扫，悬浮窗才有候选可收敛";
        return;
    }
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自动收敛条件"
        message:@"每轮先探测是否变化，没变化就不动候选"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    void (^addCond)(NSString *, int) = ^(NSString *title, int cond) {
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            [ws askFloatInterval:cond];
        }]];
    };
    addCond(@"变小了", MEMREAD_VALCOND_DECREASED);
    addCond(@"变大了", MEMREAD_VALCOND_INCREASED);
    addCond(@"变了", MEMREAD_VALCOND_CHANGED);
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)askFloatInterval:(int)cond {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"收敛间隔"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    NSArray<NSString *> *names = @[@"1 秒", @"1.5 秒", @"2 秒", @"3 秒"];
    NSArray<NSNumber *> *vals = @[@1.0, @1.5, @2.0, @3.0];
    for (NSUInteger i = 0; i < names.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            [ws startFloatCond:cond interval:[vals[i] doubleValue]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)startFloatCond:(int)cond interval:(double)iv {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    BOOL ok = [[FloatPanelController shared] startWithPid:pid type:[self type] cond:cond interval:iv];
    if (ok) {
        self.statusLabel.text = @"悬浮窗已开启，直接切到游戏";
        [self appendProgressLine:[NSString stringWithFormat:@"画中画悬浮窗已开启  每 %.1f 秒自动收敛一次", iv]];
    } else {
        self.statusLabel.text = @"悬浮窗启动失败：设备不支持画中画或预览层未就绪";
        [self appendProgressLine:@"画中画启动失败"];
    }
}

- (void)onReset {
    memread_valscan_reset();
    self.statusLabel.text = @"已重置候选";
    [self appendProgressLine:@"已重置候选"];
    [self refreshCount];
}

@end
