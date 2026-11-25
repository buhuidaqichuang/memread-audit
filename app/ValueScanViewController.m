#import "ValueScanViewController.h"
#import "ValueListViewController.h"
#import "SavedViewController.h"
#import "SavedAddressStore.h"
#import "memread_core.h"
#import "FloatPanelController.h"
#include <dlfcn.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/task.h>

extern kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *t);
#include <string.h>
#include <stdlib.h>
#include <QuartzCore/QuartzCore.h>

// ⑧ 一键读自己坐标：按 XY 聚类用的比较器
static int MemCmpCoordXY(const void *a, const void *b) {
    const memread_coord_hit_t *p = (const memread_coord_hit_t *)a;
    const memread_coord_hit_t *q = (const memread_coord_hit_t *)b;
    long px = lroundf(p->v[0] * 100.0f), py = lroundf(p->v[1] * 100.0f);
    long qx = lroundf(q->v[0] * 100.0f), qy = lroundf(q->v[1] * 100.0f);
    if (px != qx) return px < qx ? -1 : 1;
    if (py != qy) return py < qy ? -1 : 1;
    return 0;
}


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
@property (nonatomic, assign) void *coordB;      // 走动对比后的候选
@property (nonatomic, assign) int coordBn;
@property (nonatomic, assign) BOOL coordCandidates;   // 当前候选来自坐标扫描（列表按三元组显示）

// ⑤ 后台自动捕捉（画中画保活，人不用切来切去）
@property (nonatomic, strong) NSTimer *autoTimer;
@property (nonatomic, assign) uint64_t *autoAddrs;
@property (nonatomic, assign) float *autoPrev;
@property (nonatomic, assign) int autoN;
@property (nonatomic, assign) int *autoMoved;   // 走动期间变过几次
@property (nonatomic, assign) int *autoVert;    // 只动竖直轴（蹲下）几次
@property (nonatomic, assign) float *autoMax;   // 最大位移
@property (nonatomic, assign) int autoTicks;
@property (nonatomic, assign) BOOL autoRunning;
- (void)appendProgressLine:(NSString *)line;
- (void)clearProgress;
- (int)autoVertCount;
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
    [self addButton:@"⑤ 后台自动捕捉坐标（不用切来切去）" width:W y:&y sel:@selector(onAutoCapture)];
    [self addButton:@"⑥ 弹夹→自己坐标（不用动）" width:W y:&y sel:@selector(onAnchorCoord)];
    [self addButton:@"⑦ 能力探测（tfp / 内核原语）" width:W y:&y sel:@selector(onCapProbe)];
    [self addButton:@"⑨ 靶位 3D 上屏（画中画）" width:W y:&y sel:@selector(onTargetsToPiP)];
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
    self.coordCandidates = NO;

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
    self.coordCandidates = NO;
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
    vc.vec3 = self.coordCandidates;
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

#pragma mark ⑦ 能力探测（task_for_pid / 内核原语 / 越狱路径）

static pid_t probe_pid_by_name(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return 0;
    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(sz);
    if (!kp) return 0;
    if (sysctl(mib, 4, kp, &sz, NULL, 0) != 0) { free(kp); return 0; }
    pid_t found = 0;
    int cnt = (int)(sz / sizeof(struct kinfo_proc));
    for (int i = 0; i < cnt; i++) {
        if (strcmp(kp[i].kp_proc.p_comm, name) == 0) { found = kp[i].kp_proc.p_pid; break; }
    }
    free(kp);
    return found;
}

static NSString *probe_tfp(pid_t pid) {
    if (pid <= 0) return @"进程没找到";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr == KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        return [NSString stringWithFormat:@"允许 (pid %d)", pid];
    }
    return [NSString stringWithFormat:@"被拒 kr=%d (pid %d)", kr, pid];
}

- (void)onCapProbe {
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"自身 pid=%d  euid=%d\n", getpid(), geteuid()];
    [r appendFormat:@"游戏进程 tfp：%@\n", probe_tfp([self ensurePid])];
    [r appendFormat:@"SpringBoard tfp：%@\n", probe_tfp(probe_pid_by_name("SpringBoard"))];
    [r appendFormat:@"launchd tfp：%@\n", probe_tfp(probe_pid_by_name("launchd"))];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *paths[] = { @"/var/jb", @"/var/jb/usr/lib/libjailbreak.dylib",
                          @"/var/jb/usr/lib/libkfd.dylib", @"/usr/lib/libjailbreak.dylib",
                          @"/var/jb/usr/bin/ldid", @"/var/jb/usr/lib/libsubstrate.dylib" };
    [r appendString:@"\n路径：\n"];
    for (int i = 0; i < 6; i++) {
        [r appendFormat:@"  %@  %@\n", paths[i], [fm fileExistsAtPath:paths[i]] ? @"有" : @"无"];
    }

    [r appendString:@"\n内核原语符号：\n"];
    void *h = dlopen("/var/jb/usr/lib/libjailbreak.dylib", RTLD_NOW);
    [r appendFormat:@"  libjailbreak dlopen：%@\n", h ? @"成功" : @"失败"];
    void *kfd = dlopen("/var/jb/usr/lib/libkfd.dylib", RTLD_NOW);
    [r appendFormat:@"  libkfd dlopen：%@\n", kfd ? @"成功" : @"失败"];

    const char *syms[] = { "kread64", "kwrite64", "kread", "kwrite", "physrw_read",
                           "physread", "kfd_open", "jbclient_query_primitive" };
    for (int i = 0; i < 8; i++) {
        void *p = dlsym(RTLD_DEFAULT, syms[i]);
        if (!p && h) p = dlsym(h, syms[i]);
        if (!p && kfd) p = dlsym(kfd, syms[i]);
        [r appendFormat:@"  %-24s %@\n", syms[i], p ? @"有" : @"无"];
    }
    if (h) dlclose(h);
    if (kfd) dlclose(kfd);

    [r appendString:@"\n判读：SpringBoard/launchd 都「允许」= 有内核协助或 entitlements 全开；\n"
                    @"只有游戏进程「允许」= 用户态越狱 + App 未加固；\n"
                    @"kread/kwrite/physrw 任一「有」= 真有内核读写原语。"];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"⑦ 能力探测"
                                                               message:r
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    [self appendProgressLine:r];
}

#pragma mark ⑥ 从弹夹锚点推自己坐标（不用人工动作）

#pragma mark ⑧ 一键读自己坐标（扫一次，自动挑出本角色）
- (void)onSelfCoord {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"⑧ 扫描中（10~15 秒），这期间别切出游戏太多…";
    [self appendProgressLine:@"⑧ 开始扫一次，按『多副本 + Z 跨到头顶』挑自己那一簇"];
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        memread_coord_hit_t *hits = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
        int found = 0;
        int rc = hits ? memread_coord_probe(pid, hits, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL) : -4;

        int bestCnt = 0; float bx = 0, by = 0, blo = 0, bhi = 0;
        uint64_t feetAddr = 0, camAddr = 0;
        if (rc == 0 && found > 0) {
            qsort(hits, (size_t)found, sizeof(memread_coord_hit_t), MemCmpCoordXY);
            int i = 0;
            while (i < found) {
                int j = i + 1;
                while (j < found && MemCmpCoordXY(&hits[i], &hits[j]) == 0) j++;
                int cnt = j - i;
                float lo = hits[i].v[2], hi = hits[i].v[2];
                int loK = i, hiK = i;
                for (int k = i; k < j; k++) {
                    if (hits[k].v[2] < lo) { lo = hits[k].v[2]; loK = k; }
                    if (hits[k].v[2] > hi) { hi = hits[k].v[2]; hiK = k; }
                }
                float ax = fabsf(hits[i].v[0]), ay = fabsf(hits[i].v[1]);
                if (cnt >= 8 && (hi - lo) >= 60.0f && hi > 120.0f &&
                    (ax > 50.0f || ay > 50.0f) && cnt > bestCnt) {
                    bestCnt = cnt; bx = hits[i].v[0]; by = hits[i].v[1]; blo = lo; bhi = hi;
                    feetAddr = hits[loK].addr; camAddr = hits[hiK].addr;
                }
                i = j;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(hits); return; }
            [self2.spinner stopAnimating];
            if (!hits) return;
            if (rc != 0 || found <= 0 || bestCnt == 0) {
                self2.statusLabel.text = [NSString stringWithFormat:@"⑧ 没找到（命中 %d）", found];
                [self2 appendProgressLine:(rc != 0
                    ? [NSString stringWithFormat:@"⑧ 扫描失败 rc=%d（游戏可能在加载/lobby，命中 %d）", rc, found]
                    : [NSString stringWithFormat:@"⑧ 命中 %d 条，但没有符合『多副本+Z跨到头顶』的簇：世界可能还没加载", found])];
                free(hits);
                return;
            }

            uint64_t addrs[3] = { feetAddr, camAddr, 0 };
            memread_valscan_set(pid, addrs, 2, MEMREAD_VALTYPE_FLOAT);
            self2.coordCandidates = YES;
            self2.countLabel.text = @"候选: 2（脚底 / 相机）";
            self2.statusLabel.text = [NSString stringWithFormat:@"⑧ 自己坐标 feet=(%.2f, %.2f, %.2f)", bx, by, blo];

            NSString *msg = [NSString stringWithFormat:
                @"脚底  (%.4f, %.4f, %.4f)   addr=0x%llX\n相机  (%.4f, %.4f, %.4f)   addr=0x%llX\n\n副本 %d 份，Z 跨度 %.1f（脚底→头顶）。\n判据：副本数≥8 且 Z 跨到 120 以上、XY 不贴原点。\n\n这两个地址此后只读 12 字节，安全，不会闪退。",
                bx, by, blo, (unsigned long long)feetAddr,
                bx, by, bhi, (unsigned long long)camAddr,
                bestCnt, bhi - blo];
            [self2 appendProgressLine:[NSString stringWithFormat:@"⑧ 脚底 0x%llX / 相机 0x%llX（副本 %d）",
                                       (unsigned long long)feetAddr, (unsigned long long)camAddr, bestCnt]];
            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"⑧ 你自己角色的世界坐标"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self2 presentViewController:ok animated:YES completion:nil];
            free(hits);
        });
    });
}

#pragma mark ⑨ 靶位坐标上屏（画中画）

- (void)onTargetsToPiP {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"⑨ 宽松扫描一次（10~15 秒）…";
    [self appendProgressLine:@"⑨ 判据：副本 n≤3 + 相对脚底 95~140 + 不贴原点，取身边最近的 9 条"];

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        memread_coord_hit_t *hits = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * MEMREAD_COORD_HIT_CAP);
        int found = 0;
        setenv("MEMREAD_LOOSE", "1", 1);
        int rc = hits ? memread_coord_probe(pid, hits, MEMREAD_COORD_HIT_CAP, &found, NULL, NULL, NULL) : -4;

        float selfX = 0, selfY = 0, feetZ = 0;
        int haveSelf = 0, bestCnt = 0, hitCap = 0;

        if (rc == 0 && found > 0) {
            qsort(hits, (size_t)found, sizeof(memread_coord_hit_t), MemCmpCoordXY);

            // 第一遍：找自己那一簇（副本≥8 且 Z 跨度≥60）→ 当 XY 基准与脚底 Z 基准
            int i = 0;
            while (i < found) {
                int j = i + 1;
                while (j < found && MemCmpCoordXY(&hits[i], &hits[j]) == 0) j++;
                int cnt = j - i;
                float lo = hits[i].v[2], hi = hits[i].v[2];
                for (int k = i; k < j; k++) {
                    if (hits[k].v[2] < lo) lo = hits[k].v[2];
                    if (hits[k].v[2] > hi) hi = hits[k].v[2];
                }
                float ax = fabsf(hits[i].v[0]), ay = fabsf(hits[i].v[1]);
                if (cnt >= 8 && (hi - lo) >= 60.0f && (ax > 50.0f || ay > 50.0f) && cnt > bestCnt) {
                    bestCnt = cnt;
                    selfX = hits[i].v[0];
                    selfY = hits[i].v[1];
                    feetZ = lo;
                    haveSelf = 1;
                }
                i = j;
            }
            if (!haveSelf) feetZ = 0;   // 找不到自己：退回绝对高度窗口（95~140）

            // 第二遍：按「少副本 + 躯干高度 + 非原点」挑候选
            NSMutableArray<NSDictionary *> *cands = [NSMutableArray array];
            int i2 = 0;
            while (i2 < found) {
                int j2 = i2 + 1;
                while (j2 < found && MemCmpCoordXY(&hits[i2], &hits[j2]) == 0) j2++;
                int cnt = j2 - i2;
                if (cnt <= 3) {
                    float x = hits[i2].v[0], y = hits[i2].v[1], z = hits[i2].v[2];
                    float rel = z - feetZ;
                    BOOL origin = (fabsf(x) < 50.0f && fabsf(y) < 50.0f);
                    BOOL selfLayer = (fabsf(rel - 86.0f) < 1.5f);
                    if (!origin && !selfLayer && rel >= 95.0f && rel <= 140.0f) {
                        float dx = x - selfX, dy = y - selfY;
                        float d = sqrtf(dx * dx + dy * dy);
                        [cands addObject:@{@"d": @(d), @"x": @(x), @"y": @(y),
                                           @"z": @(z), @"rel": @(rel),
                                           @"addr": @((unsigned long long)hits[i2].addr)}];
                    }
                }
                i2 = j2;
            }
            [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                double da = [a[@"d"] doubleValue], db = [b[@"d"] doubleValue];
                if (da < db) return NSOrderedAscending;
                if (da > db) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            hitCap = (int)cands.count;
            NSMutableArray<NSString *> *labels = [NSMutableArray array];
            NSMutableArray<NSNumber *> *addrs = [NSMutableArray array];
            NSMutableString *lines = [NSMutableString string];
            for (NSUInteger k = 0; k < cands.count && k < 9; k++) {
                NSDictionary *c = cands[k];
                NSString *name = [NSString stringWithFormat:@"T%lu", (unsigned long)(k + 1)];
                [labels addObject:name];
                [addrs addObject:c[@"addr"]];
                [lines appendFormat:@"%@  %.2fm  (%.2f, %.2f)  Z %.2f  0x%llX\n",
                    name, [c[@"d"] doubleValue] / 100.0, [c[@"x"] doubleValue],
                    [c[@"y"] doubleValue], [c[@"z"] doubleValue],
                    [c[@"addr"] unsignedLongLongValue]];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ws) self2 = ws;
                if (!self2) { free(hits); return; }
                [self2.spinner stopAnimating];
                if (labels.count == 0) {
                    self2.statusLabel.text = [NSString stringWithFormat:@"⑨ 没挑到靶位（命中 %d）", found];
                    [self2 appendProgressLine:[NSString stringWithFormat:
                        @"⑨ 命中 %d 条但没通过判据：可能世界未加载，或周围没有靶子", found]];
                    free(hits);
                    return;
                }
                [[FloatPanelController shared] setCoordOriginX:selfX y:selfY z:feetZ];
                BOOL ok = [[FloatPanelController shared] startWatchCoordsWithPid:pid
                                                                      labels:labels
                                                                       addrs:addrs
                                                                    interval:1.0];
                if (ok) {
                    self2.statusLabel.text = [NSString stringWithFormat:@"⑨ 已上屏 %lu 条，直接切游戏",
                                               (unsigned long)labels.count];
                    [self2 appendProgressLine:[NSString stringWithFormat:@"⑨ 候选 %d 条，上屏前 %lu 条（基准 %@，脚底Z %.2f）：\n%@",
                        hitCap, (unsigned long)labels.count,
                        haveSelf ? @"自己" : @"原点", feetZ, lines]];
                } else {
                    self2.statusLabel.text = @"⑨ 上屏失败：画中画不可用或预览层未就绪";
                    [self2 appendProgressLine:@"⑨ 画中画启动失败（先确认底部预览框是黑的且设备支持 PiP）"];
                }
                free(hits);
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(hits); return; }
            [self2.spinner stopAnimating];
            self2.statusLabel.text = [NSString stringWithFormat:@"⑨ 扫描失败 rc=%d 命中=%d", rc, found];
            [self2 appendProgressLine:[NSString stringWithFormat:
                @"⑨ 扫描失败 rc=%d（游戏在 lobby/加载时命中很少，等进战场再点）", rc]];
            free(hits);
        });
    });
}


    if (pid <= 0) return;
    SavedAddress *pick = nil;
    NSArray<SavedAddress *> *items = [[SavedAddressStore shared] allItems];
    for (SavedAddress *it in items) {
        NSString *t = [NSString stringWithFormat:@"%@%@", it.label ?: @"", it.group ?: @""];
        if ([t rangeOfString:@"弹"].location != NSNotFound) { pick = it; break; }
    }
    if (!pick) {
        for (SavedAddress *it in items) if (it.type == MEMREAD_VALTYPE_FLOAT) { pick = it; break; }
    }
    if (!pick) {
        UIAlertController *e = [UIAlertController alertControllerWithTitle:@"没有锚点"
                                                                  message:@"先在『已保存地址』里存一条弹夹地址（M4A1 那个 45.0 就行），再来点这里。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:e animated:YES completion:nil];
        return;
    }

    uint64_t anchor = pick.addr;
    [self.spinner startAnimating];
    self.statusLabel.text = @"⑥ 从弹夹对象往外走指针…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int cap = 60, found = 0, objs = 0;
        memread_anchor_coord_t *out = (memread_anchor_coord_t *)malloc(sizeof(memread_anchor_coord_t) * (size_t)cap);
        int rc = out ? memread_coord_from_anchor(pid, anchor, 4, out, cap, &found, &objs) : -4;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(out); return; }
            [self2.spinner stopAnimating];
            NSString *diag = [NSString stringWithFormat:@"锚点 0x%llX（%@）· 走过 %d 个对象 · 坐标 %d 个",
                              (unsigned long long)anchor, pick.label.length ? pick.label : @"float",
                              objs, found];
            [self2 appendProgressLine:diag];
            if (rc != 0 || found <= 0) {
                free(out);
                NSString *why = (rc == -3) ? @"锚点附近没找到对象基址（这条弹夹地址可能不在对象字段里，或对象头不是 vtable 形态）"
                    : (rc == 2 ? @"模块还没加载，稍后再试"
                               : [NSString stringWithFormat:@"⑥ 失败 rc=%d", rc]);
                self2.statusLabel.text = @"⑥ 没推出来";
                [self2 appendProgressLine:why];
                return;
            }

            uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)found);
            for (int i = 0; i < found; i++) addrs[i] = out[i].coord_addr;
            memread_valscan_set(pid, addrs, found, MEMREAD_VALTYPE_FLOAT);
            free(addrs);
            self2.coordCandidates = YES;
            [self2 refreshCount];

            NSMutableString *msg = [NSMutableString stringWithFormat:@"%@\n\n", diag];
            for (int i = 0; i < found && i < 6; i++) {
                [msg appendFormat:@"%d) 0x%llX  (%.1f, %.1f, %.1f)  层%d\n", i + 1,
                 (unsigned long long)out[i].coord_addr, out[i].v[0], out[i].v[1], out[i].v[2], out[i].depth];
            }
            [msg appendString:@"\n这些是从弹夹对象沿指针走出来的组件变换，通常第 1~2 条里就有自己根组件。\n点『查看候选』可直接对每条点『链』。"];
            free(out);

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"⑥ 从弹夹推出来的坐标"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
            self2.statusLabel.text = [NSString stringWithFormat:@"⑥ 坐标 %d 个（层浅优先）", found];
        });
    });
}

#pragma mark ⑤ 后台自动捕捉坐标（画中画保活，一次回 App 出结果）

- (void)onAutoCapture {
    if (self.autoRunning) { [self onAutoFinish]; return; }
    if (memread_valscan_count() == 0) {
        self.statusLabel.text = @"先做 ①→②，拿到候选再来";
        [self appendProgressLine:@"⑤ 需要先有候选：先 ① 站定记基准，② 走动后对比"];
        return;
    }
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;

    int n = (int)memread_valscan_count();
    if (n > 300) n = 300;
    self.autoAddrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)n);
    self.autoPrev = (float *)calloc((size_t)n * 3, sizeof(float));
    self.autoMoved = (int *)calloc((size_t)n, sizeof(int));
    self.autoVert = (int *)calloc((size_t)n, sizeof(int));
    self.autoMax = (float *)calloc((size_t)n, sizeof(float));
    if (!self.autoAddrs || !self.autoPrev || !self.autoMoved || !self.autoVert || !self.autoMax) {
        [self appendProgressLine:@"⑤ 内存分配失败"];
        return;
    }
    for (int i = 0; i < n; i++) {
        uint64_t a = 0, pv = 0;
        int vt = MEMREAD_VALTYPE_FLOAT;
        if (memread_valscan_get_ex((unsigned long long)i, &a, &pv, &vt) != 0) a = 0;
        self.autoAddrs[i] = a;
    }
    self.autoN = n;
    self.autoTicks = 0;
    memread_read_vec3_batch(pid, self.autoAddrs, n, self.autoPrev);

    self.autoRunning = YES;
    self.statusLabel.text = @"后台采样中：走动 → 蹲下";
    [self appendProgressLine:[NSString stringWithFormat:
        @"⑤ 已开始后台采样（%d 条候选，每 0.5 秒一帧）。\n   现在回游戏：走几步 → 站住 → 蹲下（保持 1 秒）→ 起身。\n   做完回这里再点一次『⑤ 后台自动捕捉坐标』出结果。", n]];

    // 画中画保活：PiP 在跑，App 才不会被挂起，定时器才能继续采样
    if (![FloatPanelController shared].isRunning) {
        [[FloatPanelController shared] startMonitorWithPid:pid type:[self type] interval:1.0];
        [self appendProgressLine:@"   已开画中画保活（跑在游戏上层），采样继续"];
    }

    __weak typeof(self) ws = self;
    self.autoTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        __strong typeof(ws) self2 = ws;
        if (self2) [self2 onAutoTick];
    }];
}

- (void)onAutoTick {
    if (!self.autoRunning || self.autoN <= 0 || self.currentPid <= 0) return;
    int n = self.autoN;
    float *cur = (float *)malloc(sizeof(float) * (size_t)n * 3);
    if (!cur) return;
    int ok = memread_read_vec3_batch(self.currentPid, self.autoAddrs, n, cur);
    if (ok <= 0) { free(cur); return; }
    int changed = 0;
    for (int i = 0; i < n; i++) {
        float dx = cur[i * 3] - self.autoPrev[i * 3];
        float dy = cur[i * 3 + 1] - self.autoPrev[i * 3 + 1];
        float dz = cur[i * 3 + 2] - self.autoPrev[i * 3 + 2];
        float len = sqrtf(dx * dx + dy * dy + dz * dz);
        if (len > 1.0f) {
            changed++;
            self.autoMoved[i] = MIN(self.autoMoved[i] + 1, 9999);
            if (len > self.autoMax[i]) self.autoMax[i] = len;
        }
        // 蹲下：一个轴动 >=10，另两轴 <=5
        float dd[3] = {dx, dy, dz};
        int big = 0, small = 0;
        for (int k = 0; k < 3; k++) {
            if (fabsf(dd[k]) >= 10.0f) big++;
            else if (fabsf(dd[k]) <= 5.0f) small++;
        }
        if (big == 1 && small == 2) self.autoVert[i] = MIN(self.autoVert[i] + 1, 9999);
    }
    memcpy(self.autoPrev, cur, sizeof(float) * (size_t)n * 3);
    free(cur);
    self.autoTicks++;
    self.countLabel.text = [NSString stringWithFormat:@"采样 %d 帧 · 本帧变化 %d 条 · 蹲下命中 %d 条",
                            self.autoTicks, changed, [self autoVertCount]];
}

- (int)autoVertCount {
    int c = 0;
    for (int i = 0; i < self.autoN; i++) if (self.autoVert[i] > 0) c++;
    return c;
}

- (void)onAutoFinish {
    [self.autoTimer invalidate];
    self.autoTimer = nil;
    self.autoRunning = NO;
    int n = self.autoN;
    if (n <= 0) return;

    // 第一步：先排除「一直在变」的——采样里变动帧数占比 >= 70% 的直接判死
    // （坐标只在走动/蹲下那几个帧变，一直变的必然是计时器/粒子/相机抖动）
    int ticks = self.autoTicks > 0 ? self.autoTicks : 1;
    int *stable = (int *)malloc(sizeof(int) * (size_t)n);
    int ns = 0, dropped = 0;
    for (int i = 0; i < n; i++) {
        if (self.autoMoved[i] * 10 >= ticks * 7) { dropped++; continue; }   // 一直变 → 无效
        stable[ns++] = i;
    }

    // 第二步：留下的里面取「走动时变过 且 蹲下时只动竖直轴」
    int *pick = (int *)malloc(sizeof(int) * (size_t)ns + 1);
    int m = 0;
    for (int k = 0; k < ns; k++) {
        int i = stable[k];
        if (self.autoMoved[i] > 0 && self.autoVert[i] > 0) pick[m++] = i;
    }
    if (m == 0) {
        // 没捕捉到蹲下（可能没蹲/挂起）：退回「走动时变过」里位移最大的前 50
        for (int k = 0; k < ns; k++) {
            int i = stable[k];
            if (self.autoMoved[i] > 0) pick[m++] = i;
        }
        for (int i = 1; i < m; i++) {
            int key = pick[i], j = i - 1;
            while (j >= 0 && self.autoMax[pick[j]] < self.autoMax[key]) { pick[j + 1] = pick[j]; j--; }
            pick[j + 1] = key;
        }
        if (m > 50) m = 50;
    }
    free(stable);

    if (m == 0) {
        free(pick);
        self.statusLabel.text = @"⑤ 没捕捉到变化";
        [self appendProgressLine:@"⑤ 一帧都没变化：游戏在前台被挂起了？先确认画中画在播、进程号没过期"];
        return;
    }

    uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)m);
    for (int i = 0; i < m; i++) addrs[i] = self.autoAddrs[pick[i]];
    memread_valscan_set(self.currentPid, addrs, m, MEMREAD_VALTYPE_FLOAT);
    free(addrs);
    self.coordCandidates = YES;
    [self refreshCount];

    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"采样 %d 帧，候选 %d → %d 条（先剔掉「一直在变」%d 条）。\n\n", self.autoTicks, n, m, dropped];
    float *vals = (float *)malloc(sizeof(float) * (size_t)m * 3);
    if (vals) {
        uint64_t *tmp = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)m);
        for (int i = 0; i < m; i++) tmp[i] = self.autoAddrs[pick[i]];
        memread_read_vec3_batch(self.currentPid, tmp, m, vals);
        free(tmp);
    }
    for (int i = 0; i < m && i < 5; i++) {
        int k = pick[i];
        if (vals) {
            [msg appendFormat:@"%d) 0x%llX  (%.1f, %.1f, %.1f)\n", i + 1,
             (unsigned long long)self.autoAddrs[k], vals[i * 3], vals[i * 3 + 1], vals[i * 3 + 2]];
        }
    }
    free(vals);
    free(pick);

    [msg appendString:@"\n点『查看候选』进去点每行的『链』，找跨重启的静态路径。"];

    UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"⑤ 自动捕捉完成"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ok addAction:[UIAlertAction actionWithTitle:@"查看候选" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws onList]; }]];
    [self presentViewController:ok animated:YES completion:nil];
    [self appendProgressLine:[NSString stringWithFormat:@"⑤ 完成：%d 条（先剔除一直变的 %d 条；走动变过 + 蹲下只动竖直轴）", m, dropped]];
    self.statusLabel.text = [NSString stringWithFormat:@"⑤ 完成：%d 条候选", m];

    if (self.autoAddrs) { free(self.autoAddrs); self.autoAddrs = NULL; }
    if (self.autoPrev) { free(self.autoPrev); self.autoPrev = NULL; }
    if (self.autoMoved) { free(self.autoMoved); self.autoMoved = NULL; }
    if (self.autoVert) { free(self.autoVert); self.autoVert = NULL; }
    if (self.autoMax) { free(self.autoMax); self.autoMax = NULL; }
    self.autoN = 0;
}

#pragma mark 坐标结构扫描（不用知道坐标值）

- (void)onCoordProbe {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"坐标结构扫描"
                                                               message:@"四步，全程不用输坐标值。判据是「完整 FTransform（四元数 + 位移 + scale≈1）」，配合「走动时变、蹲下时只降竖直轴」。\n\n① 站定别动 → 记录基准\n② 走 3~5 步、站住 → 对比，留下动过的\n③ 蹲下（趴下也行，别起身）→ 回来点③：只留「一个轴降、水平不动」的，筛到个位数\n\n注意：跳跃抓不到——切回 App 只要两秒，人已经落地了，所以用能保持住的蹲姿\n④（可选）站住原地转视角 → 把跟着镜头走的那份筛掉"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"① 站定：记录基准" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeSecond:NO]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"② 走动后：对比定位" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeSecond:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"③ 蹲下：筛到个位数" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeJump]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"④ 转视角（可选）" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws coordProbeStill]; }]];
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
    memread_coord_hit_t *base = (memread_coord_hit_t *)self.coordA;
    int nbase = self.coordAn;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int found = 0;
        int cap = MEMREAD_COORD_HIT_CAP;
        int common = 0, moved = 0;
        float maxdelta = 0;
        memread_coord_hit_t *buf = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)cap);
        int rc;
        if (!second) {
            rc = buf ? memread_coord_probe(pid, buf, cap, &found, NULL, NULL, NULL) : -4;
        } else {
            int m = 0;
            rc = buf ? memread_coord_probe_diff(pid, base, nbase,
                                                buf, cap, &m, &common, &moved, &maxdelta,
                                                1.0f, 20000.0f, NULL, NULL, NULL) : -4;
            found = m;
        }
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
                int k[4] = {0, 0, 0, 0};
                for (int i = 0; i < found; i++) {
                    int q = buf[i].quat_off;
                    int kk = (q == 100) ? 3 : ((q == 0) ? 2 : ((q < 0) ? 1 : 0));
                    k[kk]++;
                }
                NSString *comp = [NSString stringWithFormat:
                    @"四元数 %d · 平凡 %d · FTransform %d · 角度 %d", k[0], k[1], k[2], k[3]];
                NSString *line = [NSString stringWithFormat:@"基准已记录：%d 个候选（%@）", found, comp];
                self2.statusLabel.text = line;
                [self2 appendProgressLine:line];
                UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"基准已记录"
                                                                           message:[NSString stringWithFormat:@"%d 个候选（%@）。\n\n现在回游戏走 3~5 步，站住，再回来点『② 走动后：对比定位』。", found, comp]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [self2 presentViewController:ok animated:YES completion:nil];
                return;
            }

            NSString *diag = [NSString stringWithFormat:
                @"基准 %d 个 · 命中 %d 个 · 同地址 %d 个 · 位移非零 %d 个 · 最大位移 %.1f",
                self2.coordAn, found, common, moved, maxdelta];
            [self2 appendProgressLine:diag];

            if (found <= 0) {
                free(buf);
                NSString *why;
                if (common == 0) {
                    why = @"两次扫描没有一个地址重合：基准候选被上限截断了（噪声太多），或者两次之间游戏重启了。";
                } else if (moved == 0) {
                    why = @"同地址的候选完全没变：两次扫描之间角色没动，或者游戏在后台被挂起了。走动时先让游戏在前台跑几秒。";
                } else {
                    why = @"有变化但位移不在 1~20000 之间（可能单位很大或只是抖动）。";
                }
                self2.statusLabel.text = @"没匹配上";
                [self2 appendProgressLine:why];
                [self2 appendProgressLine:diag];
                UIAlertController *e = [UIAlertController alertControllerWithTitle:@"没匹配上"
                                                                           message:[why stringByAppendingFormat:@"\n\n%@", diag]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [self2 presentViewController:e animated:YES completion:nil];
                return;
            }

            uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)found);
            for (int i = 0; i < found; i++) addrs[i] = buf[i].addr;
            memread_valscan_set(pid, addrs, found, MEMREAD_VALTYPE_FLOAT);
            free(addrs);
            self2.coordCandidates = YES;

            // 这批候选留作 ③ 静止过滤的基准
            memread_coord_hit_t *oldb = (memread_coord_hit_t *)self2.coordB;
            if (oldb) free(oldb);
            self2.coordB = buf;
            self2.coordBn = found;

            NSString *line = [NSString stringWithFormat:@"结构扫描匹配：%d 个（位移从大到小）", found];
            self2.statusLabel.text = line;
            [self2 appendProgressLine:line];
            [self2 appendProgressLine:diag];
            [self2 refreshCount];

            NSMutableString *msg = [NSMutableString stringWithFormat:
                @"%@\n\n位移最大的最可能是人物根组件（相机/挂点也会动）。\n下一步：回游戏站住不动、蹲下（趴下也行，别起身），再回来点『③ 蹲下过滤』——蹲下只降竖直轴、水平不动，能筛到个位数。\n\n", diag];
            for (int i = 0; i < found && i < 3; i++) {
                [msg appendFormat:@"%d) 0x%llX  (%.2f, %.2f, %.2f)%@\n", i + 1,
                 (unsigned long long)buf[i].addr,
                 buf[i].v[0], buf[i].v[1], buf[i].v[2],
                 (buf[i].quat_off == 100) ? @"  角度旋转" : ((buf[i].quat_off < 0) ? @"  平凡旋转" : @"  有旋转")];
            }

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已锁定坐标候选"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选（点『链』）" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [ok addAction:[UIAlertAction actionWithTitle:@"③ 跳一下过滤" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 coordProbeJump]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
        });
    });
}

#pragma mark 坐标结构扫描 · ③ 蹲下过滤（单轴位移）

- (void)coordProbeJump {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    if (!self.coordB || self.coordBn <= 0) {
        [self appendProgressLine:@"还没有走动候选，先做 ② 走动后对比"];
        self.statusLabel.text = @"先做 ②";
        return;
    }
    memread_coord_hit_t *base = (memread_coord_hit_t *)self.coordB;
    int nbase = self.coordBn;
    [self.spinner startAnimating];
    self.statusLabel.text = @"蹲下过滤：对比中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int cap = MEMREAD_COORD_HIT_CAP;
        int m = 0, common = 0, moved = 0;
        float maxdelta = 0;
        memread_coord_hit_t *out = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)cap);
        // 只留「某个轴变了 ≥10、另外两个轴几乎没动 ≤5」的：蹲下去竖直降、水平不挪
        int rc = out ? memread_coord_probe_jump(pid, base, nbase, out, cap, &m,
                                                &common, &moved, &maxdelta, NULL, NULL, NULL) : -4;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(out); return; }
            [self2.spinner stopAnimating];

            NSString *diag = [NSString stringWithFormat:
                @"待筛 %d 个 · 同地址 %d 个 · 变了 %d 个 · 单轴位移(保留) %d 个（最大位移 %.1f）",
                nbase, common, moved, m, maxdelta];
            [self2 appendProgressLine:diag];

            if (rc != 0 || m <= 0) {
                free(out);
                NSString *why = (rc != 0)
                    ? [NSString stringWithFormat:@"蹲下过滤失败 rc=%d", rc]
                    : (moved == 0
                       ? @"蹲下前后一个都没变：没有回游戏蹲下，或者游戏在后台被挂起了（回游戏蹲下别起身，再回来）"
                       : @"没有「只动一个轴」的候选：这些地址是乱动的特效/粒子，不是人物位置");
                self2.statusLabel.text = @"蹲下过滤没结果";
                [self2 appendProgressLine:why];
                [self2 appendProgressLine:diag];
                return;
            }

            uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)m);
            for (int i = 0; i < m; i++) addrs[i] = out[i].addr;
            memread_valscan_set(pid, addrs, m, MEMREAD_VALTYPE_FLOAT);
            free(addrs);
            self2.coordCandidates = YES;

            // 这一批当作 ④ 转视角的基准
            memread_coord_hit_t *oldb = (memread_coord_hit_t *)self2.coordB;
            if (oldb) free(oldb);
            self2.coordB = out;
            self2.coordBn = m;

            NSString *line = [NSString stringWithFormat:@"蹲下过滤后：%d 个候选（竖直变、水平不变）", m];
            self2.statusLabel.text = line;
            [self2 appendProgressLine:line];
            [self2 appendProgressLine:diag];
            [self2 refreshCount];

            NSMutableString *msg = [NSMutableString stringWithFormat:@"%@\n\n", diag];
            for (int i = 0; i < m && i < 5; i++) {
                [msg appendFormat:@"%d) 0x%llX  (%.1f, %.1f, %.1f)\n", i + 1,
                 (unsigned long long)out[i].addr,
                 out[i].v[0], out[i].v[1], out[i].v[2]];
            }
            msg = [[msg stringByAppendingString:
                @"\n这些是「蹲下只降竖直轴」的地址，基本就是人物/挂点。\n不放心可以再点④ 转视角：跟着镜头转的那份会被筛掉。"] mutableCopy];

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"候选已缩到个位数"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ok addAction:[UIAlertAction actionWithTitle:@"查看候选（点『链』）" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 onList]; }]];
            [ok addAction:[UIAlertAction actionWithTitle:@"④ 转视角再筛" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self2 coordProbeStill]; }]];
            [self2 presentViewController:ok animated:YES completion:nil];
        });
    });
}

#pragma mark 坐标结构扫描 · ④ 转视角过滤（可选）

- (void)coordProbeStill {
    pid_t pid = [self ensurePid];
    if (pid <= 0) return;
    if (!self.coordB || self.coordBn <= 0) {
        [self appendProgressLine:@"还没有走动候选，先做 ② 走动后对比"];
        self.statusLabel.text = @"先做 ②";
        return;
    }
    memread_coord_hit_t *base = (memread_coord_hit_t *)self.coordB;
    int nbase = self.coordBn;
    [self.spinner startAnimating];
    self.statusLabel.text = @"转视角过滤：对比中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int cap = MEMREAD_COORD_HIT_CAP;
        int m = 0, common = 0, moved = 0;
        float maxdelta = 0;
        memread_coord_hit_t *out = (memread_coord_hit_t *)malloc(sizeof(memread_coord_hit_t) * (size_t)cap);
        // 只保留「转视角前后位移≈0」的：人物位置不变，相机/挂点副本会跟着镜头动
        int rc = out ? memread_coord_probe_diff(pid, base, nbase, out, cap, &m,
                                                &common, &moved, &maxdelta,
                                                0.0f, 1.0f, NULL, NULL, NULL) : -4;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(out); return; }
            [self2.spinner stopAnimating];

            NSString *diag = [NSString stringWithFormat:
                @"待筛 %d 个 · 同地址 %d 个 · 转视角后变了 %d 个 · 没变(保留) %d 个（最大位移 %.1f）",
                nbase, common, moved, m, maxdelta];
            [self2 appendProgressLine:diag];

            if (rc != 0 || m <= 0) {
                free(out);
                NSString *why = (rc != 0)
                    ? [NSString stringWithFormat:@"转视角过滤失败 rc=%d", rc]
                    : (moved == 0
                       ? @"转视角前后一个都没变：说明这一步没回游戏转视角，或者游戏在后台被挂起了（回游戏原地左右转视角 2 秒再回来）"
                       : @"候选全都跟着视角一起动了（这些是相机/挂点副本），没有剩下人物位置");
                self2.statusLabel.text = @"转视角过滤没结果";
                [self2 appendProgressLine:why];
                [self2 appendProgressLine:diag];
                return;
            }

            uint64_t *addrs = (uint64_t *)malloc(sizeof(uint64_t) * (size_t)m);
            for (int i = 0; i < m; i++) addrs[i] = out[i].addr;
            memread_valscan_set(pid, addrs, m, MEMREAD_VALTYPE_FLOAT);
            free(addrs);
            self2.coordCandidates = YES;

            NSString *line = [NSString stringWithFormat:@"转视角过滤后：%d 个没变候选", m];
            self2.statusLabel.text = line;
            [self2 appendProgressLine:line];
            [self2 appendProgressLine:diag];
            [self2 refreshCount];

            NSMutableString *msg = [NSMutableString stringWithFormat:@"%@\n\n", diag];
            for (int i = 0; i < m && i < 3; i++) {
                [msg appendFormat:@"%d) 0x%llX  (%.2f, %.2f, %.2f)%@\n", i + 1,
                 (unsigned long long)out[i].addr,
                 out[i].v[0], out[i].v[1], out[i].v[2],
                 (out[i].quat_off == 100) ? @"  角度旋转" : ((out[i].quat_off < 0) ? @"  平凡旋转" : @"  有旋转")];
            }
            free(out);

            UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"没变的坐标候选"
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
