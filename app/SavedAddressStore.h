#import <Foundation/Foundation.h>
#include <stdint.h>

// 一条已保存的地址
@interface SavedAddress : NSObject
@property (nonatomic, assign) uint64_t addr;
@property (nonatomic, assign) int type;      // MEMREAD_VALTYPE_INT32 / INT64 / FLOAT / DOUBLE
@property (nonatomic, copy) NSString *label; // 自定义标签
@property (nonatomic, copy) NSString *note;
@end

// 已保存地址仓库：落盘 /var/mobile/Media/memread_saved.json，重装 App 不丢
@interface SavedAddressStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *path;

- (NSUInteger)count;
- (NSArray<SavedAddress *> *)allItems;
- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label note:(NSString *)note;
- (BOOL)removeAtIndex:(NSUInteger)idx;
- (BOOL)renameAtIndex:(NSUInteger)idx label:(NSString *)label;
- (void)reload;

+ (NSString *)typeName:(int)type;
+ (NSString *)formatValue:(double)value type:(int)type;

@end
