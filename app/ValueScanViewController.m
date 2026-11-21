#import "ValueScanViewController.h"
#import "ValueListViewController.h"
#import "SavedViewController.h"
#import "SavedAddressStore.h"
#import "memread_core.h"
#import "FloatPanelController.h"
#include <string.h>
#include <stdlib.h>
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
@property (nonatomic, assign) void *coordA;      // memread_coord_hit_t*：结构扫描基准
@property (nonatomic, assign) int coordAn;
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
    switch (self.typeControl.selectedSegmentIndex) {
        case 0: return MEMREAD_VALTYPE_AUTO;
        case 2: return MEMREAD_VALTYPE_INT64;
        case 3: return MEMREAD_VALTYPE_FLOAT;
        case 4: return MEMREAD_VALTYPE_DOUBLE;
        default: return MEMREAD_VALTYPE_INT32;
    }
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

    self.typeControl = [[UISegmentedControl alloc] initWithItems:@[@"auto", @"int32", @"int64", @"float", @"double"]];
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
    [self addButton:@"未知值扫描（不知道数值）" width:W y:&y sel:@selector(onUnknown)];
    [self addButton:@"坐标扫描（走动→站定→跳）" width:W y:&y sel:@selector(onCoord)];
    [self addButton:@"坐标结构扫描（不用输坐标值）" width:W y:&y sel:@selector(onCoordProbe)];
    [self addButton:@"释放内存快照（省内存）" width:W y:&y sel:@selector(onFreeSnap)];
    [self addButton:@"查看候选列表（点一行读当前值）" width:W y:&y sel:@selector(onList)];
    [self addButton:@"已保存地址（自定义标签）" width:W y:&y sel:@selector(onSaved)];
    [self addButton:@"画中画悬浮窗（后台监控）" width:W y:&y sel:@selector(onFloat)];
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

    __weak typeof(self) ws = self;
    [FloatPanelController shared].statusHandler = ^(NSString *line) {
        [ws appendProgressLine:line];
    };

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onPiPSync:)
                                                 name:@"MemReadPiPSync"
                                               object:nil];

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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshCount];
}

// 悬浮窗自动收敛后同步回来：更新候选数、状态行、进度框
- (void)onPiPSync:(NSNotification *)n {
    unsigned long long before = [n.userInfo[@"before"] unsignedLongLongValue];
    unsigned long long after = [n.userInfo[@"after"] unsignedLongLongValue];
    BOOL zero = [n.userInfo[@"zero"] boolValue];
    if (zero) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"悬浮窗收敛会变成 0，已拒绝并停止，保留 %llu 条", after];
        [self appendProgressLine:[NSString stringWithFormat:
            @"悬浮窗收敛被拒 会变成 0，保留 %llu 条", after]];
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"悬浮窗收敛：%llu → %llu", before, after];
        [self appendProgressLine:[NSString stringWithFormat:@"悬浮窗收敛  %llu → %llu", before, after]];
    }
    [self refreshCount];
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
            if (rc == MEMREAD_VALSCAN_ZERO) {
                self2.statusLabel.text = [NSString stringWithFormat:
                    @"本轮会变成 0，已拒绝，保留 %llu 条", left];
                [self2 appendProgressLine:[NSString stringWithFormat:
                    @"收敛被拒 结果会是 0，候选原样保留 %llu 条  用时 %.1f s", left, cost]];
            } else {
                self2.statusLabel.text = [NSString stringWithFormat:@"收敛完成 rc=%d 剩余=%llu", rc, left];
                [self2 appendProgressLine:[NSString stringWithFormat:
                    @"收敛结束  rc=%d  %llu → %llu  用时 %.1f s", rc, before, left, cost]];
            }
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

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"监控对象"
        message:@"不同枪的弹匣地址不同：各枪弹匣各存一条「已保存地址」，就能一起盯"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"当前扫描候选（自动收敛）" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws askFloatCond]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"已保存地址（多把枪一起看）" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws askSavedInterval]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)askFloatCond {
    if (memread_valscan_count() == 0) {
        self.statusLabel.text = @"先做一次首扫，悬浮窗才有候选可收敛";
        return;
    }
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"自动收敛条件"
        message:@"在游戏里开火后点 PiP 暂停键＝按此条件收敛一次，不会按秒乱筛"
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
    [a addAction:[UIAlertAction actionWithTitle:@"只看候选数（不自动收敛）" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws askMonitorInterval]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)askMonitorInterval {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"刷新间隔"
                                                               message:@"只看模式不会动候选，收敛仍回 App 手动点"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    NSArray<NSString *> *names = @[@"0.5 秒", @"1 秒", @"2 秒", @"3 秒"];
    NSArray<NSNumber *> *vals = @[@0.5, @1.0, @2.0, @3.0];
    for (NSUInteger i = 0; i < names.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            [ws startFloatMonitor:[vals[i] doubleValue]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)startFloatMonitor:(double)iv {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    BOOL ok = [[FloatPanelController shared] startMonitorWithPid:pid type:[self type] interval:iv];
    if (ok) {
        self.statusLabel.text = @"只看模式已开启，直接切到游戏";
        [self appendProgressLine:[NSString stringWithFormat:@"画中画已开启：只看候选数与数值，每 %.1f 秒刷新", iv]];
    } else {
        self.statusLabel.text = @"悬浮窗启动失败：设备不支持画中画或预览层未就绪";
        [self appendProgressLine:@"画中画启动失败"];
    }
}

- (void)askSavedInterval {
    if ([[SavedAddressStore shared] count] == 0) {
        self.statusLabel.text = @"还没有已保存地址：先把各枪的弹匣地址存进去";
        return;
    }
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"刷新间隔"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    NSArray<NSString *> *names = @[@"0.5 秒", @"1 秒", @"2 秒", @"3 秒"];
    NSArray<NSNumber *> *vals = @[@0.5, @1.0, @2.0, @3.0];
    for (NSUInteger i = 0; i < names.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            [ws startFloatSaved:[vals[i] doubleValue]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)startFloatSaved:(double)iv {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    BOOL ok = [[FloatPanelController shared] startWatchSavedWithPid:pid interval:iv];
    if (ok) {
        self.statusLabel.text = @"地址监控已开启，直接切到游戏";
        [self appendProgressLine:[NSString stringWithFormat:@"画中画已开启：监控全部已保存地址，每 %.1f 秒刷新", iv]];
    } else {
        self.statusLabel.text = @"监控启动失败：没有已保存地址，或画中画不可用";
        [self appendProgressLine:@"地址监控启动失败"];
    }
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
        [self appendProgressLine:[NSString stringWithFormat:@"画中画已开启：开火后点 PiP 暂停键收敛一次（条件已设置，每 %.1f 秒刷新数据）", iv]];
    } else {
        self.statusLabel.text = @"悬浮窗启动失败：设备不支持画中画或预览层未就绪";
        [self appendProgressLine:@"画中画启动失败"];
    }
}

#pragma mark - 未知值扫描 / 坐标扫描

- (void)onFreeSnap {
    memread_snapshot_free();
    self.statusLabel.text = @"已释放内存快照";
    [self appendProgressLine:@"已释放内存快照"];
}

- (void)takeSnapshotThen:(void (^)(BOOL ok, unsigned long long bytes, unsigned long long regs))done {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"拍内存快照…";
    [self appendProgressLine:@"开始拍内存快照（整块可写内存，可能几百 MB）"];
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long bytes = 0, regs = 0;
        int rc = memread_unknown_snapshot(pid, &bytes, &regs);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            [self2.spinner stopAnimating];
            if (rc != 0) {
                self2.statusLabel.text = [NSString stringWithFormat:@"快照失败 rc=%d", rc];
                [self2 appendProgressLine:[NSString stringWithFormat:
                    @"快照失败 rc=%d（-4 内存/映射失败 / -5 超 2GB 上限 / -7 写文件失败 / -8 磁盘空间不足 / -1 取进程失败）", rc]];
                if (done) done(NO, 0, 0);
                return;
            }
            self2.statusLabel.text = [NSString stringWithFormat:@"快照完成：%llu MB / %llu 个区域",
                                      bytes / 1048576ULL, regs];
            [self2 appendProgressLine:[NSString stringWithFormat:@"快照完成：%llu MB / %llu 区",
                                      bytes / 1048576ULL, regs]];
            if (done) done(YES, bytes, regs);
        });
    });
}

#pragma mark 未知值

- (void)onUnknown {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未知值扫描"
                                                               message:@"① 保持当前状态别动，点『拍快照』。\n② 去游戏里做一次动作（开一枪 / 换弹 / 捡东西）。\n③ 回来选『变了 / 变大了 / 变小了』，就能筛出所有跟着变的地址。\n\n拍完可继续用普通『收敛』反复筛。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"拍快照" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws startUnknownSnapshot]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)startUnknownSnapshot {
    __weak typeof(self) ws = self;
    [self takeSnapshotThen:^(BOOL ok, unsigned long long bytes, unsigned long long regs) {
        if (ok) [ws askUnknownCond];
    }];
}

- (void)askUnknownCond {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"② 去游戏操作，然后回来选条件"
                                                               message:@"刚拍完快照。现在切到游戏开一枪或换弹，再回来点下面任一条件。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"变了" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws unknownDiff:MEMREAD_VALCOND_CHANGED]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"变大了" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws unknownDiff:MEMREAD_VALCOND_INCREASED]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"变小了" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws unknownDiff:MEMREAD_VALCOND_DECREASED]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消（释放快照）" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { memread_snapshot_free(); }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)unknownDiff:(int)cond {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"与快照比对中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long hits = 0;
        int rc = memread_unknown_diff(pid, cond, 0, NULL, NULL, &hits, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            [self2.spinner stopAnimating];
            memread_snapshot_free();   // 通用未知值一轮够用，快照可以放掉
            if (rc != 0) {
                NSString *why = (rc == MEMREAD_PROC_RESTARTED)
                    ? @"游戏进程已重启，快照作废，请重新拍"
                    : [NSString stringWithFormat:@"比对失败 rc=%d", rc];
                self2.statusLabel.text = why;
                [self2 appendProgressLine:why];
                return;
            }
            self2.statusLabel.text = [NSString stringWithFormat:@"未知值扫描完成：候选 %llu", hits];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"未知值扫描完成 条件=%d 候选=%llu（快照已释放）", cond, hits]];
            [self2 refreshCount];
            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"扫描完成"
                                                                       message:[NSString stringWithFormat:@"候选 %llu 条。\n之后点『收敛』可以继续按变化筛。", hits]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
        });
    });
}

#pragma mark 坐标结构扫描（不用知道坐标值）

- (void)onCoordProbe {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"坐标结构扫描"
                                                               message:@"不需要知道坐标值。判据是「3 个 float 坐标 + 紧跟一个模长=1 的四元数」，随机数据几乎不可能凑出来。\n\n① 站定别动 → 记录基准\n② 走 3~5 步、站住 → 对比，位移对得上就是人物坐标"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"① 站定：记录基准" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeSecond:NO]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"② 走动后：对比定位" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeSecond:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)coordProbeSecond:(BOOL)second {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    if (second && (!self.coordA || self.coordAn <= 0)) {
        [self appendProgressLine:@"还没有基准，先点『① 站定：记录基准』"];
        self.statusLabel.text = @"先记录基准";
        return;
    }
    [self.spinner startAnimating];
    self.statusLabel.text = second ? @"结构扫描：对比中…" : @"结构扫描：读内存中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int found = 0;
        int cap = MEMREAD_COORD_HIT_CAP;
        memread_coord_hit_t *buf = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)cap);
        int rc = buf ? memread_coord_probe(pid, buf, cap, &found, NULL, NULL, NULL) : -4;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(buf); return; }
            [self2.spinner stopAnimating];

            if (rc != 0) {
                free(buf);
                NSString *why = (rc == -1) ? @"读不到进程（先确认游戏在跑、App 已重绑）"
                                           : [NSString stringWithFormat:@"结构扫描失败 rc=%d", rc];
                self2.statusLabel.text = why;
                [self2 appendProgressLine:why];
                return;
            }

            if (!second) {
                memread_coord_hit_t *old = (memread_coord_hit_t *)self2.coordA;
                if (old) free(old);
                self2.coordA = buf;
                self2.coordAn = found;
                NSString *line = [NSString stringWithFormat:@"基准已记录：%d 个候选（只算结构合法的位置）", found];
                self2.statusLabel.text = line;
                [self2 appendProgressLine:line];
                UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"基准已记录"
                                                                           message:[NSString stringWithFormat:@"%d 个候选。\n现在回游戏走 3~5 步，站住，再回来点『② 走动后：对比定位』。", found]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [self2 presentViewController:ok animated:YES completion:nil];
                return;
            }

            memread_coord_hit_t *out = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)cap);
            int m = 0;
            if (out) {
                memread_coord_diff((memread_coord_hit_t *)self2.coordA, self2.coordAn,
                                   buf, found, out, cap, &m, 2.0f, 5000.0f);
            }
            free(buf);
            if (!out) {
                self2.statusLabel.text = @"内存不足";
                return;
            }

            if (m <= 0) {
                free(out);
                self2.statusLabel.text = @"没匹配上";
                [self2 appendProgressLine:@"没匹配上：走动幅度太小，或两次扫描之间角色没动。走远点（5~10 步）再试"];
                return;
            }

            uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)m);
            for (int i = 0; i < m; i++) addrs[i] = out[i].addr;
            memread_valscan_set(addrs, m, MEMREAD_VALTYPE_FLOAT);
            free(addrs);

            NSString *line = [NSString stringWithFormat:@"结构扫描匹配：%d 个（位移从大到小）", m];
            self2.statusLabel.text = line;
            [self2 appendProgressLine:line];
            [self2 refreshCount];

            NSMutableString *msg = [NSMutableString stringWithFormat:
                @"%d 个坐标字段跟着你动了。位移最大的最可能是人物根组件（相机/挂点也会动）。\n\n", m];
            for (int i = 0; i < m && i < 3; i++) {
                [msg appendFormat:@"%d) 0x%llX  (%.2f, %.2f, %.2f)%@\n", i + 1,
                 (unsigned long long)out[i].addr,
                 out[i].v[0], out[i].v[1], out[i].v[2],
                 (out[i].quat_off < 0) ? @"  平凡旋转" : @"  有旋转"];
            }
            free(out);

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已锁定坐标候选"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选（点『链』）" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
        });
    });
}

#pragma mark 坐标

- (void)onCoord {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"坐标扫描（4 步）"
                                                               message:@"① 站空地别动 → 拍快照\n② 走动几步（别跳、别开枪）→ 扫描走动\n③ 站住不动 → 静止过滤\n④ 原地跳一下 → 锁定坐标\n\n靠「走时 X/Z 变、跳时只有 Y 变」把三连 float 挑出来。快照占几百 MB 内存。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"① 拍快照" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws startCoordSnapshot]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)startCoordSnapshot {
    __weak typeof(self) ws = self;
    [self takeSnapshotThen:^(BOOL ok, unsigned long long bytes, unsigned long long regs) {
        if (ok) [ws askCoordWalk];
    }];
}

- (void)askCoordWalk {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"② 去走动几步"
                                                               message:@"切到游戏，向前/左右走 3~5 秒（不要跳、不要开枪、不要开镜），然后回来点『扫描走动』。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"扫描走动" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordWalk]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消（释放快照）" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { memread_snapshot_free(); }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)coordWalk {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"扫描走动产生的变化…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long hits = 0;
        int rc = memread_unknown_diff(pid, MEMREAD_VALCOND_CHANGED, 1, NULL, NULL, &hits, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            [self2.spinner stopAnimating];
            if (rc != 0) {
                memread_snapshot_free();
                NSString *why = (rc == MEMREAD_PROC_RESTARTED)
                    ? @"游戏进程已重启，快照作废，请从第①步重来"
                    : [NSString stringWithFormat:@"走动扫描失败 rc=%d", rc];
                self2.statusLabel.text = why;
                [self2 appendProgressLine:why];
                return;
            }
            if (hits == 0) {
                memread_snapshot_free();
                self2.statusLabel.text = @"没有检测到变化：走动太短或拍快照时也在动";
                [self2 appendProgressLine:@"走动扫描命中 0：重来一次（快照时站稳）"];
                return;
            }
            self2.statusLabel.text = [NSString stringWithFormat:@"走动变化候选 %llu", hits];
            [self2 appendProgressLine:[NSString stringWithFormat:@"走动变化候选 %llu（已只留 float 形状的地址）", hits]];
            [self2 refreshCount];
            [self2 askCoordStand];
        });
    });
}

- (void)askCoordStand {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"③ 站住别动"
                                                               message:@"人物站稳、视角别转，然后点『静止过滤』：把站着还在变的地址（计时器、粒子、UI）筛掉，并重新拍一次站立基线。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"静止过滤" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordStand]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消（释放快照）" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { memread_snapshot_free(); }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)coordStand {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"静止过滤 + 重拍基线…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long left = 0;
        int rc = memread_valscan_refine(pid, MEMREAD_VALTYPE_AUTO, MEMREAD_VALCOND_UNCHANGED,
                                        0, NULL, NULL, &left, NULL);
        unsigned long long bytes = 0, regs = 0;
        int src = 0;
        if (rc == 0) src = memread_unknown_snapshot(pid, &bytes, &regs);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            [self2.spinner stopAnimating];
            if (rc == MEMREAD_VALSCAN_ZERO) {
                memread_snapshot_free();
                self2.statusLabel.text = @"静止过滤把候选筛成 0，已保留原候选";
                [self2 appendProgressLine:@"静止过滤结果会是 0（可能走动时没真的位移），重来一次"];
                [self2 refreshCount];
                return;
            }
            if (rc != 0 || src != 0) {
                memread_snapshot_free();
                self2.statusLabel.text = [NSString stringWithFormat:@"静止过滤失败 rc=%d src=%d", rc, src];
                [self2 appendProgressLine:[NSString stringWithFormat:@"静止过滤失败 rc=%d 重拍基线=%d", rc, src]];
                return;
            }
            self2.statusLabel.text = [NSString stringWithFormat:@"静止过滤后候选 %llu（基线已更新）", left];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"静止过滤后候选 %llu，重拍基线 %llu MB", left, bytes / 1048576ULL]];
            [self2 refreshCount];
            [self2 askCoordJump];
        });
    });
}

- (void)askCoordJump {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"④ 原地跳一下"
                                                               message:@"只按跳跃键，不要按方向键。落地后回来点『锁定坐标』。\n判定：三连 float 里恰好一个变了，且变的是竖直轴，不是走动时变的那两个。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"锁定坐标" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordJump]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消（释放快照）" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { memread_snapshot_free(); }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)coordJump {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"锁定坐标三连…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int triplets = 0;
        unsigned long long cands = 0;
        int rc = memread_coord_lock(pid, &triplets, &cands, NULL, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            [self2.spinner stopAnimating];
            memread_snapshot_free();
            if (rc != 0) {
                NSString *why = (rc == MEMREAD_PROC_RESTARTED)
                    ? @"游戏进程已重启，快照作废，请从第①步重来"
                    : [NSString stringWithFormat:@"坐标锁定失败 rc=%d", rc];
                self2.statusLabel.text = why;
                [self2 appendProgressLine:why];
                return;
            }
            if (triplets == 0) {
                self2.statusLabel.text = @"没锁定到坐标三连";
                [self2 appendProgressLine:@"没锁定到坐标三连：跳跃时是否也在移动？重来一次，跳的时候别按方向键"];
                return;
            }
            self2.statusLabel.text = [NSString stringWithFormat:@"锁定 %d 组坐标（%llu 条候选）", triplets, cands];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"锁定 %d 组坐标，共 %llu 条 float 候选（每 3 条一组 X/Y/Z 连续）", triplets, cands]];
            [self2 refreshCount];

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已锁定坐标"
                                                                       message:[NSString stringWithFormat:@"%d 组三连 float，共 %llu 条候选。\n列表里每 3 条一组（0x…0 / +4 / +8），点『读』边走边看它们是否平滑变化。", triplets, cands]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
        });
    });
}

- (void)onReset {
    memread_valscan_reset();
    self.statusLabel.text = @"已重置候选";
    [self appendProgressLine:@"已重置候选"];
    [self refreshCount];
}

@end
