#import "V2Remote.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <string.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString *const kCachedURL = @"v2.baseURL";

@implementation V2Remote

+ (nullable NSString *)baseURL
{
    NSString *cached = [[NSUserDefaults standardUserDefaults] stringForKey:kCachedURL];
    if (cached.length > 0) {
        return cached;
    }
    NSString *found = [self discover];
    if (found.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:found forKey:kCachedURL];
    }
    return found;
}

+ (void)reset
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCachedURL];
}

+ (nullable NSString *)discover
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return nil;
    }
    int broadcast = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_port = htons(8766);
    target.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(fd, "V2DISCOVER", 10, 0, (struct sockaddr *)&target, sizeof(target));

    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(fd, "V2DISCOVER", 10, 0, (struct sockaddr *)&target, sizeof(target));

    char buffer[256];
    struct sockaddr_in from;
    socklen_t fromLength = sizeof(from);
    ssize_t got = recvfrom(fd, buffer, sizeof(buffer) - 1, 0,
                           (struct sockaddr *)&from, &fromLength);
    close(fd);
    if (got <= 0) {
        return nil;
    }
    buffer[got] = '\0';

    // "V2LOG 8765 192.168.1.5,172.31.0.1"
    NSString *reply = [NSString stringWithUTF8String:buffer];
    NSArray<NSString *> *parts = [reply componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        return nil;
    }
    NSString *port = parts[1];
    NSArray<NSString *> *addresses = parts.count > 2
        ? [parts[2] componentsSeparatedByString:@","]
        : @[[NSString stringWithUTF8String:inet_ntoa(from.sin_addr)]];

    for (NSString *address in addresses) {
        NSString *candidate = [NSString stringWithFormat:@"http://%@:%@", address, port];
        if ([self ping:candidate]) {
            return candidate;
        }
    }
    return nil;
}

+ (BOOL)ping:(NSString *)base
{
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/v2/ping"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 1.5;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        ok = (error == nil && [(NSHTTPURLResponse *)response statusCode] == 200);
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    return ok;
}

+ (nullable NSData *)post:(NSString *)path
                     body:(NSData *)body
                  timeout:(NSTimeInterval)timeout
{
    NSString *base = [self baseURL];
    if (base.length == 0) {
        return nil;
    }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = timeout;
    [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block NSData *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && [(NSHTTPURLResponse *)response statusCode] == 200) {
            result = data;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)((timeout + 2) * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    return result;
}

+ (nullable NSString *)upload:(NSString *)log
                        build:(NSString *)build
                          run:(NSString *)run
                      timeout:(NSTimeInterval)timeout
{
    NSString *device = [[UIDevice currentDevice] name] ?: @"device";
    NSString *escaped = [device stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet alphanumericCharacterSet]];
    NSString *query = [NSString stringWithFormat:@"/v2/upload?device=%@&build=%@&run=%@",
                       escaped ?: @"device", build, run];
    NSData *data = [self post:query body:[log dataUsingEncoding:NSUTF8StringEncoding]
                      timeout:timeout];
    if (data == nil) {
        [self reset];
        return nil;
    }
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([reply[@"id"] isKindOfClass:[NSString class]]) {
        return reply[@"id"];
    }
    return @"ok";
}

+ (nullable NSDictionary *)nextCommandWithWait:(NSTimeInterval)wait
{
    NSString *base = [self baseURL];
    if (base.length == 0) {
        return nil;
    }
    NSString *path = [NSString stringWithFormat:@"/v2/command?wait=%d", (int)wait];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = wait + 5;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block NSData *payload = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        payload = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)((wait + 8) * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    if (payload == nil) {
        return nil;
    }
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    return [reply isKindOfClass:[NSDictionary class]] ? reply : nil;
}

+ (void)ack:(NSDictionary *)payload
{
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [self post:@"/v2/ack" body:body timeout:5];
}

@end
