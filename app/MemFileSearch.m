#import "MemFileSearch.h"

@implementation MemFileSearchHit
- (NSString *)description {
    return [NSString stringWithFormat:@"0x%llX %@", self.offset, self.snippet];
}
@end

// 只做 ASCII 大小写折叠，二进制内容也能安全处理
static NSData *MemLowerASCII(NSData *d) {
    NSMutableData *m = [d mutableCopy];
    uint8_t *p = m.mutableBytes;
    for (NSUInteger i = 0; i < m.length; i++) {
        if (p[i] >= 'A' && p[i] <= 'Z') p[i] = (uint8_t)(p[i] + 32);
    }
    return m;
}

// 取命中前后同一行的可读文本做摘要
static NSString *MemSnippetInData(NSData *win, NSUInteger loc, NSUInteger len) {
    const uint8_t *p = win.bytes;
    NSUInteger n = win.length;
    NSUInteger s = loc, e = MIN(loc + len, n);
    NSUInteger back = 0;
    while (s > 0 && back < 160 && p[s - 1] != '\n') { s--; back++; }
    NSUInteger fwd = 0;
    while (e < n && fwd < 160 && p[e] != '\n' && p[e] != '\r') { e++; fwd++; }

    NSMutableString *str = [NSMutableString stringWithCapacity:(e > s ? e - s : 0)];
    for (NSUInteger i = s; i < e; i++) {
        uint8_t c = p[i];
        if (c == '\t') [str appendString:@"  "];
        else if (c >= 0x20 && c < 0x7F) [str appendFormat:@"%c", c];
        else [str appendString:@" "];
    }
    NSString *t = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length > 140) t = [[t substringToIndex:140] stringByAppendingString:@"…"];
    return t.length ? t : @"(无上下文)";
}

@implementation MemFileSearch

+ (void)searchFile:(NSString *)path
           pattern:(NSString *)pattern
          caseFold:(BOOL)fold
           maxHits:(NSUInteger)maxHits
          progress:(void (^)(double))progress
          complete:(void (^)(NSArray<MemFileSearchHit *> *, BOOL, NSError *))complete {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *empty = @[];
        if (!path.length || !pattern.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (complete) complete(empty, NO, nil); });
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) {
            NSError *e = [NSError errorWithDomain:@"MemFileSearch" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"无法打开文件"}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (complete) complete(empty, NO, e); });
            return;
        }
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        unsigned long long total = [attrs[NSFileSize] unsignedLongLongValue];

        NSData *pat = [pattern dataUsingEncoding:NSUTF8StringEncoding];
        if (!pat.length) pat = [pattern dataUsingEncoding:NSUTF16StringEncoding];
        if (!pat.length) {
            [fh closeFile];
            dispatch_async(dispatch_get_main_queue(), ^{ if (complete) complete(empty, NO, nil); });
            return;
        }
        NSData *patCmp = fold ? MemLowerASCII(pat) : pat;
        NSUInteger plen = patCmp.length;
        const NSUInteger CHUNK = 2 * 1024 * 1024;
        const NSUInteger MAXH = MAX(maxHits, (NSUInteger)1);

        NSMutableArray *hits = [NSMutableArray array];
        BOOL truncated = NO;
        unsigned long long winBase = 0;     // window 起始绝对偏移
        unsigned long long checked = 0;     // 已检查到的绝对截止（不含）
        NSMutableData *win = [NSMutableData dataWithCapacity:CHUNK + plen];
        double lastReport = -1.0;

        while (YES) {
            @autoreleasepool {
                NSData *chunk = nil;
                @try { chunk = [fh readDataOfLength:CHUNK]; }
                @catch (id e) { chunk = nil; break; }
                if (!chunk || chunk.length == 0) break;
                [win appendData:chunk];

                NSData *hay = fold ? MemLowerASCII(win) : win;
                NSUInteger pos = 0;
                while (pos + plen <= hay.length) {
                    NSRange r = [hay rangeOfData:patCmp options:0
                                           range:NSMakeRange(pos, hay.length - pos)];
                    if (r.location == NSNotFound) break;
                    unsigned long long abs = winBase + r.location;
                    if (abs >= checked) {
                        MemFileSearchHit *h = [MemFileSearchHit new];
                        h.offset = abs;
                        h.snippet = MemSnippetInData(win, r.location, plen);
                        [hits addObject:h];
                        if (hits.count >= MAXH) { truncated = YES; break; }
                    }
                    pos = r.location + 1;
                }
                if (truncated) break;

                // 末尾 plen-1 字节可能含跨界命中起点，留给下一块
                NSUInteger keep = plen > 1 ? plen - 1 : 0;
                if (keep > win.length) keep = win.length;
                unsigned long long newChecked = winBase + (win.length - keep);
                if (keep > 0) {
                    NSData *tail = [win subdataWithRange:NSMakeRange(win.length - keep, keep)];
                    win = [tail mutableCopy];
                } else {
                    [win setLength:0];
                }
                winBase = newChecked;
                checked = newChecked;

                double frac = total ? ((double)checked / (double)total) : 0;
                if (progress && (frac - lastReport > 0.05 || frac >= 1.0)) {
                    lastReport = frac;
                    double f = frac;
                    dispatch_async(dispatch_get_main_queue(), ^{ progress(f); });
                }
            }
        }
        [fh closeFile];

        NSArray *result = [hits copy];
        BOOL tr = truncated;
        dispatch_async(dispatch_get_main_queue(), ^{ if (complete) complete(result, tr, nil); });
    });
}

@end
