#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProbeController : NSObject

@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) void (^completionHandler)(void);

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
