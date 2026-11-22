#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Minimal client for the workstation-side log server (tools/log_server.py).
 *
 *   POST <base>/log    body = log text
 *   GET  <base>/next   -> {"action":"..."} or 204 when the queue is empty
 *
 * Requests use IP literals, which are exempt from App Transport Security;
 * the local-network privacy prompt still applies (NSLocalNetworkUsageDescription).
 */
@interface ProbeRemote : NSObject

+ (NSString *)baseURL;
+ (void)setBaseURL:(NSString *)url;
+ (BOOL)configured;

+ (void)uploadLog:(NSString *)text
       completion:(void (^_Nullable)(NSString *_Nullable status))completion;

+ (void)pollAction:(void (^)(NSString *_Nullable action))handler;

@end

NS_ASSUME_NONNULL_END
