#import <Foundation/Foundation.h>
#include <stdint.h>

// 一条已保存的地址
@interface SavedAddress : NSObject
@property (nonatomic, assign) uint64_t addr;      // 保存时的绝对地址
@property (nonatomic, assign) int type;           // MEMREAD_VALTYPE_INT32 / INT64 / FLOAT / DOUBLE
@property (nonatomic, copy) NSString *label;      // 自定义标签
@property (nonatomic, copy) NSString *group;      // 分组（如枪械名），空 = 未分组
@property (nonatomic, copy) NSString *note;
// 模块内地址：UUID 非空表示可用「模块基址 + 偏移」跨重启复原；堆地址则为空
@property (nonatomic, copy) NSString *moduleUUID;
@property (nonatomic, copy) NSString *moduleName;
@property (nonatomic, assign) uint64_t moduleOff;
@property (nonatomic, readonly) BOOL inModule;
// 指针链：moduleUUID 非空且 chainOffsets.count > 0 表示用「模块静态槽 + 多级偏移」跨重启复原
@property (nonatomic, copy) NSString *chainName;
@property (nonatomic, assign) uint64_t chainStaticOff;
@property (nonatomic, copy) NSArray<NSNumber *> *chainOffsets;   // int64，长度 = 解引用层数
@property (nonatomic, readonly) BOOL hasChain;
@end

// 已保存地址仓库：落盘 /var/mobile/Media/memread_saved.json，重装 App 不丢
@interface SavedAddressStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *path;

- (NSUInteger)count;
- (NSArray<SavedAddress *> *)allItems;
- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note;
// 带模块信息的保存：uuid 非空时记「模块基址+偏移」，跨重启可复原
- (BOOL)addAddr:(uint64_t)addr type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note
        moduleUUID:(NSString *)uuid moduleName:(NSString *)name moduleOff:(uint64_t)off;
// 批量保存：items 每项 @{@"addr":@(uint64_t), @"type":@(int), @"label":NSString,
//                     可选 @"uuid":NSString, @"name":NSString, @"off":@(uint64_t)}
// 同地址+同类型+同分组视为重复，自动跳过；返回实际新增条数
- (NSUInteger)addBatchWithGroup:(NSString *)group items:(NSArray<NSDictionary *> *)items;
// 保存指针链：uuid + staticOff + offs（int64 数组），跨重启按模块基址重解
- (BOOL)addChain:(NSString *)uuid name:(NSString *)name staticOff:(uint64_t)staticOff
            offs:(NSArray<NSNumber *> *)offs type:(int)type label:(NSString *)label
           group:(NSString *)group note:(NSString *)note;
- (BOOL)removeAtIndex:(NSUInteger)idx;
- (BOOL)renameAtIndex:(NSUInteger)idx label:(NSString *)label;
- (BOOL)setGroupAtIndex:(NSUInteger)idx group:(NSString *)group;
- (NSArray<NSString *> *)groupNames;
- (void)reload;

+ (NSString *)typeName:(int)type;
+ (NSString *)formatValue:(double)value type:(int)type;

@end
