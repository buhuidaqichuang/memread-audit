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

// 备用：直接从 App 包内读图标文件（私有 API 失败时兜底）
static UIImage *MemReadIconFromBundlePath(NSString *bundlePath) {
    if (!bundlePath.length) return nil;
    NSArray *names = @[@"AppIcon60x60@2x.png", @"AppIcon60x60@3x.png",
                      @"AppIcon76x76@2x~ipad.png", @"AppIcon83.5x83.5@2x~ipad.png",
                      @"Icon-60@2x.png", @"Icon-72@2x.png", @"Icon.png"];
    for (NSString *n in names) {
        NSString *p = [bundlePath stringByAppendingPathComponent:n];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) return img;
    }
    return nil;
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

#pragma mark - 自绘键盘（完全不碰系统键盘，避开 CoreImage/GPU 崩溃路径）

@interface MemKeyboardView : UIView
@property (nonatomic, copy) void (^onKey)(NSString *key);
@end

@implementation MemKeyboardView {
    NSArray<NSArray<NSString *> *> *_rows;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _rows = @[
            @[@"A", @"B", @"C", @"D", @"E", @"F", @"G"],
            @[@"H", @"I", @"J", @"K", @"L", @"M", @"N"],
            @[@"O", @"P", @"Q", @"R", @"S", @"T", @"U"],
            @[@"V", @"W", @"X", @"Y", @"Z", @".", @"␣"],
            @[@"1", @"2", @"3", @"4", @"5", @"6", @"7"],
            @[@"8", @"9", @"0", @"⌫", @"粘贴", @"清空", @"完成"],
        ];
        for (NSArray *row in _rows) {
            for (NSString *title in row) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                [b setTitle:title forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
                b.backgroundColor = [UIColor systemBackgroundColor];
                b.layer.cornerRadius = 6;
                [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
                [self addSubview:b];
            }
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat gap = 4;
    CGFloat cols = 7, rows = (CGFloat)_rows.count;
    CGFloat wCell = (self.bounds.size.width - gap * (cols + 1)) / cols;
    CGFloat hCell = (self.bounds.size.height - gap * (rows + 1)) / rows;
    NSUInteger idx = 0;
    for (UIView *v in self.subviews) {
        if (![v isKindOfClass:[UIButton class]]) continue;
        NSUInteger r = idx / 7, c = idx % 7;
        v.frame = CGRectMake(gap + c * (wCell + gap), gap + r * (hCell + gap), wCell, hCell);
        idx++;
    }
}

- (void)tap:(UIButton *)b {
    if (self.onKey) self.onKey(b.currentTitle);
}

@end

#pragma mark - 列表

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIButton *searchButton;     // GPU 不可用时的自绘搜索入口
@property (nonatomic, strong) MemKeyboardView *keyboard;
@property (nonatomic, assign) BOOL keyboardShown;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) NSMutableArray *allApps;
@property (nonatomic, strong) NSMutableArray *filtered;
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) NSMutableDictionary *iconCache;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要读取的 App";
    self.allApps = [NSMutableArray array];
    self.filtered = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];
    self.sections = @[];
    self.query = @"";

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    // GPU 可用 → 系统搜索框；GPU 不可用 → 自绘搜索 + 自绘键盘（本机就是这种情况）
    extern BOOL MemReadGPUAvailable(void);
    BOOL gpuOK = MemReadGPUAvailable();
    if (gpuOK) {
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder = @"搜索名字或 Bundle ID";
        self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
        self.searchController.searchBar.spellCheckingType = UITextSpellCheckingTypeNo;
        self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.searchController.searchBar.smartQuotesType = UITextSmartQuotesTypeNo;
        self.searchController.searchBar.smartDashesType = UITextSmartDashesTypeNo;
        self.navigationItem.searchController = self.searchController;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
        self.definesPresentationContext = YES;
    } else {
        self.searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.searchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.searchButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        self.searchButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.searchButton.layer.cornerRadius = 10;
        self.searchButton.titleLabel.font = [UIFont systemFontOfSize:15];
        [self.searchButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        [self.searchButton setTitle:@"🔍 搜索名字或 Bundle ID" forState:UIControlStateNormal];
        [self.searchButton addTarget:self action:@selector(onSearchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.searchButton];

        self.keyboard = [[MemKeyboardView alloc] initWithFrame:CGRectZero];
        __weak typeof(self) weakSelf = self;
        self.keyboard.onKey = ^(NSString *key) { [weakSelf onKey:key]; };
        [self.view addSubview:self.keyboard];
    }

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"结果"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onFiles)];

    [self loadApps];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat top = self.view.safeAreaInsets.top;

    if (self.searchButton) {
        self.searchButton.frame = CGRectMake(12, top + 8, W - 24, 38);
        self.table.frame = CGRectMake(0, top + 54, W, H - top - 54);
        CGFloat kbH = 6 * 44 + 8;
        CGRect f = self.keyboard.frame;
        f.size = CGSizeMake(W, kbH);
        f.origin.x = 0;
        f.origin.y = self.keyboardShown ? H - kbH : H;
        self.keyboard.frame = f;
    } else {
        self.table.frame = CGRectMake(0, top, W, H - top);
    }
}

#pragma mark - 自绘搜索

- (void)onSearchTapped {
    self.keyboardShown = YES;
    CGFloat kbH = 6 * 44 + 8;
    [UIView animateWithDuration:0.22 animations:^{
        CGRect f = self.keyboard.frame;
        f.origin.y = self.view.bounds.size.height - kbH;
        self.keyboard.frame = f;
        self.table.contentInset = UIEdgeInsetsMake(0, 0, kbH, 0);
        self.table.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, kbH, 0);
    }];
}

- (void)hideKeyboard {
    self.keyboardShown = NO;
    [UIView animateWithDuration:0.22 animations:^{
        CGRect f = self.keyboard.frame;
        f.origin.y = self.view.bounds.size.height;
        self.keyboard.frame = f;
        self.table.contentInset = UIEdgeInsetsZero;
        self.table.scrollIndicatorInsets = UIEdgeInsetsZero;
    }];
}

- (void)onKey:(NSString *)key {
    if ([key isEqualToString:@"完成"]) { [self hideKeyboard]; return; }
    if ([key isEqualToString:@"⌫"]) {
        if (self.query.length) self.query = [self.query substringToIndex:self.query.length - 1];
    } else if ([key isEqualToString:@"清空"]) {
        self.query = @"";
    } else if ([key isEqualToString:@"粘贴"]) {
        NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.query = s;
    } else if ([key isEqualToString:@"␣"]) {
        self.query = [self.query stringByAppendingString:@" "];
    } else {
        self.query = [self.query stringByAppendingString:key];
    }

    [self.searchButton setTitle:(self.query.length ? [NSString stringWithFormat:@"🔍 %@", self.query]
                                                   : @"🔍 搜索名字或 Bundle ID")
                       forState:UIControlStateNormal];
    [self applyFilter];
}

#pragma mark - 数据

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
    NSArray *keys = [[byLetter allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"#"]) return NSOrderedDescending;
        if ([b isEqualToString:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    for (NSString *k in keys) [ordered addObject:@{@"title": k, @"apps": byLetter[k]}];
    self.sections = ordered;
    [self applyFilter];
}

- (BOOL)isSearching {
    return self.query.length > 0;
}

- (void)applyFilter {
    NSString *q = self.query.lowercaseString ?: @"";
    if (!self.searchButton && self.searchController.isActive) {
        q = (self.searchController.searchBar.text ?: @"").lowercaseString;
    }
    [self.filtered removeAllObjects];
    for (NSDictionary *d in self.allApps) {
        if (q.length == 0 ||
            [[d[@"name"] lowercaseString] containsString:q] ||
            [[d[@"bid"] lowercaseString] containsString:q]) {
            [self.filtered addObject:d];
        }
    }
    [self.table reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

- (void)onFiles {
    FilesViewController *vc = [[FilesViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

// 无键盘手动入口（系统搜索不可用时使用）：从剪贴板取 bundle id 或 PID
- (void)onClipboard {
    NSString *raw = [UIPasteboard generalPasteboard].string;
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return;
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
    }
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
    return @{@"bid": bid, @"name": name ?: bid,
             @"bundlePath": bundleURL.path ?: @"", @"dataPath": dataURL.path ?: @""};
}

#pragma mark - UITableView

- (NSDictionary *)appAt:(NSIndexPath *)indexPath {
    if ([self isSearching]) return self.filtered[indexPath.row];
    return self.sections[indexPath.section][@"apps"][indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if ([self isSearching]) return 1;
    return (NSInteger)self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self isSearching]) return nil;
    return self.sections[section][@"title"];
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView {
    if ([self isSearching]) return nil;
    NSMutableArray *t = [NSMutableArray array];
    for (NSDictionary *d in self.sections) [t addObject:d[@"title"]];
    return t;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return index;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self isSearching]) return (NSInteger)self.filtered.count;
    NSArray *apps = self.sections[section][@"apps"];
    return (NSInteger)apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *d = [self appAt:indexPath];
    c.textLabel.text = d[@"name"];
    c.detailTextLabel.text = d[@"bid"];

    NSString *bid = d[@"bid"];
    UIImage *icon = self.iconCache[bid];
    if (!icon) {
        icon = MemReadResizeIcon(MemReadIconForBundle(bid), 36);
        if (!icon) icon = MemReadResizeIcon(MemReadIconFromBundlePath(d[@"bundlePath"]), 36);
        if (icon) self.iconCache[bid] = icon;
    }
    c.imageView.image = icon;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DetailViewController *dvc = [[DetailViewController alloc] init];
    dvc.info = [self appAt:indexPath];
    [self.navigationController pushViewController:dvc animated:YES];
}

@end
