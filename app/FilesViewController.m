#import "FilesViewController.h"
#import "DumpViewController.h"
#import "FileTextViewController.h"

static NSString *const kMediaDir = @"/var/mobile/Media";

@interface FilesViewController () <UITableViewDataSource, UITableViewDelegate,
                                   UISearchResultsUpdating, UISearchControllerDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSMutableArray *shown;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation FilesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"读取结果";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.items = [NSMutableArray array];
    self.shown = [NSMutableArray array];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    // 结果页搜索：GPU 已可用，直接用系统搜索框（中文输入法可切）
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.delegate = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索文件名";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    // 左上角必须留给系统返回按钮，否则进了结果页就退不回去
    UIBarButtonItem *refresh =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
    UIBarButtonItem *clear =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearAll)];
    self.navigationItem.rightBarButtonItems = @[refresh, clear];
    self.navigationItem.backButtonTitle = @"返回";
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // push 进来时再挂一次，避免导航栏缓存了上一页的状态导致搜索栏不显示
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self reload];
}

- (void)reload {
    [self.items removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:kMediaDir error:nil];
    for (NSString *n in names) {
        if (![n hasPrefix:@"memread_"]) continue;
        NSString *path = [kMediaDir stringByAppendingPathComponent:n];
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if (!attr) continue;
        [self.items addObject:@{
            @"name": n,
            @"path": path,
            @"size": attr[NSFileSize] ?: @0,
            @"date": attr[NSFileModificationDate] ?: [NSDate date]
        }];
    }
    [self.items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    [self applyFilter];
}

- (void)applyFilter {
    NSString *q = @"";
    if (self.searchController.isActive) {
        q = (self.searchController.searchBar.text ?: @"").lowercaseString;
    }
    [self.shown removeAllObjects];
    for (NSDictionary *d in self.items) {
        NSString *name = d[@"name"] ?: @"";
        if (q.length == 0 || [[name lowercaseString] containsString:q]) {
            [self.shown addObject:d];
        }
    }
    [self.table reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

- (void)willDismissSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

- (NSString *)sizeText:(NSNumber *)size {
    return [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                           countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"f"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    NSDictionary *d = self.shown[indexPath.row];
    c.textLabel.text = d[@"name"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@   %@",
                              [self sizeText:d[@"size"]], [df stringFromDate:d[@"date"]]];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.shown[indexPath.row];
    NSString *path = d[@"path"];
    NSString *name = d[@"name"];

    if ([name.pathExtension.lowercaseString isEqualToString:@"txt"]) {
        // 文本页：分页浏览 + 文件内搜索（大文件也不会一次读进内存）
        FileTextViewController *vc = [[FileTextViewController alloc] init];
        vc.path = path;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        // 二进制 dump：进十六进制浏览页（分页读，不会把 842MB 全读进内存）
        DumpViewController *vc = [[DumpViewController alloc] init];
        vc.path = path;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)deleteRow:(NSIndexPath *)indexPath {
    NSDictionary *d = self.shown[indexPath.row];
    [[NSFileManager defaultManager] removeItemAtPath:d[@"path"] error:nil];
    [self reload];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style == UITableViewCellEditingStyleDelete) {
        [self deleteRow:indexPath];
    }
}

- (void)clearAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清空全部结果"
                                                              message:@"删除 Media 下所有 memread_* 文件"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"全部删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *act) {
        for (NSDictionary *d in self.items) {
            [[NSFileManager defaultManager] removeItemAtPath:d[@"path"] error:nil];
        }
        [self reload];
    }]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

@end
