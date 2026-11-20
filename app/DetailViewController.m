#import "DetailViewController.h"
#import "FilesViewController.h"
#import "memread_core.h"

@interface DetailViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *bidLabel;
@property (nonatomic, strong) UILabel *pidLabel;
@property (nonatomic, strong) UILabel *bundleLabel;
@property (nonatomic, strong) UILabel *dataLabel;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) pid_t currentPid;
- (void)appendLogLine:(unsigned long long)addr
                chunk:(unsigned long long)chunk
                total:(unsigned long long)total
              skipped:(int)skipped;
@end

// 读取过程中的实时回调（在后台线程触发，内部切到主线程刷 UI）
static void DetailRegionCb(unsigned long long addr, unsigned long long chunk,
                           unsigned long long total, int skipped, void *ctx) {
    DetailViewController *vc = (__bridge DetailViewController *)ctx;
    [vc appendLogLine:addr chunk:chunk total:total skipped:skipped];
}

@implementation DetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.info[@"name"];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentPid = 0;

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    CGFloat W = [UIScreen mainScreen].bounds.size.width;
    CGFloat y = 16;

    self.nameLabel   = [self addLabel:[NSString stringWithFormat:@"名称: %@", self.info[@"name"]] width:W y:&y];
    self.bidLabel    = [self addLabel:[NSString stringWithFormat:@"Bundle ID: %@", self.info[@"bid"]] width:W y:&y];
    self.pidLabel    = [self addLabel:@"PID: 未查找" width:W y:&y];
    self.bundleLabel = [self addLabel:[NSString stringWithFormat:@"App 路径:\n%@", self.info[@"bundlePath"]] width:W y:&y];
    self.dataLabel   = [self addLabel:[NSString stringWithFormat:@"数据路径:\n%@", self.info[@"dataPath"]] width:W y:&y];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.frame = CGRectMake(20, y, 40, 40);
    [self.scroll addSubview:self.spinner];
    y += 44;

    self.resultLabel = [self addLabel:@"就绪" width:W y:&y];

    [self addButton:@"查找 PID" width:W y:&y sel:@selector(onFind)];
    [self addButton:@"启动 App" width:W y:&y sel:@selector(onLaunch)];
    [self addButton:@"读取内存 (rw-only, 无注入)" width:W y:&y sel:@selector(onRead)];
    [self addButton:@"扫描敏感数据 (不落盘, 出报告)" width:W y:&y sel:@selector(onScan)];
    [self addButton:@"从剪贴板取 PID 读取" width:W y:&y sel:@selector(onManualPid)];
    [self addButton:@"把信息写入 Media" width:W y:&y sel:@selector(onSave)];
    [self addButton:@"查看结果文件（dump / 报告）" width:W y:&y sel:@selector(onShowFiles)];

    // 实时内存读取面板
    UILabel *logTitle = [self addLabel:@"实时读取（地址 / 块大小 / 累计）" width:W y:&y];
    logTitle.font = [UIFont boldSystemFontOfSize:13];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, y, W - 40, 240)];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    self.logView.layer.masksToBounds = YES;
    self.logView.text = @"等待读取…";
    [self.scroll addSubview:self.logView];
    y += 252;

    self.scroll.contentSize = CGSizeMake(W, y + 40);

    if (self.initialPid > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf readPid:weakSelf.initialPid];
        });
    }
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

// bundlePath 可能为空（手动输入 bundle id 时），此时用 LaunchServices 反查
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
    SEL sBundle = NSSelectorFromString(@"bundleURL");
    if (![proxy respondsToSelector:sBundle]) return nil;
    NSURL *u = [proxy performSelector:sBundle];
    return u.path;
}

- (pid_t)findPid {
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

- (void)onFind {
    pid_t pid = [self findPid];
    self.currentPid = pid;
    if (pid > 0) {
        self.pidLabel.text = [NSString stringWithFormat:@"PID: %d（运行中）", pid];
        self.resultLabel.text = @"已找到运行中的进程";
    } else {
        self.pidLabel.text = @"PID: 未运行";
        self.resultLabel.text = @"目标未运行，可先点「启动 App」";
    }
}

- (void)onLaunch {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) { self.resultLabel.text = @"LSApplicationWorkspace 不可用"; return; }
    id ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL s = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![ws respondsToSelector:s]) { self.resultLabel.text = @"启动 API 不可用"; return; }
    [ws performSelector:s withObject:self.info[@"bid"]];
    self.resultLabel.text = @"已请求启动，稍后自动查找 PID";
    [self performSelector:@selector(onFind) withObject:nil afterDelay:2.5];
}

- (void)appendLogLine:(unsigned long long)addr chunk:(unsigned long long)chunk
                total:(unsigned long long)total skipped:(int)skipped {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isViewLoaded) return;
        NSString *line = [NSString stringWithFormat:@"0x%08llX  +%.1fMB  %@累计 %.1fMB\n",
                          addr, chunk / 1048576.0,
                          skipped ? @"[零页跳过] " : @"",
                          total / 1048576.0];
        NSString *txt = [self.logView.text stringByAppendingString:line];
        if (txt.length > 60000) {
            txt = [@"…\n" stringByAppendingString:[txt substringFromIndex:txt.length - 40000]];
        }
        self.logView.text = txt;
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    });
}

- (void)readPid:(pid_t)pid {
    if (pid <= 0) { self.resultLabel.text = @"PID 无效"; return; }
    self.currentPid = pid;
    self.pidLabel.text = [NSString stringWithFormat:@"PID: %d", pid];
    [self.spinner startAnimating];
    self.logView.text = [NSString stringWithFormat:@"开始读取 pid=%d\n", pid];
    self.resultLabel.text = @"读取中（无注入、无 ptrace）...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = memread_dump_ex(pid, "/var/mobile/Media/memread_dump.bin", 1,
                                 DetailRegionCb, (__bridge void *)self);
        unsigned long long size = 0;
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:@"/var/mobile/Media/memread_dump.bin" error:nil];
        size = [attrs[NSFileSize] unsignedLongLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            NSString *line = [NSString stringWithFormat:@"结束 rc=%d，文件 %.1f MB\n",
                              rc, size / 1048576.0];
            self.logView.text = [self.logView.text stringByAppendingString:line];
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
            self.resultLabel.text = [NSString stringWithFormat:
                @"完成 rc=%d\n%.1f MB\n/var/mobile/Media/memread_dump.bin",
                rc, size / 1048576.0];

            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"读取完成"
                message:[NSString stringWithFormat:@"rc=%d，写入 %.1f MB\ndump 很大，看完可以在「结果」页删掉", rc, size / 1048576.0]
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"去查看" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *act) { [self onShowFiles]; }]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

- (void)onShowFiles {
    FilesViewController *vc = [[FilesViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onRead {
    pid_t pid = [self findPid];
    if (pid <= 0) { self.resultLabel.text = @"目标未运行，请先启动"; return; }
    [self readPid:pid];
}

// 扫描模式：不落盘，只输出分级报告
- (void)onScan {
    pid_t pid = [self findPid];
    if (pid <= 0) { self.resultLabel.text = @"目标未运行，请先启动"; return; }
    [self scanPid:pid];
}

- (void)scanPid:(pid_t)pid {
    if (pid <= 0) { self.resultLabel.text = @"PID 无效"; return; }
    self.currentPid = pid;
    self.pidLabel.text = [NSString stringWithFormat:@"PID: %d", pid];
    [self.spinner startAnimating];
    self.logView.text = [NSString stringWithFormat:@"开始扫描 pid=%d\n", pid];
    self.resultLabel.text = @"扫描中（不写 dump）...";

    NSString *label = self.info[@"bid"] ?: @"(unknown)";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long hits[4] = {0, 0, 0, 0};
        int rc = memread_scan_ex(pid, "/var/mobile/Media/memread_scan.txt",
                                 label.UTF8String, 1, DetailRegionCb,
                                 (__bridge void *)self, hits);
        // block 不能捕获数组，先转成标量
        unsigned long long a = hits[0], b = hits[1], c = hits[2], d = hits[3];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            NSString *summary = [NSString stringWithFormat:
                @"扫描完成 rc=%d   A=%llu B=%llu C=%llu D=%llu",
                rc, a, b, c, d];
            self.logView.text = [self.logView.text stringByAppendingFormat:@"%@\n", summary];
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
            self.resultLabel.text = [NSString stringWithFormat:
                @"%@\n报告: /var/mobile/Media/memread_scan.txt", summary];
        });
    });
}

// 手动 PID：从剪贴板取（不用系统键盘，避开键盘候选栏的 CoreImage 崩溃）
- (void)onManualPid {
    NSString *raw = [UIPasteboard generalPasteboard].string;
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) {
        self.resultLabel.text = @"剪贴板为空：先复制 PID";
        return;
    }
    pid_t pid = (pid_t)[s intValue];
    if (pid <= 0) {
        self.resultLabel.text = @"剪贴板内容不是有效 PID";
        return;
    }
    [self readPid:pid];
}

- (void)onSave {
    NSString *s = [NSString stringWithFormat:
        @"name=%@\nbid=%@\npid=%d\nbundle=%@\ndata=%@\n",
        self.info[@"name"], self.info[@"bid"], self.currentPid,
        self.info[@"bundlePath"], self.info[@"dataPath"]];
    [s writeToFile:@"/var/mobile/Media/memread_appinfo.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.resultLabel.text = @"已写入 /var/mobile/Media/memread_appinfo.txt";
}

@end
