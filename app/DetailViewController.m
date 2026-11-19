#import "DetailViewController.h"
#import "memread_core.h"

@interface DetailViewController ()
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *bidLabel;
@property (nonatomic, strong) UILabel *pidLabel;
@property (nonatomic, strong) UILabel *bundleLabel;
@property (nonatomic, strong) UILabel *dataLabel;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) pid_t currentPid;
@end

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
    [self addButton:@"把信息写入 Media" width:W y:&y sel:@selector(onSave)];

    self.scroll.contentSize = CGSizeMake(W, y + 40);
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

- (pid_t)findPid {
    NSString *bundlePath = self.info[@"bundlePath"];
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

- (void)onRead {
    pid_t pid = [self findPid];
    if (pid <= 0) { self.resultLabel.text = @"目标未运行，请先启动"; return; }
    self.currentPid = pid;
    self.pidLabel.text = [NSString stringWithFormat:@"PID: %d", pid];
    [self.spinner startAnimating];
    self.resultLabel.text = @"读取中（无注入、无 ptrace）...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = memread_dump(pid, "/var/mobile/Media/memread_dump.bin", 1, NULL, NULL);
        unsigned long long size = 0;
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:@"/var/mobile/Media/memread_dump.bin" error:nil];
        size = [attrs[NSFileSize] unsignedLongLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.resultLabel.text = [NSString stringWithFormat:
                @"完成 rc=%d\n%llu 字节\n/var/mobile/Media/memread_dump.bin", rc, size];
        });
    });
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
