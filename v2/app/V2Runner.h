/*
 * V2Runner -- spawn Helpers/guest-runner and collect everything it prints.
 *
 * posix_spawn with a pipe, same shape as v1: iOS cannot fork our process and
 * run guest code in the child, so the guest always lives in a freshly spawned
 * helper that owns its own address space.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface V2Runner : NSObject

/// Blocking.  Returns the helper's termination status, appending its output.
+ (int)runGuest:(NSString *)elfPath
           root:(NSString *)root
        timeout:(NSTimeInterval)timeout
         output:(NSMutableString *)output;

@end

NS_ASSUME_NONNULL_END
