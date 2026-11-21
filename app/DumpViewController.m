#import "DumpViewController.h"
#include <stdlib.h>

static const unsigned long long kPageSize = 16384;   // 16 KB / 页，避免一次读入整份 dump

// 把一段字节渲染成 hex + ASCII 文本（16 字节一行）
static NSString *MemReadHexPage(NSString *path, unsigned long long offset, unsigned long long want) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return @"无法打开文件";

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long total = [attrs[NSFileSize] unsignedLongLongValue];
    if (offset >= total) {
        [fh closeFile];
        return [NSString stringWithFormat:@"偏移 0x%llX 已超出文件末尾（共 %llu 字节）", offset, total];
    }
    @try { [fh seekToFileOffset:offset]; } @catch (id e) {
        [fh closeFile];
        return @"偏移超出文件";
    }
    NSData *data = [fh readDataOfLength:(NSUInteger)MIN(want, total - offset)];
    [fh closeFile];

    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 5];
    const uint8_t *p = data.bytes;
    for (NSUInteger i = 0; i < data.length; i += 16) {
        [s appendFormat:@"%010llX  ", offset + i];
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < data.length) [s appendFormat:@"%02X ", p[i + j]];
            else [s appendString:@"   "];
            if (j == 7) [s appendString:@" "];
        }
        [s appendString:@" |"];
        for (NSUInteger j = 0; j < 16 && i + j < data.length; j++) {
            uint8_t c = p[i + j];
            [s appendFormat:@"%c", (c >= 0x20 && c < 0x7F) ? c : '.'];
        }
        [s appendString:@"|\n"];
    }
    if (!data.length) [s appendString:@"（本页为空）\n"];
    return s;
}

@interface DumpViewController ()
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, assign) unsigned long long offset;
@property (nonatomic, assign) unsigned long long total;
@end

@implementation DumpViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.path.lastPathComponent;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 显式返回，避免长标题把系统返回按钮挤掉
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"返回"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(onBack)];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 32, 40)];
    self.infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.infoLabel.font = [UIFont systemFontOfSize:12];
    self.infoLabel.numberOfLines = 2;
    self.infoLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.infoLabel];

    CGFloat toolbarH = 96;
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(
        8, 52, self.view.bounds.size.width - 16, self.view.bounds.size.height - 52 - toolbarH)];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    self.textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.textView.layer.cornerRadius = 6;
    [self.view addSubview:self.textView];

    CGFloat w = self.view.bounds.size.width;
    UIButton *prev = [self buttonWithTitle:@"‹ 上一页" frame:CGRectMake(8, self.view.bounds.size.height - toolbarH, 96, 40) sel:@selector(onPrev)];
    UIButton *next = [self buttonWithTitle:@"下一页 ›" frame:CGRectMake(108, self.view.bounds.size.height - toolbarH, 96, 40) sel:@selector(onNext)];
    UIButton *jump = [self buttonWithTitle:@"跳到偏移（剪贴板）" frame:CGRectMake(212, self.view.bounds.size.height - toolbarH, w - 220, 40) sel:@selector(onJump)];
    prev.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    next.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    jump.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:prev];
    [self.view addSubview:next];
    [self.view addSubview:jump];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:nil];
    self.total = [attrs[NSFileSize] unsignedLongLongValue];
    self.offset = 0;
    [self render];
}

- (UIButton *)buttonWithTitle:(NSString *)t frame:(CGRect)f sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)render {
    unsigned long long pages = (self.total + kPageSize - 1) / kPageSize;
    unsigned long long page = self.offset / kPageSize + 1;
    self.infoLabel.text = [NSString stringWithFormat:@"总大小 %@（%llu 字节）· 第 %llu/%llu 页 · 偏移 0x%llX",
                           [NSByteCountFormatter stringFromByteCount:(long long)self.total
                                                          countStyle:NSByteCountFormatterCountStyleFile],
                           self.total, page, MAX(pages, (unsigned long long)1), self.offset];
    self.textView.text = MemReadHexPage(self.path, self.offset, kPageSize);
    [self.textView setContentOffset:CGPointMake(0, 0) animated:NO];
}

- (void)onPrev {
    if (self.offset >= kPageSize) {
        self.offset -= kPageSize;
    } else {
        self.offset = 0;
    }
    [self render];
}

- (void)onNext {
    self.offset += kPageSize;
    if (self.offset >= self.total) {
        self.offset = self.total > 0 ? ((self.total - 1) / kPageSize) * kPageSize : 0;
    }
    [self render];
}

// 偏移从剪贴板取：支持 0x 十六进制或十进制
- (void)onJump {
    NSString *s = [[UIPasteboard generalPasteboard].string
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) {
        [self toast:@"剪贴板为空：先复制偏移值（可 0x1234 或十进制）"];
        return;
    }
    unsigned long long v = 0;
    if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
        v = strtoull(s.UTF8String, NULL, 16);
    } else {
        v = strtoull(s.UTF8String, NULL, 10);
    }
    if (v == 0 && ![s isEqualToString:@"0"]) {
        [self toast:@"剪贴板内容不是有效偏移"];
        return;
    }
    self.offset = (v / kPageSize) * kPageSize;
    [self render];
}

- (void)onBack {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)toast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
