#import <UIKit/UIKit.h>
#import "MemFileSearch.h"

@interface SearchResultsViewController : UITableViewController
@property (nonatomic, copy) void (^onSelect)(MemFileSearchHit *hit);
- (instancetype)initWithHits:(NSArray<MemFileSearchHit *> *)hits
                     pattern:(NSString *)pattern
                   truncated:(BOOL)truncated;
@end
