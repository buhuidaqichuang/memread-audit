#import "ValueListViewController.h"
#import "SavedAddressStore.h"
#import "SavedViewController.h"
#import "memread_core.h"
#include <stdlib.h>

@interface ValueListViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *rows;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *latest;
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

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"存全部"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onSaveAll)];

    [self reloadCandidates];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onPiPSync:)
                                                 name:@"MemReadPiPSync"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onPiPSync:(NSNotification *)n {
    [self reloadCandidates];
}

// 候选可能被悬浮窗收敛改动：重建索引表并刷新表头
- (void)reloadCandidates {
    unsigned long long n = memread_valscan_count();
    unsigned long long shown = n > 200 ? 200 : n;
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)shown];
    for (unsigned long long i = 0; i < shown; i++) {
        [a addObject:@(i)];
    }
    self.rows = a;
    if (!self.latest) self.latest = [NSMutableDictionary dictionary];
    [self.latest removeAllObjects];
    [self.table reloadData];

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
    } else {
        self.table.tableHeaderView = nil;
    }
}

- (NSString *)fmtDouble:(double)v type:(int)t {
    if (t == MEMREAD_VALTYPE_INT32 || t == MEMREAD_VALTYPE_INT64) {
        return [NSString stringWithFormat:@"%lld", (long long)v];
    }
    if (t == MEMREAD_VALTYPE_FLOAT) return [NSString stringWithFormat:@"%.4f", v];
    return [NSString stringWithFormat:@"%.6f", v];
}

- (NSString *)fmtRaw:(uint64_t)raw type:(int)t {
    return [self fmtDouble:memread_valscan_raw2double(raw, t) type:t];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"v"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"v"];
    unsigned long long idx = [self.rows[ip.row] unsignedLongLongValue];
    uint64_t addr = 0, prev = 0;
    int vt = self.type;
    if (memread_valscan_get_ex(idx, &addr, &prev, &vt) == 0) {
        c.textLabel.text = [NSString stringWithFormat:@"0x%llX  %@", addr, [SavedAddressStore typeName:vt]];
        c.textLabel.font = [UIFont fontWithName:@"Menlo" size:13]
            ?: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        NSString *now = self.latest[@(idx)];
        if (now.length) {
            c.detailTextLabel.text = [NSString stringWithFormat:@"最新: %@   上一轮: %@", now, [self fmtRaw:prev type:vt]];
        } else {
            c.detailTextLabel.text = [NSString stringWithFormat:@"上一轮值: %@", [self fmtRaw:prev type:vt]];
        }
        c.detailTextLabel.font = [UIFont systemFontOfSize:12];
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        UIView *acc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 92, 32)];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:@"读" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        b.frame = CGRectMake(0, 0, 44, 32);
        b.tag = (NSInteger)idx;
        [b addTarget:self action:@selector(readRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [acc addSubview:b];

        UIButton *cb = [UIButton buttonWithType:UIButtonTypeSystem];
        [cb setTitle:@"链" forState:UIControlStateNormal];
        cb.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cb.frame = CGRectMake(48, 0, 44, 32);
        cb.tag = (NSInteger)idx;
        [cb addTarget:self action:@selector(chainRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [acc addSubview:cb];

        c.accessoryView = acc;
    } else {
        c.textLabel.text = @"—";
        c.detailTextLabel.text = @"—";
        c.accessoryView = nil;
    }
    return c;
}

// 「读」按钮：立刻读这条地址的最新值，直接更新到该行
- (void)readRowTapped:(UIButton *)sender {
    unsigned long long idx = (unsigned long long)sender.tag;
    if (idx >= memread_valscan_count()) return;
    pid_t pid = self.pid;
    int vt = self.type;
    uint64_t a0 = 0, p0 = 0;
    if (memread_valscan_get_ex(idx, &a0, &p0, &vt) != 0) return;

    sender.enabled = NO;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t addr = 0;
        double cur = 0;
        int rc = memread_valscan_peek(pid, vt, idx, &addr, &cur);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            sender.enabled = YES;
            if (rc == 0) {
                self2.latest[@(idx)] = [NSString stringWithFormat:@"%@ (%@)",
                                        [self2 fmtDouble:cur type:vt], [SavedAddressStore typeName:vt]];
                // 找到该候选当前所在的行再刷新
                NSUInteger row = [self2.rows indexOfObject:@(idx)];
                if (row != NSNotFound) {
                    [self2.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]]
                                        withRowAnimation:UITableViewRowAnimationNone];
                }
            } else {
                self2.latest[@(idx)] = [NSString stringWithFormat:@"读取失败 rc=%d", rc];
                NSUInteger row = [self2.rows indexOfObject:@(idx)];
                if (row != NSNotFound) {
                    [self2.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]]
                                        withRowAnimation:UITableViewRowAnimationNone];
                }
            }
        });
    });
}

#pragma mark - 指针链（跨重启复原堆地址）

- (NSString *)chainText:(NSString *)name staticOff:(uint64_t)off
                    offs:(NSArray<NSNumber *> *)offs number:(int)num {
    NSMutableString *s = [NSMutableString stringWithFormat:@"#%d  %@ + 0x%llX",
                          num, name.length ? name : @"mod", off];
    for (NSNumber *n in offs) {
        long long o = n.longLongValue;
        [s appendFormat:@"  →  %@0x%llX", (o < 0 ? @"-" : @"+"), (unsigned long long)llabs(o)];
    }
    [s appendString:@"  →  数值"];
    return s;
}

- (void)chainRowTapped:(UIButton *)sender {
    unsigned long long idx = (unsigned long long)sender.tag;
    if (idx >= memread_valscan_count()) return;
    uint64_t a = 0, prev = 0;
    int vt = self.type;
    if (memread_valscan_get_ex(idx, &a, &prev, &vt) != 0) return;
    pid_t pid = self.pid;
    int *cancelFlag = (int *)calloc(1, sizeof(int));

    UIAlertController *ask = [UIAlertController
        alertControllerWithTitle:@"指针链扫描"
                         message:[NSString stringWithFormat:
                                  @"目标 0x%llX（%@）\n先反推 3 层，找不到自动试 4 层；每层都要扫一遍可写内存，可能要几十秒。",
                                  a, [SavedAddressStore typeName:vt]]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *x) { if (cancelFlag) free(cancelFlag); }]];
    __weak typeof(self) ws = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *x) {
        [ws runChainScan:pid target:a type:vt cancel:cancelFlag];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

- (void)runChainScan:(pid_t)pid target:(uint64_t)addr type:(int)vt cancel:(int *)cancelFlag {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"扫描中"
                                                                  message:@"扫可写内存，点「取消」可中止"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction *x) { if (cancelFlag) *cancelFlag = 1; }]];
    [self presentViewController:busy animated:YES completion:nil];

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const int CAP = 24;
        memread_chain_t *chains = (memread_chain_t *)calloc((size_t)CAP, sizeof(memread_chain_t));
        int depth = 0, n = -4;
        if (chains) n = memread_chain_scan(pid, addr, MEMREAD_CHAIN_MAX_DEPTH, chains, CAP, &depth, cancelFlag);

        NSMutableArray<NSDictionary *> *copies = [NSMutableArray array];
        for (int i = 0; i < n && i < CAP; i++) {
            NSMutableArray<NSNumber *> *offs = [NSMutableArray array];
            for (int k = 0; k < chains[i].depth; k++) [offs addObject:@(chains[i].offs[k])];
            [copies addObject:@{
                @"uuid": [NSString stringWithUTF8String:chains[i].uuid],
                @"name": [NSString stringWithUTF8String:chains[i].name],
                @"off": @(chains[i].static_off),
                @"offs": offs
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) { free(chains); if (cancelFlag) free(cancelFlag); return; }
            [self2 dismissViewControllerAnimated:YES completion:^{
                [self2 showChainResult:copies count:n depth:depth target:addr type:vt];
                free(chains);
                if (cancelFlag) free(cancelFlag);
            }];
        });
    });
}

- (void)showChainResult:(NSArray<NSDictionary *> *)chains count:(int)n depth:(int)depth
                 target:(uint64_t)t type:(int)vt {
    if (n <= 0 || chains.count == 0) {
        NSString *m = (n == 0)
            ? @"3 层、4 层都没找到静态指针链。常见原因：中间指针只存在临时对象里、或走对象池 + 索引，不是固定字段链。"
            : [NSString stringWithFormat:@"扫描失败 rc=%d", n];
        UIAlertController *e = [UIAlertController alertControllerWithTitle:@"没有链"
                                                                  message:m
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:e animated:YES completion:nil];
        return;
    }

    NSMutableString *msg = [NSMutableString stringWithFormat:@"命中 %d 条（最短 %d 层）：\n",
                            (int)chains.count, depth];
    for (int i = 0; i < chains.count && i < 3; i++) {
        NSDictionary *c = chains[i];
        [msg appendFormat:@"%@\n", [self chainText:c[@"name"] staticOff:[c[@"off"] unsignedLongLongValue]
                                             offs:c[@"offs"] number:i + 1]];
    }
    if (chains.count > 3) [msg appendFormat:@"…另 %d 条（保存时可选前 8 条）", (int)chains.count - 3];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"找到可跨重启的链"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (int i = 0; i < chains.count && i < 8; i++) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"保存第 %d 条", i + 1]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            NSDictionary *c = chains[i];
            [ws promptSaveChain:c type:vt];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptSaveChain:(NSDictionary *)c type:(int)vt {
    NSString *text = [self chainText:c[@"name"] staticOff:[c[@"off"] unsignedLongLongValue]
                                offs:c[@"offs"] number:1];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"保存指针链"
                         message:[NSString stringWithFormat:@"%@\n\n重启游戏后按模块基址重算，链断会显示「链断了」", text]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"标签名，如 M4 弹匣 / 人物坐标";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    NSArray<NSString *> *groups = [[SavedAddressStore shared] groupNames];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = groups.count
            ? [NSString stringWithFormat:@"分组（已有：%@）", [groups componentsJoinedByString:@"/"]]
            : @"分组，如 M4 / AK（可留空）";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *label = a.textFields[0].text;
        NSString *group = a.textFields[1].text;
        BOOL ok = [[SavedAddressStore shared] addChain:c[@"uuid"]
                                                   name:c[@"name"]
                                              staticOff:[c[@"off"] unsignedLongLongValue]
                                                   offs:c[@"offs"]
                                                   type:vt
                                                  label:label
                                                  group:group
                                                   note:@""];
        UIAlertController *r = [UIAlertController alertControllerWithTitle:(ok ? @"已保存" : @"保存失败")
                                                                   message:(ok ? text : @"链字段缺失")
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    unsigned long long idx = [self.rows[ip.row] unsignedLongLongValue];
    pid_t pid = self.pid;
    int vt = self.type;
    if (vt == MEMREAD_VALTYPE_AUTO) {
        uint64_t a0 = 0, p0 = 0;
        memread_valscan_get_ex(idx, &a0, &p0, &vt);
    }
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
                msg = [NSString stringWithFormat:@"地址 0x%llX\n类型: %@\n当前值: %@",
                       addr, [SavedAddressStore typeName:vt], [self2 fmtDouble:cur type:vt]];
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
    char muuid[40] = {0}, mname[64] = {0};
    uint64_t mbase = 0, moff = 0;
    int mrc = memread_addr_module_info(self.pid, addr, muuid, sizeof(muuid), mname, sizeof(mname), &mbase, &moff);
    BOOL inModule = (mrc == 0 && muuid[0]);
    NSString *uuidStr = inModule ? [NSString stringWithUTF8String:muuid] : @"";
    NSString *nameStr = inModule ? [NSString stringWithUTF8String:mname] : @"";

    NSString *where = inModule
        ? [NSString stringWithFormat:@"模块 %s + 0x%llX（重启后能复原）", mname, moff]
        : @"堆地址（仅本次运行有效，重启后失效）";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存为标签"
                                                               message:[NSString stringWithFormat:@"0x%llX · %@\n%@\n分组填枪械名，同一地址在不同枪下可各存一条", addr, typeName, where]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"标签名，如 当前弹匣 / 玩家HP";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    NSArray<NSString *> *groups = [[SavedAddressStore shared] groupNames];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = groups.count
            ? [NSString stringWithFormat:@"分组（已有：%@）", [groups componentsJoinedByString:@"/"]]
            : @"分组，如 M4 / AK（可留空）";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *label = a.textFields[0].text;
        NSString *group = a.textFields[1].text;
        [[SavedAddressStore shared] addAddr:addr type:vt label:label group:group note:@""
                                  moduleUUID:uuidStr
                                  moduleName:nameStr
                                   moduleOff:moff];
        UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已保存"
                                                                   message:[NSString stringWithFormat:@"%@%@ → %@\n%@",
                                                                            group.length ? [NSString stringWithFormat:@"[%@] ", group] : @"",
                                                                            label.length ? label : @"未命名",
                                                                            [SavedAddressStore typeName:vt], where]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [ws presentViewController:ok animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 批量保存到分组

- (void)onSaveAll {
    unsigned long long n = memread_valscan_count();
    if (n == 0) {
        UIAlertController *e = [UIAlertController alertControllerWithTitle:@"没有候选"
                                                                   message:@"先做一次首扫或收敛"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:e animated:YES completion:nil];
        return;
    }
    NSUInteger cap = (n > 200) ? 200 : (NSUInteger)n;
    NSArray<NSString *> *groups = [[SavedAddressStore shared] groupNames];
    __weak typeof(self) ws = self;

    if (!groups.count) {
        [self promptSaveAllToGroup:[[NSUserDefaults standardUserDefaults] stringForKey:@"MemReadLastGroup"]
                               save:cap total:n];
        return;
    }

    NSString *title = [NSString stringWithFormat:@"保存 %lu 条候选到分组（共 %llu 条）",
                       (unsigned long)cap, n];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:@"点分组即保存；同地址同类型同分组自动跳过"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *g in groups) {
        [a addAction:[UIAlertAction actionWithTitle:g style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            [ws saveAllToGroup:g prefix:@"候选" save:cap total:n];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"新建分组…" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [ws promptSaveAllToGroup:[[NSUserDefaults standardUserDefaults] stringForKey:@"MemReadLastGroup"]
                              save:cap total:n];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptSaveAllToGroup:(NSString *)prefill save:(NSUInteger)cap total:(unsigned long long)n {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存全部候选"
                                                               message:[NSString stringWithFormat:
                                        @"将保存前 %lu 条（共 %llu 条），标签自动编号\n分组填枪械名，如 M4 / AK；留空 = 未分组",
                                        (unsigned long)cap, n]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        if (prefill.length) tf.text = prefill;
        tf.placeholder = @"分组名";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = @"候选";
        tf.placeholder = @"标签前缀";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *g = a.textFields[0].text;
        NSString *p = a.textFields[1].text;
        [ws saveAllToGroup:g prefix:(p.length ? p : @"候选") save:cap total:n];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)saveAllToGroup:(NSString *)group prefix:(NSString *)prefix
                   save:(NSUInteger)cap total:(unsigned long long)n {
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithCapacity:cap];
    NSUInteger modCount = 0;
    for (NSUInteger i = 0; i < cap; i++) {
        uint64_t addr = 0, prev = 0;
        int vt = self.type;
        if (memread_valscan_get_ex((unsigned long long)i, &addr, &prev, &vt) != 0) continue;
        NSMutableDictionary *it = [@{
            @"addr": @(addr),
            @"type": @(vt),
            @"label": [NSString stringWithFormat:@"%@%lu", prefix, (unsigned long)(i + 1)]
        } mutableCopy];
        char muuid[40] = {0}, mname[64] = {0};
        uint64_t mbase = 0, moff = 0;
        if (memread_addr_module_info(self.pid, addr, muuid, sizeof(muuid), mname, sizeof(mname), &mbase, &moff) == 0
            && muuid[0]) {
            it[@"uuid"] = [NSString stringWithUTF8String:muuid];
            it[@"name"] = [NSString stringWithUTF8String:mname];
            it[@"off"] = @(moff);
            modCount++;
        }
        [items addObject:it];
    }
    NSUInteger added = [[SavedAddressStore shared] addBatchWithGroup:gp items:items];
    if (gp.length) [[NSUserDefaults standardUserDefaults] setObject:gp forKey:@"MemReadLastGroup"];

    NSString *gname = gp.length ? gp : @"未分组";
    NSString *msg = [NSString stringWithFormat:@"新增 %lu 条 → 分组「%@」%@",
                     (unsigned long)added, gname,
                     (items.count > added)
                        ? [NSString stringWithFormat:@"\n跳过重复 %lu 条", (unsigned long)(items.count - added)]
                        : @""];
    if (modCount) {
        msg = [msg stringByAppendingFormat:@"\n其中 %lu 条在模块内，可跨重启复原；其余为堆地址，仅本次运行有效", (unsigned long)modCount];
    }
    UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"已保存"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [ok addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [ok addAction:[UIAlertAction actionWithTitle:@"查看" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        SavedViewController *vc = [[SavedViewController alloc] init];
        vc.pid = ws.pid;
        [ws.navigationController pushViewController:vc animated:YES];
    }]];
    [self presentViewController:ok animated:YES completion:nil];
}

@end
