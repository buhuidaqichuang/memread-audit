#import "ViewController.h"
#import "DetailViewController.h"

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

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSMutableArray *allApps;
@property (nonatomic, strong) NSMutableArray *filtered;
@property (nonatomic, strong) NSMutableDictionary *iconCache;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要读取的 App";
    self.allApps = [NSMutableArray array];
    self.filtered = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    // 用系统 UISearchController：位置由导航栏管理，不会被状态栏压住
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索名字或 Bundle ID";
    // 关闭候选栏/自动纠错：切输入法时候选栏的 CoreImage 样式化在本机越狱环境下会崩
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchController.searchBar.spellCheckingType = UITextSpellCheckingTypeNo;
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.smartQuotesType = UITextSmartQuotesTypeNo;
    self.searchController.searchBar.smartDashesType = UITextSmartDashesTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"手动"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onManual)];

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
            [self applyFilter];
        });
    });
}

- (void)applyFilter {
    NSString *q = [self.searchController.searchBar.text lowercaseString];
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

// 兜底：直接粘贴 bundle id，绕开列表枚举
- (void)onManual {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"手动输入 Bundle ID"
                                                              message:@"粘贴目标 App 的 bundle id"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"com.example.xxx";
        t.autocapitalizationType = UITextAutocapitalizationTypeNone;
        t.autocorrectionType = UITextAutocorrectionTypeNo;
        t.spellCheckingType = UITextSpellCheckingTypeNo;
        t.smartQuotesType = UITextSmartQuotesTypeNo;
        t.smartDashesType = UITextSmartDashesTypeNo;
        t.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *bid = a.textFields.firstObject.text;
        bid = [bid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!bid.length) return;
        NSDictionary *info = [weakSelf infoForBundleID:bid];
        DetailViewController *dvc = [[DetailViewController alloc] init];
        dvc.info = info;
        [weakSelf.navigationController pushViewController:dvc animated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filtered.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *d = self.filtered[indexPath.row];
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
    dvc.info = self.filtered[indexPath.row];
    [self.navigationController pushViewController:dvc animated:YES];
}

@end
