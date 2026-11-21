#import "FileTextViewController.h"
#import "MemFileSearch.h"
#import "SearchResultsViewController.h"

static const unsigned long long kTextPage = 262144;   // 256 KB / 页

@interface FileTextViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UIView *searchBarWrap;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *prevBtn;
@property (nonatomic, strong) UIButton *nextBtn;
@property (nonatomic, assign) unsigned long long total;
@property (nonatomic, assign) unsigned long long page;
@property (nonatomic, copy) NSString *pendingSnippet;   // 跳转后据此定位
@property (nonatomic, assign) BOOL searching;
@end

@implementation FileTextViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 关键：不让内容延伸到导航栏下面（否则顶部搜索框会被导航栏盖住，点不到）
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.path.lastPathComponent;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:nil];
    self.total = [attrs[NSFileSize] unsignedLongLongValue];
    self.page = 0;

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat searchH = 52;
    CGFloat barH = 44;

    // 顶部常驻搜索框：系统键盘（中文输入法可用）
    self.searchBarWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, searchH)];
    self.searchBarWrap.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.searchBarWrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.searchBarWrap];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 4, w, searchH - 8)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = @"在本文件中搜索（回车开始）";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [self.searchBarWrap addSubview:self.searchBar];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, searchH + 2, w - 28, 34)];
    self.infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.infoLabel.font = [UIFont systemFontOfSize:12];
    self.infoLabel.numberOfLines = 2;
    self.infoLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.infoLabel];

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(
        8, searchH + 38, w - 16, h - searchH - 38 - barH - 8)];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11]
        ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.textView.layer.cornerRadius = 6;
    [self.view addSubview:self.textView];

    self.prevBtn = [self buttonWithTitle:@"‹ 上一页" frame:CGRectMake(8, h - barH, 100, 38)
                                     sel:@selector(onPrev)];
    self.nextBtn = [self buttonWithTitle:@"下一页 ›" frame:CGRectMake(116, h - barH, 100, 38)
                                     sel:@selector(onNext)];
    self.prevBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    self.nextBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:self.prevBtn];
    [self.view addSubview:self.nextBtn];

    [self loadPage];
}

- (UIButton *)buttonWithTitle:(NSString *)t frame:(CGRect)f sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)loadPage {
    unsigned long long pages = (self.total + kTextPage - 1) / kTextPage;
    if (pages == 0) pages = 1;
    if (self.page >= pages) self.page = pages - 1;

    NSString *content = @"";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:self.path];
    if (fh) {
        @try { [fh seekToFileOffset:self.page * kTextPage]; } @catch (id e) { }
        NSData *d = nil;
        @try { d = [fh readDataOfLength:(NSUInteger)kTextPage]; } @catch (id e) { d = nil; }
        [fh closeFile];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
        content = s ?: @"（本页无法按文本解码）";
    } else {
        content = @"无法打开文件";
    }
    self.textView.text = content;
    [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];

    self.infoLabel.text = [NSString stringWithFormat:@"总大小 %@ · 第 %llu/%llu 页 · 起始偏移 0x%llX",
                           [NSByteCountFormatter stringFromByteCount:(long long)self.total
                                                          countStyle:NSByteCountFormatterCountStyleFile],
                           self.page + 1, pages, self.page * kTextPage];

    if (self.pendingSnippet.length) {
        NSString *needle = self.pendingSnippet;
        if (needle.length > 24) needle = [needle substringToIndex:24];
        NSRange r = [self.textView.text rangeOfString:needle options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) {
            [self.textView scrollRangeToVisible:NSMakeRange(r.location, MIN(r.length, (NSUInteger)1))];
        } else {
            [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];
        }
        self.pendingSnippet = nil;
    }
}

- (void)onPrev {
    if (self.page > 0) { self.page--; [self loadPage]; }
}

- (void)onNext {
    unsigned long long pages = (self.total + kTextPage - 1) / kTextPage;
    if (self.page + 1 < pages) { self.page++; [self loadPage]; }
}

- (void)jumpToOffset:(unsigned long long)off snippet:(NSString *)snippet {
    self.page = off / kTextPage;
    self.pendingSnippet = snippet;
    [self loadPage];
}

#pragma mark - 文件内搜索

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *kw = [searchBar.text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!kw.length) return;
    if (self.searching) return;
    self.searching = YES;
    self.infoLabel.text = [NSString stringWithFormat:@"正在全文件搜索“%@”…", kw];

    __weak typeof(self) weakSelf = self;
    [MemFileSearch searchFile:self.path pattern:kw caseFold:YES maxHits:2000
                     progress:^(double f) {
        weakSelf.infoLabel.text = [NSString stringWithFormat:@"正在搜索“%@”… %d%%", kw, (int)(f * 100)];
    } complete:^(NSArray<MemFileSearchHit *> *hits, BOOL truncated, NSError *err) {
        weakSelf.searching = NO;
        if (err) {
            weakSelf.infoLabel.text = [NSString stringWithFormat:@"搜索失败：%@", err.localizedDescription];
            return;
        }
        weakSelf.infoLabel.text = hits.count
            ? [NSString stringWithFormat:@"“%@”命中 %lu 处（点列表可跳转）", kw, (unsigned long)hits.count]
            : [NSString stringWithFormat:@"“%@”未找到匹配", kw];

        SearchResultsViewController *r =
            [[SearchResultsViewController alloc] initWithHits:hits pattern:kw truncated:truncated];
        r.onSelect = ^(MemFileSearchHit *h) {
            [weakSelf jumpToOffset:h.offset snippet:h.snippet];
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:r];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [weakSelf presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

@end
