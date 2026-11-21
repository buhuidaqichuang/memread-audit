#import "ValueListViewController.h"
#import "memread_core.h"

@interface ValueListViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *rows;
@end

@implementation ValueListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.title = @"候选列表";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    unsigned long long n = memread_valscan_count();
    unsigned long long shown = n > 200 ? 200 : n;
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)shown];
    for (unsigned long long i = 0; i < shown; i++) {
        [a addObject:@(i)];
    }
    self.rows = a;
    if (n > shown) {
        self.navigationItem.prompt = [NSString stringWithFormat:@"共 %llu 个候选，只显示前 %llu 个", n, shown];
    }
}

- (NSString *)fmtDouble:(double)v {
    if (self.type == MEMREAD_VALTYPE_INT32 || self.type == MEMREAD_VALTYPE_INT64) {
        return [NSString stringWithFormat:@"%lld", (long long)v];
    }
    if (self.type == MEMREAD_VALTYPE_FLOAT) return [NSString stringWithFormat:@"%.4f", v];
    return [NSString stringWithFormat:@"%.6f", v];
}

- (NSString *)fmtRaw:(uint64_t)raw {
    return [self fmtDouble:memread_valscan_raw2double(raw, self.type)];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"v"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"v"];
    unsigned long long idx = [self.rows[ip.row] unsignedLongLongValue];
    uint64_t addr = 0, prev = 0;
    if (memread_valscan_get(idx, &addr, &prev) == 0) {
        c.textLabel.text = [NSString stringWithFormat:@"0x%016llX", addr];
        c.detailTextLabel.text = [NSString stringWithFormat:@"上一轮值: %@", [self fmtRaw:prev]];
    } else {
        c.textLabel.text = @"—";
        c.detailTextLabel.text = @"—";
    }
    c.textLabel.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    unsigned long long idx = [self.rows[ip.row] unsignedLongLongValue];
    pid_t pid = self.pid;
    int vt = self.type;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t addr = 0;
        double cur = 0;
        int rc = memread_valscan_peek(pid, vt, idx, &addr, &cur);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *msg;
            if (rc == 0) {
                msg = [NSString stringWithFormat:@"地址 0x%016llX\n当前值: %@", addr, [ws fmtDouble:cur]];
            } else {
                msg = [NSString stringWithFormat:@"读取失败 rc=%d（地址可能已失效）", rc];
            }
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"读当前值"
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [ws presentViewController:al animated:YES completion:nil];
        });
    });
}

@end
