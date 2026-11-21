#import "SearchResultsViewController.h"

@interface SearchResultsViewController ()
@property (nonatomic, strong) NSArray *hits;
@property (nonatomic, copy) NSString *pattern;
@property (nonatomic, assign) BOOL truncated;
@end

@implementation SearchResultsViewController

- (instancetype)initWithHits:(NSArray<MemFileSearchHit *> *)hits
                     pattern:(NSString *)pattern
                   truncated:(BOOL)truncated {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _hits = hits ?: @[];
        _pattern = [pattern copy];
        _truncated = truncated;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.hits.count
        ? [NSString stringWithFormat:@"“%@” 命中 %lu 处", self.pattern, (unsigned long)self.hits.count]
        : [NSString stringWithFormat:@"“%@” 未找到", self.pattern];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(onDone)];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.hits.count) return @"没有匹配内容，换个关键词再试";
    if (self.truncated) {
        return [NSString stringWithFormat:@"只保留前 %lu 处（已到上限，换更具体的关键词可缩小范围）",
                (unsigned long)self.hits.count];
    }
    return [NSString stringWithFormat:@"共 %lu 处，点一条即跳到该位置", (unsigned long)self.hits.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.hits.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"hit"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:@"hit"];
    MemFileSearchHit *h = self.hits[indexPath.row];
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    c.textLabel.text = [NSString stringWithFormat:@"%lu. 0x%012llX",
                        (unsigned long)(indexPath.row + 1), h.offset];
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.text = h.snippet;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    MemFileSearchHit *h = self.hits[indexPath.row];
    void (^sel)(MemFileSearchHit *) = self.onSelect;
    [self dismissViewControllerAnimated:YES completion:^{
        if (sel) sel(h);
    }];
}

@end
