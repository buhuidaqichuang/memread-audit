#import "ValueScanViewController.h"
#import "ValueListViewController.h"
#import "memread_core.h"

@interface ValueScanViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *pidLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UISegmentedControl *typeControl;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) pid_t currentPid;
@end

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

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat y = 16;

    self.infoLabel = [self addLabel:[NSString stringWithFormat:@"目标: %@\n%@",
                                     self.info[@"name"], self.info[@"bid"]] width:W y:&y];
    self.pidLabel = [self addLabel:@"PID: 查找中…" width:W y:&y];

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
    [self addButton:@"重置候选" width:W y:&y sel:@selector(onReset)];

    self.scroll.contentSize = CGSizeMake(W, y + 40);
    [self refreshCount];
    [self findPidNow];
}

- (UILabel *)addLabel:(NSString *)text width:(CGFloat)W y:(CGFloat *)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, *y, W - 40, 0)];
    l.text = text;
    l.font = [UIFont systemFontOfSize:14];
    l.numberOfLines = 0;
    [l sizeToFit];
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

- (void)onTypeChanged {
    // 换类型后旧候选大概率不对应，只提示，不强制清空
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
    pid_t pid = self.currentPid;
    int vt = [self type];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"首扫中（全量比对，之后只重读候选）…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long hits = 0;
        int rc = memread_valscan_first(pid, 1, vt, value, tol, NULL, NULL, &hits, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws.spinner stopAnimating];
            ws.statusLabel.text = [NSString stringWithFormat:@"首扫完成 rc=%d 候选=%llu", rc, hits];
            [ws refreshCount];
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
    addCond(@"等于目标值…", MEMREAD_VALCOND_EQUAL, YES);
    addCond(@"差值等于 N…", MEMREAD_VALCOND_DELTA, YES);
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
    pid_t pid = self.currentPid;
    int vt = [self type];
    if (pid <= 0) return;
    [self.spinner startAnimating];
    self.statusLabel.text = @"收敛中…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long left = 0;
        int rc = memread_valscan_refine(pid, vt, cond, t, NULL, NULL, &left, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws.spinner stopAnimating];
            ws.statusLabel.text = [NSString stringWithFormat:@"收敛完成 rc=%d 剩余=%llu", rc, left];
            [ws refreshCount];
        });
    });
}

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

- (void)onReset {
    memread_valscan_reset();
    self.statusLabel.text = @"已重置候选";
    [self refreshCount];
}

@end
