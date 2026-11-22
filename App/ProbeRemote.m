#import "ProbeRemote.h"

static NSString *const ProbeRemoteURLKey = @"ProbeRemoteURL";

/*
 * Default points at the workstation that builds and analyses the project.
 * It can be changed at runtime from the "..." menu, and the value is kept in
 * NSUserDefaults so it survives reinstalls of the same container.
 */
static NSString *const ProbeRemoteDefaultURL = @"http://192.168.190.180:8765";

@implementation ProbeRemote

+ (NSString *)baseURL
{
    NSString *value = [[NSUserDefaults standardUserDefaults]
        stringForKey:ProbeRemoteURLKey];
    if (value.length == 0) {
        return ProbeRemoteDefaultURL;
    }
    return value;
}

+ (void)setBaseURL:(NSString *)url
{
    NSString *trimmed = [(url ?: @"") stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while (trimmed.length > 1 && [trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    [[NSUserDefaults standardUserDefaults] setObject:trimmed
                                             forKey:ProbeRemoteURLKey];
}

+ (BOOL)configured
{
    return [self baseURL].length > 0;
}

+ (NSURLSession *)session
{
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 4.0;
        configuration.timeoutIntervalForResource = 8.0;
        configuration.requestCachePolicy =
            NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPShouldUsePipelining = NO;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

+ (NSURL *)endpointWithPath:(NSString *)path
{
    NSString *base = [self baseURL];
    if (base.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:[base stringByAppendingString:path]];
}

+ (void)uploadLog:(NSString *)text
       completion:(void (^)(NSString *))completion
{
    void (^finish)(NSString *) = ^(NSString *status) {
        if (completion == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(status);
        });
    };

    NSURL *url = [self endpointWithPath:@"/log"];
    if (url == nil) {
        finish(@"remote: no server configured");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"text/plain; charset=utf-8"
   forHTTPHeaderField:@"Content-Type"];
    NSData *body = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    request.HTTPBody = body;

    NSURLSessionDataTask *task = [[self session]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data,
                              NSURLResponse *response,
                              NSError *error) {
        if (error != nil) {
            finish([NSString stringWithFormat:@"remote: upload failed (%@)",
                                              error.localizedDescription]);
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        if (status != 200) {
            finish([NSString stringWithFormat:@"remote: upload http %ld",
                                              (long)status]);
            return;
        }
        finish([NSString stringWithFormat:@"remote: log uploaded (%lu bytes)",
                                          (unsigned long)body.length]);
    }];
    [task resume];
}

+ (void)pollAction:(void (^)(NSString *))handler
{
    void (^finish)(NSString *) = ^(NSString *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(action);
        });
    };

    NSURL *url = [self endpointWithPath:@"/next"];
    if (url == nil) {
        finish(nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";

    NSURLSessionDataTask *task = [[self session]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data,
                              NSURLResponse *response,
                              NSError *error) {
        if (error != nil || data.length == 0) {
            finish(nil);
            return;
        }
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        if (status != 200) {
            finish(nil);
            return;
        }
        id object = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:NULL];
        if (![object isKindOfClass:[NSDictionary class]]) {
            finish(nil);
            return;
        }
        id action = ((NSDictionary *)object)[@"action"];
        finish([action isKindOfClass:[NSString class]] ? action : nil);
    }];
    [task resume];
}

@end
