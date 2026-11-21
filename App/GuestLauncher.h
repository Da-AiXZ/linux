#import <Foundation/Foundation.h>

@interface GuestLauncher : NSObject

@property (nonatomic, copy) void (^logHandler)(NSString *line);
@property (nonatomic, copy) void (^completionHandler)(int status);

- (BOOL)runBundledGuest;
- (BOOL)runGuestNamed:(NSString *)relativePath
            arguments:(NSArray<NSString *> *)arguments;

/*
 * Build an offline apk repository from the cached APKINDEX files so the
 * index parser can be exercised without any network in the loop.
 */
- (BOOL)prepareLocalIndexRepositoryAtRoot:(NSString *)rootPath;

@end
