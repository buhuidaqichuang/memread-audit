#import "ValueListViewController.h"
#import "SavedAddressStore.h"
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

    // 用可换行表头，避免 navigationItem.prompt 被系统截断成省略号
    if (n > shown) {
        CGFloat w = self.view.bounds.size.width;
        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 0)];
        head.text = [NSString stringWithFormat:@"共 %llu 个候选，列表只显示前 %llu 个", n, shown];
        head.numberOfLines = 0;
        head.lineBreakMode = NSLineBreakByWordWrapping;
        head.font = [UIFont systemFontOfSize:12];
        head.textColor = [UIColor secondaryLabelColor];
        head.textAlignment = NSTextAlignmentCenter;
        CGSize fit = [head sizeThatFits:CGSizeMake(w - 24, CGFLOAT_MAX)];
        head.frame = CGRectMake(12, 8, w - 24, ceil(fit.height));

        UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, head.frame.size.height + 16)];
        [h addSubview:head];
        self.table.tableHeaderView = h;
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
        c.textLabel.text = [NSString stringWithFormat:@"0x%llX", addr];
        c.textLabel.font = [UIFont fontWithName:@"Menlo" size:13]
            ?: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        c.detailTextLabel.text = [NSString stringWithFormat:@"上一轮值: %@", [self fmtRaw:prev]];
        c.detailTextLabel.font = [UIFont systemFontOfSize:12];
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        c.textLabel.text = @"—";
        c.detailTextLabel.text = @"—";
    }
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
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            NSString *msg;
            if (rc == 0) {
                msg = [NSString stringWithFormat:@"地址 0x%llX\n当前值: %@", addr, [self2 fmtDouble:cur]];
            } else {
                msg = [NSString stringWithFormat:@"读取失败 rc=%d（地址可能已失效）", rc];
            }
            UIAlertController *al = [UIAlertController alertControllerWithTitle:@"读当前值"
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            if (rc == 0) {
                [al addAction:[UIAlertAction actionWithTitle:@"保存为标签" style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *x) {
                    [self2 promptSaveAddr:addr type:vt];
                }]];
            }
            [self2 presentViewController:al animated:YES completion:nil];
        });
    });
}

- (void)promptSaveAddr:(uint64_t)addr type:(int)vt {
    NSString *typeName = [SavedAddressStore typeName:vt];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存为标签"
                                                               message:[NSString stringWithFormat:@"0x%llX · %@", addr, typeName]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"标签名，如 当前弹匣 / 玩家HP";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *label = a.textFields.firstObject.text;
        [[SavedAddressStore shared] addAddr:addr type:vt label:label note:@""];
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已保存"
                                                                   message:[NSString stringWithFormat:@"%@ → %@", label.length ? label : @"未命名", [SavedAddressStore typeName:vt]]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [ws presentViewController:ok animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
