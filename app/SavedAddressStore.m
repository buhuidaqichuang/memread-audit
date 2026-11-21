#import "SavedAddressStore.h"
#include <stdlib.h>

// 地址统一按十六进制字符串存盘，避免 JSON 数字精度问题
static uint64_t MemParseAddr(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return 0;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t hasPrefix:@"0x"] || [t hasPrefix:@"0X"]) t = [t substringFromIndex:2];
    if (!t.length) return 0;
    return strtoull(t.UTF8String, NULL, 16);
}

@implementation SavedAddress
@end

@implementation SavedAddressStore {
    NSMutableArray<NSDictionary *> *_items;
}

+ (instancetype)shared {
    static SavedAddressStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SavedAddressStore alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _path = @"/var/mobile/Media/memread_saved.json";
        _items = [NSMutableArray array];
        [self reload];
    }
    return self;
}

- (void)reload {
    [_items removeAllObjects];
    NSData *d = [NSData dataWithContentsOfFile:self.path];
    if (!d.length) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSArray class]]) return;
    for (id e in (NSArray *)obj) {
        if ([e isKindOfClass:[NSDictionary class]]) [_items addObject:(NSDictionary *)e];
    }
}

- (BOOL)persist {
    NSData *d = [NSJSONSerialization dataWithJSONObject:_items
                                                options:NSJSONWritingPrettyPrinted
                                                  error:NULL];
    if (!d) return NO;
    return [d writeToFile:self.path atomically:YES];
}

- (NSUInteger)count { return _items.count; }

- (NSArray<SavedAddress *> *)allItems {
    NSMutableArray<SavedAddress *> *out = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSDictionary *d in _items) {
        SavedAddress *s = [[SavedAddress alloc] init];
        s.addr = MemParseAddr(d[@"addr"]);
        s.type = [d[@"type"] intValue];
        NSString *lb = d[@"label"];
        s.label = [lb isKindOfClass:[NSString class]] && lb.length ? lb : @"未命名";
        NSString *nt = d[@"note"];
        s.note = [nt isKindOfClass:[NSString class]] ? nt : @"";
        NSString *gp = d[@"group"];
        s.group = [gp isKindOfClass:[NSString class]] ? gp : @"";
        [out addObject:s];
    }
    return out;
}

- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note {
    if (addr == 0) return NO;
    NSString *lb = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!lb.length) lb = @"未命名";
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *d = @{
        @"addr": [NSString stringWithFormat:@"0x%llX", addr],
        @"type": @(type),
        @"label": lb,
        @"group": gp.length ? gp : @"",
        @"note": note.length ? note : @"",
        @"ts": [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970]
    };
    [_items addObject:d];
    return [self persist];
}

- (BOOL)removeAtIndex:(NSUInteger)idx {
    if (idx >= _items.count) return NO;
    [_items removeObjectAtIndex:idx];
    return [self persist];
}

- (BOOL)renameAtIndex:(NSUInteger)idx label:(NSString *)label {
    if (idx >= _items.count) return NO;
    NSString *lb = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!lb.length) lb = @"未命名";
    NSMutableDictionary *m = [_items[idx] mutableCopy];
    m[@"label"] = lb;
    _items[idx] = m;
    return [self persist];
}

- (BOOL)setGroupAtIndex:(NSUInteger)idx group:(NSString *)group {
    if (idx >= _items.count) return NO;
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableDictionary *m = [_items[idx] mutableCopy];
    m[@"group"] = gp.length ? gp : @"";
    _items[idx] = m;
    return [self persist];
}

- (NSArray<NSString *> *)groupNames {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (SavedAddress *s in [self allItems]) {
        if (s.group.length && ![a containsObject:s.group]) [a addObject:s.group];
    }
    return a;
}

+ (NSString *)typeName:(int)type {
    switch (type) {
        case -1: return @"auto";
        case 0: return @"int32";
        case 1: return @"int64";
        case 2: return @"float";
        case 3: return @"double";
    }
    return @"?";
}

+ (NSString *)formatValue:(double)value type:(int)type {
    if (type == 0 || type == 1) return [NSString stringWithFormat:@"%lld", (long long)value];
    if (type == 2) return [NSString stringWithFormat:@"%.4f", value];
    return [NSString stringWithFormat:@"%.6f", value];
}

@end
