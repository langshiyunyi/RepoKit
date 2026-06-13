#import <Foundation/Foundation.h>

@interface RKHelperResult : NSObject
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy) NSString *output;
@end

@interface RKHelperClient : NSObject
+ (instancetype)sharedClient;
- (RKHelperResult *)runArguments:(NSArray<NSString *> *)arguments;
- (NSArray<NSDictionary *> *)repos;
- (NSDictionary *)repoWithID:(NSString *)repoID;
- (NSArray<NSDictionary *> *)packagesForRepoID:(NSString *)repoID;
@end
