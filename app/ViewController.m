#import "ViewController.h"
#import "DetailViewController.h"
#import "FilesViewController.h"

// 私有 API：按 bundle id 取 App 图标（UIKit 内部实现，SpringBoard 也用同一条）
static UIImage *MemReadIconForBundle(NSString *bid) {
    if (!bid.length) return nil;
    Class ui = [UIImage class];
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![ui respondsToSelector:s]) return nil;
    NSMethodSignature *sig = [ui methodSignatureForSelector:s];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ui];
    [inv setSelector:s];
    NSString *b = bid;
    int fmt = 2;
    CGFloat sc = 2.0;
    [inv setArgument:&b atIndex:2];
    [inv setArgument:&fmt atIndex:3];
    [inv setArgument:&sc atIndex:4];
    [inv invoke];
    __unsafe_unretained id ret = nil;
    [inv getReturnValue:&ret];
    return (UIImage *)ret;
}

// 缩放到固定边长，保证行高稳定
static UIImage *MemReadResizeIcon(UIImage *img, CGFloat side) {
    if (!img) return nil;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

@interface ViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray *allApps;
@property (nonatomic, strong) NSArray *sections;   // @{@"title":字母, @"apps":@[app...]}
@property (nonatomic, strong) NSMutableDictionary *iconCache;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要读取的 App";
    self.allApps = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];
    self.sections = @[];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    // 不用任何系统键盘输入：本机越狱环境下键盘候选栏会触发 CoreImage 崩溃
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"结果"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onFiles)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"剪贴板"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onClipboard)];

    [self loadApps];
}

- (void)loadApps {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *arr = [NSMutableArray array];
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) {
            SEL sDefault = NSSelectorFromString(@"defaultWorkspace");
            SEL sAll = NSSelectorFromString(@"allInstalledApplications");
            SEL sBid = NSSelectorFromString(@"applicationIdentifier");
            SEL sName = NSSelectorFromString(@"localizedName");
            SEL sBundle = NSSelectorFromString(@"bundleURL");
            SEL sData = NSSelectorFromString(@"dataContainerURL");

            id ws = [cls performSelector:sDefault];
            NSArray *apps = [ws performSelector:sAll];
            for (id proxy in apps) {
                @autoreleasepool {
                    if (![proxy respondsToSelector:sBid] || ![proxy respondsToSelector:sBundle]) continue;
                    NSString *bid = [proxy performSelector:sBid];
                    NSURL *bundleURL = [proxy performSelector:sBundle];
                    if (!bid.length || !bundleURL) continue;
                    NSString *name = [proxy respondsToSelector:sName] ? [proxy performSelector:sName] : bid;
                    NSURL *dataURL = [proxy respondsToSelector:sData] ? [proxy performSelector:sData] : nil;
                    [arr addObject:@{
                        @"bid": bid,
                        @"name": name ?: bid,
                        @"bundlePath": bundleURL.path ?: @"",
                        @"dataPath": dataURL.path ?: @""
                    }];
                }
            }
        }
        [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a[@"name"] lowercaseString] compare:[b[@"name"] lowercaseString]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = arr;
            [self buildSections];
        });
    });
}

// 按首字母分节，配 UITableView 右侧索引条（点字母跳转，不弹键盘）
- (void)buildSections {
    NSMutableDictionary *byLetter = [NSMutableDictionary dictionary];
    for (NSDictionary *d in self.allApps) {
        NSString *name = d[@"name"] ?: @"";
        NSString *key = @"#";
        if (name.length) {
            unichar c = [name characterAtIndex:0];
            if ([[NSCharacterSet letterCharacterSet] characterIsMember:c]) {
                key = [[name substringToIndex:1] uppercaseString];
            }
        }
        NSMutableArray *arr = byLetter[key];
        if (!arr) { arr = [NSMutableArray array]; byLetter[key] = arr; }
        [arr addObject:d];
    }
    NSMutableArray *ordered = [NSMutableArray array];
    NSArray *keys = [[byLetter allKeys] sortedUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"#"]) return NSOrderedDescending;
        if ([b isEqualToString:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    for (NSString *k in keys) {
        [ordered addObject:@{@"title": k, @"apps": byLetter[k]}];
    }
    self.sections = ordered;
    [self.table reloadData];
}

// 结果页：App 内浏览/删除 Media 下的 memread_* 文件
- (void)onFiles {
    FilesViewController *vc = [[FilesViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

// 无键盘手动入口：从剪贴板取 bundle id 或 PID
- (void)onClipboard {
    NSString *raw = [UIPasteboard generalPasteboard].string;
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板是空的"
                                                                  message:@"先在别处复制 App 的 bundle id（含点）或十进制 PID，再点这里"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    BOOL allDigits = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') { allDigits = NO; break; }
    }

    if (allDigits) {
        pid_t pid = (pid_t)[s intValue];
        DetailViewController *dvc = [[DetailViewController alloc] init];
        dvc.info = @{@"bid": @"", @"name": [NSString stringWithFormat:@"直接读 PID %d", pid],
                     @"bundlePath": @"", @"dataPath": @""};
        dvc.initialPid = pid;
        [self.navigationController pushViewController:dvc animated:YES];
        return;
    }

    if ([s rangeOfString:@" "].location != NSNotFound || s.length > 200) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板内容不像 bundle id"
                                                                  message:s
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSDictionary *info = [self infoForBundleID:s];
    DetailViewController *dvc = [[DetailViewController alloc] init];
    dvc.info = info;
    [self.navigationController pushViewController:dvc animated:YES];
}

- (NSDictionary *)infoForBundleID:(NSString *)bid {
    NSDictionary *fallback = @{@"bid": bid, @"name": bid, @"bundlePath": @"", @"dataPath": @""};
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return fallback;
    id ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL sApp = NSSelectorFromString(@"applicationForBundleIdentifier:");
    if (![ws respondsToSelector:sApp]) return fallback;
    id proxy = [ws performSelector:sApp withObject:bid];
    if (!proxy) return fallback;
    NSURL *bundleURL = [proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]
                       ? [proxy performSelector:NSSelectorFromString(@"bundleURL")] : nil;
    NSURL *dataURL = [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]
                     ? [proxy performSelector:NSSelectorFromString(@"dataContainerURL")] : nil;
    NSString *name = [proxy respondsToSelector:NSSelectorFromString(@"localizedName")]
                     ? [proxy performSelector:NSSelectorFromString(@"localizedName")] : bid;
    return @{
        @"bid": bid,
        @"name": name ?: bid,
        @"bundlePath": bundleURL.path ?: @"",
        @"dataPath": dataURL.path ?: @""
    };
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView {
    NSMutableArray *t = [NSMutableArray array];
    for (NSDictionary *d in self.sections) [t addObject:d[@"title"]];
    return t;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return index;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *apps = self.sections[section][@"apps"];
    return (NSInteger)apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *d = self.sections[indexPath.section][@"apps"][indexPath.row];
    c.textLabel.text = d[@"name"];
    c.detailTextLabel.text = d[@"bid"];

    // 每行前置 App 图标（首次取用时缓存）
    NSString *bid = d[@"bid"];
    UIImage *icon = self.iconCache[bid];
    if (!icon) {
        icon = MemReadResizeIcon(MemReadIconForBundle(bid), 36);
        if (icon) self.iconCache[bid] = icon;
    }
    c.imageView.image = icon;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DetailViewController *dvc = [[DetailViewController alloc] init];
    dvc.info = self.sections[indexPath.section][@"apps"][indexPath.row];
    [self.navigationController pushViewController:dvc animated:YES];
}

@end
