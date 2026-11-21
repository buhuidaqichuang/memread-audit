#import <Foundation/Foundation.h>

@interface MemFileSearchHit : NSObject
@property (nonatomic, assign) unsigned long long offset;
@property (nonatomic, copy) NSString *snippet;
@end

@interface MemFileSearch : NSObject
// 后台线程逐块扫描文件，命中回调在主线程
+ (void)searchFile:(NSString *)path
           pattern:(NSString *)pattern
          caseFold:(BOOL)fold
           maxHits:(NSUInteger)maxHits
          progress:(void (^)(double fraction))progress
          complete:(void (^)(NSArray<MemFileSearchHit *> *hits, BOOL truncated, NSError *err))complete;
@end
