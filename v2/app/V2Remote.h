/*
 * V2Remote -- the device half of the loop described in v2/docs/DEVICE-LOOP.md.
 *
 *   discover (udp broadcast) -> upload a log -> long-poll -> ack
 *
 * Nothing here decides what to run; it only moves text.  All calls block, so
 * the caller runs them on a background queue.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface V2Remote : NSObject

/// Cached or freshly discovered base URL, e.g. http://192.168.1.5:8765
+ (nullable NSString *)baseURL;

/// Forget the cached address (next call rediscovers).
+ (void)reset;

/// POST a whole log.  Returns the server's id, or nil.
+ (nullable NSString *)upload:(NSString *)log
                        build:(NSString *)build
                          run:(NSString *)run
                      timeout:(NSTimeInterval)timeout;

/// Long-poll.  Returns nil when there is nothing to do.
+ (nullable NSDictionary *)nextCommandWithWait:(NSTimeInterval)wait;

+ (void)ack:(NSDictionary *)payload;

@end

NS_ASSUME_NONNULL_END
