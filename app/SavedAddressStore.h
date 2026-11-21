#import <Foundation/Foundation.h>
#include <stdint.h>

// 一条已保存的地址
@interface SavedAddress : NSObject
@property (nonatomic, assign) uint64_t addr;
@property (nonatomic, assign) int type;      // MEMREAD_VALTYPE_INT32 / INT64 / FLOAT / DOUBLE
@property (nonatomic, copy) NSString *label; // 自定义标签
@property (nonatomic, copy) NSString *group; // 分组（如枪械名），空 = 未分组
@property (nonatomic, copy) NSString *note;
@end

// 已保存地址仓库：落盘 /var/mobile/Media/memread_saved.json，重装 App 不丢
@interface SavedAddressStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *path;

- (NSUInteger)count;
- (NSArray<SavedAddress *> *)allItems;
- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note;
// 批量保存：items 每项 @{@"addr":@(uint64_t), @"type":@(int), @"label":NSString}
// 同地址+同类型+同分组视为重复，自动跳过；返回实际新增条数
- (NSUInteger)addBatchWithGroup:(NSString *)group items:(NSArray<NSDictionary *> *)items;
- (BOOL)removeAtIndex:(NSUInteger)idx;
- (BOOL)renameAtIndex:(NSUInteger)idx label:(NSString *)label;
- (BOOL)setGroupAtIndex:(NSUInteger)idx group:(NSString *)group;
- (NSArray<NSString *> *)groupNames;
- (void)reload;

+ (NSString *)typeName:(int)type;
+ (NSString *)formatValue:(double)value type:(int)type;

@end
