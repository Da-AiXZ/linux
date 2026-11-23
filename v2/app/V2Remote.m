/*
 * V2Remote -- the device half of the loop described in v2/docs/DEVICE-LOOP.md.
 *
 *   discover -> upload a log -> long-poll -> ack
 *
 * Nothing here decides what to run; it only moves text.  All calls block, so
 * the caller runs them on a background queue.
 *
 * Discovery has two channels because one is not enough on a real Wi-Fi:
 *
 *   1. passive -- the workstation broadcasts `V2LOG <port> <addresses>` to
 *      UDP 8767 every two seconds.  Receiving a broadcast stays allowed even
 *      when sending one is filtered by the access point.
 *   2. active  -- send `V2DISCOVER` to the limited broadcast, to every
 *      interface's directed broadcast and to loopback, then read the answer.
 *
 * Whatever is found is remembered, and a manually entered address outranks
 * everything.  Every failure records why in +lastFailure, so the log names
 * the actual problem instead of just "failed".
 */
#import "V2Remote.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString *const kCachedURL = @"v2.baseURL";
static NSString *const kManualURL = @"v2.manualBaseURL";
static const unsigned short kDiscoveryPort = 8766;
static const unsigned short kBeaconPort = 8767;

static NSLock *gLock;
static NSString *gLastFailure;

@implementation V2Remote

+ (void)initialize
{
    if (self == [V2Remote class]) {
        gLock = [[NSLock alloc] init];
    }
}

+ (void)note:(NSString *)text
{
    [gLock lock];
    gLastFailure = [text copy];
    [gLock unlock];
}

+ (nullable NSString *)lastFailure
{
    [gLock lock];
    NSString *text = gLastFailure;
    [gLock unlock];
    return text;
}

#pragma mark - address bookkeeping

+ (nullable NSString *)manualBaseURL
{
    NSString *text = [[NSUserDefaults standardUserDefaults] stringForKey:kManualURL];
    return text.length > 0 ? text : nil;
}

+ (void)setManualBaseURL:(nullable NSString *)url
{
    NSString *trimmed = [url stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (trimmed.length == 0) {
        [defaults removeObjectForKey:kManualURL];
        [defaults synchronize];
        return;
    }
    if (![trimmed hasPrefix:@"http"]) {
        trimmed = [@"http://" stringByAppendingString:trimmed];
    }
    /* Add the default port only when the user did not type one.  Looking for
     * the last ":" is wrong (the scheme has one too); look after "://". */
    NSRange scheme = [trimmed rangeOfString:@"://"];
    NSString *afterScheme = scheme.location == NSNotFound
        ? trimmed
        : [trimmed substringFromIndex:NSMaxRange(scheme)];
    if (![afterScheme containsString:@":"]) {
        trimmed = [trimmed stringByAppendingFormat:@":%d", 8765];
    }
    [defaults setObject:trimmed forKey:kManualURL];
    [defaults synchronize];
}

+ (nullable NSString *)baseURL
{
    NSString *manual = [self manualBaseURL];
    if (manual.length > 0) {
        return manual;
    }
    NSString *cached = [[NSUserDefaults standardUserDefaults] stringForKey:kCachedURL];
    if (cached.length > 0) {
        return cached;
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [candidates addObjectsFromArray:[self beaconCandidatesWithTimeout:2.0]];
    [candidates addObjectsFromArray:[self probeCandidatesWithTimeout:2.0]];

    NSArray<NSString *> *unique = [[[NSOrderedSet alloc] initWithArray:candidates] array];
    if (unique.count == 0) {
        [self note:@"no beacon and no discovery reply -- local network permission "
                     @"on the device, or a firewall on the workstation"];
        return nil;
    }

    /*
     * Ping them all at once.  A workstation answers with every interface it
     * has, WSL and Hyper-V included, and the wrong ones do not refuse the
     * connection -- they just sit there until the timeout.  Serially that is
     * 1.5 s each; concurrently it is 1.5 s total, and the first reachable
     * address in the server's own order still wins.
     */
    NSMutableArray<NSNumber *> *reachable = [NSMutableArray array];
    NSLock *guard = [[NSLock alloc] init];
    dispatch_apply(unique.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                   ^(size_t index) {
        if ([self ping:unique[index]]) {
            [guard lock];
            [reachable addObject:@(index)];
            [guard unlock];
        }
    });
    if (reachable.count == 0) {
        [self note:[NSString stringWithFormat:@"nobody answered (%@)",
                                              [unique componentsJoinedByString:@", "]]];
        return nil;
    }
    NSArray<NSNumber *> *ordered = [reachable sortedArrayUsingSelector:@selector(compare:)];
    NSString *winner = unique[ordered.firstObject.unsignedIntegerValue];
    [[NSUserDefaults standardUserDefaults] setObject:winner forKey:kCachedURL];
    [self note:[NSString stringWithFormat:@"found %@", winner]];
    return winner;
}

+ (void)reset
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCachedURL];
}

/// Fold a `V2LOG <port> <a,b,c>` payload plus the sender address into URLs.
+ (void)addReply:(NSString *)reply
          sender:(NSString *)sender
      candidates:(NSMutableArray<NSString *> *)candidates
{
    NSArray<NSString *> *parts = [reply componentsSeparatedByString:@" "];
    if (parts.count < 2 || ![parts[0] hasPrefix:@"V2LOG"]) {
        return;
    }
    NSString *port = parts[1];
    NSMutableArray<NSString *> *addresses = [NSMutableArray array];
    if (sender.length > 0) {
        [addresses addObject:sender];
    }
    if (parts.count > 2) {
        [addresses addObjectsFromArray:[parts[2] componentsSeparatedByString:@","]];
    }
    for (NSString *address in addresses) {
        if (address.length == 0) {
            continue;
        }
        [candidates addObject:[NSString stringWithFormat:@"http://%@:%@",
                               address, port]];
    }
}

+ (NSArray<NSString *> *)beaconCandidatesWithTimeout:(NSTimeInterval)timeout
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return candidates;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct timeval tv = {.tv_sec = (int)timeout, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in bindAddress;
    memset(&bindAddress, 0, sizeof(bindAddress));
    bindAddress.sin_family = AF_INET;
    bindAddress.sin_port = htons(kBeaconPort);
    bindAddress.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&bindAddress, sizeof(bindAddress)) != 0) {
        char reason[128];
        snprintf(reason, sizeof(reason), "beacon listen failed: %s", strerror(errno));
        [self note:[NSString stringWithUTF8String:reason]];
        close(fd);
        return candidates;
    }

    char buffer[256];
    struct sockaddr_in from;
    socklen_t fromLength = sizeof(from);
    ssize_t got = recvfrom(fd, buffer, sizeof(buffer) - 1, 0,
                           (struct sockaddr *)&from, &fromLength);
    close(fd);
    if (got > 0) {
        buffer[got] = '\0';
        [self addReply:[NSString stringWithUTF8String:buffer]
                sender:[NSString stringWithUTF8String:inet_ntoa(from.sin_addr)]
            candidates:candidates];
    }
    return candidates;
}

/// Every directed broadcast address this device can see (Wi-Fi and friends).
+ (NSArray<NSString *> *)broadcastAddresses
{
    NSMutableArray<NSString *> *addresses = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        return addresses;
    }
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if ((entry->ifa_flags & IFF_UP) == 0 ||
            (entry->ifa_flags & IFF_BROADCAST) == 0) {
            continue;
        }
        if (entry->ifa_dstaddr == NULL) {
            continue;
        }
        struct sockaddr_in *broadcast = (struct sockaddr_in *)entry->ifa_dstaddr;
        char text[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &broadcast->sin_addr, text, sizeof(text)) == NULL) {
            continue;
        }
        NSString *address = [NSString stringWithUTF8String:text];
        if (address.length > 0 && [addresses containsObject:address] == NO) {
            [addresses addObject:address];
        }
    }
    freeifaddrs(list);
    return addresses;
}

+ (NSArray<NSString *> *)probeCandidatesWithTimeout:(NSTimeInterval)timeout
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return candidates;
    }
    int broadcast = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));
    struct timeval tv = {.tv_sec = (int)timeout, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_port = htons(kDiscoveryPort);

    target.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(fd, "V2DISCOVER", 10, 0, (struct sockaddr *)&target, sizeof(target));
    for (NSString *address in [self broadcastAddresses]) {
        struct in_addr parsed;
        if (inet_pton(AF_INET, address.UTF8String, &parsed) == 1) {
            target.sin_addr = parsed;
            sendto(fd, "V2DISCOVER", 10, 0, (struct sockaddr *)&target,
                   sizeof(target));
        }
    }
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(fd, "V2DISCOVER", 10, 0, (struct sockaddr *)&target, sizeof(target));

    char buffer[256];
    struct sockaddr_in from;
    socklen_t fromLength = sizeof(from);
    ssize_t got = recvfrom(fd, buffer, sizeof(buffer) - 1, 0,
                           (struct sockaddr *)&from, &fromLength);
    close(fd);
    if (got > 0) {
        buffer[got] = '\0';
        [self addReply:[NSString stringWithUTF8String:buffer]
                sender:[NSString stringWithUTF8String:inet_ntoa(from.sin_addr)]
            candidates:candidates];
    }
    return candidates;
}

+ (BOOL)ping:(NSString *)base
{
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/v2/ping"]];
    if (url == nil) {
        return NO;
    }
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
        return nil;      /* baseURL has already recorded why */
    }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:path]];
    if (url == nil) {
        [self note:[NSString stringWithFormat:@"bad address %@", base]];
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = timeout;
    [request setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __block NSData *result = nil;
    __block NSString *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && [(NSHTTPURLResponse *)response statusCode] == 200) {
            result = data;
        } else if (error != nil) {
            failure = [NSString stringWithFormat:@"%@ -> %@ %ld",
                       base, error.domain, (long)error.code];
        } else {
            failure = [NSString stringWithFormat:@"%@ -> HTTP %ld", base,
                       (long)[(NSHTTPURLResponse *)response statusCode]];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)((timeout + 2) * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    if (result == nil && failure == nil) {
        failure = [NSString stringWithFormat:@"%@ -> timed out after %.0fs",
                   base, timeout];
    }
    if (failure != nil) {
        [self note:failure];
    }
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
        [self reset];    /* next attempt rediscovers: the network may have moved */
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
