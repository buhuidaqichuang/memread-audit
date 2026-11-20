#import "FilesViewController.h"

static NSString *const kMediaDir = @"/var/mobile/Media";

@interface FilesViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray *items;
@end

@implementation FilesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"读取结果";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.items = [NSMutableArray array];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearAll)];
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
    [self.table reloadData];
}

- (NSString *)sizeText:(NSNumber *)size {
    return [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                           countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"f"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    NSDictionary *d = self.items[indexPath.row];
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
    NSDictionary *d = self.items[indexPath.row];
    NSString *path = d[@"path"];
    NSString *name = d[@"name"];

    if ([name.pathExtension.lowercaseString isEqualToString:@"txt"]) {
        NSError *err = nil;
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (!content) {
            content = [NSString stringWithFormat:@"读取失败: %@", err.localizedDescription];
        }
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = name;
        vc.view.backgroundColor = [UIColor systemBackgroundColor];
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.selectable = YES;
        tv.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        tv.text = content;
        [vc.view addSubview:tv];
        self.navigationItem.backButtonTitle = @"返回";
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:name
            message:[NSString stringWithFormat:@"二进制文件，%@。\n路径: %@", [self sizeText:d[@"size"]], path]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *act) { [self deleteRow:indexPath]; }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)deleteRow:(NSIndexPath *)indexPath {
    NSDictionary *d = self.items[indexPath.row];
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
    a.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

@end
