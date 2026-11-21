#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ProbeServiceProtocol <NSObject>

- (void)logJSON:(NSString *)json withReply:(void (^)(void))reply;
- (void)pingWithReply:(void (^)(int64_t value))reply;

@end

NS_ASSUME_NONNULL_END
