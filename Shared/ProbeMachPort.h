#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProbeMachPort : NSObject <NSSecureCoding>

@property (nonatomic, readonly) mach_port_t port;
@property (nonatomic, assign) BOOL sendOnce;

+ (nullable instancetype)portWithPortName:(mach_port_name_t)port
                                 sendOnce:(BOOL)sendOnce;
- (nullable instancetype)initWithPortName:(mach_port_name_t)port;

@end

NS_ASSUME_NONNULL_END
