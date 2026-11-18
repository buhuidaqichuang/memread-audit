#import "ViewController.h"
#import "DetailViewController.h"

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) NSMutableArray *allApps;
@property (nonatomic, strong) NSMutableArray *filtered;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择要读取的 App";
    self.allApps = [NSMutableArray array];
    self.filtered = [NSMutableArray array];

    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    self.search.delegate = self;
    self.search.placeholder = @"搜索名字或 Bundle ID";
    [self.view addSubview:self.search];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.table];

    [self loadApps];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.search.frame = CGRectMake(0, 0, self.view.bounds.size.width, 50);
    self.table.frame = CGRectMake(0, 50, self.view.bounds.size.width, self.view.bounds.size.height - 50);
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
    NSString *q = [self.search.text lowercaseString];
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

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
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
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DetailViewController *dvc = [[DetailViewController alloc] init];
    dvc.info = self.filtered[indexPath.row];
    [self.navigationController pushViewController:dvc animated:YES];
}

@end
