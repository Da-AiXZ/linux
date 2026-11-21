#import <Foundation/Foundation.h>

@interface GuestLauncher : NSObject

@property (nonatomic, copy) void (^logHandler)(NSString *line);
@property (nonatomic, copy) void (^completionHandler)(int status);

- (BOOL)runBundledGuest;
- (BOOL)runGuestNamed:(NSString *)relativePath
            arguments:(NSArray<NSString *> *)arguments;

@end
