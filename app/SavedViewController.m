#import "SavedViewController.h"
#import "SavedAddressStore.h"
#import "memread_core.h"

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
@property (nonatomic, assign) NSUInteger generation;
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
    self.navigationItem.rightBarButtonItems = @[add, refresh];

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAll];
}

- (void)reloadAll {
    [[SavedAddressStore shared] reload];
    self.items = [[SavedAddressStore shared] allItems];
    [self buildSections];
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
    if (pid <= 0 || items.count == 0) return;

    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *res = [NSMutableDictionary dictionaryWithCapacity:items.count];
        for (NSUInteger i = 0; i < items.count; i++) {
            SavedAddress *s = items[i];
            double v = 0;
            int rc = memread_read_scalar(pid, s.addr, s.type, &v);
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
    c.detailTextLabel.text = [NSString stringWithFormat:@"0x%llX  %@\n= %@",
                              s.addr, [SavedAddressStore typeName:s.type], val];
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
    c.accessoryView = b;
    return c;
}

// 「读」按钮：立刻读这条地址的最新值并刷新本行
- (void)readRowTapped:(UIButton *)sender {
    NSUInteger flat = (NSUInteger)sender.tag;
    if (flat >= self.items.count) return;
    SavedAddress *s = self.items[flat];
    pid_t pid = self.pid;
    sender.enabled = NO;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double v = 0;
        int rc = memread_read_scalar(pid, s.addr, s.type, &v);
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

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUInteger flat = [self flatAtIndexPath:ip];
    if (flat == NSNotFound || flat >= self.items.count) return;
    SavedAddress *s = self.items[flat];

    NSString *val = self.values[@(flat)] ?: @"—";
    NSString *msg = [NSString stringWithFormat:@"0x%llX · %@\n分组: %@\n当前值: %@",
                     s.addr, [SavedAddressStore typeName:s.type],
                     s.group.length ? s.group : @"未分组", val];
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
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"0x%llX", s.addr];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [ws confirmDeleteAt:flat]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
        [[SavedAddressStore shared] addAddr:addr type:type label:label group:group note:@""];
        [ws reloadAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
