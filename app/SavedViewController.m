#import "SavedViewController.h"
#import "SavedAddressStore.h"
#import "memread_core.h"
#include <stdlib.h>

static uint64_t SaveParseAddr(NSString *s) {
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"0x"] || [t hasPrefix:@"0X"]) t = [t substringFromIndex:2];
    if (!t.length) return 0;
    return strtoull(t.UTF8String, NULL, 16);
}

@interface SavedViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<SavedAddress *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *values;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *sections; // 每组：扁平的 item 下标
@property (nonatomic, strong) NSArray<NSString *> *sectionNames;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *resolved; // 扁平下标 → 本轮实际地址
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *resolveNotes; // 解析失败原因
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, strong) UIBarButtonItem *selectItem;
@property (nonatomic, strong) UIBarButtonItem *deleteItem;
@property (nonatomic, strong) UIToolbar *editBar;
@end

@implementation SavedViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.title = @"已保存地址";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.values = [NSMutableDictionary dictionary];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 64;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                        target:self
                                                                        action:@selector(onAdd)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(refreshValues)];
    self.selectItem = [[UIBarButtonItem alloc] initWithTitle:@"选择"
                                                       style:UIBarButtonItemStylePlain
                                                      target:self
                                                      action:@selector(toggleEditing)];
    self.navigationItem.rightBarButtonItems = @[add, refresh, self.selectItem];
    self.table.allowsMultipleSelectionDuringEditing = YES;

    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 46)];
    footer.text = @"存于 /var/mobile/Media/memread_saved.json";
    footer.font = [UIFont systemFontOfSize:12];
    footer.textColor = [UIColor secondaryLabelColor];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 2;
    footer.lineBreakMode = NSLineBreakByWordWrapping;
    self.table.tableFooterView = footer;

    [self reloadAll];
}

#pragma mark - 批量删除

- (void)toggleEditing {
    BOOL on = !self.table.isEditing;
    [self.table setEditing:on animated:YES];
    self.selectItem.title = on ? @"完成" : @"选择";
    if (on) {
        if (!self.editBar) {
            UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - 44,
                                                                        self.view.bounds.size.width, 44)];
            bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
            UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:@"全选"
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(selectAllRows)];
            UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                  target:nil action:nil];
            self.deleteItem = [[UIBarButtonItem alloc] initWithTitle:@"删除选中"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(deleteSelected)];
            self.deleteItem.tintColor = [UIColor systemRedColor];
            bar.items = @[all, flex, self.deleteItem];
            self.editBar = bar;
        }
        self.editBar.frame = CGRectMake(0, self.view.bounds.size.height - 44, self.view.bounds.size.width, 44);
        [self.view addSubview:self.editBar];
        self.table.contentInset = UIEdgeInsetsMake(0, 0, 44, 0);
    } else {
        [self.editBar removeFromSuperview];
        self.table.contentInset = UIEdgeInsetsZero;
        for (NSIndexPath *ip in self.table.indexPathsForSelectedRows) {
            [self.table deselectRowAtIndexPath:ip animated:NO];
        }
    }
    [self.table reloadData];
    [self updateDeleteItem];
}

- (void)selectAllRows {
    for (NSInteger s = 0; s < (NSInteger)self.sections.count; s++) {
        NSArray<NSNumber *> *rows = self.sections[(NSUInteger)s];
        for (NSInteger r = 0; r < (NSInteger)rows.count; r++) {
            [self.table selectRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]
                                     animated:NO scrollPosition:UITableViewScrollPositionNone];
        }
    }
    [self updateDeleteItem];
}

- (void)updateDeleteItem {
    NSUInteger n = self.table.indexPathsForSelectedRows.count;
    self.deleteItem.enabled = (n > 0);
    self.deleteItem.title = n ? [NSString stringWithFormat:@"删除 %lu 条", (unsigned long)n] : @"删除选中";
}

- (void)deleteSelected {
    NSArray<NSIndexPath *> *ips = self.table.indexPathsForSelectedRows;
    if (!ips.count) return;
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSIndexPath *ip in ips) {
        NSUInteger flat = [self flatAtIndexPath:ip];
        if (flat != NSNotFound) [set addIndex:flat];
    }
    if (!set.count) return;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"删除 %lu 条？", (unsigned long)set.count]
                         message:@"分组里其它条目不受影响，删掉后不可恢复"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        [[SavedAddressStore shared] removeIndexes:set];
        [ws reloadAll];
        [ws toggleEditing];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.selectItem;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAll];
}

- (void)reloadAll {
    [[SavedAddressStore shared] reload];
    self.items = [[SavedAddressStore shared] allItems];
    [self rebindPidIfNeeded];
    [self buildSections];
    [self resolveAddresses];
    if (!self.items.count) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"还没有保存的地址\n\n在「候选列表」点一行 → 保存为标签\n也可以点右上角 + 手动添加";
        empty.numberOfLines = 0;
        empty.lineBreakMode = NSLineBreakByWordWrapping;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.font = [UIFont systemFontOfSize:15];
        empty.textColor = [UIColor secondaryLabelColor];
        self.table.backgroundView = empty;
    } else {
        self.table.backgroundView = nil;
    }
    [self.table reloadData];
    [self refreshValues];
}

- (void)refreshValues {
    [self.values removeAllObjects];
    [self.table reloadData];

    NSUInteger gen = ++self.generation;
    pid_t pid = self.pid;
    NSArray<SavedAddress *> *items = self.items;
    NSDictionary<NSNumber *, NSNumber *> *resolved = [self.resolved copy];
    if (pid <= 0 || items.count == 0) return;

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *res = [NSMutableDictionary dictionaryWithCapacity:items.count];
        for (NSUInteger i = 0; i < items.count; i++) {
            SavedAddress *s = items[i];
            NSNumber *ra = resolved[@(i)];
            if (!ra) { res[@(i)] = s.hasSig ? @"指纹（未定位）" : @"模块未加载"; continue; }
            double v = 0;
            int rc = memread_read_scalar(pid, ra.unsignedLongLongValue, s.type, &v);
            res[@(i)] = (rc == 0)
                ? [SavedAddressStore formatValue:v type:s.type]
                : [NSString stringWithFormat:@"不可读 rc=%d", rc];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2 || self2.generation != gen) return;
            [self2.values removeAllObjects];
            [self2.values addEntriesFromDictionary:res];
            [self2.table reloadData];
        });
    });
}

- (void)resolveAddresses {
    self.resolved = [NSMutableDictionary dictionaryWithCapacity:self.items.count];
    self.resolveNotes = [NSMutableDictionary dictionary];
    if (self.pid <= 0) {
        for (NSUInteger i = 0; i < self.items.count; i++) self.resolveNotes[@(i)] = @"未绑定进程";
        return;
    }
    for (NSUInteger i = 0; i < self.items.count; i++) {
        SavedAddress *s = self.items[i];
        if (s.hasChain) {
            int64_t offs[MEMREAD_CHAIN_MAX_DEPTH] = {0};
            int d = (int)MIN(s.chainOffsets.count, (NSUInteger)MEMREAD_CHAIN_MAX_DEPTH);
            for (int k = 0; k < d; k++) offs[k] = [s.chainOffsets[(NSUInteger)k] longLongValue];
            uint64_t t = 0;
            int hop = 0;
            uint64_t fv = 0;
            int rc = memread_chain_resolve_ex(self.pid, s.moduleUUID.UTF8String, s.chainStaticOff,
                                              offs, d, &t, &hop, &fv);
            if (rc == 0 && t) {
                self.resolved[@(i)] = @(t);
            } else if (rc == 2) {
                self.resolveNotes[@(i)] = @"模块未加载";
            } else if (rc == -3) {
                self.resolveNotes[@(i)] = [NSString stringWithFormat:@"链断在第 %d 跳（槽值 0x%llX）", hop, fv];
            } else {
                self.resolveNotes[@(i)] = [NSString stringWithFormat:@"解析失败 rc=%d（进程可能已变）", rc];
            }
            continue;
        }
        if (s.hasSig) {
            // 指纹不预先扫（要遍历整块可写内存），点「读」时再定位
            self.resolveNotes[@(i)] = @"指纹（点读定位）";
            continue;
        }
        if (!s.inModule) {
            self.resolved[@(i)] = @(s.addr);
            continue;
        }
        uint64_t base = 0;
        char nm[64] = {0};
        if (memread_module_base(self.pid, s.moduleUUID.UTF8String, &base, nm, sizeof(nm)) == 0 && base) {
            self.resolved[@(i)] = @(base + s.moduleOff);
        } else {
            self.resolveNotes[@(i)] = @"模块未加载";
        }
        // 解析不到就留空：这条会显示「模块未加载」
    }
}

// 游戏重启后 pid 会变：按保存时记下的可执行路径找回新 pid
static pid_t SavedFindPidForPath(NSString *path) {
    if (!path.length) return 0;
    pid_t pids[512];
    int n = memread_list_procs(pids, 512);
    for (int i = 0; i < n; i++) {
        char buf[MEMREAD_PROC_PATH_MAX];
        if (memread_proc_path(pids[i], buf, sizeof(buf)) != 0) continue;
        if (strcmp(buf, path.UTF8String) == 0) return pids[i];
    }
    return 0;
}

- (void)rebindPidIfNeeded {
    for (SavedAddress *s in self.items) {
        if (!s.procPath.length) continue;
        pid_t p = SavedFindPidForPath(s.procPath);
        if (p > 0 && p != self.pid) {
            self.pid = p;
            return;
        }
        return;   // 找到第一条带路径的记录就够了
    }
}

// 链的文字摘要：main + 0x1234 → +0x20 → +0x8
- (NSString *)chainSummary:(SavedAddress *)s {
    NSMutableString *t = [NSMutableString stringWithFormat:@"%@ + 0x%llX",
                          s.chainName.length ? s.chainName : @"mod", s.chainStaticOff];
    for (NSNumber *n in s.chainOffsets) {
        long long o = n.longLongValue;
        [t appendFormat:@" → %@0x%llX", (o < 0 ? @"-" : @"+"), (unsigned long long)llabs(o)];
    }
    return t;
}

#pragma mark - 分组

// 按分组切 section；没有分组的归到「未分组」并排在最后
- (void)buildSections {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (SavedAddress *s in self.items) {
        if (s.group.length && ![names containsObject:s.group]) [names addObject:s.group];
    }
    BOOL hasUngrouped = NO;
    for (SavedAddress *s in self.items) {
        if (!s.group.length) { hasUngrouped = YES; break; }
    }
    if (hasUngrouped) [names addObject:@"未分组"];

    NSMutableArray<NSArray<NSNumber *> *> *secs = [NSMutableArray array];
    for (NSString *g in names) {
        NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.items.count; i++) {
            SavedAddress *s = self.items[i];
            NSString *gi = s.group.length ? s.group : @"未分组";
            if ([gi isEqualToString:g]) [rows addObject:@(i)];
        }
        [secs addObject:rows];
    }
    self.sectionNames = names;
    self.sections = secs;
}

- (NSUInteger)flatAtIndexPath:(NSIndexPath *)ip {
    if (ip.section >= (NSInteger)self.sections.count) return NSNotFound;
    NSArray<NSNumber *> *rows = self.sections[ip.section];
    if (ip.row >= (NSInteger)rows.count) return NSNotFound;
    return [rows[ip.row] unsignedIntegerValue];
}

- (NSIndexPath *)indexPathForFlat:(NSUInteger)flat {
    for (NSUInteger s = 0; s < self.sections.count; s++) {
        NSUInteger r = [self.sections[s] indexOfObject:@(flat)];
        if (r != NSNotFound) return [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s];
    }
    return nil;
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)self.sections.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (!self.sectionNames.count) return nil;
    NSArray<NSNumber *> *rows = self.sections[s];
    NSString *name = self.sectionNames[s];
    return [NSString stringWithFormat:@"%@  ·  %lu 条", name, (unsigned long)rows.count];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s >= (NSInteger)self.sections.count) return 0;
    return (NSInteger)self.sections[s].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"saved"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"saved"];
    NSUInteger flat = [self flatAtIndexPath:ip];
    if (flat == NSNotFound || flat >= self.items.count) return c;
    SavedAddress *s = self.items[flat];
    c.textLabel.text = s.label;
    c.textLabel.font = [UIFont boldSystemFontOfSize:15];

    NSString *val = self.values[@(flat)];
    if (!val) val = (self.pid > 0) ? @"读取中" : @"未绑定进程";

    NSNumber *ra = self.resolved[@(flat)];
    NSString *addrText = ra ? [NSString stringWithFormat:@"0x%llX", ra.unsignedLongLongValue]
                            : (self.resolveNotes[@(flat)] ?: @"未解析");
    NSString *modText;
    if (s.hasChain) {
        modText = [NSString stringWithFormat:@"  链 %@", [self chainSummary:s]];
    } else if (s.hasSig) {
        modText = [NSString stringWithFormat:@"  指纹 %lu字节/窗%d", (unsigned long)s.sigOffs.count, s.sigWin];
    } else if (s.inModule) {
        modText = [NSString stringWithFormat:@"  %@+0x%llX", (s.moduleName.length ? s.moduleName : @"mod"), s.moduleOff];
    } else {
        modText = @"";
    }
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@%@\n= %@",
                              addrText, [SavedAddressStore typeName:s.type], modText, val];
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    c.detailTextLabel.font = [UIFont systemFontOfSize:12];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"读" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.frame = CGRectMake(0, 0, 44, 32);
    b.tag = (NSInteger)flat;
    [b addTarget:self action:@selector(readRowTapped:) forControlEvents:UIControlEventTouchUpInside];
    b.hidden = self.table.isEditing;
    c.accessoryView = b;
    return c;
}

// 「读」按钮：立刻读这条地址的最新值并刷新本行（指纹条目先定位再读）
static volatile int gSigCancelFlag = 0;

- (void)readValueAt:(uint64_t)addr flat:(NSUInteger)flat sender:(UIButton *)sender {
    if (flat >= self.items.count) return;
    SavedAddress *s = self.items[flat];
    pid_t pid = self.pid;
    sender.enabled = NO;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double v = 0;
        int rc = memread_read_scalar(pid, addr, s.type, &v);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            sender.enabled = YES;
            self2.values[@(flat)] = (rc == 0)
                ? [SavedAddressStore formatValue:v type:s.type]
                : [NSString stringWithFormat:@"不可读 rc=%d", rc];
            NSIndexPath *ip = [self2 indexPathForFlat:flat];
            if (ip) [self2.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (void)readRowTapped:(UIButton *)sender {
    NSUInteger flat = (NSUInteger)sender.tag;
    if (flat >= self.items.count) return;
    SavedAddress *s = self.items[flat];
    NSNumber *ra = self.resolved[@(flat)];
    if (!ra && s.hasSig) {
        [self locateSignatureFor:s flat:flat sender:sender];
        return;
    }
    if (!ra) {
        self.values[@(flat)] = (self.resolveNotes[@(flat)] ?: @"未解析");
        NSIndexPath *ip = [self indexPathForFlat:flat];
        if (ip) [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    [self readValueAt:ra.unsignedLongLongValue flat:flat sender:sender];
}

// 扫描指纹定位：命中 1 处直接读；多处让用户挑
- (void)locateSignatureFor:(SavedAddress *)s flat:(NSUInteger)flat sender:(UIButton *)sender {
    if (self.pid <= 0) {
        UIAlertController *e = [UIAlertController alertControllerWithTitle:@"没有进程"
                                                                   message:@"先绑定游戏进程再定位指纹"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:e animated:YES completion:nil];
        return;
    }
    memread_sig_t *sig = (memread_sig_t *)calloc(1, sizeof(memread_sig_t));
    if (!sig) return;
    sig->win = s.sigWin;
    sig->target_off = s.sigTargetOff;
    sig->stable_n = (int)MIN(s.sigOffs.count, (NSUInteger)MEMREAD_SIG_MAX_STABLE);
    for (int i = 0; i < sig->stable_n; i++) {
        sig->offs[i] = (unsigned char)[s.sigOffs[(NSUInteger)i] unsignedIntValue];
        sig->vals[i] = (unsigned char)[s.sigVals[(NSUInteger)i] unsignedIntValue];
    }
    gSigCancelFlag = 0;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"定位指纹"
                                                                  message:@"正在扫可写内存…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *x) { gSigCancelFlag = 1; }]];
    [self presentViewController:busy animated:YES completion:nil];

    pid_t pid = self.pid;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t cand[64] = {0};
        int n = memread_sig_scan(pid, sig, cand, 64, &gSigCancelFlag);
        free(sig);
        NSMutableArray<NSNumber *> *arr = [NSMutableArray array];
        for (int i = 0; i < n && i < 64; i++) [arr addObject:@(cand[i])];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            void (^afterDismiss)(void) = ^{
                if (n < 0) {
                    NSString *m = (n == -5) ? @"已取消" : [NSString stringWithFormat:@"扫描失败 rc=%d", n];
                    UIAlertController *e = [UIAlertController alertControllerWithTitle:@"定位失败"
                                                                               message:m
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                    [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self2 presentViewController:e animated:YES completion:nil];
                } else if (n == 0) {
                    UIAlertController *e = [UIAlertController
                        alertControllerWithTitle:@"没找到指纹"
                                         message:@"这段字节已被改写或对象已销毁。\n回到游戏让这个数值出现（进对局/开镜），再点「读」。"
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self2 presentViewController:e animated:YES completion:nil];
                } else if (n == 1) {
                    self2.resolved[@(flat)] = arr.firstObject;
                    [self2 readValueAt:arr.firstObject.unsignedLongLongValue flat:flat sender:sender];
                } else {
                    [self2 chooseSignatureCandidate:arr flat:flat sender:sender];
                }
            };
            if (self2.presentedViewController) {
                [self2 dismissViewControllerAnimated:YES completion:afterDismiss];
            } else {
                afterDismiss();
            }
        });
    });
}

- (void)chooseSignatureCandidate:(NSArray<NSNumber *> *)arr flat:(NSUInteger)flat sender:(UIButton *)sender {
    NSString *title = [NSString stringWithFormat:@"找到 %lu 处相同指纹", (unsigned long)arr.count];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:@"挑一个，读到合理数值（比如弹匣数对上）就记住它"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    NSUInteger shown = MIN(arr.count, 8);
    for (NSUInteger i = 0; i < shown; i++) {
        uint64_t ad = arr[i].unsignedLongLongValue;
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"0x%llX", ad]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            __strong typeof(ws) self2 = ws;
            if (!self2) return;
            self2.resolved[@(flat)] = @(ad);
            [self2 readValueAt:ad flat:flat sender:sender];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = sender;
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.table.isEditing) { [self updateDeleteItem]; return; }
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUInteger flat = [self flatAtIndexPath:ip];
    if (flat == NSNotFound || flat >= self.items.count) return;
    SavedAddress *s = self.items[flat];

    NSString *val = self.values[@(flat)] ?: @"—";
    NSNumber *ra = self.resolved[@(flat)];
    NSString *addrText = ra ? [NSString stringWithFormat:@"0x%llX", ra.unsignedLongLongValue]
                            : (self.resolveNotes[@(flat)] ?: @"未解析");
    NSString *where;
    if (s.hasChain) {
        where = [NSString stringWithFormat:@"\n链: %@", [self chainSummary:s]];
    } else if (s.inModule) {
        where = [NSString stringWithFormat:@"\n模块: %@ + 0x%llX", (s.moduleName.length ? s.moduleName : @"mod"), s.moduleOff];
    } else {
        where = @"\n类型: 堆地址（仅本次运行）";
    }
    NSString *msg = [NSString stringWithFormat:@"%@ · %@\n分组: %@%@\n当前值: %@",
                     addrText, [SavedAddressStore typeName:s.type],
                     s.group.length ? s.group : @"未分组", where, val];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:s.label
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"改名" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws promptRenameAt:flat]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"移动到分组" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [ws promptGroupAt:flat]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"复制地址" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSNumber *rv = ws.resolved[@(flat)];
        uint64_t copyAddr = rv ? rv.unsignedLongLongValue : s.addr;
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"0x%llX", copyAddr];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [ws confirmDeleteAt:flat]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didDeselectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.table.isEditing) [self updateDeleteItem];
}

#pragma mark - 编辑

- (void)promptRenameAt:(NSUInteger)idx {
    if (idx >= self.items.count) return;
    SavedAddress *s = self.items[idx];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"改名"
                                                               message:@"给这条地址一个能记住的名字"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = s.label;
        tf.placeholder = @"如 当前弹匣 / 玩家HP";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *t = a.textFields.firstObject.text;
        [[SavedAddressStore shared] renameAtIndex:idx label:t];
        [ws reloadAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptGroupAt:(NSUInteger)idx {
    if (idx >= self.items.count) return;
    SavedAddress *s = self.items[idx];
    NSArray<NSString *> *groups = [[SavedAddressStore shared] groupNames];
    NSString *hint = groups.count
        ? [NSString stringWithFormat:@"已有分组：%@\n留空 = 未分组", [groups componentsJoinedByString:@" / "]]
        : @"按枪械建组，如 M4 / AK / 手枪\n留空 = 未分组";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"移动到分组"
                                                               message:hint
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = s.group;
        tf.placeholder = @"分组名";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *g = a.textFields.firstObject.text;
        [[SavedAddressStore shared] setGroupAtIndex:idx group:g];
        [ws reloadAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmDeleteAt:(NSUInteger)idx {
    if (idx >= self.items.count) return;
    SavedAddress *s = self.items[idx];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除"
                                                               message:[NSString stringWithFormat:@"确认删除「%@」？", s.label]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        [[SavedAddressStore shared] removeAtIndex:idx];
        [ws reloadAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 手动添加

- (void)onAdd {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"手动添加"
                                                               message:@"先选这条地址的数值类型"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    for (int t = 0; t < 4; t++) {
        NSString *name = [SavedAddressStore typeName:t];
        [a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [ws promptAddrForType:t]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptAddrForType:(int)type {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"手动添加"
                                                               message:[NSString stringWithFormat:@"类型 %@；地址填十六进制，如 0x0000000123456789",
                                                                        [SavedAddressStore typeName:type]]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"地址 0x...";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"标签名，如 玩家HP";
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
        uint64_t addr = SaveParseAddr(a.textFields[0].text);
        NSString *label = a.textFields[1].text;
        NSString *group = a.textFields[2].text;
        if (addr == 0) {
            UIAlertController *e = [UIAlertController alertControllerWithTitle:@"地址无效"
                                                                       message:@"按十六进制填，例如 0x0000000123456789"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [ws presentViewController:e animated:YES completion:nil];
            return;
        }
        char muuid[40] = {0}, mname[64] = {0};
        uint64_t mbase = 0, moff = 0;
        BOOL inModule = (memread_addr_module_info(ws.pid, addr, muuid, sizeof(muuid),
                                                  mname, sizeof(mname), &mbase, &moff) == 0 && muuid[0]);
        [[SavedAddressStore shared] addAddr:addr type:type label:label group:group note:@""
                                  moduleUUID:(inModule ? [NSString stringWithUTF8String:muuid] : @"")
                                  moduleName:(inModule ? [NSString stringWithUTF8String:mname] : @"")
                                   moduleOff:moff];
        [ws reloadAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
