#import "SavedAddressStore.h"
#import "memread_core.h"
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
- (BOOL)inModule {
    return self.moduleUUID.length > 0;
}
- (BOOL)hasChain {
    return self.moduleUUID.length > 0 && self.chainOffsets.count > 0;
}
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
        NSString *mu = d[@"muuid"];
        s.moduleUUID = [mu isKindOfClass:[NSString class]] ? mu : @"";
        NSString *mn = d[@"mname"];
        s.moduleName = [mn isKindOfClass:[NSString class]] ? mn : @"";
        NSNumber *mo = d[@"moff"];
        s.moduleOff = [mo isKindOfClass:[NSNumber class]] ? mo.unsignedLongLongValue : 0;
        NSString *cn = d[@"cname"];
        s.chainName = [cn isKindOfClass:[NSString class]] ? cn : @"";
        NSNumber *cso = d[@"coff"];
        s.chainStaticOff = [cso isKindOfClass:[NSNumber class]] ? cso.unsignedLongLongValue : 0;
        id co = d[@"cchain"];
        if ([co isKindOfClass:[NSArray class]]) {
            NSMutableArray<NSNumber *> *offs = [NSMutableArray array];
            for (id v in (NSArray *)co) {
                if ([v isKindOfClass:[NSNumber class]]) [offs addObject:v];
            }
            s.chainOffsets = offs;
        } else {
            s.chainOffsets = @[];
        }
        NSString *pp = d[@"proc"];
        s.procPath = [pp isKindOfClass:[NSString class]] ? pp : @"";
        [out addObject:s];
    }
    return out;
}

- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note {
    return [self addAddr:addr type:type label:label group:group note:note
               moduleUUID:@"" moduleName:@"" moduleOff:0];
}

- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note
        moduleUUID:(NSString *)uuid moduleName:(NSString *)name moduleOff:(uint64_t)off {
    if (addr == 0) return NO;
    NSString *lb = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!lb.length) lb = @"未命名";
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *mu = uuid.length ? uuid : @"";
    NSDictionary *d = @{
        @"addr": [NSString stringWithFormat:@"0x%llX", addr],
        @"type": @(type),
        @"label": lb,
        @"group": gp.length ? gp : @"",
        @"note": note.length ? note : @"",
        @"muuid": mu,
        @"mname": (name.length ? name : @""),
        @"moff": @(off),
        @"ts": [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970]
    };
    [_items addObject:d];
    return [self persist];
}

- (BOOL)addChain:(NSString *)uuid name:(NSString *)name staticOff:(uint64_t)staticOff
            offs:(NSArray<NSNumber *> *)offs type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note {
    return [self addChain:uuid name:name staticOff:staticOff offs:offs type:type
                     label:label group:group note:note procPath:@""];
}

- (BOOL)addChain:(NSString *)uuid name:(NSString *)name staticOff:(uint64_t)staticOff
            offs:(NSArray<NSNumber *> *)offs type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note procPath:(NSString *)procPath {
    if (!uuid.length || !offs.count || offs.count > MEMREAD_CHAIN_MAX_DEPTH) return NO;
    NSString *lb = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!lb.length) lb = @"未命名";
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSNumber *> *co = [NSMutableArray array];
    for (NSNumber *n in offs) [co addObject:@([n longLongValue])];
    NSDictionary *d = @{
        @"addr": @"0x0",           // 链存的是静态槽，不是绝对地址
        @"type": @(type),
        @"label": lb,
        @"group": gp.length ? gp : @"",
        @"note": note.length ? note : @"",
        @"muuid": uuid,
        @"mname": (name.length ? name : @""),
        @"moff": @(0),
        @"cname": (name.length ? name : @""),
        @"coff": @(staticOff),
        @"cchain": co,
        @"proc": (procPath.length ? procPath : @""),
        @"ts": [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970]
    };
    [_items addObject:d];
    return [self persist];
}

- (NSUInteger)addBatchWithGroup:(NSString *)group items:(NSArray<NSDictionary *> *)items {
    NSString *gp = [group stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!gp) gp = @"";

    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSDictionary *d in _items) {
        NSString *a = d[@"addr"], *g = d[@"group"];
        NSNumber *t = d[@"type"];
        if (![a isKindOfClass:[NSString class]] || ![t isKindOfClass:[NSNumber class]]) continue;
        NSString *gi = [g isKindOfClass:[NSString class]] ? g : @"";
        [keys addObject:[NSString stringWithFormat:@"%@|%d|%@", a.lowercaseString, t.intValue, gi]];
    }

    NSString *ts = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970];
    NSUInteger added = 0;
    for (NSDictionary *it in items) {
        uint64_t addr = [it[@"addr"] unsignedLongLongValue];
        if (addr == 0) continue;
        int type = [it[@"type"] intValue];
        NSString *label = it[@"label"];
        if (![label isKindOfClass:[NSString class]] || !label.length) continue;

        NSString *hex = [NSString stringWithFormat:@"0x%llX", addr];
        NSString *key = [NSString stringWithFormat:@"%@|%d|%@", hex.lowercaseString, type, gp];
        if ([keys containsObject:key]) continue;

        [_items addObject:@{
            @"addr": hex,
            @"type": @(type),
            @"label": label,
            @"group": gp,
            @"note": @"",
            @"muuid": it[@"uuid"] ?: @"",
            @"mname": it[@"name"] ?: @"",
            @"moff": it[@"off"] ?: @(0),
            @"ts": ts
        }];
        [keys addObject:key];
        added++;
    }
    if (added) [self persist];
    return added;
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
